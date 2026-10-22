# Roadmap — IAM Roles Anywhere para el uploader

**Última revisión:** 2026-10-22

Este es el camino recomendado para reemplazar la access key usada temporalmente por la PoC. No es requisito para el deployment inicial. El servidor Windows obtiene credenciales temporales a partir de un certificado X.509, sin llaves AWS de larga duración.

Este runbook cubre la demo (cuenta de prototipo) y cómo el cliente lo replica en
**su propia cuenta**.

## Piezas

| Pieza | Qué es | Dónde vive |
|-------|--------|-----------|
| CA (autoridad certificadora) | Firma los certificados de cliente | Offline / AWS Private CA |
| Trust anchor | Registra la CA en IAM Roles Anywhere | Cuenta AWS (creado/reutilizado por `setup_roles_anywhere.sh` mediante AWS CLI) |
| Profile + Role | Rol write-only al prefijo de ingesta | Cuenta AWS (stack SAM) |
| Certificado de cliente | Identidad del servidor | Servidor Windows |
| `aws_signing_helper` | Intercambia el cert por credenciales temporales | Servidor Windows |

El rol es **write-only al prefijo `videos/`** (mínimo privilegio): puede subir
(incluido multipart) pero no leer, borrar ni listar fuera de ese prefijo.

## Requisitos del certificado y del helper (aprendidos en pruebas)

Dos cosas que Roles Anywhere exige y que rompen la sesión si faltan:

1. **CA:** el certificado de la CA necesita `basicConstraints=critical,CA:TRUE`
   (ya incluido en `setup_ca.sh`). Sin esto: *"Incorrect basic constraints"*.
2. **Certificado de cliente (end-entity):** necesita
   `keyUsage=digitalSignature` + `extendedKeyUsage=clientAuth`
   (ya incluido en `setup_ca.sh`). Sin esto la sesión falla con
   *"Untrusted certificate. Insufficient certificate"*.
3. **Helper:** descargá el `aws_signing_helper` de la URL vigente (el formato
   cambió; las URLs `1.1.1/X86_64/Linux/...` dan 403). Formato actual:
   `https://rolesanywhere.amazonaws.com/releases/1.8.5/<Arch>/<OS>/<Distro>/aws_signing_helper`
   — ej. Linux AL2023 x86-64: `.../1.8.5/X86_64/Linux/Amzn2023/aws_signing_helper`;
   macOS Apple Silicon: `.../1.8.5/Aarch64/MacOS/Sonoma/aws_signing_helper`.
   Fuente: https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html

> **Antes de una demo en vivo del path Roles Anywhere:** re-emitir el cert con
> `setup_ca.sh` (ya trae ambas extensiones), volver a subir cert+key a SSM
> (`infra/deploy-demo-ec2.sh` lo hace), y recrear la EC2 para que su UserData
> tome el helper correcto (`aws cloudformation deploy` del stack onprem). El path
> **instance profile** no depende de nada de esto y funciona tal cual.

## A) Demo (nuestra cuenta) — pasos

```bash
cd /ruta/cctv-storeindexer

# 1. Generar CA + certificado de cliente demo (openssl)
./uploader/roles-anywhere/setup_ca.sh
#    -> uploader/roles-anywhere/certs/{ca.crt,ca.key,client.crt,client.key}

# 2. Provisionar Roles Anywhere de punta a punta:
#    - crea el TRUST ANCHOR por CLI (lee ca.crt directo; evita el problema del
#      PEM multilínea en parámetros SAM),
#    - despliega el ROLE + PROFILE por SAM (RolesAnywhereEnabled=true),
#    - escribe RA_TRUST_ANCHOR_ARN / RA_PROFILE_ARN / RA_ROLE_ARN en .env.
./uploader/roles-anywhere/setup_roles_anywhere.sh
```

> Por qué el trust anchor va por CLI y el role/profile por SAM: pasar un
> certificado PEM (multilínea) a través de `sam deploy --parameter-overrides`
> corrompe los saltos de línea y Roles Anywhere lo rechaza ("Bad certificate
> data"). El CLI lee el archivo directamente. El role y el profile no necesitan
> el PEM, así que quedan en IaC (SAM) con teardown gestionado.

## B) Servidor Windows — configuración

1. Instalar el **AWS IAM Roles Anywhere Credential Helper**
   (`aws_signing_helper.exe`) desde la documentación oficial de AWS.
2. Copiar `client.crt` y `client.key` a una ruta protegida del servidor
   (por ejemplo `C:\ProgramData\cctv\`), con permisos restringidos.
3. Configurar el perfil en `%USERPROFILE%\.aws\config`:

   ```ini
   [profile cctv-uploader]
   credential_process = C:\ruta\aws_signing_helper.exe credential-process --certificate C:\ProgramData\cctv\client.crt --private-key C:\ProgramData\cctv\client.key --trust-anchor-arn <RA_TRUST_ANCHOR_ARN> --profile-arn <RA_PROFILE_ARN> --role-arn <RA_ROLE_ARN>
   ```

   `credential_process` debe estar completo en una sola línea dentro del archivo
   de configuración; `^` sirve para continuar comandos en `cmd.exe`, no entradas
   de `%USERPROFILE%\.aws\config`.

4. Programar la subida con **Task Scheduler** (baseline `aws s3 sync`):

   ```bat
   aws s3 sync "D:\Grabaciones" s3://<VIDEO_BUCKET>/videos/ ^
     --profile cctv-uploader --region us-east-1
   ```

   El `credential_process` obtiene credenciales temporales automáticamente en
   cada corrida; no hay llaves guardadas.

## C) Réplica en la cuenta del cliente

Mismos pasos, en su cuenta:

1. Usar **su** CA — idealmente **AWS Private CA** en vez de la CA openssl de
   demo. Registrar el trust anchor por CLI (o consola):
   `aws rolesanywhere create-trust-anchor --name <nombre> --enabled --source sourceType=CERTIFICATE_BUNDLE,sourceData={x509CertificateData=$(cat su-ca.crt)}`.
2. Desplegar el role + profile con `ROLES_ANYWHERE_ENABLED=true ./infra/deploy.sh`
   (o correr `setup_roles_anywhere.sh` adaptado a su CA).
3. Emitir un certificado de cliente por servidor de grabación.
4. Configurar el `credential_process` y la tarea programada como en (B).

## Rotación de certificados

- El certificado de cliente demo dura **90 días** (`DAYS_CLIENT`). Volvé a correr
  `setup_ca.sh` para emitir uno nuevo con la misma CA (no hace falta redeploy: la
  CA/trust anchor no cambia) y reemplazá `client.crt`/`client.key` en el servidor.
- La CA dura 5 años. Si rota la CA, hay que actualizar el trust anchor (redeploy
  con la nueva `ca.crt`).
- Producción: preferir **AWS Private CA** con rotación gestionada.

## Seguridad

- `ca.key` y `client.key` **nunca** se suben al repositorio (`.gitignore` cubre
  `certs/` y `*.key`/`*.crt`).
- El rol es write-only al prefijo de ingesta: un servidor comprometido no puede
  leer ni borrar grabaciones existentes.
- Credenciales temporales (1 h) en lugar de llaves permanentes.

## D) Validación desde macOS

Roles Anywhere no depende de Windows. Puede validarse desde una Mac con el mismo certificado antes de configurar el servidor del cliente:

```bash
./scripts/install-roles-anywhere-helper-macos.sh
./scripts/test-roles-anywhere-local.sh
./scripts/test-roles-anywhere-local.sh --upload-fixture
```

El primer comando instala el helper oficial validado para el usuario actual. El segundo valida credenciales/identidad sin escribir; el tercero sube un fixture sintético único y comprueba su indexación.

**Evidencia 2026-10-22:** prueba exitosa desde macOS Apple Silicon con `aws_signing_helper` 1.8.5 y sesión de una hora sobre el rol uploader. Esto valida trust anchor, profile, role, certificado y renovación mediante `credential_process`; no reemplaza la validación posterior del uploader PowerShell/Task Scheduler en Windows.
