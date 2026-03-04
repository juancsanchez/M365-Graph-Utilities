# =====================================================================
# Script: Migración de SharePoint a Azure Files
# Versión: 5.0 - Configuración externalizada en configMigracion.json
#
# Uso:
#   1. Complete los valores en configMigracion.json (mismo directorio que este script)
#   2. Ejecute: .\Migracion-SharePoint-AzureFiles.ps1
#   3. Si el script se interrumpe, vuelva a ejecutarlo — retomará automáticamente
#      desde el último lote pendiente gracias al sistema de checkpoint.
#
# Estrategia de resiliencia (dos capas):
#   CAPA 1 - Checkpoint JSON:
#     Registra cada subcarpeta completada. Al reiniciar, las omite
#     automáticamente y continúa desde la primera pendiente.
#   CAPA 2 - AzCopy Job Resume:
#     Si AzCopy se interrumpe a mitad de una subida, detecta el Job ID
#     fallido y lo retoma archivo por archivo antes de continuar.
#
# Archivos generados en LocalStagingDrive (definido en configMigracion.json):
#   migration_checkpoint.json  → progreso por subcarpeta
#   migration_log.txt          → log completo con timestamps
# =====================================================================

# ---------------------------------------------------------
# 0. Pre-requisitos y Módulos
# ---------------------------------------------------------
Write-Host "Verificando el módulo PnP.PowerShell..." -ForegroundColor Cyan
if (!(Get-Module -ListAvailable -Name PnP.PowerShell)) {
    Write-Host "Instalando PnP.PowerShell..." -ForegroundColor Yellow
    Install-Module -Name PnP.PowerShell -Force -AllowClobber -Scope AllUsers
}
Import-Module PnP.PowerShell -ErrorAction Stop

# ---------------------------------------------------------
# 1. Carga de Configuración desde configMigracion.json
# ---------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir "configMigracion.json"

if (!(Test-Path $ConfigPath)) {
    Write-Host "ERROR: No se encontró el archivo de configuración en '$ConfigPath'." -ForegroundColor Red
    Write-Host "Cree el archivo configMigracion.json en el mismo directorio que este script." -ForegroundColor Yellow
    exit 1
}

try {
    $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "ERROR: El archivo configMigracion.json tiene un formato JSON inválido." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# Mapear variables desde la configuración
$SiteUrl = $Config.SiteUrl
$ClientId = $Config.ClientId
$LocalStagingDrive = $Config.LocalStagingDrive
$AzCopyPath = $Config.AzCopyPath
$AzureFileShareBaseUrl = $Config.AzureFileShareBaseUrl
$AzureSASToken = $Config.AzureSASToken
$TargetFolders = $Config.TargetFolders

# Validar que todos los campos requeridos estén presentes
$requiredFields = @("SiteUrl", "ClientId", "LocalStagingDrive", "AzCopyPath", "AzureFileShareBaseUrl", "AzureSASToken", "TargetFolders")
foreach ($field in $requiredFields) {
    if ([string]::IsNullOrWhiteSpace($Config.$field) -and $field -ne "TargetFolders") {
        Write-Host "ERROR: El campo '$field' está vacío en configMigracion.json." -ForegroundColor Red
        exit 1
    }
}
if ($TargetFolders.Count -eq 0) {
    Write-Host "ERROR: 'TargetFolders' está vacío en configMigracion.json. Defina al menos una carpeta." -ForegroundColor Red
    exit 1
}

$CheckpointFile = "$LocalStagingDrive\migration_checkpoint.json"
$LogFile = "$LocalStagingDrive\migration_log.txt"

# ---------------------------------------------------------
# 2. Funciones de Log y Checkpoint
# ---------------------------------------------------------
Function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp][$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    $color = switch ($Level) {
        "OK" { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "SECTION" { "Magenta" }
        default { "Cyan" }
    }
    Write-Host $line -ForegroundColor $color
}

Function Get-Checkpoint {
    if (Test-Path $CheckpointFile) {
        $data = Get-Content $CheckpointFile -Raw | ConvertFrom-Json
        $ht = @{}
        $data.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
        return $ht
    }
    return @{}
}

Function Set-Checkpoint {
    param([string]$BatchKey, [string]$Status)
    $checkpoint = Get-Checkpoint
    $checkpoint[$BatchKey] = $Status
    $checkpoint | ConvertTo-Json | Set-Content -Path $CheckpointFile
}

Function Get-CheckpointStatus {
    param([string]$BatchKey)
    $checkpoint = Get-Checkpoint
    if ($checkpoint.ContainsKey($BatchKey)) { return $checkpoint[$BatchKey] }
    return $null
}

# ---------------------------------------------------------
# 3. Función: Descarga Recursiva de SharePoint
# ---------------------------------------------------------
Function Copy-PnPFolderRecursive {
    param (
        [Parameter(Mandatory = $true)][string] $FolderRelativeUrl,
        [Parameter(Mandatory = $true)][string] $LocalTargetFolder
    )

    if (!(Test-Path -Path $LocalTargetFolder)) {
        New-Item -ItemType Directory -Path $LocalTargetFolder -Force | Out-Null
    }

    Write-Log "Descargando: $FolderRelativeUrl"

    try {
        $files = Get-PnPFolderItem -FolderSiteRelativeUrl $FolderRelativeUrl -ItemType File -ErrorAction Stop
        foreach ($file in $files) {
            Write-Host "    -> $($file.Name)" -ForegroundColor DarkGray
            Get-PnPFile -Url $file.ServerRelativeUrl -Path $LocalTargetFolder -FileName $file.Name -AsFile -Force
        }

        $subFolders = Get-PnPFolderItem -FolderSiteRelativeUrl $FolderRelativeUrl -ItemType Folder |
        Where-Object { $_.Name -ne "Forms" }

        foreach ($subFolder in $subFolders) {
            Copy-PnPFolderRecursive `
                -FolderRelativeUrl "$FolderRelativeUrl/$($subFolder.Name)" `
                -LocalTargetFolder (Join-Path $LocalTargetFolder $subFolder.Name)
        }
    }
    catch {
        Write-Log "No se pudo acceder a '$FolderRelativeUrl': $($_.Exception.Message)" "ERROR"
    }
}

# ---------------------------------------------------------
# 4. Función: Subir a Azure con soporte de Resume
# ---------------------------------------------------------
Function Send-FolderToAzure {
    param (
        [Parameter(Mandatory = $true)][string] $LocalFolderPath,
        [Parameter(Mandatory = $true)][string] $AzureDestinationName
    )

    $sourcePath = "$LocalFolderPath\*"
    $destinationUrl = "$AzureFileShareBaseUrl/$AzureDestinationName`?$AzureSASToken"

    Write-Log "Subiendo '$AzureDestinationName' a Azure..."

    $azCopyArgs = @(
        "copy",
        $sourcePath,
        $destinationUrl,
        "--recursive=true",
        "--put-md5"
    )

    & $AzCopyPath @azCopyArgs

    # CAPA 2: AzCopy Resume
    if ($LASTEXITCODE -ne 0) {
        Write-Log "AzCopy falló (código $LASTEXITCODE). Intentando resume del job más reciente..." "WARN"

        $azCopyLogPath = "$env:USERPROFILE\.azcopy"
        $latestJob = Get-ChildItem -Path $azCopyLogPath -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

        if ($latestJob) {
            $jobId = [System.IO.Path]::GetFileNameWithoutExtension($latestJob.Name)
            Write-Log "Retomando Job ID: $jobId" "WARN"

            & $AzCopyPath jobs resume $jobId "--destination-sas=$AzureSASToken"

            if ($LASTEXITCODE -eq 0) {
                Write-Log "Resume exitoso para '$AzureDestinationName'." "OK"
            }
            else {
                Write-Log "Resume también falló para '$AzureDestinationName'. Lote marcado como ERROR." "ERROR"
                return $false
            }
        }
        else {
            Write-Log "No se encontró un Job ID de AzCopy para retomar. Lote marcado como ERROR." "ERROR"
            return $false
        }
    }

    Write-Log "'$AzureDestinationName' transferido correctamente." "OK"

    Write-Log "Eliminando '$LocalFolderPath' del Staging..."
    Remove-Item -Path $LocalFolderPath -Recurse -Force
    Write-Log "Staging limpiado para '$AzureDestinationName'." "OK"

    return $true
}

# ---------------------------------------------------------
# 5. Validaciones previas
# ---------------------------------------------------------
if (!(Test-Path $AzCopyPath)) {
    Write-Host "ERROR: No se encontró azcopy.exe en '$AzCopyPath'." -ForegroundColor Red
    Write-Host "Descárguelo desde https://aka.ms/downloadazcopy-v10-windows" -ForegroundColor Yellow
    exit 1
}
if (!(Test-Path $LocalStagingDrive)) {
    New-Item -ItemType Directory -Path $LocalStagingDrive -Force | Out-Null
}

Write-Log "======================================================" "SECTION"
Write-Log " INICIO DE MIGRACIÓN - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "SECTION"
Write-Log " Configuración cargada desde: $ConfigPath" "SECTION"
Write-Log "======================================================" "SECTION"

$existingCheckpoint = Get-Checkpoint
if ($existingCheckpoint.Count -gt 0) {
    Write-Log "Checkpoint detectado con $($existingCheckpoint.Count) lote(s) ya procesado(s). Se omitirán." "WARN"
    Write-Log "Para reiniciar desde cero, elimine: $CheckpointFile" "WARN"
}

# ---------------------------------------------------------
# 6. Autenticación en SharePoint
# ---------------------------------------------------------
Write-Log "Autenticando en SharePoint (se abrirá ventana del navegador)..."
Connect-PnPOnline -Url $SiteUrl -Interactive -ClientId $ClientId

# ---------------------------------------------------------
# 7. Migración Parcial con Checkpoint
# ---------------------------------------------------------
$totalSuccess = 0
$totalSkipped = 0
$totalFailed = 0

foreach ($targetFolder in $TargetFolders) {

    $rootFolderName = ($targetFolder -split "/")[-1]
    Write-Log "==== Carpeta raíz: $targetFolder ====" "SECTION"

    $spSubFolders = Get-PnPFolderItem -FolderSiteRelativeUrl $targetFolder -ItemType Folder |
    Where-Object { $_.Name -ne "Forms" }

    $spRootFiles = Get-PnPFolderItem -FolderSiteRelativeUrl $targetFolder -ItemType File

    # --- Archivos sueltos en la raíz ---
    if ($spRootFiles.Count -gt 0) {
        $batchKey = "$rootFolderName/_raiz"
        $status = Get-CheckpointStatus -BatchKey $batchKey

        if ($status -eq "COMPLETADO") {
            Write-Log "OMITIDO (ya completado): $batchKey" "WARN"
            $totalSkipped++
        }
        else {
            $stagingPath = Join-Path $LocalStagingDrive "_raiz_$rootFolderName"
            if (!(Test-Path $stagingPath)) {
                New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
            }
            foreach ($file in $spRootFiles) {
                Get-PnPFile -Url $file.ServerRelativeUrl -Path $stagingPath -FileName $file.Name -AsFile -Force
            }
            $success = Send-FolderToAzure -LocalFolderPath $stagingPath -AzureDestinationName $rootFolderName
            if ($success) {
                Set-Checkpoint -BatchKey $batchKey -Status "COMPLETADO"
                $totalSuccess++
            }
            else {
                Set-Checkpoint -BatchKey $batchKey -Status "ERROR"
                $totalFailed++
            }
        }
    }

    # --- Subcarpetas de primer nivel ---
    foreach ($subFolder in $spSubFolders) {

        $batchKey = "$rootFolderName/$($subFolder.Name)"
        $spSubFolderUrl = "$targetFolder/$($subFolder.Name)"
        $stagingSubPath = Join-Path $LocalStagingDrive $subFolder.Name
        $azureDestName = "$rootFolderName/$($subFolder.Name)"

        $status = Get-CheckpointStatus -BatchKey $batchKey
        if ($status -eq "COMPLETADO") {
            Write-Log "OMITIDO (ya completado): $batchKey" "WARN"
            $totalSkipped++
            continue
        }

        Write-Log "---- Lote: $batchKey ----"
        Write-Log "  SharePoint : $spSubFolderUrl"
        Write-Log "  Staging    : $stagingSubPath"
        Write-Log "  Azure      : $AzureFileShareBaseUrl/$azureDestName"

        Copy-PnPFolderRecursive -FolderRelativeUrl $spSubFolderUrl -LocalTargetFolder $stagingSubPath

        $success = Send-FolderToAzure -LocalFolderPath $stagingSubPath -AzureDestinationName $azureDestName

        if ($success) {
            Set-Checkpoint -BatchKey $batchKey -Status "COMPLETADO"
            $totalSuccess++
        }
        else {
            Set-Checkpoint -BatchKey $batchKey -Status "ERROR"
            $totalFailed++
            Write-Log "El lote '$batchKey' quedó en ERROR. Al reiniciar el script se reintentará." "WARN"
        }
    }
}

# ---------------------------------------------------------
# 8. Resumen Final
# ---------------------------------------------------------
Write-Log "======================================================" "SECTION"
Write-Log " RESUMEN DE MIGRACIÓN" "SECTION"
Write-Log "======================================================" "SECTION"
Write-Log " Lotes completados  : $totalSuccess" "OK"
Write-Log " Lotes omitidos     : $totalSkipped (ya procesados en ejecución anterior)"
if ($totalFailed -gt 0) {
    Write-Log " Lotes con error    : $totalFailed" "ERROR"
    Write-Log " Revise el log completo en: $LogFile" "WARN"
    Write-Log " Al volver a ejecutar el script, los lotes con ERROR se reintentarán." "WARN"
    exit 1
}
else {
    Write-Log " Migración completada sin errores." "OK"
    Write-Log " Puede eliminar el checkpoint en: $CheckpointFile" "OK"
}