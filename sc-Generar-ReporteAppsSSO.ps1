<#
.SYNOPSIS
    Genera un informe de auditoría unificado de las Aplicaciones Empresariales de tipo 'Application' y 'Legacy'.

.DESCRIPTION
    Este script se conecta a Microsoft Graph utilizando autenticación desatendida para obtener un listado combinado
    de todos los Service Principals cuyo tipo es 'Application' o 'Legacy'.

    El resultado final es un archivo CSV que incluye una columna 'App_Type' para diferenciar los tipos. La detección de SSO
    y el conteo de asignaciones se realiza únicamente para las aplicaciones modernas.

.REQUIREMENTS
    - Módulo de PowerShell: Microsoft.Graph.
    - Un archivo 'config.json' en la misma carpeta con tenantId, clientId y certThumbprint.
    - Permisos de API de Microsoft Graph requeridos para el Service Principal:
        - Application.Read.All
        - Directory.Read.All
        - DelegatedPermissionGrant.Read.All

.NOTES
    Autor: Juan Sanchez
    Fecha: 2025-09-16
    Versión: 7.0 - Informe unificado para Apps 'Application' y 'Legacy'.
#>

# --- BLOQUE DE CONEXIÓN Y CONFIGURACIÓN ---
$configFilePath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
if (-not (Test-Path $configFilePath)) {
    Write-Error "Archivo de configuración 'config.json' no encontrado en: $configFilePath"
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    $tenantId = $config.tenantId
    $clientId = $config.clientId
    $certThumbprint = $config.certThumbprint
}
catch {
    Write-Error "No se pudo leer o procesar 'config.json'. Verifique el formato del archivo."
    return
}

try {
    Write-Host "Conectando a Microsoft Graph con certificado..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $tenantId -AppId $clientId -CertificateThumbprint $certThumbprint
    Write-Host "Conexión exitosa." -ForegroundColor Green
}
catch {
    Write-Error "Falló la conexión a Microsoft Graph. Verifique los detalles en config.json y el certificado."
    return
}

# --- LÓGICA PRINCIPAL ---
$reportData = [System.Collections.Generic.List[object]]::new()

try {
    # Obtener todas las aplicaciones de tipo 'Application' y 'Legacy' para el reporte
    Write-Host "Obteniendo aplicaciones 'Application' y 'Legacy' del tenant... (esto puede tardar varios minutos)"
    $properties = "id,displayName,appId,accountEnabled,appRoleAssignmentRequired,preferredSingleSignOnMode,servicePrincipalType"
    
    # --- Consulta de producción unificada ---
    $enterpriseApps = Get-MgServicePrincipal -Filter "servicePrincipalType in ('Application', 'Legacy')" -All -Property $properties

    $totalApps = $enterpriseApps.Count
    Write-Host "Se encontraron $totalApps aplicaciones para analizar."

    $counter = 0
    foreach ($app in $enterpriseApps) {
        $counter++
        Write-Progress -Activity "Analizando Aplicaciones Empresariales" -Status "($counter/$totalApps) - $($app.DisplayName)" -PercentComplete (($counter / $totalApps) * 100)

        # Inicializar variables
        $ssoType = "N/A"
        $userCount = "N/A"
        $groupCount = "N/A"

        # La lógica de SSO y asignaciones solo aplica a Apps de tipo 'Application'
        if ($app.ServicePrincipalType -eq 'Application') {
            $assignedUsersAndGroups = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $app.Id -All
            $userCount = ($assignedUsersAndGroups | Where-Object { $_.PrincipalType -eq 'User' }).Count
            $groupCount = ($assignedUsersAndGraphs | Where-Object { $_.PrincipalType -eq 'Group' }).Count

            $ssoType = "Otro"
            
            if ($app.PreferredSingleSignOnMode -eq "saml") {
                $ssoType = "SAML"
            }
            elseif ([string]::IsNullOrEmpty($app.PreferredSingleSignOnMode)) {
                try {
                    $oAuthGrants = Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $app.Id -ErrorAction SilentlyContinue
                    
                    $isOidc = $false
                    if ($oAuthGrants) {
                        foreach ($grant in $oAuthGrants) {
                            if ($grant.Scope -match "openid" -or $grant.Scope -match "profile" -or $grant.Scope -match "email") {
                                $isOidc = $true
                                break
                            }
                        }
                    }

                    if ($isOidc) {
                        $ssoType = "OIDC"
                    }
                } catch {}
            }
        }
        
        $reportRecord = [PSCustomObject]@{
            "ApplicationName"         = $app.DisplayName
            "Application (Client) ID" = $app.AppId
            "App_Type"                = $app.ServicePrincipalType
            "Status"                  = if ($app.AccountEnabled) { "Enabled" } else { "Disabled" }
            "AssignmentRequired"      = if ($app.ServicePrincipalType -eq 'Application') { if ($app.AppRoleAssignmentRequired) { "Yes" } else { "No (Open)" } } else { "N/A" }
            "SSO_Type"                = $ssoType
            "AssignedUsers"           = $userCount
            "AssignedGroups"          = $groupCount
        }
        $reportData.Add($reportRecord)
    }
}
catch {
    Write-Error "Ocurrió un error crítico durante el procesamiento: $($_.Exception.Message)"
}
finally {
    if ($reportData.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
        $reportFileName = "Report_All_EnterpriseApps_$timestamp.csv"
        $reportFilePath = Join-Path -Path $PSScriptRoot -ChildPath $reportFileName
        
        $reportData | Export-Csv -Path $reportFilePath -NoTypeInformation -Encoding UTF8 -Delimiter ";"
        
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "Proceso completado. Reporte generado en:" -ForegroundColor Green
        Write-Host $reportFilePath -ForegroundColor White
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
    } else {
        Write-Warning "No se procesaron aplicaciones para generar un reporte."
    }

    if (Get-MgContext) {
        Write-Host "`nDesconectando de la sesión de Microsoft Graph."
        Disconnect-MgGraph
    }
}