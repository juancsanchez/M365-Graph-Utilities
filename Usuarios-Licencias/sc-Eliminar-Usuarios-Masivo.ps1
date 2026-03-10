<#
.SYNOPSIS
    Elimina masivamente usuarios de Microsoft Entra ID desde un archivo CSV.

.DESCRIPTION
    Este script se conecta a Microsoft Graph utilizando autenticación desatendida (Certificado).
    Lee un archivo CSV con las columnas 'upn' y 'objectId'.

    Para cada fila, el script intenta encontrar al usuario de la siguiente forma:
    - Si 'objectId' tiene valor, lo usa directamente para localizar al usuario (más rápido y exacto).
    - Si 'objectId' está vacío, intenta localizar al usuario por 'upn'.
    - Si ambas columnas están vacías, la fila se omite con una advertencia.

    IMPORTANTE: Antes de proceder con las eliminaciones, el script busca y muestra todos los
    usuarios que va a eliminar, y solicita una confirmación explícita del operador.

    Al finalizar, genera un reporte CSV con el resultado de cada operación.

.PARAMETER CsvFilePath
    Ruta al archivo CSV de entrada.
    Columnas requeridas: upn, objectId (al menos una de las dos debe tener valor por fila)

.REQUIREMENTS
    - Módulo de PowerShell: Microsoft.Graph.Users
    - Archivo 'config.json' en la carpeta raíz del repositorio.
    - Permisos de API (Application):
        - User.ReadWrite.All  (para eliminar usuarios)

.NOTES
    Autor: Juan Sánchez
    Fecha: 2026-03-10
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Ruta al archivo CSV de entrada.")]
    [string]$CsvFilePath
)

# ============================================================
# 1. VERIFICACIÓN DE MÓDULOS
# ============================================================
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
    Write-Host "Instalando módulo 'Microsoft.Graph.Users'..." -ForegroundColor Yellow
    try {
        Install-Module Microsoft.Graph.Users -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    catch {
        Write-Error "No se pudo instalar el módulo 'Microsoft.Graph.Users': $($_.Exception.Message)"
        return
    }
}

# ============================================================
# 2. CONEXIÓN A MICROSOFT GRAPH
# ============================================================
$configFilePath = Join-Path -Path (Split-Path $PSScriptRoot -Parent) -ChildPath "config.json"
if (-not (Test-Path $configFilePath)) {
    Write-Error "No se encontró el archivo 'config.json' en: $configFilePath"
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json

    Write-Host "Conectando a Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $config.tenantId -AppId $config.clientId -CertificateThumbprint $config.certThumbprint
    Write-Host "Conexión establecida.`n" -ForegroundColor Green
}
catch {
    Write-Error "Error crítico de conexión: $($_.Exception.Message)"
    return
}

# ============================================================
# 3. LECTURA Y VALIDACIÓN DEL CSV
# ============================================================
try {
    if (-not (Test-Path $CsvFilePath)) {
        throw "Archivo CSV no encontrado: $CsvFilePath"
    }

    $csvData = Import-Csv -Path $CsvFilePath
    $totalRows = $csvData.Count

    if ($totalRows -eq 0) {
        Write-Warning "El archivo CSV está vacío. No hay usuarios a procesar."
        return
    }

    Write-Host "Se leyeron $totalRows filas del CSV." -ForegroundColor Cyan
}
catch {
    Write-Error "Error al leer el CSV: $($_.Exception.Message)"
    if (Get-MgContext) { Disconnect-MgGraph | Out-Null }
    return
}

# ============================================================
# 4. BÚSQUEDA Y RESOLUCIÓN DE USUARIOS (Pre-validación)
# ============================================================
Write-Host "`n--- FASE 1: Buscando usuarios en Entra ID ---" -ForegroundColor Cyan

$usersToDelete = [System.Collections.Generic.List[object]]::new()
$skippedRows = [System.Collections.Generic.List[object]]::new()
$counter = 0

foreach ($row in $csvData) {
    $counter++
    $upnInput = $row.upn
    $objectIdInput = $row.objectId

    Write-Progress -Activity "Buscando usuarios" -Status "($counter/$totalRows)" -PercentComplete (($counter / $totalRows) * 100)

    # Validar que al menos un campo tenga valor
    if ([string]::IsNullOrWhiteSpace($upnInput) -and [string]::IsNullOrWhiteSpace($objectIdInput)) {
        Write-Warning "  [!] Fila $counter omitida: 'upn' y 'objectId' están ambos vacíos."
        $skippedRows.Add([PSCustomObject]@{
                Fila     = $counter
                UPN      = "(vacío)"
                ObjectId = "(vacío)"
                Motivo   = "Fila sin datos identificadores"
            })
        continue
    }

    $foundUser = $null
    $searchKey = ""

    try {
        # Prioridad 1: Buscar por objectId
        if (-not [string]::IsNullOrWhiteSpace($objectIdInput)) {
            $searchKey = $objectIdInput
            $foundUser = Get-MgUser -UserId $objectIdInput -ErrorAction SilentlyContinue
        }

        # Prioridad 2: Buscar por UPN si no se encontró por objectId
        if (-not $foundUser -and -not [string]::IsNullOrWhiteSpace($upnInput)) {
            $searchKey = $upnInput
            $foundUser = Get-MgUser -UserId $upnInput -ErrorAction SilentlyContinue
        }

        if ($foundUser) {
            Write-Host "  [OK] Encontrado: $($foundUser.UserPrincipalName) | ID: $($foundUser.Id)" -ForegroundColor Green
            $usersToDelete.Add([PSCustomObject]@{
                    UserId            = $foundUser.Id
                    UserPrincipalName = $foundUser.UserPrincipalName
                    DisplayName       = $foundUser.DisplayName
                    SearchKey         = $searchKey
                })
        }
        else {
            Write-Warning "  [!] No encontrado (clave: '$searchKey'). Se omitirá."
            $skippedRows.Add([PSCustomObject]@{
                    Fila     = $counter
                    UPN      = $upnInput
                    ObjectId = $objectIdInput
                    Motivo   = "Usuario no encontrado en Entra ID"
                })
        }
    }
    catch {
        Write-Warning "  [!] Error al buscar '$searchKey': $($_.Exception.Message). Se omitirá."
        $skippedRows.Add([PSCustomObject]@{
                Fila     = $counter
                UPN      = $upnInput
                ObjectId = $objectIdInput
                Motivo   = "Error durante la búsqueda: $($_.Exception.Message)"
            })
    }
}

Write-Progress -Activity "Buscando usuarios" -Completed

# ============================================================
# 5. CONFIRMACIÓN ANTES DE ELIMINAR
# ============================================================
Write-Host "`n============================================================" -ForegroundColor Yellow
Write-Host " RESUMEN PREVIO A LA ELIMINACIÓN" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host "  Total filas en CSV    : $totalRows"
Write-Host "  Usuarios a ELIMINAR   : $($usersToDelete.Count)" -ForegroundColor Red
Write-Host "  Filas omitidas/error  : $($skippedRows.Count)" -ForegroundColor DarkYellow
Write-Host "============================================================" -ForegroundColor Yellow

if ($usersToDelete.Count -eq 0) {
    Write-Host "`nNo se encontró ningún usuario válido para eliminar. El script finalizará sin cambios." -ForegroundColor Yellow
    if (Get-MgContext) { Disconnect-MgGraph | Out-Null }
    return
}

Write-Host "`nUsuarios que serán ELIMINADOS PERMANENTEMENTE:" -ForegroundColor Red
$usersToDelete | ForEach-Object {
    Write-Host "  * $($_.DisplayName) | $($_.UserPrincipalName) | ID: $($_.UserId)" -ForegroundColor White
}

Write-Host ""
Write-Host "ADVERTENCIA: Esta acción es IRREVERSIBLE. Los usuarios serán movidos a la papelera" -ForegroundColor DarkYellow
Write-Host "de reciclaje de Entra ID (recuperables por 30 días)." -ForegroundColor DarkYellow
Write-Host ""

$confirmation = Read-Host "¿Confirma la eliminación de $($usersToDelete.Count) usuario(s)? Escriba 'CONFIRMAR' para continuar"

if ($confirmation -ne "CONFIRMAR") {
    Write-Host "`nOperación cancelada por el operador. No se eliminó ningún usuario." -ForegroundColor Yellow
    if (Get-MgContext) { Disconnect-MgGraph | Out-Null }
    return
}

try {

    # ============================================================
    # 6. ELIMINACIÓN DE USUARIOS
    # ============================================================
    Write-Host "`n--- FASE 2: Eliminando usuarios ---" -ForegroundColor Cyan

    $reportData = [System.Collections.Generic.List[object]]::new()
    $deleteCounter = 0
    $totalToDelete = $usersToDelete.Count

    foreach ($userEntry in $usersToDelete) {
        $deleteCounter++
        Write-Progress -Activity "Eliminando usuarios" -Status "($deleteCounter/$totalToDelete) - $($userEntry.UserPrincipalName)" -PercentComplete (($deleteCounter / $totalToDelete) * 100)

        $status = "Exitoso"
        $message = "Usuario eliminado correctamente."

        try {
            Remove-MgUser -UserId $userEntry.UserId -ErrorAction Stop
            Write-Host "  [-] $($userEntry.UserPrincipalName)" -ForegroundColor Green
        }
        catch {
            $status = "Error"
            $message = $_.Exception.Message
            Write-Warning "  [X] Error al eliminar '$($userEntry.UserPrincipalName)': $message"
        }

        $reportData.Add([PSCustomObject]@{
                UserPrincipalName = $userEntry.UserPrincipalName
                DisplayName       = $userEntry.DisplayName
                UserId            = $userEntry.UserId
                Estado            = $status
                Detalle           = $message
                Fecha             = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            })
    }

    Write-Progress -Activity "Eliminando usuarios" -Completed

    # Agregar filas omitidas al reporte
    foreach ($skipped in $skippedRows) {
        $reportData.Add([PSCustomObject]@{
                UserPrincipalName = $skipped.UPN
                DisplayName       = ""
                UserId            = $skipped.ObjectId
                Estado            = "Omitido"
                Detalle           = $skipped.Motivo
                Fecha             = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            })
    }

    # ============================================================
    # 7. EXPORTAR REPORTE
    # ============================================================
    if ($reportData.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
        $outputFile = Join-Path -Path $PSScriptRoot -ChildPath "Reporte_Usuarios_Eliminados_$timestamp.csv"

        $reportData | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

        $exitosos = ($reportData | Where-Object { $_.Estado -eq "Exitoso" }).Count
        $errores = ($reportData | Where-Object { $_.Estado -eq "Error" }).Count
        $omitidos = ($reportData | Where-Object { $_.Estado -eq "Omitido" }).Count

        Write-Host "`n============================================================" -ForegroundColor Cyan
        Write-Host " RESULTADO FINAL" -ForegroundColor Cyan
        Write-Host "============================================================" -ForegroundColor Cyan
        Write-Host "  Eliminados exitosamente : $exitosos" -ForegroundColor Green
        Write-Host "  Errores durante eliminación: $errores" -ForegroundColor Red
        Write-Host "  Filas omitidas           : $omitidos" -ForegroundColor DarkYellow
        Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "  Reporte generado en: $outputFile" -ForegroundColor White
        Write-Host "============================================================" -ForegroundColor Cyan
    }

}
catch {
    Write-Error "Error crítico durante el proceso de eliminación: $($_.Exception.Message)"
}
finally {
    # ============================================================
    # 8. DESCONEXIÓN
    # ============================================================
    if (Get-MgContext) { Disconnect-MgGraph | Out-Null }
}
