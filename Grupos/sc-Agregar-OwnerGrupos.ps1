<#
.SYNOPSIS
    Agrega un usuario o un Service Principal (Aplicación) como propietario a múltiples grupos de Microsoft Entra ID desde un archivo Excel.

.DESCRIPTION
    Este script se conecta a Microsoft Graph utilizando un certificado para la autenticación desatendida. Lee un archivo de Excel 
    que contiene los grupos y agrega el principal especificado (usuario o aplicación) como propietario a cada uno.
    
    El script prioriza la búsqueda de grupos por su Object ID. Si no lo encuentra, busca por el nombre exacto del grupo.
    Al finalizar, genera un reporte en CSV con el estado (éxito, error o advertencia) de la operación para cada grupo.

.PARAMETER PrincipalId
    El identificador del principal que se agregará como propietario.
    - Para una Aplicación Empresarial (Enterprise App), utilice el 'Application (client) ID'.
    - Para un usuario, utilice su User Principal Name (UPN), por ejemplo, 'usuario@dattics.com'.

.PARAMETER ExcelFilePath
    La ruta completa al archivo de Excel (.xlsx) que contiene la lista de grupos a procesar.
    IMPORTANTE: El archivo de Excel debe tener obligatoriamente dos columnas con los siguientes encabezados exactos:
    - 'Group': Contiene el nombre para mostrar (DisplayName) del grupo.
    - 'Object ID': Contiene el ID del objeto del grupo en Microsoft Entra ID.

.PARAMETER PrincipalType
    (Opcional) Define el tipo de principal. Si no se especifica, el script desplegará un menú interactivo para seleccionarlo.
    - 'User': Para una cuenta de usuario.
    - 'ServicePrincipal': Para una Aplicación Empresarial.

.REQUIREMENTS
    - Módulos de PowerShell: Microsoft.Graph, ImportExcel.
    - Permiso de API de Microsoft Graph: GroupMember.ReadWrite.All.
    - Un archivo 'config.json' en la misma carpeta con tenantId, clientId y certThumbprint.

.EXAMPLE
    # Ejemplo 1: Ejecución interactiva (El script mostrará un menú para seleccionar el tipo de principal)
    .\sc-Agregar-OwnerGrupos.ps1 -PrincipalId "usuario.demo@dattics.com" -ExcelFilePath "C:\Temp\Grupos.xlsx"
    
.EXAMPLE
    # Ejemplo 2: Ejecución desatendida (Ideal para automatización en Power Automate o Tareas Programadas)
    .\sc-Agregar-OwnerGrupos.ps1 -PrincipalId "0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d" -PrincipalType ServicePrincipal -ExcelFilePath "C:\Temp\Grupos.xlsx"

.NOTES
    Autor: Juan Sánchez
    Fecha: 2026-02-23
    Versión: 4.2 (Agregado menú de selección interactiva para PrincipalType)
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Para Aplicaciones, ingrese el App ID. Para Usuarios, ingrese el UPN.")]
    [string]$PrincipalId,

    [Parameter(Mandatory = $true, HelpMessage = "Ruta al archivo Excel. Debe contener las columnas 'Group' y 'Object ID'.")]
    [string]$ExcelFilePath,
    
    [Parameter(Mandatory = $false, HelpMessage = "Opcional. Especifique el tipo: 'User' o 'ServicePrincipal'. Si se omite, se solicitará en un menú interactivo.")]
    [ValidateSet('User', 'ServicePrincipal')]
    [string]$PrincipalType
)

# --- INICIO: SELECCIÓN INTERACTIVA DEL TIPO DE PRINCIPAL ---
if ([string]::IsNullOrWhiteSpace($PrincipalType)) {
    Write-Host "`n"
    $titulo = "Tipo de Principal"
    $mensaje = "Seleccione el tipo de principal que corresponde al ID ingresado ($PrincipalId):"
    
    $opciones = [System.Management.Automation.Host.ChoiceDescription[]] @(
        [System.Management.Automation.Host.ChoiceDescription]::new("&Usuario", "Cuenta de usuario normal (UPN)."),
        [System.Management.Automation.Host.ChoiceDescription]::new("&Service Principal", "Aplicación Empresarial (App ID).")
    )
    
    # El valor '0' indica que "Usuario" es la opción por defecto
    $seleccion = $host.UI.PromptForChoice($titulo, $mensaje, $opciones, 0)

    $PrincipalType = if ($seleccion -eq 0) { 'User' } else { 'ServicePrincipal' }
    Write-Host "Tipo seleccionado: $PrincipalType`n" -ForegroundColor Cyan
}
# --- FIN: SELECCIÓN INTERACTIVA ---

# --- INICIO: VERIFICACIÓN DE PRERREQUISITOS ---
$requiredModules = @("Microsoft.Graph", "ImportExcel")
foreach ($moduleName in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Write-Host "Instalando módulo '$moduleName'..." -ForegroundColor Yellow
        try {
            Install-Module $moduleName -Scope CurrentUser -Repository PSGallery -Force
        }
        catch {
            Write-Error "No se pudo instalar el módulo '$moduleName'. Por favor, instálelo manualmente."
            return
        }
    }
}

# --- INICIO: BLOQUE DE CONEXIÓN Y CONFIGURACIÓN ---
$configFilePath = Join-Path -Path (Split-Path $PSScriptRoot -Parent) -ChildPath "config.json"
if (-not (Test-Path $configFilePath)) {
    Write-Error "Archivo de configuración '$configFilePath' no encontrado."
    return
}
try {
    $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
    $tenantId = $config.tenantId
    $clientId = $config.clientId
    $certThumbprint = $config.certThumbprint
}
catch {
    Write-Error "Error al leer 'config.json'. Verifique su formato."
    return
}

try {
    Write-Host "Conectando a Microsoft Graph con certificado..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $tenantId -AppId $clientId -CertificateThumbprint $certThumbprint
    Write-Host "Conexión exitosa." -ForegroundColor Green
}
catch {
    Write-Error "Falló la conexión a Microsoft Graph. Verifique los detalles en config.json y el certificado."
    return
}

# --- FIN: BLOQUE DE CONEXIÓN ---

# --- INICIO: LÓGICA PRINCIPAL ---
$reportData = [System.Collections.Generic.List[object]]::new()

try {
    # 1. Validar la existencia del archivo Excel
    if (-not (Test-Path -Path $ExcelFilePath)) {
        throw "El archivo de Excel no fue encontrado en la ruta: '$ExcelFilePath'"
    }

    # 2. Validar que el principal (usuario o SP) a agregar exista
    Write-Host "Verificando el principal '$PrincipalId' (Tipo: $PrincipalType)..."
    $principalToAdd = $null
    
    if ($PrincipalType -eq 'User') {
        $principalToAdd = Get-MgUser -UserId $PrincipalId -Property Id, DisplayName, UserPrincipalName -ErrorAction SilentlyContinue
    }
    elseif ($PrincipalType -eq 'ServicePrincipal') {
        $principalToAdd = Get-MgServicePrincipal -Filter "appId eq '$PrincipalId'" -Property Id, DisplayName, AppId -ErrorAction SilentlyContinue
    }

    if (-not $principalToAdd) {
        throw "El principal con ID '$PrincipalId' y tipo '$PrincipalType' no fue encontrado."
    }
    $principalDisplayName = if ($principalToAdd.DisplayName) { $principalToAdd.DisplayName } else { $principalToAdd.AppId }
    Write-Host "Principal '$($principalDisplayName)' encontrado (ID: $($principalToAdd.Id))." -ForegroundColor Green

    # 3. Leer los datos del archivo Excel
    Write-Host "Leyendo el archivo de Excel..."
    $groupsToProcess = Import-Excel -Path $ExcelFilePath

    # 4. Procesar cada grupo de la lista
    $totalGroups = $groupsToProcess.Count
    $counter = 0

    foreach ($groupRow in $groupsToProcess) {
        $counter++
        $groupObjectId = $groupRow."Object ID"
        $groupDisplayName = $groupRow.Group
        $currentGroupIdentifier = if (-not [string]::IsNullOrWhiteSpace($groupObjectId)) { $groupObjectId } else { $groupDisplayName }

        Write-Progress -Activity "Procesando Grupos" -Status "($counter/$totalGroups) - $currentGroupIdentifier" -PercentComplete (($counter / $totalGroups) * 100)
        
        $group = $null
        $status = ""
        $reason = ""

        try {
            # Búsqueda de grupo
            if (-not [string]::IsNullOrWhiteSpace($groupObjectId)) {
                $group = Get-MgGroup -GroupId $groupObjectId -ErrorAction SilentlyContinue
            }
            if (-not $group -and -not [string]::IsNullOrWhiteSpace($groupDisplayName)) {
                $group = Get-MgGroup -Filter "displayName eq '$groupDisplayName'" -ErrorAction SilentlyContinue
            }

            if (-not $group) {
                throw "El grupo no fue encontrado ni por ID ni por nombre."
            }
            
            # Construir el BodyParameter para la referencia
            $ownerRef = @{"@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($principalToAdd.Id)" }
            
            Write-Host "Agregando a '$principalDisplayName' como propietario del grupo '$($group.DisplayName)'..."
            New-MgGroupOwnerByRef -GroupId $group.Id -BodyParameter $ownerRef -ErrorAction Stop
            
            $status = "Exitoso"
            $reason = "El principal fue agregado como propietario."
        }
        catch {
            if ($_.Exception.Message -like "*already exist for the following modified properties: 'owners'*") {
                $status = "Advertencia"
                $reason = "El principal ya es propietario de este grupo."
                Write-Warning "El principal ya es propietario del grupo '$($group.DisplayName)'."
            }
            else {
                $status = "Error"
                if ($_.Exception.Message -like "*Request_ResourceNotFound*") {
                    $reason = "El grupo no fue encontrado en Microsoft Entra ID."
                }
                elseif ($_.Exception.Message -like "*Authorization_RequestDenied*") {
                    $reason = "Permisos insuficientes. Se requiere 'GroupMember.ReadWrite.All'."
                }
                else {
                    $reason = $_.Exception.Message
                }
                Write-Warning "Ocurrió un error con el grupo '$currentGroupIdentifier': $reason"
            }
        }
        
        # Agregar el resultado al reporte
        $reportData.Add([PSCustomObject]@{
                GrupoIdentificador = $currentGroupIdentifier
                NombreEncontrado   = if ($group) { $group.DisplayName } else { "N/A" }
                Estado             = $status
                Detalle            = $reason
            })
    }
}
catch {
    Write-Error "Ocurrió un error crítico durante la ejecución: $($_.Exception.Message)"
}
finally {
    # 5. Generar y mostrar el reporte CSV
    if ($reportData.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
        $reportFileName = "Reporte_Agregar_Owner_Grupos_$timestamp.csv"
        $reportFilePath = Join-Path -Path $PSScriptRoot -ChildPath $reportFileName
        
        $reportData | Export-Csv -Path $reportFilePath -NoTypeInformation -Encoding UTF8 -Delimiter ";"
        
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "Proceso completado. Reporte generado en:" -ForegroundColor Green
        Write-Host $reportFilePath -ForegroundColor White
        Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
        $reportData | Format-Table -AutoSize
    }
    else {
        Write-Warning "No se procesaron grupos para generar un reporte."
    }

    # 6. Desconectar la sesión de Graph
    if (Get-MgContext) {
        Write-Host "`nDesconectando de la sesión de Microsoft Graph."
        Disconnect-MgGraph
    }
}