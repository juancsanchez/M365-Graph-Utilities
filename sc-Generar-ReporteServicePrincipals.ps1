<#
.SYNOPSIS
    Genera un informe de auditoría detallado de las Aplicaciones Empresariales de tipo 'Application' en Microsoft Entra ID.

.DESCRIPTION
    Este script se conecta a Microsoft Graph utilizando autenticación desatendida con un certificado. Itera a través de los 
    Service Principals y filtra aquellos de tipo 'Application' para recopilar información clave sobre su configuración, estado y asignaciones.

    El resultado final es un archivo CSV que incluye:
    - Nombre de la aplicación y su App ID.
    - Estado (Habilitado o Deshabilitado).
    - Requisito de asignación de usuario.
    - Tipo de Single Sign-On (SSO) configurado.
    - Un recuento de usuarios y grupos asignados directamente.

.REQUIREMENTS
    - Módulo de PowerShell: Microsoft.Graph.
    - Un archivo 'config.json' en la misma carpeta con tenantId, clientId y certThumbprint.
    - Permisos de API de Microsoft Graph requeridos para el Service Principal:
        - Application.Read.All

.NOTES
    Autor: Juan Sanchez
    Fecha: 2025-09-11
    Versión: 4.1 - Se agregó filtro para obtener solo Service Principals de tipo 'Application'.
#>

# --- START: CONNECTION AND CONFIGURATION BLOCK ---

# Load configuration from JSON file
$configFilePath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
if (-not (Test-Path $configFilePath)) {
    Write-Error "Configuration file 'config.json' not found at: $configFilePath"
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    $tenantId = $config.tenantId
    $clientId = $config.clientId
    $certThumbprint = $config.certThumbprint
}
catch {
    Write-Error "Failed to read or process 'config.json'. Please check the file format."
    return
}

# Connect to Microsoft Graph
try {
    Write-Host "Connecting to Microsoft Graph with certificate..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $tenantId -AppId $clientId -CertificateThumbprint $certThumbprint
    Write-Host "Connection successful." -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to Microsoft Graph. Please check the configuration details in config.json and the certificate."
    return
}

# --- END: CONNECTION BLOCK ---


# --- START: MAIN LOGIC ---

$reportData = [System.Collections.Generic.List[object]]::new()

try {
    # 1. Get all Enterprise Applications (Service Principals) of type 'Application'
    Write-Host "Getting all Enterprise Applications of type 'Application' from the tenant... (this may take a while)"
    $enterpriseApps = Get-MgServicePrincipal -Filter "servicePrincipalType eq 'Application'" -All -Property "id,displayName,appId,accountEnabled,appRoleAssignmentRequired,preferredSingleSignOnMode"
    $totalApps = $enterpriseApps.Count
    Write-Host "Found $totalApps applications. Now analyzing each one..."

    $counter = 0
    # 2. Process each application
    foreach ($app in $enterpriseApps) {
        $counter++
        Write-Progress -Activity "Analyzing Enterprise Applications" -Status "($counter/$totalApps) - $($app.DisplayName)" -PercentComplete (($counter / $totalApps) * 100)

        # 2.1. Count assigned users and groups
        $assignedUsersAndGroups = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $app.Id -All
        $userCount = ($assignedUsersAndGroups | Where-Object { $_.PrincipalType -eq 'User' }).Count
        $groupCount = ($assignedUsersAndGroups | Where-Object { $_.PrincipalType -eq 'Group' }).Count

        # 2.2. Determine SSO type
        $ssoType = $app.PreferredSingleSignOnMode
        if ([string]::IsNullOrEmpty($ssoType)) {
            $ssoType = "Not configured"
        }

        # 2.3. Create the object for the report
        $reportRecord = [PSCustomObject]@{
            "ApplicationName"        = $app.DisplayName
            "Application (Client) ID" = $app.AppId
            "Status"                 = if ($app.AccountEnabled) { "Enabled" } else { "Disabled" }
            "AssignmentRequired"     = if ($app.AppRoleAssignmentRequired) { "Yes" } else { "No (Open)" }
            "SSO_Type"               = $ssoType
            "AssignedUsers"          = $userCount
            "AssignedGroups"         = $groupCount
        }
        $reportData.Add($reportRecord)
    }
}
catch {
    Write-Error "A critical error occurred during processing: $($_.Exception.Message)"
}
finally {
    # 3. Generate the CSV report
    if ($reportData.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
        $reportFileName = "Report_EnterpriseApps_$timestamp.csv"
        $reportFilePath = Join-Path -Path $PSScriptRoot -ChildPath $reportFileName
        
        $reportData | Export-Csv -Path $reportFilePath -NoTypeInformation -Encoding UTF8 -Delimiter ";"
        
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "Process completed. Report generated at:" -ForegroundColor Green
        Write-Host $reportFilePath -ForegroundColor White
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
    } else {
        Write-Warning "No applications were processed to generate a report."
    }

    # 4. Disconnect from Graph
    if (Get-MgContext) {
        Write-Host "`nDisconnecting from Microsoft Graph session."
        Disconnect-MgGraph
    }
}