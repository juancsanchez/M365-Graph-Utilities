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
}
catch {
    Write-Error "No se pudo leer o procesar el archivo de configuración '$configFilePath'. Verifique que el formato JSON sea correcto."
    Write-Error $_.Exception.Message
    return
}

# Create certificate
# https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2?view=exchange-ps#step-1-register-the-application-in-microsoft-entra-id
$mycert = New-SelfSignedCertificate -DnsName $dnsName -CertStoreLocation "cert:\CurrentUser\My" -NotAfter (Get-Date).AddYears(1) -KeySpec KeyExchange

# Export certificate to .pfx file
$mycert | Export-PfxCertificate -FilePath mycert.pfx -Password (Get-Credential).password

# Export certificate to .cer file
$mycert | Export-Certificate -FilePath mycert.cer