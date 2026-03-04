<#
.SYNOPSIS
    Genera un informe unificado de Aplicaciones Empresariales ('Application' y 'Legacy') en CSV.
    Incluye detalles de SSO (SAML/OIDC), URLs y asignaciones, con optimizaciones de rendimiento y modo de prueba.

.DESCRIPTION
    Este script utiliza Microsoft Graph (autenticación desatendida) para listar Service Principals con type 'Application' o 'Legacy'.
    Características principales:
    - Identificación de tipo de SSO (SAML, OIDC, u Otro).
    - Extracción de Identifiers y Reply URLs.
    - Conteo de usuarios y grupos asignados (solo para Apps modernas).
    - Modo de Prueba: Permite procesar un número limitado de apps para validar el script rápidamente.
    - Procesamiento en Paralelo: Utiliza 'ForEach-Object -Parallel' para maximizar la velocidad en tenants grandes.

.REQUIREMENTS
    - Módulo: Microsoft.Graph (Submódulos: Applications, Identity.Directory, Users.Actions).
    - Archivo 'config.json' con credenciales (Client Credentials + Certificado).
    - Permisos mínimos: Application.Read.All, Directory.Read.All.

.NOTES
    Autor: Juan Sanchez
    Fecha: 2026-02-11
    Versión: 7.1 - Optimización masiva (Parallel), Modo de Prueba (-Top) y detalles extendidos (URLs).
#>

# --- BLOQUE DE CONEXIÓN Y CONFIGURACIÓN ---
$configFilePath = Join-Path -Path (Split-Path $PSScriptRoot -Parent) -ChildPath "config.json"
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
    # --- MODO DE PRUEBA: Permite limitar la ejecución para validaciones rápidas ---
    $testMode = Read-Host "¿Desea ejecutar una prueba? (S/N)"
    $maxApps = 0
    if ($testMode -eq 'S' -or $testMode -eq 's' -or $testMode -eq 'Si' -or $testMode -eq 'si' -or $testMode -eq 'SI' -or $testMode -eq 'sI') {
        $maxApps = Read-Host "¿Cuántas aplicaciones desea procesar?"
        Write-Host "Modo de prueba activado. Se procesarán las primeras $maxApps aplicaciones." -ForegroundColor Yellow
    }

    # Obtener todas las aplicaciones de tipo 'Application' y 'Legacy' para el reporte
    Write-Host "Obteniendo aplicaciones 'Application' y 'Legacy' del tenant... (esto puede tardar varios minutos)"
    $properties = "id,displayName,appId,accountEnabled,appRoleAssignmentRequired,preferredSingleSignOnMode,servicePrincipalType,identifierUris,replyUrls"
    
    # --- Obtención de Apps (Optimizada con -Top para pruebas) ---
    if ($testMode -eq 'S' -or $testMode -eq 's' -or $testMode -eq 'Si' -or $testMode -eq 'si' -or $testMode -eq 'SI' -or $testMode -eq 'sI') {
        Write-Host "Modo Prueba: Obteniendo solo las primeras $maxApps aplicaciones..." -ForegroundColor Cyan
        $enterpriseApps = Get-MgServicePrincipal -Filter "servicePrincipalType in ('Application', 'Legacy')" -Top $maxApps -Property $properties
    }
    else {
        Write-Host "Modo Producción: Obteniendo TODAS las aplicaciones..." -ForegroundColor Cyan
        $enterpriseApps = Get-MgServicePrincipal -Filter "servicePrincipalType in ('Application', 'Legacy')" -All -Property $properties
    }

    $totalApps = $enterpriseApps.Count
    Write-Host "Se encontraron $totalApps aplicaciones para analizar."

    Write-Host "Procesando $($enterpriseApps.Count) aplicaciones en paralelo (ThrottleLimit: 20)..." -ForegroundColor Cyan
    
    # --- Procesamiento Paralelo: Acelera la consulta de detalles por app ---
    $reportData = $enterpriseApps | ForEach-Object -Parallel {
        $app = $_
        
        # Inicializar variables
        $ssoType = "N/A"
        $userCount = "N/A"
        $groupCount = "N/A"

        # La lógica de SSO y asignaciones solo aplica a Apps de tipo 'Application'
        if ($app.ServicePrincipalType -eq 'Application') {
            try {
                $assignedUsersAndGroups = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $app.Id -All -ErrorAction SilentlyContinue
                if ($assignedUsersAndGroups) {
                    $userCount = ($assignedUsersAndGroups | Where-Object { $_.PrincipalType -eq 'User' }).Count
                    $groupCount = ($assignedUsersAndGroups | Where-Object { $_.PrincipalType -eq 'Group' }).Count
                }
                else {
                    $userCount = 0
                    $groupCount = 0
                }
            }
            catch {
                $userCount = "Error"
                $groupCount = "Error"
            }

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
                }
                catch {}
            }
        }
        
        # Retornar el objeto para la colección
        [PSCustomObject]@{
            "ApplicationName"         = $app.DisplayName
            "Application (Client) ID" = $app.AppId
            "App_Type"                = $app.ServicePrincipalType
            "Status"                  = if ($app.AccountEnabled) { "Enabled" } else { "Disabled" }
            "AssignmentRequired"      = if ($app.ServicePrincipalType -eq 'Application') { if ($app.AppRoleAssignmentRequired) { "Yes" } else { "No (Open)" } } else { "N/A" }
            "SSO_Type"                = $ssoType
            "AssignedUsers"           = $userCount
            "AssignedGroups"          = $groupCount
            "Identifier (SAML)"       = ($app.IdentifierUris -join ", ")
            "Reply URL"               = ($app.ReplyUrls -join ", ")
        }
    } -ThrottleLimit 20
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
    }
    else {
        Write-Warning "No se procesaron aplicaciones para generar un reporte."
    }

    if (Get-MgContext) {
        Write-Host "`nDesconectando de la sesión de Microsoft Graph."
        Disconnect-MgGraph | Out-Null
    }
}