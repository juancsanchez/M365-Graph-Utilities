<#
.SYNOPSIS
    Identifica qué políticas de Acceso Condicional (CA) incluyen o excluyen grupos específicos de Microsoft Entra ID.

.DESCRIPTION
    Este script se conecta a Microsoft Graph utilizando un certificado para autenticación desatendida. 
    Solicita al usuario una lista de Object IDs de grupos y audita si están incluidos o excluidos 
    explícitamente en la configuración de las políticas de Acceso Condicional del tenant.

.REQUIREMENTS
    - Módulos de PowerShell: Microsoft.Graph.
    - Archivo 'config.json' en la misma carpeta con tenantId, clientId y certThumbprint.
    - Permisos de API (Application): Policy.Read.All, Group.Read.All.

.NOTES
    Autor: Juan Sánchez
    Fecha: 2025-12-18
    Versión: 1.3 (Verificación de módulos simplificada y robusta)
#>

# --- INICIO: BLOQUE DE CONEXIÓN Y CONFIGURACIÓN ---

# 1. Verificar módulos necesarios (Lógica simplificada)
# Verificamos la presencia del módulo padre en lugar de submódulos específicos para evitar falsos negativos.
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Error "El módulo 'Microsoft.Graph' no se encuentra instalado en este equipo."
    Write-Error "El script no puede continuar sin él. Por favor, ejecute el siguiente comando manualmente y vuelva a intentar:"
    Write-Host "Install-Module Microsoft.Graph -Scope CurrentUser -Force" -ForegroundColor Yellow
    return
}

# Intentamos importar los submódulos necesarios. Si ya están cargados, esto no hace nada.
# Usamos SilentlyContinue para evitar ruido si la estructura de carpetas del módulo varía (común en Mac).
Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue
Import-Module Microsoft.Graph.Identity.ConditionalAccess -ErrorAction SilentlyContinue

# 2. Cargar configuración desde el archivo JSON
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
    Write-Error "Error al leer 'config.json'. Verifique que el formato sea correcto."
    return
}

# 3. Conexión a Microsoft Graph mediante certificado
try {
    Write-Host "Conectando a Microsoft Graph con certificado..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $tenantId -AppId $clientId -CertificateThumbprint $certThumbprint
    Write-Host "Conexión exitosa." -ForegroundColor Green
}
catch {
    Write-Error "Falló la conexión a Microsoft Graph. Verifique los detalles en config.json y el certificado."
    return
}

# --- FIN: BLOQUE DE CONEXIÓN ---

# --- INICIO: LÓGICA PRINCIPAL ---

try {
    # 4. Solicitar entrada de IDs de grupo al usuario
    Write-Host "`n--- Auditoría de Alcance de Grupos ---" -ForegroundColor Cyan
    $inputGroups = Read-Host "Ingrese los Object IDs de los grupos a consultar (separe varios con comas)"

    if ([string]::IsNullOrWhiteSpace($inputGroups)) {
        Write-Warning "No se proporcionó ningún ID de grupo. El script finalizará."
        return
    }

    # Procesar la entrada para convertirla en un array limpio
    $targetGroupIds = $inputGroups.Split(',').Trim() | Where-Object { $_ -ne "" }

    Write-Host "`nObteniendo todas las políticas de Acceso Condicional..." -ForegroundColor Yellow
    
    # Verificación defensiva antes de llamar al comando
    if (-not (Get-Command Get-MgIdentityConditionalAccessPolicy -ErrorAction SilentlyContinue)) {
        throw "El comando 'Get-MgIdentityConditionalAccessPolicy' no está disponible. Asegúrese de que el módulo Microsoft.Graph esté actualizado."
    }

    $policies = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop

    Write-Host "Analizando el alcance de $($targetGroupIds.Count) grupos en $($policies.Count) políticas..." -ForegroundColor Cyan

    # 5. Filtrado y construcción del reporte personalizado
    $results = foreach ($policy in $policies) {
        foreach ($groupId in $targetGroupIds) {
            # Verificar si el grupo está en la lista de incluidos o excluidos
            $isIncluded = $policy.Conditions.Users.IncludeGroups -contains $groupId
            $isExcluded = $policy.Conditions.Users.ExcludeGroups -contains $groupId

            if ($isIncluded -or $isExcluded) {
                [PSCustomObject]@{
                    NombrePolitica = $policy.DisplayName
                    Estado         = $policy.State
                    ID_Grupo       = $groupId
                    Asignacion     = if ($isIncluded) { "Incluido" } else { "Excluido" }
                }
            }
        }
    }

    # 6. Despliegue de resultados
    if ($results) {
        Write-Host "`n--- Resultado del Análisis de Alcance ---" -ForegroundColor Green
        $results | Format-Table -AutoSize
    }
    else {
        Write-Host "`nNo se encontraron políticas que afecten directamente a los grupos proporcionados." -ForegroundColor Yellow
    }
}
catch {
    Write-Error "Ocurrió un error inesperado: $($_.Exception.Message)"
}
finally {
    # 7. Desconexión de la sesión de Graph
    if (Get-MgContext) {
        Write-Host "`nDesconectando de Microsoft Graph."
        Disconnect-MgGraph | Out-Null
    }
}