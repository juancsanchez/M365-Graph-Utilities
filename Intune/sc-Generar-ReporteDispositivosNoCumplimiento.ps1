<#
.SYNOPSIS
    Genera un reporte de dispositivos no conformes en Intune con sus razones de no cumplimiento.

.DESCRIPTION
    Este script extrae todos los dispositivos registrados en Microsoft Intune cuyo estado
    de cumplimiento (complianceState) NO sea 'compliant'. Para cada dispositivo, consulta
    los estados de cumplimiento por política y por configuración de ajuste, construyendo
    un campo detallado con el formato "NombrePolítica/MotivoDeIncumplimiento".

    Al finalizar, genera dos salidas:
    - Un archivo CSV (para Excel / Power BI)
    - Un archivo TXT con el formato visual legible solicitado (por dispositivo)

.REQUIREMENTS
    - Módulo de PowerShell: Microsoft.Graph.DeviceManagement, Microsoft.Graph.DeviceManagement.Actions
    - Archivo 'config.json' en la carpeta raíz del repositorio con tenantId, clientId y certThumbprint.
    - Permiso de API (Application): DeviceManagementManagedDevices.Read.All
      (Opcional pero recomendado para ver políticas):  DeviceManagementConfiguration.Read.All

.EXAMPLE
    .\sc-Generar-ReporteDispositivosNoCumplimiento.ps1

.NOTES
    Autor: Juan Sánchez
#>

[CmdletBinding()]
param ()

# ─────────────────────────────────────────────
# 1. MÓDULOS
# ─────────────────────────────────────────────
$requiredModules = @("Microsoft.Graph.DeviceManagement")
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Instalando módulo '$module'..." -ForegroundColor Yellow
        try {
            Install-Module $module -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        }
        catch {
            Write-Error "No se pudo instalar el módulo '$module'. Instálelo manualmente."
            return
        }
    }
}

# ─────────────────────────────────────────────
# 2. CONEXIÓN
# ─────────────────────────────────────────────
$configFilePath = Join-Path -Path (Split-Path $PSScriptRoot -Parent) -ChildPath "config.json"
if (-not (Test-Path $configFilePath)) {
    Write-Error "No se encontró el archivo 'config.json' en: $configFilePath"
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    Write-Host "Conectando a Microsoft Graph con certificado..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $config.tenantId -AppId $config.clientId -CertificateThumbprint $config.certThumbprint -ErrorAction Stop
    Write-Host "Conexión establecida exitosamente.`n" -ForegroundColor Green
}
catch {
    Write-Error "Error crítico al conectar a Microsoft Graph: $($_.Exception.Message)"
    return
}

# ─────────────────────────────────────────────
# 3. OBTENER DISPOSITIVOS NO CONFORMES
#    Filtro OData: complianceState eq 'noncompliant'
#    Nota: el operador 'ne' no es compatible con la
#    Graph API para complianceState y es ignorado,
#    devolviendo todos los dispositivos.
#    Se usa 'eq noncompliant' para obtener únicamente
#    los dispositivos marcados como no conformes.
# ─────────────────────────────────────────────
Write-Host "Obteniendo dispositivos no conformes desde Intune..." -ForegroundColor Cyan

$nonCompliantDevices = [System.Collections.Generic.List[object]]::new()
$devicesUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices" +
"?`$filter=complianceState eq 'noncompliant'" +
"&`$select=id,deviceName,userPrincipalName,operatingSystem,complianceState,osVersion,lastSyncDateTime"

while ($devicesUri) {
    try {
        $response = Invoke-MgGraphRequest -Method GET -Uri $devicesUri -ErrorAction Stop
        foreach ($device in $response.value) {
            $nonCompliantDevices.Add($device)
        }
        $devicesUri = $response."@odata.nextLink"
    }
    catch {
        Write-Error "Error al obtener dispositivos: $($_.Exception.Message)"
        $devicesUri = $null
    }
}

Write-Host "Dispositivos no conformes encontrados: $($nonCompliantDevices.Count)`n" -ForegroundColor Yellow

if ($nonCompliantDevices.Count -eq 0) {
    Write-Host "No se encontraron dispositivos fuera de cumplimiento. Saliendo." -ForegroundColor Green
    Disconnect-MgGraph | Out-Null
    return
}

# ─────────────────────────────────────────────
# 4. OBTENER RAZONES DE NO CUMPLIMIENTO
#    Por cada dispositivo consultamos:
#      /managedDevices/{id}/deviceCompliancePolicyStates
#    y por cada política con estado != compliant,
#    obtenemos los ajustes específicos que fallaron:
#      /deviceCompliancePolicyStates/{policyId}/settingStates
# ─────────────────────────────────────────────
$reportData = [System.Collections.Generic.List[object]]::new()
$reportLines = [System.Collections.Generic.List[string]]::new()  # Formato visual TXT
$totalDevices = $nonCompliantDevices.Count
$counter = 0

foreach ($device in $nonCompliantDevices) {
    $counter++
    Write-Progress -Activity "Analizando dispositivos no conformes" `
        -Status "($counter/$totalDevices) - $($device.deviceName)" `
        -PercentComplete (($counter / $totalDevices) * 100)

    $deviceId = $device.id
    $deviceName = $device.deviceName
    $userUPN = if ($device.userPrincipalName) { $device.userPrincipalName } else { "Sin usuario asignado" }
    $os = $device.operatingSystem
    $compState = $device.complianceState

    # --- 4a. Obtener estados de política de cumplimiento del dispositivo ---
    $policyStatesUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$deviceId/deviceCompliancePolicyStates"
    $reasons = [System.Collections.Generic.List[string]]::new()

    try {
        $policyStatesResponse = Invoke-MgGraphRequest -Method GET -Uri $policyStatesUri -ErrorAction Stop
        $policyStates = $policyStatesResponse.value

        foreach ($policyState in $policyStates) {
            # Sólo procesamos políticas que tienen problemas
            if ($policyState.state -ne "compliant") {
                $policyDisplayName = $policyState.displayName
                $policyId = $policyState.id  # Formato: "{policyId}:{userId}" en v1.0

                # --- 4b. Obtener ajustes (settings) que fallaron dentro de esta política ---
                $settingStatesUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$deviceId/deviceCompliancePolicyStates/$policyId/settingStates"
                
                try {
                    $settingStatesResponse = Invoke-MgGraphRequest -Method GET -Uri $settingStatesUri -ErrorAction Stop
                    $settingStates = $settingStatesResponse.value

                    $foundSettings = $false
                    foreach ($setting in $settingStates) {
                        if ($setting.state -ne "compliant" -and $setting.state -ne "notApplicable") {
                            # settingName o setting pueden contener la clase de configuración completa;
                            # tomamos sólo la última parte después del último punto para legibilidad
                            $rawSettingName = if (-not [string]::IsNullOrEmpty($setting.settingName)) { $setting.settingName } elseif (-not [string]::IsNullOrEmpty($setting.setting)) { $setting.setting } else { "Unknown" }
                            $shortSetting = if ($rawSettingName -match '\.([^.]+)$') { $Matches[1] } else { $rawSettingName }
                            
                            $reasons.Add("$policyDisplayName/$shortSetting")
                            $foundSettings = $true
                        }
                    }

                    # Si la política falla pero no hay ajustes individuales disponibles,
                    # registramos la política con el estado general
                    if (-not $foundSettings) {
                        $reasons.Add("$policyDisplayName/[$($policyState.state)]")
                    }
                }
                catch {
                    # settingStates no disponible para este tipo de política; registrar nivel de política
                    $reasons.Add("$policyDisplayName/[$($policyState.state)]")
                }
            }
        }
    }
    catch {
        $reasons.Add("[No se pudieron obtener políticas: $($_.Exception.Message)]")
    }

    # Si no se encontraron razones detalladas, indicar el estado general
    if ($reasons.Count -eq 0) {
        $reasons.Add("[$compState - sin detalles de política disponibles]")
    }

    # Eliminar duplicados para una salida más limpia
    $uniqueReasons = $reasons | Select-Object -Unique
    $reasonsJoined = $uniqueReasons -join " | "

    # --- CSV record ---
    $reportData.Add([PSCustomObject]@{
            "DeviceID"                   = $deviceId
            "Usuario"                    = $userUPN
            "Nombre Dispositivo"         = $deviceName
            "SO"                         = $os
            "Estado de Cumplimiento"     = $compState
            "Razones de no cumplimiento" = $reasonsJoined
        })

    # --- Bloque visual para el TXT ---
    $block = @"
──────────────────────────────────────────────────────────────
DeviceID        : $deviceId
Usuario         : $userUPN
Nombre Dispotivo: $deviceName
SO              : $os
Estado          : $compState
Razones de no cumplimiento:
$(($uniqueReasons | ForEach-Object { "  $_" }) -join "`n")
"@
    $reportLines.Add($block)
}

Write-Progress -Activity "Analizando dispositivos no conformes" -Completed

# ─────────────────────────────────────────────
# 5. EXPORTAR REPORTES
# ─────────────────────────────────────────────
$timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
$csvOutput = Join-Path -Path $PSScriptRoot -ChildPath "Reporte_NoCumplimiento_Intune_$timestamp.csv"
$txtOutput = Join-Path -Path $PSScriptRoot -ChildPath "Reporte_NoCumplimiento_Intune_$timestamp.txt"

# CSV
$reportData | Export-Csv -Path $csvOutput -NoTypeInformation -Encoding UTF8

# TXT visual
$header = @"
╔══════════════════════════════════════════════════════════════╗
║   REPORTE DE DISPOSITIVOS NO CONFORMES - MICROSOFT INTUNE   ║
║   Generado: $(Get-Date -Format "yyyy-MM-dd HH:mm")                              ║
║   Total de dispositivos: $($reportData.Count)                                 ║
╚══════════════════════════════════════════════════════════════╝

"@
$txtContent = $header + ($reportLines -join "`n`n")
$txtContent | Out-File -FilePath $txtOutput -Encoding UTF8

Write-Host "`n────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "Proceso finalizado. Reportes generados:" -ForegroundColor Green
Write-Host "  CSV  → $csvOutput" -ForegroundColor White
Write-Host "  TXT  → $txtOutput" -ForegroundColor White
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor Cyan

# ─────────────────────────────────────────────
# 6. DESCONEXIÓN
# ─────────────────────────────────────────────
if (Get-MgContext) {
    Write-Host "`nDesconectando de Microsoft Graph..."
    Disconnect-MgGraph | Out-Null
}