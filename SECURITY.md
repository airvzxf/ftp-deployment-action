# Security Policy

## Supported versions

Only the latest tagged release receives security fixes. Older tags
(`v1.0-alpha.*`, `v1.1`, `v1.2.0`, `v1.3.x`, `latest`) are kept on a
best-effort basis and may not receive patches.

| Tag        | Supported |
|------------|-----------|
| `latest`   | Yes       |
| `<v1.4+>`  | Yes       |
| `<v1.4`    | No        |

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems.

Report privately by emailing **israel.alberto.rv@gmail.com** with:

- A short description of the issue and its impact.
- A reproducer (workflow YAML, lftp command, or steps).
- The affected version (commit SHA or tag).

You should receive an acknowledgement within 72 hours. If you do not,
please follow up with a second email.

## What to expect

- **Acknowledgement** within 72 hours.
- **Triage** within 7 days: confirm the issue, assign a CVSS estimate
  and decide whether to fix in-tree or in a fork.
- **Fix** for critical/high issues as soon as possible, ideally within
  30 days. Lower-severity issues are bundled with the next regular
  release.
- **Disclosure**: once a fix is published, the original report will be
  credited in the release notes (unless the reporter prefers otherwise).

## Out of scope

- Vulnerabilities in upstream `lftp` — please report them upstream at
  https://lftp.yar.ru/.
- Vulnerabilities in the base `alpine` image — please report to the
  Alpine security team.
- Misconfiguration of the action (e.g. using `delete: true` with the
  wrong `remote_dir`) that does not require a code change.
