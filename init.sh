#!/bin/sh
# TODO: Add list of excluded delete files in two formats, string separated by space and file.

FTP_SETTINGS="set ftp:ssl-allow ${INPUT_SSL_ALLOW};" \
  "set ftp:use-feat ${INPUT_USE_FEAT};" \
  "set net:max-retries ${INPUT_MAX_RETRIES};"
MIRROR_COMMAND="mirror --continue --reverse --no-symlinks"

echo "=== Environment variables ==="
echo "INPUT_SERVER: ${INPUT_SERVER}"
echo "INPUT_USER: ${INPUT_USER}"
echo "INPUT_PASSWORD: ${INPUT_PASSWORD}"
echo "INPUT_SSL_ALLOW: ${INPUT_SSL_ALLOW}"
echo "INPUT_USE_FEAT: ${INPUT_USE_FEAT}"
echo "INPUT_MAX_RETRIES : ${INPUT_MAX_RETRIES}"
echo "INPUT_DELETE: ${INPUT_DELETE}"
echo "INPUT_LOCAL_DIR: ${INPUT_LOCAL_DIR}"
echo "INPUT_REMOTE_DIR: ${INPUT_REMOTE_DIR}"
echo ""
echo "=== Current location ==="
pwd
echo ""
echo "=== List this directory ==="
ls -lha
echo ""

if [ -z "${INPUT_LOCAL_DIR}" ]; then
  INPUT_LOCAL_DIR="./"
else
  INPUT_LOCAL_DIR="./${INPUT_LOCAL_DIR}/"
fi

if [ -z "${INPUT_REMOTE_DIR}" ]; then
  INPUT_REMOTE_DIR="./"
else
  INPUT_REMOTE_DIR="./${INPUT_REMOTE_DIR}/"
fi

if [ "${INPUT_DELETE}" = "true" ]; then
  MIRROR_COMMAND="${MIRROR_COMMAND} --delete"
fi

echo "=== Directories ==="
echo "INPUT_LOCAL_DIR: ${INPUT_LOCAL_DIR}"
echo "INPUT_REMOTE_DIR: ${INPUT_REMOTE_DIR}"
echo ""
echo "=== List local directory | ${INPUT_LOCAL_DIR} ==="
ls -lha "${INPUT_LOCAL_DIR}"
echo ""
echo "=== LFTP ==="
echo "lftp -> ${FTP_SETTINGS} ${MIRROR_COMMAND} ${INPUT_LOCAL_DIR} ${INPUT_REMOTE_DIR}"
echo ""
echo "=== * NOTE * ==="
echo "The upload should be fast depends how many files and what size they have."
echo "If the process take for several minutes, please stop the job and run it again."
echo ""

lftp \
  --debug \
  -u "${INPUT_USER}","${INPUT_PASSWORD}" \
  "${INPUT_SERVER}" \
  -e "${FTP_SETTINGS} ${MIRROR_COMMAND} ${INPUT_LOCAL_DIR} ${INPUT_REMOTE_DIR}; quit;"

echo ""
echo "=============================="
echo "=   FTP UPLOADED FINISHED!   ="
echo "=============================="
