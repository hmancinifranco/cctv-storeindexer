# Teardown seguro de la PoC

**Última revisión:** 2026-10-22

El teardown puede conservar o eliminar permanentemente los datos. Revise el plan antes de ejecutar cualquier modo destructivo.

## 1. Detener nuevas cargas y contener la credencial

En el Windows Server:

1. Deshabilite la tarea y confirme que no hay una corrida activa:

   ```powershell
   Disable-ScheduledTask -TaskName 'CctvVideoUploader'
   Get-ScheduledTaskInfo -TaskName 'CctvVideoUploader'
   Get-Process aws -ErrorAction SilentlyContinue
   ```

2. Registre la hora y resultado de la última sincronización.
3. Deshabilite la access key del usuario IAM técnico en la consola IAM. Hágalo antes del teardown para impedir nuevas sesiones del uploader.
4. Una sesión STS ya emitida puede continuar hasta una hora. Para una baja normal, confirme que no hay proceso activo. Ante sospecha de compromiso, use **Revoke active sessions** sobre `UploaderRoleArn`; esto invalida todas las sesiones anteriores y puede interrumpir trabajo.
5. Elimine la tarea local mediante el script con confirmación:

   ```powershell
   .\uploader\iam-user\remove-task.ps1
   ```

6. No borre todavía el usuario IAM: CloudFormation debe retirar primero la política inline asociada durante el teardown del stack.

Esto evita nuevos objetos durante el inventario y la eliminación de recursos. La desactivación de la key es reversible mientras no se elimine; la purga de datos S3 no lo es.

## 2. Ver el plan (solo lectura)

```bash
./scripts/teardown.sh --plan
```

El comando muestra:

- Cuenta, región y stack.
- Buckets y cantidad/tamaño aproximado de objetos.
- Tablas de catálogo y auditoría.
- Stacks auxiliares de simulación.
- Diferencia entre retener y purgar.

No modifica recursos.

## 3. Opción A — retirar la aplicación y conservar datos

Este modo elimina CloudFront, Cognito, API, Lambdas, colas y recursos auxiliares. Conserva:

- Bucket de videos.
- Tabla de catálogo.
- Tabla de auditoría.

```bash
./scripts/teardown.sh --retain-data --confirm <nombre-del-stack>
```

### Eliminar posteriormente los recursos retenidos

Después de validar `retain-data`, utilice el manifiesto generado:

```bash
./scripts/teardown.sh \
  --purge-retained teardown-output/<manifest.txt> \
  --confirm <nombre-del-stack-original>
```

Esto elimina únicamente el bucket de videos y las tablas Catalog/Audit registradas en ese manifiesto.

El script genera un manifiesto local en `teardown-output/` y vuelve a aplicar una política TLS-only al bucket de videos retenido.

Después del teardown, esos recursos siguen generando costo de almacenamiento. El manifiesto indica sus nombres.

## 4. Opción B — eliminar completamente la PoC

> Esta acción elimina permanentemente videos, catálogo y auditoría. No puede deshacerse.

Ejecute únicamente después de aprobación escrita del propietario de los datos:

```bash
./scripts/teardown.sh --purge-data --confirm <nombre-del-stack>
```

El script:

1. Elimina stacks auxiliares de simulación, si existen.
2. Vacía el bucket de la SPA.
3. Vacía el bucket de videos.
4. Elimina el stack principal, incluido el uploader role y la política `sts:AssumeRole` adjunta al usuario técnico.
5. Elimina bucket de videos y tablas retenidas.
6. Solo si se habilitó el roadmap Roles Anywhere, deshabilita/elimina su trust anchor y parámetros SSM de la simulación.

## 5. Controles de seguridad

- Sin `--confirm <stack>` no se ejecuta ningún modo destructivo.
- El valor de confirmación debe coincidir exactamente con `STACK_NAME` de `.env`.
- `--retain-data` es la opción segura si existe duda.
- El script no elimina el bucket administrado por SAM CLI (`aws-sam-cli-managed-*`) porque puede ser compartido por otros proyectos.

## 6. Verificación posterior

Después de `retain-data`:

- La URL CloudFront deja de estar disponible.
- El bucket de videos continúa existiendo y bloqueando acceso público.
- Catálogo y auditoría continúan existiendo.
- El manifiesto local registra los nombres retenidos.

Después de `purge-data`:

```bash
aws cloudformation describe-stacks --stack-name <stack> --profile <perfil> --region <region>
aws s3api head-bucket --bucket <video-bucket> --profile <perfil> --region <region>
aws dynamodb describe-table --table-name <catalog-table> --profile <perfil> --region <region>
```

Los comandos deben devolver `not found` para los recursos eliminados.

Después de que el stack se elimine correctamente:

1. Verifique que el usuario IAM técnico ya no tenga la política inline del stack.
2. Elimine definitivamente su access key si solo fue creada para la PoC.
3. Elimine el usuario IAM si era exclusivo, no tiene otras políticas/keys y el cliente aprobó su retiro.
4. Retire de forma segura las secciones locales `cctv-uploader-source` y `cctv-uploader`; no elimine todo el archivo AWS credentials si contiene otros perfiles.

## 7. Limitaciones

- Los datos retenidos quedan fuera de CloudFormation después de `retain-data`; adminístrelos con sus nombres del manifiesto.
- El usuario IAM técnico y su access key son preexistentes/customer-owned: el stack solo elimina su política inline y el role.
- Si Roles Anywhere fue habilitado, su trust anchor se creó por CLI y se elimina por CLI.
- CloudTrail o buckets de logs futuros deberán agregarse al plan cuando se implementen.
- Antes de usar este script en la cuenta del cliente, ensayar ambos modos con datos descartables en una cuenta de prueba.

## 8. Evidencia de ensayo

Validado el 2026-10-21 en la cuenta demo, sin tocar el stack principal:

- `cctv-retain-test`: deployment completo desde cero; `retain-data` eliminó la aplicación y conservó el bucket de videos, Catalog y Audit. Se verificaron bucket privado/no público y ambas tablas `ACTIVE`. Luego `purge-retained` eliminó los tres recursos conservados.
- `cctv-purge-test`: deployment completo desde cero; `purge-data` eliminó SPA, stack, bucket de videos y tablas retenidas.
- Verificación posterior: ambos stacks, ambos buckets de videos y las cuatro tablas retornaron `not found`; `cctv-storeindexer-demo` permaneció `UPDATE_COMPLETE`.

Los buckets de SPA contenían dos objetos reales de build y fueron vaciados correctamente. Los buckets de video y tablas del ensayo estaban vacíos porque las escrituras de datos descartables fueron bloqueadas por la política del entorno; la supervivencia/eliminación de los recursos protegidos sí quedó validada.

El ensayo usó `RolesAnywhereEnabled=false`, igual que el baseline PoC. El role uploader y su política de assume-role son eliminados con el stack. El usuario IAM preexistente no pertenece al stack: el cliente debe deshabilitar/eliminar manualmente su access key al cierre. La limpieza adicional de trust anchor/SSM continúa documentada para quienes habiliten el roadmap Roles Anywhere.
