<#
.SYNOPSIS
    Crea App Registrations masivamente en Microsoft Entra ID basándose en un archivo CSV.

.DESCRIPTION
    Este script automatiza la creación de aplicaciones en Microsoft Entra ID.
    1. Lee un archivo CSV de entrada.
    2. Crea la aplicación con la configuración web especificada (Redirect URIs, Logout URL, ID Token).
    3. Asigna un propietario (Owner) si se especifica.
    4. Genera un reporte CSV final con el ID de la App y el enlace directo a su administración.

.PARAMETER CsvFilePath
    Ruta al archivo CSV. Debe contener las columnas exactas:
    AppName, RedirectURL, LogOutURL, idTokenRequired, owner

.REQUIREMENTS
    - Módulos: Microsoft.Graph.Applications, Microsoft.Graph.Users
    - Archivo 'config.json' en la misma carpeta con credenciales (Certificate Thumbprint).
    - Permisos de API (Application): Application.ReadWrite.All, User.Read.All, Directory.Read.All

.NOTES
    Autor: Juan Sánchez
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Ruta al archivo CSV de entrada.")]
    [string]$CsvFilePath
)

# --- 1. VERIFICACIÓN DE MÓDULOS ---
$requiredModules = @("Microsoft.Graph.Applications", "Microsoft.Graph.Users")
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Warning "El módulo '$module' no está instalado. Intentando instalar..."
        Install-Module $module -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
}

# --- 2. CARGA DE CONFIGURACIÓN Y CONEXIÓN ---
$configFilePath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"

if (-not (Test-Path $configFilePath)) {
    Write-Error "Error: No se encontró el archivo 'config.json' en la ruta del script."
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    
    Write-Host "Conectando a Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $config.tenantId -AppId $config.clientId -CertificateThumbprint $config.certThumbprint
    Write-Host "Conexión establecida." -ForegroundColor Green
}
catch {
    Write-Error "Error crítico al conectar: $($_.Exception.Message)"
    return
}

# --- 3. PROCESAMIENTO DEL CSV ---
$reportData = [System.Collections.Generic.List[object]]::new()

try {
    if (-not (Test-Path $CsvFilePath)) { throw "No se encuentra el archivo CSV: $CsvFilePath" }
    
    $csvData = Import-Csv -Path $CsvFilePath
    $total = $csvData.Count
    $count = 0

    Write-Host "Iniciando procesamiento de $total registros..." -ForegroundColor Cyan

    foreach ($row in $csvData) {
        $count++
        $appName = $row.AppName
        Write-Progress -Activity "Creando Aplicaciones" -Status "Procesando: $appName" -PercentComplete (($count / $total) * 100)
        
        # Variables de estado para el reporte
        $createdAppId = $null
        $adminUrl = "N/A"
        $status = "Exitoso"
        $details = ""

        try {
            # A. Configuración de parámetros Web
            # Convierte el string "TRUE" del CSV en booleano real
            $enableIdToken = if ($row.idTokenRequired -match "TRUE") { $true } else { $false }
            
            $webParams = @{
                RedirectUris          = @($row.RedirectURL)
                LogoutUrl             = $row.LogOutURL
                ImplicitGrantSettings = @{ 
                    EnableIdTokenIssuance     = $enableIdToken
                    EnableAccessTokenIssuance = $false 
                }
            }

            # B. Creación de la App
            # SignInAudience "AzureADMyOrg" configura la app como Single Tenant
            $newApp = New-MgApplication -DisplayName $appName -Web $webParams -SignInAudience "AzureADMyOrg" -ErrorAction Stop
            $createdAppId = $newApp.AppId

            # C. Construcción de URL de administración
            $adminUrl = "https://entra.microsoft.com/?feature.msaljs=true#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/$createdAppId/isMSAApp~/false"

            # D. Asignación de Owner (si aplica)
            if (-not [string]::IsNullOrWhiteSpace($row.owner)) {
                try {
                    $userOwner = Get-MgUser -UserId $row.owner -ErrorAction Stop
                    $ownerRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($userOwner.Id)" }
                    
                    New-MgApplicationOwnerByRef -ApplicationId $newApp.Id -BodyParameter $ownerRef -ErrorAction Stop
                }
                catch {
                    Write-Warning "App '$appName' creada, pero falló la asignación del owner ($($row.owner))."
                    $details = "Advertencia: Owner no asignado. " + $_.Exception.Message
                }
            }
        }
        catch {
            $status = "Error"
            $details = $_.Exception.Message
            Write-Error "Fallo al crear '$appName': $details"
        }

        # E. Registro de resultados
        $reportData.Add([PSCustomObject]@{
                AppName = $appName
                AppID   = if ($createdAppId) { $createdAppId } else { "ERROR" }
                URL     = $adminUrl
                Estado  = $status
                Detalle = $details
            })
    }

    # --- 4. EXPORTACIÓN DEL REPORTE ---
    $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
    $csvOut = Join-Path -Path $PSScriptRoot -ChildPath "Reporte_Apps_Creadas_$timestamp.csv"
    
    # Exporta estrictamente las columnas solicitadas al principio, dejando los detalles de auditoría al final
    $reportData | Select-Object AppName, AppID, URL, Estado, Detalle | Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8

    Write-Host "`n--------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "Proceso finalizado. Reporte generado en:" -ForegroundColor Green
    Write-Host "$csvOut" -ForegroundColor White
    Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
}
catch {
    Write-Error "Ocurrió un error inesperado: $($_.Exception.Message)"
}
finally {
    if (Get-MgContext) { Disconnect-MgGraph }
}