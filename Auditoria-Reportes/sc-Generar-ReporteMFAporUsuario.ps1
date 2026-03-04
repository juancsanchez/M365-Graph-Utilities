<#
.SYNOPSIS
    Genera un informe detallado de los métodos de autenticación (MFA) registrados por cada usuario.

.DESCRIPTION
    Este script se conecta a Microsoft Graph utilizando un certificado (autenticación desatendida).
    Utiliza la API de informes de métodos de autenticación para obtener una instantánea de todos los usuarios,
    indicando si tienen MFA registrado, qué métodos específicos tienen configurados (Authenticator, Teléfono, FIDO2, etc.)
    y cuál es su método predeterminado.
    
    El uso de la API de reportes es mucho más eficiente que iterar usuario por usuario.

.NOTES
    Autor: Juan Sánchez
    Fecha: 2025-11-20
    Requiere módulo: Microsoft.Graph.Reports
    Permisos de API requeridos: 'Reports.Read.All' o 'AuditLog.Read.All'.
#>

# --- INICIO: BLOQUE DE CONEXIÓN Y CONFIGURACIÓN ---

# Validar módulo
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Reports)) {
    Write-Host "El módulo 'Microsoft.Graph.Reports' no está instalado. Instalando..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Reports -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
}

# Cargar configuración desde JSON
$configFilePath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"

if (-not (Test-Path $configFilePath)) {
    Write-Error "No se encontró el archivo de configuración 'config.json' en: $configFilePath"
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    $tenantId = $config.tenantId
    $clientId = $config.clientId
    $certThumbprint = $config.certThumbprint
}
catch {
    Write-Error "Error al leer 'config.json'. Verifique el formato."
    return
}

# Conexión a Graph
try {
    Write-Host "Conectando a Microsoft Graph (Reports) con certificado..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $tenantId -AppId $clientId -CertificateThumbprint $certThumbprint
    Write-Host "Conexión exitosa." -ForegroundColor Green
}
catch {
    Write-Error "Falló la conexión a Microsoft Graph. Verifique config.json y los permisos (Reports.Read.All)."
    Write-Error $_.Exception.Message
    return
}

# --- FIN: BLOQUE DE CONEXIÓN ---

# --- INICIO: LÓGICA PRINCIPAL ---

$reportData = [System.Collections.Generic.List[object]]::new()

try {
    Write-Host "Obteniendo detalles de registro de métodos de autenticación (esto puede tardar unos instantes)..." -ForegroundColor Cyan
    
    # Esta API es la forma más eficiente de obtener el estado de MFA masivo sin hacer loop por usuario
    $authDetails = Get-MgReportAuthenticationMethodUserRegistrationDetail -All

    $totalUsers = $authDetails.Count
    Write-Host "Se obtuvieron registros para $totalUsers usuarios. Procesando datos..." -ForegroundColor Green

    $counter = 0
    foreach ($userRecord in $authDetails) {
        $counter++
        if ($counter % 100 -eq 0) {
            Write-Progress -Activity "Procesando reporte de MFA" -Status "Procesando usuario $counter de $totalUsers" -PercentComplete (($counter / $totalUsers) * 100)
        }

        # Convertir el array de métodos a un string separado por comas para el CSV
        $methodsString = if ($userRecord.MethodsRegistered) { ($userRecord.MethodsRegistered -join ", ") } else { "Ninguno" }
        
        # Determinar estado legible
        $mfaStatus = if ($userRecord.IsMfaRegistered) { "Registrado" } else { "No Registrado" }
        $ssprStatus = if ($userRecord.IsSsprRegistered) { "Habilitado" } else { "No Habilitado" }

        $reportObject = [PSCustomObject]@{
            UserPrincipalName      = $userRecord.UserPrincipalName
            Nombre                 = $userRecord.UserDisplayName
            MFA_Estado             = $mfaStatus
            SSPR_Estado            = $ssprStatus
            Metodo_Predeterminado  = $userRecord.DefaultMfaMethod
            Metodos_Registrados    = $methodsString
            Es_Passwordless        = $userRecord.IsPasswordlessCapable
        }

        $reportData.Add($reportObject)
    }
    Write-Progress -Activity "Procesando reporte de MFA" -Completed

    # Exportar a CSV
    if ($reportData.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
        $fileName = "Reporte_MFA_Usuarios_$timestamp.csv"
        $filePath = Join-Path -Path $PSScriptRoot -ChildPath $fileName
        
        # Determinar el encoding correcto según la versión de PowerShell para garantizar BOM (Excel lo necesita para tildes)
        # PowerShell Core (6+) usa utf8NoBOM por defecto con "UTF8", así que forzamos "utf8BOM".
        # PowerShell Windows (5.1) usa BOM por defecto con "UTF8".
        $encoding = "UTF8"
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $encoding = "utf8BOM"
        }

        # Ordenar por nombre para facilitar la lectura
        $reportData | Sort-Object Nombre | Export-Csv -Path $filePath -NoTypeInformation -Encoding $encoding -Delimiter ","
        
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "Reporte generado exitosamente en:" -ForegroundColor Green
        Write-Host $filePath -ForegroundColor White
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
        
        # Mostrar vista previa
        $reportData | Select-Object Nombre, MFA_Estado, Metodos_Registrados | Select-Object -First 10 | Format-Table -AutoSize
    }
    else {
        Write-Warning "No se encontraron datos de autenticación."
    }

}
catch {
    Write-Error "Ocurrió un error durante la generación del reporte: $($_.Exception.Message)"
}
finally {
    if (Get-MgContext) {
        Write-Host "Desconectando de Microsoft Graph..."
        Disconnect-MgGraph
    }
}