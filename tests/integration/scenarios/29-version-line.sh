#!/bin/sh
# 29-version-line.sh — the first log line names the release (no FTP server).
#
# Business rule: a support log shows which release @v2 / @latest resolved
# to. GitHub builds the Dockerfile on the runner without build args, so the
# version must come from the repo's VERSION file, not a build arg.
#
# Expected: the first line of a run is `ftp-deployment-action v<VERSION>`
#           for an image built the way GitHub builds it (no build args).
set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

printf '\n=== Scenario: %s ===\n' "29-version-line"

_expected="ftp-deployment-action v$(cat "${ROOT}/VERSION")"

# local_dir=../etc makes the run stop at validation (exit 2) without
# touching the network; the version line comes before that.
_out=$(${RUNTIME} run --rm \
    -e INPUT_SERVER=ftp://127.0.0.1:1 \
    -e INPUT_USER=u \
    -e INPUT_PASSWORD=p \
    -e INPUT_LOCAL_DIR=../etc \
    "${IMAGE}" 2>&1) || true
printf '%s\n' "${_out}" | head -3 | sed 's/^/    /'

_first=$(printf '%s\n' "${_out}" | head -1)
[ "${_first}" = "${_expected}" ] \
  || log_fail "first line is '${_first}', expected '${_expected}'"

log_pass "scenario 29 passed: first line is '${_expected}'"
exit 0
