# Scripts de PowerShell para Microsoft 365

Este repositorio contiene una colección de scripts de PowerShell diseñados para automatizar tareas de administración, auditoría y generación de informes en entornos de Microsoft 365. Los scripts utilizan autenticación desatendida a través de un App Registration en Microsoft Entra ID, permitiendo su ejecución sin intervención manual.

## Características

* **Autenticación Desatendida**: Conexión segura a Microsoft Graph y Exchange Online mediante un principal de servicio (App Registration).
* **Configuración Externalizada**: Los parámetros sensibles como IDs de tenant y cliente se gestionan en un archivo `config.json` para no exponerlos en el código.
* **Manejo Seguro de Secretos**: El secreto del cliente se almacena de forma segura en un archivo XML encriptado, que solo puede ser utilizado por el usuario que lo creó en el mismo equipo.
* **Generación de Informes**: Exporta los datos recopilados a archivos CSV para fácil análisis y auditoría.
* **Instalación Automática de Módulos**: Los scripts verifican e intentan instalar los módulos de PowerShell requeridos (`Microsoft.Graph`, `ExchangeOnlineManagement`) si no están presentes.

## Prerrequisitos

* **PowerShell**: Versión 5.1 o superior.
* **App Registration en Microsoft Entra ID**: Se necesita una aplicación registrada en el tenant con los permisos de API correspondientes consentidos por un administrador.

## Permisos de API Requeridos

Asegúrese de que el *Service Principal* de su App Registration tenga los siguientes permisos de API (tipo `Aplicación`) consentidos:

| Script                                      | API                    | Permisos Necesarios                                        |
| :------------------------------------------ | :--------------------- | :--------------------------------------------------------- |
| **sc-Generar-ReporteDeUsoM365.ps1** | Microsoft Graph        | `User.Read.All`, `Files.Read.All`, `Directory.Read.All`    |
|                                             | Office 365 Exchange Online | `Exchange.ManageAsApp`                                     |
| **sc-Generar-ReporteLicencias.ps1** | Microsoft Graph        | `User.Read.All`, `Directory.Read.All`, `AuditLog.Read.All` |
| **sc-Generar-ReporteRolesAdmin.ps1** | Microsoft Graph        | `RoleManagement.Read.Directory`, `User.Read.All`           |

**Nota importante**: Para el script `sc-Generar-ReporteDeUsoM365.ps1`, el Service Principal debe tener asignado un rol de administrador en Exchange Online (ej. `Global Reader` o `View-Only Organization Management`).

## Configuración Inicial

Siga estos pasos para configurar su entorno antes de ejecutar los scripts.

### 1. Clonar el Repositorio

```bash
git clone <URL_DEL_REPOSITORIO>
cd <NOMBRE_CARPETA_REPOSITORIO>
```

### 2. Crear el Archivo de Configuración

Cree un archivo llamado `config.json` en la raíz del directorio. Este archivo contendrá los parámetros de conexión. Copie la siguiente plantilla y rellene sus valores.

```json
{
  "tenantId": "SU_ID_DE_TENANT_AQUI",
  "clientId": "SU_ID_DE_CLIENTE_(APLICACION)_AQUI",
  "organizationName": "SU_ORGANIZACION.onmicrosoft.com",
  "certThumbprint": "HUELLA_DEL_CERTIFICADO_PARA_EXCHANGE",
  "dnsName": "su.dominio.com"
}
```
*Nota: `certThumbprint` y `dnsName` solo son requeridos por los scripts que se conectan a Exchange Online.*

### 3. Crear el Secreto Encriptado

Para evitar almacenar el secreto del cliente en texto plano, los scripts utilizan un archivo `secret.xml` encriptado. Para crearlo, abra una terminal de PowerShell y ejecute el siguiente comando, reemplazando `"SU_SECRETO_AQUI"` con el secreto real de su App Registration.

```powershell
"SU_SECRETO_AQUI" | ConvertTo-SecureString -AsPlainText -Force | Export-CliXml -Path ".\secret.xml"
```
Este comando creará el archivo `secret.xml`. **Importante**: Este archivo solo puede ser desencriptado por el mismo usuario y en el mismo equipo donde fue creado.

### 4. Crear y Subir el Certificado (Para Exchange Online)

El script `sc-Generar-ReporteDeUsoM365.ps1` utiliza un certificado para la autenticación en Exchange Online.

1.  Asegúrese de que el parámetro `dnsName` en su `config.json` sea correcto.
2.  Ejecute el script `sc-Crear-CertificadoExchangePowerShell.ps1`. Le pedirá una contraseña para proteger el archivo `.pfx` resultante.
3.  Una vez creado, suba el archivo `.cer` a su App Registration en el portal de Microsoft Entra ID (en la sección *Certificados y secretos*).
4.  Copie la **huella digital (Thumbprint)** del certificado y péguela en el campo `certThumbprint` de su `config.json`.

## Scripts Incluidos

#### `sc-Generar-ReporteDeUsoM365.ps1`
Genera un informe CSV que detalla el uso del almacenamiento para cada usuario, incluyendo:
* Tamaño del buzón principal.
* Tamaño del buzón de archivo.
* Espacio utilizado en OneDrive.

#### `sc-Generar-ReporteLicencias.ps1`
Audita las licencias de Microsoft 365. El informe CSV resultante incluye:
* Nombre del usuario y UPN.
* Licencias asignadas (con nombres comerciales, p. ej., "Microsoft 365 E5").
* Fecha del último inicio de sesión.

#### `sc-Generar-ReporteRolesAdmin.ps1`
Crea un informe de los usuarios que son miembros de roles de administrador privilegiados (como Administrador Global, Administrador de Exchange, etc.). El informe CSV detalla:
* Nombre del rol.
* Nombre del miembro.
* User Principal Name (UPN) del miembro.

#### `sc-Crear-CertificadoExchangePowerShell.ps1`
Script de utilidad para crear un nuevo certificado autofirmado y exportarlo a los formatos `.pfx` y `.cer`, necesarios para la autenticación basada en certificados con Exchange Online.

## Cómo Ejecutar un Script

Después de completar la configuración inicial:

1.  Abra una terminal de PowerShell.
2.  Navegue a la carpeta del repositorio.
3.  Ejecute el script deseado. Por ejemplo:

```powershell
.\sc-Generar-ReporteLicencias.ps1
```

El script se conectará a los servicios necesarios, recopilará los datos y generará un archivo CSV con los resultados en la misma carpeta.

## Autor

Juan Sánchez

## Descargo de Responsabilidad

Estos scripts se proporcionan "tal cual", sin garantía de ningún tipo. Úselos bajo su propio riesgo. Siempre es recomendable probarlos primero en un entorno de desarrollo o de prueba.
Fueron probados y validados en entornos de prueba y producción.