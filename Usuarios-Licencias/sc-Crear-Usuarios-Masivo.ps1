<#
.SYNOPSIS
    Crea usuarios masivamente en Microsoft Entra ID desde un CSV, con soporte para campos opcionales.

.DESCRIPTION
    Este script se conecta a Microsoft Graph utilizando un certificado (autenticación desatendida).
    Lee un archivo CSV y crea usuarios con contraseña aleatoria.
    Soporta columnas opcionales: jobTitle, department, country, mobilePhone, firstName, lastName.
    Si alguna de estas columnas no existe o está vacía, se omite ese campo específico para ese usuario.

.PARAMETER CsvFilePath
    Ruta al archivo CSV.
    Columnas OBLIGATORIAS: upn, DisplayName
    Columnas OPCIONALES: jobTitle, department, country, mobilePhone, firstName, lastName

.NOTES
    Autor: Juan Sánchez
    Fecha: 2025-12-04
    Requiere módulo: Microsoft.Graph.Users
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Ruta al archivo CSV de entrada.")]
    [string]$CsvFilePath
)

# --- FUNCIÓN AUXILIAR: GENERAR CONTRASEÑA ROBUSTA ---
function New-SecurePassword {
    param ([int]$Length = 16)
    $lower = 97..122 | ForEach-Object { [char]$_ }
    $upper = 65..90  | ForEach-Object { [char]$_ }
    $digits = 48..57 | ForEach-Object { [char]$_ }
    $specials = "!@#$%^&*".ToCharArray()
    
    $passwordChars = @(
        ($lower | Get-Random),
        ($upper | Get-Random),
        ($digits | Get-Random),
        ($specials | Get-Random)
    )
    
    $allChars = $lower + $upper + $digits + $specials
    while ($passwordChars.Count -lt $Length) {
        $passwordChars += ($allChars | Get-Random)
    }
    
    return ($passwordChars | Sort-Object { Get-Random }) -join ""
}

# --- VERIFICACIÓN DE MÓDULOS ---
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
    Write-Host "Instalando módulo 'Microsoft.Graph.Users'..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Users -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
}

# --- CONEXIÓN Y CONFIGURACIÓN ---
$configFilePath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
if (-not (Test-Path $configFilePath)) {
    Write-Error "No se encontró 'config.json'."
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    Write-Host "Conectando a Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $config.tenantId -AppId $config.clientId -CertificateThumbprint $config.certThumbprint
    Write-Host "Conexión exitosa." -ForegroundColor Green
}
catch {
    Write-Error "Error de conexión: $($_.Exception.Message)"
    return
}

# --- LÓGICA PRINCIPAL ---
$reportData = [System.Collections.Generic.List[object]]::new()

try {
    if (-not (Test-Path $CsvFilePath)) { throw "Archivo CSV no encontrado." }

    $csvData = Import-Csv -Path $CsvFilePath
    $totalRows = $csvData.Count
    
    if ($totalRows -eq 0) { Write-Warning "El CSV está vacío."; return }

    Write-Host "Procesando $totalRows usuarios..." -ForegroundColor Cyan
    $counter = 0

    foreach ($row in $csvData) {
        $counter++
        
        # 1. Campos Obligatorios
        $upn = $row.upn
        $displayName = $row.DisplayName
        
        if ([string]::IsNullOrWhiteSpace($upn)) {
            Write-Warning "Fila $counter omitida: Falta 'upn'."
            continue
        }
        # Si no hay DisplayName, intenta construirlo con firstName y lastName si existen
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            if (-not [string]::IsNullOrWhiteSpace($row.firstName) -and -not [string]::IsNullOrWhiteSpace($row.lastName)) {
                $displayName = "$($row.firstName) $($row.lastName)"
            }
            else {
                Write-Warning "Fila $counter omitida: Falta 'DisplayName' y no se pudo construir."
                continue
            }
        }

        Write-Progress -Activity "Creando Usuarios" -Status "($counter/$totalRows) - $upn" -PercentComplete (($counter / $totalRows) * 100)

        # 2. Preparar Parámetros Base
        $generatedPassword = New-SecurePassword
        $mailNickname = $upn.Split("@")[0]

        $userParams = @{
            UserPrincipalName = $upn
            DisplayName       = $displayName
            MailNickname      = $mailNickname
            AccountEnabled    = $true
            PasswordProfile   = @{
                Password                      = $generatedPassword
                ForceChangePasswordNextSignIn = $false
            }
        }

        # 3. Mapeo de Campos Opcionales (Solo si tienen datos)
        # Se verifica si la propiedad existe en el objeto $row Y si no está vacía
        if (-not [string]::IsNullOrWhiteSpace($row.jobTitle)) { $userParams["JobTitle"] = $row.jobTitle }
        if (-not [string]::IsNullOrWhiteSpace($row.department)) { $userParams["Department"] = $row.department }
        if (-not [string]::IsNullOrWhiteSpace($row.mobilePhone)) { $userParams["MobilePhone"] = $row.mobilePhone }
        if (-not [string]::IsNullOrWhiteSpace($row.firstName)) { $userParams["GivenName"] = $row.firstName }
        if (-not [string]::IsNullOrWhiteSpace($row.lastName)) { $userParams["Surname"] = $row.lastName }
        if (-not [string]::IsNullOrWhiteSpace($row.country)) { $userParams["Country"] = $row.country }

        # Variables de reporte
        $status = "Exitoso"
        $message = "Usuario creado"
        $userId = $null

        try {
            # Verificar existencia previa
            if (Get-MgUser -UserId $upn -ErrorAction SilentlyContinue) {
                throw "El usuario ya existe"
            }

            # Crear usuario con Splatting (pasa el hashtable dinámico)
            $newUser = New-MgUser @userParams -ErrorAction Stop
            $userId = $newUser.Id
            
            Write-Host "  [OK] $upn" -ForegroundColor Green
        }
        catch {
            $status = "Error"
            $message = $_.Exception.Message
            $generatedPassword = "NO_GENERADA"
            Write-Warning "  [X] Error en '$upn': $message"
        }

        # 4. Construir objeto para el reporte final (incluyendo los datos opcionales usados)
        $reportRecord = [PSCustomObject]@{
            UserPrincipalName = $upn
            DisplayName       = $displayName
            Password          = $generatedPassword
            JobTitle          = if ($userParams.ContainsKey("JobTitle")) { $userParams["JobTitle"] } else { "" }
            Department        = if ($userParams.ContainsKey("Department")) { $userParams["Department"] } else { "" }
            Country           = if ($userParams.ContainsKey("Country")) { $userParams["Country"] } else { "" }
            MobilePhone       = if ($userParams.ContainsKey("MobilePhone")) { $userParams["MobilePhone"] } else { "" }
            UserID            = $userId
            Estado            = $status
            Detalle           = $message
        }
        $reportData.Add($reportRecord)
    }
    Write-Progress -Activity "Creando Usuarios" -Completed

    # 5. Exportar Reporte
    if ($reportData.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
        $outputFile = Join-Path -Path $PSScriptRoot -ChildPath "Reporte_Usuarios_Creados_$timestamp.csv"
        
        $reportData | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
        
        Write-Host "`n--------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "Reporte generado en: $outputFile" -ForegroundColor Green
        Write-Host "IMPORTANTE: Contiene contraseñas. Protéjalo." -ForegroundColor Red
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
    }

}
catch {
    Write-Error "Error crítico: $($_.Exception.Message)"
}
finally {
    if (Get-MgContext) { Disconnect-MgGraph | Out-Null }
}