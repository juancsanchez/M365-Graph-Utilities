# Migración de SharePoint Online a Azure Files

Script de PowerShell para migrar bibliotecas de documentos desde **SharePoint Online** hacia un **Azure File Share**, con soporte para volúmenes grandes mediante migración parcial por lotes, checkpoint de progreso y reanudación automática de transferencias interrumpidas.

---

## Contenido del repositorio

```
📁 Repositorio
├── Migracion-SharePoint-AzureFiles.ps1   # Script principal
├── example.configMigracion.json          # Plantilla de configuración
├── .gitignore                            # Excluye configMigracion.json y archivos de runtime
└── README.md                            # Este archivo
```

> **Nota de seguridad:** El archivo `configMigracion.json` con las credenciales reales está excluido del repositorio mediante `.gitignore`. Nunca lo suba al control de versiones.

---

## Requisitos previos

| Requisito | Detalle |
|-----------|---------|
| PowerShell | 5.1 o superior (incluido en Windows) |
| Módulo PnP.PowerShell | Se instala automáticamente si no está presente |
| AzCopy v10 | Descarga: https://aka.ms/downloadazcopy-v10-windows |
| App Registration en Entra ID | Ver sección [Crear App Registration](#crear-app-registration-en-entra-id) |
| Azure File Share | Con token SAS generado desde el portal de Azure |

---

## Crear App Registration en Entra ID

El script usa PnP.PowerShell con autenticación delegada. Las versiones recientes de PnP ya no permiten usar su Client ID integrado, por lo que es necesario registrar una aplicación propia.

### Paso 1 — Registrar la aplicación

1. Acceda a [https://entra.microsoft.com](https://entra.microsoft.com)
2. Navegue a **App registrations** → **New registration**
3. Complete los campos:
   - **Name:** `PnP-Migracion-SharePoint` (o el nombre que prefiera)
   - **Supported account types:** *Accounts in this organizational directory only*
   - **Redirect URI:** seleccione `Public client/native` → URI: `http://localhost`
4. Haga clic en **Register**
5. Copie el **Application (Client) ID** — lo necesitará en `configMigracion.json`

### Paso 2 — Asignar permisos

1. En la aplicación registrada, vaya a **API permissions** → **Add a permission**
2. Seleccione **SharePoint**
3. Elija **Delegated permissions** y agregue:
   - `Files.Read.All`
4. Haga clic en **Grant admin consent for \<tenant\>** ✅

> Con `Files.Read.All` es suficiente para leer y descargar todos los archivos del sitio. No se requieren permisos de escritura en SharePoint.

---

## Configuración

### 1. Copiar la plantilla

```powershell
Copy-Item example.configMigracion.json configMigracion.json
```

### 2. Completar los valores en `configMigracion.json`

```json
{
  "SiteUrl": "https://<tenant>.sharepoint.com/sites/<NombreSitio>",
  "ClientId": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
  "LocalStagingDrive": "C:\\Staging",
  "AzCopyPath": "C:\\AzCopy\\azcopy.exe",
  "AzureFileShareBaseUrl": "https://<cuenta>.file.core.windows.net/<nombre-share>",
  "AzureSASToken": "sv=YYYY-MM-DD&ss=f&srt=sco&sp=rwdlc&...",
  "TargetFolders": [
    "Documentos compartidos/<CarpetaRaiz1>",
    "Documentos compartidos/<CarpetaRaiz2>"
  ]
}
```

| Campo | Descripción |
|-------|-------------|
| `SiteUrl` | URL completa del sitio de SharePoint origen |
| `ClientId` | Application (Client) ID del App Registration en Entra ID |
| `LocalStagingDrive` | Ruta local temporal para staging. Debe tener espacio suficiente para la subcarpeta más grande |
| `AzCopyPath` | Ruta completa al ejecutable `azcopy.exe` |
| `AzureFileShareBaseUrl` | URL base del File Share **sin** token SAS y **sin** barra final |
| `AzureSASToken` | Token SAS que inicia en `sv=...` (sin el `?` inicial). Permisos mínimos: `Read, Write, Create, List` |
| `TargetFolders` | Rutas relativas internas de SharePoint. Puede diferir del nombre visible — verifique la URL real navegando a la carpeta en el navegador |

### 3. Instalar AzCopy

```powershell
# Ejecutar en PowerShell como Administrador
Expand-Archive -Path "$env:USERPROFILE\Downloads\azcopy_windows_amd64_*.zip" -DestinationPath "C:\AzCopy_temp"
$extracted = Get-ChildItem "C:\AzCopy_temp" -Recurse -Filter "azcopy.exe" | Select-Object -First 1
New-Item -ItemType Directory -Path "C:\AzCopy" -Force | Out-Null
Move-Item $extracted.FullName "C:\AzCopy\azcopy.exe"
Remove-Item "C:\AzCopy_temp" -Recurse -Force

# Verificar instalación
& "C:\AzCopy\azcopy.exe" --version
```

---

## Uso

```powershell
.\Migracion-SharePoint-AzureFiles.ps1
```

Al ejecutar, el script:

1. Carga y valida `configMigracion.json`
2. Abre una ventana del navegador para autenticarse en SharePoint
3. Por cada carpeta definida en `TargetFolders`, procesa sus subcarpetas de primer nivel de forma individual:
   - Descarga la subcarpeta a `LocalStagingDrive`
   - La sube a Azure Files mediante AzCopy
   - Si la subida es exitosa, elimina la subcarpeta del staging
   - Registra el lote como `COMPLETADO` en el checkpoint
4. Al finalizar, muestra un resumen con lotes completados, omitidos y con error

### Reanudar una ejecución interrumpida

Si el script se interrumpe por cualquier motivo, simplemente vuélvalo a ejecutar:

```powershell
.\Migracion-SharePoint-AzureFiles.ps1
```

El sistema de checkpoint (`migration_checkpoint.json`) detectará los lotes ya completados y los omitirá automáticamente, retomando desde el primer lote pendiente. Los lotes marcados como `ERROR` también se reintentarán.

### Reiniciar desde cero

Para ignorar el progreso anterior y migrar todo nuevamente:

```powershell
Remove-Item "C:\Staging\migration_checkpoint.json"
.\Migracion-SharePoint-AzureFiles.ps1
```

---

## Archivos generados en runtime

| Archivo | Descripción |
|---------|-------------|
| `migration_checkpoint.json` | Estado de cada lote (`COMPLETADO` / `ERROR`). Base para reanudar ejecuciones. |
| `migration_log.txt` | Log completo con timestamps de todas las operaciones. |

Ejemplo de `migration_checkpoint.json`:

```json
{
  "BKP/Subcarpeta1": "COMPLETADO",
  "BKP/Subcarpeta2": "COMPLETADO",
  "BKP/Subcarpeta3": "ERROR",
  "Departamento Mercadeo/Campañas": "COMPLETADO"
}
```

---

## Estrategia de resiliencia

El script implementa dos capas de tolerancia a fallos:

**Capa 1 — Checkpoint por lote**
Cada subcarpeta de primer nivel se procesa como un lote independiente. Al completarse, queda registrada en el checkpoint. Si el script se detiene, la siguiente ejecución omite los lotes ya completados y reintenta los que fallaron.

**Capa 2 — AzCopy Job Resume**
Si AzCopy se interrumpe a mitad de una transferencia (corte de red, timeout, etc.), el script detecta automáticamente el Job ID más reciente y ejecuta `azcopy jobs resume` antes de declarar el lote como fallido. Esto permite retomar la transferencia a nivel de archivo individual, sin repetir lo que ya se subió.

```
AzCopy transfiere archivos 1–500 de 1000 → se cae la red
→ Script detecta el Job ID fallido
→ Ejecuta: azcopy jobs resume <JobID>
→ Retoma desde el archivo 501
```

---

## Forma óptima de ejecución para volúmenes grandes

Para migraciones de alto volumen (cientos de GB o más de 1 TB), se recomienda ejecutar el script desde una **máquina virtual en Azure** en lugar de desde un equipo local. Esto elimina la latencia de internet y maximiza el ancho de banda hacia Azure Files.

### Arquitectura recomendada

```
SharePoint Online
      │
      │ (descarga vía HTTPS — PnP.PowerShell)
      ▼
 Azure VM (Windows Server)
 misma región que el Storage Account
      │
      │ (transferencia interna — AzCopy vía Service Endpoint)
      ▼
 Azure File Share
```

### Paso 1 — Crear la VM en la misma región que el Storage Account

1. En el **Azure Portal**, cree una VM con **Windows Server 2022**
2. Seleccione la **misma región** donde está el Storage Account (ej: `East US`, `West Europe`)
3. Tamaño recomendado: `Standard_D4s_v3` o superior (4 vCPU, 16 GB RAM)
4. Asegúrese de que la VM esté en la misma **Virtual Network (VNet)** desde la que configurará el Service Endpoint

> Ejecutar desde la misma región elimina costos de egress de red y reduce la latencia a milisegundos.

### Paso 2 — Configurar un Service Endpoint para el Storage

Un Service Endpoint permite que el tráfico entre la VM y el Storage Account viaje por la red troncal de Azure, sin salir a internet público.

1. En el **Azure Portal**, navegue a la **Virtual Network** de la VM
2. Vaya a **Subnets** → seleccione la subred de la VM
3. En **Service endpoints** → **Add** → seleccione `Microsoft.Storage`
4. Guarde los cambios

Luego, restrinja el acceso al Storage Account:

1. Navegue al **Storage Account** → **Networking**
2. En **Firewalls and virtual networks**, seleccione **Selected networks**
3. Agregue la VNet y subred de la VM
4. Guarde los cambios

### Paso 3 — Ejecutar el script desde la VM

1. Conéctese a la VM vía **RDP**
2. Copie los archivos `Migracion-SharePoint-AzureFiles.ps1` y `configMigracion.json` a la VM
3. Instale AzCopy y el módulo PnP.PowerShell según las instrucciones de este README
4. Ejecute el script desde PowerShell

### Beneficios de esta arquitectura

| Factor | Ejecución local | Ejecución desde VM en Azure |
|--------|-----------------|------------------------------|
| Velocidad de subida a Azure | Limitada por internet del cliente | Gbps internos de Azure |
| Costo de transferencia | Egress charges | Sin costo (tráfico interno) |
| Estabilidad de la conexión | Dependiente del ISP | Red troncal de Microsoft |
| Interrupción del proceso | Si se apaga el PC, se detiene | La VM sigue corriendo |

> **Tip:** Una vez iniciada la migración, puede desconectarse del RDP. El script continuará ejecutándose en la VM. Reconéctese cuando quiera revisar el progreso en `migration_log.txt`.

---

## Solución de problemas frecuentes

**`Please specify a valid client id for an Entra ID App Registration`**
PnP.PowerShell v2+ requiere un Client ID propio. Asegúrese de haber completado el paso [Crear App Registration](#crear-app-registration-en-entra-id) y de haber configurado el `ClientId` en `configMigracion.json`.

**`cannot transfer individual files/folders to the root of a service`**
La `AzureFileShareBaseUrl` apunta a la raíz del share. Verifique que no incluya el token SAS y que no termine en `/`.

**`No transfers were scheduled` en AzCopy**
El staging está vacío — la descarga desde SharePoint no funcionó. Verifique que la ruta en `TargetFolders` coincide con la URL interna real de la carpeta en SharePoint (navegue a la carpeta en el navegador y observe la URL).

**La ruta de SharePoint no funciona aunque se ve bien en el navegador**
El nombre visible de la biblioteca puede diferir del nombre interno. En sitios en español, la biblioteca puede llamarse `Documentos compartidos` internamente aunque se muestre como `Documents` en la interfaz. Verifique con:

```powershell
Connect-PnPOnline -Url "<SiteUrl>" -Interactive -ClientId "<ClientId>"
Get-PnPList | Select-Object Title, RootFolder | Format-Table -AutoSize
```