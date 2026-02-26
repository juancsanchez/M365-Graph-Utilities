<#
.SYNOPSIS
    Renombra políticas de configuración de dispositivos en Intune masivamente basándose en un archivo CSV.

.DESCRIPTION
    Este script automatiza la actualización masiva de nombres de múltiples tipos de 
    políticas en Microsoft Intune (Device Configuration, Settings Catalog, 
    Compliance, Endpoint Security, Scripts, Update Rings y Administrative Templates).
    
    Utiliza autenticación desatendida mediante certificado, leyendo los parámetros 
    desde el archivo 'config.json'. Al finalizar, genera un reporte en formato CSV 
    indicando el estado de actualización para cada política procesada.

.PARAMETER CsvFilePath
    Ruta al archivo CSV de entrada.
    IMPORTANTE: El archivo debe contener exactamente las columnas:
    - Nombre actual
    - Nombre sugerido

.REQUIREMENTS
    - Módulo de PowerShell: Microsoft.Graph.DeviceManagement
    - Archivo 'config.json' en la misma carpeta con tenantId, clientId y certThumbprint.
    - Permisos de API (Application): DeviceManagementConfiguration.ReadWrite.All

.EXAMPLE
    .\sc-Renombrar-PoliticasIntune-Masivo.ps1 -CsvFilePath ".\Politicas_Intune_Estandarizadas_ES.csv"

.NOTES
    Autor: Juan Sánchez
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Ruta al archivo CSV con las columnas 'Nombre actual' y 'Nombre sugerido'.")]
    [string]$CsvFilePath
)

# --- 1. VERIFICACIÓN DE MÓDULOS ---
$requiredModules = @("Microsoft.Graph.DeviceManagement")
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
$configFilePath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
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

Write-Host "Construyendo catálogo local de políticas de Intune (esto evitará errores de búsqueda)..." -ForegroundColor Cyan
$policyCatalog = [System.Collections.Generic.List[object]]::new()

# Definición de los endpoints a consultar en Graph API.
# NOTA: Se utiliza la versión 'beta' para ciertos endpoints porque algunas políticas
# (Administrative Templates, Settings Catalog, Endpoint Security o perfiles específicos
# como Wi-Fi y Windows Health Monitoring) no existen o no se retornan completamente en v1.0.
$endpointsToScan = @(
    @{ Uri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations"; Type = "DeviceConfiguration"; NameProp = "displayName" },
    @{ Uri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"; Type = "ConfigurationPolicy"; NameProp = "name" },
    @{ Uri = "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies"; Type = "DeviceCompliancePolicy"; NameProp = "displayName" },
    @{ Uri = "https://graph.microsoft.com/beta/deviceManagement/intents"; Type = "Intent"; NameProp = "displayName" },
    @{ Uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsUpdateForBusinessConfigurations"; Type = "WindowsUpdateRing"; NameProp = "displayName" },
    @{ Uri = "https://graph.microsoft.com/v1.0/deviceManagement/deviceManagementScripts"; Type = "DeviceManagementScript"; NameProp = "displayName" },
    @{ Uri = "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations"; Type = "GroupPolicyConfiguration"; NameProp = "displayName" }
)

foreach ($ep in $endpointsToScan) {
    $currentUri = $ep.Uri
    while ($currentUri) {
        try {
            $response = Invoke-MgGraphRequest -Method GET -Uri $currentUri -ErrorAction Stop
            if ($response -and $response.value) {
                foreach ($item in $response.value) {
                    $itemName = $item.($ep.NameProp)
                    if ($itemName) {
                        $policyCatalog.Add([PSCustomObject]@{
                                Id        = $item.id
                                Name      = $itemName
                                Type      = $ep.Type
                                ODataType = $item."@odata.type"
                                NameProp  = $ep.NameProp
                            })
                    }
                }
                $currentUri = $response."@odata.nextLink" # Maneja la paginación si hay muchas políticas
            }
            else {
                $currentUri = $null
            }
        }
        catch {
            $currentUri = $null # Si falla un endpoint (ej. sin licencias o no usado), ignorar y seguir
        }
    }
}
Write-Host "Catálogo construido: $($policyCatalog.Count) políticas encontradas en total." -ForegroundColor Green

try {
    # Validar existencia del archivo CSV
    if (-not (Test-Path $CsvFilePath)) { throw "Archivo CSV no encontrado en la ruta: $CsvFilePath" }

    Write-Host "Leyendo archivo CSV..."
    $policiesToUpdate = Import-Csv -Path $CsvFilePath
    $totalRows = $policiesToUpdate.Count
    $counter = 0

    if ($totalRows -eq 0) {
        Write-Warning "El archivo CSV está vacío."
        return
    }

    Write-Host "Procesando $totalRows políticas de Intune..." -ForegroundColor Cyan

    foreach ($row in $policiesToUpdate) {
        $counter++
        
        $currentName = $row."Nombre actual"
        $newName = $row."Nombre sugerido"
        
        $status = "Exitoso"
        $message = "Política actualizada correctamente."
        $policyId = $null

        Write-Progress -Activity "Renombrando Políticas en Intune" -Status "($counter/$totalRows) - Buscando: $currentName" -PercentComplete (($counter / $totalRows) * 100)

        try {
            if ([string]::IsNullOrWhiteSpace($currentName) -or [string]::IsNullOrWhiteSpace($newName)) {
                throw "Faltan datos en la fila. 'Nombre actual' o 'Nombre sugerido' están vacíos."
            }

            # Búsqueda local en el catálogo (Inmune a problemas de codificación de URLs de Graph)
            $currentNameClean = $currentName.Trim()
            $foundPolicies = $policyCatalog | Where-Object { $_.Name.Trim() -eq $currentNameClean }

            if ($foundPolicies.Count -eq 0) {
                throw "No se encontró la política: '$currentNameClean' en todo el catálogo de Intune."
            }
            
            $foundPolicy = $foundPolicies[0]
            $policyId = $foundPolicy.Id
            $policyType = $foundPolicy.Type
            $policyODataType = $foundPolicy.ODataType
            $nameProp = $foundPolicy.NameProp

            Write-Host "  Actualizando: '$currentName' -> '$newName' (Tipo: $policyType)..." -ForegroundColor Yellow

            # Aplicar el cambio de nombre mediante Invoke-MgGraphRequest
            $uri = ""
            switch ($policyType) {
                "DeviceConfiguration" { $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$policyId" }
                "ConfigurationPolicy" { $uri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$policyId" }
                "DeviceCompliancePolicy" { $uri = "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$policyId" }
                "Intent" { $uri = "https://graph.microsoft.com/beta/deviceManagement/intents/$policyId" }
                "WindowsUpdateRing" { $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsUpdateForBusinessConfigurations/$policyId" }
                "DeviceManagementScript" { $uri = "https://graph.microsoft.com/v1.0/deviceManagement/deviceManagementScripts/$policyId" }
                "GroupPolicyConfiguration" { $uri = "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations/$policyId" }
            }

            $body = @{}
            $body[$nameProp] = $newName

            # Agregar @odata.type si existe (Requerido estrictamente por Graph API para actualizar objetos polimórficos)
            if (-not [string]::IsNullOrEmpty($policyODataType)) {
                $body["@odata.type"] = $policyODataType
            }

            Invoke-MgGraphRequest -Method PATCH -Uri $uri -Body ($body | ConvertTo-Json -Depth 2 -Compress) -ContentType "application/json" -ErrorAction Stop
            
            Write-Host "  [+] Éxito." -ForegroundColor Green
        }
        catch {
            $status = "Error"
            $message = $_.Exception.Message
            Write-Error "  [X] Fallo al procesar '$currentName': $message"
        }

        # Guardar el resultado para el reporte final
        $reportRecord = [PSCustomObject]@{
            "Nombre Original" = $currentName
            "Nombre Nuevo"    = $newName
            "ID Política"     = if ($policyId) { $policyId } else { "N/A" }
            "Estado"          = $status
            "Detalle"         = $message
        }
        $reportData.Add($reportRecord)
    }

    Write-Progress -Activity "Renombrando Políticas en Intune" -Completed

    # --- 4. EXPORTACIÓN DEL REPORTE ---
    if ($reportData.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
        $outputFile = Join-Path -Path $PSScriptRoot -ChildPath "Reporte_Renombrado_Intune_$timestamp.csv"
        
        $reportData | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
        
        Write-Host "`n--------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "Proceso finalizado. Reporte generado en:" -ForegroundColor Green
        Write-Host "$outputFile" -ForegroundColor White
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
    }
}
catch {
    Write-Error "Ocurrió un error general en la ejecución: $($_.Exception.Message)"
}
finally {
    # --- 5. DESCONEXIÓN ---
    if (Get-MgContext) {
        Write-Host "`nDesconectando de Microsoft Graph..."
        Disconnect-MgGraph | Out-Null
    }
}