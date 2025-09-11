<#
.SYNOPSIS
    Generates a detailed audit report of all Enterprise Applications in Microsoft Entra ID.

.DESCRIPTION
    This script connects to Microsoft Graph using unattended authentication with a certificate. It iterates through all 
    Service Principals to gather key information about their configuration, status, and assignments.

    The final output is a CSV file that includes:
    - Application Name and its App ID.
    - Status (Enabled or Disabled).
    - User assignment requirement.
    - Configured Single Sign-On (SSO) type.
    - A count of directly assigned users and groups.

.REQUIREMENTS
    - PowerShell Module: Microsoft.Graph.
    - A 'config.json' file in the same folder with tenantId, clientId, and certThumbprint.
    - Microsoft Graph API Permissions required for the Service Principal:
        - Application.Read.All

.NOTES
    Author: Juan Sanchez
    Date: 2025-09-11
    Version: 4.0
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
    # 1. Get all Enterprise Applications (Service Principals)
    Write-Host "Getting all Enterprise Applications from the tenant... (this may take a while)"
    $enterpriseApps = Get-MgServicePrincipal -All -Property "id,displayName,appId,accountEnabled,appRoleAssignmentRequired,preferredSingleSignOnMode"
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