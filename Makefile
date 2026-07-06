# Makefile — ftp-deployment-action developer shortcuts.
#
# All targets are no-ops if the underlying tool is not installed
# (the CI workflow is the source of truth, this Makefile is for
# local iteration).

SHELL := /bin/sh

# Use bash where available, fall back to sh. We do not use /bin/bash
# directly because alpine containers (where the action runs) ship
# only busybox ash.
SH := $(shell command -v bash 2>/dev/null || echo sh)

# Repository root (parent of this file).
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Override on the command line: make build VERSION=dev, etc.
VERSION ?= dev
IMAGE   ?= ftp-deployment-action:local

# ----------------------------------------------------------------------------
# Lint: shellcheck on all .sh files, actionlint on action.yml, hadolint
# on the Dockerfile. actionlint is installed from upstream's release tarball
# to avoid pulling the full Go toolchain.
# ----------------------------------------------------------------------------
.PHONY: lint
lint: shellcheck actionlint hadolint

.PHONY: shellcheck
shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { \
		echo "shellcheck not found; install with: apt-get install shellcheck / apk add shellcheck"; \
		exit 1; }
	shellcheck init.sh tests/contract.sh tests/smoke.sh

.PHONY: actionlint
actionlint:
	@command -v actionlint >/dev/null 2>&1 || { \
		echo "actionlint not found; install with the upstream binary"; \
		exit 1; }
	actionlint -color

.PHONY: hadolint
hadolint:
	@command -v hadolint >/dev/null 2>&1 || { \
		echo "hadolint not found; install with: brew install hadolint / download from hadolint/hadolint releases"; \
		exit 1; }
	hadolint --failure-threshold error Dockerfile

# ----------------------------------------------------------------------------
# Test: the contract test (action.yml <-> init.sh consistency) and the
# smoke tests (init.sh run inside an Alpine container). The smoke tests
# require docker or podman; if neither is available they skip with a
# notice, mirroring the smoke.sh behaviour.
# ----------------------------------------------------------------------------
.PHONY: test
test: contract smoke

.PHONY: contract
contract:
	$(SH) tests/contract.sh

.PHONY: smoke
smoke:
	$(SH) tests/smoke.sh

# ----------------------------------------------------------------------------
# Build: a local Docker image tagged ftp-deployment-action:local. VERSION
# is baked into /app/VERSION; the default 'dev' matches the value
# committed in the repo.
# ----------------------------------------------------------------------------
.PHONY: build
build:
	docker build -t $(IMAGE) --build-arg VERSION=$(VERSION) .

.PHONY: run
run: build
	docker run --rm -it \
		-e INPUT_SERVER=$${FTP_SERVER:-ftp://example.com} \
		-e INPUT_USER=$${FTP_USERNAME:-anonymous} \
		-e INPUT_PASSWORD=$${FTP_PASSWORD:-} \
		-e INPUT_LOCAL_DIR=/data \
		-v "$(PWD)":/data:ro \
		$(IMAGE)

# ----------------------------------------------------------------------------
# Release smoke tests: run the same checks the release pipeline
# runs against a freshly-built image, locally. Catches Dockerfile
# / lftp pin / build-arg regressions before a tag is pushed.
# Usage: make release-smoke IMAGE=ftp-deployment-action:local
# ----------------------------------------------------------------------------
.PHONY: release-smoke
release-smoke:
	@test -n "$(IMAGE)" || { \
		echo "usage: make release-smoke IMAGE=<image:tag>"; \
		echo "  e.g. make build IMAGE=ftp-deployment-action:local"; \
		echo "       make release-smoke IMAGE=ftp-deployment-action:local"; \
		exit 2; }
	$(SH) tests/release-smoke.sh "$(IMAGE)"

# ----------------------------------------------------------------------------
# Release: a thin reminder. The real release pipeline lives in
# .github/workflows/release.yml and is triggered by a signed tag push.
# ----------------------------------------------------------------------------
.PHONY: release
release:
	@echo "Releases are automated by .github/workflows/release.yml."
	@echo "To cut a new release locally:"
	@echo "  1. Stamp CHANGELOG.md (\$$VERSION to the new version)."
	@echo "  2. Commit the CHANGELOG bump with a signed commit."
	@echo "  3. Tag with: git tag -s \$$VERSION -m \"<message>\""
	@echo "  4. Push:     git push origin main \$$VERSION"
	@echo "The release workflow will then build, sign and publish."

.PHONY: clean
clean:
	docker rmi -f $(IMAGE) 2>/dev/null || true
