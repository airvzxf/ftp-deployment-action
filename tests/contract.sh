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

# 5. Docs version stamp matches VERSION. The re-drift of #234 (the
# original SEC.md stamp drift fix) and the F2 audit's #299 made the
# same point: VERSION, CHANGELOG.md, and SECURITY.md drift every
# release unless something mechanically pins them together. This
# check enforces that contract at CI time. The release branch
# (release.yml) bumps VERSION and stamps CHANGELOG.md; a missed
# SECURITY.md stamp update would otherwise reach the release page.
#
# The check operates on the EXPLICIT version stamps in each file
# (SECURITY.md's `latest = vX.Y.Z`, CHANGELOG.md's `## [X.Y.Z]`
# heading) rather than a `grep -q v${VER}` substring match, because
# feature-history notes like `since v2.0.0` and `Fixed in v2.11.0`
# would make a substring match trivially true and hide the drift.

VER=$(cat "${ROOT}/VERSION") || fail "cannot read ${ROOT}/VERSION"

# SECURITY.md carries the explicit stamp:
#   `| Currently maintained | `v2.x` (latest = `vX.Y.Z`) | ...`
# v2.11.12 (F2 audit): the previous shape hardcoded line 7 via
# `sed -n '7p'`. A future maintainer who adds another row to the
# supported-versions table (e.g. a "Preview" track) before the
# "Currently maintained" row silently shifts line 7 to the new
# row. Replace the line-anchor with a whole-file regex scan that
# matches the documented stamp anywhere in SECURITY.md.
# shellcheck disable=SC2016
_sec_stamp=$(grep -oE 'latest = `v[0-9]+\.[0-9]+\.[0-9]+`' "${ROOT}/SECURITY.md" \
  | head -n 1 \
  | sed -n 's/.*`v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)`.*/\1/p')
if [ "${_sec_stamp:-}" != "${VER}" ]; then
  fail "SECURITY.md 'latest = vX.Y.Z' stamp is '${_sec_stamp:-<missing>}' but VERSION is '${VER}'"
fi
ok "SECURITY.md 'latest = vX.Y.Z' matches VERSION (${VER})"

# CHANGELOG.md top heading: `## [X.Y.Z] - YYYY-MM-DD`. The Keep a
# Changelog preamble sits between line 1 and the first version
# heading, so the awk exits at the first match. v2.11.12 (F2
# audit): the previous shape bounded the sed read to `1,30p` to
# be "resilient to preamble edits". A maintainer who expands the
# preamble (extra intro / audit backlog / links) past line 30
# silently breaks the read. Drop the bound and rely on the awk
# `exit` after the first match; the awk never reads past the first
# heading, so preamble length is irrelevant.
_chg_stamp=$(awk '/^## \[[0-9]+\.[0-9]+\.[0-9]+\][ ]/ { sub(/^## \[/, ""); sub(/\][ ].*$/, ""); print; exit }' \
  "${ROOT}/CHANGELOG.md")
if [ -z "${_chg_stamp:-}" ]; then
  fail "CHANGELOG.md has no '## [X.Y.Z]' heading"
fi
if [ "${_chg_stamp}" != "${VER}" ]; then
  fail "CHANGELOG.md top '## [X.Y.Z]' heading is '${_chg_stamp}' but VERSION is '${VER}'"
fi
ok "CHANGELOG.md top '## [X.Y.Z]' matches VERSION (${VER})"

# README.md: most version references in README are feature-history
# notes ('since v2.0.0', 'Fixed in v2.11.0', `v2.10.0+` publishing
# examples), not stamps. Defensive check: if a `latest = vX.Y.Z`
# stamp is added later, verify it matches VERSION; otherwise emit an
# info note so a future audit knows the check ran and found no
# stamp to verify.
if grep -qE 'latest = v[0-9]+\.[0-9]+\.[0-9]+' "${ROOT}/README.md"; then
  _readme_stamp=$(grep -oE 'latest = v[0-9]+\.[0-9]+\.[0-9]+' "${ROOT}/README.md" \
    | head -n 1 | sed 's/.*v//')
  if [ "${_readme_stamp}" != "${VER}" ]; then
    fail "README.md 'latest = vX.Y.Z' stamp is 'v${_readme_stamp}' but VERSION is '${VER}'"
  fi
  ok "README.md 'latest = vX.Y.Z' matches VERSION (${VER})"
else
  ok "README.md has no 'latest = vX.Y.Z' stamp (no drift to check)"
fi

exit 0
