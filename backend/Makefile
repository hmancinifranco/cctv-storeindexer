# SAM custom build for the backend Lambdas (Metadata.BuildMethod: makefile).
#
# SAM invokes `make build-<LogicalId>` with ARTIFACTS_DIR set to the output
# staging dir. Every function ships the same `app` package (boto3 is provided
# by the Lambda python runtime, so there are normally no deps to install); if
# requirements.txt ever gains real (non-comment) entries, they are pip-installed
# with whatever python3 is available (pure-python deps only).
#
# One canned recipe, three targets — keep in sync with the functions in
# infra/template.yaml that declare BuildMethod: makefile.

define COPY_APP
	mkdir -p "$(ARTIFACTS_DIR)"
	cp -r app "$(ARTIFACTS_DIR)/app"
	@if grep -qvE '^[[:space:]]*(#.*)?$$' requirements.txt 2>/dev/null; then \
		echo "Installing runtime deps from requirements.txt"; \
		python3 -m pip install -r requirements.txt -t "$(ARTIFACTS_DIR)"; \
	else \
		echo "No third-party deps to install (boto3 provided by runtime)"; \
	fi
endef

build-IndexerFunction:
	$(COPY_APP)

build-SearchFunction:
	$(COPY_APP)

build-DownloadFunction:
	$(COPY_APP)
