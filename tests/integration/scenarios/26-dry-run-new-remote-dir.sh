#!/bin/sh
# 26-dry-run-new-remote-dir.sh — dry run of a first deploy, when
# remote_dir does not exist on the server yet.
#
# Business rule: a first deploy is the most common reason to run a dry
# run, so a missing remote_dir must not make it fail, and the dry run
# must not create it.
#
# Expected:   exit 0, "DRY RUN COMPLETED" banner, stdout lists the
#             fixture files, remote_dir is still absent on the server.
set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "26-dry-run-new-remote-dir"
start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env file failed"
_log=$(mktemp -t actlog.XXXXXX) || log_fail "mktemp log file failed"
trap 'rm -f "${_env:-}" "${_log:-}"; stop_ftp_server' EXIT

build_action_env_file "${_env}" "${IMAGE}" /data new-site/www "INPUT_DRY_RUN=true"
# run_action re-enables `set -e` before returning, so capture the code
# with `||` instead of reading $? after it.
_rc=0
run_action "${IMAGE}" "${_env}" 60 "${_log}" || _rc=$?

show_log() { sed 's/^/    | /' "${_log}" >&2; }

if [ "${_rc}" -ne 0 ]; then
  show_log; log_fail "dry run to a missing remote_dir exited ${_rc}"
fi
grep -q "DRY RUN COMPLETED" "${_log}" || { show_log; log_fail "missing DRY RUN banner"; }
for _f in index.html about.html; do
  if ! grep -q "${_f}" "${_log}"; then
    show_log; log_fail "dry-run plan does not mention ${_f}"
  fi
done

assert_absent "${FTP_DATA_DIR}/${FTP_USER}" "new-site"

log_pass "scenario 26 passed: dry run of a first deploy shows the plan and creates nothing"
exit 0
