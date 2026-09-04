#!/bin/sh
# tests/contract.sh — verify that the user-facing contract between
# action.yml and the implementation (entrypoint.sh + lib.sh) is
# consistent. Would have caught B-01 (mirror_verbose declared in
# init.sh/README but not in action.yml).
#
# Strategy:
#   1. Parse action.yml and collect the list of input names declared
#      under `inputs:`.
#   2. Grep entrypoint.sh and lib.sh for every literal `INPUT_<NAME>`
#      reference and collect the set of names referenced statically.
#   3. Grep lib.sh for the "for _pid_name in <NAME1> <NAME2> ..."
#      dump loop in `print_inputs_dump` and collect the names
#      referenced dynamically.
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
ENTRY="${ROOT}/entrypoint.sh"
LIB="${ROOT}/lib.sh"

[ -f "${ACTION}" ] || { echo "missing ${ACTION}" >&2; exit 1; }
[ -f "${ENTRY}" ]  || { echo "missing ${ENTRY}" >&2;  exit 1; }
[ -f "${LIB}" ]    || { echo "missing ${LIB}" >&2;    exit 1; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ok: %s\n' "$*"; }

# 1. Inputs declared in action.yml (top-level keys under "inputs:").
# v2.11.3 (#197): stop scanning when we hit either `runs:` or
# `outputs:` (both are top-level siblings of `inputs:`; for Docker
# actions, `outputs:` sits next to `runs:`, not inside it, so the
# earlier parser picked up output keys like `log_file` as inputs).
declared=$(awk '
  /^inputs:/ { in_inputs = 1; next }
  in_inputs && (/^runs:/ || /^outputs:/) { in_inputs = 0; next }
  in_inputs && /^  [a-z][a-z0-9_]*:$/ {
    sub(/:$/, "")
    sub(/^  /, "")
    print
  }
' "${ACTION}" | sort -u)
[ -n "${declared}" ] || fail "no inputs found in action.yml under 'inputs:'"

# 2. INPUT_<X> static references in entrypoint.sh and lib.sh. Both
# files may legitimately reference any given input (the orchestrator
# does the defaulting, the helpers do the reading), so the union is
# the meaningful set. The `-h` flag suppresses the filename prefix
# that `grep` adds when given multiple input files.
static=$(grep -hoE 'INPUT_[A-Z][A-Z0-9_]*' "${ENTRY}" "${LIB}" \
  | sed 's/^INPUT_//' \
  | tr '[:upper:]' '[:lower:]' \
  | sort -u)
[ -n "${static}" ] || fail "no INPUT_<X> references found in entrypoint.sh or lib.sh"

# 3. Dump loop's name list in lib.sh's `print_inputs_dump`
# (collects across line continuations). The variable in the loop
# was renamed from `_v` to `_pid_name` in v2.5.0 when the function
# moved to lib.sh.
dynamic=$(awk '
  /for _pid_name in/ { capture = 1; buf = "" }
  capture {
    buf = buf " " $0
    if (/; do/) {
      sub(/^.*for _pid_name in /, "", buf)
      sub(/; do.*$/, "", buf)
      print tolower(buf)
      capture = 0
    }
  }
' "${LIB}" | sed 's/\\//g' | tr -s '[:space:]' '\n' | sed '/^$/d' | sort -u)
[ -n "${dynamic}" ] || fail "could not extract dump loop name list from lib.sh's print_inputs_dump"

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
  printf 'declared inputs (action.yml) vs static INPUT_* refs (entrypoint.sh + lib.sh) differ:\n' >&2
  _diff_files "${declared}" "${static}" >&2 || true
  fail "static INPUT_* references do not match declared inputs"
fi
ok "static INPUT_* references match declared inputs"

if [ "${declared}" != "${dynamic}" ]; then
  printf 'declared inputs (action.yml) vs dump loop list (lib.sh print_inputs_dump) differ:\n' >&2
  _diff_files "${declared}" "${dynamic}" >&2 || true
  fail "dump loop's name list does not match declared inputs"
fi
ok "dump loop's name list matches declared inputs"

n=$(echo "${declared}" | wc -l | tr -d ' ')
printf '  info: %s input(s): %s\n' "${n}" "$(echo "${declared}" | tr '\n' ' ')"

exit 0
