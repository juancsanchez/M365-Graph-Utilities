# Microsoft 365 Graph Utilities

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-blue?logo=powershell)
![Microsoft Graph](https://img.shields.io/badge/Microsoft%20Graph-API-blueviolet)
![Entra ID](https://img.shields.io/badge/Microsoft-Entra%20ID-0078D4)

Colección de scripts de PowerShell para automatizar tareas de administración, auditoría y generación de informes en entornos de Microsoft 365. Los scripts operan con **autenticación desatendida (App-Only)** mediante certificados en Microsoft Entra ID.

---

## 📁 Estructura del Repositorio

```
📁 Raíz
├── 📁 Auditoria-Reportes/          # Scripts de solo lectura que generan reportes CSV
├── 📁 Grupos/                      # Operaciones sobre grupos de Entra ID
├── 📁 Usuarios-Licencias/          # Creación y gestión de cuentas de usuario
├── 📁 Apps-ServicePrincipals/      # App Registrations y Managed Identities
├── 📁 Intune/                      # Gestión de políticas de dispositivos
├── 📁 Migrar-SP-AzFiles/           # Migración de SharePoint Online a Azure Files
├── 📁 Utils/                       # Herramientas de soporte (certificados, etc.)
├── example.config.json             # Plantilla de configuración
├── .gitignore
└── README.md
```

---

## 🚀 Características Principales

- **Autenticación Segura**: Service Principals con certificados (recomendado).
- **Configuración Externalizada**: Parámetros sensibles gestionados en `config.json`, excluido del repositorio vía `.gitignore`.
- **Optimización**: Procesamiento en paralelo y filtros OData para tenants de gran volumen.
- **Salida Estructurada**: Reportes en CSV (UTF-8) listos para Excel o Power BI.
- **Gestión de Dependencias**: Instalación automática de módulos requeridos.

---

## 📋 Prerrequisitos

- **PowerShell**: 5.1 o superior (se recomienda 7+ para scripts con `-Parallel`).
- **Módulos**: `Microsoft.Graph`, `ExchangeOnlineManagement`. Los scripts los instalan automáticamente si no están presentes.
- **Entra ID App Registration**: Con los permisos de API correspondientes a cada script.

---

## ⚙️ Configuración Inicial

### 1. Clonar el repositorio

```bash
git clone <URL_DEL_REPOSITORIO>
cd <NOMBRE_CARPETA_REPOSITORIO>
```

### 2. Crear el archivo de configuración

Copia la plantilla y completa los valores reales:

```bash
Copy-Item example.config.json config.json
```

```json
{
  "tenantId": "SU_GUID_DE_TENANT",
  "clientId": "SU_APP_ID_DEL_REGISTRO",
  "organizationName": "suorganizacion.onmicrosoft.com",
  "certThumbprint": "HUELLA_DIGITAL_DEL_CERTIFICADO",
  "dnsName": "su.dominio.com"
}
```

> ⚠️ `config.json` está excluido del repositorio por `.gitignore`. Nunca lo subas al control de versiones.

### 3. Configurar el certificado

#### Paso A — Generar el certificado

```powershell
.\Utils\sc-Crear-Certificado-PowerShell.ps1
```

Genera dos archivos: `.cer` (clave pública) y `.pfx` (clave privada con contraseña).

#### Paso B — Cargar en Microsoft Entra ID

1. Ve a **Entra ID** → **App registrations** → tu aplicación.
2. Navega a **Certificates & secrets** → **Certificates** → **Upload certificate**.
3. Sube el archivo `.cer` y copia el **Thumbprint** al campo `certThumbprint` de `config.json`.

#### Paso C — Instalar en la máquina local

Instala el archivo `.pfx` en el almacén **Current User → Personal** haciendo doble clic o con:

```powershell
Import-PfxCertificate -FilePath ".\cert-*.pfx" -CertStoreLocation "Cert:\CurrentUser\My"
```

---

## 🔐 Permisos de API Requeridos

Todos los scripts usan permisos de tipo **Application** que deben ser consentidos por un administrador del tenant.

| Script | Permisos Mínimos |
| :--- | :--- |
| `sc-Generar-ReporteMFAporUsuario` | `Reports.Read.All` o `AuditLog.Read.All` |
| `sc-Generar-ReporteAppsSSO` | `Application.Read.All`, `Directory.Read.All`, `DelegatedPermissionGrant.Read.All` |
| `sc-Generar-CuentaUsuariosLicenciados-Paralelo` | `User.Read.All` |
| `sc-Encontrar-GruposComunesUsuarios` | `User.Read.All`, `Group.Read.All` |
| `sc-Agregar-OwnerGrupos` | `GroupMember.ReadWrite.All`, `User.Read.All`, `Application.Read.All` |
| `sc-Gestionar-MembresiaGrupos-Masivo` | `GroupMember.ReadWrite.All`, `User.Read.All` |
| `sc-Renombrar-GruposSeguridad` | `Group.ReadWrite.All` |
| `sc-Generar-ReporteDeUsoM365` | `User.Read.All`, `Files.Read.All`, `Directory.Read.All`, `Exchange.ManageAsApp` |
| `sc-Generar-ReporteLicenciasGrupos` | `Group.Read.All`, `GroupMember.Read.All` |
| `sc-Generar-ReporteLicencias` | `User.Read.All`, `Directory.Read.All`, `AuditLog.Read.All` |
| `sc-Generar-ReporteRolesAdmin` | `RoleManagement.Read.Directory`, `User.Read.All` |
| `sc-Generar-ReportePermisosServicePrincipals` | `Application.Read.All`, `AppRoleAssignment.ReadWrite.All`, `Directory.Read.All` |
| `sc-Asignar-PermisosGraph-ManagedIdentity` | `AppRoleAssignment.ReadWrite.All` |
| `sc-Crear-AppRegistrations-Masivo` | `Application.ReadWrite.All`, `User.Read.All`, `Directory.Read.All` |
| `sc-Crear-Usuarios-Masivo` | `User.ReadWrite.All` |
| `sc-Eliminar-Usuarios-Masivo` | `User.ReadWrite.All` |
| `sc-Deshabilitar-Usuarios-Masivo` | `User.ReadWrite.All` |
| `sc-Investigar-SignIn-CorrelationId` | `AuditLog.Read.All`, `Directory.Read.All` |
| `sc-Encontrar-AlcanceGruposCA` | `Policy.Read.All`, `Group.Read.All` |
| `sc-Renombrar-PoliticasIntune-Masivo` | `DeviceManagementConfiguration.ReadWrite.All` |
| `sc-Generar-ReporteDispositivosNoCumplimiento` | `DeviceManagementManagedDevices.Read.All`, `DeviceManagementConfiguration.Read.All` |
| `sc-Generar-ReporteInventarioDispositivos` | `DeviceManagementManagedDevices.Read.All` |
| `sc-Generar-ReporteRecursosExchange` | `Exchange.ManageAsApp` + rol `View-Only Recipients` en Exchange Online |

---

## 📂 Scripts por Carpeta

---

### 📊 Auditoria-Reportes/

Scripts de solo lectura que generan un archivo CSV como salida. No modifican datos del tenant.

#### `sc-Generar-ReporteMFAporUsuario.ps1`
Radiografía del estado de MFA por usuario: métodos registrados (Authenticator, FIDO2, Teléfono, etc.), estado de SSPR, método predeterminado y capacidad Passwordless. Usa la API de reportes de Graph para máxima eficiencia.

#### `sc-Generar-ReporteAppsSSO.ps1`
Auditoría unificada de Aplicaciones Empresariales (modernas y legacy). Identifica tipo de SSO (SAML/OIDC), Identifier URIs, Reply URLs y conteo de usuarios y grupos asignados. Soporta modo de prueba con `-Top` y procesamiento paralelo.

#### `sc-Generar-ReporteLicencias.ps1`
Reporte de licenciamiento por usuario con nombres comerciales legibles (ej: "Microsoft 365 E5") e incluye la última fecha de inicio de sesión.

#### `sc-Generar-ReporteLicenciasGrupos.ps1`
Auditoría de Group-Based Licensing: qué licencias están asignadas a qué grupos, planes de servicio deshabilitados y conteo de miembros.

#### `sc-Generar-ReporteDeUsoM365.ps1`
Informe de almacenamiento por usuario: tamaño de buzón principal, buzón de archivo y uso de OneDrive for Business. Requiere conexión a Exchange Online además de Graph.

#### `sc-Generar-ReporteRolesAdmin.ps1`
Identifica usuarios con roles privilegiados activos (Global Admin, Security Admin, etc.).

#### `sc-Generar-ReportePermisosServicePrincipals.ps1`
Auditoría de seguridad de todos los permisos de API asignados a Service Principals, con alertas sobre permisos de alto privilegio.

#### `sc-Generar-CuentaUsuariosLicenciados-Paralelo.ps1`
Recuento rápido de usuarios licenciados en tenants muy grandes. Usa `ForEach-Object -Parallel` (requiere PowerShell 7+).

#### `sc-Investigar-SignIn-CorrelationId.ps1`
Diagnóstico de un intento de inicio de sesión fallido a partir de su Correlation ID. Muestra detalles del usuario, dispositivo, código de error y análisis de qué políticas de Acceso Condicional causaron el bloqueo.

#### `sc-Generar-ReporteRecursosExchange.ps1`
Inventario completo de buzones de recurso del tenant: salas de reuniones y equipos. Por cada recurso extrae la configuración de calendario (AutomateProcessing, AllowConflicts, duración máxima), capacidad de la sala, delegados con FullAccess y SendAs, tamaño del buzón, fecha de último uso y estado habilitado/deshabilitado. Requiere conexión a Exchange Online con autenticación desatendida mediante certificado.

> ⚙️ **Configuración previa requerida:** Exchange Online mantiene su propio registro de Service Principals, independiente de Entra ID. Antes de ejecutar este script por primera vez es necesario registrar el SP en Exchange y asignarle el rol `View-Only Recipients` mediante `New-ServicePrincipal` y `New-ManagementRoleAssignment`. El procedimiento completo con los comandos exactos se encuentra documentado en el bloque `.NOTES` del script.

---

### 👥 Grupos/

Operaciones de lectura y escritura sobre grupos de Microsoft Entra ID.

#### `sc-Encontrar-GruposComunesUsuarios.ps1`
Identifica grupos de seguridad y Microsoft 365 compartidos entre 3 a 5 usuarios. Útil para diagnóstico de membresías.

#### `sc-Encontrar-AlcanceGruposCA.ps1`
Audita qué políticas de Acceso Condicional incluyen o excluyen grupos específicos, a partir de una lista de Object IDs.

#### `sc-Agregar-OwnerGrupos.ps1`
Asigna masivamente un usuario o Service Principal como Owner de una lista de grupos desde un archivo Excel. Prioriza búsqueda por Object ID con fallback por DisplayName.

#### `sc-Gestionar-MembresiaGrupos-Masivo.ps1`
Gestiona el ciclo de vida de membresía (agregar/retirar) para múltiples usuarios y grupos desde un CSV. Identifica el grupo por ID o por nombre.

**Columnas del CSV:** `upn`, `groupName`, `groupId`, `action` (`agregar` / `retirar`)

#### `sc-Renombrar-GruposSeguridad.ps1`
Renombra masivamente grupos de seguridad desde un CSV. Prioriza búsqueda por Object ID; fallback por DisplayName exacto. Detecta grupos que ya tienen el nombre correcto para evitar llamadas innecesarias a la API.

**Columnas del CSV:** `nombreActual`, `groupId`, `nombreNuevo`

---

### 👤 Usuarios-Licencias/

#### `sc-Crear-Usuarios-Masivo.ps1`
Crea usuarios en Entra ID desde un CSV con contraseñas aleatorias seguras. Soporta campos opcionales como `jobTitle`, `department`, `country`, `mobilePhone`. Genera un reporte con las credenciales creadas.

**Columnas obligatorias:** `upn`, `DisplayName`  
**Columnas opcionales:** `jobTitle`, `department`, `country`, `mobilePhone`, `firstName`, `lastName`

#### `sc-Eliminar-Usuarios-Masivo.ps1`
Elimina masivamente usuarios de Entra ID desde un CSV. Opera en dos fases: primero resuelve y muestra todos los usuarios encontrados (por `objectId` con fallback a `upn`), luego solicita confirmación explícita escribiendo `CONFIRMAR` antes de proceder. Genera un reporte CSV con el resultado de cada operación (exitosos, errores y filas omitidas).

**Columnas del CSV:** `upn`, `objectId` (al menos una de las dos por fila)  
> ⚠️ Los usuarios eliminados quedan en la papelera de reciclaje de Entra ID y son recuperables durante 30 días.

#### `sc-Deshabilitar-Usuarios-Masivo.ps1`
Deshabilita masivamente cuentas de usuario de Entra ID desde un CSV. Opera en dos fases: primero resuelve y muestra todos los usuarios encontrados (por `objectId` con fallback a `upn`) indicando cuáles ya están deshabilitados, luego solicita confirmación explícita escribiendo `CONFIRMAR`. Las cuentas ya deshabilitadas se omiten automáticamente. Genera un reporte CSV con el resultado.

**Columnas del CSV:** `upn`, `objectId` (al menos una de las dos por fila)  
> ✅ Esta acción es **reversible**. Las cuentas pueden volver a habilitarse desde el portal de Entra ID.

---

### 🔑 Apps-ServicePrincipals/

#### `sc-Crear-AppRegistrations-Masivo.ps1`
Crea App Registrations masivamente desde un CSV. Configura Redirect URIs, Logout URL, ID Token y propietarios. Genera un reporte con URLs directas de administración en Entra.

**Columnas del CSV:** `AppName`, `RedirectURL`, `LogOutURL`, `idTokenRequired`, `owner`

#### `sc-Asignar-PermisosGraph-ManagedIdentity.ps1`
Asigna permisos de Graph API (App Roles) a una Managed Identity de Azure de forma programática, sin necesidad de hacerlo desde el portal.

---

### 📱 Intune/

#### `sc-Generar-ReporteDispositivosNoCumplimiento.ps1`
Genera un reporte detallado de dispositivos no conformes en Intune con sus razones específicas de incumplimiento. Consulta los estados por política y por configuración de ajuste, emitiendo una salida en CSV para análisis y en TXT para lectura rápida.

#### `sc-Generar-ReporteInventarioDispositivos.ps1`
Inventario completo de todos los dispositivos administrados en Intune, optimizado para tenants de alto volumen. Extrae nombre del dispositivo, ID, UPN del usuario principal, marca, modelo, estado de cumplimiento, fecha de último check-in, sistema operativo y versión, tipo de propiedad (Corporate/Personal) y número de serie. Implementa paginación robusta (`$top=999`), retry con exponential backoff para manejar throttling en endpoints de Intune (que frecuentemente omiten el header `Retry-After`), `$select` explícito para propiedades non-default y escritura progresiva al CSV para evitar consumo excesivo de RAM. En PowerShell 7+ activa procesamiento paralelo con `ForEach-Object -Parallel`; en 5.1 degrada automáticamente a modo secuencial.

#### `sc-Renombrar-PoliticasIntune-Masivo.ps1`
Renombra masivamente políticas de Intune de múltiples tipos (Device Configuration, Settings Catalog, Compliance, Endpoint Security, Scripts, Update Rings, Administrative Templates) desde un CSV. Usa la API beta donde es necesario para cubrir todos los tipos de perfil.

**Columnas del CSV:** `Nombre actual`, `Nombre sugerido`

---

### 🗂️ Migrar-SP-AzFiles/

Herramienta independiente para migrar bibliotecas de documentos de SharePoint Online a Azure Files.

Ver [`Migracion-SharePoint-AzFiles/README.md`](./Migracion-SharePoint-AzFiles/README.md) para documentación completa.

| Archivo | Descripción |
|---------|-------------|
| `sc-Migrar-SharePoint2AzFiles.ps1` | Script principal de migración con checkpoint y resume |
| `example.configMigracion.json` | Plantilla de configuración para la migración |

---

### 🛠️ Utils/

#### `sc-Crear-Certificado-PowerShell.ps1`
Genera y exporta un certificado autofirmado (`.cer` + `.pfx`) para autenticación con Microsoft Graph. Lee el `dnsName` desde `config.json`.

---

## 👤 Autor

**Juan Sánchez**

---

## ⚠️ Descargo de Responsabilidad

Estos scripts se proporcionan "tal cual", sin garantía de ningún tipo. Se recomienda revisarlos y probarlos en un entorno de desarrollo antes de ejecutarlos en producción.