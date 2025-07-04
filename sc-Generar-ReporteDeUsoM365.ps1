<#
.SYNOPSIS
    Genera un informe del tamaño de buzón (principal y archivo) y el almacenamiento de OneDrive para todos los usuarios.

.DESCRIPTION
    Este script se conecta a Microsoft Graph y Exchange Online utilizando una App Registration para operar de forma desatendida.
    Para la conexión, utiliza un secreto de cliente para Microsoft Graph y un certificado para Exchange Online.

    Recopila la siguiente información para cada usuario:
    - User Principal Name (UPN)
    - Nombre para mostrar (Display Name)
    - Tamaño del Buzón Principal
    - Tamaño del Buzón de Archivo
    - Tamaño utilizado en OneDrive
    
    El resultado es un archivo CSV con todos losdatos recopilados.

.NOTES
    Autor: Juan Sánchez
    Fecha: 17/06/2025
    Versión: 3.5 (Se fuerza la visualización de la barra de progreso)
    
    Requisitos de Módulos de PowerShell:
    - Microsoft.Graph
    - ExchangeOnlineManagement

    IMPORTANTE: El App Registration utilizado debe tener los siguientes permisos de API (tipo Aplicación):
    - Microsoft Graph:
        - User.Read.All: Para leer el perfil de todos los usuarios.
        - Files.Read.All (o Sites.Read.All): Para leer el uso de almacenamiento de OneDrive de todos los usuarios a través de Get-MgUserDrive.
        - Directory.Read.All: Para leer información del directorio.
    - Office 365 Exchange Online:
        - Exchange.ManageAsApp: Para permitir que la aplicación acceda a Exchange Online.

    Además, el Service Principal del App Registration debe tener un rol de administrador en Exchange Online (p. ej., 'Global Reader' o 'View-Only Organization Management').
#>

#region Conexión y Prerrequisitos

# Instalar módulos si no existen
$requiredModules = @("Microsoft.Graph", "ExchangeOnlineManagement")
foreach ($moduleName in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Write-Host "El módulo '$moduleName' no está instalado. Intentando instalar..." -ForegroundColor Yellow
        try {
            Install-Module $moduleName -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        }
        catch {
            Write-Error "No se pudo instalar el módulo '$moduleName'. Por favor, instálelo manualmente y vuelva a ejecutar el script."
            return
        }
    }
}

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
    $tenantId = $config.tenantId
    $clientId = $config.clientId
    $organizationName = $config.organizationName
    $certThumbprint = $config.certThumbprint
}
catch {
    Write-Error "No se pudo leer o procesar el archivo de configuración '$configFilePath'. Verifique que el formato JSON sea correcto."
    Write-Error $_.Exception.Message
    return
}

# Fin de parámetros de conexión desatendida

# Se usa para la conexión a Microsoft Graph
$secretFilePath = Join-Path -Path $PSScriptRoot -ChildPath "secret.xml"


# --- Importación del Secreto de Cliente (para Microsoft Graph) ---
if (-not (Test-Path $secretFilePath)) {
    Write-Error "El archivo de secreto '$secretFilePath' no fue encontrado."
    Write-Error "Para crearlo, ejecute: 'SU_SECRETO_AQUI' | ConvertTo-SecureString -AsPlainText -Force | Export-CliXml -Path '.\secret.xml'"
    return
}

try {
    $secureSecret = Import-CliXml -Path $secretFilePath
}
catch {
    Write-Error "No se pudo importar el secreto desde '$secretFilePath'. Asegúrese de que el archivo no esté corrupto."
    Write-Error $_.Exception.Message
    return
}


# --- Conexión a Servicios ---
try {
    Write-Host "Conectando a Microsoft Graph..." -ForegroundColor Cyan
    # $credential = New-Object System.Management.Automation.PSCredential($clientId, $secureSecret)
    # Connect-MgGraph -TenantId $tenantId -Credential $credential
    Connect-MgGraph -TenantId $TenantId -AppId $ClientId -CertificateThumbprint $certThumbprint
    Write-Host "Conexión a Microsoft Graph exitosa." -ForegroundColor Green

    Write-Host "Conectando a Exchange Online con certificado..." -ForegroundColor Cyan
    Connect-ExchangeOnline -AppId $clientId -CertificateThumbPrint $certThumbprint -Organization $organizationName
    Write-Host "Conexión a Exchange Online exitosa." -ForegroundColor Green
}
catch {
    Write-Error "Fallo en la conexión. Verifique los parámetros, permisos de la API y el rol asignado al Service Principal."
    Write-Error $_.Exception.Message
    # Desconectar si alguna sesión quedó abierta
    if (Get-MgContext) { Disconnect-MgGraph }
    if (Get-ConnectionInformation) { Disconnect-ExchangeOnline -Confirm:$false }
    return
}

#endregion

#region Función auxiliar para formatear tamaños

function Format-MailboxSize {
    param(
        $SizeValue
    )
    
    # Si es nulo, vacío o un estado especial, devolverlo tal cual.
    if ($null -eq $SizeValue -or $SizeValue -eq "" -or ($SizeValue -in ("N/A", "Sin buzón", "Sin archivo", "Error", "No aprovisionado"))) {
        return $SizeValue
    }
    
    # Si es un objeto ByteQuantifiedSize de Exchange, que viene como string "X.XX GB (XXX,XXX bytes)"
    if ($SizeValue -is [string] -and $SizeValue -match '\(([\d,]+) bytes\)') {
        # Extraer solo los bytes del string
        $bytes = [double]($matches[1] -replace ',', '')
        $gb = $bytes / 1GB
        return "{0:N2} GB" -f $gb
    }
    
    # Si es un valor numérico (útil para otros casos), convertirlo a GB.
    try {
        $numericValue = [double]$SizeValue
        $gb = $numericValue / 1GB
        return "{0:N2} GB" -f $gb
    }
    catch {
        # Si no se puede convertir, devolver el valor original o un error.
        return $SizeValue.ToString()
    }
}

#endregion

#region Recopilación de Datos

$ProgressPreference = 'Continue' # Asegura que la barra de progreso siempre se muestre
$reportData = @()
Write-Host "Obteniendo la lista de usuarios..." -ForegroundColor Cyan

try {
    # Para ser más eficiente, puede filtrar solo usuarios con licencia:
    # $users = Get-MgUser -Filter "assignedLicenses/any(x:x/skuId ne null)" -All -Property "id,displayName,userPrincipalName"
    $users = Get-MgUser -All -Property "id,displayName,userPrincipalName"
}
catch {
    Write-Error "No se pudo obtener la lista de usuarios desde Microsoft Graph."
    Write-Error $_.Exception.Message
    return
}

Write-Host "Se encontraron $($users.Count) usuarios. Procesando cada uno..." -ForegroundColor Cyan

$i = 0
foreach ($user in $users) {
    $i++
    $upn = $user.UserPrincipalName
    $activity = "Procesando: $upn ($i de $($users.Count))"
    Write-Progress -Activity "Recopilando datos de almacenamiento" -Status $activity -PercentComplete (($i / $users.Count) * 100)

    # --- Inicializar variables para este usuario ---
    $primaryMailboxSize = "N/A"
    $archiveMailboxSize = "N/A"
    $oneDriveSize = "N/A"

    # --- Obtener Tamaño de Buzón (Principal y Archivo) ---
    try {
        $mailboxStats = Get-MailboxStatistics -Identity $upn -ErrorAction SilentlyContinue
        if ($mailboxStats -and $mailboxStats.TotalItemSize) {
            # El TotalItemSize viene como un objeto ByteQuantifiedSize, lo convertimos a string para procesarlo
            $primaryMailboxSize = $mailboxStats.TotalItemSize.ToString()
        } else {
             $primaryMailboxSize = "Sin buzón"
        }

        # Intentar obtener estadísticas del buzón de archivo
        $archiveStats = Get-MailboxStatistics -Identity $upn -Archive -ErrorAction SilentlyContinue
        if ($archiveStats -and $archiveStats.TotalItemSize) {
            $archiveMailboxSize = $archiveStats.TotalItemSize.ToString()
        } else {
            $archiveMailboxSize = "Sin archivo"
        }
    }
    catch {
        Write-Warning "No se pudo obtener la información de buzón para $upn. Error: $($_.Exception.Message)"
        $primaryMailboxSize = "Error"
        $archiveMailboxSize = "Error"
    }

    # --- Obtener Tamaño de OneDrive ---
    try {
        # Se utiliza Get-MgUserDrive para obtener la información del drive principal del usuario.
        $driveInfo = Get-MgUserDrive -UserId $user.Id -ErrorAction SilentlyContinue

        # Corrección: En algunos casos, Get-MgUserDrive puede devolver una colección. Nos aseguramos de tomar solo el primer elemento (el drive principal).
        if ($driveInfo -is [System.Array] -and $driveInfo.Count -gt 0) {
            $driveInfo = $driveInfo[0]
        }
        
        # Se comprueba si se devolvió información del Drive y si contiene datos de cuota.
        if ($driveInfo -and $null -ne $driveInfo.Quota.Used) {
            $usedBytes = $driveInfo.Quota.Used
            if ($usedBytes -gt 0) {
                # Convertir bytes a Gigabytes (GB)
                $oneDriveSize = "{0:N2} GB" -f ($usedBytes / 1GB)
            } else {
                $oneDriveSize = "0.00 GB"
            }
        } else {
            # Esto ocurre si el usuario tiene licencia pero nunca ha accedido a su OneDrive o no lo tiene aprovisionado.
            $oneDriveSize = "No aprovisionado"
        }
    }
    catch {
        # Captura otros errores inesperados de conexión o permisos al intentar obtener la información de OneDrive.
        Write-Warning "No se pudo obtener la información de OneDrive para $upn. Error: $($_.Exception.Message)"
        $oneDriveSize = "Error"
    }
    
    # --- Crear registro para el informe ---
    $record = [PSCustomObject]@{
        "UserPrincipalName"    = $upn
        "Nombre"               = $user.DisplayName
        "TamañoBuzonPrincipal" = Format-MailboxSize -SizeValue $primaryMailboxSize
        "TamañoBuzonArchivo"   = Format-MailboxSize -SizeValue $archiveMailboxSize
        "UsoOneDrive"          = $oneDriveSize
    }

    $reportData += $record
}

Write-Progress -Activity "Recopilando datos de almacenamiento" -Completed

#endregion

#region Exportación y Desconexión

if ($reportData.Count -gt 0) {
    $timestamp = Get-Date -Format "yyyy-MM-dd"
    $fileName = "Reporte_Almacenamiento_M365_$timestamp.csv"
    $filePath = Join-Path -Path $PSScriptRoot -ChildPath $fileName

    try {
        $reportData | Export-Csv -Path $filePath -NoTypeInformation -Encoding UTF8 -Delimiter ";"
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "Informe generado exitosamente en:" -ForegroundColor Green
        Write-Host $filePath -ForegroundColor White
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
    }
    catch {
        Write-Error "Ocurrió un error al exportar el archivo CSV."
        Write-Error $_.Exception.Message
    }
}
else {
    Write-Warning "No se encontraron datos para generar un informe."
}

# --- Desconectar todas las sesiones ---
Write-Host "Desconectando de todos los servicios..."
if (Get-MgContext) { Disconnect-MgGraph }
if (Get-ConnectionInformation) { Disconnect-ExchangeOnline -Confirm:$false }
Write-Host "Proceso finalizado."

#endregion
