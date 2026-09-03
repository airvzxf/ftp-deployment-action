#!/bin/sh
# tests/integration/run-integration-tests.sh — orchestrator for the
# integration test suite.
#
# Runs every scenario in tests/integration/scenarios/ in lexical
# order. Each scenario is standalone (boot + teardown its own FTP
# server), so a failure in scenario N does NOT skip scenarios N+1..M.
# The orchestrator tracks per-scenario pass/fail and exits with the
# failure aggregate at the end.
#
# Usage:
#   tests/integration/run-integration-tests.sh
#
# Required env (set by the Makefile or the CI job):
#   IMAGE              ftp-deployment-action:<tag> under test
#                      (defaults to ftp-deployment-action:local).
#   FTP_SERVER_IMAGE   fauria/vsftpd tag to use for the test server
#                      (defaults to docker.io/fauria/vsftpd:latest).
#
# Exit code:
#   0  all scenarios passed
#   1  one or more scenarios failed
#   2  prerequisite missing (no docker/podman, IMAGE not built, etc.)

set -eu

# Resolve the integration test root from the script's location so the
# orchestrator is callable from any cwd.
# shellcheck disable=SC1007
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Repository root: parent of tests/integration. Used as a stable
# absolute path for the FTP_INTEGRATION_ROOT env var that each
# scenario sources, so common.sh can resolve FIXTURES_DIR regardless
# of how the scenario was invoked.
# shellcheck disable=SC1007
ROOT_REPO=$(CDPATH= cd -- "${ROOT}/../.." && pwd)

# Runtime detection. Skip with exit 0 if neither docker nor podman is
# available, mirroring tests/smoke.sh / tests/release-smoke.sh.
if command -v docker >/dev/null 2>&1; then
  RUNTIME=docker
elif command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
else
  printf 'skip: no docker/podman found\n'
  exit 0
fi
export RUNTIME

# Sanity check: the ftp-deployment-action IMAGE must exist in the
# local runtime. Pulling is not the orchestrator's job (the Makefile
# `build` step / the CI workflow does that). This is a fail-fast so
# the developer sees a clear "image not built" message instead of a
# downstream timeout inside the action.
: "${IMAGE:=ftp-deployment-action:local}"
export IMAGE

if ! ${RUNTIME} image inspect "${IMAGE}" >/dev/null 2>&1; then
  printf 'FAIL: IMAGE=%s not found in %s. Build it first:\n' \
    "${IMAGE}" "${RUNTIME}" >&2
  printf '  make build IMAGE=%s\n' "${IMAGE}" >&2
  exit 2
fi

# Same fail-fast for the pre-baked FTPS test server image (closes
# #135). Scenarios 03 / 04 will surface a confusing
# `vsftpd: not found` (or, post-pre-bake, a wait_for_port timeout)
# if this image is missing; checking up-front makes the failure
# mode obvious. Mirror the IMAGE block above: re-default from
# TEST_SERVER_IMAGE for callers that set the make variable but not
# the orchestrator's FTPS-specific name.
: "${FTP_TEST_SERVER_IMAGE:=${TEST_SERVER_IMAGE:-ftp-deployment-action-test-server:ci-integration}}"
export FTP_TEST_SERVER_IMAGE

if ! ${RUNTIME} image inspect "${FTP_TEST_SERVER_IMAGE}" >/dev/null 2>&1; then
  printf 'FAIL: TEST_SERVER_IMAGE=%s not found in %s. Build it first:\n' \
    "${FTP_TEST_SERVER_IMAGE}" "${RUNTIME}" >&2
  printf '  make build-test-server-image TEST_SERVER_IMAGE=%s\n' \
    "${FTP_TEST_SERVER_IMAGE}" >&2
  exit 2
fi

# Confirm the FTP server image is pullable. We try a one-shot
# `docker/podman pull` so the developer gets a clear error if the
# registry is unreachable, instead of a downstream failure when
# scenario 01 tries to start vsftpd.
: "${FTP_SERVER_IMAGE:=docker.io/fauria/vsftpd:latest}"
export FTP_SERVER_IMAGE

# Pre-pull fauria/vsftpd (idempotent, fast if already cached). We do
# NOT error out on a pull failure here because some CI runners
# already have it cached and the per-scenario `docker run` will
# surface a clear error if the image is genuinely missing.
if ! ${RUNTIME} pull "${FTP_SERVER_IMAGE}" >/dev/null 2>&1; then
  printf '%s\n' "  info: pre-pull of ${FTP_SERVER_IMAGE} failed; will retry on first scenario"
fi

# Confirm the fixtures directory exists. This catches a developer
# who runs `make integration` from a stale checkout where the
# fixtures/ tree was not yet committed.
if [ ! -d "${ROOT}/fixtures/sample-public-html" ]; then
  printf 'FAIL: fixtures directory missing: %s\n' \
    "${ROOT}/fixtures/sample-public-html" >&2
  exit 2
fi

# Discover scenarios in lexical order. POSIX `find` with -maxdepth
# is portable across busybox (alpine) and GNU find (ubuntu).
# Leading numeric prefix (01-, 02-, ...) ensures deterministic
# ordering across filesystems with different locale collation.
_scenarios=$(find "${ROOT}/scenarios" -maxdepth 1 -type f -name '*.sh' \
  | sort)

if [ -z "${_scenarios}" ]; then
  printf 'FAIL: no scenarios found under %s\n' "${ROOT}/scenarios" >&2
  exit 2
fi

# Per-scenario timing so the CI job log surfaces a slow scenario.
_start_ts() { date +%s; }
_elapsed()  { printf '%s' "$(( $(date +%s) - $1 ))s"; }

_passed=0
_failed=0
_failed_names=""

printf '%s\n' "=== ftp-deployment-action integration tests ==="
printf '  IMAGE=%s\n' "${IMAGE}"
printf '  FTP_SERVER_IMAGE=%s\n' "${FTP_SERVER_IMAGE}"
printf '  FTP_TEST_SERVER_IMAGE=%s\n' "${FTP_TEST_SERVER_IMAGE}"
printf '  RUNTIME=%s\n' "${RUNTIME}"
printf '  scenarios:'
for _s in ${_scenarios}; do
  printf ' %s' "$(basename "${_s}")"
done
printf '\n\n'

for _s in ${_scenarios}; do
  _name=$(basename "${_s}")
  _t0=$(_start_ts)

  # Each scenario is invoked as its own process so its `set -eu`
  # and `trap stop_ftp_server EXIT` are isolated from the
  # orchestrator. This is what makes scenarios "standalone":
  # a failed scenario cannot leave half-initialised global state
  # that bleeds into the next scenario.
  #
  # FTP_INTEGRATION_ROOT is exported so the scenario's
  # tests/integration/lib/common.sh can resolve the repository
  # root reliably. Without it, common.sh falls back to walking up
  # from $0, which is correct when the scenario is run directly
  # but fragile when the scenario is sourced from bash -c.
  set +e
  FTP_INTEGRATION_ROOT="${ROOT_REPO}" "${_s}"
  _rc=$?
  set -e

  _elapsed_str=$(_elapsed "${_t0}")

  if [ "${_rc}" -eq 0 ]; then
    printf '  %s: PASS (%s)\n' "${_name}" "${_elapsed_str}"
    _passed=$((_passed + 1))
  else
    printf '  %s: FAIL (exit %s, %s)\n' "${_name}" "${_rc}" "${_elapsed_str}" >&2
    _failed=$((_failed + 1))
    _failed_names="${_failed_names} ${_name}"
  fi
done

printf '\n=== integration summary ===\n'
printf '  passed: %s\n' "${_passed}"
printf '  failed: %s\n' "${_failed}"
if [ "${_failed}" -gt 0 ]; then
  printf '  failing scenarios:%s\n' "${_failed_names}" >&2
  exit 1
fi

exit 0
