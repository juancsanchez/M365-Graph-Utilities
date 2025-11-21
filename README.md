# Microsoft 365 Graph Utilities

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-blue?logo=powershell)
![Microsoft Graph](https://img.shields.io/badge/Microsoft%20Graph-API-blueviolet)
![Entra ID](https://img.shields.io/badge/Microsoft-Entra%20ID-0078D4)

Este repositorio contiene una colección de scripts de PowerShell optimizados para automatizar tareas de administración, auditoría y generación de informes en entornos de Microsoft 365. Los scripts están diseñados para operar con **autenticación desatendida** (App-Only) a través de Microsoft Entra ID, garantizando seguridad y eficiencia en ejecuciones programadas.

## 🚀 Características Principales

* **Autenticación Segura**: Implementación de Service Principals utilizando Certificados (recomendado) y Secretos de Cliente encriptados localmente.
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
| **sc-Generar-ReporteDeUsoM365.ps1** | Microsoft Graph | `User.Read.All`, `Files.Read.All`, `Directory.Read.All` |
| | Exchange Online | `Exchange.ManageAsApp` (Requiere Rol de Admin en EXO) |
| **sc-Generar-ReporteLicenciasGrupos.ps1** | Microsoft Graph | `Group.Read.All`, `GroupMember.Read.All` |
| **sc-Generar-ReporteLicencias.ps1** | Microsoft Graph | `User.Read.All`, `Directory.Read.All`, `AuditLog.Read.All` |
| **sc-Generar-ReporteRolesAdmin.ps1** | Microsoft Graph | `RoleManagement.Read.Directory`, `User.Read.All` |
| **sc-Generar-ReportePermisosServicePrincipals.ps1**| Microsoft Graph | `Application.Read.All`, `AppRoleAssignment.ReadWrite.All`, `Directory.Read.All` |
| **sc-Asignar-PermisosGraph-ManagedIdentity.ps1**| Microsoft Graph | `AppRoleAssignment.ReadWrite.All` |

## ⚙️ Configuración Inicial

### 1. Clonar el Repositorio
```bash
git clone <URL_DEL_REPOSITORIO>
cd <NOMBRE_CARPETA_REPOSITORIO>
````

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

### 3\. Seguridad de Secretos (Solo para scripts con Secreto)

Para scripts que requieren un *Client Secret* en lugar de certificado, genere el archivo encriptado `secret.xml`:

```powershell
"SU_CLIENT_SECRET_TEXTO_PLANO" | ConvertTo-SecureString -AsPlainText -Force | Export-CliXml -Path ".\secret.xml"
```

*Advertencia: El archivo `secret.xml` solo puede ser desencriptado por el usuario que lo creó en la misma máquina (DPAPI).*

### 4\. Certificados

Para crear un certificado autofirmado válido para pruebas o uso interno, ejecute:

```powershell
.\sc-Crear-Certificado-PowerShell.ps1
```

Esto generará un `.cer` (para subir a Azure) y un `.pfx` (para instalar localmente).
El usuario y la contraseña pueden ser cualquier palabra, solo tenga presente recordar la contraseña para instalar el certificado en otros dispositivos en el futuro.

-----

## 📂 Scripts Incluidos

### 📊 Auditoría y Reportes

#### `sc-Generar-ReporteMFAporUsuario.ps1`

Genera una radiografía del estado de seguridad de los usuarios. Detalla si tienen MFA registrado, el estado de SSPR, si son *Passwordless Capable* y lista todos los métodos de autenticación configurados (Authenticator, Teléfono, FIDO2, etc.).
*(Auth: Certificado)*

#### `sc-Generar-ReporteAppsSSO.ps1`

Auditoría unificada de Aplicaciones Empresariales (Modernas y Legacy). Identifica el tipo de SSO (SAML, OIDC), estado de la cuenta y conteo de usuarios/grupos asignados.
*(Auth: Certificado)*

#### `sc-Generar-ReporteLicencias.ps1`

Reporte detallado de licenciamiento por usuario. Traduce los `SkuPartNumber` a nombres comerciales legibles e incluye la última fecha de inicio de sesión.
*(Auth: Secreto)*

#### `sc-Generar-ReporteLicenciasGrupos.ps1`

Analiza el *Group-Based Licensing*. Muestra qué licencias están asignadas a qué grupos, incluyendo planes de servicio deshabilitados específicamente y conteo de miembros.
*(Auth: Certificado)*

#### `sc-Generar-ReporteDeUsoM365.ps1`

Informe de consumo de almacenamiento. Incluye tamaño de buzón principal, buzón de archivo y uso de OneDrive for Business por usuario.
*(Auth: Certificado + Exchange Online)*

#### `sc-Generar-ReporteRolesAdmin.ps1`

Identifica a los usuarios con roles privilegiados activos (Global Admin, Security Admin, etc.) en el directorio.
*(Auth: Secreto)*

#### `sc-Generar-ReportePermisosServicePrincipals.ps1`

Auditoría de seguridad que lista todos los permisos de API asignados a los Service Principals del tenant, con alertas sobre permisos de alto privilegio.
*(Auth: Certificado)*

#### `sc-Generar-CuentaUsuariosLicenciados-Paralelo.ps1`

Obtiene un recuento rápido de usuarios licenciados en tenants muy grandes mediante procesamiento multi-hilo (`-Parallel`).
*(Auth: Certificado)*

#### `sc-Encontrar-GruposComunesUsuarios.ps1`

Herramienta de diagnóstico que identifica grupos de seguridad o M365 compartidos entre una lista de usuarios proporcionada.
*(Auth: Certificado)*

### 🛠️ Administración y Utilidades

#### `sc-Agregar-OwnerGrupos.ps1`

Automatización para asignar un Owner (Usuario o Service Principal) a una lista masiva de grupos desde un archivo Excel.
*(Auth: Certificado)*

#### `sc-Asignar-PermisosGraph-ManagedIdentity.ps1`

Script para asignar permisos de Graph API (App Roles) a una Managed Identity de Azure de forma programática.
*(Auth: Certificado)*

#### `sc-Crear-Certificado-PowerShell.ps1`

Utilidad para generar y exportar certificados autofirmados para autenticación.

## 👤 Autor

**Juan Sánchez**

## ⚠️ Descargo de Responsabilidad

Estos scripts se proporcionan "tal cual", sin garantía de ningún tipo. Úselos bajo su propio riesgo. Se recomienda encarecidamente revisar el código y probarlo en un entorno de desarrollo antes de ejecutarlo en producción.