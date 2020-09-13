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
      - name: Upload public_html via FTP
        uses: airvzxf/ftp-deployment-action@v1.0-alpha.1
        with:
          server: ${{ secrets.FTP_SERVER }}
          user: ${{ secrets.FTP_USERNAME }}
          password: ${{ secrets.FTP_PASSWORD }}
          delete: "true"
          local_dir: "public_html"
```

## Settings

Option | Description | Required | Default | Example
---    | ---         | ---      | ---     | ---
server | FTP Server | true | N/A | rovisoft.net
user | FTP Username | true | N/A | myself&#64;rovisoft.net
password | FTP Password | true | N/A | ExampleOnlyAlphabets
ssl_allow | Allow SSL encryption | false | false | N/A
use_feat | Determining what extended features the FTP server supports | false | false | N/A
delete | Delete all the files inside of the remote directory before the upload process | false | false | N/A
local_dir | Local directory | false | "" | "public_html"
remote_dir | Remote directory | false | "" | "www/user/home"


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
