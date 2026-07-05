#!/bin/sh
# tests/contract.sh — verify that the user-facing contract between
# action.yml and init.sh is consistent. Would have caught B-01
# (mirror_verbose declared in init.sh/README but not in action.yml).
#
# Strategy:
#   1. Parse action.yml and collect the list of input names declared
#      under `inputs:`.
#   2. Grep init.sh for every literal `INPUT_<NAME>` reference and
#      collect the set of names referenced statically.
#   3. Grep init.sh for the "for _v in <NAME1> <NAME2> ...; do" dump
#      loop and collect the names referenced dynamically.
#   4. Assert: all three sets are equal.
#
# Exit 0 on success, non-zero on any mismatch.

set -u

# CDPATH= cd -- ... is the POSIX idiom to resolve the script's own directory
# without being affected by the caller's CDPATH. shellcheck gets confused
# by the `=` spacing, hence the disable.
# shellcheck disable=SC1007
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ACTION="${ROOT}/action.yml"
INIT="${ROOT}/init.sh"

[ -f "${ACTION}" ] || { echo "missing ${ACTION}" >&2; exit 1; }
[ -f "${INIT}" ]   || { echo "missing ${INIT}" >&2;   exit 1; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ok: %s\n' "$*"; }

# 1. Inputs declared in action.yml (top-level keys under "inputs:").
declared=$(awk '
  /^inputs:/ { in_inputs = 1; next }
  in_inputs && /^runs:/ { in_inputs = 0; next }
  in_inputs && /^  [a-z][a-z0-9_]*:$/ {
    sub(/:$/, "")
    sub(/^  /, "")
    print
  }
' "${ACTION}" | sort -u)
[ -n "${declared}" ] || fail "no inputs found in action.yml under 'inputs:'"

# 2. INPUT_<X> static references in init.sh.
static=$(grep -oE 'INPUT_[A-Z][A-Z0-9_]*' "${INIT}" \
  | sed 's/^INPUT_//' \
  | tr '[:upper:]' '[:lower:]' \
  | sort -u)
[ -n "${static}" ] || fail "no INPUT_<X> references found in init.sh"

# 3. Dump loop's name list in init.sh (collects across line continuations).
#    Strip backslashes (line-continuation markers) before splitting.
dynamic=$(awk '
  /for _v in/ { capture = 1; buf = "" }
  capture {
    buf = buf " " $0
    if (/; do/) {
      sub(/^.*for _v in /, "", buf)
      sub(/; do.*$/, "", buf)
      print tolower(buf)
      capture = 0
    }
  }
' "${INIT}" | sed 's/\\//g' | tr -s '[:space:]' '\n' | sed '/^$/d' | sort -u)
[ -n "${dynamic}" ] || fail "could not extract dump loop name list from init.sh"

# 4. Compare the three sets. Use temp files so we don't depend on
# process substitution (which shellcheck flags SC3001 in strict POSIX).
_diff_files() {
  _a=$1; _b=$2
  _f1=$(mktemp) || return 1
  _f2=$(mktemp) || return 1
  printf '%s\n' "${_a}" > "${_f1}"
  printf '%s\n' "${_b}" > "${_f2}"
  diff "${_f1}" "${_f2}" | sed 's/^/  /'
  _rc=$?
  rm -f "${_f1}" "${_f2}"
  return "${_rc}"
}

if [ "${declared}" != "${static}" ]; then
  printf 'declared inputs (action.yml) vs static INPUT_* refs (init.sh) differ:\n' >&2
  _diff_files "${declared}" "${static}" >&2 || true
  fail "static INPUT_* references do not match declared inputs"
fi
ok "static INPUT_* references match declared inputs"

if [ "${declared}" != "${dynamic}" ]; then
  printf 'declared inputs (action.yml) vs dump loop list (init.sh) differ:\n' >&2
  _diff_files "${declared}" "${dynamic}" >&2 || true
  fail "dump loop's name list does not match declared inputs"
fi
ok "dump loop's name list matches declared inputs"

n=$(echo "${declared}" | wc -l | tr -d ' ')
printf '  info: %s input(s): %s\n' "${n}" "$(echo "${declared}" | tr '\n' ' ')"

exit 0
