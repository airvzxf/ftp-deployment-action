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

# S11 — ROADMAP.md was removed (#238): no file outside CHANGELOG.md
#       may still link to it.
_s11=$(grep -rn 'ROADMAP' --exclude-dir=.git --exclude=CHANGELOG.md . 2>/dev/null \
        | grep -v '^./tests/acceptance/static.sh:')
if [ -z "${_s11}" ]; then
  pass "S11 no reference to the removed ROADMAP.md"
else
  fail "S11 ROADMAP.md is gone but still referenced:"
  printf '%s\n' "${_s11}" | cut -c1-140 | sed 's/^/     /'
fi

# S12 — AGENTS.md states what the Dockerfile installs: the same lftp
#       pin, no curl in the "Stack" row or section (S5b), and any
#       quoted base digest is a prefix of the one on Dockerfile line 1.
_lftp_pin=$(grep -oE 'lftp~[0-9.]+' Dockerfile | head -n 1)
_digest=$(sed -n '1s/^FROM alpine@sha256:\([0-9a-f]*\).*/\1/p' Dockerfile)
_stack=$(awk '/^\| Stack \|/ { print } /^## / { s = ($0 == "## Stack") } s' AGENTS.md)
_s12=""
if [ -z "${_lftp_pin}" ] || ! grep -qF "${_lftp_pin}" AGENTS.md; then
  _s12="${_s12} lftp(Dockerfile pins '${_lftp_pin:-?}', AGENTS.md does not say it)"
fi
if printf '%s\n' "${_stack}" | grep -qiw curl; then
  _s12="${_s12} curl(AGENTS.md Stack lists curl)"
fi
while read -r _d; do
  case "${_digest}" in
    "${_d}"*) ;;
    *) _s12="${_s12} digest(AGENTS.md ${_d} is not Dockerfile ${_digest:-?})" ;;
  esac
done <<EOF
$(grep -oE 'alpine@sha256:[0-9a-f]+' AGENTS.md | sed 's/.*://')
EOF
if [ -z "${_s12}" ]; then
  pass "S12 AGENTS.md stack matches the Dockerfile"
else
  fail "S12 AGENTS.md stack differs from the Dockerfile:${_s12}"
fi

# S13 — the test images are built on the same Alpine digest as the
#       action image, so the tests run the OpenSSL / busybox users get.
#       Dependabot bumps all three in one grouped PR
#       (.github/dependabot.yml, group dockerfile-base).
_s13=""
for _f in tests/integration/Dockerfile.test-server tests/Dockerfile.smoke; do
  _d13=$(sed -n 's/^FROM alpine@sha256:\([0-9a-f]*\).*/\1/p' "${_f}")
  [ -n "${_digest}" ] && [ "${_d13}" = "${_digest}" ] \
    || _s13="${_s13} ${_f}(${_d13:-?})"
done
if [ -z "${_s13}" ]; then
  pass "S13 test Dockerfiles use the Dockerfile:1 Alpine digest"
else
  fail "S13 not on the Dockerfile:1 digest ${_digest:-?}:${_s13}"
fi

# S14 — no workflow uses the GitHub Actions cache. A cache entry is
#       scoped to the ref that wrote it, and a tag or branch run reads
#       only its own ref and the default branch. The release build
#       wrote one entry set per tag and no later run could read it, so
#       every release missed the cache and left ~6 MB of entries
#       behind. The build installs two apk packages in about a second;
#       there is nothing to cache. See AGENTS.md design decision 6.
_s14=$(grep -nE 'type=gha|cache-(from|to):|actions/cache[@/]' \
    .github/workflows/*.yml | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#')
if [ -z "${_s14}" ]; then
  pass "S14 no workflow reads or writes the GitHub Actions cache"
else
  fail "S14 workflows use the GitHub Actions cache:"
  printf '%s\n' "${_s14}" | sed 's/^/  /'
fi

# S15 — release.yml validate-tag-input (FND-0025, FND-0026). The
#       workflow_dispatch `version` input is attacker-controlled text.
#       (a) the validator's run block holds no `${{ }}` expression
#           (a template expression in a shell comment is rendered
#           before bash runs, so a newline in the input injects script
#           lines ahead of the regex check);
#       (b) the raw `github.event.inputs.version` is read only by the
#           workflow concurrency group and the validator's RAW env;
#           every other consumer uses the validated job output;
#       (c) the validator rejects a multi-line value (grep anchors per
#           line, so 'v9.9.9<LF>x' used to pass) and still accepts a
#           plain tag.
#       RELEASE_YML overrides the file under test (used to prove the
#       check fails on the pre-fix workflow).
_rel=${RELEASE_YML:-.github/workflows/release.yml}
_s15=""
_tmp15=$(mktemp -d) || _tmp15=""
if [ -z "${_tmp15}" ] || [ ! -r "${_rel}" ] || ! command -v bash >/dev/null 2>&1; then
  _s15="${_s15} setup(need mktemp, bash and a readable ${_rel})"
else
  awk '
    /^      - name: Validate tag shape/ { step = 1; next }
    step && /^        run: \|/            { cap = 1; next }
    cap && /^          /                 { sub(/^          /, ""); print; next }
    cap && /^[[:space:]]*$/              { print ""; next }
    cap                                  { exit }
  ' "${_rel}" > "${_tmp15}/validator.sh"
  if [ ! -s "${_tmp15}/validator.sh" ]; then
    _s15="${_s15} (a)(validate-tag-input run block not found)"
  else
    # shellcheck disable=SC2016
    if grep -qF '${{' "${_tmp15}/validator.sh"; then
      _s15="${_s15} (a)(validator run block contains a template expression)"
    fi
    # (c) run the extracted block the way Actions does (bash).
    : > "${_tmp15}/out"
    _ml=$(printf 'v9.9.9\nx')
    if RAW="${_ml}" GITHUB_OUTPUT="${_tmp15}/out" bash "${_tmp15}/validator.sh" >/dev/null 2>&1 \
        || [ -s "${_tmp15}/out" ]; then
      _s15="${_s15} (c)(two-line value was accepted)"
    fi
    : > "${_tmp15}/out"
    if ! RAW="v1.2.3-rc.1" GITHUB_OUTPUT="${_tmp15}/out" bash "${_tmp15}/validator.sh" >/dev/null 2>&1 \
        || [ "$(cat "${_tmp15}/out")" != "TAG=v1.2.3-rc.1" ]; then
      _s15="${_s15} (c)(valid tag v1.2.3-rc.1 was not accepted)"
    fi
  fi
  rm -rf "${_tmp15}"
  # (b)
  _raw15=$(grep -n 'github\.event\.inputs\.version' "${_rel}" \
      | grep -vE '^[0-9]+:[[:space:]]*#' \
      | grep -vE '^[0-9]+:[[:space:]]*group: release-\$\{\{ github\.event\.inputs\.version \|\| github\.ref_name \}\}[[:space:]]*$' \
      | grep -vE '^[0-9]+:[[:space:]]*RAW: \$\{\{ github\.event\.inputs\.version \|\| github\.ref_name \}\}[[:space:]]*$')
  if [ -n "${_raw15}" ]; then
    _s15="${_s15} (b)(raw input still read:$(printf '%s' "${_raw15}" | tr '\n' ' '))"
  fi
fi
if [ -z "${_s15}" ]; then
  pass "S15 release.yml validator is injection-safe and consumers use its output"
else
  fail "S15 release.yml tag-input handling:${_s15}"
fi

# S16 — release.yml binds the signed tag to the built commit (FND-0027).
#       verify-tag-reachability and verify-tag-signature fetch the mutable
#       tag separately, so the commit build checks out (tag_commit) could
#       differ from the commit of the tag object whose signature was
#       verified. The first step of `build` ("bind-commit") must fail
#       unless both values are 40 lowercase hex characters and equal.
#       (a) the bind-commit run block is extracted and run under bash
#           with equal SHAs (exit 0) and with every bad pair (non-zero);
#       (b) the wiring: bind-commit is steps[0] of build, takes its two
#           values from the two verify jobs' outputs, build needs both
#           jobs, verify-tag-signature exports verified_commit from the
#           step that runs `git verify-tag` and `git rev-parse` on the
#           same ref, and the run block holds no `${{ }}` expression.
#       RELEASE_YML overrides the file under test (used to prove the
#       check fails on the pre-fix workflow).
_s16=""
_tmp16=$(mktemp -d) || _tmp16=""
if [ -z "${_tmp16}" ] || [ ! -r "${_rel}" ] || ! command -v bash >/dev/null 2>&1; then
  _s16="${_s16} setup(need mktemp, bash and a readable ${_rel})"
else
  s16_run() { # $1=VERIFIED_COMMIT $2=TAG_COMMIT
    VERIFIED_COMMIT="$1" TAG_COMMIT="$2" bash "${_tmp16}/bind.sh" >/dev/null 2>&1
  }
  s16_bad() { # $1=label $2=VERIFIED_COMMIT $3=TAG_COMMIT
    if s16_run "$2" "$3"; then
      _s16="${_s16} (a)($1 was accepted)"
    fi
  }
  awk '
    /^      - name: Fail if the verified tag commit differs from tag_commit/ { step = 1; next }
    step && /^        run: \|/            { cap = 1; next }
    cap && /^          /                 { sub(/^          /, ""); print; next }
    cap && /^[[:space:]]*$/              { print ""; next }
    cap                                  { exit }
  ' "${_rel}" > "${_tmp16}/bind.sh"
  if [ ! -s "${_tmp16}/bind.sh" ]; then
    _s16="${_s16} (a)(bind-commit run block not found)"
  else
    # shellcheck disable=SC2016
    if grep -qF '${{' "${_tmp16}/bind.sh"; then
      _s16="${_s16} (b)(bind-commit run block contains a template expression)"
    fi
    _a=$(printf 'a%.0s' $(seq 1 40))
    _b=$(printf 'b%.0s' $(seq 1 40))
    _up=$(printf 'A%.0s' $(seq 1 40))
    _39=$(printf 'a%.0s' $(seq 1 39))
    _41=$(printf 'a%.0s' $(seq 1 41))
    _nl=$(printf '%s\n%s' "${_a}" "${_b}")
    if ! s16_run "${_a}" "${_a}"; then
      _s16="${_s16} (a)(equal valid SHAs were rejected)"
    fi
    s16_bad "different valid SHAs" "${_a}" "${_b}"
    s16_bad "both empty" "" ""
    s16_bad "empty verified_commit" "" "${_a}"
    s16_bad "empty tag_commit" "${_a}" ""
    s16_bad "uppercase hex" "${_up}" "${_up}"
    s16_bad "39 characters" "${_39}" "${_39}"
    s16_bad "41 characters" "${_41}" "${_41}"
    s16_bad "41 characters (tag_commit only)" "${_a}" "${_41}"
    s16_bad "SHA plus newline plus second SHA" "${_nl}" "${_nl}"
    s16_bad "multi-line verified_commit, single tag_commit" "${_nl}" "${_a}"
  fi
  rm -rf "${_tmp16}"
  # (b) wiring, parsed as YAML.
  if "${PY}" -c 'import yaml' >/dev/null 2>&1; then
    _w16=$("${PY}" -I - "${_rel}" <<'PYEOF'
import re, sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
jobs = doc.get("jobs") or {}
bad = []
build = jobs.get("build") or {}
sig = jobs.get("verify-tag-signature") or {}

steps = build.get("steps") or []
first = steps[0] if steps else {}
if first.get("id") != "bind-commit":
    bad.append("build steps[0] is not bind-commit (id=%r)" % first.get("id"))
if first.get("name") != "Fail if the verified tag commit differs from tag_commit":
    bad.append("bind-commit step name differs (%r)" % first.get("name"))
env = first.get("env") or {}
if env.get("VERIFIED_COMMIT") != "${{ needs.verify-tag-signature.outputs.verified_commit }}":
    bad.append("bind-commit VERIFIED_COMMIT env is %r" % env.get("VERIFIED_COMMIT"))
if env.get("TAG_COMMIT") != "${{ needs.verify-tag-reachability.outputs.tag_commit }}":
    bad.append("bind-commit TAG_COMMIT env is %r" % env.get("TAG_COMMIT"))
if "${{" in (first.get("run") or ""):
    bad.append("bind-commit run block contains a template expression")

needs = build.get("needs") or []
if isinstance(needs, str):
    needs = [needs]
for j in ("verify-tag-signature", "verify-tag-reachability"):
    if j not in needs:
        bad.append("build.needs lacks %s" % j)

out = (sig.get("outputs") or {}).get("verified_commit")
if out != "${{ steps.verify.outputs.VERIFIED_COMMIT }}":
    bad.append("verify-tag-signature outputs.verified_commit is %r" % out)

vsteps = [s for s in (sig.get("steps") or []) if s.get("id") == "verify"]
if len(vsteps) != 1:
    bad.append("verify-tag-signature has %d steps with id verify" % len(vsteps))
else:
    run = vsteps[0].get("run") or ""
    if "git verify-tag" not in run:
        bad.append("verify step lacks git verify-tag")
    if 'git rev-parse "refs/tags/${TAG}^{commit}"' not in run:
        bad.append("verify step lacks git rev-parse of refs/tags/${TAG}^{commit}")
    if not re.search(r'VERIFIED_COMMIT=.*>>\s*"?\$GITHUB_OUTPUT"?', run):
        bad.append("verify step does not write VERIFIED_COMMIT to GITHUB_OUTPUT")
print("; ".join(bad))
PYEOF
    ) || _w16="could not parse ${_rel} as YAML"
    if [ -n "${_w16}" ]; then
      _s16="${_s16} (b)(${_w16})"
    fi
  else
    _s16="${_s16} (b)(no YAML parser: install PyYAML or set PYTHON)"
  fi
fi
if [ -z "${_s16}" ]; then
  pass "S16 release.yml build refuses a tag commit that differs from the verified one"
else
  fail "S16 release.yml tag-commit binding:${_s16}"
fi

# S17 — release.yml binds the tag object's own name to the ref (FND-0087).
#       `git verify-tag` checks the signature only, so an old signed tag
#       object re-pushed as refs/tags/<new> passed the `verify` step. The
#       step must now read the object's `tag` header (header block only)
#       and fail unless it equals ${TAG}.
#       (a) the verify run block is extracted and run under
#           `bash -c 'set -euo pipefail'` semantics with a `git` shim on
#           PATH (verify-tag succeeds, cat-file tag prints a crafted
#           object): a matching name passes and writes VERIFIED_COMMIT;
#           a different name, an empty name, a body line "tag <TAG>"
#           under a different header name, and a failing cat-file all
#           exit non-zero and write nothing;
#       (b) the cat-file/sed line is exactly
#           `sed -n '1,/^$/s/^tag //p'` (no `q`, so pipefail cannot
#           SIGPIPE cat-file) and sits after `git verify-tag` and before
#           the VERIFIED_COMMIT line.
#       RELEASE_YML overrides the file under test.
_s17=""
_tmp17=$(mktemp -d) || _tmp17=""
if [ -z "${_tmp17}" ] || [ ! -r "${_rel}" ] || ! command -v bash >/dev/null 2>&1; then
  _s17="${_s17} setup(need mktemp, bash and a readable ${_rel})"
else
  mkdir "${_tmp17}/bin"
  # git shim: verify-tag succeeds; cat-file tag prints $S17_OBJ (or fails
  # when S17_CATFILE_FAIL is set); rev-parse prints a fixed SHA.
  cat > "${_tmp17}/bin/git" <<'GITEOF'
#!/bin/sh
case "$1" in
  verify-tag) exit 0 ;;
  cat-file)
    [ -z "${S17_CATFILE_FAIL:-}" ] || exit 128
    printf '%s' "${S17_OBJ}"
    ;;
  rev-parse) echo "0123456789abcdef0123456789abcdef01234567" ;;
  *) echo "git shim: unexpected: $*" >&2; exit 99 ;;
esac
GITEOF
  chmod +x "${_tmp17}/bin/git"
  awk '
    /^      - name: Verify tag signature/ { step = 1; next }
    step && /^        run: \|/            { cap = 1; next }
    cap && /^          /                 { sub(/^          /, ""); print; next }
    cap && /^[[:space:]]*$/              { print ""; next }
    cap                                  { exit }
  ' "${_rel}" > "${_tmp17}/verify.sh"
  if [ ! -s "${_tmp17}/verify.sh" ]; then
    _s17="${_s17} (a)(verify run block not found)"
  else
    # s17_run LABEL EXPECT(pass|fail) TAG OBJECT [catfile-fail] [pattern]
    s17_run() {
      : > "${_tmp17}/out"
      S17_OBJ="$4" S17_CATFILE_FAIL="${5:-}" TAG="$3" \
        GITHUB_OUTPUT="${_tmp17}/out" PATH="${_tmp17}/bin:${PATH}" \
        bash -c 'set -euo pipefail; . "$1"' _ "${_tmp17}/verify.sh" \
        > "${_tmp17}/log" 2>&1
      _rc=$?
      if [ "$2" = pass ]; then
        if [ "${_rc}" -ne 0 ]; then
          _s17="${_s17} (a)($1: rejected, rc=${_rc})"
        elif ! grep -qx 'VERIFIED_COMMIT=0123456789abcdef0123456789abcdef01234567' "${_tmp17}/out"; then
          _s17="${_s17} (a)($1: VERIFIED_COMMIT not written)"
        fi
      else
        if [ "${_rc}" -eq 0 ]; then
          _s17="${_s17} (a)($1: accepted)"
        fi
        if [ -s "${_tmp17}/out" ]; then
          _s17="${_s17} (a)($1: wrote GITHUB_OUTPUT)"
        fi
        if [ -n "${6:-}" ] && ! grep -qF "$6" "${_tmp17}/log"; then
          _s17="${_s17} (a)($1: missing message ${6})"
        fi
      fi
    }
    s17_obj() { # $1=header tag name, $2=message body
      printf 'object 0123456789abcdef0123456789abcdef01234567\ntype commit\ntag %s\ntagger t <t@example.invalid> 1 +0000\n\n%s\n' "$1" "$2"
    }
    _o_match=$(s17_obj v9.9.9 "release")
    _o_other=$(s17_obj v1.0.0 "release")
    _o_body=$(s17_obj v1.0.0 "tag v9.9.9")
    _o_none='object 0123456789abcdef0123456789abcdef01234567
type commit
tagger t <t@example.invalid> 1 +0000

release'
    s17_run "matching name" pass v9.9.9 "${_o_match}"
    s17_run "different name" fail v9.9.9 "${_o_other}" "" "::error::tag object is named 'v1.0.0' but was pushed as refs/tags/v9.9.9"
    s17_run "empty name (no tag header)" fail v9.9.9 "${_o_none}" "" "::error::refs/tags/v9.9.9 has no tag header"
    s17_run "body line 'tag <TAG>' with another header name" fail v9.9.9 "${_o_body}" "" "::error::tag object is named 'v1.0.0'"
    s17_run "cat-file failing" fail v9.9.9 "${_o_match}" 1
    # (b) static shape and order, on the extracted block.
    _l_sed=$(grep -n "git cat-file tag \"refs/tags/\${TAG}\" | sed -n '1,/^\$/s/^tag //p'" "${_tmp17}/verify.sh" | cut -d: -f1)
    _l_ver=$(grep -n '^if git verify-tag ' "${_tmp17}/verify.sh" | head -n1 | cut -d: -f1)
    _l_out=$(grep -n '^  *VERIFIED_COMMIT=' "${_tmp17}/verify.sh" | head -n1 | cut -d: -f1)
    case "${_l_sed}" in
      ''|*[!0-9]*) _s17="${_s17} (b)(exact cat-file | sed -n '1,/^\$/s/^tag //p' line not found exactly once)" ;;
      *)
        if [ -z "${_l_ver}" ] || [ -z "${_l_out}" ] \
           || [ "${_l_sed}" -le "${_l_ver}" ] || [ "${_l_sed}" -ge "${_l_out}" ]; then
          _s17="${_s17} (b)(tag-name check is not between git verify-tag (${_l_ver:-?}) and VERIFIED_COMMIT (${_l_out:-?}): line ${_l_sed})"
        fi
        ;;
    esac
    if grep -nE "sed -n '1,/\^\\\$/[^']*q" "${_tmp17}/verify.sh" >/dev/null; then
      _s17="${_s17} (b)(sed range uses q)"
    fi
  fi
fi
rm -rf "${_tmp17}"
if [ -z "${_s17}" ]; then
  pass "S17 release.yml verify step requires the tag object name to equal the ref"
else
  fail "S17 release.yml tag-name binding:${_s17}"
fi

# S18 — release.yml publishes the public tags last (FND-0029, FND-0037).
#       The build pushes the image by digest, untagged. Smoke, SBOM,
#       cosign and attest use <image>@<digest>; only the final step
#       (`publish-tags`) creates the public tags from that digest,
#       version tags before :latest, never :latest for a pre-release.
#       (a) step order and wiring in the `build` job, parsed as YAML:
#           no step before publish-tags pushes a tag; publish-tags comes
#           after smoke, SBOM, cosign and both attest steps and is the
#           only `imagetools create`; digest directly follows build;
#           build has no `tags:`/`push:` and an `outputs:` with
#           push-by-digest/name-canonical/push and name= image_names;
#           every consumer reads steps.digest.outputs.digest as @D, only
#           the digest step reads steps.build.outputs.digest, and smoke
#           and SBOM no longer use the version tag;
#       (b) the digest regex and the per-tag digest comparison are in
#           the run blocks, which hold no `${{`;
#       (c) the digest step run under `bash -c 'set -euo pipefail'`:
#           a valid digest passes and writes digest=; empty, short,
#           uppercase and multi-line values fail and write nothing;
#       (d) the publish-tags block run with a fake `docker` and `jq` on
#           PATH (a tiny sed-based jq shim, with a NOTE, if jq is not
#           installed): digest match, mismatch, empty digest, empty
#           DIGEST and the pre-release cases;
#       (e) the meta step run with a fake env: stable and rc versions
#           give the right pre_release, all_tags and image_names.
#       RELEASE_YML overrides the file under test.
_s18=""
_tmp18=$(mktemp -d) || _tmp18=""
if [ -z "${_tmp18}" ] || [ ! -r "${_rel}" ] || ! command -v bash >/dev/null 2>&1; then
  _s18="${_s18} setup(need mktemp, bash and a readable ${_rel})"
else
  # (a) wiring, parsed as YAML.
  if "${PY}" -c 'import yaml' >/dev/null 2>&1; then
    _w18=$("${PY}" -I - "${_rel}" <<'PYEOF'
import re, sys, yaml

path = sys.argv[1]
doc = yaml.safe_load(open(path))
steps = ((doc.get("jobs") or {}).get("build") or {}).get("steps") or []
bad = []
DIG = "${{ steps.digest.outputs.digest }}"
IMG = "${{ steps.meta.outputs.image }}@" + DIG

def idx(pred):
    return [i for i, s in enumerate(steps) if pred(s)]

def blob(s):
    parts = [str(s.get("run") or "")]
    parts += [str(v) for v in (s.get("env") or {}).values()]
    parts += [str(v) for v in (s.get("with") or {}).values()]
    return "\n".join(parts)

def one(label, found):
    if len(found) != 1:
        bad.append("%s: expected 1 step, found %d" % (label, len(found)))
        return None
    return found[0]

build = one("build", idx(lambda s: s.get("id") == "build"))
digest = one("digest", idx(lambda s: s.get("id") == "digest"))
smoke = one("smoke", idx(lambda s: s.get("name") == "Smoke test the just-pushed image"))
sbom = one("sbom", idx(lambda s: str(s.get("uses") or "").startswith("anchore/sbom-action@")))
cosign = one("cosign", idx(lambda s: "cosign sign" in str(s.get("run") or "")))
pub = one("publish-tags", idx(lambda s: s.get("id") == "publish-tags"))
attest = idx(lambda s: str(s.get("uses") or "").startswith("actions/attest@"))
if len(attest) < 2:
    bad.append("expected 2 active attest steps, found %d" % len(attest))

creators = idx(lambda s: "imagetools create" in str(s.get("run") or ""))
if pub is None or creators != [pub]:
    bad.append("imagetools create runs in steps %r, expected only publish-tags (%r)" % (creators, pub))

if None not in (pub, smoke, sbom, cosign) and attest:
    for label, i in (("smoke", smoke), ("SBOM", sbom), ("cosign", cosign)):
        if pub <= i:
            bad.append("publish-tags (%d) is not after %s (%d)" % (pub, label, i))
    for i in attest:
        if pub <= i:
            bad.append("publish-tags (%d) is not after attest step %d" % (pub, i))
if None not in (build, digest) and digest != build + 1:
    bad.append("digest step (%d) does not directly follow build (%d)" % (digest, build))

# No step before publish-tags may push or move a tag.
if pub is not None:
    for i in range(pub):
        s = steps[i]
        w = s.get("with") or {}
        r = str(s.get("run") or "")
        if w.get("tags") or str(w.get("push")).lower() == "true":
            bad.append("step %d (%s) has tags:/push: before publish-tags" % (i, s.get("name")))
        if re.search(r"docker (push|tag)\b|buildx imagetools", r):
            bad.append("step %d (%s) pushes or tags in its run block before publish-tags" % (i, s.get("name")))

if build is not None:
    w = steps[build].get("with") or {}
    for k in ("tags", "push"):
        if k in w:
            bad.append("build step still has %s:" % k)
    o = str(w.get("outputs") or "")
    for need in ("type=image", "push-by-digest=true", "name-canonical=true", "push=true",
                 '"name=${{ steps.meta.outputs.image_names }}"'):
        if need not in o:
            bad.append("build outputs lacks %s (outputs=%r)" % (need, o))

def eq(label, got, want):
    if got != want:
        bad.append("%s is %r, expected %r" % (label, got, want))

if smoke is not None:
    eq("smoke env IMAGE", (steps[smoke].get("env") or {}).get("IMAGE"), IMG)
if sbom is not None:
    eq("SBOM image", (steps[sbom].get("with") or {}).get("image"), IMG)
if cosign is not None:
    eq("cosign env DIGEST", (steps[cosign].get("env") or {}).get("DIGEST"), DIG)
    if "@${DIGEST}" not in steps[cosign].get("run", ""):
        bad.append("cosign run does not sign <image>@${DIGEST}")
for i in attest:
    eq("attest[%d] subject-digest" % i, (steps[i].get("with") or {}).get("subject-digest"), DIG)
for label, i in (("smoke", smoke), ("SBOM", sbom)):
    if i is not None and re.search(r"steps\.meta\.outputs\.(version|tag)\b", blob(steps[i])):
        bad.append("%s still references a tag (steps.meta.outputs.version/tag)" % label)

# steps.build.outputs.digest: parsed steps (all but digest) ...
for i, s in enumerate(steps):
    if i != digest and "steps.build.outputs.digest" in blob(s):
        bad.append("step %d (%s) reads steps.build.outputs.digest" % (i, s.get("name")))
# ... and every non-comment line of the file: exactly one reader.
n = sum(1 for l in open(path) if "steps.build.outputs.digest" in l and not l.lstrip().startswith("#"))
if n != 1:
    bad.append("steps.build.outputs.digest appears on %d non-comment lines, expected 1" % n)
print("; ".join(bad))
PYEOF
    ) || _w18="could not parse ${_rel} as YAML"
    if [ -n "${_w18}" ]; then
      _s18="${_s18} (a)(${_w18})"
    fi
  else
    _s18="${_s18} (a)(no YAML parser: install PyYAML or set PYTHON)"
  fi

  # run-block extraction, same awk as S15-S17.
  s18_extract() { # $1=step name prefix $2=output file
    awk -v name="      - name: $1" '
      index($0, name) == 1                 { step = 1; next }
      step && /^        run: \|/            { cap = 1; next }
      cap && /^          /                 { sub(/^          /, ""); print; next }
      cap && /^[[:space:]]*$/              { print ""; next }
      cap                                  { exit }
    ' "${_rel}" > "$2"
  }
  s18_extract "Validate the pushed image digest" "${_tmp18}/digest.sh"
  s18_extract "Publish the release tags" "${_tmp18}/publish.sh"
  s18_extract "Resolve tag, version and enabled registries" "${_tmp18}/meta.sh"

  # (b) static content of the run blocks.
  for _f in digest publish meta; do
    if [ ! -s "${_tmp18}/${_f}.sh" ]; then
      _s18="${_s18} (b)(${_f} run block not found)"
    fi
  done
  # shellcheck disable=SC2016
  if [ -s "${_tmp18}/digest.sh" ]; then
    grep -qF '^sha256:[0-9a-f]{64}$' "${_tmp18}/digest.sh" \
      || _s18="${_s18} (b)(digest regex missing from the digest step)"
    grep -qF '${{' "${_tmp18}/digest.sh" \
      && _s18="${_s18} (b)(digest run block contains a template expression)"
  fi
  # shellcheck disable=SC2016
  if [ -s "${_tmp18}/publish.sh" ]; then
    grep -qF "docker buildx imagetools inspect" "${_tmp18}/publish.sh" \
      && grep -qF "jq -r '.digest // empty'" "${_tmp18}/publish.sh" \
      && grep -qF '!= "${DIGEST}"' "${_tmp18}/publish.sh" \
      || _s18="${_s18} (b)(per-tag digest comparison missing from publish-tags)"
    grep -qF '${{' "${_tmp18}/publish.sh" \
      && _s18="${_s18} (b)(publish-tags run block contains a template expression)"
  fi
  # shellcheck disable=SC2016
  if [ -s "${_tmp18}/meta.sh" ]; then
    grep -qF 'Pre-release tag ${tag} must not publish a :latest alias' "${_tmp18}/meta.sh" \
      || _s18="${_s18} (e)(meta pre-release :latest guard missing)"
  fi

  _d_ok=$(printf 'a%.0s' $(seq 1 64))
  _d_other=$(printf 'b%.0s' $(seq 1 64))
  _D="sha256:${_d_ok}"
  _DO="sha256:${_d_other}"

  # (c) the digest step.
  if [ -s "${_tmp18}/digest.sh" ]; then
    s18_dig() { # $1=label $2=expect(pass|fail) $3=DIGEST
      : > "${_tmp18}/out"
      DIGEST="$3" GITHUB_OUTPUT="${_tmp18}/out" \
        bash -c 'set -euo pipefail; . "$1"' _ "${_tmp18}/digest.sh" > "${_tmp18}/log" 2>&1
      _rc=$?
      if [ "$2" = pass ]; then
        if [ "${_rc}" -ne 0 ]; then
          _s18="${_s18} (c)($1: rejected, rc=${_rc})"
        elif [ "$(cat "${_tmp18}/out")" != "digest=$3" ]; then
          _s18="${_s18} (c)($1: digest= not written)"
        fi
      else
        [ "${_rc}" -ne 0 ] || _s18="${_s18} (c)($1: accepted)"
        [ ! -s "${_tmp18}/out" ] || _s18="${_s18} (c)($1: wrote GITHUB_OUTPUT)"
      fi
    }
    s18_dig "valid digest" pass "${_D}"
    s18_dig "empty digest" fail ""
    s18_dig "short digest" fail "sha256:abc"
    s18_dig "63 hex characters" fail "sha256:${_d_ok%a}"
    s18_dig "uppercase hex" fail "sha256:$(printf 'A%.0s' $(seq 1 64))"
    s18_dig "uppercase prefix" fail "SHA256:${_d_ok}"
    s18_dig "no prefix" fail "${_d_ok}"
    s18_dig "digest plus newline plus junk" fail "$(printf '%s\nx' "${_D}")"
    s18_dig "newline before digest" fail "$(printf 'x\n%s' "${_D}")"
  fi

  # (d) the publish-tags step, with docker (and, if absent, jq) shims.
  if [ -s "${_tmp18}/publish.sh" ]; then
    mkdir "${_tmp18}/bin"
    cat > "${_tmp18}/bin/docker" <<'DEOF'
#!/bin/sh
# Logs create calls; answers inspect according to S18_INSPECT.
[ "$1 $2" = "buildx imagetools" ] || { echo "docker shim: unexpected: $*" >&2; exit 99; }
case "$3" in
  create) printf 'CREATE %s %s\n' "$5" "$6" >> "${S18_LOG}" ;;
  inspect)
    printf 'INSPECT %s\n' "$4" >> "${S18_LOG}"
    case "${S18_INSPECT}" in
      match) printf '{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"%s","size":1}\n' "${S18_D}" ;;
      other) printf '{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"%s","size":1}\n' "${S18_DO}" ;;
      nodigest) printf '{"mediaType":"application/vnd.oci.image.index.v1+json","size":1}\n' ;;
      emptydigest) printf '{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"","size":1}\n' ;;
      *) echo "docker shim: bad S18_INSPECT" >&2; exit 98 ;;
    esac
    ;;
  *) echo "docker shim: unexpected: $*" >&2; exit 99 ;;
esac
DEOF
    chmod +x "${_tmp18}/bin/docker"
    if command -v jq >/dev/null 2>&1; then
      _jq18=real
    else
      _jq18=shim
      printf 'NOTE S18: jq is not installed here; using a sed-based jq shim for "-r .digest // empty"\n'
      cat > "${_tmp18}/bin/jq" <<'JEOF'
#!/bin/sh
sed -n 's/.*"digest":"\([^"]*\)".*/\1/p'
JEOF
      chmod +x "${_tmp18}/bin/jq"
    fi
    _g=ghcr.io/acme/ftp-deployment-action
    _h=docker.io/acme/ftp-deployment-action
    _names="${_g},${_h}"
    _stable=$(printf '%s\n' "${_g}:1.2.3" "${_g}:v1.2.3" "${_g}:latest" "${_h}:1.2.3" "${_h}:v1.2.3" "${_h}:latest")
    _rc_tags=$(printf '%s\n' "${_g}:1.2.3-rc.1" "${_g}:v1.2.3-rc.1" "${_h}:1.2.3-rc.1" "${_h}:v1.2.3-rc.1")
    _rc_latest=$(printf '%s\n%s\n' "${_rc_tags}" "${_g}:latest")
    # s18_pub LABEL EXPECT DIGEST PRE TAGS INSPECT [nocreate]
    s18_pub() {
      : > "${_tmp18}/plog"
      S18_LOG="${_tmp18}/plog" S18_INSPECT="$6" S18_D="${_D}" S18_DO="${_DO}" \
        DIGEST="$3" PRE_RELEASE="$4" ALL_TAGS="$5" IMAGE_NAMES="${_names}" \
        PATH="${_tmp18}/bin:${PATH}" \
        bash -c 'set -euo pipefail; . "$1"' _ "${_tmp18}/publish.sh" > "${_tmp18}/log" 2>&1
      _rc=$?
      if [ "$2" = pass ]; then
        [ "${_rc}" -eq 0 ] || _s18="${_s18} (d)($1: rejected, rc=${_rc})"
      else
        [ "${_rc}" -ne 0 ] || _s18="${_s18} (d)($1: accepted)"
      fi
      if [ "${7:-}" = nocreate ] && grep -q '^CREATE' "${_tmp18}/plog"; then
        _s18="${_s18} (d)($1: created a tag before failing)"
      fi
    }
    s18_pub "matching digest" pass "${_D}" false "${_stable}" match
    # Order, source and coverage of the creates from that run.
    if ! awk -v D="${_D}" '
        $1 != "CREATE" { next }
        { n++; ref = $2; repo = ref; sub(/:[^:]*$/, "", repo)
          if ($3 != repo "@" D) { print "source of " ref " is " $3; bad = 1 }
          if (ref ~ /:latest$/) { latest++; seen = 1; r[repo] = r[repo] "L" }
          else { if (seen) { print "version tag " ref " after :latest"; bad = 1 }
                 ver++; r[repo] = r[repo] "V" } }
        END { if (n != 6 || ver != 4 || latest != 2) { print "creates: " n " (" ver " version, " latest " latest), expected 6 (4, 2)"; bad = 1 }
              for (k in r) if (r[k] !~ /V.*L$/) { print k " lacks version tags before :latest"; bad = 1 }
              if (length(r) != 2) { print "registries covered: " length(r); bad = 1 }
              exit bad }
      ' "${_tmp18}/plog" > "${_tmp18}/why"; then
      _s18="${_s18} (d)(matching digest: $(tr '\n' ' ' < "${_tmp18}/why"))"
    fi
    # every created tag was inspected afterwards
    if [ "$(grep -c '^INSPECT' "${_tmp18}/plog")" -ne 6 ]; then
      _s18="${_s18} (d)(matching digest: not every created tag was inspected)"
    fi
    s18_pub "inspect returns a different digest" fail "${_D}" false "${_stable}" other
    s18_pub "inspect returns no digest field" fail "${_D}" false "${_stable}" nodigest
    s18_pub "inspect returns an empty digest" fail "${_D}" false "${_stable}" emptydigest
    s18_pub "empty DIGEST" fail "" false "${_stable}" match nocreate
    s18_pub "malformed DIGEST" fail "sha256:abc" false "${_stable}" match nocreate
    s18_pub "pre-release with :latest in ALL_TAGS" fail "${_D}" true "${_rc_latest}" match nocreate
    s18_pub "pre-release without :latest" pass "${_D}" true "${_rc_tags}" match
    if grep -q ':latest' "${_tmp18}/plog" || [ "$(grep -c '^CREATE' "${_tmp18}/plog")" -ne 4 ]; then
      _s18="${_s18} (d)(pre-release without :latest: expected exactly 4 creates and no :latest)"
    fi
  fi

  # (e) the meta step with a fake environment.
  if [ -s "${_tmp18}/meta.sh" ]; then
    # shellcheck disable=SC2016
    sed 's/\${{ github\.repository_owner }}/acme/' "${_tmp18}/meta.sh" > "${_tmp18}/meta_run.sh"
    s18_meta() { # $1=label $2=tag $3=pre_release $4=expect :latest (yes|no)
      : > "${_tmp18}/mout"
      GITHUB_EVENT_NAME=push GITHUB_REF_NAME="$2" INPUT_VERSION="" \
        DOCKERHUB_USERNAME=u DOCKERHUB_TOKEN=t AWS_ROLE_TO_ASSUME="" \
        GITHUB_OUTPUT="${_tmp18}/mout" \
        bash -c 'set -euo pipefail; . "$1"' _ "${_tmp18}/meta_run.sh" > "${_tmp18}/log" 2>&1 \
        || { _s18="${_s18} (e)($1: meta step failed)"; return; }
      grep -qx "pre_release=$3" "${_tmp18}/mout" \
        || _s18="${_s18} (e)($1: pre_release is not $3)"
      grep -qx "image_names=ghcr.io/acme/ftp-deployment-action,docker.io/acme/ftp-deployment-action" "${_tmp18}/mout" \
        || _s18="${_s18} (e)($1: image_names wrong)"
      _tags=$(sed -n '/^all_tags<<EOF$/,/^EOF$/p' "${_tmp18}/mout" | sed '1d;$d')
      _nl=$(printf '%s\n' "${_tags}" | grep -c '.')
      _lt=$(printf '%s\n' "${_tags}" | grep -c ':latest$')
      if [ "$4" = yes ]; then
        [ "${_nl}" -eq 6 ] && [ "${_lt}" -eq 2 ] \
          || _s18="${_s18} (e)($1: all_tags has ${_nl} lines, ${_lt} :latest; expected 6 and 2)"
      else
        [ "${_nl}" -eq 4 ] && [ "${_lt}" -eq 0 ] \
          || _s18="${_s18} (e)($1: all_tags has ${_nl} lines, ${_lt} :latest; expected 4 and 0)"
      fi
    }
    s18_meta "stable v1.2.3" v1.2.3 false yes
    s18_meta "pre-release v1.2.3-rc.1" v1.2.3-rc.1 true no
  fi
fi
rm -rf "${_tmp18}"
if [ -z "${_s18}" ]; then
  pass "S18 release.yml pushes by digest and publishes the tags last, :latest after the gate"
else
  fail "S18 release.yml digest-first publishing:${_s18}"
fi

if [ "${_failed}" -ne 0 ]; then
  printf '\nRESULT: FAIL\n'
  exit 1
fi
printf '\nRESULT: PASS\n'
