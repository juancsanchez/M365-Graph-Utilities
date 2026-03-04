<#
.SYNOPSIS
    Genera un certificado autofirmado para pruebas y desarrollo, y lo exporta en formatos .pfx y .cer.

.DESCRIPTION
    Este script automatiza la creación de un certificado autofirmado utilizando el cmdlet New-SelfSignedCertificate.
    Está diseñado para facilitar la configuración de entornos de prueba que requieren autenticación basada en certificados,
    como la conexión a Microsoft Graph o Exchange Online mediante Service Principals.

    El script realiza las siguientes acciones:
    1. Carga la configuración (nombre DNS y tenant) desde un archivo 'config.json'.
    2. Crea un certificado autofirmado en el almacén de certificados del usuario actual.
    3. Exporta el certificado con clave privada (.pfx) protegido por contraseña.
    4. Exporta el certificado de clave pública (.cer) para ser subido a Azure/Entra ID.

.NOTES
    Autor: Juan Sánchez
    Fecha: 2025-12-04
    Requisitos: PowerShell 5.1 o superior.
#>

# --- PASO 1: CARGA DE CONFIGURACIÓN ---
# Se intenta leer el archivo 'config.json' ubicado en la misma carpeta que este script.
# Este archivo debe contener 'dnsName' (para el certificado) y 'tenant' (para nombrar los archivos de salida).
$configFilePath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"

if (-not (Test-Path $configFilePath)) {
    Write-Error "El archivo de configuración '$configFilePath' no fue encontrado."
    Write-Error "Asegúrese de que el archivo exista en la misma carpeta que el script y contenga los parámetros necesarios (tenantId, clientId, organizationName, certThumbprint, dnsName, tenant)."
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    $dnsName = $config.dnsName
    $tenant = $config.tenant
}
catch {
    Write-Error "No se pudo leer o procesar el archivo de configuración '$configFilePath'. Verifique que el formato JSON sea correcto."
    Write-Error $_.Exception.Message
    return
}

# --- PASO 2: CREACIÓN DEL CERTIFICADO ---
# Se crea el certificado autofirmado.
# -DnsName: El nombre de dominio asociado al certificado (ej. "MiAppLocal").
# -CertStoreLocation: Dónde se guardará (Usuario actual -> Personal).
# -NotAfter: Validez del certificado (2 años en este caso).
# -KeySpec KeyExchange: Habilita el intercambio de claves, necesario para cifrado/descifrado.
Write-Host "Creando certificado autofirmado para '$dnsName'..." -ForegroundColor Cyan
$mycert = New-SelfSignedCertificate -DnsName $dnsName -CertStoreLocation "cert:\CurrentUser\My" -NotAfter (Get-Date).AddYears(2) -KeySpec KeyExchange

# --- PASO 3: EXPORTACIÓN A .PFX (CON CLAVE PRIVADA) ---
# Este paso exporta el certificado incluyendo la clave privada.
# Es CRÍTICO para poder utilizar el certificado desde otra máquina o para autenticarse como la aplicación.
# Se solicitará una contraseña al usuario para proteger el archivo .pfx.
$pfxFileName = "cert-$($tenant)-$(Get-Date -Format 'yyyy-MM-dd').pfx"
Write-Host "Exportando clave privada a '$pfxFileName'..."
Write-Host "Por favor, ingrese una contraseña para proteger el archivo .pfx:" -ForegroundColor Yellow
$mycert | Export-PfxCertificate -FilePath $pfxFileName -Password (Get-Credential).password

# --- PASO 4: EXPORTACIÓN A .CER (SOLO CLAVE PÚBLICA) ---
# Este archivo es el que se debe subir al portal de Azure (App Registrations -> Certificates & secrets).
# No contiene información sensible (clave privada), por lo que es seguro compartirlo.
$cerFileName = "cert-$($tenant)-$(Get-Date -Format 'yyyy-MM-dd').cer"
Write-Host "Exportando clave pública a '$cerFileName'..."
$mycert | Export-Certificate -FilePath $cerFileName

Write-Host "Proceso completado exitosamente." -ForegroundColor Green