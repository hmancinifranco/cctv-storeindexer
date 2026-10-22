# Manual de implementación — Video Archive Pilot

**Última revisión:** 2026-10-22
**Audiencia:** equipo del cliente y SA que conduce el deployment

Este documento es el recorrido principal para desplegar, probar y, si corresponde, retirar el piloto en una cuenta AWS del cliente. Los runbooks especializados continúan disponibles, pero este manual define el orden y los puntos de decisión de la reunión.

## 1. Alcance y limitaciones conocidas

El piloto despliega S3 privado, indexación automática, DynamoDB, API Gateway, Lambda, Cognito y una SPA privada detrás de CloudFront OAC. Permite cargar videos terminados, buscarlos por fecha/hora/cámara y emitir descargas temporales auditadas.

Antes de comenzar, comunicar y aceptar:

- El template todavía no implementa AWS WAF para CloudFront/API Gateway. El piloto puede operar con Cognito y `IP_ALLOWLIST_MODE=disabled` solo con aprobación explícita; no debe describirse como restringido por IP.
- La PoC incluye configuración de credenciales Windows, ejecución manual y registro en Task Scheduler con usuario IAM técnico → role acotado. Debe validarse en el Windows Server del cliente y acordar el contrato real de carpeta de archivos finalizados.
- CloudTrail S3 Data Events y alarmas operativas completas siguen pendientes. DynamoDB registra la emisión de URLs y el catálogo registra cambios de lifecycle; todavía no existe un journal inmutable de todos los eventos.
- La configuración segura inicial es `RETENTION_MODE=keep`. No habilitar expiración automática durante la reunión.
- No se migran los 90 TB. El alcance propuesto es un piloto de 3–5 cámaras, aproximadamente 7 días y 250–500 GB, sujeto a confirmación.

## 2. Datos que debe proporcionar el cliente

Registrar antes del deployment:

- Cuenta AWS de destino.
- Región del workload; la referencia probada es `us-east-1`.
- Método de autenticación para la persona que despliega: `aws login` con credenciales de consola, IAM Identity Center o access key como último recurso.
- Si usan `aws login`: usuario/rol de consola, región, AWS CLI 2.32+ y aprobación para adjuntar `SignInLocalDevelopmentAccess`.
- Si usan IAM Identity Center: URL de inicio o issuer URL, región SSO, cuenta y permission set/rol.
- Si excepcionalmente usan access key: nombre del usuario, permisos aprobados y entrega segura; nunca registrar la secret key en este manual.
- Email del primer operador.
- Nombre del stack, por ejemplo `video-archive-pilot`.
- Aprobación explícita para Cognito-only mientras WAF esté pendiente.
- Formato real de filenames, zona horaria, cámaras y carpeta de videos finalizados.
- Nombre del usuario IAM técnico para el uploader, sin acceso a consola ni permisos S3 directos.
- Responsable, canal de entrega y fecha de retiro de la access key de PoC.
- Decisión futura sobre PKI corporativa o AWS Private CA si se migra a IAM Roles Anywhere.

## 3. Herramientas de la estación de deployment

Instalar y verificar:

```bash
aws --version
sam --version
node --version
npm --version
python3 --version  # debe ser 3.12 o posterior
git --version
# Solo para el roadmap IAM Roles Anywhere:
openssl version
```

Se requiere AWS CLI v2. Para usar `aws login`, la versión mínima es **2.32.0**; con una versión anterior deben actualizar AWS CLI o usar IAM Identity Center.

En macOS, si `command -v aws` devuelve `/opt/homebrew/bin/aws`, actualice la instalación existente con:

```bash
brew update && brew upgrade awscli && hash -r && aws --version
```

La versión final debe ser `aws-cli/2.32.0` o posterior. Este comando no modifica perfiles ni credenciales. Si `aws` proviene de otra ruta, siga el [instalador oficial de AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) en lugar de mezclar métodos de instalación.

## 4. Configurar autenticación y el perfil de AWS CLI v2

### 4.1 Camino recomendado para usuario IAM o federación IAM — `aws login`

Este camino usa el mismo inicio de sesión de AWS Management Console para obtener credenciales temporales. Evita crear o copiar access keys permanentes. Si el cliente usa IAM Identity Center, vaya a la sección 4.2.

Un administrador del cliente debe:

1. Confirmar que la persona puede iniciar sesión en AWS Management Console con su usuario IAM o identidad federada.
2. Adjuntar la política administrada `SignInLocalDevelopmentAccess` al usuario, rol o grupo.
3. Asignar por separado los permisos necesarios para desplegar el piloto. `SignInLocalDevelopmentAccess` habilita el login local, pero no otorga permisos sobre S3, IAM, CloudFormation u otros servicios.
4. Confirmar la duración máxima de la sesión y MFA.

En la estación de deployment se requiere AWS CLI 2.32.0 o posterior:

```bash
aws --version
aws login --profile video-archive-deployer
```

AWS CLI solicita la región si todavía no existe y abre el navegador. Seleccione la sesión correcta o ingrese como usuario IAM; no use el usuario root. Luego verifique:

```bash
aws configure list --profile video-archive-deployer
aws sts get-caller-identity --profile video-archive-deployer --region us-east-1
```

AWS CLI renueva las credenciales temporales aproximadamente cada 15 minutos según necesidad. La sesión completa dura hasta 12 horas, limitada por la configuración de la identidad. Al terminar:

```bash
aws logout --profile video-archive-deployer
```

Fuente oficial: [AWS CLI login con credenciales de consola](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html).

### 4.2 Camino para IAM Identity Center

Un administrador debe asignar al responsable del deployment a la cuenta AWS y al permission set autorizado. Luego:

```bash
aws configure sso --profile video-archive-deployer
aws sso login --profile video-archive-deployer
```

El asistente solicita nombre de sesión, URL de inicio o issuer URL, región de IAM Identity Center, cuenta, permission set/rol, región por defecto del workload y formato `json`.

Verifique:

```bash
aws sts get-caller-identity --profile video-archive-deployer --region us-east-1
```

Fuente oficial: [Configurar IAM Identity Center con AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html).

### 4.3 Último recurso: usuario IAM con access key permanente

Use esta alternativa únicamente si `aws login` no está habilitado y el cliente no dispone de IAM Identity Center. AWS desaconseja credenciales de larga duración para acceso humano.

Un administrador debe:

1. Crear o seleccionar un usuario IAM dedicado al deployment; no usar root.
2. Asignar los permisos aprobados.
3. Crear una access key con caso de uso **Command Line Interface (CLI)**.
4. Entregarla por un canal seguro. La secret access key se muestra una sola vez y nunca debe enviarse por chat ni copiarse al proyecto.

Configure el perfil:

```bash
aws configure --profile video-archive-deployer
```

Ingrese access key ID, secret access key, `us-east-1` y formato `json` cuando el asistente lo solicite. No agregar las claves a `.env`: los scripts solo guardan allí el nombre del perfil.

Verifique:

```bash
aws configure list --profile video-archive-deployer
aws sts get-caller-identity --profile video-archive-deployer --region us-east-1
```

Después del piloto, rotar o desactivar la access key si ya no es necesaria.

Referencia oficial: [configuración de credenciales de larga duración](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-quickstart.html).

### 4.4 Compatibilidad con SAM y otros SDKs

Las versiones actuales de AWS SDKs y herramientas pueden usar el perfil generado por `aws login`. Mantenga AWS CLI y SAM CLI actualizados. Si una herramienta antigua no reconoce `login_session`, AWS documenta un puente mediante `credential_process`:

```bash
aws configure set credential_process "aws configure export-credentials --profile video-archive-deployer --format process" --profile video-archive-sam
aws configure set region us-east-1 --profile video-archive-sam
aws configure set output json --profile video-archive-sam
```

En ese caso, configure `AWS_PROFILE=video-archive-sam` en `.env`, pero renueve la sesión con:

```bash
aws login --profile video-archive-deployer
```

> **AWS CLI vs. AWS Toolkit:** este proyecto se despliega con AWS CLI v2 y SAM CLI. AWS Toolkit puede reutilizar perfiles, pero no sustituye `aws login`, `aws configure sso`, la verificación STS ni SAM CLI.

## 5. Preparar el proyecto

Desde una copia limpia del proyecto:

```bash
cd /ruta/cctv-storeindexer
[ -e .env ] || cp .env.example .env
```

Editar `.env`:

```dotenv
AWS_PROFILE=video-archive-deployer
AWS_REGION=us-east-1
PROJECT_NAME=cctv-storeindexer
STACK_NAME=video-archive-pilot
ENVIRONMENT=pilot

RETENTION_MODE=keep
RETENTION_DAYS=90
CATALOG_TOMBSTONE_RETENTION_DAYS=365

IP_ALLOWLIST_MODE=disabled
OFFICE_ALLOWED_CIDRS=

UPLOADER_IAM_USER_NAME=cctv-pilot-uploader
ROLES_ANYWHERE_ENABLED=false
INGEST_PREFIX=videos
```

Reglas:

- `.env` es local y está ignorado por Git.
- No colocar access keys, contraseñas ni claves privadas en `.env`.
- `RETENTION_DAYS` no elimina videos mientras `RETENTION_MODE=keep`.
- `IP_ALLOWLIST_MODE=disabled` requiere aprobación explícita y el flag `--allow-cognito-only`.

## 6. Preflight

```bash
./scripts/preflight.sh --allow-cognito-only
```

Revisar con el cliente la cuenta, ARN, región, stack, retención y advertencia de perímetro. No continuar si algún valor es incorrecto.

## 7. Deployment completo

```bash
./scripts/deploy-customer.sh --allow-cognito-only
```

El script ejecuta en orden:

1. Preflight.
2. SAM build/deploy.
3. Recuperación de outputs.
4. Configuración del frontend.
5. Instalación reproducible, typecheck, tests y build.
6. Publicación en el bucket privado de la SPA.
7. Invalidación de CloudFront.
8. Verificación de stack, S3, DynamoDB, frontend y API.

Resultado esperado: stack `CREATE_COMPLETE` o `UPDATE_COMPLETE`, frontend HTTP 200, health HTTP 200 y API anónima 401/403.

## 8. Crear el primer operador

```bash
./scripts/create-user.sh usuario@cliente.com
```

Cognito envía una contraseña temporal. El usuario debe establecer una contraseña nueva en el primer ingreso. No registrar contraseñas en documentos o chat.

## 9. Prueba inicial con carga manual

### Opción A — fixtures sintéticos

En un bucket nuevo:

```bash
./uploader/synthetic/upload_to_s3.sh
```

Carga archivos válidos, casos límite y filenames inválidos. Cada creación recorre S3 → EventBridge → SQS → Lambda → DynamoDB.

### Opción B — AVI pequeño del cliente

Usar una copia sanitizada y renombrada según la gramática temporal:

```text
CAM01_YYYYMMDD_HHMMSS-HHMMSS.avi
```

Subirla bajo el prefijo `videos/` mediante la consola S3 o AWS CLI. No mover el archivo original ni usar una grabación sensible sin aprobación.

## 10. Verificación funcional

```bash
./scripts/verify-deployment.sh
```

Después:

1. Abrir el output `CloudFrontUrl`.
2. Iniciar sesión con el operador de Cognito.
3. Buscar por fecha y cámara.
4. Confirmar que los nombres válidos estén `Disponible` y los inválidos aparezcan como `Metadata inválida`.
5. Descargar un fixture válido.
6. Confirmar el registro `DOWNLOAD_URL_ISSUED` en Audit sin almacenar la URL.
7. Verificar que la cola y DLQ estén vacías.

Para la demostración narrativa seguir `docs/demo-runbook.md`.

## 11. Uploader PoC — usuario IAM que asume un role acotado

### 11.1 Crear el usuario técnico antes del deployment

Un administrador del cliente crea un usuario IAM sin acceso a consola y sin políticas, por ejemplo `cctv-pilot-uploader`. No cree la access key todavía. Configure su nombre en `.env`:

```dotenv
UPLOADER_IAM_USER_NAME=cctv-pilot-uploader
ROLES_ANYWHERE_ENABLED=false
```

Durante el deployment, CloudFormation crea el role `<project>-<environment>-uploader`, limita sus permisos a PUT/multipart y listado de `videos/`, configura su trust para el ARN exacto del usuario y adjunta a ese usuario únicamente `sts:AssumeRole` sobre ese role.

### 11.2 Crear y custodiar la access key

Después del deployment, el administrador abre IAM → Users → `cctv-pilot-uploader` → Security credentials → Create access key, selecciona el caso de uso CLI y registra servidor/propietario/fecha de retiro. CloudFormation no crea la key, no la devuelve como output y no la almacena.

- Entregarla al administrador de Windows por un canal seguro.
- No enviarla por email/chat ni copiarla al repositorio.
- Registrar usuario, servidor, propietario y fecha de retiro.
- Mantener el usuario sin acceso directo a S3.

### 11.3 Configurar los perfiles Windows

Si AWS CLI v2 no está instalado, abra PowerShell como administrador:

```powershell
msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
aws --version
```

Cierre y vuelva a abrir PowerShell si `aws` todavía no aparece. Obtenga `UploaderRoleArn` y `VideoBucketName` desde los outputs y ejecute:

```powershell
.\uploader\iam-user\configure-profile.ps1 -RoleArn '<UploaderRoleArn>' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1'
```

El script solicita la access key interactivamente y configura:

- `cctv-uploader-source`: guarda la key y solo puede asumir el role.
- `cctv-uploader`: obtiene credenciales STS temporales de una hora y se usa para transferencias.

Nunca ejecute cargas con el perfil source. Pruebe primero con `-DryRun`, luego ejecute una carga real y recién después registre Task Scheduler:

```powershell
.\uploader\iam-user\upload-videos.ps1 -SourceDirectory 'D:\ReadyToUpload' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1' -DryRun
.\uploader\iam-user\upload-videos.ps1 -SourceDirectory 'D:\ReadyToUpload' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1'
.\uploader\iam-user\register-task.ps1 -SourceDirectory 'D:\ReadyToUpload' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1' -EveryMinutes 15 -MinimumFileAgeMinutes 5
```

Use la misma cuenta Windows para configurar perfiles y registrar/ejecutar la tarea. Ejecute `register-task.ps1` desde PowerShell elevado. El registrador copia el uploader a `C:\ProgramData\CctvUploader\bin`, crea/protege el directorio de logs y evita depender de la ubicación del checkout. El uploader solo sincroniza AVI cerrados y estables; si encuentra uno abierto/reciente pospone el lote. No usa `--delete`, no elimina el origen, evita solapamientos, reintenta fallas AWS y conserva backlog para el intervalo siguiente. Logs JSONL: `C:\ProgramData\CctvUploader\logs`.

El role puede subir/listar dentro del prefijo, pero no leer, borrar ni escribir fuera de `videos/`. El runbook operativo y troubleshooting están en [`../uploader/iam-user/README.md`](../uploader/iam-user/README.md).

### 11.4 Cerrar la excepción

Al finalizar la PoC, deshabilite o elimine la access key. El teardown elimina el role y la política de assume-role; no elimina el usuario IAM preexistente. El detalle está en [`../uploader/iam-user/README.md`](../uploader/iam-user/README.md).

## 12. Roadmap — IAM Roles Anywhere

### 12.1 Qué valida

IAM Roles Anywhere es la mejora recomendada para retirar la access key de la PoC. Permite que una máquina externa a AWS use un certificado X.509 para obtener credenciales temporales del mismo role uploader. El camino está documentado y validado desde macOS, pero no es requisito para el deployment de mañana.

La prueba local valida:

- certificado y clave utilizables;
- trust anchor y profile habilitados;
- llamada `CreateSession` mediante `aws_signing_helper`;
- identidad STS correspondiente al rol uploader;
- acceso limitado al prefijo configurado;
- ausencia de access keys persistentes.

### 12.2 CA y recursos de Roles Anywhere

IAM Roles Anywhere necesita una CA, pero no exige que el cliente ya tenga una PKI interna. Las opciones son:

| Escenario | Opción | Uso recomendado |
|---|---|---|
| Laboratorio/validación técnica | CA local temporal con OpenSSL | Solo ensayo controlado del roadmap; no requerida para la PoC de mañana |
| Piloto controlado | CA temporal con custodia formal, certificado por servidor y rotación corta | Aceptable únicamente con responsable y procedimiento acordados |
| Producción sin PKI propia | AWS Private CA | Alternativa administrada por AWS; evaluar costo y operación |
| Producción con PKI corporativa | CA interna existente | Registrar su certificado público como trust anchor |

Para nuestra CA temporal de prueba:

```bash
./uploader/roles-anywhere/setup_ca.sh
./uploader/roles-anywhere/setup_roles_anywhere.sh
```

`setup_ca.sh` crea material local bajo `uploader/roles-anywhere/certs/`, ignorado por Git. `setup_roles_anywhere.sh` crea/reutiliza el trust anchor mediante AWS CLI, despliega role/profile mediante SAM y guarda sus ARNs en `.env`.

Reglas para una CA temporal:

- `ca.key` se mantiene fuera del servidor uploader y no se comparte; solo firma certificados.
- El servidor recibe únicamente su propio `client.crt` y `client.key`.
- Emitir un certificado distinto por servidor para poder revocarlo individualmente.
- Usar vigencia corta y rotarlo antes del vencimiento; el ejemplo usa 90 días.
- Ante compromiso, deshabilitar el trust anchor para detener nuevas sesiones o importar una CRL generada por la CA. IAM Roles Anywhere verifica CRLs importadas, pero no consulta OCSP ni CRL Distribution Points.
- La CA OpenSSL del ejemplo no tiene automatización de emisión, rotación o revocación y no debe presentarse como diseño productivo.

Si el cliente no posee PKI, la PoC continúa con el usuario técnico → role acotado. Durante el piloto se decide si adoptar AWS Private CA o formalizar una CA propia antes de migrar a Roles Anywhere. No reutilizar nuestra CA demo en la cuenta del cliente.

Fuentes: [Introducción a IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html) y [prácticas de integración con PKI](https://aws.amazon.com/blogs/security/best-practices-for-integrating-iam-roles-anywhere-with-your-pki/).

### 12.3 Instalar el helper en macOS Apple Silicon

La versión validada por este proyecto es `1.8.5`. Instálela para el usuario actual con:

```bash
./scripts/install-roles-anywhere-helper-macos.sh
```

El instalador detecta Apple Silicon/Intel, descarga desde el endpoint oficial de AWS, verifica que el binario reporte `1.8.5` y lo instala en `$HOME/.local/bin/aws_signing_helper` sin `sudo`.

El test también acepta otra ubicación mediante `AWS_SIGNING_HELPER=/ruta/aws_signing_helper`.

Fuente oficial: [AWS IAM Roles Anywhere credential helper](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html).

### 12.4 Ejecutar prueba local sin modificar el perfil global

Primero pruebe solamente autenticación y autorización de lectura del prefijo:

```bash
./scripts/test-roles-anywhere-local.sh
```

Luego pruebe una carga real de un fixture sintético único:

```bash
./scripts/test-roles-anywhere-local.sh --upload-fixture
```

El script crea una configuración AWS temporal con una línea `credential_process`, llama a STS y valida la identidad. Sin flags no escribe. Con `--upload-fixture`, usa el rol Roles Anywhere para subir un AVI sintético de 256 bytes y usa el perfil de deployment solo para comprobar cifrado e indexación `AVAILABLE`. No modifica `~/.aws/config`, no imprime credenciales y no borra objetos.

Resultado esperado:

```text
OK: IAM Roles Anywhere emitió credenciales temporales válidas.
```

**Evidencia 2026-10-22:** validado desde macOS Apple Silicon con `aws_signing_helper` 1.8.5. `CreateSession` emitió credenciales temporales y STS devolvió el rol uploader esperado. Luego el rol subió `CAM93_20261022_161545.avi` (256 bytes), no pudo leerlo —confirmando mínimo privilegio— y el flujo S3 → EventBridge → SQS → Lambda lo indexó como `OK/AVAILABLE` con cifrado AES256. No se modificó el perfil global ni se imprimieron credenciales.

## 13. Estado de Glacier y eliminación

El catálogo diferencia `AVAILABLE`, `ARCHIVED`, `RESTORE_PENDING`, `RESTORED` y `DELETED`. Para el detalle de campos, tombstones, TTL, Glacier Instant/Flexible y restore, consultar `docs/lifecycle-states.md`.

No configurar transitions a Glacier durante la reunión. Primero se debe acordar SLA de recuperación y costos. `GLACIER_IR` permite acceso inmediato; `GLACIER` y `DEEP_ARCHIVE` requieren restore previo.

## 14. Teardown

Antes de tocar AWS:

1. Deshabilite y retire `CctvVideoUploader` con `remove-task.ps1`.
2. Confirme que no existe un proceso `aws` activo.
3. Deshabilite la access key del usuario técnico. Esto impide nuevas sesiones; las ya emitidas pueden durar hasta una hora.
4. Ante sospecha de compromiso, use **Revoke active sessions** en el uploader role.
5. No elimine todavía el usuario: el stack debe retirar primero su política inline.

El script de teardown verifica las keys activas y falla cerrado si detecta alguna.

### 14.1 Siempre comenzar con el plan

```bash
./scripts/teardown.sh --plan
```

No modifica recursos.

### 14.2 Retirar aplicación y conservar datos

Solo con aprobación explícita:

```bash
./scripts/teardown.sh --retain-data --confirm video-archive-pilot
```

Conserva bucket de videos, Catalog y Audit y genera un manifiesto local.

### 14.3 Purga completa

Solo con aprobación escrita del propietario de los datos:

```bash
./scripts/teardown.sh --purge-data --confirm video-archive-pilot
```

Es irreversible. Para procedimientos de recursos retenidos, revisar `docs/teardown.md`.

## 15. Estado de validación

Validado en la cuenta demo:

- deployment completo y redeployment;
- deployments desde cero en stacks descartables;
- frontend/API/seguridad básica;
- carga manual y sintética;
- IAM Roles Anywhere y carga E2E desde macOS como evidencia del roadmap;
- indexación, filenames inválidos, descarga y auditoría de emisión;
- borrado físico y estados lifecycle;
- teardown `plan`, `retain-data`, `purge-retained` y `purge-data` en stacks descartables.

Implementado localmente para la PoC y pendiente de validar en la cuenta/Windows del cliente:

- usuario IAM técnico → role uploader acotado;
- configuración de perfiles source/assume-role con PowerShell;
- safe sync manual y dry-run;
- exclusión de lotes con AVI abiertos/recientes;
- lock contra ejecuciones paralelas;
- retries, backlog, logs y métricas locales;
- registro/remoción de Task Scheduler cada 15 minutos.

Pendiente o roadmap:

- WAF global/regional;
- validación de la automatización Windows contra la carpeta/VMS real y recuperación de backlog;
- migración del uploader a IAM Roles Anywhere;
- CloudTrail S3 Data Events y alarmas completas;
- endpoint de aplicación para iniciar restores Glacier Flexible.

## 16. Orden recomendado para la reunión

1. Confirmar alcance y limitaciones.
2. Configurar el perfil CLI humano de deployment y verificar identidad.
3. Crear el usuario IAM técnico sin consola/políticas y configurar su nombre en `.env`.
4. Completar `.env` con `keep`, Cognito-only aprobado y Roles Anywhere deshabilitado.
5. Ejecutar preflight.
6. Desplegar.
7. Crear operador Cognito.
8. Crear la access key del usuario técnico y configurar `cctv-uploader` en Windows.
9. Ejecutar dry-run y carga real de un AVI sanitizado.
10. Mostrar login, búsqueda, descarga y auditoría.
11. Registrar Task Scheduler solo después de validar el flujo manual; revisar log y `LastTaskResult`.
12. Ejecutar únicamente `teardown --plan` salvo decisión explícita del cliente.
13. Registrar métricas y acordar roadmap: WAF, Roles Anywhere y lifecycle.

## 17. Navegación operativa

Este manual explica el recorrido completo. Para ejecutar cada etapa use, en orden:

1. [`prerequisites.md`](prerequisites.md)
2. [`deployment.md`](deployment.md)
3. [`../uploader/iam-user/README.md`](../uploader/iam-user/README.md)
4. [`demo-runbook.md`](demo-runbook.md)
5. [`cost-model.md`](cost-model.md) y [`lifecycle-states.md`](lifecycle-states.md)
6. [`teardown.md`](teardown.md), comenzando siempre por `--plan`

Los documentos de WAF y IAM Roles Anywhere son roadmap y no interrumpen el camino PoC aprobado.
