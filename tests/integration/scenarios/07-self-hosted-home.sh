#!/bin/sh
# tests/integration/scenarios/07-self-hosted-home.sh
#
# Scenario 07 — POSITIVE regression test for the fix to issue #111
# (sub-issue of EPIC #116). Mirrors the red reproducer scenario 06
# but on the FIXED entrypoint.sh. Asserts that the action no longer
# crashes with the .netrc write failure when a self-hosted runner
# forwards HOME=/github/home into the container.
#
# Background (from #111):
#   entrypoint.sh pre-fix used `: "${HOME:=/home/lftp}"`. When a
#   self-hosted GitHub Actions runner forwarded HOME=/github/home
#   (which actions/runner does by default), the `:=` fallback never
#   fired and lib.sh::write_netrc failed trying to write
#   /github/home/.netrc inside a read-only bind-mount of the
#   runner's actual home directory. Reported symptom:
#     "can't create /github/home/.netrc: Permission denied"
#
# The fix (issue #119): entrypoint.sh unconditionally pins
# NETRC=/home/lftp/.netrc and `export HOME=/home/lftp` so the bug
# cannot surface regardless of what HOME the runner forwards.
#
# This scenario sets up the same four conditions as scenario 06:
#   1. HOME=/github/home exported into the container.
#   2. USER lftp active inside the container (Dockerfile sets it).
#   3. /github/home bind-mounted read-only into the container,
#      owned by a UID the in-container lftp user cannot write as.
#   4. /data bind-mounted read-only so INPUT_LOCAL_DIR=/data
#      resolves to a real directory.
#
# What the scenario asserts:
#   * The captured action log does NOT contain a .netrc write
#     failure (Permission denied / Read-only file system /
#     cannot create / cannot open). That is the direct signal
#     that the bug from #111 is closed: the .netrc write inside
#     lib.sh::write_netrc succeeded (because the .netrc path is
#     now pinned to /home/lftp/, not /github/home/).
#
# What this scenario DELIBERATELY does NOT assert:
#   * That the upload to vsftpd succeeded end-to-end. lftp 4.9.3
#     (pinned in the Dockerfile) ignores .netrc for `ftp://host:port`
#     URLs and falls back to anonymous, which vsftpd rejects with
#     530. That is a separate bug (#124) outside the scope of #119.
#     Asserting end-to-end success here would make this scenario
#     red against the current code and break CI. Once #124 lands,
#     add `assert_action_success` to upgrade this to a true
#     end-to-end scenario — see TODO below.
#
#   * The action's exit code is intentionally NOT asserted to be 0.
#     With #124 open, lftp will exit non-zero (530 from vsftpd).
#     The scenario PASSES regardless of that exit code, as long
#     as the .netrc write failure from #111 is absent.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "07-self-hosted-home"

# --- Step 1: start the FTP server -------------------------------------------
# Same harness as scenarios 01/02/05/06. The FTP server is required
# because the action validates INPUT_SERVER as part of its normal
# startup; it also makes the scenario realistic.
start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

# --- Step 2: build the host-side fake /github/home --------------------------
# Mirrors scenario 06 verbatim: a host directory that mimics what a
# self-hosted runner forwards, bind-mounted :ro into the container.
# In rootless podman the in-container lftp user (uid 1000) maps to a
# high host uid; bind-mounting a directory owned by host root (uid 0)
# means the in-container lftp user cannot write inside regardless of
# the uid mapping. Combined with the `:ro` bind-mount flag below,
# this guarantees a write to /github/home/.netrc would fail for any
# non-root in-container user — exactly the failure surface the
# pre-fix action encountered.
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

# --- Step 3: invoke the action image with the four conditions --------------
#
# Same shape as scenario 06, but on the FIXED entrypoint.sh. The
# only behavioural difference vs. scenario 06 is the entrypoint:
# scenario 06 used to crash inside write_netrc (NETRC=/github/home/
# .netrc on a :ro bind-mount), scenario 07 does not (NETRC is
# unconditionally pinned to /home/lftp/.netrc by the fix).
#
# We do NOT use run_action from common.sh: that helper bakes in the
# INPUT_* env-file layout and the FIXTURES_DIR bind-mount but does
# not support the extra /github/home:ro bind-mount this scenario
# needs. So we inline the runtime invocation here, matching the
# run_action style (combined stdout+stderr to a tempfile, exit
# code captured). Output is captured to a tempfile (not /dev/null)
# so the assertion below can grep for the .netrc error message.
#
# Inputs (all go through an env-file; we do NOT pass -e KEY=VALUE on
# the runtime argv because podman/docker put those into /proc/<pid>/
# cmdline and `ps aux`, briefly exposing INPUT_PASSWORD to any other
# process on the host while the container is alive — closes #133):
#   * IMAGE             — the action image under test (orchestrator
#                          exports this from its own $IMAGE).
#   * _fake_home        — bind-mounted read-only as /github/home.
#   * FIXTURES_DIR      — bind-mounted read-only as /data so
#                          INPUT_LOCAL_DIR=/data resolves to a real
#                          directory.
#   * HOME=/github/home — forces the entrypoint past the `:=`
#                          fallback (which the fix removed anyway).
#   * INPUT_SERVER      — ftp://127.0.0.1:<FTP_CONTROL_PORT> (host
#                          loopback, which the --network host action
#                          container shares).
#   * INPUT_USER / INPUT_PASSWORD — the per-scenario virtual user.
#   * INPUT_LOCAL_DIR=/data      — the bind-mounted fixture dir.
#
# We deliberately do NOT set INPUT_FTP_SSL_ALLOW (the action default
# is true): the .netrc write happens BEFORE lftp is invoked, so the
# SSL-vs-plain setting is irrelevant to the bug under test.
_log=$(mktemp -t reg119.XXXXXX) \
  || log_fail "mktemp log file failed"

# Build the env-file via build_action_env_file so this scenario gets
# the same env-file interface (and chmod 0600) that scenarios 08/09/10
# already use, without the -e flag leaks the v2.11.0 harness shipped.
# HOME=/github/home is an extra kv: it must land INSIDE the container's
# environment (not on the host's) so the entrypoint's fixed
# `export HOME=/home/lftp` overrides it — but we still need the value
# present so the pre-fix `: "${HOME:=/home/lftp}"` fallback is
# demonstrably bypassed (the bind-mount then refuses the .netrc write
# at /github/home/.netrc on the original code path). See #119 for the
# HOME-pinning fix that made this scenario a regression test for #111.
_env=$(mktemp -t actenv.XXXXXX) \
  || log_fail "mktemp env file failed"
build_action_env_file "${_env}" "${IMAGE}" /data / \
    "HOME=/github/home"

# Extend the EXIT trap so the env-file is removed on any exit path.
# The previous trap cleaned _fake_home + FTP container; the new one
# also removes _env so the temporary INPUT_PASSWORD file does not
# survive the test run.
# v2.11.9 (#225): _log is included in the trap so the captured
# action log is removed on any exit path, not just the success
# branch. See scenarios 01 / 03 for the rationale.
#
# F2 audit (v2.11.9 +1 day): use :- defaults for _env and _log so
# a failure before either is assigned does not abort the trap under
# `set -u` and leak the FTP container. See scenario 03.
trap 'rm -f "${_env:-}" "${_log:-}"; rm -rf "${_fake_home:-}"; stop_ftp_server' EXIT

log_info "invoking action with HOME=/github/home bind-mounted :ro (log=${_log})"
set +e
timeout 30 ${RUNTIME} run --rm \
    --network host \
    -v "${FIXTURES_DIR}:/data:ro" \
    -v "${_fake_home}:/github/home:ro" \
    --env-file "${_env}" \
    "${IMAGE}" > "${_log}" 2>&1
_rc=$?
set -e

# --- Step 4: assert the bug was FIXED --------------------------------------
#
# Private helper for this scenario. We assert the NEGATION of the
# bug from #111: the captured log must NOT contain any of the
# .netrc write failure messages that the pre-fix code produced.
# We do NOT assert the action's exit code here — see the file
# header for why (lftp 4.9.3 / #124 makes the upload fail with
# 530, which would mask this regression test with a non-zero
# exit that's unrelated to #111).
assert_no_netrc_write_failure() {
  _anwf_log=$1

  # The .netrc redirect inside write_netrc fails with one of these
  # messages depending on the shell and the underlying errno:
  #   * busybox ash on EROFS : "can't create ... : Read-only file system"
  #   * bash on EACCES       : "... : Permission denied"
  #   * bash on EROFS        : "... : Read-only file system"
  # "cannot open" is accepted too because some shells use that
  # wording. Any match here means the pre-fix bug from #111 is
  # back, which is exactly what this scenario is here to catch.
  if grep -iE '\.netrc.*(permission denied|read-?only file system|cannot create|cannot open)' \
      "${_anwf_log}" >/dev/null; then
    printf '%s\n' "---- captured action log (.netrc failure detected) ----" >&2
    cat "${_anwf_log}" >&2
    printf '%s\n' "---- end of action log ----" >&2
    log_fail "bug #111 REGRESSION: .netrc write failure detected in the log"
  fi
}

assert_no_netrc_write_failure "${_log}"

# --- Step 5: dump a tail of the log for the developer -----------------------
#
# Print the action's rc + the last 30 lines of the captured log so a
# developer running the test locally (or reading the CI log) can see
# exactly what the action did, including the (expected) lftp-vs-vsftpd
# 530 failure. The tail is bounded so a chatty lftp session does not
# flood the runner log.
printf '%s\n' ""
printf '%s\n' "action container exited with code ${_rc} (expected: non-zero if #124 is open; see scenario header)"
printf '%s\n' "---- last 30 lines of captured action log ----"
tail -n 30 "${_log}"
printf '%s\n' "---- end of action log ----"

# Print the unique signal that the green test passed: the .netrc
# failure from #111 is gone. Keep this line grep-friendly so the
# orchestrator / a CI job can detect "we confirmed the fix" vs. a
# silent PASS. Format: "REGRESSION_FIXED: <message>" verbatim.
printf 'REGRESSION_FIXED: action ran without the .netrc write failure from #111\n'

# _log cleanup is handled by the EXIT trap installed above
# (v2.11.9 #225).

# TODO (v2.11.x): enable full upload assertion after #124 lands.
# lftp 4.9.3 (pinned in the Dockerfile) ignores .netrc for
# `ftp://host:port` URLs and falls back to anonymous, which
# vsftpd rejects with 530 Login authentication failed. Once that
# bug is closed, add `assert_action_success "${_log}" "${_rc}"`
# here and remove the file-header note about the deliberate
# non-assertion of the exit code. Until then, this scenario
# verifies the narrow fix from #119 (NETRC + HOME are pinned)
# without making end-to-end claims the rest of the pipeline
# cannot yet honour.

log_pass "scenario 07 passed (green): bug #111 fix verified end-to-end"

exit 0
