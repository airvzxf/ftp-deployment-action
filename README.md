# FTP Deployment: Github Action

This GitHub action copy the files via FTP from your Git project to your server in a specific path.


## Usage Example

Add this code in `.github/workflows/your_action.yml`.

More about Github "secrets" in this article:
[Creating and storing encrypted secrets][1].

```yaml
name: CI -> Deploy to My website
on:
  push:
    branches: [ master, Development ]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      # Here is the deployment action
      - name: Upload from public_html via FTP
        uses: airvzxf/ftp-deployment-action@latest
        with:
          server: ${{ secrets.FTP_SERVER }}
          user: ${{ secrets.FTP_USERNAME }}
          password: ${{ secrets.FTP_PASSWORD }}
          delete: "false"
          local_dir: "./public_html"
```

Optional, you can get the live version which has the last commits using this:
`uses: airvzxf/ftp-deployment-action@master`


## Settings

Usually the 0 (zero) values means unlimited or infinite.

Option | Description | Required | Default | Example
---    | ---         | ---      | ---     | ---
server | FTP Server. | Yes | N/A | rovisoft.net
user | FTP Username. | Yes | N/A | myself@rovisoft.net
password | FTP Password. | Yes | N/A | ExampleOnlyAlphabets
delete | Delete all the files inside of the remote directory before the upload process. | No | false | N/A
local_dir | Local directory. | No | "./" | "./public_html"
remote_dir | Remote directory. | No | "./" | "/www/user/home"
ftp_ssl_allow | FTP - Allow SSL encryption | No | false | N/A
ftp_use_feat | FTP - FEAT: Determining what extended features the FTP server supports. | No | false | N/A
ftp_nop_interval | FTP - Delay in seconds between NOOP commands when downloading tail of a file. | No | 2 | N/A
net_max_retries | NET - Maximum number of operation without success.<br> 0 unlimited.<br> 1 no retries. | No | 1 | N/A
net_persist_retries | NET - Ignore hard errors.<br> When reply 5xx errors or there is too many users. | No | 5 | N/A
net_timeout | NET - Sets the network protocol timeout. | No | 15s | N/A
dns_max_retries | DNS - 0 no limit trying to lookup an address otherwise try only this number of times. | No | 8 | N/A
dns_fatal_timeout | DNS - Time for DNS queries.<br> Set to "never" to disable. | No | 10s | N/A

More information in the official site for [lftp - Manual pages][2]

Example with NO DEFAULT settings:

```yaml
name: CI -> Deploy to My website
on:
  push:
    branches: [ master, Development ]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      # Here is the deployment action
      - name: Upload from public_html via FTP
        uses: airvzxf/ftp-deployment-action@latest
        with:
          server: ${{ secrets.FTP_SERVER }}
          user: ${{ secrets.FTP_USERNAME }}
          password: ${{ secrets.FTP_PASSWORD }}
          delete: "true"
          local_dir: "./public_html"
          remote_dir: "/www/sub-domain/games/myself"
          ftp_ssl_allow: "true"
          ftp_use_feat: "true"
          ftp_nop_interval: "6"
          net_max_retries: "0"
          net_persist_retries: "7"
          net_timeout: "18s"
          dns_max_retries: "9"
          dns_fatal_timeout: "never"
```

## NOTES
This Alpha version is for personal usage but in a short future will be robust for any Github developer.

Main features:
- Copy all the files inside of the specific folder from your Github repository to the specific folder in your server.
- Option to delete all the files in the specific remote folder before the upload.
- Use Alpine container means small size and faster creation of the container.
- Show messages in the console logs for every executed command.

TODOs:
- Add options for exclude delete files.
- Add the property/option for the upload the Symlinks.


[1]: https://docs.github.com/en/actions/configuring-and-managing-workflows/creating-and-storing-encrypted-secrets
[2]: http://lftp.tech/lftp-man.html