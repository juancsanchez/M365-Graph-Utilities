<#
.SYNOPSIS
    Gets the total count of users with at least one Microsoft 365 license assigned,
    authenticating non-interactively using a certificate.

.DESCRIPTION
    This script connects to Microsoft Graph using an Entra ID App Registration and a certificate.
    It reads connection parameters from an external 'config.json' file.
    To handle very large tenants efficiently, it uses parallel processing. It breaks down the
    user query into smaller chunks (based on the starting letter of the DisplayName) and processes
    them concurrently to significantly reduce execution time and memory usage.

.NOTES
    Author: Juan Sánchez
    Date: 2025-07-04
    Requires: 
        - PowerShell 7+ (for ForEach-Object -Parallel)
        - Microsoft.Graph PowerShell module.
        - A 'config.json' file in the same directory as this script.
        - An Entra ID App Registration with the 'User.Read.All' application permission granted.
        - A certificate uploaded to the App Registration and installed on the local machine.
#>

# --- CONFIGURACIÓN ---
# El script carga la configuración desde un archivo 'config.json' ubicado en el mismo directorio.
# Asegúrate de que el archivo exista y contenga las claves: tenantId, clientId, y certThumbprint.

try {
    # Define la ruta del archivo de configuración
    $configFile = Join-Path -Path $PSScriptRoot -ChildPath "config.json"

    if (-not (Test-Path $configFile)) {
        throw "Error: No se encontró el archivo de configuración 'config.json' en la ruta '$PSScriptRoot'."
    }

    # Lee y procesa el archivo JSON
    $config = Get-Content -Path $configFile -Raw | ConvertFrom-Json
    $tenantId = $config.tenantId
    $clientId = $config.clientId
    $certificateThumbprint = $config.certThumbprint

    # Valida que los valores requeridos fueron cargados
    if ([string]::IsNullOrEmpty($tenantId) -or [string]::IsNullOrEmpty($clientId) -or ([string]::IsNullOrEmpty($certificateThumbprint))) {
        throw "El archivo 'config.json' no contiene todos los valores requeridos (tenantId, clientId, certThumbprint)."
    }

    # Bloque para asegurar que el módulo de Microsoft Graph esté instalado
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
        Write-Host "El módulo de PowerShell de Microsoft Graph no está instalado." -ForegroundColor Yellow
        Write-Host "Instalando el módulo... (esto puede tardar unos minutos)"
        Install-Module Microsoft.Graph -Repository PSGallery -Force -Scope CurrentUser
    } else {
        Write-Host "Módulo Microsoft.Graph ya se encuentra instalado." -ForegroundColor Green
    }

    # Conecta a Microsoft Graph en la sesión principal (aunque cada hilo reconectará)
    Write-Host "Conectando a Microsoft Graph con certificado..."
    Connect-MgGraph -TenantId $tenantId -AppId $clientId -CertificateThumbprint $certificateThumbprint

    Write-Host "Conexión principal exitosa." -ForegroundColor Green

    # --- OPTIMIZACIÓN PARA TENANTS GRANDES CON PROCESAMIENTO EN PARALELO ---
    Write-Host "Iniciando procesamiento en paralelo para optimizar la consulta en un tenant grande..."
    
    # Se crea un conjunto de caracteres para dividir las consultas
    $processSet = ('a'..'z') + ('0'..'9')

    Write-Host $processSet

    # Se procesa cada caracter en un hilo separado.
    # -ThrottleLimit controla cuántos hilos se ejecutan simultáneamente. 10 es un valor razonable.
    $results = $processSet | ForEach-Object -ThrottleLimit 10 -Parallel {
        # Las variables del script principal se deben pasar al ámbito del hilo con $using:
        $threadTenantId = $using:tenantId
        $threadClientId = $using:clientId
        $threadCertThumbprint = $using:certificateThumbprint
        $char = $_
        
        try {
            # 1. FORZAR LA CARGA DE MÓDULOS EN EL HILO
            Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users -ErrorAction Stop

            # 2. CONECTAR Y VERIFICAR LA CONEXIÓN DENTRO DEL HILO
            $connection = Connect-MgGraph -TenantId $threadTenantId -AppId $threadClientId -CertificateThumbprint $threadCertThumbprint
            if (-not $connection) {
                throw "La conexión a Graph falló en el hilo para el caracter '$char'."
            }
            
            # Se obtienen los usuarios que comienzan con el caracter actual y se cuentan los que tienen licencia.
            $users = Get-MgUser -Filter "startsWith(displayName, '$char')" -All -Property Id,AssignedLicenses -ConsistencyLevel eventual
            $count = ($users | Where-Object { $_.AssignedLicenses.Count -gt 0 }).Count
            
            # Se devuelve un objeto con el resultado para este hilo.
            return [PSCustomObject]@{ Character = $char; Count = $count; Error = $null }
        }
        catch {
            return [PSCustomObject]@{ Character = $char; Count = 0; Error = "Error en caracter '$char': $($_.Exception.Message)" }
        }
        finally {
            # Se desconecta la sesión de Graph del hilo actual.
            if (Get-MgContext) { Disconnect-MgGraph }
        }
    }

    # Se consolidan los resultados de todos los hilos.
    $totalLicensedUserCount = 0
    $errors = @()
    foreach ($result in $results) {
        if ($result.Error) {
            $errors += $result.Error
        } else {
            $totalLicensedUserCount += $result.Count
            Write-Host "Carácter '$($result.Character)' procesado, encontró $($result.Count). Recuento acumulado: $totalLicensedUserCount"
        }
    }

    if ($errors.Count -gt 0) {
        Write-Warning "Se encontraron errores durante el procesamiento en paralelo:"
        $errors | ForEach-Object { Write-Warning "- $_" }
    }

    Write-Host "Nota: Este método optimizado cuenta usuarios cuyo DisplayName comienza con a-z o 0-9." -ForegroundColor Yellow
    Write-Host "Usuarios con otros caracteres iniciales no serán incluidos en este recuento." -ForegroundColor Yellow

    # Muestra el resultado final
    Write-Host "----------------------------------------" -ForegroundColor Cyan
    Write-Host "Total de usuarios con licencia: $totalLicensedUserCount" -ForegroundColor Green
    Write-Host "----------------------------------------" -ForegroundColor Cyan

}
catch {
    Write-Host "Ocurrió un error:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
}
finally {
    # Desconecta la sesión principal de Microsoft Graph.
    if (Get-MgContext) {
        Write-Host "Desconectando de la sesión de Microsoft Graph."
        Disconnect-MgGraph
    }
}
