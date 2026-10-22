# Deployment de la PoC en una cuenta AWS

**Última revisión:** 2026-10-22

Este procedimiento despliega infraestructura, genera la configuración del frontend, ejecuta pruebas, publica la SPA y verifica controles básicos.

## 1. Preparar

Complete [`prerequisites.md`](prerequisites.md). Un administrador del cliente debe crear previamente un usuario IAM técnico único sin acceso a consola y sin políticas, por ejemplo `cctv-pilot-uploader`. No cree todavía su access key.

Cree la configuración local sin sobrescribir una existente:

```bash
[ -e .env ] || cp .env.example .env
```

Configure como mínimo:

```dotenv
AWS_PROFILE=video-archive-deployer
AWS_REGION=us-east-1
STACK_NAME=video-archive-pilot
ENVIRONMENT=pilot
RETENTION_MODE=keep
RETENTION_DAYS=90
IP_ALLOWLIST_MODE=disabled
UPLOADER_IAM_USER_NAME=cctv-pilot-uploader
ROLES_ANYWHERE_ENABLED=false
```

Revise especialmente cuenta, región, stack, retención, usuario uploader y la excepción temporal de IP allowlist.

## 2. Preflight

```bash
./scripts/preflight.sh --allow-cognito-only
```

Resultado esperado:

```text
Preflight OK. Revise cuenta, región y advertencias antes de continuar.
```

El preflight muestra cuenta y ARN del rol. Confírmelos antes de crear recursos.

### Excepción temporal del piloto

Mientras WAF está pendiente, el deployment de cliente requiere aprobación explícita para operar con Cognito sin restricción IP y usar `--allow-cognito-only`. Con `RETENTION_MODE=keep` no use `--allow-expiration`.

La demo histórica además usa expiración a 60 días; solo para reproducirla se añade:

```bash
./scripts/preflight.sh --allow-cognito-only --allow-expiration
```

No utilice esos flags en la cuenta del cliente sin aprobación explícita.

## 3. Deployment completo de la PoC

```bash
./scripts/deploy-customer.sh --allow-cognito-only
```

El flag confirma la excepción temporal sin WAF. No deshabilita Cognito. El script ejecuta:

1. Preflight y validación del usuario IAM técnico.
2. `sam build` y `sam deploy`.
3. Creación del uploader role write-only y política exacta `sts:AssumeRole` para el usuario.
4. Lectura de outputs del stack.
5. Actualización de outputs resueltos en `.env`.
6. Generación de `frontend/.env.production`.
7. `npm ci`, typecheck, tests y build.
8. Publicación en el bucket privado de la SPA.
9. Invalidación de CloudFront.
10. `scripts/verify-deployment.sh`.

Resultado esperado:

```text
Deployment completo: https://<distribution>.cloudfront.net/
```

Cuando WAF global/regional esté implementado, `IP_ALLOWLIST_MODE=enforce` permitirá desplegar sin `--allow-cognito-only`.

## 4. Crear el primer usuario

```bash
./scripts/create-user.sh usuario@cliente.com
```

Cognito envía una contraseña temporal por email. En el primer login, el usuario define una contraseña permanente.

El script es idempotente: si el usuario ya existe, solo asegura que pertenezca al grupo `Operators`.

## 5. Configurar el uploader PoC en Windows

Después del deployment:

1. Obtenga `UploaderRoleArn` y `VideoBucketName` de los outputs del stack.
2. El administrador crea una access key para el usuario técnico configurado. CloudFormation nunca crea ni muestra esa key.
3. En el Windows Server, ejecute:

   ```powershell
   .\uploader\iam-user\configure-profile.ps1 -RoleArn '<UploaderRoleArn>' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1'
   ```

4. Use exclusivamente `--profile cctv-uploader` para las transferencias. Ese perfil obtiene credenciales STS temporales del role; `cctv-uploader-source` no debe usarse para S3.
5. Pruebe primero el uploader seguro en modo dry-run:

   ```powershell
   .\uploader\iam-user\upload-videos.ps1 -SourceDirectory 'D:\ReadyToUpload' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1' -DryRun
   ```

6. Ejecute una carga real y compruebe que el archivo aparece en la aplicación:

   ```powershell
   .\uploader\iam-user\upload-videos.ps1 -SourceDirectory 'D:\ReadyToUpload' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1'
   ```

7. Cuando el flujo manual esté validado, abra PowerShell **como administrador con la misma cuenta Windows que configuró los perfiles** y registre la tarea cada 15 minutos:

   ```powershell
   .\uploader\iam-user\register-task.ps1 -SourceDirectory 'D:\ReadyToUpload' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1' -EveryMinutes 15 -MinimumFileAgeMinutes 5
   ```

El registrador copia el uploader a `C:\ProgramData\CctvUploader\bin`, prepara `C:\ProgramData\CctvUploader\logs` y restringe sus ACLs; la tarea no depende de la ubicación futura del checkout.

El uploader solo procesa `.avi`, nunca usa `--delete`, no elimina el origen, evita ejecuciones paralelas y pospone el lote completo si algún AVI está abierto o fue modificado dentro de los últimos cinco minutos. Los errores de red quedan como backlog para el siguiente intervalo. Logs y métricas locales se escriben en `C:\ProgramData\CctvUploader\logs`.

El role permite upload/multipart y listado del prefijo, pero no lectura ni borrado. Consulte [`../uploader/iam-user/README.md`](../uploader/iam-user/README.md).

IAM Roles Anywhere queda como camino de mejora para eliminar la key de larga duración. Su procedimiento completo permanece en [`../uploader/roles-anywhere/README.md`](../uploader/roles-anywhere/README.md).

## 6. Verificación básica

Puede repetirse sin modificar recursos:

```bash
./scripts/verify-deployment.sh
```

Comprueba:

- Stack en estado completo.
- S3 Block Public Access y cifrado.
- Tablas DynamoDB activas.
- SPA HTTP 200.
- Health API HTTP 200.
- API de videos rechaza requests sin sesión.
- Retención y estado del allowlist.

## 7. Verificación funcional

1. Copiar un AVI terminado a `D:\ReadyToUpload`.
2. Ejecutar `upload-videos.ps1` manualmente y confirmar que aparece en S3/catálogo.
3. Ejecutarlo nuevamente y confirmar cero operaciones de upload.
4. Registrar/iniciar la tarea programada y revisar `LastTaskResult=0` y el log JSONL.
5. Iniciar sesión en la URL CloudFront.
6. Buscar por fecha/cámara.
7. Descargar el video.
8. Confirmar el registro de solicitud de descarga.

También pruebe:

- AVI abierto o modificado recientemente → se pospone todo el lote.
- Corte de conectividad → la corrida falla y el intervalo siguiente recupera el backlog.
- Perfil source → acceso S3 denegado.
- Perfil `cctv-uploader` → upload permitido, lectura/borrado denegados.
- Archivo con nombre inválido → visible para revisión.

## 8. Próximo paso

Antes de escalar, registrar las métricas indicadas en `docs/cost-model.md`: GB/día por cámara, archivos/día, tamaños AVI, throughput, backlog, latencias y descargas.

Para retirar la PoC, seguir `docs/teardown.md`. No ejecutar comandos de borrado manuales fuera de ese procedimiento.

## 9. Checklist go/no-go para la reunión

Antes de ejecutar `deploy-customer.sh`, todos estos puntos deben estar en **GO**:

- [ ] Cuenta y región confirmadas verbalmente con el cliente.
- [ ] `aws sts get-caller-identity` devuelve la cuenta/identidad esperadas.
- [ ] El cliente aprobó explícitamente el piloto Cognito-only sin WAF/IP allowlist.
- [ ] `.env` usa `RETENTION_MODE=keep`; no se habilita expiración automática.
- [ ] Existe el usuario IAM técnico sin consola, access key ni políticas amplias.
- [ ] `UPLOADER_IAM_USER_NAME` coincide exactamente con ese usuario.
- [ ] `ROLES_ANYWHERE_ENABLED=false` para la PoC simplificada.
- [ ] `preflight.sh --allow-cognito-only` finaliza OK.
- [ ] Se acordó quién recibirá la contraseña temporal de Cognito.
- [ ] Se acordó quién custodiará y retirará la access key del uploader.
- [ ] Hay un AVI sanitizado y una carpeta de archivos finalizados para la prueba.
- [ ] No se ejecutará teardown destructivo durante la reunión sin aprobación explícita.

Deténgase si falla identidad, usuario técnico, permisos IAM/CloudFormation, aprobación Cognito-only, región o custodia de la key. No improvise permisos amplios para destrabar el deployment: capture el error y corríjalo con el administrador del cliente.

### Evidencia mínima antes de cerrar la reunión

- [ ] Stack `CREATE_COMPLETE` o `UPDATE_COMPLETE`.
- [ ] Frontend y health responden HTTP 200; API anónima responde 401/403.
- [ ] Usuario Cognito completó primer login.
- [ ] Perfil source fue rechazado por S3.
- [ ] Perfil `cctv-uploader` devolvió el assumed-role correcto.
- [ ] Dry-run revisado y un AVI real/sanitizado indexado.
- [ ] Segunda ejecución no volvió a transferir el archivo.
- [ ] Descarga autorizada y registro `DOWNLOAD_URL_ISSUED` comprobados.
- [ ] Task Scheduler se registró solo si el flujo manual fue exitoso.
- [ ] `LastTaskResult=0`, logs JSONL presentes y DLQ vacía.
- [ ] `teardown.sh --plan` revisado; no se eliminó nada.

## Siguiente paso

Después de obtener un deployment saludable y crear el operador Cognito:

1. Configure y valide el servidor siguiendo [`../uploader/iam-user/README.md`](../uploader/iam-user/README.md).
2. Cuando la carga manual y Task Scheduler estén saludables, ejecute [`demo-runbook.md`](demo-runbook.md).
3. Durante la reunión use únicamente [`teardown.md`](teardown.md) en modo `--plan`, salvo aprobación destructiva explícita.
