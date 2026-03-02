# Microsoft 365 Graph Utilities

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-blue?logo=powershell)
![Microsoft Graph](https://img.shields.io/badge/Microsoft%20Graph-API-blueviolet)
![Entra ID](https://img.shields.io/badge/Microsoft-Entra%20ID-0078D4)

Este repositorio contiene una colección de scripts de PowerShell optimizados para automatizar tareas de administración, auditoría y generación de informes en entornos de Microsoft 365. Los scripts están diseñados para operar con **autenticación desatendida** (App-Only) a través de Microsoft Entra ID, garantizando seguridad y eficiencia en ejecuciones programadas.

## 🚀 Características Principales

* **Autenticación Segura**: Implementación de Service Principals utilizando Certificados (recomendado).
* **Configuración Externalizada**: Gestión de parámetros sensibles (`tenantId`, `clientId`, etc.) mediante un archivo `config.json`, manteniendo el código limpio y seguro.
* **Optimización**: Uso de técnicas de procesamiento en paralelo y filtros OData avanzados para manejar tenants de gran volumen.
* **Salida Estructurada**: Generación automática de reportes en formato CSV (UTF-8) listos para análisis en Excel o Power BI.
* **Gestión de Dependencias**: Verificación e instalación automática de módulos requeridos (`Microsoft.Graph`, `ExchangeOnlineManagement`).

## 📋 Prerrequisitos

* **PowerShell**: Versión 5.1 o superior (Se recomienda PowerShell 7+ para scripts que utilizan `-Parallel`).
* **Módulos**: Los scripts intentarán instalar los módulos necesarios, pero se recomienda tener actualizados:
    * `Microsoft.Graph`
    * `ExchangeOnlineManagement`
* **Entra ID App Registration**: Una aplicación registrada con los permisos de API adecuados.

## 🔐 Permisos de API Requeridos

Asegúrese de que el *Service Principal* de su App Registration tenga los siguientes permisos de API (tipo `Application`) consentidos por un administrador:

| Script | API | Permisos Mínimos |
| :--- | :--- | :--- |
| **sc-Generar-ReporteMFAporUsuario.ps1** | Microsoft Graph | `Reports.Read.All` o `AuditLog.Read.All` |
| **sc-Generar-ReporteAppsSSO.ps1** | Microsoft Graph | `Application.Read.All`, `Directory.Read.All`, `DelegatedPermissionGrant.Read.All` |
| **sc-Generar-CuentaUsuariosLicenciados-Paralelo.ps1** | Microsoft Graph | `User.Read.All` |
| **sc-Encontrar-GruposComunesUsuarios.ps1** | Microsoft Graph | `User.Read.All`, `Group.Read.All` |
| **sc-Agregar-OwnerGrupos.ps1** | Microsoft Graph | `GroupMember.ReadWrite.All`, `User.Read.All`, `Application.Read.All` |
| **sc-Gestionar-MembresiaGrupos-Masivo.ps1** | Microsoft Graph | `GroupMember.ReadWrite.All`, `User.Read.All` |
| **sc-Generar-ReporteDeUsoM365.ps1** | Microsoft Graph | `User.Read.All`, `Files.Read.All`, `Directory.Read.All` |
| | Exchange Online | `Exchange.ManageAsApp` (Requiere Rol de Admin en EXO) |
| **sc-Generar-ReporteLicenciasGrupos.ps1** | Microsoft Graph | `Group.Read.All`, `GroupMember.Read.All` |
| **sc-Generar-ReporteLicencias.ps1** | Microsoft Graph | `User.Read.All`, `Directory.Read.All`, `AuditLog.Read.All` |
| **sc-Generar-ReporteRolesAdmin.ps1** | Microsoft Graph | `RoleManagement.Read.Directory`, `User.Read.All` |
| **sc-Generar-ReportePermisosServicePrincipals.ps1**| Microsoft Graph | `Application.Read.All`, `AppRoleAssignment.ReadWrite.All`, `Directory.Read.All` |
| **sc-Asignar-PermisosGraph-ManagedIdentity.ps1**| Microsoft Graph | `AppRoleAssignment.ReadWrite.All` |
| **sc-Crear-AppRegistrations-Masivo.ps1** | Microsoft Graph | `Application.ReadWrite.All`, `User.Read.All`, `Directory.Read.All` |
| **sc-Crear-Usuarios-Masivo.ps1** | Microsoft Graph | `User.ReadWrite.All` |
| **sc-Investigar-SignIn-CorrelationId.ps1** | Microsoft Graph | `AuditLog.Read.All`, `Directory.Read.All` |
| **sc-Encontrar-AlcanceGruposCA.ps1** | Microsoft Graph | `Policy.Read.All`, `Group.Read.All` |
| **sc-Renombrar-Grupos-Masivo.ps1** | Microsoft Graph | `Group.ReadWrite.All` |

## ⚙️ Configuración Inicial

### 1. Clonar el Repositorio
```bash
git clone <URL_DEL_REPOSITORIO>
cd <NOMBRE_CARPETA_REPOSITORIO>
```

### 2\. Archivo de Configuración (config.json)

Cree un archivo `config.json` en la raíz. Copie la siguiente estructura:
```json
{
  "tenantId": "SU_GUID_DE_TENANT",
  "clientId": "SU_APP_ID_DEL_REGISTRO",
  "organizationName": "suorganizacion.onmicrosoft.com",
  "certThumbprint": "HUELLA_DIGITAL_DEL_CERTIFICADO",
  "dnsName": "su.dominio.com"
}
```

*Nota: `certThumbprint`, `organizationName` y `dnsName` son obligatorios para scripts que usan autenticación por certificado.*

### 3\. Configuración de Certificado (Paso a Paso)

Para utilizar la autenticación segura por certificado (recomendada), siga estos pasos. Este proceso es compatible tanto con **Windows** como con **macOS**.

#### Paso A: Generar el Certificado

Ejecute el script de utilidad incluido para crear un nuevo certificado autofirmado:
```powershell
.\sc-Crear-Certificado-PowerShell.ps1
```

*Esto generará dos archivos en la carpeta del script: un `.cer` (clave pública) y un `.pfx` (clave privada).*

#### Paso B: Cargar en Microsoft Entra ID

1.  Vaya al portal de Azure \> **App registrations** \> Seleccione su aplicación.
2.  Navegue a **Certificates & secrets** \> Pestaña **Certificates**.
3.  Haga clic en **Upload certificate** y seleccione el archivo `.cer` generado en el paso anterior.
4.  Copie el valor del **Thumbprint** y péguelo en su archivo `config.json` en el campo `certThumbprint`.

#### Paso C: Instalar en la Máquina Local

Para que el script pueda autenticarse, el certificado con la clave privada debe estar instalado en el almacén de certificados del usuario actual.

1.  Localice el archivo `.pfx` generado.
2.  Haga doble clic para instalarlo (o use el comando `Import-PfxCertificate`).
3.  **Importante**: Instálelo en la ubicación **Current User** (Usuario Actual).
4.  Cuando se le solicite, ingrese la contraseña que definió al momento de crear el certificado.

*Nota: Sin este paso, recibirá un error indicando que no se encuentra el certificado con el Thumbprint especificado.*

-----

## 📂 Scripts Incluidos

### 📊 Auditoría y Reportes

#### `sc-Generar-ReporteMFAporUsuario.ps1`

Genera una radiografía del estado de seguridad de los usuarios. Detalla si tienen MFA registrado, el estado de SSPR, si son *Passwordless Capable* y lista todos los métodos de autenticación configurados (Authenticator, Teléfono, FIDO2, etc.).
*(Auth: Certificado)*

#### `sc-Generar-ReporteAppsSSO.ps1`

Auditoría unificada de Aplicaciones Empresariales (Modernas y Legacy). 
**Novedades v7.1**:
- **Detalles Extendidos**: Nuevas columnas para *Identifier (SAML)* y *Reply URLs*.
- **Modo de Prueba**: Opción interactiva para procesar un número limitado de apps (optimizado con `-Top`).
- **Alto Rendimiento**: Utiliza procesamiento en paralelo (`-Parallel`) para manejar miles de aplicaciones rápidamente.
*(Auth: Certificado)*

#### `sc-Generar-ReporteLicencias.ps1`

Reporte detallado de licenciamiento por usuario. Traduce los `SkuPartNumber` a nombres comerciales legibles e incluye la última fecha de inicio de sesión.
*(Auth: Certificado)*

#### `sc-Generar-ReporteLicenciasGrupos.ps1`

Analiza el *Group-Based Licensing*. Muestra qué licencias están asignadas a qué grupos, incluyendo planes de servicio deshabilitados específicamente y conteo de miembros.
*(Auth: Certificado)*

#### `sc-Generar-ReporteDeUsoM365.ps1`

Informe de consumo de almacenamiento. Incluye tamaño de buzón principal, buzón de archivo y uso de OneDrive for Business por usuario.
*(Auth: Certificado + Exchange Online)*

#### `sc-Generar-ReporteRolesAdmin.ps1`

Identifica a los usuarios con roles privilegiados activos (Global Admin, Security Admin, etc.) en el directorio.
*(Auth: Certificado)*

#### `sc-Generar-ReportePermisosServicePrincipals.ps1`

Auditoría de seguridad que lista todos los permisos de API asignados a los Service Principals del tenant, con alertas sobre permisos de alto privilegio.
*(Auth: Certificado)*

#### `sc-Generar-CuentaUsuariosLicenciados-Paralelo.ps1`

Obtiene un recuento rápido de usuarios licenciados en tenants muy grandes mediante procesamiento multi-hilo (`-Parallel`).
*(Auth: Certificado)*

#### `sc-Encontrar-GruposComunesUsuarios.ps1`

Herramienta de diagnóstico que identifica grupos de seguridad o M365 compartidos entre una lista de usuarios proporcionada.
*(Auth: Certificado)*

#### `sc-Investigar-SignIn-CorrelationId.ps1`

Investiga un intento de inicio de sesión fallido a partir de su Correlation ID. Muestra detalles del usuario, dispositivo, error técnico y analiza qué políticas de Acceso Condicional causaron el bloqueo.
*(Auth: Certificado)*

#### `sc-Encontrar-AlcanceGruposCA.ps1`

Identifica qué políticas de Acceso Condicional (CA) incluyen o excluyen grupos específicos de Microsoft Entra ID. Solicita al usuario una lista de Object IDs y audita si están explícitamente configurados en las políticas del tenant.
*(Auth: Certificado)*

### 🛠️ Administración y Utilidades

#### `sc-Renombrar-Grupos-Masivo.ps1`

Renombra masivamente grupos de seguridad en Microsoft Entra ID a partir de un archivo CSV. El script prioriza la búsqueda por Object ID para evitar ambigüedades; si el ID no está disponible, realiza un fallback por DisplayName exacto. Detecta automáticamente grupos que ya tienen el nombre correcto para evitar llamadas innecesarias a la API, y genera un reporte final con el estado de cada operación (Exitoso, Omitido, Error).
*(Auth: Certificado)*

**Estructura del CSV Requerido:**
El archivo debe contener exactamente las siguientes columnas (encabezados):
`nombreActual,groupId,nombreNuevo`

* **nombreActual**: Nombre actual del grupo. Se usa como fallback de búsqueda si `groupId` está vacío.
* **groupId**: Object ID del grupo en Entra ID. Prioritario y recomendado para evitar conflictos con nombres duplicados.
* **nombreNuevo**: Nombre que se asignará al grupo.

#### `sc-Renombrar-PoliticasIntune-Masivo.ps1`

Automatiza la actualización masiva de nombres de múltiples tipos de políticas en Microsoft Intune (Device Configuration, Settings Catalog, Compliance, Endpoint Security, Scripts, Update Rings y Administrative Templates) basándose en un archivo CSV. Utiliza APIs en versión beta en los casos necesarios para localizar todos los perfiles de configuración de forma transparente.
*(Auth: Certificado)*

**Estructura del CSV Requerido:**
El archivo debe contener exactamente las siguientes columnas (encabezados):
`Nombre actual`, `Nombre sugerido`

#### `sc-Crear-Usuarios-Masivo.ps1`

Crea usuarios masivamente en Entra ID a partir de un CSV, generando contraseñas aleatorias seguras que cumplen las políticas de complejidad. Genera un reporte final confidencial con las credenciales creadas y los detalles de la operación.
*(Auth: Certificado)*

**Estructura del CSV Requerido:**

  * **Columnas Obligatorias:** `upn`, `DisplayName`
  * **Columnas Opcionales:** `jobTitle`, `department`, `country`, `mobilePhone`, `firstName`, `lastName`
  * *Nota: Si no se proporciona `DisplayName` pero sí `firstName` y `lastName`, el script lo construirá automáticamente.*

#### `sc-Crear-AppRegistrations-Masivo.ps1`

Crea masivamente App Registrations en Entra ID a partir de un archivo CSV. Configura automáticamente las Redirect URIs, Logout URL, Flujos de ID Token y asigna propietarios. Genera un reporte final con URLs directas de administración.
*(Auth: Certificado)*

**Estructura del CSV Requerido:**
El archivo debe contener exactamente las siguientes columnas (encabezados):
`AppName,RedirectURL,LogOutURL,idTokenRequired,owner`

#### `sc-Agregar-OwnerGrupos.ps1`

Automatización para asignar un Owner (Usuario o Service Principal) a una lista masiva de grupos desde un archivo Excel.
*(Auth: Certificado)*

#### `sc-Asignar-PermisosGraph-ManagedIdentity.ps1`

Script para asignar permisos de Graph API (App Roles) a una Managed Identity de Azure de forma programática.
*(Auth: Certificado)*

#### `sc-Crear-Certificado-PowerShell.ps1`

Utilidad para generar y exportar certificados autofirmados para autenticación.

#### `sc-Gestionar-MembresiaGrupos-Masivo.ps1`

Gestiona el ciclo de vida de la membresía de usuarios en grupos (agregar o retirar) de forma masiva procesando un archivo CSV. El script es capaz de identificar el grupo objetivo por su ID (prioritario) o por su nombre exacto.
*(Auth: Certificado)*

**Estructura del CSV Requerido:**
El archivo debe contener las siguientes columnas (el orden no es estricto, pero los nombres de encabezado sí):
`upn,groupName,groupId,action`

  * **upn**: El User Principal Name del usuario.
  * **action**: Debe ser `agregar` o `retirar`.
  * **groupId** / **groupName**: Se debe llenar al menos uno. El script prioriza `groupId`; si está vacío, buscará por `groupName`.

## 👤 Autor

**Juan Sánchez**

## ⚠️ Descargo de Responsabilidad

Estos scripts se proporcionan "tal cual", sin garantía de ningún tipo. Úselos bajo su propio riesgo. Se recomienda encarecidamente revisar el código y probarlo en un entorno de desarrollo antes de ejecutarlo en producción.