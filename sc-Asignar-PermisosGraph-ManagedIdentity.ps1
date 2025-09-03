<#
.SYNOPSIS
    Asigna permisos de API de Microsoft Graph a una Identidad Administrada (Managed Identity) o Service Principal.

.DESCRIPTION
    Este script se conecta a Microsoft Graph utilizando un certificado para la autenticación desatendida y asigna un conjunto 
    predefinido de permisos de aplicación a la Identidad Administrada especificada por su App (Client) ID.

    El script es ideal para automatizar la configuración de permisos necesarios para servicios de Azure que utilizan 
    Managed Identities para acceder a recursos de Microsoft Graph.

.PARAMETER ManagedIdentityAppId
    El 'Application (client) ID' de la Identidad Administrada o Service Principal al que se le asignarán los permisos.

.REQUIREMENTS
    - Módulo de PowerShell: Microsoft.Graph.
    - Permiso de API de Microsoft Graph para el principal que ejecuta el script: 'AppRoleAssignment.ReadWrite.All'.
    - Un archivo 'config.json' en la misma carpeta con tenantId, clientId y certThumbprint para la conexión.

.EXAMPLE
    .\sc-Asignar-PermisosGraph-ManagedIdentity.ps1 -ManagedIdentityAppId "f1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d"

    El script buscará la Identidad Administrada con el App ID proporcionado y le asignará los permisos definidos.

.NOTES
    Autor: Juan Sánchez
    Fecha: 2025-09-03
    Versión: 1.0
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Ingrese el Application (client) ID de la Identidad Administrada.")]
    [string]$ManagedIdentityAppId
)

# --- INICIO: BLOQUE DE CONEXIÓN Y CONFIGURACIÓN ---
# Asegurar que el módulo de Microsoft Graph esté disponible
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Host "Instalando módulo 'Microsoft.Graph'..." -ForegroundColor Yellow
    try {
        Install-Module Microsoft.Graph -Scope CurrentUser -Repository PSGallery -Force
    } catch {
        Write-Error "No se pudo instalar el módulo 'Microsoft.Graph'. Por favor, instálelo manualmente."
        return
    }
}

# Cargar configuración desde el archivo JSON
$configFilePath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
if (-not (Test-Path $configFilePath)) {
    Write-Error "Archivo de configuración '$configFilePath' no encontrado."
    return
}
try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    $tenantId = $config.tenantId
    $clientId = $config.clientId # El App ID del SP que ejecuta este script
    $certThumbprint = $config.certThumbprint
} catch {
    Write-Error "Error al leer 'config.json'. Verifique su formato y que contenga tenantId, clientId y certThumbprint."
    return
}

# Conexión a Microsoft Graph
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
try {
    # 1. Definir los permisos a asignar
    $permissionsToAssign = @(
        "AuditLog.Read.All",
        "User.Read.All",
        "User.ReadWrite.All"
    )

    # 2. Obtener el Service Principal de la Managed Identity
    Write-Host "Buscando la Identidad Administrada con App ID: '$ManagedIdentityAppId'..."
    $managedIdentitySP = Get-MgServicePrincipal -Filter "appId eq '$ManagedIdentityAppId'"
    if (-not $managedIdentitySP) {
        throw "No se encontró un Service Principal con el App ID '$ManagedIdentityAppId'. Verifique el identificador."
    }
    Write-Host "Identidad Administrada encontrada: '$($managedIdentitySP.DisplayName)' (ID: $($managedIdentitySP.Id))" -ForegroundColor Green

    # 3. Obtener el Service Principal de Microsoft Graph (es el recurso al que se le piden los permisos)
    $graphApiSP = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
    Write-Host "Service Principal de Microsoft Graph encontrado."

    # 4. Iterar y asignar cada permiso
    foreach ($permission in $permissionsToAssign) {
        Write-Host "Procesando permiso: '$permission'..." -ForegroundColor Yellow

        # Buscar el AppRole (permiso) correspondiente en el SP de Graph
        $appRole = $graphApiSP.AppRoles | Where-Object { $_.Value -eq $permission -and $_.AllowedMemberTypes -contains "Application" }

        if (-not $appRole) {
            Write-Warning "El permiso '$permission' no fue encontrado en el Service Principal de Microsoft Graph. Se omitirá."
            continue
        }

        # Verificar si el permiso ya está asignado
        $existingAssignment = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentitySP.Id `
            | Where-Object { $_.AppRoleId -eq $appRole.Id }

        if ($existingAssignment) {
            Write-Host "El permiso '$permission' ya está asignado. No se requiere ninguna acción." -ForegroundColor Cyan
        } else {
            # Crear la asignación del permiso
            $params = @{
                ServicePrincipalId = $managedIdentitySP.Id
                PrincipalId        = $managedIdentitySP.Id
                ResourceId         = $graphApiSP.Id
                AppRoleId          = $appRole.Id
            }
            New-MgServicePrincipalAppRoleAssignment @params
            Write-Host "Permiso '$permission' asignado exitosamente." -ForegroundColor Green
        }
    }
}
catch {
    Write-Error "Ocurrió un error crítico durante la asignación de permisos: $($_.Exception.Message)"
}
finally {
    # Desconectar la sesión de Graph
    if (Get-MgContext) {
        Write-Host "`nDesconectando de la sesión de Microsoft Graph."
        Disconnect-MgGraph
    }
}