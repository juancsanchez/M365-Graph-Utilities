Scripts de PowerShell para Microsoft 365
Este repositorio contiene una colección de scripts de PowerShell diseñados para automatizar tareas de administración, auditoría y generación de informes en entornos de Microsoft 365. Los scripts utilizan autenticación desatendida a través de un App Registration en Microsoft Entra ID, permitiendo su ejecución sin intervención manual.

Características
Autenticación Desatendida: Conexión segura a Microsoft Graph y Exchange Online mediante un principal de servicio (App Registration).
Configuración Externalizada: Los parámetros sensibles como IDs de tenant y cliente se gestionan en un archivo config.json para no exponerlos en el código.
Manejo Seguro de Secretos: El secreto del cliente se almacena de forma segura en un archivo XML encriptado.
Generación de Informes: Exporta los datos recopilados a archivos CSV para fácil análisis y auditoría.
Instalación Automática de Módulos: Los scripts verifican e intentan instalar los módulos de PowerShell requeridos si no están presentes.
Prerrequisitos
Antes de utilizar estos scripts, asegúrese de cumplir con los siguientes requisitos:

PowerShell: Versión 5.1 o superior.

Módulos de PowerShell:

Microsoft.Graph
ExchangeOnlineManagement (Nota: Los scripts intentarán instalarlos automáticamente desde la Galería de PowerShell si no los detectan).
App Registration en Microsoft Entra ID:
Necesitará una aplicación registrada en su tenant con los siguientes permisos de API (tipo aplicación) consentidos por un administrador:

Para el reporte de uso (dt-Generar-ReporteDeUsoM365.ps1):
Microsoft Graph: User.Read.All, Files.Read.All, Directory.Read.All
Office 365 Exchange Online: Exchange.ManageAsApp
Para el reporte de licencias (dt-Generar-ReporteLicencias.ps1):
Microsoft Graph: User.Read.All, Directory.Read.All, AuditLog.Read.All
Para el reporte de roles de administrador (dt-Generar-ReporteRolesAdmin.ps1):
Microsoft Graph: RoleManagement.Read.Directory, User.Read.All
Rol de Administrador para el Service Principal:
Para el script que se conecta a Exchange Online (dt-Generar-ReporteDeUsoM365.ps1), el Service Principal de su App Registration debe tener un rol administrativo en Exchange Online (p. ej., Global Reader o View-Only Organization Management).

Configuración Inicial
Siga estos pasos para configurar su entorno antes de ejecutar los scripts.

1. Clonar el Repositorio

Bash
git clone <URL_DEL_REPOSITORIO>
cd <NOMBRE_CARPETA_REPOSITORIO>
2. Crear el Archivo de Configuración

Cree un archivo llamado config.json en la raíz del directorio. Este archivo contendrá los parámetros de conexión. Copie y pegue la siguiente plantilla y rellene sus valores.

JSON
{
  "tenantId": "SU_ID_DE_TENANT_AQUI",
  "clientId": "SU_ID_DE_CLIENTE_(APLICACION)_AQUI",
  "organizationName": "SU_ORGANIZACION.onmicrosoft.com",
  "certThumbprint": "HUELLA_DEL_CERTIFICADO_PARA_EXCHANGE",
  "dnsName": "su.dominio.com"
}
Nota: certThumbprint y dnsName solo son requeridos por los scripts que se conectan a Exchange Online o crean certificados.

3. Crear el Secreto Encriptado

Para evitar almacenar el secreto del cliente en texto plano, los scripts utilizan un archivo secret.xml encriptado. Para crearlo, abra una terminal de PowerShell y ejecute el siguiente comando, reemplazando "SU_SECRETO_AQUI" con el secreto real de su App Registration.

PowerShell
"SU_SECRETO_AQUI" | ConvertTo-SecureString -AsPlainText -Force | Export-CliXml -Path ".\secret.xml"
Este comando creará el archivo secret.xml en la misma carpeta. Importante: Este archivo solo puede ser desencriptado por el mismo usuario y en el mismo equipo donde fue creado.

4. Crear y Exportar el Certificado (si es necesario)

El script dt-Generar-ReporteDeUsoM365.ps1 utiliza un certificado para la autenticación en Exchange Online.

Asegúrese de que el parámetro dnsName en su config.json sea correcto.
Ejecute el script dt-Crear-CertificadoExchangePowerShell.ps1. Le pedirá una contraseña para proteger el archivo .pfx.
Una vez creado, suba el archivo .cer a su App Registration en Azure y copie la huella digital (Thumbprint) del certificado en el campo certThumbprint de su config.json.
Scripts Incluidos
dt-Generar-ReporteDeUsoM365.ps1

Genera un informe CSV que detalla el uso del almacenamiento para cada usuario, incluyendo:

Tamaño del buzón principal.
Tamaño del buzón de archivo.
Espacio utilizado en OneDrive.
dt-Generar-ReporteLicencias.ps1

Audita las licencias de Microsoft 365. El informe CSV resultante incluye:

Nombre del usuario y UPN.
Licencias asignadas (con nombres comerciales, p. ej., "Microsoft 365 E5").
Fecha del último inicio de sesión.
dt-Generar-ReporteRolesAdmin.ps1

Crea un informe de los usuarios que son miembros de roles de administrador privilegiados (como Administrador Global, Administrador de Exchange, etc.). El informe CSV detalla:

Nombre del rol.
Nombre del miembro.
User Principal Name (UPN) del miembro.
dt-Crear-CertificadoExchangePowerShell.ps1

Script de utilidad para crear un nuevo certificado autofirmado y exportarlo a los formatos .pfx y .cer, necesarios para la autenticación basada en certificados con Exchange Online.

Cómo Ejecutar un Script
Después de completar la configuración inicial:

Abra una terminal de PowerShell.
Navegue a la carpeta del repositorio.
Ejecute el script deseado. Por ejemplo:
PowerShell
.\dt-Generar-ReporteLicencias.ps1
El script se conectará a los servicios necesarios, recopilará los datos y generará un archivo CSV con los resultados en la misma carpeta.

Autor
Juan Sánchez
Descargo de Responsabilidad
Estos scripts se proporcionan "tal cual", sin garantía de ningún tipo. Úselos bajo su propio riesgo. Siempre es recomendable probarlos primero en un entorno de desarrollo o de prueba.