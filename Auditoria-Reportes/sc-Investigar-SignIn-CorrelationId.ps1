<#
.SYNOPSIS
    Investiga un intento de inicio de sesión fallido utilizando su Correlation ID.

.DESCRIPTION
    Este script solicita al usuario un 'Correlation ID' de un evento de Sign-In de Microsoft Entra ID.
    Se conecta a Microsoft Graph utilizando un certificado (autenticación desatendida) y recupera los detalles del evento.
    
    Analiza y muestra en consola:
    - Detalles del usuario, fecha, aplicación y dispositivo.
    - El motivo técnico del error (Sign-in Error Code).
    - Un desglose de las Políticas de Acceso Condicional que se aplicaron y, específicamente, cuáles causaron el fallo.

.NOTES
    Autor: Juan Sánchez
    Fecha: 2025-12-15
    Requiere módulo: Microsoft.Graph.Reports
    Permisos de API requeridos: 'AuditLog.Read.All' y 'Directory.Read.All'.
#>

# --- INICIO: BLOQUE DE CONEXIÓN Y CONFIGURACIÓN ---

# 1. Verificar módulo necesario
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Reports)) {
    Write-Host "El módulo 'Microsoft.Graph.Reports' no está instalado. Intentando instalar..." -ForegroundColor Yellow
    try {
        Install-Module Microsoft.Graph.Reports -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    catch {
        Write-Error "No se pudo instalar el módulo requerido. Instálelo manualmente."
        return
    }
}

# 2. Cargar configuración desde JSON (Mismo patrón que tus otros scripts)
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
    Write-Error "Error al leer 'config.json'. Verifique el formato JSON."
    return
}

# 3. Conexión a Graph
try {
    Write-Host "Conectando a Microsoft Graph con certificado..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $tenantId -AppId $clientId -CertificateThumbprint $certThumbprint
    Write-Host "Conexión exitosa." -ForegroundColor Green
}
catch {
    Write-Error "Falló la conexión a Microsoft Graph. Verifique config.json y los permisos (AuditLog.Read.All)."
    Write-Error $_.Exception.Message
    return
}

# --- FIN: BLOQUE DE CONEXIÓN ---

# --- INICIO: LÓGICA PRINCIPAL ---

try {
    # 4. Solicitar Input al usuario
    Write-Host "`n--- Investigador de Logs de Sign-In ---" -ForegroundColor Cyan
    $correlationId = Read-Host "Por favor, ingrese el Correlation ID del intento de sign-in"

    if ([string]::IsNullOrWhiteSpace($correlationId)) {
        Write-Warning "No se ingresó un Correlation ID válido."
        return
    }

    Write-Host "Buscando evento con ID: $correlationId ..." -ForegroundColor Yellow

    # 5. Buscar el log de sign-in
    # Se utiliza el filtro OData para buscar específicamente ese ID
    $signInRecord = Get-MgAuditLogSignIn -Filter "correlationId eq '$correlationId'" -ErrorAction Stop

    if (-not $signInRecord) {
        Write-Warning "No se encontraron registros de inicio de sesión con ese Correlation ID."
        Write-Warning "Nota: Los logs pueden tardar unos minutos en aparecer en Graph después del evento."
        return
    }

    # Nota: A veces un correlation ID trae varios registros (interactivos y no interactivos).
    # Tomamos el primero o iteramos si es necesario. Generalmente el error está en el registro principal.
    foreach ($record in $signInRecord) {
        
        Write-Host "`n--------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "RESUMEN DEL INTENTO DE CONEXIÓN" -ForegroundColor White
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan

        # Datos Básicos
        Write-Host "Fecha y Hora (UTC) : " -NoNewline; Write-Host $record.CreatedDateTime -ForegroundColor White
        Write-Host "Usuario            : " -NoNewline; Write-Host $record.UserPrincipalName -ForegroundColor White
        Write-Host "Nombre             : " -NoNewline; Write-Host $record.UserDisplayName -ForegroundColor White
        Write-Host "Aplicación         : " -NoNewline; Write-Host $record.AppDisplayName -ForegroundColor White
        Write-Host "IP Address         : " -NoNewline; Write-Host $record.IpAddress -ForegroundColor White
        
        # Datos del Dispositivo
        $deviceInfo = "Desconocido/No registrado"
        if ($record.DeviceDetail) {
            $os = if ($record.DeviceDetail.OperatingSystem) { $record.DeviceDetail.OperatingSystem } else { "SO Desconocido" }
            $browser = if ($record.DeviceDetail.Browser) { $record.DeviceDetail.Browser } else { "" }
            $deviceInfo = "$os ($browser)"
        }
        Write-Host "Dispositivo        : " -NoNewline; Write-Host $deviceInfo -ForegroundColor White

        # Estado del Error Principal
        $errorCode = $record.Status.ErrorCode
        $failureReason = $record.Status.FailureReason
        
        Write-Host "`n--- ANÁLISIS DE ERROR ---" -ForegroundColor Yellow
        if ($errorCode -eq 0) {
            Write-Host "Resultado          : EXITOSO" -ForegroundColor Green
        }
        else {
            Write-Host "Resultado          : FALLIDO" -ForegroundColor Red
            Write-Host "Código de Error    : $errorCode" -ForegroundColor Red
            Write-Host "Razón del Fallo    : $failureReason" -ForegroundColor Red
            Write-Host "Mensaje Adicional  : $($record.Status.AdditionalDetails)" -ForegroundColor Gray
        }

        # Análisis de Acceso Condicional
        if ($record.AppliedConditionalAccessPolicies) {
            Write-Host "`n--- POLÍTICAS DE ACCESO CONDICIONAL ---" -ForegroundColor Yellow
            
            $failedPolicies = $record.AppliedConditionalAccessPolicies | Where-Object { $_.Result -eq "failure" }
            $successPolicies = $record.AppliedConditionalAccessPolicies | Where-Object { $_.Result -eq "success" }
            $reportOnlyPolicies = $record.AppliedConditionalAccessPolicies | Where-Object { $_.Result -eq "reportOnlyFailure" }

            # Mostrar las que fallaron (La causa del bloqueo)
            if ($failedPolicies) {
                Write-Host "[BLOQUEO] Las siguientes políticas impidieron el acceso:" -ForegroundColor Red
                foreach ($policy in $failedPolicies) {
                    Write-Host " - Nombre: $($policy.DisplayName)" -ForegroundColor Red
                    Write-Host "   Controles no cumplidos: $($policy.EnforcedGrantControls -join ', ')" -ForegroundColor Gray
                    Write-Host "   Razón del fallo: $($policy.ResultReason)" -ForegroundColor Gray
                }
            }
            elseif ($errorCode -ne 0) {
                Write-Host "El fallo no fue causado por Acceso Condicional (posible error de credenciales o bloqueo de cuenta)." -ForegroundColor Gray
            }

            # Resumen rápido de otras políticas
            if ($successPolicies) {
                Write-Host "`n[OK] Políticas superadas correctamente: $($successPolicies.Count)" -ForegroundColor Green
            }
            if ($reportOnlyPolicies) {
                Write-Host "[REPORT-ONLY] Políticas que habrían fallado: $($reportOnlyPolicies.Count)" -ForegroundColor Magenta
            }
        }
        else {
            Write-Host "`nNo se aplicaron políticas de Acceso Condicional." -ForegroundColor Gray
        }
        Write-Host "--------------------------------------------------------`n" -ForegroundColor Cyan
    }

}
catch {
    Write-Error "Ocurrió un error inesperado al procesar la solicitud."
    Write-Error $_.Exception.Message
}
finally {
    # Desconexión opcional, dependiendo de si quieres mantener la sesión viva
    if (Get-MgContext) {
        Write-Host "Desconectando de Microsoft Graph..."
        Disconnect-MgGraph | Out-Null
    }
}