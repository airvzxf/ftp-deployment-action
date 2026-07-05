# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[Unreleased]: https://github.com/airvzxf/ftp-deployment-action/compare/v2.0.1...HEAD
[2.0.0]: https://github.com/airvzxf/ftp-deployment-action/compare/v1.5.0...v2.0.0
[1.5.0]: https://github.com/airvzxf/ftp-deployment-action/releases/tag/v1.5.0
[1.3.3]: https://github.com/airvzxf/ftp-deployment-action/releases/tag/v1.3.3
