<#
.SYNOPSIS
    Busca grupos de seguridad y de Microsoft 365 compartidos entre tres o más usuarios en Microsoft Entra ID.

.DESCRIPTION
    Este script se conecta a Microsoft Graph y, dado un listado de User Principal Names (UPNs),
    identifica a qué grupos pertenecen todos ellos en común. El script valida que se
    ingresen entre 3 y 5 UPNs.

    Requiere un archivo 'config.json' en la misma carpeta con el tenantId, clientId y certThumbprint.
    La autenticación se realiza mediante un certificado.

.PARAMETER UPNs
    Un array de strings que contiene entre 3 y 5 User Principal Names (UPNs) de los usuarios a consultar.

.EXAMPLE
    PS C:\Scripts> .\Find-CommonGroups.ps1 -UPNs "usuario1@ejemplo.com", "usuario2@ejemplo.com", "usuario3@ejemplo.com"

    Este comando buscará los grupos comunes para los tres usuarios especificados.

.OUTPUTS
    Muestra en la consola un listado de los grupos comunes encontrados, especificando su DisplayName,
    ID y tipo (Seguridad o Microsoft 365).
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true,
               ValueFromPipeline = $true,
               HelpMessage = "Proporcione entre 3 y 5 UPNs de usuarios.")]
    [string[]]$UPNs
)

# --- Inicio: Bloque de Conexión y Configuración ---

# Validar que el módulo de Microsoft Graph esté instalado
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Error "El módulo de PowerShell 'Microsoft.Graph' no está instalado. Por favor, instálelo con 'Install-Module Microsoft.Graph -Scope CurrentUser'."
    return
}

# Cargar configuración desde el archivo JSON
$configFilePath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
if (-not (Test-Path $configFilePath)) {
    Write-Error "No se encontró el archivo de configuración 'config.json' en la ruta: $configFilePath"
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    $tenantId = $config.tenantId
    $clientId = $config.clientId
    $certThumbprint = $config.certThumbprint
    Write-Host "Certificado encontrado: $certThumbprint" -ForegroundColor Green
    Write-Host "Cliente ID: $clientId" -ForegroundColor Green
    Write-Host "Tenant ID: $tenantId" -ForegroundColor Green
}
catch {
    Write-Error "Error al leer o procesar el archivo 'config.json'. Verifique que el formato sea correcto y que contenga tenantId, clientId y certThumbprint."
    return
}

if ([string]::IsNullOrWhiteSpace($certThumbprint)) {
    Write-Error "El valor 'certThumbprint' no se encontró o está vacío en el archivo config.json."
    return
}

# Conexión a Microsoft Graph
try {
    Write-Host "Conectando a Microsoft Graph..." -ForegroundColor Yellow
    # Seleccionar el perfil Beta para acceder a todas las propiedades necesarias de los grupos.
    # Select-MgProfile -Name "beta"
    Connect-MgGraph -TenantId $tenantId -AppId $clientId -CertificateThumbprint $certThumbprint
    Write-Host "Conexión exitosa." -ForegroundColor Green
}
catch {
    Write-Error "Falló la conexión a Microsoft Graph. Verifique los detalles de configuración en config.json y el certificado."
    return
}

# --- Fin: Bloque de Conexión y Configuración ---


# --- Inicio: Lógica Principal del Script ---

# Validar la cantidad de UPNs ingresados
if ($UPNs.Count -lt 3 -or $UPNs.Count -gt 5) {
    Write-Error "El script requiere entre 3 y 5 UPNs. Usted proporcionó $($UPNs.Count)."
    return
}

Write-Host "`nIniciando la búsqueda de grupos comunes para $($UPNs.Count) usuarios..." -ForegroundColor Cyan

$allUsersGroups = @{}
$userCounter = 0

# 1. Obtener los grupos de cada usuario
foreach ($upn in $UPNs) {
    $userCounter++
    Write-Host "($userCounter/$($UPNs.Count)) Obteniendo grupos para: $upn"
    try {
        # Obtenemos los IDs de los grupos a los que pertenece el usuario
        $userGroups = Get-MgUserMemberOf -UserId $upn -All | Select-Object -ExpandProperty Id
        if ($null -eq $userGroups) {
            Write-Warning "El usuario $upn no parece ser miembro de ningún grupo o no se pudo obtener la información."
            continue
        }
        $allUsersGroups[$upn] = $userGroups
    }
    catch {
        Write-Error "No se pudo obtener la información para el usuario '$upn'. Verifique que el UPN sea correcto y que tenga permisos."
        # Si un usuario falla, no podemos continuar la comparación.
        return
    }
}

# 2. Encontrar la intersección de los grupos
Write-Host "`nCalculando la intersección de grupos..." -ForegroundColor Yellow

# Empezamos con la lista de grupos del primer usuario
# Si el primer usuario no tiene grupos, no puede haber intersección.
if (-not $allUsersGroups.ContainsKey($UPNs[0])) {
     Write-Host "`nNo se encontraron grupos para el primer usuario ($($UPNs[0])). No se puede realizar la comparación." -ForegroundColor Green
     Disconnect-MgGraph
     return
}
$commonGroupIds = $allUsersGroups[$UPNs[0]]

# Iteramos sobre el resto de los usuarios para encontrar los grupos en común
for ($i = 1; $i -lt $UPNs.Count; $i++) {
    $currentUserUPN = $UPNs[$i]
    if (-not $allUsersGroups.ContainsKey($currentUserUPN)) {
        # Si uno de los usuarios no tiene grupos, la intersección es vacía.
        $commonGroupIds = @()
        break
    }
    $currentUserGroups = $allUsersGroups[$currentUserUPN]
    
    # Comparamos la lista actual de grupos comunes con la del usuario actual
    # y nos quedamos solo con los que están en ambas (la intersección).
    $commonGroupIds = Compare-Object -ReferenceObject $commonGroupIds -DifferenceObject $currentUserGroups -IncludeEqual -ExcludeDifferent -PassThru
}

if (-not $commonGroupIds) {
    Write-Host "`nNo se encontraron grupos comunes para todos los usuarios especificados." -ForegroundColor Green
    Disconnect-MgGraph
    return
}

# 3. Obtener detalles de los grupos comunes y mostrar los resultados
Write-Host "`nSe encontraron $($commonGroupIds.Count) grupos comunes. Obteniendo detalles..." -ForegroundColor Yellow
$finalResults = @()

foreach ($groupId in $commonGroupIds) {
    try {
        $group = Get-MgGroup -GroupId $groupId -Property "DisplayName,Id,GroupTypes,MailEnabled,SecurityEnabled"
        
        $groupType = "Desconocido"
        # Un grupo de Microsoft 365 es del tipo "Unified"
        if ($group.GroupTypes -contains "Unified") {
            $groupType = "Microsoft 365"
        }
        # Un grupo de seguridad tiene esta propiedad en $true y no es MailEnabled (para excluir Distribution Groups)
        elseif ($group.SecurityEnabled -and -not $group.MailEnabled) {
            $groupType = "Seguridad"
        }
        # Podríamos añadir más lógica para otros tipos si fuera necesario

        # Añadimos solo los tipos que nos interesan al resultado final
        if ($groupType -in ("Microsoft 365", "Seguridad")) {
             $finalResults += [PSCustomObject]@{
                NombreDelGrupo = $group.DisplayName
                TipoDeGrupo    = $groupType
                ID             = $group.Id
            }
        }
    }
    catch {
        Write-Warning "No se pudo obtener información para el grupo con ID: $groupId"
    }
}

# 4. Desplegar la tabla de resultados
if ($finalResults.Count -gt 0) {
    Write-Host "`n--- Grupos Comunes Encontrados ---" -ForegroundColor Cyan
    $finalResults | Format-Table -AutoSize
}
else {
    Write-Host "`nNo se encontraron grupos de Seguridad o Microsoft 365 en común para los usuarios especificados." -ForegroundColor Green
}

# --- Fin: Lógica Principal del Script ---

# Desconexión de la sesión de Graph
Write-Host "`nScript finalizado. Desconectando de Microsoft Graph."
Disconnect-MgGraph
