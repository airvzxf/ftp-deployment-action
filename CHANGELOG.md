# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- Password and other input values are no longer printed to the workflow
  log by default.

## [1.3.3] - 2024-XX-XX

Historical. See git history for changes prior to `CHANGELOG.md` adoption.

[Unreleased]: https://github.com/airvzxf/ftp-deployment-action/compare/v1.3.3...HEAD
[1.3.3]: https://github.com/airvzxf/ftp-deployment-action/releases/tag/v1.3.3
