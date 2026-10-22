# Demo Runbook — Video Archive Prototype

**Last reviewed:** 2026-10-22
**Audience:** internal (SA driving the demo). Client-facing talking points are marked 🗣️.
**Environment:** use the AWS profile, region and stack configured in the local `.env`. Do not copy resource IDs or credentials between accounts.

Guion para mostrarle al cliente el prototipo funcionando de punta a punta: un
servidor sube grabaciones → se inventarían solas → un usuario las busca y
descarga con auditoría. La PoC contiene la access key de un usuario técnico sin acceso S3 directo y usa sesiones temporales de un role acotado para cada sincronización.

---

## 0. Recursos en vivo (referencia)

Obtenga los valores de la cuenta donde se desplegó:

```bash
aws cloudformation describe-stacks --stack-name <stack> \
  --profile <perfil> --region <region> \
  --query 'Stacks[0].Outputs'
```

Use los outputs `CloudFrontUrl`, `VideoBucketName`, `UserPoolId`, `CatalogTableName` y `AuditTableName`. El usuario se crea con:

```bash
./scripts/create-user.sh usuario@cliente.com
```

Cognito entrega una contraseña temporal; ninguna contraseña debe guardarse en este documento.

> Antes de presentar, ejecute `./scripts/verify-deployment.sh`.

---

## 1. Narrativa (2 min, sin pantalla)

🗣️ "Hoy sus grabaciones viven en servidores locales y recuperarlas es manual.
Este prototipo las lleva a AWS: el servidor las sube solo, quedan inventariadas
por fecha/hora/cámara automáticamente, y su equipo las busca y descarga desde el
navegador — con acceso controlado y auditoría de quién pidió cada video."

Arquitectura en una frase 🗣️: "Servidor → S3 (privado) → indexado automático en
una base liviana → interfaz web con login → descarga por enlace temporal."

Mostrar el diagrama: `architecture/client-proposal-aws-icons.drawio`.

---

## 2. Ingesta desde el servidor (5 min)

Para la PoC, el Windows Server usa un usuario IAM técnico únicamente como fuente de credencial. Ese usuario no puede acceder directamente a S3: AWS CLI asume el uploader role y recibe una sesión temporal de una hora.

Mostrar la identidad del perfil final:

```powershell
aws sts get-caller-identity --profile cctv-uploader --region us-east-1
```

Luego ejecutar primero el dry-run y después la carga segura desde la carpeta de archivos terminados:

```powershell
.\uploader\iam-user\upload-videos.ps1 -SourceDirectory 'D:\ReadyToUpload' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1' -DryRun
.\uploader\iam-user\upload-videos.ps1 -SourceDirectory 'D:\ReadyToUpload' -VideoBucketName '<VideoBucketName>' -IngestPrefix 'videos' -Region 'us-east-1'
```

Después de validar la carga manual, la misma operación puede registrarse cada 15 minutos mediante `register-task.ps1`.

🗣️ Puntos clave:

- La access key pertenece a un usuario técnico único y no tiene permisos S3 directos.
- El usuario puede asumir exactamente un role.
- El role solo puede listar/subir dentro de `videos/`; no puede leer ni borrar.
- La key se deshabilita o elimina al cerrar el piloto.
- IAM Roles Anywhere es la mejora recomendada para reemplazar esa key por certificados y credenciales completamente temporales.

Configuración PoC: `uploader/iam-user/README.md`. Roadmap: `uploader/roles-anywhere/README.md`.

---

## 3. Inventario automático (2 min)

Los objetos recién subidos disparan el pipeline
`S3 → EventBridge → SQS → Lambda → DynamoDB` y quedan catalogados en segundos.

```bash
# Total catalogado
aws dynamodb scan --table-name <CatalogTableName> --select COUNT \
  --profile <perfil> --region <region> --query 'Count'
```

🗣️ "El inventario es automático: ni bien el archivo llega, el sistema lee la
fecha, hora y cámara del nombre y lo cataloga. Los nombres mal formados no se
pierden: quedan marcados como 'metadata inválida' para revisar, nunca se
descartan en silencio."

Mostrar que los nombres inválidos quedan en cuarentena:

```bash
aws dynamodb query --table-name <CatalogTableName> \
  --key-condition-expression "PK = :pk" \
  --expression-attribute-values '{":pk":{"S":"INVALID"}}' --select COUNT \
  --profile <perfil> --region <region> --query 'Count'
```

---

## 4. Búsqueda y descarga en la web (5 min) — el momento principal

1. Abrir el output **CloudFrontUrl** (ventana incógnito para mostrar el login desde cero).
2. 🗣️ "Sin login no se ve nada" → click **Iniciar sesión** → hosted UI de Cognito.
3. Entrar con el usuario creado para la reunión y su contraseña temporal/permanente; nunca colocarla en este documento.
4. Buscar: Fecha = **2026-09-21** → **Buscar**. Aparecen las grabaciones con
   estado (Disponible / Metadata inválida / Restauración pendiente).
5. Click **Descargar** en una fila → se genera un **enlace temporal (120 s)** y
   baja el archivo. 🗣️ "El enlace expira solo, y queda registrado quién lo pidió."
6. Mostrar el **toggle sol/luna** (tema claro/oscuro) arriba a la derecha.
7. **Cerrar sesión** → vuelve al login.

Estados que vale la pena mostrar (si hay tiempo): sin resultados, metadata
inválida, y el aviso de acceso denegado.

---

## 5. Seguridad y auditoría (3 min)

🗣️ Cuatro mensajes:

1. **Acceso restringido**: la web exige login individual (Cognito). Se puede
   sumar restricción por IP de oficina (WAF) — está diseñado, se activa con un flag.
2. **Descarga auditada**: cada solicitud de descarga se registra con quién,
   cuándo y desde qué IP — **sin guardar el enlace** (que es una credencial temporal).
3. **Enlace ≠ prueba de descarga** (honestidad técnica): registramos quién *pidió*
   el enlace. CloudTrail S3 Data Events permitirá registrar el acceso real al
   objeto cuando se implemente; hoy esa segunda evidencia todavía está pendiente.
4. **Credencial PoC contenida**: la key del usuario técnico no accede a S3; solo obtiene una sesión temporal del uploader role. Se retira al finalizar el piloto. Roles Anywhere elimina esa key en el roadmap.

Mostrar un registro de auditoría real (sin fuga de URL):

```bash
aws dynamodb query --table-name <AuditTableName> \
  --key-condition-expression "PK = :pk" \
  --expression-attribute-values '{":pk":{"S":"OBJ#<stable-id>"}}' \
  --profile <perfil> --region <region> --query 'Items[0]'
```

---

## 6. Costos (2 min)

🗣️ "El costo depende de cuántas cámaras y GB/día se seleccionen, del período de retención y del tiempo aceptable para recuperar un video." Abrir `docs/cost-model.md` y mostrar la matriz de escenarios para 90 días: Standard; Standard 30 días → Standard-IA 60 días; Glacier Instant Retrieval; o Glacier Flexible Retrieval si aceptan restore. Los 90 TB actuales son una referencia del estate local, no el volumen confirmado que se subirá a AWS. No presentar un total mensual hasta medir el piloto y validar los precios de la región en AWS Pricing Calculator.

---

## 7. Qué está y qué falta (encuadre honesto)

**Funciona hoy (desplegado y validado):** ingesta segura, inventario automático,
búsqueda autenticada, descarga con enlace temporal, auditoría, interfaz web con
tema claro/oscuro, credenciales temporales en el servidor.

**Roadmap (documentado, no en el prototipo):** definir el lifecycle de 90 días entre Standard, Standard→Standard-IA, Glacier Instant o Glacier Flexible según costo y SLA; implementar restore si se elige Flexible; completar WAF en modo enforce y MFA obligatorio.

**Pendiente de confirmar con el cliente:** software exacto del DVR/NVR y formato
real de nombres de archivo, volumen y retención reales, CIDRs de oficina.

---

## 8. Post-demo — apagar o retirar la PoC

Si se desplegó una EC2 para simular el servidor, deténgala cuando no se utilice. Obtenga su ID desde el stack auxiliar, no desde este documento.

Para revisar todos los recursos sin borrar nada:

```bash
./scripts/teardown.sh --plan
```

Después elija el resultado aprobado:

```bash
# Retirar aplicación/identidad, conservar videos, catálogo y auditoría
./scripts/teardown.sh --retain-data --confirm <nombre-del-stack>

# Eliminar permanentemente también los datos (requiere aprobación escrita)
./scripts/teardown.sh --purge-data --confirm <nombre-del-stack>
```

Detalle y controles: `docs/teardown.md`.

## Siguiente paso

Después de la demostración:

1. Registre volumen, archivos, throughput y decisiones en [`cost-model.md`](cost-model.md).
2. Revise estados de archivo/eliminación en [`lifecycle-states.md`](lifecycle-states.md).
3. Ejecute el plan read-only de [`teardown.md`](teardown.md); no elija `retain-data` o `purge-data` sin aprobación explícita.
