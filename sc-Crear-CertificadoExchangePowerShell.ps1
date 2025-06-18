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
    $dnsName = $config.dnsName
    $tenant = $config.tenant
}
catch {
    Write-Error "No se pudo leer o procesar el archivo de configuración '$configFilePath'. Verifique que el formato JSON sea correcto."
    Write-Error $_.Exception.Message
    return
}

# Create certificate
# https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2?view=exchange-ps#step-1-register-the-application-in-microsoft-entra-id
$mycert = New-SelfSignedCertificate -DnsName $dnsName -CertStoreLocation "cert:\CurrentUser\My" -NotAfter (Get-Date).AddYears(2) -KeySpec KeyExchange

# Export certificate to .pfx file
# Optional step if you need to export the certificate with a password (for MacOS or other systems)
$mycert | Export-PfxCertificate -FilePath "cert-$($tenant)-$(Get-Date -Format 'yyyy-MM-dd').pfx" -Password (Get-Credential).password

# Export certificate to .cer file with current date in the name
$mycert | Export-Certificate -FilePath "cert-$($tenant)-$(Get-Date -Format 'yyyy-MM-dd').cer"