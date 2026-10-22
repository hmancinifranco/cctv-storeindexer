# Video Archive Prototype — developer entry points.
# Targets mirror the CI gates (see .github/workflows/ci.yml).

.PHONY: help install format lint typecheck test validate openapi-validate powershell-validate secret-scan check

help:
	@grep -E '^[a-zA-Z_-]+:.*?# .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?# "}{printf "  %-18s %s\n", $$1, $$2}'

install:  # install Python dev tooling
	python3 -m pip install ruff mypy pytest

format:  # auto-format Python
	ruff format backend uploader

lint:  # lint Python (ruff)
	ruff format --check backend uploader
	ruff check backend uploader

typecheck:  # static types (mypy)
	mypy

test:  # unit tests (pytest)
	python3 -m pytest

validate:  # validate SAM/CloudFormation templates (cfn-lint if present, else local parser)
	@if command -v cfn-lint >/dev/null 2>&1; then \
		cfn-lint infra/**/*.yaml infra/*.yaml; \
	else \
		echo "cfn-lint not installed — using local validator"; \
		python3 scripts/validate_templates.py; \
	fi

openapi-validate:  # validate the OpenAPI contract (if present)
	@if [ -f backend/api/openapi.yaml ]; then \
		python3 -c "import yaml,sys; yaml.safe_load(open('backend/api/openapi.yaml')); print('OpenAPI parses')"; \
	else echo "no OpenAPI contract yet — skipping"; fi

powershell-validate:  # parse Windows uploader scripts with PowerShell
	@if [ -x .tools/powershell/7.6.6/pwsh ]; then \
		.tools/powershell/7.6.6/pwsh -NoLogo -NoProfile -File scripts/validate-powershell.ps1; \
	elif command -v pwsh >/dev/null 2>&1; then \
		pwsh -NoLogo -NoProfile -File scripts/validate-powershell.ps1; \
	else \
		echo "PowerShell missing; run ./scripts/install-powershell-macos.sh" >&2; exit 1; \
	fi

secret-scan:  # fail if secrets / presigned URLs appear in source
	bash scripts/scan_secrets.sh

check: lint typecheck test validate openapi-validate powershell-validate secret-scan  # run all gates
