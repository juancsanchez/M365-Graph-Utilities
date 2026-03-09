<#
.SYNOPSIS
    Genera un reporte de inventario de todos los dispositivos administrados en Microsoft Intune,
    optimizado para tenants de alto volumen (decenas de miles de dispositivos).

.DESCRIPTION
    Este script se conecta a Microsoft Graph utilizando autenticación desatendida (certificado)
    y extrae un listado completo de todos los dispositivos registrados en Intune.

    OPTIMIZACIONES PARA TENANTS GRANDES:
    ─────────────────────────────────────
    1. PAGINACIÓN ROBUSTA: Usa Invoke-MgGraphRequest con $top=999 para maximizar el tamaño
       de cada página y reduce el número total de llamadas a la API. Sigue @odata.nextLink
       hasta agotar todos los registros.

    2. RETRY CON EXPONENTIAL BACKOFF: Los endpoints de Intune (deviceManagement) frecuentemente
       omiten el header 'Retry-After' en respuestas 429. El script implementa:
       - Lectura del header Retry-After cuando está disponible.
       - Exponential backoff con jitter aleatorio como fallback.
       - Máximo de 5 reintentos por solicitud antes de declarar error.
       Referencia: https://learn.microsoft.com/en-us/graph/throttling

    3. $SELECT EXPLÍCITO: Reduce el payload de cada respuesta al solicitar solo las propiedades
       necesarias. Esto acelera la respuesta y disminuye el riesgo de throttling.
       Las propiedades 'manufacturer', 'model' y 'serialNumber' son "non-default" y requieren
       $select para retornar valores reales.
       Referencia: https://learn.microsoft.com/en-us/graph/api/resources/intune-devices-manageddevice

    4. PROCESAMIENTO PARALELO: Una vez recopilados los dispositivos por lotes, el mapeo y
       transformación de datos se realiza con ForEach-Object -Parallel para aprovechar
       múltiples núcleos (requiere PowerShell 7+). Si se ejecuta en PowerShell 5.1,
       el script degrada automáticamente a procesamiento secuencial.

    5. ESCRITURA PROGRESIVA A DISCO: En lugar de acumular todo en memoria y escribir al final,
       el script escribe lotes de registros procesados al CSV incrementalmente.
       Esto evita el consumo excesivo de RAM en tenants con +50,000 dispositivos.

    Para cada dispositivo recopila:
    - Nombre del dispositivo
    - ID del dispositivo en Intune
    - UPN del usuario principal
    - Marca (Manufacturer)
    - Modelo
    - Estado de cumplimiento (Compliance)
    - Fecha del último check-in (Last Sync)
    - Sistema operativo y versión
    - Tipo de propiedad (Corporate / Personal)
    - Número de serie

.REQUIREMENTS
    - PowerShell 7+ (recomendado para procesamiento paralelo; compatible con 5.1 en modo secuencial).
    - Módulo de PowerShell: Microsoft.Graph.Authentication
    - Archivo 'config.json' en la carpeta raíz del repositorio con tenantId, clientId y certThumbprint.
    - Permiso de API (Application): DeviceManagementManagedDevices.Read.All

.EXAMPLE
    .\sc-Generar-ReporteInventarioDispositivos.ps1

.NOTES
    Autor: Juan Sánchez
    Fecha: 2026-03-09
    Versión: 2.0 - Optimización para tenants grandes (Pagination + Retry + Parallel + Streaming)
#>

[CmdletBinding()]
param ()

# ─────────────────────────────────────────────
# 1. MÓDULOS
# ─────────────────────────────────────────────
$requiredModules = @("Microsoft.Graph.Authentication")
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Instalando módulo '$module'..." -ForegroundColor Yellow
        try {
            Install-Module $module -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        }
        catch {
            Write-Error "No se pudo instalar el módulo '$module'. Instálelo manualmente."
            return
        }
    }
}

# ─────────────────────────────────────────────
# 2. FUNCIÓN: INVOKE CON RETRY Y BACKOFF
#    Maneja errores 429, 503, 504 con reintentos
#    inteligentes. Los endpoints de Intune a menudo
#    omiten el header Retry-After, por lo que se
#    implementa exponential backoff como fallback.
# ─────────────────────────────────────────────

function Invoke-GraphWithRetry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [string]$Method = "GET",

        [int]$MaxRetries = 5,

        [int]$BaseDelaySeconds = 5
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $response = Invoke-MgGraphRequest -Method $Method -Uri $Uri -ErrorAction Stop -OutputType Hashtable
            return $response
        }
        catch {
            $errorMessage = $_.Exception.Message
            $isTransientError = $errorMessage -match "429" -or
            $errorMessage -match "Too Many Requests" -or
            $errorMessage -match "503" -or
            $errorMessage -match "504" -or
            $errorMessage -match "Service Unavailable" -or
            $errorMessage -match "Gateway Timeout"

            if ($isTransientError -and $attempt -le $MaxRetries) {
                # Intentar leer el header Retry-After de la respuesta
                $delay = 0
                try {
                    $innerResponse = $_.Exception.Response
                    if ($innerResponse -and $innerResponse.Headers) {
                        $retryAfterValues = $null
                        if ($innerResponse.Headers.TryGetValues("Retry-After", [ref]$retryAfterValues)) {
                            $retryAfterValue = $retryAfterValues | Select-Object -First 1
                            if ([int]::TryParse($retryAfterValue, [ref]$delay)) {
                                # Usar el valor que sugiere la API
                            }
                        }
                    }
                }
                catch {
                    # Si no se puede leer el header, usar backoff
                }

                # Fallback: Exponential backoff con jitter aleatorio
                if ($delay -le 0) {
                    $exponentialDelay = [math]::Pow(2, $attempt) * $BaseDelaySeconds
                    $jitter = Get-Random -Minimum 1 -Maximum 5
                    $delay = [math]::Min($exponentialDelay + $jitter, 120) # Máximo 2 minutos
                }

                Write-Warning "Throttling detectado (intento $attempt/$MaxRetries). Esperando $delay segundos antes de reintentar..."
                Start-Sleep -Seconds $delay
            }
            else {
                if ($attempt -gt $MaxRetries) {
                    Write-Error "Se alcanzó el máximo de reintentos ($MaxRetries) para la solicitud."
                }
                throw $_
            }
        }
    }
}

# ─────────────────────────────────────────────
# 3. FUNCIÓN: TRANSFORMAR DISPOSITIVO
#    Mapea las propiedades crudas de Graph API
#    a un objeto limpio para el reporte CSV.
#    Se usa en el modo secuencial (PowerShell 5.1).
# ─────────────────────────────────────────────

function ConvertTo-DeviceReportObject {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Device
    )

    # Traducir Ownership
    $ownership = switch ($Device.managedDeviceOwnerType) {
        "company" { "Corporate" }
        "personal" { "Personal" }
        default { $Device.managedDeviceOwnerType }
    }

    # Traducir Compliance
    $compliance = switch ($Device.complianceState) {
        "compliant" { "Compliant" }
        "noncompliant" { "Non-compliant" }
        "conflict" { "Conflict" }
        "error" { "Error" }
        "inGracePeriod" { "In Grace Period" }
        "configManager" { "ConfigManager" }
        "unknown" { "Unknown" }
        default { $Device.complianceState }
    }

    # Formatear fecha de último check-in
    $lastCheckIn = "N/A"
    if ($Device.lastSyncDateTime) {
        try {
            $lastCheckIn = ([datetime]$Device.lastSyncDateTime).ToString("yyyy-MM-dd HH:mm:ss")
        }
        catch {
            $lastCheckIn = $Device.lastSyncDateTime
        }
    }

    return [PSCustomObject]@{
        "Nombre"        = if ($Device.deviceName) { $Device.deviceName }        else { "N/A" }
        "DeviceID"      = $Device.id
        "Primary User"  = if ($Device.userPrincipalName) { $Device.userPrincipalName }  else { "Sin usuario" }
        "Marca"         = if ($Device.manufacturer) { $Device.manufacturer }       else { "N/A" }
        "Modelo"        = if ($Device.model) { $Device.model }              else { "N/A" }
        "Compliance"    = $compliance
        "Last Check-In" = $lastCheckIn
        "SO"            = if ($Device.operatingSystem) { $Device.operatingSystem }    else { "N/A" }
        "Versión SO"    = if ($Device.osVersion) { $Device.osVersion }          else { "N/A" }
        "Ownership"     = $ownership
        "Serial Number" = if ($Device.serialNumber) { $Device.serialNumber }       else { "N/A" }
    }
}

# ─────────────────────────────────────────────
# 4. CONEXIÓN
# ─────────────────────────────────────────────
$configFilePath = Join-Path -Path (Split-Path $PSScriptRoot -Parent) -ChildPath "config.json"
if (-not (Test-Path $configFilePath)) {
    Write-Error "No se encontró el archivo 'config.json' en: $configFilePath"
    return
}

try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    Write-Host "Conectando a Microsoft Graph con certificado..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $config.tenantId -AppId $config.clientId -CertificateThumbprint $config.certThumbprint -ErrorAction Stop
    Write-Host "Conexión establecida exitosamente.`n" -ForegroundColor Green
}
catch {
    Write-Error "Error crítico al conectar a Microsoft Graph: $($_.Exception.Message)"
    return
}

# ─────────────────────────────────────────────
# 5. PREPARAR ARCHIVO DE SALIDA
#    Se inicializa el CSV con encabezados para
#    permitir escritura progresiva (streaming).
# ─────────────────────────────────────────────
$timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
$csvOutput = Join-Path -Path $PSScriptRoot -ChildPath "Reporte_Inventario_Dispositivos_Intune_$timestamp.csv"

# Determinar encoding correcto (BOM para compatibilidad con Excel y tildes)
$encoding = "UTF8"
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $encoding = "utf8BOM"
}

# Escribir encabezados del CSV
$csvHeaders = '"Nombre","DeviceID","Primary User","Marca","Modelo","Compliance","Last Check-In","SO","Versión SO","Ownership","Serial Number"'
$csvHeaders | Out-File -FilePath $csvOutput -Encoding $encoding -Force

# ─────────────────────────────────────────────
# 6. OBTENER DISPOSITIVOS CON PAGINACIÓN ROBUSTA
#    - $top=999 maximiza el tamaño de cada página.
#    - $select reduce payload y fuerza propiedades
#      "non-default" (manufacturer, model, serialNumber).
#    - @odata.nextLink se sigue hasta agotar datos.
#    - Cada lote se procesa y escribe a disco
#      inmediatamente para liberar memoria.
# ─────────────────────────────────────────────
Write-Host "Obteniendo inventario de dispositivos desde Intune..." -ForegroundColor Cyan
Write-Host "Configuración: `$top=999, endpoint beta, `$select optimizado." -ForegroundColor Gray

$selectProperties = @(
    "id",
    "deviceName",
    "userPrincipalName",
    "manufacturer",
    "model",
    "complianceState",
    "lastSyncDateTime",
    "operatingSystem",
    "osVersion",
    "managedDeviceOwnerType",
    "serialNumber"
) -join ","

$devicesUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$top=999&`$select=$selectProperties"

$totalDeviceCount = 0
$totalWrittenCount = 0
$pageNumber = 0
$batchSize = 500            # Dispositivos a acumular antes de procesar y escribir
$deviceBatch = [System.Collections.Generic.List[hashtable]]::new()
$isPwsh7 = $PSVersionTable.PSVersion.Major -ge 7

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

while ($devicesUri) {
    $pageNumber++

    try {
        $response = Invoke-GraphWithRetry -Uri $devicesUri -MaxRetries 5 -BaseDelaySeconds 5
    }
    catch {
        Write-Error "Error fatal al obtener la página $pageNumber de dispositivos: $($_.Exception.Message)"
        Write-Warning "Se escribirán los datos recopilados hasta este punto."
        break
    }

    $pageDevices = $response.value
    $pageCount = if ($pageDevices) { $pageDevices.Count } else { 0 }
    $totalDeviceCount += $pageCount

    # Acumular dispositivos en el lote actual
    foreach ($device in $pageDevices) {
        $deviceBatch.Add($device)
    }

    # Indicador de progreso
    $elapsed = $stopwatch.Elapsed.ToString("hh\:mm\:ss")
    Write-Host "  Página $pageNumber procesada ($pageCount dispositivos) | Total acumulado: $totalDeviceCount | Tiempo: $elapsed" -ForegroundColor Gray

    # Siguiente página
    $devicesUri = $response."@odata.nextLink"

    # ─── PROCESAR Y ESCRIBIR LOTE SI ALCANZA EL UMBRAL O ES LA ÚLTIMA PÁGINA ───
    if ($deviceBatch.Count -ge $batchSize -or -not $devicesUri) {

        if ($deviceBatch.Count -eq 0) { continue }

        Write-Host "  Procesando y escribiendo lote de $($deviceBatch.Count) dispositivos a disco..." -ForegroundColor Yellow

        $processedRecords = $null

        # ─── MODO PARALELO (PowerShell 7+) ───
        if ($isPwsh7) {
            $processedRecords = $deviceBatch | ForEach-Object -ThrottleLimit 10 -Parallel {
                $d = $_

                # Traducir Ownership
                $ownership = switch ($d.managedDeviceOwnerType) {
                    "company" { "Corporate" }
                    "personal" { "Personal" }
                    default { $d.managedDeviceOwnerType }
                }

                # Traducir Compliance
                $compliance = switch ($d.complianceState) {
                    "compliant" { "Compliant" }
                    "noncompliant" { "Non-compliant" }
                    "conflict" { "Conflict" }
                    "error" { "Error" }
                    "inGracePeriod" { "In Grace Period" }
                    "configManager" { "ConfigManager" }
                    "unknown" { "Unknown" }
                    default { $d.complianceState }
                }

                # Formatear fecha
                $lastCheckIn = "N/A"
                if ($d.lastSyncDateTime) {
                    try {
                        $lastCheckIn = ([datetime]$d.lastSyncDateTime).ToString("yyyy-MM-dd HH:mm:ss")
                    }
                    catch {
                        $lastCheckIn = $d.lastSyncDateTime
                    }
                }

                [PSCustomObject]@{
                    "Nombre"        = if ($d.deviceName) { $d.deviceName }        else { "N/A" }
                    "DeviceID"      = $d.id
                    "Primary User"  = if ($d.userPrincipalName) { $d.userPrincipalName }  else { "Sin usuario" }
                    "Marca"         = if ($d.manufacturer) { $d.manufacturer }       else { "N/A" }
                    "Modelo"        = if ($d.model) { $d.model }              else { "N/A" }
                    "Compliance"    = $compliance
                    "Last Check-In" = $lastCheckIn
                    "SO"            = if ($d.operatingSystem) { $d.operatingSystem }    else { "N/A" }
                    "Versión SO"    = if ($d.osVersion) { $d.osVersion }          else { "N/A" }
                    "Ownership"     = $ownership
                    "Serial Number" = if ($d.serialNumber) { $d.serialNumber }       else { "N/A" }
                }
            }
        }
        # ─── MODO SECUENCIAL (PowerShell 5.1) ───
        else {
            $processedRecords = foreach ($d in $deviceBatch) {
                ConvertTo-DeviceReportObject -Device $d
            }
        }

        # ─── ESCRITURA INCREMENTAL AL CSV (APPEND) ───
        # Se construyen las líneas manualmente con StringBuilder para máximo rendimiento.
        # Export-Csv con -Append realiza validación de schema en cada llamada, lo cual
        # es ineficiente para escritura frecuente de lotes grandes.
        $csvLines = [System.Text.StringBuilder]::new()
        foreach ($record in $processedRecords) {
            $line = '"{0}","{1}","{2}","{3}","{4}","{5}","{6}","{7}","{8}","{9}","{10}"' -f `
            ($record.Nombre -replace '"', '""'),
            ($record.DeviceID -replace '"', '""'),
            ($record."Primary User" -replace '"', '""'),
            ($record.Marca -replace '"', '""'),
            ($record.Modelo -replace '"', '""'),
            ($record.Compliance -replace '"', '""'),
            ($record."Last Check-In" -replace '"', '""'),
            ($record.SO -replace '"', '""'),
            ($record."Versión SO" -replace '"', '""'),
            ($record.Ownership -replace '"', '""'),
            ($record."Serial Number" -replace '"', '""')
            [void]$csvLines.AppendLine($line)
        }

        # Append al archivo existente (los encabezados ya se escribieron en el paso 5)
        $csvLines.ToString() | Out-File -FilePath $csvOutput -Encoding $encoding -Append -NoNewline

        $totalWrittenCount += $processedRecords.Count
        Write-Host "  Lote escrito. Registros en disco: $totalWrittenCount" -ForegroundColor Green

        # Liberar memoria del lote procesado
        $deviceBatch.Clear()
        [System.GC]::Collect()
    }
}

$stopwatch.Stop()

# ─────────────────────────────────────────────
# 7. RESUMEN FINAL
# ─────────────────────────────────────────────
$elapsedTotal = $stopwatch.Elapsed.ToString("hh\:mm\:ss")

Write-Host "`n════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " REPORTE DE INVENTARIO COMPLETADO" -ForegroundColor White
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Dispositivos obtenidos de la API : $totalDeviceCount" -ForegroundColor Green
Write-Host " Registros escritos en el CSV     : $totalWrittenCount" -ForegroundColor Green
Write-Host " Páginas de API procesadas        : $pageNumber" -ForegroundColor Green
Write-Host " Tiempo total de ejecución        : $elapsedTotal" -ForegroundColor Green
Write-Host " Modo de procesamiento            : $(if ($isPwsh7) { 'Paralelo (PowerShell 7+)' } else { 'Secuencial (PowerShell 5.1)' })" -ForegroundColor Green
Write-Host " Archivo de salida                : $csvOutput" -ForegroundColor White
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan

# Validación de integridad
if ($totalDeviceCount -ne $totalWrittenCount) {
    Write-Warning "ADVERTENCIA: La cantidad de dispositivos obtenidos ($totalDeviceCount) no coincide con los escritos ($totalWrittenCount)."
    Write-Warning "Esto puede indicar que ocurrieron errores durante el procesamiento de algún lote."
}
else {
    Write-Host "`nIntegridad verificada: Todos los dispositivos fueron escritos correctamente." -ForegroundColor Green
}

# ─────────────────────────────────────────────
# 8. DESCONEXIÓN
# ─────────────────────────────────────────────
if (Get-MgContext) {
    Write-Host "`nDesconectando de Microsoft Graph..."
    Disconnect-MgGraph | Out-Null
}