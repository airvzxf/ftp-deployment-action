# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


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
[1.3.3]: https://github.com/airvzxf/ftp-deployment-action/releases/tag/v1.3.3
