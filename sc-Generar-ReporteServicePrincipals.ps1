<#
.SYNOPSIS
    Realiza una auditoría avanzada de los permisos de aplicación (AppRoleAssignments) asignados a todos los Service Principals
    en un tenant de Microsoft Entra ID, utilizando autenticación desatendida con Microsoft Graph.

.DESCRIPTION
    Este script se conecta a Microsoft Graph usando un Service Principal y un certificado. Itera sobre todos los Service Principals
    del tenant para recolectar, clasificar e identificar permisos de alto privilegio.
    
    La salida es un archivo CSV detallado y un resumen en la consola para un análisis rápido.

.PARAMETER TenantId
    El ID del Tenant de Microsoft Entra (ej: 'contoso.onmicrosoft.com' o un GUID).

.PARAMETER ClientId
    El App (Client) ID del Service Principal que se usará para la autenticación.

.PARAMETER CertificateThumbprint
    El Thumbprint (huella digital) del certificado asociado al Service Principal de autenticación.

.REQUIREMENTS
    - Módulo de PowerShell: Microsoft.Graph.Authentication, Microsoft.Graph.Applications.
    - El Service Principal utilizado para ejecutar este script necesita los siguientes permisos de API de Microsoft Graph:
        - Application.Read.All
        - AppRoleAssignment.ReadWrite.All
        - Directory.Read.All

.EXAMPLE
    .\Audit-ServicePrincipalPermissions.ps1 -TenantId "your-tenant-id.onmicrosoft.com" -ClientId "your-app-client-id" -CertificateThumbprint "YOUR_CERTIFICATE_THUMBPRINT"
    
    Ejecuta el script con los parámetros de autenticación requeridos, generando el reporte CSV y el resumen en consola.

.NOTES
    Autor: Juan Sánchez
    Fecha: 2024-06-17
#>

# --- INICIO DE CONFIGURACIÓN ---

# Lista editable de permisos considerados de alto privilegio. Puede agregar o quitar permisos según sus políticas de seguridad.
$HighPrivilegePermissions = @(
    "Directory.ReadWrite.All",
    "RoleManagement.ReadWrite.Directory",
    "Application.ReadWrite.All",
    "AppRoleAssignment.ReadWrite.All",
    "Policy.ReadWrite.All",
    "User.ReadWrite.All",
    "Group.ReadWrite.All",
    "Mail.ReadWrite",
    "Mail.Send",
    "Sites.FullControl.All",
    "Files.ReadWrite.All",
    "Calendars.ReadWrite",
    "Sites.ReadWrite.All",
    "full_access_as_app",
    "AppRoleAssignment.ReadWrite.All",
    "RoleManagement.Read.Directory",
    "Exchange.ManageAsApp"
)

# --- FIN DE CONFIGURACIÓN ---

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
    $CertificateThumbprint = $config.certThumbprint
}
catch {
    Write-Error "No se pudo leer o procesar el archivo de configuración '$configFilePath'. Verifique que el formato JSON sea correcto."
    Write-Error $_.Exception.Message
    return
}

# Fin de parámetros de conexión desatendida

# Inicialización de contadores y recolectores de datos
$reportData = [System.Collections.Generic.List[object]]::new()
$summary = @{
    TotalSPs = 0
    ReadPermissions = 0
    ReadWritePermissions = 0
    OtherPermissions = 0
    HighPrivilegeSPs = [System.Collections.Generic.List[string]]::new()
}

try {
    Write-Host "Iniciando la auditoría de permisos de Service Principals..."
    Write-Host "Paso 1: Conectando a Microsoft Graph de forma desatendida..."

    # Conexión a Microsoft Graph usando Service Principal y certificado
    Connect-MgGraph -TenantId $TenantId -AppId $ClientId -CertificateThumbprint $CertificateThumbprint
    
    Write-Host "Conexión exitosa." -ForegroundColor Green

    # Paso 2: Obteniendo todos los Service Principals. Esto puede tardar en tenants grandes.
    Write-Host "Paso 2: Obteniendo todos los Service Principals del tenant (esto puede tardar)..."
    $allServicePrincipals = Get-MgServicePrincipal -All -ErrorAction Stop
    $summary.TotalSPs = $allServicePrincipals.Count
    Write-Host "Se encontraron $($summary.TotalSPs) Service Principals."

    # Crear una tabla hash para búsquedas rápidas de SPs por su ID (optimización)
    $spLookup = @{}
    $allServicePrincipals | ForEach-Object { $spLookup[$_.Id] = $_ }
    
    Write-Host "Paso 3: Analizando los permisos para cada Service Principal..."
    $spCounter = 0

    # Paso 3: Iterar sobre cada Service Principal para analizar sus permisos
    foreach ($sp in $allServicePrincipals) {
        $spCounter++
        Write-Progress -Activity "Analizando Service Principals" -Status "Procesando $($sp.DisplayName)" -PercentComplete ($spCounter / $summary.TotalSPs * 100)

        # Obtener las asignaciones de roles de aplicación (permisos) para el SP actual
        $appRoleAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -ErrorAction SilentlyContinue

        if (-not $appRoleAssignments) {
            continue # Si no tiene permisos, pasar al siguiente
        }

        foreach ($assignment in $appRoleAssignments) {
            # El ResourceId apunta al SP de la API (ej: Microsoft Graph) que concede el permiso
            $resourceSP = $spLookup[$assignment.ResourceId]

            if (-not $resourceSP) {
                Write-Warning "No se pudo encontrar el Service Principal del recurso con ID $($assignment.ResourceId) para el permiso del SP $($sp.DisplayName)."
                continue
            }
            
            # El AppRoleId identifica el permiso específico dentro de la API
            $permissionDefinition = $resourceSP.AppRoles | Where-Object { $_.Id -eq $assignment.AppRoleId }

            if ($permissionDefinition) {
                $permissionName = $permissionDefinition.Value
                $apiName = $resourceSP.DisplayName

                # Clasificación de permisos
                $classification = "Otros"
                if ($permissionName -like "*.Read" -and $permissionName -notlike "*.ReadWrite*") {
                    $classification = "Read"
                    $summary.ReadPermissions++
                }
                elseif ($permissionName -like "*.ReadWrite*" -or $permissionName.EndsWith(".All")) {
                    $classification = "ReadWrite"
                    $summary.ReadWritePermissions++
                } else {
                    $summary.OtherPermissions++
                }

                # Verificación de alto privilegio
                $isHighPrivilege = $HighPrivilegePermissions -contains $permissionName
                if ($isHighPrivilege -and !$summary.HighPrivilegeSPs.Contains($sp.DisplayName)) {
                    $summary.HighPrivilegeSPs.Add($sp.DisplayName)
                }
                
                # Crear el objeto para el reporte
                $outputObject = [PSCustomObject]@{
                    ServicePrincipalDisplayName = $sp.DisplayName
                    AppId                     = $sp.AppId
                    API                       = $apiName
                    Permiso                   = $permissionName
                    Clasificacion             = $classification
                    EsAltoPrivilegio          = $isHighPrivilege
                }
                $reportData.Add($outputObject)
            }
        }
    }

    Write-Progress -Activity "Analizando Service Principals" -Completed

    # Paso 4: Generar el reporte en formato CSV
    if ($reportData.Count -gt 0) {
        $fileName = "Reporte_Permisos_SP_$(Get-Date -Format 'yyyy-MM-dd-HH-mm-ss').csv"
        $filePath = Join-Path -Path $PSScriptRoot -ChildPath $fileName
        
        Write-Host "Paso 4: Generando reporte CSV en: $filePath"
        $reportData | Export-Csv -Path $filePath -NoTypeInformation -Encoding UTF8
        Write-Host "Reporte CSV generado exitosamente." -ForegroundColor Green
    } else {
        Write-Warning "No se encontraron permisos asignados a ningún Service Principal para generar un reporte."
    }

    # Paso 5: Mostrar el resumen en la consola
    Write-Host "`n--- RESUMEN DE LA AUDITORÍA ---" -ForegroundColor Yellow
    Write-Host "Total de Service Principals analizados: $($summary.TotalSPs)"
    Write-Host "Permisos de tipo 'Read' encontrados : $($summary.ReadPermissions)"
    Write-Host "Permisos de tipo 'ReadWrite' encontrados: $($summary.ReadWritePermissions)"
    Write-Host "Permisos de tipo 'Otros' encontrados: $($summary.OtherPermissions)"
    Write-Host "----------------------------------" -ForegroundColor Yellow
    
    if ($summary.HighPrivilegeSPs.Count -gt 0) {
        Write-Host "`n[!] ATENCIÓN: Se encontraron permisos de ALTO PRIVILEGIO en los siguientes Service Principals:" -ForegroundColor Red
        $summary.HighPrivilegeSPs | ForEach-Object { Write-Host " - $_" }
    } else {
        Write-Host "`n[+] No se encontraron permisos de alto privilegio según la lista definida." -ForegroundColor Green
    }

}
catch {
    Write-Error "Ocurrió un error crítico durante la ejecución del script: $($_.Exception.Message)"
    Write-Error "Detalles: $($_.ToString())"
}
finally {
    # Paso 6: Desconexión de la sesión de Microsoft Graph
    if (Get-MgContext) {
        Write-Host "`n`nPaso 6: Desconectando de la sesión de Microsoft Graph."
        Disconnect-MgGraph | Out-Null
    }
}
