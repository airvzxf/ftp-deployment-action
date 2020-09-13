#!/bin/bash

# TODO: Add list of excluded delete files in two formats, string separated by space and file.

INPUT_SERVER=rovisoft.net
INPUT_USER=saint_seiya_kotz@rovisoft.net
INPUT_PASSWORD=OpYfgb5coLyd
INPUT_SSL_ALLOW=false
INPUT_USE_FEAT=false
INPUT_DELETE=true
#INPUT_LOCAL_DIR=""
INPUT_REMOTE_DIR=""

FTP_SETTINGS='set ftp:ssl-allow '${INPUT_SSL_ALLOW}'; set ftp:use-feat '${INPUT_USE_FEAT}';'
FILE_LIST=remote_ftp_list_$(date "+%s").tmp

if [ -z "${INPUT_REMOTE_DIR}" ]; then
  INPUT_REMOTE_DIR="./"
else
  INPUT_REMOTE_DIR="./${INPUT_REMOTE_DIR}/"
fi

if [ "${INPUT_DELETE}" = "true" ]; then
  echo "Deleting from the Server the files and directories with 'lftp'."
  echo -e " Path: ${INPUT_REMOTE_DIR}\n"

  rm -f "${FILE_LIST}"

  lftp \
    -u ${INPUT_USER},${INPUT_PASSWORD} \
    ${INPUT_SERVER} \
    -e "${FTP_SETTINGS} renlist > ${FILE_LIST}; quit;"

  sed -i 's/^\.$/..\n/g' "${FILE_LIST}"
  sed -i ':begin;N;$!b begin;s/\.\.\n//gm' "${FILE_LIST}"

  DELETE_ITEMS=""
  while read -r LINE; do
    if [ -n "$LINE" ]; then
      DELETE_ITEMS=${DELETE_ITEMS}"${INPUT_REMOTE_DIR}$LINE "
    fi
  done <"${FILE_LIST}"

  rm -f "${FILE_LIST}"

  lftp \
    -u ${INPUT_USER},${INPUT_PASSWORD} \
    ${INPUT_SERVER} \
    -e "${FTP_SETTINGS} glob rm -rf ${DELETE_ITEMS} 2>/dev/null; quit;"
fi

pwd
ls -lha .
