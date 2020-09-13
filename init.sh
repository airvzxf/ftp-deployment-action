#!/bin/sh
# TODO: Add list of excluded delete files in two formats, string separated by space and file.

FTP_SETTINGS="set ftp:ssl-allow ${INPUT_SSL_ALLOW}; set ftp:use-feat ${INPUT_USE_FEAT};"
MIRROR_COMMAND="mirror --continue --reverse --dereference"

echo "=== Environment variables ==="
echo "INPUT_SERVER: ${INPUT_SERVER}"
echo "INPUT_USER: ${INPUT_USER}"
echo "INPUT_PASSWORD: ${INPUT_PASSWORD}"
echo "INPUT_SSL_ALLOW: ${INPUT_SSL_ALLOW}"
echo "INPUT_USE_FEAT: ${INPUT_USE_FEAT}"
echo "INPUT_DELETE: ${INPUT_DELETE}"
echo "INPUT_LOCAL_DIR: ${INPUT_LOCAL_DIR}"
echo "INPUT_REMOTE_DIR: ${INPUT_REMOTE_DIR}"
echo ""
echo "=== Current location==="
pwd
echo ""
echo "=== List this directory ==="
ls -lha
echo ""

if [ -z "${INPUT_REMOTE_DIR}" ]; then
  INPUT_REMOTE_DIR="./"
else
  INPUT_REMOTE_DIR="./${INPUT_REMOTE_DIR}/"
  echo "=== List local directory ==="
  ls -lha "${INPUT_REMOTE_DIR}"
  echo ""
fi

if [ "${INPUT_DELETE}" = "true" ]; then
  MIRROR_COMMAND="${MIRROR_COMMAND} --delete"
fi

lftp \
  -u "${INPUT_USER}","${INPUT_PASSWORD}" \
  "${INPUT_SERVER}" \
  -e "${FTP_SETTINGS} ${MIRROR_COMMAND} ${INPUT_LOCAL_DIR}/ ${INPUT_REMOTE_DIR}; quit;"

echo ""
echo "FTP UPLOADED FINISHED!"
