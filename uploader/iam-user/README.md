# Uploader PoC — usuario IAM que asume un role acotado

**Última revisión:** 2026-10-22

Este es el mecanismo simplificado para la PoC. El Windows Server guarda una access key de un **usuario IAM técnico único**, pero ese usuario no tiene permisos directos sobre S3: únicamente puede ejecutar `sts:AssumeRole` sobre el uploader role creado por el stack.

El perfil `cctv-uploader` obtiene credenciales STS temporales de una hora. El role permite listar `videos/` y ejecutar PUT/multipart únicamente dentro de ese prefijo. No permite `GetObject`, `DeleteObject` ni acceso a otros buckets.

> Este mecanismo acepta temporalmente una key de larga duración para reducir complejidad en la PoC. IAM Roles Anywhere es el roadmap documentado en [`../roles-anywhere/README.md`](../roles-anywhere/README.md).

## 1. Crear el usuario técnico

Un administrador del cliente crea un usuario IAM sin acceso a consola, por ejemplo:

```text
cctv-pilot-uploader
```

No adjunte políticas S3, permisos administrativos ni políticas administradas amplias. Configure ese nombre en `.env` antes del deployment:

```dotenv
UPLOADER_IAM_USER_NAME=cctv-pilot-uploader
ROLES_ANYWHERE_ENABLED=false
```

El deployment crea el uploader role y adjunta al usuario una política inline que permite únicamente asumir ese role. CloudFormation no crea ni devuelve access keys.

## 2. Crear la access key

Después de un deployment exitoso, el administrador crea una access key para el usuario técnico:

1. Abra IAM → **Users** → `cctv-pilot-uploader`.
2. Abra **Security credentials** → **Access keys** → **Create access key**.
3. Seleccione el caso de uso **Command Line Interface (CLI)** y reconozca la recomendación de credenciales temporales.
4. Agregue una descripción con servidor, propietario y fecha de retiro.
5. Cree la key y transfiera Access Key ID/Secret Access Key al administrador Windows por un canal seguro. La secret se muestra una sola vez.

Controles:
- No la envíe por email/chat.
- No la coloque en `.env`, scripts, documentación o Git.
- Registre propietario, servidor, fecha de creación y fecha de retiro.

## 3. Obtener el role ARN

Use el output `UploaderRoleArn` de CloudFormation. No copie un ARN de otra cuenta o ambiente.

## 4. Configurar Windows

En PowerShell, desde la raíz del proyecto:

```powershell
.\uploader\iam-user\configure-profile.ps1 -RoleArn '<UploaderRoleArn>' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1'
```

El script solicita la access key interactivamente, crea:

- `cctv-uploader-source`: credencial base del usuario IAM.
- `cctv-uploader`: role temporal usado por las cargas.

También restringe la ACL del archivo local de credenciales al usuario Windows actual y valida `sts get-caller-identity`.

## 5. Probar identidad y mínimo privilegio

La identidad final debe ser un assumed-role:

```powershell
aws sts get-caller-identity --profile cctv-uploader --region us-east-1
```

`configure-profile.ps1` también comprueba que el perfil source sea rechazado por S3 y que el perfil role pueda listar el prefijo aprobado.

## 6. Preparar la carpeta de archivos finalizados

Use una carpeta que contenga únicamente grabaciones cerradas, por ejemplo:

```text
D:\ReadyToUpload
```

El VMS debe mover o exportar allí cada AVI solo después de finalizarlo. Como defensa adicional, `upload-videos.ps1` exige que todos los AVI estén cerrados y no hayan cambiado durante `MinimumFileAgeMinutes` (5 minutos por defecto). Si detecta uno abierto o reciente, no sube ninguno y espera la próxima corrida. Esto evita publicar archivos parciales, aunque un archivo atascado puede posponer el lote completo.

El script:

- sincroniza solamente `*.avi`;
- usa `cctv-uploader`, nunca el perfil source;
- no usa `--delete` y no elimina archivos locales;
- no sigue enlaces simbólicos;
- usa un lock exclusivo para evitar solapamientos;
- configura retry estándar de AWS CLI con 5 intentos;
- conserva backlog para la siguiente corrida si AWS CLI falla;
- escribe logs JSON Lines en `C:\ProgramData\CctvUploader\logs`;
- rota logs locales después de 30 días;
- registra archivos/bytes elegibles, operaciones upload, duración y código de salida.

## 7. Probar manualmente

Primero ejecute un dry-run:

```powershell
.\uploader\iam-user\upload-videos.ps1 -SourceDirectory 'D:\ReadyToUpload' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1' -DryRun
```

Revise la salida. Después ejecute la carga real:

```powershell
.\uploader\iam-user\upload-videos.ps1 -SourceDirectory 'D:\ReadyToUpload' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1'
```

Una segunda ejecución sin cambios debe reportar cero operaciones de upload. Busque el archivo en la aplicación para comprobar S3 → EventBridge → SQS → Lambda → DynamoDB.

## 8. Programar con Task Scheduler

Ejecute `configure-profile.ps1` con la cuenta Windows que ejecutará la tarea. Luego abra **PowerShell como administrador con esa misma cuenta** para ejecutar `register-task.ps1`. El script falla si la identidad actual no coincide con `RunAsUser`. Esa cuenta debe tener lectura sobre `ReadyToUpload`.

`register-task.ps1` copia `upload-videos.ps1` a `C:\ProgramData\CctvUploader\bin`, crea `C:\ProgramData\CctvUploader\logs` y restringe las ACL de ambas rutas a la cuenta de la tarea, SYSTEM y Administrators. La tarea no depende de que el checkout Git permanezca en el mismo lugar.

Desde PowerShell:

```powershell
.\uploader\iam-user\register-task.ps1 -SourceDirectory 'D:\ReadyToUpload' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1' -EveryMinutes 15 -MinimumFileAgeMinutes 5
```

El script solicita la contraseña de la cuenta Windows mediante `Get-Credential`; no se incluye en el comando ni en archivos del proyecto. Registra una tarea que:

- comienza aproximadamente un minuto después;
- se repite cada 15 minutos;
- ejecuta `powershell.exe -NoProfile -NonInteractive`;
- inicia cuando vuelve el servidor si perdió una ejecución;
- evita instancias paralelas con `MultipleInstances=IgnoreNew`;
- limita una corrida a seis horas.

Compruebe:

```powershell
Get-ScheduledTask -TaskName 'CctvVideoUploader'
Start-ScheduledTask -TaskName 'CctvVideoUploader'
Get-ScheduledTaskInfo -TaskName 'CctvVideoUploader'
Get-Content 'C:\ProgramData\CctvUploader\logs\upload-*.jsonl' -Tail 20
```

Valores esperados: tarea `Ready`, `LastTaskResult=0`, eventos `SYNC_COMPLETED` o `NO_FILES`, y archivos visibles en la aplicación.

## 9. Fallos y recuperación

| Situación | Comportamiento |
|---|---|
| Otro sync está ejecutándose | La segunda corrida se omite por lock; Task Scheduler además usa `IgnoreNew` |
| AVI abierto o reciente | Lote pospuesto, evento `DEFERRED_INCOMPLETE_FILES`; reintenta en la próxima corrida |
| Corte de internet/AWS | AWS CLI reintenta; si falla, retorna error y el próximo intervalo recupera el backlog |
| Credencial source comprometida | Deshabilitar inmediatamente la access key y usar **Revoke active sessions** en el uploader role; la key no accede a S3 directamente, pero una sesión STS existente puede durar hasta una hora |
| `AccessDenied` al asumir | Verificar que el usuario configurado sea el correcto y que el stack esté desplegado |
| `AccessDenied` durante sync | Usar `cctv-uploader`, confirmar bucket/prefijo y no usar el perfil source |

El script no elimina archivos de origen después de subirlos. La política de limpieza local debe definirse separadamente y solo después de una verificación end-to-end aprobada.

## 10. Cierre del piloto

1. Deshabilite la tarea y espere que no exista un sync activo.
2. Deshabilite inmediatamente la access key en IAM.
3. Elimine la tarea local con confirmación:

   ```powershell
   .\uploader\iam-user\remove-task.ps1
   ```

4. Ejecute el teardown AWS en modo plan y luego el modo aprobado.
5. El stack elimina la política de assume-role y el role.
6. El usuario IAM preexistente no es eliminado por el stack; elimínelo si era exclusivo y ya no tiene keys/políticas.
7. Para continuidad, migre a IAM Roles Anywhere antes de operación extendida.

## Limitaciones del piloto

- La carpeta debe obedecer el contrato de archivos finalizados; la estabilidad por edad/lock es defensa adicional, no una integración específica con el VMS.
- Si cualquier AVI no está listo, se pospone el lote completo para conservar el uso de `aws s3 sync` sin construir listas enormes de includes.
- Las métricas locales reportan bytes elegibles y cantidad de operaciones observadas; el dimensionamiento final debe contrastarse con métricas S3/CloudWatch.
- La access key sigue siendo de larga duración hasta que se retire o se migre a IAM Roles Anywhere.

Fuentes: [AWS CLI `s3 sync`](https://docs.aws.amazon.com/cli/latest/reference/s3/sync.html), [revocar sesiones temporales de un role](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_revoke-sessions.html), [Register-ScheduledTask](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/register-scheduledtask) y [New-ScheduledTaskTrigger](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtasktrigger).

## Validación sintáctica fuera de Windows

En macOS se puede validar la sintaxis con PowerShell LTS portable:

```bash
./scripts/install-powershell-macos.sh
make powershell-validate
```

Esto usa el parser oficial sobre los cuatro scripts. No valida los cmdlets exclusivos de Windows (`ScheduledTasks`), `icacls.exe`, la cuenta de servicio ni una ejecución real de `aws s3 sync`; esos controles se realizan en el Windows Server.

## Siguiente paso

Cuando el perfil role, dry-run, carga real, segunda sincronización y tarea programada hayan sido validados, continúe con [`../../docs/demo-runbook.md`](../../docs/demo-runbook.md). Si cualquier control falla, no continúe con la demostración como si el uploader estuviera completo; use carga manual administrada y registre el pendiente.
