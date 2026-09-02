#!/bin/sh
# tests/integration/scenarios/06-reproduce-issue-111.sh
#
# Scenario 06 — RED reproducer for issue #111 (sub-issue of EPIC #116).
#
# This scenario INTENTIONALLY fails against the current code to prove the
# bug from #111 is reproducible end-to-end. It will be DELETED when
# issue #119 ships its fix; #119 will also add a positive regression
# test (07-self-hosted-home.sh) that takes the SAME four conditions
# below and verifies the action succeeds.
#
# The bug, in one line:
#   entrypoint.sh:184 calls `: "${HOME:=/home/lftp}"`. When a self-hosted
#   GitHub Actions runner forwards HOME=/github/home into the container
#   (which is what actions/runner does by default), the `:=` fallback
#   never fires and lib.sh::write_netrc fails trying to write
#   /github/home/.netrc inside a read-only bind-mount of the runner's
#   actual home directory. Reported symptom:
#     "can't create /github/home/.netrc: Permission denied"
#
# The four conditions the bug needs (per #111 author):
#   1. HOME=/github/home exported into the container.
#   2. USER lftp active inside the container (Dockerfile sets it).
#   3. /github/home bind-mounted read-only into the container, owned
#      by a UID the in-container lftp user cannot write as.
#   4. entrypoint.sh:184 trusts the `:=` fallback (it does not: the
#      fallback only triggers when HOME is UNSET, not when it is set
#      to a hostile value).
#
# This scenario sets all four conditions and asserts that the
# container exits non-zero AND that the captured output shows a
# .netrc write failure. Reproducing the bug = the scenario PASSES
# (a red test that consistently reproduces the bug it was written
# for is GREEN). See issue #118 for the acceptance criteria.
#
# IMPORTANT: this scenario will be DELETED in #119. Do not extend it;
# add the positive regression test as scenarios/07-self-hosted-home.sh
# instead.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "06-reproduce-issue-111"

# --- Step 1: start the FTP server -------------------------------------------
# Same harness as scenarios 01, 02, 05: fauria/vsftpd with the per-
# scenario virtual user. The bug under test happens BEFORE lftp ever
# runs (the .netrc write is what fails, which is line 597 in lib.sh /
# line 184-187 in entrypoint.sh), but we still need a real FTP server
# reachable from the action container because the action validates
# INPUT_SERVER as part of its normal startup.
start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

# --- Step 2: build the host-side fake /github/home --------------------------
# Mimics what a self-hosted runner forwards: a host directory that
# the runner's actions.runner service bind-mounts into the action
# container. In rootless podman the container's lftp user (uid 1000)
# maps to a high host uid; bind-mounting a directory owned by host
# root (uid 0) means the in-container lftp user cannot write inside
# regardless of the uid mapping. Combined with the `:ro` bind-mount
# flag below this guarantees a write to /github/home/.netrc fails
# for any non-root in-container user — the exact failure surface
# actions/runner presents to the action.
#
# mktemp -d creates a directory owned by the test runner; chmod 0755
# keeps it from being world-writable (we want only root to be able
# to write inside — same as a real runner home).
_fake_home=$(mktemp -d -t fake-github-home.XXXXXX) \
  || log_fail "mktemp fake-github-home failed"
chmod 0755 "${_fake_home}"

# Extend the EXIT trap installed by scenario_setup so the fake home
# is also removed on any exit path (assertion failure, signal,
# normal exit). Single-quoted variable expansion means the trap
# dereferences _fake_home at fire time, so if the script fails
# before _fake_home is assigned, the trap is a harmless no-op
# (`rm -rf ""` is a no-op).
trap 'rm -rf "${_fake_home}"; stop_ftp_server' EXIT

# --- Step 3: invoke the action image with the four hostile conditions ------
#
# We do NOT use run_action from common.sh: that helper bakes in the
# INPUT_* env-file layout and the FIXTURES_DIR bind-mount but does
# not support the extra /github/home:ro bind-mount this reproducer
# needs. So we inline the runtime invocation here, matching the
# run_action style (combined stdout+stderr to a tempfile, exit
# code captured). Output is captured to a tempfile (not /dev/null)
# so the assertion below can grep for the .netrc error message.
#
# Inputs:
#   * IMAGE             — the action image under test (orchestrator
#                          exports this from its own $IMAGE).
#   * _fake_home        — bind-mounted read-only as /github/home.
#   * FIXTURES_DIR      — bind-mounted read-only as /data so
#                          INPUT_LOCAL_DIR=/data resolves to a real
#                          directory.
#   * HOME=/github/home — forces the entrypoint past the `:=` fallback.
#   * INPUT_SERVER      — ftp://127.0.0.1:<FTP_CONTROL_PORT> (host
#                          loopback, which the --network host action
#                          container shares).
#   * INPUT_USER / INPUT_PASSWORD — the per-scenario virtual user.
#   * INPUT_LOCAL_DIR=/data      — the bind-mounted fixture dir.
#
# We deliberately do NOT set INPUT_FTP_SSL_ALLOW (the action default
# is true): the .netrc write happens BEFORE lftp is invoked, so the
# SSL-vs-plain setting is irrelevant — the bug reproduces regardless.
_log=$(mktemp -t repro118.XXXXXX) \
  || log_fail "mktemp log file failed"

log_info "invoking action with HOME=/github/home bind-mounted :ro (log=${_log})"
set +e
timeout 30 ${RUNTIME} run --rm \
    --network host \
    -v "${FIXTURES_DIR}:/data:ro" \
    -v "${_fake_home}:/github/home:ro" \
    -e "HOME=/github/home" \
    -e "INPUT_SERVER=ftp://127.0.0.1:${FTP_CONTROL_PORT}" \
    -e "INPUT_USER=${FTP_USER}" \
    -e "INPUT_PASSWORD=${FTP_PASSWORD}" \
    -e "INPUT_LOCAL_DIR=/data" \
    "${IMAGE}" > "${_log}" 2>&1
_rc=$?
set -e

# --- Step 4: assert the bug was reproduced ----------------------------------

# Private helper for this scenario: the dual of assert_action_success.
# A red test is GREEN when the container exits non-zero AND the
# captured log contains a .netrc write failure. Any other failure
# (container didn't start, IMAGE missing, action timed out before
# reaching write_netrc) is a regression in the reproducer itself.
assert_action_failed_with_netrc_error() {
  _aafwe_rc=$1
  _aafwe_log=$2

  if [ "${_aafwe_rc}" -eq 0 ]; then
    printf '%s\n' "---- captured action log (unexpected exit 0) ----" >&2
    cat "${_aafwe_log}" >&2
    printf '%s\n' "---- end of action log ----" >&2
    log_fail "bug #111 NOT reproduced: action exited 0; the reproducer is stale (or #119 already shipped)"
  fi

  # The .netrc redirect inside write_netrc fails with one of these
  # messages depending on the shell and the underlying errno:
  #   * busybox ash on EROFS : "can't create ... : Read-only file system"
  #   * bash on EACCES       : "... : Permission denied"
  #   * bash on EROFS        : "... : Read-only file system"
  # We match any of those as long as the .netrc path appears in the
  # same line — that is the common signal that the write_netrc
  # redirect failed before lftp ever started. "cannot open" is
  # accepted too because some shells use that wording.
  if ! grep -iE '\.netrc.*(permission denied|read-?only file system|cannot create|cannot open)' \
      "${_aafwe_log}" >/dev/null; then
    printf '%s\n' "---- captured action log (no .netrc error matched) ----" >&2
    cat "${_aafwe_log}" >&2
    printf '%s\n' "---- end of action log ----" >&2
    log_fail "action exited ${_aafwe_rc} but no .netrc write failure was detected in the log"
  fi
}

assert_action_failed_with_netrc_error "${_rc}" "${_log}"

# Dump the last 30 lines of the captured log to stdout so a developer
# running the test locally (or reading the CI log) can see the exact
# error message the action produced without re-running. The tail is
# bounded so a very chatty lftp session does not flood the runner log.
# Note: we use `printf '%s\n'` (not a single-arg format string) for
# the banner lines because the bash builtin rejects `--` as the
# leading two characters of the format. (Same convention as the
# `printf '%s\n' "---- ..."` calls in scenarios 01, 02, 05.)
printf '%s\n' ""
printf '%s\n' "---- last 30 lines of captured action log ----"
tail -n 30 "${_log}"
printf '%s\n' "---- end of action log ----"

# Print the unique signal that the red test passed: reproducing
# bug #111 is the success criterion. Keep this line grep-friendly
# so the orchestrator / a CI job can detect "we reproduced the
# bug" vs. a silent PASS. Format: "REPRODUCED: <message>" verbatim.
printf 'REPRODUCED: action exited with code %s; .netrc write failure observed\n' "${_rc}"

rm -f "${_log}"

log_pass "scenario 06 passed (red test): bug #111 reproduced end-to-end"

exit 0
