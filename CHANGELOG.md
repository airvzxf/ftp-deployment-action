# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Release pipeline with tag-signature guard (port of `airvzxf/moagan` PR #737)** — `.github/workflows/release.yml` is now a five-job pipeline (`validate-tag-input` → `verify-tag-reachability` ∥ `verify-tag-signature` → `build` → `publish`) with two parallel verify jobs that gate the build. `validate-tag-input` regex-checks the dispatch input. `verify-tag-reachability` enforces the AGENTS.md "tag the trunk merge commit, NOT the branch tip" rule mechanically (`git merge-base --is-ancestor`). `verify-tag-signature` runs `git verify-tag` against an in-repo allow-list fetched from `origin/main` (so revoking a key on main takes effect on the next release). The `build` job checks out the immutable tag commit SHA (not the mutable ref) so a tag force-push mid-run cannot redirect the build. `publish` is the only job with `contents: write`. Top-level `concurrency: release-<tag>` prevents two `release.yml` runs against the same tag from racing the publish step.
- **In-repo trusted-signers allow-list** — two new files under `.github/`. `.github/trusted-signers` is the SSH backend (one line: the maintainer's ED25519 key, fingerprint `SHA256:POu2Sr8ILb1IM05Vh1cGU3xivjx05QjWoWYhdLc6YHA`). `.github/trusted-signers.asc` is the PGP backend (ASCII-armored RSA key, fingerprint `82DE44111B30F91F55BCEB1F414687A3CD7E65B9`, used for `v1.5.0` … `v2.10.0`). `git verify-tag` auto-detects the tag's signature format; the workflow imports the PGP key into a temp keyring only when the tag is PGP-signed, so SSH-only releases never need the `.asc` file (keeps the documented key-removal path in AGENTS.md intact).
- **`AGENTS.md`** — project-level agent instructions mirroring the structure of `airvzxf/moagan`'s `AGENTS.md` (complementary to the existing `ROADMAP.md`). Documents the tag-signature guard, the dual-backend allow-list, the local-verification command, the "tag the trunk merge commit" procedure, and the red-workflow repair loop. The procedural rules are load-bearing; the workflow guards are the structural check.
- **`scripts/verify-tag.sh`** — single-purpose local re-verifier. Imports the PGP allow-list into a `mktemp -d` keyring (so the developer's permanent `~/.gnupg` is untouched), configures git via per-invocation `git -c` overrides (so `.git/config` is untouched), and runs `git verify-tag` against the tag. Handles SSH-signed (`v2.11.0+`), PGP-signed (`v2.10.0` and earlier), and lightweight (`v1.0-alpha.1` … `v1.3.3`, exits 0 with INFO) tags. Shellcheck-clean.

### Changed

- **`SECURITY.md` (Tag signing policy)** — replaced the out-of-date "GPG-signed" claim with a per-tag-range table covering all three historical formats (lightweight legacy, PGP, SSH), and added the local-verification command (`scripts/verify-tag.sh <tag>`).
- **ECR Public publishing temporarily disabled** — the `AWS_ROLE_TO_ASSUME` secret is configured in the repo, but the IAM role's OIDC trust policy is not configured to allow this repo, so `Configure AWS credentials (OIDC) for ECR Public` fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity` (the role was set up under an AWS account the maintainer no longer has access to). The two ECR Public steps (`Configure AWS credentials`, `Log in to ECR Public`) and the ECR branch in the meta step are commented out, and the `if false; then` in the meta step emits a `::notice::ECR Public publishing disabled...` line on every release. The cosign sign + SBOM attestation steps for ECR Public remain in the file (gated on `if: ecr_enabled == 'true'`, which is never set), so re-enabling the feature is a one-line change in two places once the IAM trust policy is fixed. The pipeline now publishes to **ghcr.io (always) + Docker Hub (when `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` are set)** only. See the comment in `.github/workflows/release.yml` for the exact re-enable diff.

### Fixed

- **`INPUT_EXCLUDE_DELETE` is no longer a no-op on `lftp` 4.9.3 (closes #131)** — `lib.sh::build_ftp_settings` now wraps the `mirror:exclude-file` assignment in `set -a; set mirror:exclude-file <value>; set -a;`. lftp 4.9.x hides `mirror:exclude-file` behind the `set -a` toggle (off by default; the toggle enables "show all variables" so a plain `set mirror:exclude-file ...` is recognised); toggling `-a` on for the whole settings chain would also flip the auto-show for every other directive and produce surprising side effects, so the toggle is on for the one write and off again before the rest of the chain. Users who set `delete: true` together with `INPUT_EXCLUDE_DELETE=<glob>` to preserve a list of remotely-managed files from the mirror's `--delete` pass now get the documented behaviour (the glob is honoured end-to-end); pre-fix, the directive was rejected by lftp with `mirror:exclude-file: no such variable. Use 'set -a' to look at all variables.` and the files were silently deleted. A new integration scenario `11-exclude-delete-protects-remote.sh` exercises the action end-to-end: it pre-seeds the FTP user's home with `stale.html` (must be removed by `--delete`) and `important.bak` (matches `*.bak`, must survive), invokes the action image with `INPUT_DELETE=true` + `INPUT_EXCLUDE_DELETE='*.bak'`, and asserts all three states. The `parse.bats` unit test for `build_ftp_settings` is updated to assert the new directive count (11 standard + 3 for the EXCLUDE_DELETE directive = 14) and the full `set -a; set mirror:exclude-file *.bak; set -a;` substring. Supersedes the `INPUT_EXCLUDE_DELETE is a no-op on lftp 4.9.3` entry under v2.11.0 "Known limitations".

## [2.11.1] - 2026-09-03

Pre-baked FTPS test server image (PR #139, closes #135): scenarios 03 (explicit) and 04 (implicit) no longer pay the per-run `apk add --no-cache` cost, eliminating the apk-index download race that intermittently failed CI.

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
  | AWS ECR Public (opt-in, OIDC) | `public.ecr.aws/airvzxf/ftp-deployment-action:<tag>` | `uses: docker://public.ecr.aws/airvzxf/ftp-deployment-action@v2` |

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


[2.1.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.0.1...v2.1.0
[2.0.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v1.5.0...v2.0.0
[1.5.0]: https://github.com/airvzxf/ftp-deployment-action/releases/tag/v1.5.0
[2.9.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.8.0...v2.9.0
[2.10.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.9.0...v2.10.0
[2.4.1]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.4.0...v2.4.1
[1.3.3]: https://github.com/airvzxf/ftp-deployment-action/releases/tag/v1.3.3
[2.0.1]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.0.0...v2.0.1
[2.8.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.7.0...v2.8.0
