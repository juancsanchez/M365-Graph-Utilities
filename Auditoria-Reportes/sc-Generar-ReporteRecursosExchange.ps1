<#
.SYNOPSIS
    Genera un informe de todos los recursos de Exchange Online: salas de reuniones y equipos.

.DESCRIPTION
    Este script se conecta a Exchange Online utilizando un App Registration y un certificado
    para operar de forma desatendida. Extrae todos los buzones de tipo recurso del tenant
    (RoomMailbox y EquipmentMailbox) y enriquece cada registro con su configuración de
    calendario (CalendarProcessing), capacidad, delegados y estado del buzón.

    Para cada recurso recopila:
    - Nombre para mostrar, alias y tipo (Sala / Equipo)
    - User Principal Name y dirección de correo primaria
    - Capacidad (solo para salas)
    - Si acepta reuniones automáticamente (AutomateProcessing)
    - Si permite conflictos de horario (AllowConflicts)
    - Si está habilitado para responder a convocatorias externas (AddOrganizerToSubject)
    - Límite de duración máxima de reunión
    - Delegados con permiso FullAccess y SendAs
    - Tamaño del buzón y último acceso
    - Estado habilitado/deshabilitado

    El resultado se exporta en un archivo CSV con todos los datos recopilados.

.NOTES
    Autor: Juan Sánchez
    Fecha: 2026-03-09

    Requisitos de Módulos de PowerShell:
    - ExchangeOnlineManagement

    El App Registration debe tener los siguientes permisos:
    - Office 365 Exchange Online → Exchange.ManageAsApp (Application)
    - El Service Principal debe tener asignado el rol 'View-Only Recipients' en Exchange Online.

    CONFIGURACIÓN ÚNICA DEL SERVICE PRINCIPAL EN EXCHANGE ONLINE
    -------------------------------------------------------------
    Exchange Online mantiene su propio registro de Service Principals, independiente de Entra ID.
    Antes de ejecutar este script por primera vez, un Exchange Admin debe registrar el SP
    y asignarle el rol. Este proceso solo se realiza una vez por tenant.

    Paso 1 — Conectarse a Exchange Online de forma interactiva (como Exchange Admin o Global Admin):

        Connect-ExchangeOnline

    Paso 2 — Registrar el Service Principal en Exchange Online.
    Requiere el Application (Client) ID y el Object ID de la Enterprise Application
    (Entra ID → Enterprise Applications → tu app → Overview → Object ID):

        New-ServicePrincipal `
            -AppId      "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `   # clientId en config.json
            -ObjectId   "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `   # Object ID de Enterprise Applications
            -DisplayName "Nombre-De-Tu-App"

    Paso 3 — Asignar el rol 'View-Only Recipients' al Service Principal:

        New-ManagementRoleAssignment `
            -Role "View-Only Recipients" `
            -App  "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"           # clientId en config.json

    Paso 4 — Verificar que el rol quedó asignado:

        Get-ManagementRoleAssignment -RoleAssignee "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" |
            Select-Object Name, Role, RoleAssigneeType

    NOTA: El parámetro -App de New-ManagementRoleAssignment requiere
    ExchangeOnlineManagement v3.0 o superior. Si el comando no lo reconoce, ejecute:
        Update-Module ExchangeOnlineManagement
#>

#region Conexión y Prerrequisitos

# Instalar módulo si no existe
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host "El módulo 'ExchangeOnlineManagement' no está instalado. Intentando instalar..." -ForegroundColor Yellow
    try {
        Install-Module ExchangeOnlineManagement -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    catch {
        Write-Error "No se pudo instalar el módulo 'ExchangeOnlineManagement'. Instálelo manualmente y vuelva a ejecutar el script."
        return
    }
}

# Cargar parámetros desde config.json
$configFilePath = Join-Path -Path (Split-Path $PSScriptRoot -Parent) -ChildPath "config.json"

if (-not (Test-Path $configFilePath)) {
    Write-Error "El archivo de configuración '$configFilePath' no fue encontrado."
    Write-Error "Asegúrese de que exista y contenga: tenantId, clientId, organizationName, certThumbprint."
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    $clientId = $config.clientId
    $organizationName = $config.organizationName
    $certThumbprint = $config.certThumbprint
}
catch {
    Write-Error "No se pudo leer o procesar el archivo 'config.json'. Verifique que el formato JSON sea correcto."
    Write-Error $_.Exception.Message
    return
}

# Conexión a Exchange Online
try {
    Write-Host "Conectando a Exchange Online con certificado..." -ForegroundColor Cyan
    Connect-ExchangeOnline -AppId $clientId -CertificateThumbprint $certThumbprint -Organization $organizationName -ShowBanner:$false
    Write-Host "Conexión a Exchange Online exitosa." -ForegroundColor Green
}
catch {
    Write-Error "Falló la conexión a Exchange Online. Verifique los parámetros en config.json, el certificado y el rol asignado al Service Principal."
    Write-Error $_.Exception.Message
    return
}

#endregion

#region Función auxiliar para formatear tamaños

function Format-MailboxSize {
    param($SizeValue)
    if ($null -eq $SizeValue -or $SizeValue -eq "" -or $SizeValue -in @("N/A", "Sin buzón", "Error")) {
        return $SizeValue
    }
    if ($SizeValue -is [string] -and $SizeValue -match '\(([\d,]+) bytes\)') {
        $bytes = [double]($matches[1] -replace ',', '')
        return "{0:N2} GB" -f ($bytes / 1GB)
    }
    try {
        return "{0:N2} GB" -f ([double]$SizeValue / 1GB)
    }
    catch {
        return $SizeValue.ToString()
    }
}

#endregion

#region Recopilación de Datos

$ProgressPreference = 'Continue'
$reportData = @()

Write-Host "Obteniendo buzones de recursos (salas y equipos)..." -ForegroundColor Cyan

try {
    # Recuperar todos los buzones de recurso del tenant en una sola llamada
    $resourceMailboxes = Get-Mailbox -RecipientTypeDetails RoomMailbox, EquipmentMailbox -ResultSize Unlimited `
        -Properties DisplayName, Alias, UserPrincipalName, PrimarySmtpAddress, RecipientTypeDetails,
    ResourceCapacity, AccountDisabled, WhenMailboxCreated
}
catch {
    Write-Error "No se pudo obtener la lista de recursos. Verifique los permisos del Service Principal."
    Write-Error $_.Exception.Message
    if (Get-ConnectionInformation) { Disconnect-ExchangeOnline -Confirm:$false }
    return
}

$total = $resourceMailboxes.Count
Write-Host "Se encontraron $total recursos. Procesando configuración de cada uno..." -ForegroundColor Cyan

$i = 0
foreach ($resource in $resourceMailboxes) {
    $i++
    Write-Progress -Activity "Procesando recursos de Exchange" `
        -Status "($i/$total) $($resource.DisplayName)" `
        -PercentComplete (($i / $total) * 100)

    # --- Tipo legible ---
    $resourceType = if ($resource.RecipientTypeDetails -eq "RoomMailbox") { "Sala" } else { "Equipo" }

    # --- Configuración del calendario ---
    $autoProcess = "N/A"
    $allowConflicts = "N/A"
    $maxDuration = "N/A"
    $addOrganizer = "N/A"

    try {
        $calProc = Get-CalendarProcessing -Identity $resource.UserPrincipalName -ErrorAction Stop
        $autoProcess = $calProc.AutomateProcessing    # AutoAccept | None | AutoUpdate
        $allowConflicts = if ($calProc.AllowConflicts) { "Sí" } else { "No" }
        $maxDuration = if ($calProc.MaximumDurationInMinutes -gt 0) { "$($calProc.MaximumDurationInMinutes) min" } else { "Sin límite" }
        $addOrganizer = if ($calProc.AddOrganizerToSubject) { "Sí" } else { "No" }
    }
    catch {
        Write-Warning "No se pudo obtener CalendarProcessing para $($resource.DisplayName): $($_.Exception.Message)"
    }

    # --- Delegados con FullAccess ---
    $fullAccessDelegates = "Ninguno"
    try {
        $faPerms = Get-MailboxPermission -Identity $resource.UserPrincipalName -ErrorAction SilentlyContinue |
        Where-Object { $_.AccessRights -contains "FullAccess" -and -not $_.IsInherited -and $_.User -notmatch "NT AUTHORITY" }
        if ($faPerms) {
            $fullAccessDelegates = ($faPerms.User -join "; ")
        }
    }
    catch { }

    # --- Delegados con SendAs ---
    $sendAsDelegates = "Ninguno"
    try {
        $saPerms = Get-RecipientPermission -Identity $resource.UserPrincipalName -ErrorAction SilentlyContinue |
        Where-Object { $_.AccessRights -contains "SendAs" -and $_.Trustee -notmatch "NT AUTHORITY" }
        if ($saPerms) {
            $sendAsDelegates = ($saPerms.Trustee -join "; ")
        }
    }
    catch { }

    # --- Estadísticas del buzón ---
    $mailboxSize = "N/A"
    $lastUserAction = "N/A"

    try {
        $stats = Get-MailboxStatistics -Identity $resource.UserPrincipalName -ErrorAction SilentlyContinue
        if ($stats -and $stats.TotalItemSize) {
            $mailboxSize = Format-MailboxSize -SizeValue $stats.TotalItemSize.ToString()
        }
        if ($stats -and $stats.LastUserActionTime) {
            $lastUserAction = Get-Date $stats.LastUserActionTime -Format "yyyy-MM-dd HH:mm"
        }
    }
    catch { }

    # --- Construir registro ---
    $reportData += [PSCustomObject]@{
        "Nombre"              = $resource.DisplayName
        "Alias"               = $resource.Alias
        "Tipo"                = $resourceType
        "Correo"              = $resource.PrimarySmtpAddress
        "UPN"                 = $resource.UserPrincipalName
        "Capacidad"           = if ($resource.RecipientTypeDetails -eq "RoomMailbox") {
            if ($resource.ResourceCapacity -gt 0) { $resource.ResourceCapacity } else { "No definida" }
        }
        else { "N/A" }
        "Procesamiento"       = $autoProcess
        "PermiteConflictos"   = $allowConflicts
        "DuracionMaxima"      = $maxDuration
        "AgregaOrganizador"   = $addOrganizer
        "DelegadosFullAccess" = $fullAccessDelegates
        "DelegadosSendAs"     = $sendAsDelegates
        "TamanoBuzon"         = $mailboxSize
        "UltimoUso"           = $lastUserAction
        "CreadoEl"            = if ($resource.WhenMailboxCreated) { Get-Date $resource.WhenMailboxCreated -Format "yyyy-MM-dd" } else { "N/A" }
        "Estado"              = if ($resource.AccountDisabled) { "Deshabilitado" } else { "Habilitado" }
    }
}

Write-Progress -Activity "Procesando recursos de Exchange" -Completed

#endregion

#region Exportación y Desconexión

if ($reportData.Count -gt 0) {
    $timestamp = Get-Date -Format "yyyy-MM-dd"
    $fileName = "Reporte_Recursos_Exchange_$timestamp.csv"
    $filePath = Join-Path -Path $PSScriptRoot -ChildPath $fileName

    try {
        $reportData | Export-Csv -Path $filePath -NoTypeInformation -Encoding UTF8 -Delimiter ";"
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "Informe generado exitosamente en:" -ForegroundColor Green
        Write-Host $filePath -ForegroundColor White
        Write-Host "Total de recursos procesados: $($reportData.Count)" -ForegroundColor Green
        Write-Host "  Salas   : $(($reportData | Where-Object { $_.Tipo -eq 'Sala' }).Count)" -ForegroundColor Green
        Write-Host "  Equipos : $(($reportData | Where-Object { $_.Tipo -eq 'Equipo' }).Count)" -ForegroundColor Green
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
    }
    catch {
        Write-Error "Ocurrió un error al exportar el archivo CSV."
        Write-Error $_.Exception.Message
    }
}
else {
    Write-Warning "No se encontraron buzones de recurso en el tenant."
}

Write-Host "Desconectando de Exchange Online..."
if (Get-ConnectionInformation) { Disconnect-ExchangeOnline -Confirm:$false }
Write-Host "Proceso finalizado."

#endregion