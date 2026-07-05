# FTP Deployment: GitHub Action

This GitHub action copies the files via FTP from your Git project to your server in a specific path.

## Security and SSL

By default, `ftp_ssl_allow` is set to `true` to ensure your connection is encrypted, and `ssl_verify_certificate` is also set to `true`, so the action refuses to connect to a server with an invalid, expired, or hostname-mismatched certificate. **This is a breaking change from v1.x**: if you connect to a server with a self-signed certificate or a direct IP, the action will now fail with a TLS error. To opt back into the v1.x behaviour, set `ssl_verify_certificate: false` explicitly in your workflow.

> **Note on direct-IP connections**: lftp cannot validate a hostname against an IP-address certificate, so `ssl_verify_certificate: true` requires both a valid certificate and a hostname (not a bare IP) in the `server` input.

## Usage Example

Add this code in `./.github/workflows/your_action.yml`.

More about GitHub "secrets" in this article:
[Creating and storing encrypted secrets][1].

```yaml
name: CI -> Deploy to My website
on:
  push:
    branches: [ main, development ]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # Here is the deployment action
      - name: Upload from public_html via FTP
        uses: airvzxf/ftp-deployment-action@latest
        with:
          server: ${{ secrets.FTP_SERVER }}
          user: ${{ secrets.FTP_USERNAME }}
          password: ${{ secrets.FTP_PASSWORD }}
          local_dir: "./public_html"
```

Optionally, you can get the live version which has the last commits using the `main` branch like this:
`uses: airvzxf/ftp-deployment-action@main`.

## Settings

Usually the zero values mean unlimited or infinite. This table is based on the default values on `lftp-4.9.2`.

| Option                 | Description                                                                           | Required | Default | Example                                                                                           |
|------------------------|---------------------------------------------------------------------------------------|----------|---------|---------------------------------------------------------------------------------------------------|
| server                 | FTP Server.                                                                           | Yes      | N/A     | rovisoft.net                                                                                      |
| user                   | FTP Username.                                                                         | Yes      | N/A     | myself@rovisoft.net                                                                               |
| password               | FTP Password.                                                                         | Yes      | N/A     | ExampleOnlyAlphabets                                                                              |
| local_dir              | Local directory.                                                                      | No       | "./"    | "./public_html"                                                                                   |
| remote_dir             | Remote directory.                                                                     | No       | "./"    | "/www/user/home"                                                                                  |
| max_retries            | Times that the `lftp` command will be executed if an error occurred.                  | No       | 10      | N/A                                                                                               |
| delete                 | Delete all the files inside of the remote directory before the upload process.        | No       | false   | N/A                                                                                               |
| no_symlinks            | Do not create symbolic links.                                                         | No       | true    | N/A                                                                                               |
| mirror_verbose         | Mirror verbosity level.                                                               | No       | 1       | N/A                                                                                               |
| ftp_ssl_allow          | FTP - Allow SSL encryption.                                                           | No       | true    | N/A                                                                                               |
| ssl_verify_certificate | FTP - Verify SSL certificate.                                                         | No       | false   | N/A                                                                                               |
| ssl_check_hostname     | FTP - Check certificate hostname.                                                     | No       | true    | N/A                                                                                               |
| ftp_passive_mode       | FTP - This can be useful if you are behind a firewall or a dumb masquerading router.  | No       | true    | N/A                                                                                               |
| ftp_use_feat           | FTP - FEAT: Determining what extended features the FTP server supports.               | No       | false   | N/A                                                                                               |
| ftp_nop_interval       | FTP - Delay in seconds between NOOP commands when downloading tail of a file.         | No       | 2       | N/A                                                                                               |
| net_max_retries        | NET - Maximum number of operation without success.<br> 0 unlimited.<br> 1 no retries. | No       | 1       | N/A                                                                                               |
| net_persist_retries    | NET - Ignore hard errors.<br> When reply 5xx errors or there is too many users.       | No       | 5       | N/A                                                                                               |
| net_timeout            | NET - Sets the network protocol timeout.                                              | No       | 15s     | N/A                                                                                               |
| dns_max_retries        | DNS - 0 no limit trying to lookup an address otherwise try only this number of times. | No       | 8       | N/A                                                                                               |
| dns_fatal_timeout      | DNS - Time for DNS queries.<br> Set to "never" to disable.                            | No       | 10s     | N/A                                                                                               |
| lftp_settings          | Any other settings that you find in the MAN pages for the LFTP package.               | No       | ""      | "set cache:cache-empty-listings true; set cmd:status-interval 1s; set http:user-agent 'firefox';" |
| debug                  | If "true", print resolved input values to the log.                                    | No       | false   | N/A                                                                                               |

More information on the official site for [lftp - Manual pages][2].

### Minimal example (only required inputs)

The example above shows the **minimum** required inputs (`server`, `user`, `password`, `local_dir`).
All other settings use the defaults shown in the table above. For full control see the
extended example below.

### Example with NO DEFAULT settings

```yaml
name: CI -> Deploy to My website
on:
  push:
    branches: [ main, development ]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # Here is the deployment action
      - name: Upload from public_html via FTP
        uses: airvzxf/ftp-deployment-action@latest
        with:
          server: ${{ secrets.FTP_SERVER }}
          user: ${{ secrets.FTP_USERNAME }}
          password: ${{ secrets.FTP_PASSWORD }}
          local_dir: "./public_html"
          remote_dir: "/www/sub-domain/games/myself"
          delete: "true"
          max_retries: "7"
          no_symlinks: "false"
          ftp_ssl_allow: "false"
          ssl_verify_certificate: "true"
          ssl_check_hostname: "false"
          ftp_use_feat: "true"
          ftp_nop_interval: "9"
          net_max_retries: "0"
          net_persist_retries: "11"
          net_timeout: "13s"
          dns_max_retries: "17"
          dns_fatal_timeout: "never"
          lftp_settings: "set cache:cache-empty-listings true; set cmd:status-interval 1s; set http:user-agent 'firefox';"
```

## NOTES

Main features:

- Copy all the files inside the specific folder from your GitHub repository to the specific folder in your server.
- Option to delete all the files in the specific remote folder before the upload.
- Using Alpine container means small size and faster creation of the container.
- Show messages in the console logs for every executed command.

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Upload finished successfully. |
| `1`  | Upload failed after all retries; the last lftp error is printed above. |
| `2`  | Invalid input. This includes: a non-integer numeric option (e.g. `max_retries`); a `local_dir` / `remote_dir` that fails the path-traversal or shell-metacharacter guard; an `lftp_settings` value that contains control characters, a backtick, a dollar sign, or more than three `;`-chained directives. |

When the global 5-hour timeout is reached the lftp process is killed and the
action exits with `1` (the most recent lftp exit code is also printed to the
log for debugging).

## Security

For how to report vulnerabilities please see [`SECURITY.md`](./SECURITY.md).

This action runs as the unprivileged `lftp` user inside the container
(Dockerfile `USER lftp`). The `password` input is never passed to
`lftp` on the command line: it is written to `~/.netrc` with mode
`0600` for the duration of the run and removed via an `EXIT` trap
on any exit path (success, error, `set -e` abort, SIGINT). Combined,
these mean the password never appears in `/proc/<pid>/cmdline` or in
the GitHub Actions runner log.

`local_dir` and `remote_dir` are validated against `..` path-traversal
components, leading dashes (which `lftp` would misread as options),
control characters, and shell metacharacters (`;`, `&`, `|`, backtick,
dollar). `lftp_settings` is lightly sanitised: control characters,
backtick, dollar, and more than three `;`-chained directives are
rejected. The action exits with code `2` and a clear error on any
of these.

## Changelog

See [`CHANGELOG.md`](./CHANGELOG.md) for release notes.

TODOs:

- Add options for exclude delete files.
- Take all the logs from the Linux container then attach all into the Workflow Artifacts, to review unknown errors.

[1]: https://docs.github.com/en/actions/configuring-and-managing-workflows/creating-and-storing-encrypted-secrets

[2]: https://lftp.yar.ru/lftp-man.html
