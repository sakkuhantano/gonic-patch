#!/bin/sh
# Read-only Synology Photos API probe. Does not alter the Photos catalog.
# Run on any machine with curl:
#   DSM_URL='https://your-vDSM-host:5001' sh scripts/photos-api-probe.sh
# Optional: FOLDER_ID=338 LIMIT=1
set -u

: "${DSM_URL:?Set DSM_URL, e.g. https://192.168.1.20:5001}"

API_ROOT="${DSM_URL%/}/webapi"
LIMIT="${LIMIT:-1}"
FOLDER_ID="${FOLDER_ID:-}"

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required" >&2
    exit 1
fi

printf 'DSM username: '
IFS= read -r DSM_USER
printf 'DSM password: '
stty -echo 2>/dev/null || true
IFS= read -r DSM_PASS
stty echo 2>/dev/null || true
printf '\n'

if [ -z "$DSM_USER" ] || [ -z "$DSM_PASS" ]; then
    echo "ERROR: username/password cannot be empty" >&2
    unset DSM_PASS
    exit 1
fi

LOGIN_RESPONSE=$(curl -k -sS --get "${API_ROOT}/auth.cgi" \
    --data-urlencode 'api=SYNO.API.Auth' \
    --data-urlencode 'version=7' \
    --data-urlencode 'method=login' \
    --data-urlencode "account=$DSM_USER" \
    --data-urlencode "passwd=$DSM_PASS" \
    --data-urlencode 'session=FileStation' \
    --data-urlencode 'format=sid')
unset DSM_PASS

SID=$(printf '%s' "$LOGIN_RESPONSE" | sed -n 's/.*"sid"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
if [ -z "$SID" ]; then
    echo "ERROR: DSM login did not return a SID. Raw response:" >&2
    printf '%s\n' "$LOGIN_RESPONSE" >&2
    unset LOGIN_RESPONSE
    exit 1
fi
unset LOGIN_RESPONSE
echo "Login berhasil; menjalankan pemeriksaan baca-saja."

printf '\n%s\n' '===== API metadata ====='
curl -k -sS --get "${API_ROOT}/query.cgi" \
    --data-urlencode 'api=SYNO.API.Info' \
    --data-urlencode 'version=1' \
    --data-urlencode 'method=query' \
    --data-urlencode 'query=SYNO.FotoTeam.Browse.Item,SYNO.FotoTeam.Browse.Folder,SYNO.FotoTeam.Index,SYNO.FotoTeam.BackgroundTask.File,SYNO.Foto.BackgroundTask.Info'
printf '\n'

printf '\n%s\n' '===== Browse.Item.list (read-only) ====='
set -- --get "${API_ROOT}/entry.cgi" \
    --data-urlencode 'api=SYNO.FotoTeam.Browse.Item' \
    --data-urlencode 'version=7' \
    --data-urlencode 'method=list' \
    --data-urlencode "limit=$LIMIT" \
    --data-urlencode 'offset=0' \
    --data-urlencode "_sid=$SID"
if [ -n "$FOLDER_ID" ]; then
    set -- "$@" --data-urlencode "folder_id=$FOLDER_ID"
fi
curl -k -sS "$@"
printf '\n'

printf '\n%s\n' '===== Browse.Folder.list (read-only) ====='
curl -k -sS --get "${API_ROOT}/entry.cgi" \
    --data-urlencode 'api=SYNO.FotoTeam.Browse.Folder' \
    --data-urlencode 'version=2' \
    --data-urlencode 'method=list' \
    --data-urlencode "limit=$LIMIT" \
    --data-urlencode 'offset=0' \
    --data-urlencode "_sid=$SID"
printf '\n'

printf '\n%s\n' '===== Index.get (read-only) ====='
curl -k -sS --get "${API_ROOT}/entry.cgi" \
    --data-urlencode 'api=SYNO.FotoTeam.Index' \
    --data-urlencode 'version=1' \
    --data-urlencode 'method=get' \
    --data-urlencode "_sid=$SID"
printf '\n'

# Best-effort logout; no catalog mutation.
curl -k -sS --get "${API_ROOT}/auth.cgi" \
    --data-urlencode 'api=SYNO.API.Auth' \
    --data-urlencode 'version=7' \
    --data-urlencode 'method=logout' \
    --data-urlencode 'session=FileStation' \
    --data-urlencode "_sid=$SID" >/dev/null 2>&1 || true
unset SID

printf '\n%s\n' 'Probe selesai. Tidak ada file atau entri katalog yang diubah.'
