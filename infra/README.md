# Infraestructura AWS

**Última revisión:** 2026-10-22

El stack principal se define en `infra/template.yaml` con AWS SAM/CloudFormation.

## Entry point soportado

No ejecute `sam deploy --guided` directamente y no use un `samconfig.toml` de otra cuenta. Desde la raíz del proyecto:

```bash
./scripts/preflight.sh --allow-cognito-only
./scripts/deploy-customer.sh --allow-cognito-only
```

El segundo comando despliega la infraestructura, recupera outputs, configura/compila el frontend, publica la SPA e invalida CloudFront.

## Recursos principales

- Buckets privados de videos y SPA.
- CloudFront con Origin Access Control.
- Cognito User Pool, cliente OAuth y grupo `Operators`.
- DynamoDB Catalog y Audit.
- EventBridge → SQS/DLQ → Lambda indexadora.
- API Gateway REST + Lambdas de búsqueda y descarga.
- Uploader role write-only when an existing `UPLOADER_IAM_USER_NAME` is configured; the user receives only exact `sts:AssumeRole`. The stack never creates access keys.
- Optional IAM Roles Anywhere profile when its roadmap flag is enabled.

## Estado de hardening

- Block Public Access, TLS-only y cifrado S3: implementados.
- Cognito y autorización de API: implementados.
- Restricción independiente por IP para descarga S3: implementada en modo `enforce`.
- WAF para CloudFront/API: pendiente. El preflight bloquea `enforce` hasta completarlo.
- CloudTrail S3 data events y alarmas: pendientes.

## Teardown

```bash
./scripts/teardown.sh --plan
```

Después de revisar el plan, siga `docs/teardown.md`. Los modos destructivos requieren `--confirm <stack-name>`.

El template conserva por defecto el bucket de videos y las tablas Catalog/Audit al borrar el stack. El script de teardown decide si conservarlos o purgarlos explícitamente.
