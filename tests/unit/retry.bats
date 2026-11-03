#!/usr/bin/env bats
# tests/unit/retry.bats — unit tests for the retry-loop helpers in
# lib.sh: classify_permanent_error, compute_backoff_seconds. The
# file-IO part of run_lftp_once is exercised by tests/smoke.sh.

setup() {
  set +u
  # v2.11.12 (F2 audit): drop the dead BATS_TESTDIR (no-underscores)
  # branch. The correct bats-core variable is BATS_TEST_DIRNAME; the
  # no-underscore form expands to empty under `set +u`, producing
  # `LIB="/../../lib.sh"` which is non-empty (so the fallback never
  # fires) and the file path is invalid. The other 6 .bats files
  # already use BATS_TEST_DIRNAME directly; align.
  # LIB_SRC overrides the lib.sh under test (used to prove the FND-0097
  # run_lftp_once tests fail on the pre-fix lib.sh).
  LIB="${LIB_SRC:-${BATS_TEST_DIRNAME}/../../lib.sh}"
  # shellcheck disable=SC1090
  . "${LIB}"
}

# ----------------------------------------------------------------------------
# classify_permanent_error
# ----------------------------------------------------------------------------

@test "classify_permanent_error: '530 Login authentication failed' is permanent" {
  f=$(mktemp)
  printf 'Trying to login...\n< 530 Login authentication failed\nmirror: Login failed: 530 Login authentication failed\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "classify_permanent_error: '530 Login incorrect' is permanent" {
  f=$(mktemp)
  printf '< 530 Login incorrect.\nmirror: Login failed: 530 Login incorrect.\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "classify_permanent_error: '550 Permission denied' is permanent" {
  f=$(mktemp)
  printf 'mirror: Access failed: 550 Permission denied\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "classify_permanent_error: '550 ... No such file' is permanent" {
  f=$(mktemp)
  printf 'mirror: Access failed: 550 /foo/bar: No such file or directory\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "classify_permanent_error: 'Connection refused' is transient (not permanent)" {
  f=$(mktemp)
  printf 'connect: Connection refused\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "classify_permanent_error: an empty log is transient" {
  f=$(mktemp)
  : > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

# F2 audit (#330): when the action uses net:max-retries=0 (the
# v2.11.14 default) lftp does NOT internally retry, so the FIRST
# attempt's server "530 Login incorrect" error is preserved verbatim
# in the log. The classifier must match it as PERMANENT. Before
# v2.11.14 the default was net:max-retries=1 and lftp's internal
# retry overwrote the 530 with "max-retries exceeded", silently
# breaking PERMANENT classification for this entire class of errors.
@test "classify_permanent_error: 'mirror: Login failed: 530 Login incorrect' is permanent (v2.11.14 #330 regression test)" {
  f=$(mktemp)
  printf 'Trying ftp://user@host:21\n---> PASS wrong\n<--- 530 Login incorrect.\nmirror: Login failed: 530 Login incorrect.\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

# ----------------------------------------------------------------------------
# FND-0045: classify_permanent_error matches only lftp's own error lines
# ("<cmd>: Login failed: ..." / "<cmd>: Access failed: 550 ..."), only in
# the bytes after OFFSET (the current attempt). Lines below are lftp 4.9.3
# output (maintainer evidence). Every assertion is a `run` + `[ ]` in the
# test body, so a wrong status fails the test.
# ----------------------------------------------------------------------------

@test "FND-0045: 'mirror: Login failed: 530 Login incorrect.' is permanent" {
  f=$(mktemp)
  printf 'mirror: Login failed: 530 Login incorrect.\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "FND-0045: 'mirror: Access failed: 550 Failed to change directory.' is permanent" {
  f=$(mktemp)
  printf 'mirror: Access failed: 550 Failed to change directory. (/nope)\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "FND-0045: a Login failed line after OFFSET is permanent (earlier bytes are unrelated)" {
  f=$(mktemp)
  printf 'Try #1\n-------\nconnect: Connection refused\n' > "$f"
  offset=$(wc -c < "$f" | tr -d '[:space:]')
  printf 'Try #2\n-------\nmirror: Login failed: 530 Login incorrect.\n' >> "$f"
  run classify_permanent_error "$f" "$offset"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "FND-0045: 'Fatal error: max-retries exceeded (530 ...)' (connection limit) is transient" {
  f=$(mktemp)
  printf 'mirror: Fatal error: max-retries exceeded (530 Sorry, the maximum number of clients (5) from your host are already connected.)\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "FND-0045: a 'Transferring file' line whose path says '530 login failed' is transient" {
  f=$(mktemp)
  printf "Transferring file \`530 login failed.txt'\n" > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "FND-0045: mirror statistics with 530 files or bytes are transient" {
  f=$(mktemp)
  printf 'Total: 3 directories, 530 files, 0 symlinks\nNew: 530 files, 0 symlinks\n530 bytes transferred\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "FND-0045: a Login failed line BEFORE OFFSET (earlier attempt) does not count" {
  f=$(mktemp)
  printf 'Try #1\n-------\nmirror: Login failed: 530 Login incorrect.\n' > "$f"
  offset=$(wc -c < "$f" | tr -d '[:space:]')
  printf 'Try #2\n-------\nmirror: Fatal error: max-retries exceeded (530 Sorry, the maximum number of clients (5) from your host are already connected.)\n' >> "$f"
  run classify_permanent_error "$f" "$offset"
  [ "$status" -eq 1 ]
  # Control: the same file without OFFSET still sees attempt 1.
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "FND-0045: lowercase 'mirror: login failed: 530 ...' is not permanent (case-sensitive)" {
  f=$(mktemp)
  printf 'mirror: login failed: 530 Login incorrect.\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "FND-0045: OFFSET equal to the file size leaves an empty tail (transient)" {
  f=$(mktemp)
  printf 'mirror: Login failed: 530 Login incorrect.\n' > "$f"
  offset=$(wc -c < "$f" | tr -d '[:space:]')
  run classify_permanent_error "$f" "$offset"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "FND-0045: OFFSET past the end of the file leaves an empty tail (transient)" {
  f=$(mktemp)
  printf 'mirror: Login failed: 530 Login incorrect.\n' > "$f"
  run classify_permanent_error "$f" 100000
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "FND-0045: without OFFSET the whole file is read" {
  f=$(mktemp)
  printf 'Try #1\nmirror: Access failed: 550 Failed to change directory. (/nope)\nTry #2\nconnect: Connection refused\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  run classify_permanent_error "$f" 0
  [ "$status" -eq 0 ]
  rm -f "$f"
}

# ----------------------------------------------------------------------------
# compute_backoff_seconds
# ----------------------------------------------------------------------------

@test "compute_backoff_seconds: counter=1 -> 1" {
  run compute_backoff_seconds 1
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "compute_backoff_seconds: counter=2 -> 1 (no jitter at delay=1)" {
  run compute_backoff_seconds 2
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "compute_backoff_seconds: counter=3 -> 2 (with ±1 jitter, 1..3)" {
  # Run several times to exercise the jitter. The output should
  # always be in [1, 3] (delay=2, jitter range [-1, +1], floor 1).
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 3
    [ "$status" -eq 0 ]
    n=$output
    [ "$n" -ge 1 ]
    [ "$n" -le 3 ]
  done
}

@test "compute_backoff_seconds: counter=4 -> in [2, 6] (delay=4, ±2 jitter)" {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 4
    n=$output
    [ "$n" -ge 2 ]
    [ "$n" -le 6 ]
  done
}

@test "compute_backoff_seconds: counter=5 -> in [4, 12] (delay=8, ±4 jitter)" {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 5
    n=$output
    [ "$n" -ge 4 ]
    [ "$n" -le 12 ]
  done
}

@test "compute_backoff_seconds: counter=6 -> in [8, 24] (delay=16, ±8 jitter)" {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 6
    n=$output
    [ "$n" -ge 8 ]
    [ "$n" -le 24 ]
  done
}

@test "compute_backoff_seconds: counter=10 (above cap) -> in [15, 45] (delay=30, ±15 jitter)" {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 10
    n=$output
    [ "$n" -ge 15 ]
    [ "$n" -le 45 ]
  done
}

@test "compute_backoff_seconds: result is always >= 1 (floor enforced)" {
  for counter in 1 2 3 4 5 6 10 20 100; do
    run compute_backoff_seconds "$counter"
    n=$output
    [ "$n" -ge 1 ]
  done
}

@test "compute_backoff_seconds: works when \$RANDOM is unset (v2.11.8 #179, POSIX sh)" {
  # Regression test for the busybox-ash-only $RANDOM dependency.
  # On a strict POSIX /bin/sh (e.g. dash on Debian), $RANDOM is
  # unset; the pre-fix jitter collapsed to zero and every retry
  # fired at the same instant. The new awk-based jitter has no
  # dependency on $RANDOM.
  #
  # Run lib.sh under `env -u RANDOM bash -c` to mimic a POSIX sh
  # that does not pre-set $RANDOM, then call compute_backoff_seconds
  # with counter=5 (delay=8, ±4 jitter) and assert the output is in
  # [4, 12]. The contract is unchanged for callers that do have
  # $RANDOM (existing tests above still pass), and the fix is
  # transparent to them.
  unset RANDOM
  run compute_backoff_seconds 5
  [ "$status" -eq 0 ]
  n=$output
  [ "$n" -ge 4 ]
  [ "$n" -le 12 ]
}

# ----------------------------------------------------------------------------
# FND-0049: the jitter seed is per process, not per second
# ----------------------------------------------------------------------------
# Helper. Runs compute_backoff_seconds in $1 separate bash processes
# (counter $2) and leaves the values, one per line, in $BATCH. Every
# process sees the same time of day: the condition under which the old
# bare `srand()` gave identical values. awk reads the clock only in a
# bare `srand()`, so a PATH-first `awk` wrapper rewrites `srand()` to
# `srand(FAKE_AWK_TIME)` (a fixed second) and then runs the real awk.
# FND-0107: this replaces a retry until `date +%s` was equal before and
# after the batch, which failed when 20 spawns did not fit in a second.
# The wrapper logs one line per rewritten call, `s=<the -v s value>`
# (`s=-` without one), in $FAKE_AWK_LOG. A bare `bash -c` is used
# because /bin/sh is dash on CI and pipefail is a bash feature.
# BACKOFF_LIB can point at another lib.sh (used to prove the tests fail
# on the pre-fix file).
_backoff_batch() {
  _bb_n=$1
  _bb_counter=$2
  _bb_lib="${BACKOFF_LIB:-${LIB}}"
  _bb_bin="${BATS_TEST_TMPDIR}/fixed-clock-awk"
  mkdir -p "${_bb_bin}"
  FAKE_REAL_AWK=$(command -v awk)
  FAKE_AWK_TIME=1782907200
  FAKE_AWK_LOG="${BATS_TEST_TMPDIR}/fixed-clock-awk.log"
  export FAKE_REAL_AWK FAKE_AWK_TIME FAKE_AWK_LOG
  : > "${FAKE_AWK_LOG}"
  cat > "${_bb_bin}/awk" << 'AWK'
#!/usr/bin/env bash
_fa_s='-'
_fa_hit=''
_fa_args=()
for _fa_a in "$@"; do
  case "${_fa_a}" in
    s=*) _fa_s=${_fa_a#s=} ;;
    *'srand()'*) _fa_hit=1 ;;
  esac
  _fa_args+=("${_fa_a//'srand()'/srand(${FAKE_AWK_TIME})}")
done
[ -n "${_fa_hit}" ] && printf 's=%s\n' "${_fa_s}" >> "${FAKE_AWK_LOG}"
exec "${FAKE_REAL_AWK}" "${_fa_args[@]}"
AWK
  chmod +x "${_bb_bin}/awk"
  BATCH=''
  _bb_i=0
  while [ "${_bb_i}" -lt "${_bb_n}" ]; do
    _bb_i=$((_bb_i + 1))
    _bb_v=$(PATH="${_bb_bin}:${PATH}" bash -c 'set -eu; set -o pipefail; . "$1"; compute_backoff_seconds "$2"' _ "${_bb_lib}" "${_bb_counter}")
    BATCH="${BATCH}${_bb_v}
"
  done
  # The fixed clock was in force in every process.
  [ "$(wc -l < "${FAKE_AWK_LOG}")" -eq "${_bb_n}" ]
}

# Asserts every line of $FAKE_AWK_LOG matches the ERE $1 (which seed
# path compute_backoff_seconds took).
_assert_seed_log() {
  _sl_bad=$(grep -Ev "$1" "${FAKE_AWK_LOG}" || true)
  [ -z "${_sl_bad}" ]
}

# Asserts every line of $BATCH is an integer in [$1, $2] and that
# more than one distinct value occurs.
_assert_spread_in_range() {
  _as_lo=$1
  _as_hi=$2
  _as_distinct=$(printf '%s' "${BATCH}" | sort -u | wc -l)
  [ "${_as_distinct}" -gt 1 ]
  for _as_v in ${BATCH}; do
    case "${_as_v}" in
      '' | *[!0-9]*) return 1 ;;
    esac
    [ "${_as_v}" -ge "${_as_lo}" ]
    [ "${_as_v}" -le "${_as_hi}" ]
  done
}

@test "FND-0049: separate processes in the same second get different jitter, within range" {
  # counter=6 -> delay=16, jitter in [-8, 8], sleep in [8, 24]
  # (17 values; 20 identical results by chance is about 17^-19).
  _backoff_batch 20 6
  _assert_spread_in_range 8 24
  # Every process took the /dev/urandom seed.
  _assert_seed_log '^s=[0-9]+$'
}

@test "FND-0049: with od failing, the call neither aborts nor collapses to one value" {
  # The fallback seed is time + $$, so PIDs still separate processes
  # in the same second. A failing od must not abort under
  # `set -eu` + pipefail.
  stub="${BATS_TEST_TMPDIR}/odfail"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/od"
  chmod +x "$stub/od"
  PATH="$stub:$PATH"
  export PATH
  run od -An -N4 -tu4 /dev/urandom
  [ "$status" -eq 1 ]
  _backoff_batch 20 6
  _assert_spread_in_range 8 24
  # Every process took the fallback seed (empty -v s).
  _assert_seed_log '^s=$'
}

@test "FND-0049: with od printing non-numeric text, the fallback seed is used" {
  stub="${BATS_TEST_TMPDIR}/odjunk"
  mkdir -p "$stub"
  printf '#!/bin/sh\necho "od: garbage"\nexit 0\n' > "$stub/od"
  chmod +x "$stub/od"
  PATH="$stub:$PATH"
  export PATH
  _backoff_batch 20 6
  _assert_spread_in_range 8 24
  # Every process took the fallback seed (empty -v s).
  _assert_seed_log '^s=$'
}

# ----------------------------------------------------------------------------
# run_lftp_once: FND-0097 / FND-0002 runs the timeout|tee pipeline in the
# background and waits for it, so a signal trap runs at once. The return value,
# the tee -a log and pipefail must stay as for the foreground pipeline. Each
# case runs in a bash child (pipefail, `wait` and the traps stay out of the
# bats shell) with a fake lftp (explicit bash shebang: /bin/sh is dash on CI)
# behind the real `timeout`.
# ----------------------------------------------------------------------------

# _rlo_run LFTP_BODY: runs run_lftp_once with a fake lftp whose body is
# LFTP_BODY; the log starts with one line, so tee -a must keep it.
_rlo_run() {
  local fb="${BATS_TEST_TMPDIR}/fbrlo"
  mkdir -p "${fb}"
  printf '#!/bin/bash\n%s\n' "$1" > "${fb}/lftp"
  chmod +x "${fb}/lftp"
  RLO_LOG="${BATS_TEST_TMPDIR}/rlo.log"
  printf 'earlier attempt\n' > "${RLO_LOG}"
  run timeout 60 bash -c '
    . "$1"
    PATH="$2:${PATH}"
    run_lftp_once "ftp://h" "set a b;" "mirror -R" "./" "./" "$3" 30s 1s ""
    echo "rc=$? active=${RUN_LFTP_ACTIVE:-}"
  ' _ "${LIB}" "${fb}" "${RLO_LOG}"
}

@test "run_lftp_once: FND-0097: returns lftp's exit status and tees the output to the step log and (appended) to the log file" {
  _rlo_run 'echo "out line"; echo "err line" >&2; exit 7'
  echo "${output}"; cat "${RLO_LOG}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"out line"* ]]
  [[ "${output}" == *"err line"* ]]
  [ "${lines[${#lines[@]}-1]}" = "rc=7 active=" ]
  [ "$(sed -n 1p "${RLO_LOG}")" = "earlier attempt" ]
  grep -qx 'out line' "${RLO_LOG}"
  grep -qx 'err line' "${RLO_LOG}"
}

@test "run_lftp_once: FND-0097: success returns 0" {
  _rlo_run 'echo ok-line; exit 0'
  echo "${output}"
  [ "${lines[${#lines[@]}-1]}" = "rc=0 active=" ]
}

@test "run_lftp_once: FND-0097: lftp killed by SIGTERM (as on the 5 h timeout) returns 143, by SIGKILL 137" {
  _rlo_run 'echo before; kill -TERM $$; sleep 5'
  echo "${output}"
  [ "${lines[${#lines[@]}-1]}" = "rc=143 active=" ]
  grep -qx 'before' "${RLO_LOG}"
  _rlo_run 'kill -KILL $$'
  echo "${output}"
  [ "${lines[${#lines[@]}-1]}" = "rc=137 active=" ]
}

@test "run_lftp_once: FND-0097: the pipeline runs in the background (a trapped TERM interrupts the wait at once and the trap sees RUN_LFTP_ACTIVE)" {
  local fb="${BATS_TEST_TMPDIR}/fbrlo"
  mkdir -p "${fb}"
  printf '#!/bin/bash\nsleep 20\n' > "${fb}/lftp"
  chmod +x "${fb}/lftp"
  local t0=${SECONDS}
  run timeout 60 bash -c '
    . "$1"
    PATH="$2:${PATH}"
    trap '"'"'echo "trap active=${RUN_LFTP_ACTIVE:-}"; kill -TERM %% 2>/dev/null; wait; exit 143'"'"' TERM
    ( sleep 1; kill -TERM $$ ) &
    run_lftp_once "ftp://h" "" "mirror -R" "./" "./" "$3" 30s 1s ""
    echo "not reached"
  ' _ "${LIB}" "${fb}" "${BATS_TEST_TMPDIR}/rlo.log"
  echo "${output}"
  [ "${status}" -eq 143 ]
  [ "${output}" = "trap active=1" ]
  # The TERM comes after 1 s; a foreground pipeline would hold the trap back
  # for the whole `sleep 20`.
  [ $((SECONDS - t0)) -lt 10 ]
}

# ----------------------------------------------------------------------------
# FND-0093: entrypoint.sh must pass "${LOG_OFFSET}" to classify_permanent_error
# (FND-0045), so only the current attempt's output is classified. A scratch
# copy of entrypoint.sh (paths rewritten into BATS_TEST_TMPDIR) runs with a
# lib.sh copy whose run_lftp_once is a stub appending to LOG_FILE ($6) and
# whose compute_backoff_seconds is 0. A fake date pins the log name, so the
# log can be pre-seeded with an earlier "mirror: Login failed: 530 ..." line
# (permanent if the whole log is read). Attempt 1 appends a transient
# "max-retries exceeded (530 ...)" line and fails; attempt 2 succeeds. With
# the offset the run retries and exits 0; without it attempt 1 is classified
# permanent from the old line. ENTRYPOINT_SRC overrides the entrypoint under
# test (used to prove the tests fail on a mutant without the offset).
# ----------------------------------------------------------------------------

_run_entrypoint_offset() {
  local root="${BATS_TEST_DIRNAME}/../.."
  local src="${ENTRYPOINT_SRC:-${root}/entrypoint.sh}"
  local app="${BATS_TEST_TMPDIR}/app"
  local h="${BATS_TEST_TMPDIR}/home/lftp"
  mkdir -p "${app}" "${h}/.lftp-logs" "${BATS_TEST_TMPDIR}/site" "${BATS_TEST_TMPDIR}/bin"
  cp "${LIB}" "${app}/lib.sh"
  printf '0.0.0-test\n' > "${app}/VERSION"
  cat >> "${app}/lib.sh" <<'STUB'

run_lftp_once() {
  _n=$(cat "${MIRROR_COUNT_FILE}" 2>/dev/null || echo 0)
  _n=$((_n + 1))
  printf '%s\n' "${_n}" > "${MIRROR_COUNT_FILE}"
  if [ "${_n}" -ge 2 ]; then
    printf 'Transferring file\n' >> "$6"
    return 0
  fi
  printf 'mirror: Fatal error: max-retries exceeded (530 Too many connections)\n' >> "$6"
  return 1
}
compute_backoff_seconds() { echo 0; }
STUB
  sed -e "s#/app/#${app}/#g" -e "s#/home/lftp#${h}#g" "${src}" > "${app}/entrypoint.sh"

  export MIRROR_COUNT_FILE="${BATS_TEST_TMPDIR}/mirror.count"
  rm -f "${MIRROR_COUNT_FILE}"
  printf '#!/bin/sh\nprintf "20260601T120000Z\\n"\n' > "${BATS_TEST_TMPDIR}/bin/date"
  chmod +x "${BATS_TEST_TMPDIR}/bin/date"
  # Earlier output in the shared log: permanent only if it is classified.
  printf 'mirror: Login failed: 530 Login incorrect.\n' > "${h}/.lftp-logs/run-20260601T120000Z.log"

  # bash, not sh: the scratch entrypoint is run like the other harnesses.
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" HOME="${BATS_TEST_TMPDIR}/home" \
  INPUT_SERVER="ftp://example.test" INPUT_USER="ftptest" INPUT_PASSWORD="pw" \
  INPUT_LOCAL_DIR="${BATS_TEST_TMPDIR}/site/" INPUT_REMOTE_DIR="./" \
  INPUT_CONCURRENCY_LOCK="false" INPUT_MAX_RETRIES="3" \
    run bash -eu "${app}/entrypoint.sh"
}

@test "entrypoint: FND-0093: an earlier permanent line in the shared log does not stop the retry of a transient failure (offset passed)" {
  _run_entrypoint_offset
  echo "status=${status}"; echo "${output}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${MIRROR_COUNT_FILE}")" = "2" ]
  printf '%s\n' "${output}" | grep -F 'Try #2' > /dev/null
  ! printf '%s\n' "${output}" | grep -F 'Detected permanent error' > /dev/null
}

@test "entrypoint: FND-0093: the classify_permanent_error call passes LOG_OFFSET (static guard)" {
  grep -F 'classify_permanent_error "${LOG_FILE}" "${LOG_OFFSET}"' "${ENTRYPOINT_SRC:-${BATS_TEST_DIRNAME}/../../entrypoint.sh}" > /dev/null
}
