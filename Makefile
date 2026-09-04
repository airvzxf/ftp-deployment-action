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
VERSION          ?= dev
IMAGE            ?= ftp-deployment-action:local
# Pre-baked FTPS test server image (tests/integration/Dockerfile.test-
# server). Used by scenarios 03 / 04 in tests/integration/scenarios/.
# Closed #135: the previous inline `apk add vsftpd openssl` on every
# scenario start raced the apk index download against the 20s
# wait_for_port deadline in CI; the pre-baked image eliminates that
# race.
TEST_SERVER_IMAGE ?= ftp-deployment-action-test-server:ci-integration

# Container runtime detection (matches the runtime-detection logic in
# tests/integration/lib/common.sh: docker first, podman fallback).
# Used by `clean` so a rootless-podman-only developer gets their
# images removed instead of `docker rmi` failing silently. `make
# build` and `make build-test-server-image` keep their explicit
# `docker` invocations — docker is the CI runtime, and the local
# dev / CI parity check wants the build to error loudly if docker
# is missing rather than fall through to a different binary.
RUNTIME          := $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)

# Export IMAGE / TEST_SERVER_IMAGE so sub-process invocations
# (`make integration` -> tests/integration/run-integration-tests.sh,
# `make build-test-server-image` -> the buildx subprocess) inherit
# the Makefile defaults. Without `export`, a developer who runs
#   make build IMAGE=mytag:local
#   make build-test-server-image TEST_SERVER_IMAGE=mytag-server:local
#   make integration
# would have `make integration` use the Makefile's hardcoded
# default (ftp-deployment-action-test-server:ci-integration)
# instead of the locally-built mytag-server:local, because each
# `make` invocation starts a fresh shell and the prior command-
# line overrides do not persist. `export` here propagates the
# command-line overrides set on this `make` invocation into the
# sub-shell that runs the recipe. CI already passes both on the
# command line; this only affects the local-dev override path.
export IMAGE
export TEST_SERVER_IMAGE

# ----------------------------------------------------------------------------
# Lint: shellcheck on all .sh files, actionlint on action.yml, hadolint
# on every Dockerfile in the repo. actionlint is installed from
# upstream's release tarball to avoid pulling the full Go toolchain.
# ----------------------------------------------------------------------------
.PHONY: lint
lint: shellcheck actionlint hadolint

.PHONY: shellcheck
shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { \
		echo "shellcheck not found; install with: apt-get install shellcheck / apk add shellcheck"; \
		exit 1; }
	# -x: follow `shellcheck source=` directives (entrypoint.sh sources lib.sh,
	# tests/integration/scenarios/*.sh source tests/integration/lib/common.sh).
	# Pass common.sh alongside each scenario so shellcheck's source= path
	# resolution can find the shared library.
	shellcheck -x entrypoint.sh lib.sh tests/contract.sh tests/smoke.sh scripts/backfill-releases.sh
	shellcheck -x tests/integration/lib/common.sh tests/integration/run-integration-tests.sh
	shellcheck -x tests/integration/scenarios/*.sh

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
	# Both the action Dockerfile and the pre-baked FTPS test server
	# Dockerfile (closes #135). The previous target only covered
	# `Dockerfile`, which left Dockerfile.test-server unlinted in CI.
	hadolint --failure-threshold error Dockerfile
	hadolint --failure-threshold error tests/integration/Dockerfile.test-server

# ----------------------------------------------------------------------------
# Test: the contract test (action.yml <-> entrypoint.sh/lib.sh consistency)
# and the smoke tests (entrypoint.sh run inside an Alpine container). The
# smoke tests require docker or podman; if neither is available they
# skip with a notice, mirroring the smoke.sh behaviour.
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
# Unit tests: bats tests for the pure functions in lib.sh. Faster
# than the smoke tests (no docker, no lftp, no network) — run
# these during local iteration. Skipped (exit 0) if bats is not
# installed.
# ----------------------------------------------------------------------------
.PHONY: unit
unit:
	@command -v bats >/dev/null 2>&1 || { \
		echo "bats not found; install with: apt-get install -y bats"; \
		echo "(see tests/unit/README.md for alternatives)"; \
		exit 0; }
	bats tests/unit

# ----------------------------------------------------------------------------
# Build: a local Docker image tagged ftp-deployment-action:local. VERSION
# is baked into /app/VERSION; the default 'dev' matches the value
# committed in the repo.
# ----------------------------------------------------------------------------
.PHONY: build
build:
	docker build -t $(IMAGE) --build-arg VERSION=$(VERSION) .

# ----------------------------------------------------------------------------
# build-test-server-image: build the pre-baked FTPS test server image
# (tests/integration/Dockerfile.test-server) used by scenarios 03 and
# 04. CI builds this before `make integration`; local developers can
# run it standalone with `make build-test-server-image
# TEST_SERVER_IMAGE=ftpint-test-server:local`. The Makefile variable
# TEST_SERVER_IMAGE defaults to `ftp-deployment-action-test-server:
# ci-integration`, matching the tag the CI workflow uses, so the
# Makefile target is in lockstep with `make integration` without
# needing a separate flag.
#
# `tests/integration` is the build context (not the repo root) so
# only the Dockerfile.test-server and its adjacent files are sent to
# the docker daemon — the rest of the repo (action source, fixtures,
# etc.) is never visible to the build.
# ----------------------------------------------------------------------------
# build-test-server-image: build the pre-baked FTPS test server image
# (tests/integration/Dockerfile.test-server) used by scenarios 03 and
# 04. CI builds this before `make integration`; local developers can
# run it standalone with `make build-test-server-image
# TEST_SERVER_IMAGE=ftpint-test-server:local`. The Makefile variable
# TEST_SERVER_IMAGE defaults to `ftp-deployment-action-test-server:
# ci-integration`, matching the tag the CI workflow uses, so the
# Makefile target is in lockstep with `make integration` without
# needing a separate flag.
#
# `tests/integration` is the build context (not the repo root) so
# only the Dockerfile.test-server and its adjacent files are sent to
# the docker daemon — the rest of the repo (action source, fixtures,
# etc.) is never visible to the build.
#
# v2.11.3 (#156): Dockerfile.test-server pins `# syntax=docker/
# dockerfile:1.4` and uses a heredoc (`<<'EOF'`) for the pam.d
# vsftpd_virtual config. Plain `docker build` defaults to the legacy
# builder on Docker < 23.0 and rejects both, with a confusing parse
# error pointing at the heredoc line. CI happens to work today only
# because the GH Actions `ubuntu-latest` runner ships Docker 23+
# (BuildKit default builder). Switch to `docker buildx build` to
# match the canonical path used in `.github/workflows/release.yml`
# (`docker/setup-buildx-action@v4.3.0`) and make the BuildKit
# requirement load-bearing rather than incidental.
# ----------------------------------------------------------------------------
.PHONY: build-test-server-image
build-test-server-image:
	docker buildx build -f tests/integration/Dockerfile.test-server \
	    -t $(TEST_SERVER_IMAGE) tests/integration

# ----------------------------------------------------------------------------
# Integration: boot a real vsftpd container (docker.io/fauria/vsftpd) and
# exercise the action against it. Wired by #117; see tests/integration/README.md
# for the harness layout, the per-scenario conventions, and how to add a
# new scenario.
#
# IMAGE is the ftp-deployment-action image under test. CI sets
# IMAGE=ftp-deployment-action:ci-integration and builds it with `make build
# IMAGE=ftp-deployment-action:ci-integration VERSION=ci` first.
#
# TEST_SERVER_IMAGE is the pre-baked FTPS test server image used by
# scenarios 03 / 04 (closes #135). CI builds it with `make build-test-
# server-image` before invoking this target. The default tag matches
# what CI uses; override for local development with a different name.
#
# Skips (exit 0) if no docker/podman is on PATH, mirroring tests/smoke.sh.
# ----------------------------------------------------------------------------
.PHONY: integration
integration:
	@command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 || { \
		echo "no docker/podman found; skipping integration tests"; \
		exit 0; }
	$(SH) tests/integration/run-integration-tests.sh

.PHONY: run
run: build
	@tmp=$$(mktemp -t actenv.XXXXXX); \
	trap 'rm -f "$${tmp}"' EXIT; \
	{ printf '%s\n' "INPUT_SERVER=$${FTP_SERVER:-ftp://example.com}"; \
	  printf '%s\n' "INPUT_USER=$${FTP_USERNAME:-anonymous}"; \
	  printf '%s\n' "INPUT_PASSWORD=$${FTP_PASSWORD:-}"; \
	  printf '%s\n' "INPUT_LOCAL_DIR=/data"; \
	} > "$${tmp}"; \
	chmod 0600 "$${tmp}"; \
	docker run --rm -it \
	    --env-file "$${tmp}" \
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
	-$(RUNTIME) rmi -f $(IMAGE) 2>/dev/null
	-$(RUNTIME) rmi -f $(TEST_SERVER_IMAGE) 2>/dev/null
