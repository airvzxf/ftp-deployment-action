#!/bin/sh
# 25-dry-run-unreachable.sh — dry run against a server that refuses
# the connection (#341).
#
# Business rule: a dry run checks a configuration before the real
# deploy, so it must fail when the server cannot be reached.
#
# Expected:   exit != 0, no "DRY RUN COMPLETED" banner, lftp's
#             "Connection refused" in stdout.
# Not expected: a full upload plan and a green step (lftp's
#             `mirror --dry-run` treats an unreachable target as an
#             empty remote directory).
set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "25-dry-run-unreachable"

_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env file failed"
_log=$(mktemp -t actlog.XXXXXX) || log_fail "mktemp log file failed"
trap 'rm -f "${_env:-}" "${_log:-}"' EXIT

# Nothing listens on TCP port 1 of the loopback: the connect is refused
# at once, without depending on a firewall or a timeout.
build_action_env_file "${_env}" "${IMAGE}" /data site \
  "INPUT_DRY_RUN=true" "INPUT_SERVER=ftp://127.0.0.1:1"
# run_action re-enables `set -e` before returning, so capture the code
# with `||` instead of reading $? after it.
_rc=0
run_action "${IMAGE}" "${_env}" 60 "${_log}" || _rc=$?

show_log() { sed 's/^/    | /' "${_log}" >&2; }

if [ "${_rc}" -eq 0 ]; then
  show_log; log_fail "dry run against a closed port exited 0"
fi
if grep -q "DRY RUN COMPLETED" "${_log}"; then
  show_log; log_fail "dry run against a closed port printed the DRY RUN COMPLETED banner"
fi
if ! grep -q "Connection refused" "${_log}"; then
  show_log; log_fail "stdout does not say why the dry run failed (Connection refused)"
fi

log_pass "scenario 25 passed: dry run fails when the server is unreachable"
exit 0
