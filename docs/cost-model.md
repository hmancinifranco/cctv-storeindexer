# Modelo de costos P×Q — Video Archive

**Última revisión:** 2026-10-21
**Trazabilidad:** Requirements R10–R11 y design sections 2, 5 y 11.

Este documento **no es una cotización**. Permite comparar escenarios cuando el cliente defina cuántas cámaras subirá, cuánto generan y cuánto tiempo puede esperar para recuperar una grabación.

## 1. Lo que sabemos y lo que todavía no

### Confirmado por el cliente

- El estate local completo contiene aproximadamente **90 TB** entre todas las cámaras.
- La retención objetivo discutida es aproximadamente **3 meses (90 días)**.
- Se generan muchos archivos AVI pequeños.
- Las descargas son irregulares: algunas semanas puede haber varias y otras ninguna.
- El cliente quiere comenzar con pocas cámaras y escalar a partir de mediciones.

### Todavía no confirmado

- Qué porcentaje de los 90 TB se subirá a AWS.
- Cuántas cámaras participan y cuánto genera cada una.
- GB/día seleccionados para cloud.
- Cantidad y tamaño promedio/p95/máximo de archivos AVI.
- Región AWS.
- Tiempo máximo aceptable para recuperar un video.
- GB descargados por mes.

Por estas razones, **90 TB no se usa como volumen propuesto ni se presenta un total mensual único**. Solo puede emplearse como punto de sensibilidad si el cliente pide modelar el estate completo.

## 2. Piloto recomendado

| Variable | Rango de planificación |
|----------|------------------------|
| Cámaras | 3–5 cámaras representativas |
| Período de captura | Aproximadamente 7 días |
| Datos totales | 250–500 GB como rango inicial |
| Clase inicial | S3 Standard |
| Expiración | `keep` hasta aprobación explícita |
| Migración histórica | No incluida |

El piloto mide volumen, archivos y rendimiento. Después se reemplazan los supuestos por datos reales.

## 3. La decisión que gobierna el costo: tiempo de recuperación

| Escenario | Lifecycle para 90 días | Acceso al video | Cuándo evaluarlo |
|-----------|-------------------------|-----------------|-------------------|
| A. Simple | S3 Standard días 0–90 | Inmediato | Piloto y máxima simplicidad |
| B. Menor costo con acceso inmediato | Standard días 0–30 → Standard-IA días 30–90 | Inmediato | Buen candidato si las consultas se concentran en el primer mes |
| C. Archivo económico con acceso inmediato | Glacier Instant Retrieval desde el ingreso → expira día 90 | Inmediato | Si el acceso es muy poco frecuente y se acepta mayor cargo de recuperación |
| D. Archivo con espera | Glacier Flexible Retrieval desde el ingreso → expira día 90 | Restore previo: minutos a 12 horas | Solo si el cliente acepta la espera y se implementa el flujo de restauración |

### Restricciones relevantes

- Standard-IA tiene mínimo de 30 días.
- Glacier Instant Retrieval y Glacier Flexible Retrieval tienen mínimo de 90 días.
- Deep Archive tiene mínimo de 180 días, por lo que **no encaja** con una retención objetivo de 90 días.
- Un objeto menor a 128 KB no se mueve por lifecycle de forma predeterminada. Standard-IA y Glacier Instant Retrieval también facturan un mínimo de 128 KB por objeto.
- Glacier Flexible agrega 40 KB de metadata por objeto archivado, relevante cuando existen millones de archivos pequeños.

Fuentes oficiales:

- https://docs.aws.amazon.com/AmazonS3/latest/userguide/glacier-storage-classes.html
- https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html
- https://aws.amazon.com/s3/pricing/

## 4. Lifecycle que no debemos presentar como optimizado

Este patrón parece intuitivo, pero puede generar cargos inesperados:

```text
Standard días 0–30 → Glacier día 30 → borrar día 90
```

El objeto permanece solo 60 días en Glacier, pero Glacier Instant/Flexible tiene mínimo de 90 días. Se cobra el período restante aunque el objeto ya se haya eliminado.

Para usar Glacier con una retención total de 90 días, las alternativas coherentes son:

- ingresarlo directamente en Glacier desde el día 0; o
- extender la expiración hasta cumplir 90 días dentro de Glacier.

## 5. Fórmula P×Q por volumen seleccionado

Definir:

```text
D = GB/día realmente seleccionados para AWS
R = días de retención (objetivo: 90)
F = archivos/día
G = GB descargados por mes
T = cantidad de transiciones lifecycle por mes
```

Volumen almacenado estable:

```text
Stored_GB = D × R
```

### Escenario A — Standard 90 días

```text
Storage_A = D × 90 × precio_Standard
```

### Escenario B — Standard 30 días + Standard-IA 60 días

```text
Storage_B = (D × 30 × precio_Standard)
          + (D × 60 × precio_StandardIA)
          + (T × precio_transition_request)
          + retrieval_StandardIA
```

### Escenario C — Glacier Instant Retrieval 90 días

```text
Storage_C = D × 90 × precio_GlacierInstant
          + retrieval_GlacierInstant
          + request_costs
```

### Escenario D — Glacier Flexible Retrieval 90 días

```text
Storage_D = D × 90 × precio_GlacierFlexible
          + metadata_por_objeto
          + restore_requests
          + temporary_restored_copy
          + retrieval/egress
```

Costo total aproximado:

```text
Total = Storage
      + PUT/transitions
      + EventBridge + SQS + Lambda + DynamoDB
      + CloudTrail data events
      + WAF
      + download/restore/egress
      + DataSync (solo si se selecciona)
```

Los precios unitarios se cargan desde AWS Pricing Calculator para la región elegida. No deben hardcodearse en una propuesta comercial.

## 6. Sensibilidad por cámaras

Si todavía no hay medición por cámara:

```text
GB_por_cámara_por_día = GB_medidos_en_piloto ÷ cámaras_del_piloto ÷ días_medidos
D = suma de GB/día de las cámaras seleccionadas
Stored_GB = D × 90
```

No conviene estimar `90 TB × cámaras seleccionadas ÷ cámaras totales` salvo como aproximación inicial, porque bitrate, actividad y resolución pueden variar mucho entre cámaras.

La tabla que se presentará al cliente debe completarse después del piloto:

| Escenario | Cámaras | GB/día medidos | Retención | Clase/lifecycle | Restore | Costo estimado |
|-----------|---------|----------------|-----------|-----------------|---------|----------------|
| Piloto | 3–5 | por medir | 7–90 días | Standard | No | por calcular |
| Parcial | por definir | por calcular | 90 días | A/B/C/D | según opción | por calcular |
| Ampliado | por definir | por calcular | 90 días | A/B/C/D | según opción | por calcular |

## 7. Cantidad de archivos

La cantidad de archivos afecta requests, indexado y metadata de archivo:

```text
Files_per_day = D_GB × 1,000 ÷ Average_file_MB
Monthly_files = Files_per_day × 30
```

El piloto debe medir:

- archivos/día por cámara;
- tamaño promedio, p95 y máximo;
- pico de archivos/segundo;
- porcentaje menor a 128 KB;
- tiempo desde archivo terminado hasta registro en el catálogo.

## 8. Conectividad

El ancho de banda depende del volumen cloud seleccionado, no de los 90 TB locales:

```text
Mbps mínimos ≈ GB/día × 8,000 ÷ ventana_en_segundos
```

Luego se agrega margen por overhead, reintentos y tráfico concurrente. El piloto determina si `aws s3 sync` alcanza o si conviene evaluar AWS DataSync.

## 9. Descargas y restore

Registrar durante el piloto:

- solicitudes de descarga por semana;
- GB descargados;
- antigüedad del video solicitado;
- SLA aceptable de recuperación;
- porcentaje que debe estar disponible inmediatamente.

Estos datos deciden entre Standard/Standard-IA/Glacier Instant y Glacier Flexible. Si se elige Flexible, hay que presupuestar e implementar el flujo de restore antes del rollout.

## 10. Resultado del piloto

El piloto debe entregar:

1. GB/día por cámara.
2. Archivos/día y distribución de tamaños.
3. Throughput y backlog de transferencia.
4. Latencia de indexado, búsqueda y descarga.
5. Frecuencia y GB de descarga.
6. Matriz A/B/C/D en AWS Pricing Calculator para la región del cliente.
7. Recomendación de `aws s3 sync` versus DataSync.
8. Recomendación de lifecycle y recuperación.

Solo después de estas mediciones se presenta una cifra mensual y un plan de escalamiento.
