<#
.SYNOPSIS
    Renombra grupos de seguridad en Microsoft Entra ID masivamente basándose en un archivo CSV.

.DESCRIPTION
    Este script se conecta a Microsoft Graph utilizando un certificado (autenticación desatendida).
    Lee un archivo CSV con tres columnas y actualiza el displayName de cada grupo especificado.

    El script prioriza la búsqueda por 'groupId'. Si el ID está vacío, intenta localizar
    el grupo por su 'nombreActual' (DisplayName exacto) como fallback.
    
    Al finalizar, genera un reporte CSV con el estado de cada operación.

.PARAMETER CsvFilePath
    Ruta al archivo CSV de entrada.
    Columnas requeridas:
    - nombreActual : Nombre actual del grupo (usado como fallback si no hay groupId)
    - groupId     : Object ID del grupo en Entra ID (recomendado, prioritario)
    - nombreNuevo : Nuevo nombre que se asignará al grupo

.REQUIREMENTS
    - Módulo de PowerShell: Microsoft.Graph.Groups
    - Archivo 'config.json' en la misma carpeta con tenantId, clientId y certThumbprint.
    - Permisos de API (Application): Group.ReadWrite.All

.EXAMPLE
    .\sc-Renombrar-Grupos-Masivo.ps1 -CsvFilePath ".\grupos_renombrados.csv"

.NOTES
    Autor: Juan Sánchez
    Fecha: 2026-03-02
    Versión: 1.0
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Ruta al archivo CSV con las columnas 'nombreActual', 'groupId' y 'nombreNuevo'.")]
    [string]$CsvFilePath
)

# --- 1. VERIFICACIÓN DE MÓDULOS ---
$requiredModules = @("Microsoft.Graph.Groups")
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Instalando módulo '$module'..." -ForegroundColor Yellow
        try {
            Install-Module $module -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        }
        catch {
            Write-Error "No se pudo instalar el módulo '$module'. Por favor, instálelo manualmente."
            return
        }
    }
}

# --- 2. CONEXIÓN Y CONFIGURACIÓN ---
$configFilePath = Join-Path -Path (Split-Path $PSScriptRoot -Parent) -ChildPath "config.json"
if (-not (Test-Path $configFilePath)) {
    Write-Error "No se encontró el archivo 'config.json' en: $configFilePath"
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json

    Write-Host "Conectando a Microsoft Graph con certificado..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $config.tenantId -AppId $config.clientId -CertificateThumbprint $config.certThumbprint
    Write-Host "Conexión establecida exitosamente." -ForegroundColor Green
}
catch {
    Write-Error "Error crítico al conectar a Microsoft Graph: $($_.Exception.Message)"
    Write-Error "Verifique que el certificado esté instalado y los datos en config.json sean correctos."
    return
}

# --- 3. PROCESAMIENTO PRINCIPAL ---
$reportData = [System.Collections.Generic.List[object]]::new()

try {
    # Validar existencia del archivo CSV
    if (-not (Test-Path $CsvFilePath)) {
        throw "El archivo CSV no fue encontrado en la ruta: '$CsvFilePath'"
    }

    Write-Host "Leyendo archivo CSV..." -ForegroundColor Cyan
    $groupsToRename = Import-Csv -Path $CsvFilePath
    $totalRows = $groupsToRename.Count
    $counter = 0

    if ($totalRows -eq 0) {
        Write-Warning "El archivo CSV está vacío. No hay grupos para procesar."
        return
    }

    # Validar que las columnas requeridas existan
    $firstRow = $groupsToRename[0]
    $requiredColumns = @("nombreActual", "groupId", "nombreNuevo")
    foreach ($col in $requiredColumns) {
        if ($null -eq $firstRow.PSObject.Properties[$col]) {
            throw "El CSV no contiene la columna requerida: '$col'. Verifique los encabezados del archivo."
        }
    }

    Write-Host "Se encontraron $totalRows grupos para procesar." -ForegroundColor Cyan
    Write-Host "Iniciando proceso de renombrado...`n" -ForegroundColor Cyan

    foreach ($row in $groupsToRename) {
        $counter++

        $nombreActual = $row.nombreActual.Trim()
        $groupId = $row.groupId.Trim()
        $nombreNuevo = $row.nombreNuevo.Trim()

        $identifier = if (-not [string]::IsNullOrWhiteSpace($groupId)) { $groupId } else { $nombreActual }

        Write-Progress -Activity "Renombrando Grupos en Entra ID" `
            -Status "($counter/$totalRows) - Procesando: $identifier" `
            -PercentComplete (($counter / $totalRows) * 100)

        # Variables de estado para el reporte
        $status = "Exitoso"
        $message = "Grupo renombrado correctamente."
        $resolvedId = $null
        $resolvedName = $null

        try {
            # VALIDACIONES BÁSICAS DE LA FILA
            if ([string]::IsNullOrWhiteSpace($nombreNuevo)) {
                throw "El campo 'nombreNuevo' está vacío. Se omite esta fila."
            }
            if ([string]::IsNullOrWhiteSpace($groupId) -and [string]::IsNullOrWhiteSpace($nombreActual)) {
                throw "Debe proporcionar al menos 'groupId' o 'nombreActual' para identificar el grupo."
            }

            # LOCALIZAR EL GRUPO
            # Prioridad 1: Buscar por Object ID (más confiable, evita ambigüedades)
            $group = $null
            if (-not [string]::IsNullOrWhiteSpace($groupId)) {
                $group = Get-MgGroup -GroupId $groupId -Property "id,displayName" -ErrorAction SilentlyContinue
            }

            # Prioridad 2 (Fallback): Buscar por DisplayName exacto
            if (-not $group -and -not [string]::IsNullOrWhiteSpace($nombreActual)) {
                Write-Host "  ID no encontrado o vacío, buscando por nombre: '$nombreActual'..." -ForegroundColor Gray
                
                # El filtro OData requiere ConsistencyLevel eventual para búsquedas de texto
                $group = Get-MgGroup -Filter "displayName eq '$nombreActual'" `
                    -Property "id,displayName" `
                    -ConsistencyLevel eventual `
                    -ErrorAction SilentlyContinue

                # Si la búsqueda devuelve más de un resultado, es ambiguo — no renombrar
                if ($group -is [array] -and $group.Count -gt 1) {
                    throw "Se encontraron $($group.Count) grupos con el nombre '$nombreActual'. Proporcione el 'groupId' para evitar ambigüedad."
                }
            }

            # Si no se encontró el grupo por ningún método, lanzar error
            if (-not $group) {
                throw "No se encontró ningún grupo con el ID '$groupId' ni con el nombre '$nombreActual'."
            }

            $resolvedId = $group.Id
            $resolvedName = $group.DisplayName

            # Verificar si el nombre ya es el correcto (evita llamadas innecesarias a la API)
            if ($resolvedName -eq $nombreNuevo) {
                $status = "Omitido"
                $message = "El grupo ya tiene el nombre '$nombreNuevo'. No se requiere cambio."
                Write-Host "  [=] '$resolvedName' ya tiene el nombre correcto. Omitido." -ForegroundColor Gray
            }
            else {
                Write-Host "  Renombrando: '$resolvedName' -> '$nombreNuevo'..." -ForegroundColor Yellow

                # EJECUTAR EL RENOMBRADO
                Update-MgGroup -GroupId $resolvedId -DisplayName $nombreNuevo -ErrorAction Stop

                Write-Host "  [+] Éxito." -ForegroundColor Green
            }
        }
        catch {
            $status = "Error"
            $message = $_.Exception.Message

            # Mensajes de error más descriptivos para los casos comunes
            if ($message -match "Request_ResourceNotFound") {
                $message = "El grupo con ID '$groupId' no existe en Entra ID."
            }
            elseif ($message -match "Authorization_RequestDenied") {
                $message = "Permisos insuficientes. Se requiere 'Group.ReadWrite.All' consentido por un administrador."
            }
            elseif ($message -match "ObjectConflict" -or $message -match "already exists") {
                $message = "Ya existe otro grupo con el nombre '$nombreNuevo'. Elija un nombre diferente."
            }

            Write-Error "  [X] Fallo al procesar '$identifier': $message"
        }

        # REGISTRAR RESULTADO EN EL REPORTE
        $reportData.Add([PSCustomObject]@{
                "GroupID"         = if ($resolvedId) { $resolvedId }   else { $groupId }
                "Nombre Original" = if ($resolvedName) { $resolvedName } else { $nombreActual }
                "Nombre Nuevo"    = $nombreNuevo
                "Estado"          = $status
                "Detalle"         = $message
            })
    }

    Write-Progress -Activity "Renombrando Grupos en Entra ID" -Completed
}
catch {
    Write-Error "Ocurrió un error crítico durante la ejecución: $($_.Exception.Message)"
}
finally {
    # --- 4. EXPORTAR REPORTE ---
    if ($reportData.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
        $reportFileName = "Reporte_Renombrado_Grupos_$timestamp.csv"
        $reportFilePath = Join-Path -Path $PSScriptRoot -ChildPath $reportFileName

        $reportData | Export-Csv -Path $reportFilePath -NoTypeInformation -Encoding UTF8 -Delimiter ";"

        Write-Host "`n--------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "Proceso completado. Reporte generado en:" -ForegroundColor Green
        Write-Host $reportFilePath -ForegroundColor White
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan

        # Resumen rápido en consola
        $exitosos = ($reportData | Where-Object { $_.Estado -eq "Exitoso" }).Count
        $omitidos = ($reportData | Where-Object { $_.Estado -eq "Omitido" }).Count
        $errores = ($reportData | Where-Object { $_.Estado -eq "Error" }).Count

        Write-Host "Resumen: $exitosos renombrados | $omitidos omitidos (sin cambio) | $errores errores" -ForegroundColor Cyan
        
        if ($errores -gt 0) {
            Write-Host "`nGrupos con error:" -ForegroundColor Red
            $reportData | Where-Object { $_.Estado -eq "Error" } | 
            Format-Table "Nombre Original", "Nombre Nuevo", "Detalle" -AutoSize -Wrap
        }
    }
    else {
        Write-Warning "No se procesaron registros. No se generó reporte."
    }

    # --- 5. DESCONEXIÓN ---
    if (Get-MgContext) {
        Write-Host "`nDesconectando de Microsoft Graph."
        Disconnect-MgGraph | Out-Null
    }
}