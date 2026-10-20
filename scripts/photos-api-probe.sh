#!/bin/sh
# Read-only Synology Photos API probe.
# This script never calls delete, index_add, or reindex.
# Usage:
#   DSM_URL='https://192.0.2.10:5001' SID='...' ./scripts/photos-api-probe.sh
# Optional:
#   FOLDER_ID=338 LIMIT=1
set -u

: "${DSM_URL:?Set DSM_URL to the DSM base URL, e.g. https://nas:5001}"
: "${SID:?Set SID to an authenticated DSM API session ID}"

API_ROOT="${DSM_URL%/}/webapi"
LIMIT="${LIMIT:-1}"
FOLDER_ID="${FOLDER_ID:-}"

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required" >&2
    exit 1
fi

request()
{
    LABEL="$1"
    shift
    printf '\n===== %s =====\n' "$LABEL"
    curl -k -sS --get "${API_ROOT}/entry.cgi" \
        --data-urlencode "api=$1" \
        --data-urlencode "version=$2" \
        --data-urlencode "method=$3" \
        "${@:4}" 2>/dev/null
    printf '\n'
}

# POSIX sh does not support array-style positional expansion. Keep each
# request explicit so this remains compatible with DSM's /bin/sh.
printf '%s\n' '===== API metadata ====='
curl -k -sS --get "${API_ROOT}/query.cgi" \
    --data-urlencode 'api=SYNO.API.Info' \
    --data-urlencode 'version=1' \
    --data-urlencode 'method=query' \
    --data-urlencode 'query=SYNO.FotoTeam.Browse.Item,SYNO.FotoTeam.Browse.Folder,SYNO.FotoTeam.Index,SYNO.FotoTeam.BackgroundTask.File,SYNO.Foto.BackgroundTask.Info'
printf '\n'

printf '%s\n' '===== Browse.Item.list (read-only) ====='
if [ -n "$FOLDER_ID" ]; then
    curl -k -sS --get "${API_ROOT}/entry.cgi" \
        --data-urlencode 'api=SYNO.FotoTeam.Browse.Item' \
        --data-urlencode 'version=7' \
        --data-urlencode 'method=list' \
        --data-urlencode "folder_id=$FOLDER_ID" \
        --data-urlencode "limit=$LIMIT" \
        --data-urlencode 'offset=0' \
        --data-urlencode "_sid=$SID"
else
    curl -k -sS --get "${API_ROOT}/entry.cgi" \
        --data-urlencode 'api=SYNO.FotoTeam.Browse.Item' \
        --data-urlencode 'version=7' \
        --data-urlencode 'method=list' \
        --data-urlencode "limit=$LIMIT" \
        --data-urlencode 'offset=0' \
        --data-urlencode "_sid=$SID"
fi
printf '\n'

printf '%s\n' '===== Browse.Folder.list (read-only) ====='
curl -k -sS --get "${API_ROOT}/entry.cgi" \
    --data-urlencode 'api=SYNO.FotoTeam.Browse.Folder' \
    --data-urlencode 'version=2' \
    --data-urlencode 'method=list' \
    --data-urlencode "limit=$LIMIT" \
    --data-urlencode 'offset=0' \
    --data-urlencode "_sid=$SID"
printf '\n'

printf '%s\n' '===== Index.get (read-only) ====='
curl -k -sS --get "${API_ROOT}/entry.cgi" \
    --data-urlencode 'api=SYNO.FotoTeam.Index' \
    --data-urlencode 'version=1' \
    --data-urlencode 'method=get' \
    --data-urlencode "_sid=$SID"
printf '\n'

printf '\n%s\n' 'Probe finished. Responses are diagnostic only; no catalog changes were requested.'
