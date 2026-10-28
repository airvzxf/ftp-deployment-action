# Makefile — ftp-deployment-action developer shortcuts.
#
# Missing tools are handled per target. unit (bats), smoke and
# integration (docker/podman) skip with exit 0; shellcheck, actionlint
# and hadolint exit 1; build, build-test-server-image, run (docker),
# release-smoke (docker or podman) and acceptance (bats) fail when
# their tool is absent, while clean and build-smoke-image exit 0 without a
# runtime. The Makefile is
# the source of truth for the shellcheck file list and flags and for
# the smoke / integration invocations, which .github/workflows/ci.yml
# calls (`make shellcheck`, `make smoke`, `make integration`); other
# CI jobs (actionlint, hadolint, contract, unit, acceptance) run their
# tools directly, and this Makefile mirrors them for local iteration.

SHELL := /bin/sh

# Use bash where available, fall back to sh. These recipes run on the
# host, not in the action image. So `make contract`, `make smoke`,
# `make acceptance`, `make integration` and `make release-smoke` run
# their #!/bin/sh harness scripts (tests/contract.sh, tests/smoke.sh,
# tests/acceptance/static.sh, tests/integration/run-integration-tests.sh,
# tests/release-smoke.sh) under bash (where bash is installed), locally and in the CI jobs that
# go through make (ci.yml `make smoke`, `make integration`). Through
# make, none of them is run under dash or busybox ash. tests/smoke.sh and
# tests/integration/run-integration-tests.sh are only ever run this
# way. On ubuntu-latest, where /bin/sh is dash, three of them are run
# directly: tests/contract.sh (ci.yml contract job, by its shebang),
# tests/acceptance/static.sh (ci.yml acceptance job, `sh`) and
# tests/release-smoke.sh (release.yml, by its shebang). shellcheck
# checks all of them as sh (`make shellcheck`).
SH := $(shell command -v bash 2>/dev/null || echo sh)

# Repository root (parent of this file).
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

PYTHON           ?= python3
IMAGE            ?= ftp-deployment-action:local
# Pre-baked FTPS test server image (tests/integration/Dockerfile.test-
# server). It is the FTPS server of the scenarios that call
# start_ftps_server; it also supplies nc for wait_for_port (called by
# start_ftp_server, so every plain-FTP scenario) and lftp for
# lftp_run_script (the variant B scenarios 01, 02, 05); see
# tests/integration/lib/. run-integration-tests.sh exits 2 if it is
# missing.
# Closed #135: the previous inline `apk add vsftpd openssl` on every
# scenario start raced the apk index download against the 20s
# wait_for_port deadline in CI; the pre-baked image eliminates that
# race.
TEST_SERVER_IMAGE ?= ftp-deployment-action-test-server:ci-integration

# Pre-baked smoke-test image (tests/Dockerfile.smoke). Used by
# tests/smoke.sh (every run_init call in the suite). Closed #137:
# the previous inline `apk add --no-cache lftp ca-certificates` on
# every smoke container raced the apk index download and silently
# masked apk failures behind `>/dev/null 2>&1`. The pre-baked image
# is built once via `make build-smoke-image` and pinned to the
# same alpine digest + lftp version as the production image (the
# FROM line and the lftp pin in the Dockerfile), so the smoke suite exercises the same
# runtime the user gets.
SMOKE_IMAGE ?= ftp-deployment-action-smoke:local

# Container runtime detection (matches the runtime-detection logic in
# tests/integration/lib/common.sh: docker first, podman fallback).
# Used by `clean` so a rootless-podman-only developer gets their
# images removed instead of `docker rmi` failing silently, and by
# `build-smoke-image`, which is on the `make test` / `make smoke`
# path: it builds with podman when docker is absent and skips when
# neither is installed, so tests/smoke.sh can run or skip as
# documented instead of make aborting on `docker: not found`. `make
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
export SMOKE_IMAGE

# ----------------------------------------------------------------------------
# Lint: shellcheck on the .sh files listed in the recipe, actionlint on
# the workflows (the recipe passes no file arguments, so it lints
# .github/workflows; action.yml is not a workflow and is checked by
# tests/contract.sh instead), hadolint on every Dockerfile in the repo
# (the action image, the test server and the smoke image). actionlint
# is installed from
# upstream's release tarball to avoid pulling the full Go toolchain.
# v2.11.9 (#228): tests/release-smoke.sh is included so the
# post-build smoke check (run between image build and SBOM attach
# in release.yml) is shellcheck-clean from the same local target.
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
	shellcheck -x entrypoint.sh lib.sh tests/acceptance/static.sh tests/contract.sh tests/smoke.sh tests/release-smoke.sh
	shellcheck -x tests/integration/lib/common.sh tests/integration/run-integration-tests.sh
	shellcheck -x tests/integration/scenarios/*.sh
	# v2.11.13 (#317): include the FTPS-cert helper and the
	# tag-verifier script in the lint sweep. verify-tag.sh is clean;
	# self-signed-cert.sh has known SC2016 false positives
	# (the user_sub_token and local_root printf lines in
	# _write_ftps_vsftpd_conf write $$USER literals that are consumed by
	# vsftpd's *own* template expansion at
	# runtime, not by the outer shell; the docker -c body in
	# start_ftps_server (adduser, chpasswd, chmod) uses the
	# `'"$${var}"'` close-quote / open-double-quote trick to smuggle
	# outer-shell expansions into a `-c '...'` docker body, and
	# shellcheck parses the in-line `"$${var}"` segment as outer
	# shell code that looks like an unexpanded literal). Excluding
	# SC2016 is per-file (`-e`) so a future real SC2016 elsewhere
	# (entrypoint.sh, lib.sh, etc.) is still caught.
	shellcheck -x scripts/verify-tag.sh tests/integration/lib/self-signed-cert.sh -e SC2016

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
	# v2.11.3 (#137): also lint the pre-baked smoke-test image so
	# hadolint's DL3018 (pin apk versions) and DL3006 (pin base) cover
	# it from the first CI run.
	hadolint --failure-threshold error Dockerfile
	hadolint --failure-threshold error tests/integration/Dockerfile.test-server
	hadolint --failure-threshold error tests/Dockerfile.smoke

# ----------------------------------------------------------------------------
# Test (`make test` = contract unit smoke): the contract test
# (action.yml <-> entrypoint.sh/lib.sh consistency), the bats unit tests
# (skipped if bats is not installed) and the smoke tests (entrypoint.sh
# run inside an Alpine container). The smoke tests require docker or
# podman; if neither is available they skip with a notice, mirroring the
# smoke.sh behaviour.
# ----------------------------------------------------------------------------
.PHONY: test
# v2.11.13 (#315): make smoke depends on a pre-baked SMOKE_IMAGE
# (tests/smoke.sh fails fast when the image is missing). Previously
# `make test` -> `make smoke` hard-failed locally for any developer
# who had not remembered to run `make build-smoke-image` first.
# build-smoke-image is a prerequisite of `smoke` (not a sibling in
# `test:`), so `make smoke` on its own and `make -j test` both build
# the image before tests/smoke.sh runs. build-smoke-image is .PHONY,
# so the image is rebuilt on every run (the build is cached, so an
# unchanged Dockerfile.smoke costs little), not only when absent. CI
# builds the image explicitly before invoking `make smoke`
# (.github/workflows/ci.yml, "Build the smoke-test image"); the
# rebuild through this prerequisite then reuses that cache. The
# `integration:` target is untouched — it depends on a different
# image (`make build IMAGE=...` + `make build-test-server-image`)
# which the integration job builds explicitly.
test: contract unit smoke

.PHONY: contract
contract:
	$(SH) tests/contract.sh

.PHONY: smoke
smoke: build-smoke-image
	$(SH) tests/smoke.sh

.PHONY: acceptance
acceptance:
	PYTHON="$(PYTHON)" $(SH) tests/acceptance/static.sh
	bats tests/acceptance

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
# Build: a local Docker image tagged ftp-deployment-action:local. The
# repo's VERSION file is copied to /app/VERSION.
# ----------------------------------------------------------------------------
.PHONY: build
build:
	docker build -t "$(IMAGE)" "$(ROOT)"

# ----------------------------------------------------------------------------
# build-test-server-image: build the pre-baked FTPS test server image
# (tests/integration/Dockerfile.test-server). It is the FTPS server of
# the scenarios that call start_ftps_server; it also supplies nc for
# wait_for_port (every start_ftp_server scenario) and lftp for
# lftp_run_script (scenarios 01, 02, 05). CI builds this before `make
# integration`; local developers can
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
# dockerfile:1.4` (still does) and used a heredoc (`<<'EOF'`) for the
# pam.d vsftpd_virtual config (the file now writes it with printf).
# Plain `docker build` defaulted to the legacy builder on Docker < 23.0
# and rejected both, with a confusing parse error pointing at the
# heredoc line. CI had worked only because the GH Actions
# `ubuntu-latest` runner ships Docker 23+ (BuildKit default builder).
# The target therefore uses `docker buildx build`, to match the
# canonical path used in `.github/workflows/release.yml` (its
# docker/setup-buildx-action step; the pin lives there) and make the
# BuildKit requirement load-bearing rather than incidental.
# ----------------------------------------------------------------------------
.PHONY: build-test-server-image
build-test-server-image:
	docker buildx build --load -f "$(ROOT)/tests/integration/Dockerfile.test-server" \
	    -t "$(TEST_SERVER_IMAGE)" "$(ROOT)/tests/integration"

# ----------------------------------------------------------------------------
# build-smoke-image: build the pre-baked smoke-test image
# (tests/Dockerfile.smoke) used by tests/smoke.sh. CI builds this
# before `make smoke`; local developers can run it standalone with
# `make build-smoke-image SMOKE_IMAGE=ftpint-smoke:local`. The
# Makefile variable SMOKE_IMAGE defaults to `ftp-deployment-action-
# smoke:local`, matching the tag tests/smoke.sh expects (overridable
# for the `make smoke` target above).
#
# `tests` is the build context (not the repo root) so only the
# Dockerfile.smoke is sent to the docker daemon — the rest of the
# repo (action source, fixtures, scenarios, etc.) is never visible
# to the build. Same `buildx build --load` as
# `build-test-server-image` (closes #156): the syntax directive and
# any future heredoc syntax would otherwise fail under legacy
# `docker build` on Docker < 23.0. Unlike that target it runs
# $(RUNTIME), so podman builds it when docker is absent.
# ----------------------------------------------------------------------------
.PHONY: build-smoke-image
build-smoke-image:
	@if [ -z "$(RUNTIME)" ]; then \
		echo "no docker/podman found; skipping the smoke image build (tests/smoke.sh skips too)"; \
		exit 0; \
	fi; \
	set -x; \
	"$(RUNTIME)" buildx build --load -f "$(ROOT)/tests/Dockerfile.smoke" \
	    -t "$(SMOKE_IMAGE)" "$(ROOT)/tests"

# ----------------------------------------------------------------------------
# Integration: boot a real vsftpd container (docker.io/fauria/vsftpd) and
# exercise the action against it. Wired by #117; see tests/integration/README.md
# for the harness layout, the per-scenario conventions, and how to add a
# new scenario.
#
# IMAGE is the ftp-deployment-action image under test. CI sets
# IMAGE=ftp-deployment-action:ci-integration and builds it with `make build
# IMAGE=ftp-deployment-action:ci-integration` first.
#
# TEST_SERVER_IMAGE is the pre-baked FTPS test server image (closes
# #135): the FTPS server of the start_ftps_server scenarios; it also
# supplies nc for wait_for_port (every start_ftp_server scenario) and
# lftp for lftp_run_script (scenarios 01, 02, 05).
# run-integration-tests.sh exits 2 if it is missing.
# CI builds it with `make build-test-server-image` before invoking this
# target. The default tag matches what CI uses; override for local
# development with a different name.
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
	  printf '%s\n' "INPUT_PASSWORD=$${FTP_PASSWORD:-anonymous@}"; \
	  printf '%s\n' "INPUT_LOCAL_DIR=/data"; \
	} > "$${tmp}"; \
	chmod 0600 "$${tmp}"; \
	docker run --rm -it \
	    --env-file "$${tmp}" \
	    -v "$(ROOT)":/data:ro \
	    "$(IMAGE)"

# ----------------------------------------------------------------------------
# Release smoke tests: run the same checks the release pipeline
# runs against a freshly-built image, locally. Catches Dockerfile
# / lftp pin / version-line regressions before a tag is pushed.
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
	@echo 'Releases are cut by .github/workflows/release.yml on a signed tag push.'
	@echo 'Follow AGENTS.md: "Red / failed workflows: do NOT merge, repair until green"'
	@echo '(steps 7-10), "Tag the trunk merge commit, NOT the branch tip" and'
	@echo '"Tag signature guard". In short:'
	@echo '  1. Open a release branch + PR that bumps VERSION and stamps CHANGELOG.md.'
	@echo '  2. Wait for green CI, then squash-merge the PR.'
	@echo '  3. Tag the merge commit on main: git tag -s vX.Y.Z -m "..." <merge-sha>'
	@echo '  4. Push only the tag: git push origin vX.Y.Z'
	@echo '  5. release.yml checks the tag signature, that the tag commit is on main,'
	@echo '     and that VERSION matches the tag (vX.Y.Z-rc.N needs VERSION X.Y.Z).'

.PHONY: clean
clean:
	@if [ -z "$(RUNTIME)" ]; then \
		echo "make clean: no docker/podman on PATH; nothing to remove"; \
	else \
		"$(RUNTIME)" rmi -f "$(IMAGE)" 2>/dev/null || true; \
		"$(RUNTIME)" rmi -f "$(TEST_SERVER_IMAGE)" 2>/dev/null || true; \
		"$(RUNTIME)" rmi -f "$(SMOKE_IMAGE)" 2>/dev/null || true; \
	fi
