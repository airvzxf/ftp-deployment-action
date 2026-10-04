#!/bin/sh
# tests/acceptance/static.sh — frozen acceptance checks (no containers).
#
# Each check prints "PASS <id> <summary>" or "FAIL <id> <summary>" plus
# the evidence. The script exits 1 if any check fails. It never skips:
# a missing tool is a FAIL, not a pass.
#
# Usage: sh tests/acceptance/static.sh            (from the repo root)
#        PYTHON=/path/to/python sh tests/acceptance/static.sh
set -u

# shellcheck disable=SC1007
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "${ROOT}" || exit 1

_failed=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; _failed=1; }

# ---------------------------------------------------------------------------
# Helper: print "<input_name>=<default>" for every input in action.yml
# that declares a default. Values are single-quoted in action.yml; ''
# inside a single-quoted YAML scalar is a literal '.
# ---------------------------------------------------------------------------
action_defaults() {
  awk '
    /^inputs:/                { in_inputs = 1; next }
    /^[^ ]/                   { in_inputs = 0 }
    in_inputs && /^  [a-z_]+:[ ]*$/ { name = $1; sub(":", "", name); next }
    in_inputs && /^    default:/ {
      v = $0
      sub(/^    default:[ ]*/, "", v)
      if (v ~ /^\x27.*\x27$/) { v = substr(v, 2, length(v) - 2); gsub(/\x27\x27/, "\x27", v) }
      print name "=" v
    }
  ' action.yml
}

# S1 — action.yml must be valid YAML (v2.11.14 shipped an unparseable one).
PY=${PYTHON:-python3}
if "${PY}" -c 'import yaml' >/dev/null 2>&1; then
  if _err=$("${PY}" -c 'import sys,yaml; yaml.safe_load(open("action.yml"))' 2>&1); then
    pass "S1 action.yml parses as YAML"
  else
    fail "S1 action.yml is not valid YAML: ${_err}"
  fi
else
  fail "S1 no YAML parser: install PyYAML (see 01-preflight.md) or set PYTHON=<python with yaml>"
fi

# S2 — for every input that declares a default in action.yml,
#      entrypoint.sh has a ': "${INPUT_X:=<same value>}"' fallback.
#      GitHub always injects the action.yml default; local runs, smoke
#      and integration tests do not. Any difference means tests and real
#      users run different configurations (this is how #334 hid).
_defaults=$(action_defaults)
_s2_bad=""
for _kv in ${_defaults}; do
  _name=${_kv%%=*}
  _ay=${_kv#*=}
  _var=$(printf '%s' "${_name}" | tr "[:lower:]" "[:upper:]")
  _line=$(grep -E "^: \"\\\$\{INPUT_${_var}:=" entrypoint.sh | head -1)
  if [ -z "${_line}" ]; then
    _s2_bad="${_s2_bad} ${_name}(no fallback in entrypoint.sh)"
    continue
  fi
  # shellcheck disable=SC2016
  _fb=$(printf '%s' "${_line}" | sed -n 's/^: "\${INPUT_[A-Z_]*:=\([^}]*\)}".*/\1/p')
  if [ "${_fb}" != "${_ay}" ]; then
    _s2_bad="${_s2_bad} ${_name}(entrypoint='${_fb}',action.yml='${_ay}')"
  fi
done
if [ -z "${_s2_bad}" ]; then
  pass "S2 entrypoint.sh fallbacks match action.yml defaults"
else
  fail "S2 entrypoint.sh fallbacks differ from action.yml:${_s2_bad}"
fi

# S3 — business rule: net_max_retries defaults to 1 (0 hangs lftp on
#      'mirror -R local/ /', see issue #334).
_nmr=$(printf '%s\n' "${_defaults}" | sed -n 's/^net_max_retries=//p')
if [ "${_nmr}" = "1" ]; then
  pass "S3a action.yml net_max_retries default is 1"
else
  fail "S3a action.yml net_max_retries default is '${_nmr}', expected '1'"
fi
# S3b — business rule: net_persist_retries defaults to 0 (lftp's own
#       default). Any other value makes lftp retry a '530 Login
#       incorrect' and replace it with 'max-retries exceeded', so the
#       user never sees why the login failed (issue #330). The action's
#       own max_retries loop still retries transient errors.
_npr=$(printf '%s\n' "${_defaults}" | sed -n 's/^net_persist_retries=//p')
if [ "${_npr}" = "0" ]; then
  pass "S3b action.yml net_persist_retries default is 0"
else
  fail "S3b action.yml net_persist_retries default is '${_npr}', expected '0'"
fi

# S4 — removed surface: upload_log_on_failure, exclude_delete and the
#      log_file output must be gone from the action contract, the code
#      and the user-facing docs (CHANGELOG.md may mention them).
_s4=$(grep -nE 'upload_log_on_failure|UPLOAD_LOG_ON_FAILURE|exclude_delete|EXCLUDE_DELETE|upload_log_artifact|log_file' \
        action.yml entrypoint.sh lib.sh README.md 2>/dev/null)
if [ -z "${_s4}" ]; then
  pass "S4 upload_log_on_failure / exclude_delete / log_file removed"
else
  fail "S4 removed features still referenced:"
  printf '%s\n' "${_s4}" | sed 's/^/     /' | head -40
fi

# S5 — Dockerfiles: no apk revision pins (pkg=X.Y.Z-rN breaks every
#      published tag when Alpine rotates the package), and the action
#      image does not install curl.
_s5=$(grep -nE '[a-z0-9.+_-]+=[0-9][^ ]*-r[0-9]+' \
        Dockerfile tests/Dockerfile.smoke tests/integration/Dockerfile.test-server 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
if [ -z "${_s5}" ]; then
  pass "S5a no apk '-rN' revision pins in Dockerfiles"
else
  fail "S5a apk revision pins found:"
  printf '%s\n' "${_s5}" | sed 's/^/     /'
fi
if grep -vE '^[[:space:]]*#' Dockerfile | grep -qw curl; then
  fail "S5b Dockerfile still installs curl"
else
  pass "S5b Dockerfile does not install curl"
fi

# S6 — dead code removed: no-op lock shims and the one-shot backfill
#      script.
_s6=$(grep -rnE 'build_lock_acquire_script|build_lock_release_script|run_lftp_lock_release' \
        --include='*.sh' --include='*.bats' --include='*.yml' --include='Makefile' . 2>/dev/null \
        | grep -v '^./tests/acceptance/')
if [ -z "${_s6}" ] && [ ! -e scripts/backfill-releases.sh ]; then
  pass "S6 dead lock shims and scripts/backfill-releases.sh removed"
else
  fail "S6 dead code still present:"
  [ -e scripts/backfill-releases.sh ] && printf '     scripts/backfill-releases.sh exists\n'
  printf '%s\n' "${_s6}" | sed 's/^/     /' | head -20
fi

# S7 — action.yml is the Marketplace contract: descriptions must not
#      carry internal version history like "v2.11.14 (#330): ...".
_s7=$(grep -nE 'v[0-9]+\.[0-9]+(\.[0-9]+)?[^a-z]{0,3}\(#[0-9]+\)|\(#[0-9]+\)' action.yml)
if [ -z "${_s7}" ]; then
  pass "S7 action.yml descriptions carry no version/issue history"
else
  fail "S7 action.yml descriptions reference versions/issues:"
  printf '%s\n' "${_s7}" | cut -c1-140 | sed 's/^/     /'
fi

# S8 — the e2e workflow exists and drives the action through action.yml.
if [ -f .github/workflows/e2e.yml ] && grep -qE '^[[:space:]]+uses:[[:space:]]+\./[[:space:]]*$' .github/workflows/e2e.yml; then
  pass "S8 .github/workflows/e2e.yml runs the action with 'uses: ./'"
else
  fail "S8 .github/workflows/e2e.yml missing or does not contain 'uses: ./'"
fi

# S9 — acceptance suite is wired into make and CI.
if grep -qE '^acceptance:' Makefile && grep -q 'tests/acceptance' .github/workflows/ci.yml; then
  pass "S9 acceptance suite wired into Makefile and ci.yml"
else
  fail "S9 'make acceptance' target or ci.yml wiring missing"
fi

# S10 — tests/contract.sh must define ok()/fail() before first use.
#       On main it calls them at line ~63 but defines them at ~77, so
#       a broken action.yml prints "fail: command not found" and the
#       script still exits 0 (the #334 YAML guard never fired).
_def=$(grep -nE '^fail\(\)' tests/contract.sh | head -1 | cut -d: -f1)
_use=$(grep -nE '^[[:space:]]+(fail|ok) ' tests/contract.sh | head -1 | cut -d: -f1)
if [ -n "${_def}" ] && [ -n "${_use}" ] && [ "${_def}" -lt "${_use}" ]; then
  pass "S10 tests/contract.sh defines fail()/ok() before first use"
else
  fail "S10 tests/contract.sh uses fail/ok (line ${_use:-?}) before defining them (line ${_def:-?})"
fi

if [ "${_failed}" -ne 0 ]; then
  printf '\nRESULT: FAIL\n'
  exit 1
fi
printf '\nRESULT: PASS\n'
