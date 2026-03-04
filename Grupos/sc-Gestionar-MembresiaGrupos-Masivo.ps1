<#
.SYNOPSIS
    Gestiona masivamente la membresía de usuarios en grupos (agregar o retirar) desde un archivo CSV.

.DESCRIPTION
    Este script se conecta a Microsoft Graph utilizando autenticación desatendida (Certificado).
    Lee un archivo CSV con las columnas 'upn', 'groupName', 'groupId' y 'action'.
    
    Dependiendo de la columna 'action':
    - 'agregar': Añade al usuario al grupo especificado.
    - 'retirar': Elimina al usuario del grupo especificado.

    El script intenta localizar el grupo primero por 'groupId'. Si este está vacío, busca por 'groupName'.
    Genera un reporte final CSV con el resultado de cada operación.

.PARAMETER CsvFilePath
    Ruta al archivo CSV.
    Columnas requeridas: upn, action
    Columnas condicionales: groupId O groupName (al menos una debe tener valor)

.REQUIREMENTS
    - Módulo de PowerShell: Microsoft.Graph.Groups, Microsoft.Graph.Users
    - Archivo 'config.json' en la misma carpeta.
    - Permisos de API (Application): 
        - GroupMember.ReadWrite.All
        - User.Read.All

.NOTES
    Autor: Juan Sánchez
    Fecha: 2025-12-05
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Ruta al archivo CSV de entrada.")]
    [string]$CsvFilePath
)

# --- 1. VERIFICACIÓN DE MÓDULOS ---
$requiredModules = @("Microsoft.Graph.Groups", "Microsoft.Graph.Users")
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Instalando módulo '$module'..." -ForegroundColor Yellow
        try {
            Install-Module $module -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        }
        catch {
            Write-Error "No se pudo instalar el módulo '$module'."
            return
        }
    }
}

# --- 2. CONEXIÓN Y CONFIGURACIÓN ---
$configFilePath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
if (-not (Test-Path $configFilePath)) {
    Write-Error "No se encontró el archivo 'config.json' en: $configFilePath"
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    
    Write-Host "Conectando a Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $config.tenantId -AppId $config.clientId -CertificateThumbprint $config.certThumbprint
    Write-Host "Conexión establecida." -ForegroundColor Green
}
catch {
    Write-Error "Error crítico de conexión: $($_.Exception.Message)"
    return
}

# --- 3. PROCESAMIENTO PRINCIPAL ---
$reportData = [System.Collections.Generic.List[object]]::new()

try {
    if (-not (Test-Path $CsvFilePath)) { throw "Archivo CSV no encontrado: $CsvFilePath" }

    $csvData = Import-Csv -Path $CsvFilePath
    $totalRows = $csvData.Count
    $counter = 0

    Write-Host "Procesando $totalRows solicitudes de membresía..." -ForegroundColor Cyan

    foreach ($row in $csvData) {
        $counter++
        
        # Variables de entrada
        $upn = $row.upn
        $groupIdInput = $row.groupId
        $groupNameInput = $row.groupName
        $action = $row.action
        
        # Variables de reporte
        $status = "Exitoso"
        $message = ""
        $targetGroupName = ""
        
        Write-Progress -Activity "Gestionando Membresías" -Status "($counter/$totalRows) - $action $upn" -PercentComplete (($counter / $totalRows) * 100)

        try {
            # VALIDACIÓN BÁSICA
            if ([string]::IsNullOrWhiteSpace($upn)) { throw "El campo 'upn' está vacío." }
            if ([string]::IsNullOrWhiteSpace($action)) { throw "El campo 'action' está vacío." }
            
            # 1. OBTENER USUARIO
            $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
            if (-not $user) { throw "Usuario con UPN '$upn' no encontrado en Entra ID." }

            # 2. OBTENER GRUPO (Prioridad: ID > Nombre)
            $group = $null
            if (-not [string]::IsNullOrWhiteSpace($groupIdInput)) {
                $group = Get-MgGroup -GroupId $groupIdInput -ErrorAction SilentlyContinue
            }
            elseif (-not [string]::IsNullOrWhiteSpace($groupNameInput)) {
                # Buscamos por DisplayName exacto
                $group = Get-MgGroup -Filter "displayName eq '$groupNameInput'" -ErrorAction SilentlyContinue
            }
            else {
                throw "Debe proporcionar 'groupId' o 'groupName'."
            }

            if (-not $group) { 
                throw "Grupo no encontrado (ID: '$groupIdInput', Nombre: '$groupNameInput')." 
            }
            
            $targetGroupName = $group.DisplayName

            # 3. EJECUTAR ACCIÓN
            switch ($action.ToLower()) {
                "agregar" {
                    try {
                        New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $user.Id -ErrorAction Stop
                        $message = "Usuario agregado correctamente."
                        Write-Host "  [+] $upn -> $targetGroupName" -ForegroundColor Green
                    }
                    catch {
                        # Manejo de error si ya existe
                        if ($_.Exception.Message -match "already exist" -or $_.Exception.Message -match "One or more added object references already exist") {
                            $status = "Advertencia"
                            $message = "El usuario ya es miembro del grupo."
                            Write-Warning "  [!] $upn ya está en $targetGroupName"
                        }
                        else {
                            throw $_
                        }
                    }
                }
                "retirar" {
                    try {
                        # Remove-MgGroupMemberByRef requiere el ID del miembro a remover
                        Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $user.Id -ErrorAction Stop
                        $message = "Usuario retirado correctamente."
                        Write-Host "  [-] $upn retirado de $targetGroupName" -ForegroundColor Yellow
                    }
                    catch {
                        # Manejo de error si no es miembro
                        if ($_.Exception.Message -match "ResourceNotFound" -or $_.Exception.Message -match "does not exist") {
                            $status = "Advertencia"
                            $message = "El usuario no era miembro del grupo, no se pudo retirar."
                            Write-Warning "  [!] $upn no estaba en $targetGroupName"
                        }
                        else {
                            throw $_
                        }
                    }
                }
                default {
                    throw "Acción desconocida '$action'. Use 'agregar' o 'retirar'."
                }
            }
        }
        catch {
            $status = "Error"
            $message = $_.Exception.Message
            Write-Error "  [X] Error con $($upn): $message"
        }

        # Guardar registro
        $reportRecord = [PSCustomObject]@{
            UPN          = $upn
            Grupo_Input  = if ($groupIdInput) { $groupIdInput } else { $groupNameInput }
            Grupo_Nombre = $targetGroupName
            Accion       = $action
            Estado       = $status
            Detalle      = $message
            Fecha        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
        $reportData.Add($reportRecord)
    }

    Write-Progress -Activity "Gestionando Membresías" -Completed

    # --- 4. EXPORTAR REPORTE ---
    if ($reportData.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
        $outputFile = Join-Path -Path $PSScriptRoot -ChildPath "Reporte_Gestion_Membresias_$timestamp.csv"
        
        $reportData | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
        
        Write-Host "`n--------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "Proceso finalizado. Reporte disponible en:" -ForegroundColor Green
        Write-Host "$outputFile" -ForegroundColor White
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
    }
}
catch {
    Write-Error "Error general en el script: $($_.Exception.Message)"
}
finally {
    if (Get-MgContext) { Disconnect-MgGraph | Out-Null }
}