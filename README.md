# Scripts de PowerShell para Microsoft 365

Este repositorio contiene una colección de scripts de PowerShell diseñados para automatizar tareas de administración, auditoría y generación de informes en entornos de Microsoft 365. Los scripts utilizan autenticación desatendida a través de un App Registration en Microsoft Entra ID, permitiendo su ejecución sin intervención manual.

## Características

  * **Autenticación Desatendida**: Conexión segura a Microsoft Graph y Exchange Online mediante un Service Principal (App Registration), utilizando tanto secretos de cliente como certificados.
  * **Configuración Externalizada**: Los parámetros sensibles como IDs de tenant y cliente se gestionan en un archivo `config.json` para no exponerlos en el código.
  * **Manejo Seguro de Secretos**: Para los scripts que lo requieren, el secreto del cliente se almacena de forma segura en un archivo XML encriptado, que solo puede ser utilizado por el usuario que lo creó en el mismo equipo.
  * **Generación de Informes**: Exporta los datos recopilados a archivos CSV para fácil análisis y auditoría.
  * **Instalación Automática de Módulo**: Los scripts verifican e intentan instalar los módulos de PowerShell requeridos (`Microsoft.Graph`, `ExchangeOnlineManagement`) si no están presentes.

## Prerrequisitos

  * **PowerShell**: Versión 5.1 o superior. Se recomienda la 7+ para scripts que usan `-Parallel`.
  * **App Registration en Microsoft Entra ID**: Se necesita una aplicación registrada en el tenant con los permisos de API correspondientes consentidos por un administrador.

## Permisos de API Requeridos

Asegúrese de que el *Service Principal* de su App Registration tenga los siguientes permisos de API (tipo `Aplicación`) consentidos:

| Script | API | Permisos Necesarios |
| :--- | :--- | :--- |
| **sc-Generar-ReporteAppsSSO.ps1** | Microsoft Graph | `Application.Read.All`, `Directory.Read.All`, `DelegatedPermissionGrant.Read.All` |
| **sc-Generar-CuentaUsuariosLicenciados-Paralelo.ps1** | Microsoft Graph | `User.Read.All` |
| **sc-Encontrar-GruposComunesUsuarios.ps1** | Microsoft Graph | `User.Read.All`, `Group.Read.All`, `Directory.Read.All` |
| **sc-Agregar-OwnerGrupos.ps1** | Microsoft Graph | `GroupMember.ReadWrite.All`, `User.Read.All`, `Application.Read.All` |
| **sc-Generar-ReporteDeUsoM365.ps1** | Microsoft Graph | `User.Read.All`, `Files.Read.All`, `Directory.Read.All` |
| | Office 365 Exchange Online | `Exchange.ManageAsApp` |
| **sc-Generar-ReporteLicenciasGrupos.ps1** | Microsoft Graph | `Group.Read.All`, `Directory.Read.All`, `GroupMember.Read.All` |
| **sc-Generar-ReporteLicencias.ps1** | Microsoft Graph | `User.Read.All`, `Directory.Read.All`, `AuditLog.Read.All` |
| **sc-Generar-ReporteRolesAdmin.ps1** | Microsoft Graph | `RoleManagement.Read.Directory`, `User.Read.All` |
| **sc-Generar-ReportePermisosServicePrincipals.ps1**| Microsoft Graph | `Application.Read.All`, `AppRoleAssignment.ReadWrite.All`, `Directory.Read.All` |
| **sc-Asignar-PermisosGraph-ManagedIdentity.ps1**| Microsoft Graph | `AppRoleAssignment.ReadWrite.All` |

**Nota importante**: Para el script `sc-Generar-ReporteDeUsoM365.ps1`, el Service Principal debe tener asignado un rol de administrador en Exchange Online (ej. `Global Reader` o `View-Only Organization Management`).

## Configuración Inicial

Siga estos pasos para configurar su entorno antes de ejecutar los scripts.

### 1\. Clonar el Repositorio

```bash
git clone <URL_DEL_REPOSITORIO>
cd <NOMBRE_CARPETA_REPOSITORIO>
```

### 2\. Crear el Archivo de Configuración

Cree un archivo llamado `config.json` en la raíz del directorio. Este archivo contendrá los parámetros de conexión. Copie la siguiente plantilla y rellene sus valores.

```json
{
  "tenantId": "SU_ID_DE_TENANT_AQUI",
  "clientId": "SU_ID_DE_CLIENTE_(APLICACION)_AQUI",
  "organizationName": "SU_ORGANIZACION.onmicrosoft.com",
  "certThumbprint": "HUELLA_DEL_CERTIFICADO_AQUI",
  "dnsName": "su.dominio.com"
}
```

*Nota: `certThumbprint`, `organizationName` y `dnsName` solo son requeridos por los scripts que se conectan usando un certificado (a Exchange Online o a Microsoft Graph).*

### 3\. Crear el Secreto Encriptado (Si es necesario)

Algunos scripts utilizan un archivo `secret.xml` encriptado para la autenticación con Microsoft Graph. Para crearlo, abra una terminal de PowerShell y ejecute el siguiente comando, reemplazando `"SU_SECRETO_AQUI"` con el secreto real de su App Registration.

```powershell
"SU_SECRETO_AQUI" | ConvertTo-SecureString -AsPlainText -Force | Export-CliXml -Path ".\secret.xml"
```

**Importante**: Este archivo solo puede ser desencriptado por el mismo usuario y en el mismo equipo donde fue creado.

### 4\. Crear y Subir el Certificado (Si es necesario)

Los scripts que se conectan a Exchange Online o los que usan autenticación por certificado para Graph requieren un certificado.

1.  Asegúrese de que el parámetro `dnsName` en su `config.json` sea correcto.
2.  Ejecute el script `sc-Crear-Certificado-PowerShell.ps1`. Le pedirá una contraseña para proteger el archivo `.pfx` resultante.
3.  Una vez creado, suba el archivo `.cer` a su App Registration en el portal de Microsoft Entra ID (en la sección *Certificados y secretos*).
4.  Copie la **huella digital (Thumbprint)** del certificado y péguela en el campo `certThumbprint` de su `config.json`.

## Scripts Incluidos

#### `sc-Generar-ReporteAppsSSO.ps1`

Genera un informe de auditoría unificado de todas las Aplicaciones Empresariales, incluyendo los tipos 'Application' y 'Legacy'. El reporte en CSV incluye una columna `App_Type` para diferenciarlas, el estado, si requiere asignación, el tipo de SSO y el conteo de usuarios/grupos asignados (estos últimos campos solo para las de tipo 'Application').
*(Método de autenticación: Certificado para Graph)*

#### `sc-Agregar-OwnerGrupos.ps1`

Agrega un principal (usuario por UPN o Service Principal por App ID) como propietario a una lista de grupos cargada desde un archivo Excel. Genera un reporte detallado de la operación.
*(Método de autenticación: Certificado para Graph)*

#### `sc-Asignar-PermisosGraph-ManagedIdentity.ps1`

Asigna un conjunto predefinido de permisos de Microsoft Graph a una Identidad Administrada (Managed Identity) a partir de su App ID.
*(Método de autenticación: Certificado para Graph)*

#### `sc-Generar-CuentaUsuariosLicenciados-Paralelo.ps1`

Obtiene el recuento total de usuarios con al menos una licencia de Microsoft 365 asignada, utilizando procesamiento en paralelo para optimizar la consulta en tenants muy grandes.
*(Método de autenticación: Certificado para Graph)*

#### `sc-Encontrar-GruposComunesUsuarios.ps1`

Busca grupos de seguridad y de Microsoft 365 compartidos entre un listado de 3 a 5 usuarios.
*(Método de autenticación: Certificado para Graph)*

#### `sc-Generar-ReporteDeUsoM365.ps1`

Genera un informe CSV que detalla el uso del almacenamiento para cada usuario, incluyendo el tamaño del buzón principal, del buzón de archivo y el espacio utilizado en OneDrive.
*(Método de autenticación: Certificado para Graph y Exchange Online)*

#### `sc-Generar-ReporteLicenciasGrupos.ps1`

Genera un informe de las licencias asignadas a grupos (Group-Based Licensing) y los servicios deshabilitados en cada una, incluyendo el recuento de miembros del grupo.
*(Método de autenticación: Certificado para Graph)*

#### `sc-Generar-ReporteLicencias.ps1`

Audita las licencias de Microsoft 365. El informe CSV resultante incluye el nombre del usuario, UPN, licencias asignadas (con nombres comerciales) y su fecha del último inicio de sesión.
*(Método de autenticación: Secreto para Graph)*

#### `sc-Generar-ReporteRolesAdmin.ps1`

Crea un informe de los usuarios que son miembros de roles de administrador privilegiados. El informe CSV detalla el nombre del rol y los datos del miembro.
*(Método de autenticación: Secreto para Graph)*

#### `sc-Generar-ReportePermisosServicePrincipals.ps1`

Realiza una auditoría de los permisos de API asignados a todos los Service Principals en el tenant, clasificándolos y destacando aquellos con privilegios elevados.
*(Método de autenticación: Certificado para Graph)*

#### `sc-Crear-Certificado-PowerShell.ps1`

Script de utilidad para crear un nuevo certificado autofirmado y exportarlo a los formatos `.pfx` y `.cer`, necesarios para la autenticación basada en certificados.

## Cómo Ejecutar un Script

Después de completar la configuración inicial:

1.  Abra una terminal de PowerShell.
2.  Navegue a la carpeta del repositorio.
3.  Ejecute el script deseado. Por ejemplo:

<!-- end list -->

```powershell
.\sc-Generar-ReporteLicencias.ps1
```

El script se conectará a los servicios necesarios, recopilará los datos y generará un archivo CSV con los resultados en la misma carpeta.

## Autor

Juan Sánchez

## Descargo de Responsabilidad

Estos scripts se proporcionan "tal cual", sin garantía de ningún tipo. Úselos bajo su propio riesgo. Siempre es recomendable probarlos primero en un entorno de desarrollo o de prueba. Fueron probados y validados en entornos de prueba y producción.