<#
.SYNOPSIS
    Genera un informe de los miembros activos en roles de administrador privilegiados en Microsoft Entra ID utilizando autenticación desatendida y un secreto almacenado de forma segura.

.DESCRIPTION
    Este script se conecta a Microsoft Graph utilizando un App Registration (ID de Cliente y un Secreto importado de un archivo encriptado) 
    para identificar a los usuarios que son miembros de roles de administrador específicos y altamente privilegiados. 
    El resultado es un archivo CSV que contiene el nombre del rol, el nombre de usuario, el User Principal Name (UPN) y el tipo de objeto.
    
.NOTES
    Autor: Juan Sánchez
    Fecha: 17/06/2025
    Versión: 2.1 (Secreto externalizado y encriptado)
    Requiere el módulo de PowerShell de Microsoft Graph.
    
    IMPORTANTE: El App Registration utilizado debe tener los siguientes permisos de API de Microsoft Graph (tipo Aplicación):
    - RoleManagement.Read.Directory
    - User.Read.All
    
#>

#region Conexión y Prerrequisitos

# Importar el módulo de Microsoft Graph
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Host "El módulo de PowerShell de Microsoft Graph no está instalado." -ForegroundColor Yellow
    Write-Host "Por favor, ejecute: Install-Module Microsoft.Graph -Scope CurrentUser" -ForegroundColor Yellow
    return
}

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

# Conectarse a Microsoft Graph utilizando las credenciales de la aplicación.
try {
    Write-Host "Conectando a Microsoft Graph con credenciales de aplicación..." -ForegroundColor Cyan
      $credential = New-Object System.Management.Automation.PSCredential($clientId, $secureSecret)
    Connect-MgGraph -TenantId $tenantId -Credential $credential
    Write-Host "Conexión exitosa." -ForegroundColor Green
}
catch {
    Write-Error "No se pudo conectar a Microsoft Graph. Verifique las credenciales de la aplicación y los permisos."
    Write-Error $_.Exception.Message
    return
}

#endregion

#region Definición de Roles y Procesamiento

# --- PERSONALICE ESTA LISTA ---
# Agregue o quite los nombres exactos de los roles que desea auditar.
$privilegedRoleNames = @(
    "Global Administrator",
    "SharePoint Administrator",
    "Exchange Administrator",
    "Teams Administrator",
    "Security Administrator",
    "User Administrator",
    "Billing Administrator",
    "Conditional Access Administrator",
    "Helpdesk Administrator"
)

# Arreglo para almacenar los resultados finales
$reportData = @()

Write-Host "Iniciando la auditoría de roles privilegiados..." -ForegroundColor Cyan

# Obtener todos los roles de directorio disponibles en el tenant para mapear nombres a IDs
try {
    $allDirectoryRoles = Get-MgDirectoryRole -All
}
catch {
    Write-Error "No se pudieron obtener los roles de directorio. Verifique los permisos de la aplicación en Entra ID."
    Write-Error $_.Exception.Message
    return
}


# Iterar sobre la lista de roles privilegiados definidos
foreach ($roleName in $privilegedRoleNames) {
    
    $activity = "Procesando rol: $roleName"
    Write-Progress -Activity "Auditando Roles" -Status $activity -PercentComplete (($privilegedRoleNames.IndexOf($roleName) / $privilegedRoleNames.Count) * 100)
    
    Write-Host $activity
    
    # Encontrar el objeto de rol correspondiente al nombre
    $roleObject = $allDirectoryRoles | Where-Object { $_.DisplayName -eq $roleName }
    
    if (-not $roleObject) {
        Write-Warning "El rol '$roleName' no fue encontrado en el directorio. Se omitirá."
        continue
    }
    
    # Obtener los miembros del rol
    try {
        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $roleObject.Id -All
        
        if (-not $members) {
            Write-Host "  -> El rol '$roleName' no tiene miembros activos." -ForegroundColor Gray
            continue
        }

        # Iterar sobre cada miembro del rol
        foreach ($member in $members) {
            
            $displayName = $member.AdditionalProperties.displayName
            $userPrincipalName = $member.AdditionalProperties.userPrincipalName
            $objectType = $member.OdataType -replace '#microsoft.graph.'
            
            if (-not $userPrincipalName) {
                $userPrincipalName = "N/A (Objeto tipo: $objectType)"
            }

            Write-Host "  -> Miembro encontrado: $displayName ($userPrincipalName)" -ForegroundColor Green

            $record = [PSCustomObject]@{
                "Rol"                 = $roleObject.DisplayName
                "NombreMiembro"       = $displayName
                "UserPrincipalName"   = $userPrincipalName
                "TipoDeObjeto"        = $objectType
            }
            
            $reportData += $record
        }
    }
    catch {
        Write-Warning "No se pudieron obtener los miembros para el rol '$roleName'."
        Write-Warning $_.Exception.Message
    }
}

Write-Progress -Activity "Auditando Roles" -Completed

#endregion

#region Exportación del Informe

if ($reportData.Count -gt 0) {
    $timestamp = Get-Date -Format "yyyy-MM-dd"
    $fileName = "Reporte_Membresia_Roles_Administrador_$timestamp.csv"
    $filePath = Join-Path -Path $PSScriptRoot -ChildPath $fileName
    
    try {
        $reportData | Export-Csv -Path $filePath -NoTypeInformation -Encoding UTF8
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "Informe generado exitosamente en:" -ForegroundColor Green
        Write-Host $filePath -ForegroundColor White
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
    }
    catch {
        Write-Error "Ocurrió un error al exportar el archivo CSV."
        Write-Error $_.Exception.Message
    }
}
else {
    Write-Warning "No se encontraron miembros en los roles especificados para generar un informe."
}

# Desconectar la sesión de Microsoft Graph
Write-Host "Desconectando de Microsoft Graph..."
Disconnect-MgGraph

#endregion
