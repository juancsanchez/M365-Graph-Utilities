<#
.SYNOPSIS
    Genera un informe de auditoría de licencias de Microsoft 365 utilizando autenticación de Service Principal y nombres comerciales para las licencias.

.DESCRIPTION
    Este script se conecta a Microsoft Graph de forma no interactiva para obtener una lista de todos los usuarios, las licencias que tienen asignadas (mostrando nombres comerciales como "Microsoft 365 E5") y su última fecha de inicio de sesión. 
    El resultado se exporta a un archivo CSV.

.NOTES
    Autor: Juan Sánchez
    Fecha: 17/04/2025
    Requiere el módulo de PowerShell 'Microsoft.Graph'.
    Permisos de aplicación de Graph necesarios: 'User.Read.All', 'Directory.Read.All', 'AuditLog.Read.All' (con consentimiento de administrador).
#>

# --- PARÁMETROS DE CONEXIÓN DESATENDIDA ---
# Los parámetros se cargan desde un archivo de configuración JSON externo.
$configFilePath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"

if (-not (Test-Path $configFilePath)) {
    Write-Error "El archivo de configuración '$configFilePath' no fue encontrado."
    Write-Error "Asegúrese de que el archivo exista en la misma carpeta que el script y contenga los parámetros necesarios (tenantId, clientId, organizationName, certThumbprint)."
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    $tenantId = $config.tenantId
    $clientId = $config.clientId
}
catch {
    Write-Error "No se pudo leer o procesar el archivo de configuración '$configFilePath'. Verifique que el formato JSON sea correcto."
    Write-Error $_.Exception.Message
    return
}

# Fin de parámetros de conexión desatendida

# --- Importación del Secreto de Cliente ---
# El secreto se almacena en un archivo XML encriptado para mayor seguridad.
$secretFilePath = Join-Path -Path $PSScriptRoot -ChildPath "secret.xml"

if (-not (Test-Path $secretFilePath)) {
    Write-Error "El archivo de secreto '$secretFilePath' no fue encontrado."
    Write-Error "Para crearlo, ejecute este comando en PowerShell, reemplazando con su secreto real:"
    Write-Error '"SU_SECRETO_AQUI" | ConvertTo-SecureString -AsPlainText -Force | Export-CliXml -Path ".\secret.xml"'
    return
}

# Importar el secreto (SecureString) desde el archivo encriptado.
try {
    $secureSecret = Import-CliXml -Path $secretFilePath
}
catch {
    Write-Error "No se pudo importar el secreto desde '$secretFilePath'. Asegúrese de que el archivo no esté corrupto y que usted sea el mismo usuario que lo creó."
    Write-Error $_.Exception.Message
    return
}

# Paso 2: Conectarse a Microsoft Graph utilizando las credenciales de la aplicación.
try {
    Write-Host "Conectando a Microsoft Graph con credenciales de aplicación..." -ForegroundColor Cyan
    # $credential = New-Object System.Management.Automation.PSCredential($clientId, $secureSecret)
    # Connect-MgGraph -TenantId $tenantId -Credential $credential
    Connect-MgGraph -TenantId $TenantId -AppId $ClientId -CertificateThumbprint $certThumbprint
    Write-Host "Conexión exitosa." -ForegroundColor Green
}
catch {
    Write-Error "No se pudo conectar a Microsoft Graph. Verifique las credenciales de la aplicación y los permisos."
    Write-Error $_.Exception.Message
    return
}

# Paso 3: Crear una tabla de búsqueda de SKU a SKU Part Number
# -----------------------------------------------------------
Write-Host "Obteniendo SKUs de licencias disponibles en el tenant..."
$skuIdToPartNumberTable = @{}
try {
    $subscribedSkus = Get-MgSubscribedSku
    foreach ($sku in $subscribedSkus) {
        $skuIdToPartNumberTable[$sku.SkuId] = $sku.SkuPartNumber
    }
    Write-Host "Se encontraron $($skuIdToPartNumberTable.Count) SKUs." -ForegroundColor Green
}
catch {
    Write-Error "No se pudieron obtener las SKUs de las licencias. Error: $($_.Exception.Message)"
    Disconnect-MgGraph
    return
}

# Paso 4: Tabla de conversión de SKU Part Number a Nombres Comerciales
# --------------------------------------------------------------------
# Esta tabla traduce los identificadores técnicos a nombres legibles. Puede agregar más según sea necesario.
$skuFriendlyNames = @{
    "SPE_E5" = "Microsoft 365 E5";
    "SPE_E3" = "Microsoft 365 E3";
    "SPE_F3" = "Microsoft 365 F3";
    "ENTERPRISEPREMIUM" = "Office 365 E5";
    "ENTERPRISEPACK" = "Office 365 E3";
    "STANDARDPACK" = "Microsoft 365 Business Standard";
    "BUSINESS_PREMIUM" = "Microsoft 365 Business Premium";
    "BUSINESS_VOICE" = "Microsoft 365 Business Voice";
    "POWER_BI_PRO" = "Power BI Pro";
    "POWER_BI_PREMIUM_PER_USER" = "Power BI Premium Per User";
    "PROJECTPREMIUM" = "Project Plan 5";
    "PROJECTPROFESSIONAL" = "Project Plan 3";
    "PROJECTESSENTIALS" = "Project Plan 1"; 
    "VISIO_PLAN2" = "Visio Plan 2";
    "DYN365_ENTERPRISE_P1" = "Dynamics 365 Customer Engagement Plan";
    "FLOW_PER_USER" = "Power Automate per user plan";
    "POWERAPPS_PER_USER" = "Power Apps per user plan";
    "POWER_AUTOMATE_FREE" = "Power Automate Gratuito";
    "EMSPREMIUM" = "Enterprise Mobility + Security E5";
    "EMS" = "Enterprise Mobility + Security E3";
    "AAD_PREMIUM_P1" = "Microsoft Entra ID P1";
    "AAD_PREMIUM_P2" = "Microsoft Entra ID P2";
    "RIGHTSMANAGEMENT_ADHOC" = "Rights Management Ad-Hoc";
    "TEAMS_ROOMS_STANDARD" = "Microsoft Teams Rooms Standard";
    "TEAMS_EXPLORATORY" = "Microsoft Teams Exploratorio"; 
    "Deskless" = "Office 365 F3";
    "STANDARDWOFFPACK_IW_STUDENT" = "Office 365 A1 para Estudiantes"
    "Microsoft_365_Copilot" = "Microsoft 365 Copilot";
    "MICROSOFT_365_BUSINESS" = "Microsoft 365 Business Basic";
    "Dynamics_365_Sales_Field_Service_and_Customer_Service_Partner_Sandbox" = "Dynamics 365 Sales";
    "VISIOCLIENT" = "Visio Plan 1";
    "CCIBOTS_PRIVPREV_VIRAL" = "Copilot Studio Viral Trial";
    "FLOW_FREE" = "Power Automate Free";
    "VIVA" = "Viva Suite";
    "POWER_BI_STANDARD" = "Power BI Free";
    "POWERAPPS_DEV" = "Power Apps Developer Plan";
    "Power_Pages_vTrial_for_Makers" = "Power Pages Trial";
    "CPC_E_8C_32GB_512GB" = "Windows 365 Enterprise 8 vCPU 32 GB 512 GB";
    "DYN365_ENTERPRISE_PLAN1" = "Dynamics 365 Plan 1";
    "MCOMEETADV" = "Microsoft 365 Audio Conferencing";
    "SMB_APPS" = "Business Apps (free)";
    "POWERAPPS_VIRAL" = "Microsoft Power Apps Plan 2 Trial";
    "FORMS_PRO" = "Dynamics 365 Customer Voice Trial";
    "O365_BUSINESS_PREMIUM" = "Microsoft 365 Business Premium";
    "O365_BUSINESS_ESSENTIALS" = "Microsoft 365 Business Basic";
    "O365_BUSINESS" = "Microsoft 365 Business Standard";
    # Agregue aquí otras licencias que su organización utilice
}

# Paso 5: Obtener todos los usuarios y sus datos de inicio de sesión
# -----------------------------------------------------------------
Write-Host "Obteniendo todos los usuarios... Esto puede tardar unos minutos en tenants grandes."
try {
    $users = Get-MgUser -All -Property "id,displayName,userPrincipalName,assignedLicenses,signInActivity"
}
catch {
    Write-Error "No se pudieron obtener los usuarios. Verifique permisos. Error: $($_.Exception.Message)"
    Disconnect-MgGraph
    return
}

# Paso 6: Procesar los datos de cada usuario
# ------------------------------------------
$totalUsers = $users.Count
$processedCount = 0
Write-Host "Procesando $($totalUsers) usuarios para generar el informe..."

$reportData = foreach ($user in $users) {
    $processedCount++
    Write-Progress -Activity "Procesando usuarios" -Status "Usuario $processedCount de $totalUsers" -PercentComplete (($processedCount / $totalUsers) * 100)

    # Obtener los SKU Part Numbers (ej: SPE_E5) de las licencias asignadas al usuario
    $skuPartNumbers = $user.AssignedLicenses | ForEach-Object { $skuIdToPartNumberTable[$_.SkuId] }

    # Traducir los SKU Part Numbers a nombres comerciales usando la tabla del Paso 4
    $assignedLicensesFriendly = ($skuPartNumbers | ForEach-Object {
        if ($skuFriendlyNames.ContainsKey($_)) {
            $skuFriendlyNames[$_] # Usar el nombre comercial si existe
        } else {
            $_ # Si no se encuentra, usar el identificador original
        }
    }) -join ", "
    
    if ([string]::IsNullOrEmpty($assignedLicensesFriendly)) {
        $assignedLicensesFriendly = "Sin licencias asignadas"
    }

    # Obtener la última fecha de inicio de sesión
    $lastSignIn = if ($user.SignInActivity -and $user.SignInActivity.LastSignInDateTime) {
        Get-Date -Date $user.SignInActivity.LastSignInDateTime -Format 'yyyy-MM-dd HH:mm:ss'
    } else {
        "Dato no disponible"
    }

    # Crear el objeto para el informe
    [PSCustomObject]@{
        "Nombre"               = $user.DisplayName
        "CorreoElectronico"    = $user.UserPrincipalName
        "UltimoInicioDeSesion" = $lastSignIn
        "LicenciasAsignadas"   = $assignedLicensesFriendly
    }
}

Write-Progress -Activity "Procesando usuarios" -Completed

# Paso 7: Exportar los resultados a un archivo CSV
# ------------------------------------------------
$fileName = "Informe_Auditoria_Licencias_M365_$(Get-Date -Format 'yyyy-MM-dd-HH-mm-ss').csv"
$path = if ($PSScriptRoot) { Join-Path -Path $PSScriptRoot -ChildPath $fileName } else { $fileName }

try {
    $reportData | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
    Write-Host "`nInforme completado con éxito." -ForegroundColor Green
    Write-Host "Resultados exportados a: $path"
}
catch {
    Write-Error "No se pudo exportar el informe a CSV. Error: $($_.Exception.Message)"
}

# Paso 8: Desconexión y vista previa
# ----------------------------------
Write-Host "Desconectando de Microsoft Graph..." -ForegroundColor Green
Disconnect-MgGraph

Write-Host "`nMostrando una vista previa del informe:" -ForegroundColor Cyan
$reportData | Select-Object -First 10 | Format-Table -AutoSize
