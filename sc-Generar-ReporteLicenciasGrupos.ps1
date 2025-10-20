<#
.SYNOPSIS
    Genera un informe de las licencias asignadas a grupos (Group-Based Licensing) 
    y los servicios deshabilitados en cada una.

.DESCRIPTION
    Este script se conecta a Microsoft Graph utilizando un App Registration y un certificado,
    cargando los parámetros desde el archivo 'config.json'.
    
    El script audita todos los grupos que tengan asignación de licencias
    basada en grupo (GBL) utilizando un filtro OData para mayor eficiencia.
    
    Para cada grupo, muestra:
    - El nombre del producto (SKU) asignado.
    - La lista de planes de servicio que están explícitamente deshabilitados.
    - La cantidad de miembros en el grupo.
    
    El resultado se muestra en la consola y se exporta a un archivo CSV (delimitado por comas).

.NOTES
    Autor: Juan Sánchez
    Fecha: 2025-10-20
    Versión: 3.2 (Se añade el recuento de miembros por grupo)
    
    Requiere: 
        - Módulo de PowerShell: Microsoft.Graph.
        - Un archivo 'config.json' en la misma carpeta.
        
    Permisos de API de Aplicación (Microsoft Graph) necesarios:
        - Group.Read.All
        - Directory.Read.All
        - GroupMember.Read.All (Para contar los miembros del grupo)
#>

# --- INICIO: FUNCIÓN DE REINTENTOS MEJORADA (MANEJO DE THROTTLING) ---

function Invoke-MgGraphCommandWithRetry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,
        [int]$MaxRetries = 5,
        [int]$BaseDelaySeconds = 15 
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return . $Command
        }
        catch {
            # Comprueba si es un error transitorio (429, 503, 504)
            $isTransientError = $_.Exception.Message -match "429" -or 
                                $_.Exception.Message -match "503" -or 
                                $_.Exception.Message -match "504" -or 
                                $_.Exception.GetType().Name -match "ServiceException"

            if ($isTransientError -and $attempt -lt $MaxRetries) {
                
                $delay = $BaseDelaySeconds * $attempt # Backoff exponencial
                
                # Intentar leer el encabezado 'Retry-After' de la API silenciosamente
                try {
                    $response = $_.Exception.Response
                    if ($response -and $response.Headers.Contains("Retry-After")) {
                        $retryAfterValue = $response.Headers.GetValues("Retry-After")[0]
                        if ([int]::TryParse($retryAfterValue, [ref]$delay)) {
                            # Se usará el delay sugerido por la API
                        }
                    }
                } catch {
                    # No hacer nada si no se puede leer el header
                }
                
                # Pausar y reintentar sin mostrar advertencias
                Start-Sleep -Seconds $delay
            }
            else {
                # Si no es un error transitorio o se superaron los reintentos, mostrar el error final.
                Write-Error "Error no recuperable o reintentos máximos alcanzados."
                throw $_
            }
        }
    }
}

# --- FIN: FUNCIÓN DE REINTENTOS ---


# --- INICIO: BLOQUE DE CONEXIÓN Y CONFIGURACIÓN ---

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Host "Instalando módulo 'Microsoft.Graph'..." -ForegroundColor Yellow
    try {
        Install-Module Microsoft.Graph -Scope CurrentUser -Repository PSgallery -Force -AllowClobber
    } catch {
        Write-Error "No se pudo instalar el módulo 'Microsoft.Graph'. Por favor, instálelo manualmente."
        return
    }
}

$configFilePath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
if (-not (Test-Path $configFilePath)) {
    Write-Error "Archivo de configuración '$configFilePath' no encontrado."
    return
}
try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    $tenantId = $config.tenantId
    $clientId = $config.clientId 
    $certThumbprint = $config.certThumbprint
} catch {
    Write-Error "Error al leer 'config.json'. Verifique su formato y que contenga tenantId, clientId y certThumbprint."
    return
}

try {
    Write-Host "Conectando a Microsoft Graph con certificado..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $tenantId -AppId $clientId -CertificateThumbprint $certThumbprint
    Write-Host "Conexión exitosa." -ForegroundColor Green
} catch {
    Write-Error "Falló la conexión a Microsoft Graph. Verifique los detalles en config.json, el certificado y los permisos."
    return
}

# --- FIN: BLOQUE DE CONEXIÓN ---

# --- INICIO: LÓGICA PRINCIPAL ---
$reportData = [System.Collections.Generic.List[object]]::new()

try {
    # 1. Obtener un catálogo de todos los SKUs (CON REINTENTOS)
    Write-Host "Obteniendo catálogo de SKUs y planes de servicio del tenant..."
    $allSkus = Invoke-MgGraphCommandWithRetry -Command { Get-MgSubscribedSku -All }
    
    $skuIdToName = @{}
    $planIdToName = @{}

    foreach ($sku in $allSkus) {
        $skuIdToName[$sku.SkuId] = $sku.SkuPartNumber
        foreach ($plan in $sku.ServicePlans) {
            if (-not $planIdToName.ContainsKey($plan.ServicePlanId)) {
                $planIdToName.Add($plan.ServicePlanId, $plan.ServicePlanName)
            }
        }
    }
    Write-Host "Catálogo de $($skuIdToName.Count) SKUs y $($planIdToName.Count) planes de servicio cargado." -ForegroundColor Green

    # 2. Obtener grupos con licencias (CON REINTENTOS)
    Write-Host "Buscando grupos con licencias asignadas (método OData - Rápido)..."
    $groupsWithLicenses = Invoke-MgGraphCommandWithRetry -Command { 
        Get-MgGroup -Filter "assignedLicenses/any()" -All -Property "id,displayName,assignedLicenses" 
    }

    if (-not $groupsWithLicenses) {
        Write-Warning "No se encontraron grupos con licencias asignadas en el tenant."
    } else {

        Write-Host "Se encontraron $($groupsWithLicenses.Count) grupos con licencias. Analizando..."

        # 3. Procesar cada grupo
        foreach ($group in $groupsWithLicenses) {
            
            # --- OBTENER RECUENTO DE MIEMBROS ---
            $memberCount = "Error" # Valor por defecto
            try {
                $null = Invoke-MgGraphCommandWithRetry -Command { 
                    Get-MgGroupMember -GroupId $group.Id -Top 1 -CountVariable 'groupMemberCount' -ConsistencyLevel eventual 
                }
                $memberCount = $groupMemberCount
            }
            catch {
                Write-Warning "No se pudo obtener el recuento de miembros para el grupo $($group.DisplayName)."
            }
            
            Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
            Write-Host "Grupo: $($group.DisplayName) (ID: $($group.Id)) - Miembros: $memberCount" -ForegroundColor White
            
            $licenseDetails = @()

            foreach ($license in $group.AssignedLicenses) {
                
                $skuName = $skuIdToName.($license.SkuId)
                if ([string]::IsNullOrEmpty($skuName)) { $skuName = "Desconocido (ID: $($license.SkuId))" }

                $disabledPlanNames = @()
                if ($license.DisabledPlans) {
                    foreach ($planId in $license.DisabledPlans) {
                        $planName = $planIdToName.($planId)
                        if ([string]::IsNullOrEmpty($planName)) { $planName = "Plan Desconocido (ID: $planId)" }
                        $disabledPlanNames += $planName
                    }
                }
                
                $disabledServicesString = ($disabledPlanNames | Sort) -join "; "
                if ([string]::IsNullOrEmpty($disabledServicesString)) {
                    $disabledServicesString = "(Ninguno deshabilitado)"
                }

                $licenseDetails += [PSCustomObject]@{
                    LicenciaAsignada = $skuName
                    ServiciosDeshabilitados = $disabledServicesString
                }
            }
            
            $licenseDetails | Format-Table -AutoSize -Wrap
            
            foreach ($detail in $licenseDetails) {
                $reportData.Add([PSCustomObject]@{
                    NombreGrupo        = $group.DisplayName
                    GrupoID            = $group.Id
                    CantidadMiembros   = $memberCount
                    LicenciaAsignada   = $detail.LicenciaAsignada
                    ServiciosDeshabilitados = $detail.ServiciosDeshabilitados
                })
            }
        }
    }
    
    # 4. Exportar el reporte a CSV
    if ($reportData.Count -gt 0) {
        $timestampCsv = Get-Date -Format "yyyy-MM-dd-HHmm"
        $reportFileName = "Reporte_Licencias_Grupos_$timestampCsv.csv"
        $reportFilePath = Join-Path -Path $PSScriptRoot -ChildPath $reportFileName
        
        $reportData | Export-Csv -Path $reportFilePath -NoTypeInformation -Encoding UTF8 -Delimiter ","
        
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "Proceso completado. Reporte CSV (con comas) generado en:" -ForegroundColor Green
        Write-Host $reportFilePath -ForegroundColor White
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
    } else {
        Write-Warning "No se generó reporte CSV ya que no se encontraron grupos con licencias."
    }

}
catch {
    Write-Error "Ocurrió un error crítico durante la ejecución: $($_.Exception.Message)"
}
finally {
    # 5. Desconectar la sesión de Graph
    if (Get-MgContext) {
        Write-Host "`nDesconectando de la sesión de Microsoft Graph."
        Disconnect-MgGraph
    }
}

