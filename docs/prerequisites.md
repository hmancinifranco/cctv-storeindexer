# Prerrequisitos para desplegar la PoC

**Última revisión:** 2026-10-22

Esta guía prepara una cuenta AWS y una estación de trabajo antes de ejecutar el deployment. No crea ni modifica recursos.

## 1. Información a confirmar

- Cuenta AWS donde se instalará la PoC.
- Región AWS. La referencia probada es `us-east-1`.
- Nombre del stack, por ejemplo `video-archive-pilot`.
- Email del primer usuario.
- 3–5 cámaras elegidas y carpeta Windows de grabaciones finalizadas.
- Retención del piloto. El valor seguro inicial es `keep` (sin borrado automático).
- CIDRs públicos de la oficina si se exige restricción por IP.
- Nombre de un usuario IAM técnico existente para el uploader PoC, sin acceso a consola ni políticas amplias.
- Responsable y canal seguro para crear/entregar su access key después del deployment.
- Zona horaria y 10–20 nombres AVI reales sanitizados.

## 2. Autenticación AWS y perfil de AWS CLI v2

El comando `sts get-caller-identity` **no crea ni autentica un perfil**: asume que el perfil nombrado ya existe y tiene credenciales válidas. Configure primero uno de los siguientes caminos. Use el mismo nombre de perfil posteriormente en `.env` como `AWS_PROFILE`.

### 2.1 Camino recomendado para usuario IAM o federación IAM — `aws login`

`aws login` reutiliza el inicio de sesión de AWS Management Console en el navegador y entrega credenciales temporales; evita crear y copiar access keys permanentes. No corresponde a usuarios de IAM Identity Center, que deben usar la sección 2.2.

Requisitos:

- AWS CLI **2.32.0 o posterior**.
- El usuario debe poder iniciar sesión en AWS Management Console.
- Un administrador debe adjuntar la política administrada `SignInLocalDevelopmentAccess` al usuario, rol o grupo.
- La identidad también debe tener por separado los permisos de deployment de la sección 2.5.
- No usar el usuario root aunque técnicamente esté soportado.

Ejecute:

```bash
aws login --profile video-archive-deployer
```

AWS CLI solicita la región si falta y abre el navegador. Seleccione la sesión o inicie sesión como el usuario IAM del cliente, incluyendo MFA si está configurado. Luego verifique:

```bash
aws sts get-caller-identity --profile video-archive-deployer --region us-east-1
```

Las credenciales se renuevan automáticamente y la sesión puede durar hasta 12 horas según la identidad. Para cerrar y retirar la caché local:

```bash
aws logout --profile video-archive-deployer
```

Fuente oficial: [AWS CLI login con credenciales de consola](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html).

### 2.2 Camino para IAM Identity Center (SSO)

Un administrador del cliente debe asignar al responsable del deployment a la cuenta AWS y al permission set autorizado. Luego, en la estación de deployment:

```bash
aws configure sso --profile video-archive-deployer
aws sso login --profile video-archive-deployer
```

El asistente solicita la URL de inicio o issuer URL, región de IAM Identity Center, cuenta, permission set/rol, región por defecto del workload y formato de salida. IAM Identity Center entrega credenciales temporales y AWS CLI las renueva durante la sesión.

Instrucciones detalladas: [`implementation-manual.md`](implementation-manual.md#4-configurar-autenticación-y-el-perfil-de-aws-cli-v2) y [documentación oficial de AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html).

### 2.3 Último recurso — usuario IAM con access key permanente

Use este camino solo si `aws login` no está habilitado y el cliente no dispone de IAM Identity Center. El cliente debe aceptar explícitamente la custodia, rotación y revocación de credenciales de larga duración.

El administrador debe generar una access key para un usuario IAM de deployment. La secret access key se muestra una sola vez. No debe enviarse por email/chat ni guardarse en este proyecto.

```bash
aws configure --profile video-archive-deployer
```

Ingrese cuando AWS CLI lo solicite:

```text
AWS Access Key ID: <entregada por el cliente>
AWS Secret Access Key: <entregada por el cliente>
Default region name: us-east-1
Default output format: json
```

AWS CLI guarda las claves en `~/.aws/credentials` en macOS/Linux o `%UserProfile%\.aws\credentials` en Windows. No copie esos archivos al repositorio. Rote o desactive la access key después del piloto.

Referencia oficial: [configurar AWS CLI con credenciales de usuario IAM](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-quickstart.html).

### 2.4 Verificar el perfil antes de desplegar

En todos los caminos:

```bash
aws configure list --profile video-archive-deployer
aws sts get-caller-identity --profile video-archive-deployer --region us-east-1
```

Confirme verbalmente el número de cuenta y el ARN. Con `aws login` usando un usuario IAM puede observarse una identidad STS asociada al usuario; con SSO normalmente se observa `assumed-role`. Valide el valor real con el administrador en lugar de inferirlo por el formato.

Si la cuenta o identidad no son las acordadas, deténgase. Nunca use el perfil `default` implícitamente para este deployment.

### 2.5 Permisos de deployment

La identidad debe poder crear mediante CloudFormation/SAM recursos de IAM, S3, CloudFront, Cognito, DynamoDB, Lambda, API Gateway, EventBridge y SQS. También debe poder adjuntar una política inline al usuario técnico existente indicado en `UPLOADER_IAM_USER_NAME`. IAM Roles Anywhere solo es necesario cuando se habilita ese camino de roadmap.

Para la reunión puede utilizarse temporalmente un rol o usuario de administración aprobado por el cliente. Para operación regular debe crearse un rol de deployment con permisos limitados al proyecto.

### 2.6 Crear el usuario técnico del uploader PoC

Un administrador del cliente crea un usuario IAM preexistente, por ejemplo `cctv-pilot-uploader`, con estas condiciones:

- Sin acceso a AWS Management Console.
- Sin access key inicialmente.
- Sin políticas S3 ni políticas administradas amplias.
- Único para este workload; no compartirlo entre aplicaciones o servidores no relacionados.

Configure el nombre en `.env`. El stack creará el role acotado y adjuntará al usuario únicamente `sts:AssumeRole` sobre ese role. La access key se crea **después** del deployment y se retira al cierre de la PoC. Tanto `preflight.sh` como CloudFormation bloquean el deployment si no se configura este usuario y Roles Anywhere permanece deshabilitado.

## 3. Herramientas locales

- AWS CLI v2.
- AWS SAM CLI.
- Node.js 20 LTS o posterior y npm.
- Python 3.12 o posterior.
- Git.
- OpenSSL y `aws_signing_helper` únicamente para el roadmap IAM Roles Anywhere.

Verifique las instalaciones antes de continuar:

```bash
aws --version
sam --version
node --version
npm --version
python3 --version  # debe ser 3.12 o posterior
git --version
# Solo si se habilitará IAM Roles Anywhere:
openssl version
```

No ejecute todavía `preflight.sh`: ese script también autentica el perfil y lee `.env`, por lo que debe correrse después de completar la sección 4 y elegir el modo de perímetro de la sección 5.

## 4. Configuración

```bash
[ -e .env ] || cp .env.example .env
```

Complete como mínimo:

```dotenv
AWS_PROFILE=<perfil-de-la-cuenta-cliente>
AWS_REGION=us-east-1
PROJECT_NAME=cctv-storeindexer
STACK_NAME=video-archive-pilot
ENVIRONMENT=pilot

RETENTION_MODE=keep
RETENTION_DAYS=90
CATALOG_TOMBSTONE_RETENTION_DAYS=365

# Excepción temporal del piloto; requiere aprobación y --allow-cognito-only.
IP_ALLOWLIST_MODE=disabled
OFFICE_ALLOWED_CIDRS=

# Usuario IAM técnico preexistente; el stack no crea su access key.
UPLOADER_IAM_USER_NAME=cctv-pilot-uploader
ROLES_ANYWHERE_ENABLED=false
INGEST_PREFIX=videos
```

`RETENTION_DAYS` no elimina objetos mientras `RETENTION_MODE=keep`.

## 5. Limitación actual del perímetro

El template actual todavía no crea WAF para CloudFront y API Gateway. Por seguridad, el preflight rechaza `IP_ALLOWLIST_MODE=enforce` hasta implementar y validar ambos WebACLs.

Para una PoC explícitamente aceptada con Cognito pero sin restricción por IP, use:

```dotenv
IP_ALLOWLIST_MODE=disabled
```

Y ejecute el preflight con la excepción aprobada:

```bash
./scripts/preflight.sh --allow-cognito-only
```

No describa ese despliegue como restringido a la oficina. Si `RETENTION_MODE=expire`, el preflight también exige `--allow-expiration`; para el cliente use `keep` y no agregue ese flag.

## 6. Preparación de Windows

Confirme:

- Windows Server y arquitectura x86-64.
- Salida HTTPS 443 hacia AWS.
- Carpeta que contenga únicamente archivos finalizados, idealmente `ReadyToUpload`.
- AWS CLI v2 instalado. Desde PowerShell elevado:

  ```powershell
  msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
  aws --version
  ```

  Si `aws` no aparece inmediatamente, cierre y vuelva a abrir PowerShell. Fuente: [instalación oficial de AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).
- Usuario IAM técnico único, sin consola ni políticas S3 directas.
- Canal seguro para entregar una access key temporal de PoC después del deployment.
- Cuenta Windows dedicada que configurará los perfiles y ejecutará Task Scheduler.
- Permisos de lectura sobre `ReadyToUpload` y escritura en `C:\ProgramData\CctvUploader\logs`.

La configuración de identidad para la PoC está en [`../uploader/iam-user/README.md`](../uploader/iam-user/README.md). IAM Roles Anywhere se conserva como roadmap en [`../uploader/roles-anywhere/README.md`](../uploader/roles-anywhere/README.md).

## Siguiente paso

Cuando todos los prerrequisitos estén completos, continúe con [`deployment.md`](deployment.md). No ejecute comandos de deployment desde este documento antes de completar la autenticación, `.env`, usuario IAM técnico y aprobación Cognito-only.
