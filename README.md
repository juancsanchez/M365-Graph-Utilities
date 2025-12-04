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
| **sc-Crear-AppRegistrations-Masivo.ps1** | Microsoft Graph | `Application.ReadWrite.All`, `User.Read.All`, `Directory.Read.All` |

## ⚙️ Configuración Inicial

### 1. Clonar el Repositorio
```bash
git clone <URL_DEL_REPOSITORIO>
cd <NOMBRE_CARPETA_REPOSITORIO>