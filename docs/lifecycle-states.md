# Estados de ciclo de vida del catálogo

**Last reviewed:** 2026-10-22

## Propósito

El catálogo separa dos conceptos independientes:

- `catalogStatus`: calidad de la metadata extraída (`OK` o `INVALID_METADATA`).
- `lifecycleState`: disponibilidad física del objeto (`AVAILABLE`, `ARCHIVED`, `RESTORE_PENDING`, `RESTORED` o `DELETED`).

Una transición a almacenamiento de archivo no equivale a borrar. El objeto conserva su metadata y sigue siendo localizable, pero puede requerir una restauración antes de descargarse.

## Eventos y transiciones

S3 envía todos estos eventos a EventBridge. Una sola regla los dirige a SQS y un único Lambda idempotente actualiza DynamoDB.

| Evento S3/EventBridge | Estado resultante | Metadata registrada |
|---|---|---|
| `Object Created` | `AVAILABLE` | `stateChangedAt`, clase inicial, `deleted=false` |
| `Object Storage Class Changed` a `GLACIER`/`DEEP_ARCHIVE` | `ARCHIVED` | `storageClass`, `storageClassChangedAt`, `archivedAt` |
| `Object Storage Class Changed` a `GLACIER_IR`/IA | `AVAILABLE` | `storageClass`, `storageClassChangedAt` |
| `Object Access Tier Changed` a un tier de archivo | `ARCHIVED` | `accessTier`, `accessTierChangedAt`, `archivedAt` |
| `Object Restore Initiated` | `RESTORE_PENDING` | `restoreRequestedAt`, `restoreStatus=PENDING` |
| `Object Restore Completed` | `RESTORED` | `restoredAt`, `restoreExpiresAt` |
| `Object Restore Expired` | `ARCHIVED` | `restoreExpiredAt`, `restoreStatus=EXPIRED` |
| `Object Deleted` por API | `DELETED` | `deletedAt`, `deletionReason=DELETE_OBJECT`, `deletionType` |
| `Object Deleted` por lifecycle | `DELETED` | `deletedAt`, `deletionReason=LIFECYCLE_EXPIRATION`, `deletionType` |

Fuentes oficiales:

- [S3 con EventBridge](https://docs.aws.amazon.com/AmazonS3/latest/userguide/EventBridge.html)
- [Estructura de eventos de S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/ev-events.html)

## Búsqueda y descarga

- Las búsquedas normales excluyen `deleted=true`.
- La API permite `includeDeleted=true` para una vista operativa explícita.
- Los objetos archivados permanecen visibles con acción no disponible hasta su restauración.
- `GLACIER_IR` es descargable inmediatamente.
- `GLACIER` y `DEEP_ARCHIVE` solo son descargables si `HeadObject` confirma una copia restaurada vigente.
- La descarga vuelve a consultar S3. El catálogo nunca se usa como autoridad final para existencia o restauración.

La API para **iniciar** una restauración continúa pendiente. Esta iteración registra correctamente las transiciones emitidas por S3 y evita URLs rotas, pero no solicita restores en nombre del usuario.

## Idempotencia y eventos fuera de orden

S3/EventBridge entrega al menos una vez y puede entregar fuera de orden.

- Creaciones usan el `sequencer` de S3 y escritura condicional.
- Cambios de lifecycle usan `event time + rank de transición + event id` como orden determinístico.
- Duplicados y eventos anteriores fallan la condición de DynamoDB y se tratan como no-op.
- `DELETED` es terminal frente a otros eventos de lifecycle, incluso si llegan después; solo un nuevo `Object Created` real puede reactivar el registro.
- Si un evento de lifecycle llega antes que la creación, SQS lo reintenta; después de cinco fallos pasa a la DLQ.
- Los cambios resuelven el registro mediante el índice `by-object`; no ejecutan `Scan`.

## Escalabilidad y retención del catálogo

Un registro `DELETED` es un tombstone, no un objeto activo. Se conserva para explicar cuándo y por qué desapareció y recibe `catalogExpiresAt`.

DynamoDB TTL lo elimina de manera asíncrona después de `CATALOG_TOMBSTONE_RETENTION_DAYS` (365 días por defecto). Esto limita el crecimiento permanente del catálogo sin acoplar su retención a los 90 días de los videos.

El filtro de borrados se aplica después de la lectura de DynamoDB y no reduce unidades consumidas. Esto es aceptable para el piloto y para búsquedas dentro de la ventana activa. Si el volumen medido produce particiones con alta densidad de tombstones, el rollout deberá usar un índice sparse de objetos activos o mover tombstones a una partición histórica, además del sharding diario ya contemplado.

## Relación con una política de 90 días

Ejemplos:

- Standard durante 90 días y expiración: `AVAILABLE → DELETED`.
- Standard 30 días, Standard-IA 60 días y expiración: `AVAILABLE → AVAILABLE → DELETED`.
- Glacier Flexible durante el período de archivo: `AVAILABLE/ARCHIVED → RESTORE_PENDING → RESTORED → ARCHIVED → DELETED`.
- Glacier Instant Retrieval: puede cambiar la clase, pero continúa `AVAILABLE` porque no requiere restore.

No se configura una transición a Glacier automáticamente hasta que el cliente apruebe el SLA y el modelo de costos. El seguimiento de estados queda preparado para cualquiera de esos escenarios.

## Evidencia del despliegue demo — 2026-10-22

- Stack actualizado in-place y finalizado en `UPDATE_COMPLETE`; bucket y tablas no fueron reemplazados.
- Regla EventBridge habilitada para creación, borrado, transición de clase/tier y los tres eventos de restore.
- TTL de DynamoDB `ENABLED` sobre `catalogExpiresAt`; retención configurada en 365 días.
- Un evento `Object Deleted` con causa `Lifecycle Expiration` enviado a la cola produjo el tombstone esperado y fue excluido por la búsqueda normal.
- La entrega duplicada fue un no-op.
- Un evento de transición a Glacier más antiguo, entregado después de `Object Restore Completed`, no hizo retroceder el estado.
- `Object Restore Expired` devolvió el registro a `ARCHIVED/EXPIRED`.
- Un restore posterior no pudo revivir un tombstone `DELETED`; solo una nueva creación real lo reactivó.
- La re-subida de los fixtures devolvió ambos registros a `AVAILABLE`; cola y DLQ terminaron vacías.

El consumidor se validó primero con envelopes oficiales en la cola real. Después se eliminó físicamente el fixture sintético CAM92 de 256 bytes mediante `scripts/test-physical-delete.sh`. S3 emitió por sí mismo `Object Deleted`; el catálogo registró `DELETED`, `deletedAt=2026-10-22T15:09:10Z`, `deletionReason=DELETE_OBJECT` y `deletionType=Permanently Deleted`. La búsqueda normal lo excluyó, la vista histórica conservó exactamente un tombstone y la cola/DLQ terminaron vacías. La aceptación E2E de borrado queda cerrada.

## Ensayo físico de borrado

El ensayo final usa exclusivamente el fixture sintético `videos/CAM92_20261022_101500.avi` del stack demo. El script valida perfil/cuenta, stack, clave y tamaño antes de pedir una confirmación interactiva exacta. Luego comprueba S3, el tombstone, su exclusión de la búsqueda normal y que SQS/DLQ queden vacías.

Desde la raíz del proyecto:

```bash
./scripts/test-physical-delete.sh
```

Confirmación requerida: `BORRAR-CAM92`.

El script no admite otra clave ni otro stack. Al completarse, CAM92 permanece eliminado y su tombstone queda disponible para auditoría hasta que DynamoDB TTL lo retire.
