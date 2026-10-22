# Backend

**Last reviewed:** 2026-10-22

Python AWS Lambda handlers and shared modules.

- `app/` — package: filename parser (T3.2), indexer (T3.3), search (T5.3), download-authorization (T5.4), catalog/audit access, added by their tasks.
- `tests/` — unit tests (pytest / stdlib unittest).
- `api/openapi.yaml` — versioned API contract (added in T5.1).

## Develop

```bash
make install     # ruff, mypy, pytest
make test        # run tests
make lint        # ruff format --check + ruff check
make typecheck   # mypy
```
