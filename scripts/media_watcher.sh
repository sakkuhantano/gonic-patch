#!/bin/bash

# Start each watcher run with clean logs. Supervisor has already opened these
# files for stdout/stderr; truncate them before emitting startup messages.
WATCHER_LOG_DIR="/var/log/app_logs"
mkdir -p "$WATCHER_LOG_DIR"
: > "$WATCHER_LOG_DIR/watcher_stdout.log"
: > "$WATCHER_LOG_DIR/watcher_stderr.log"

DSM_IP="192.168.10.3"
DSM_USER="hendry"
DSM_SYNOINDEX="/usr/syno/bin/synoindex"
DSM_PHOTO_INDEX="/var/packages/SynologyPhotos/target/usr/bin/synofoto-bin-index-tool"
DSM_API_URL="http://${DSM_IP}:5000/webapi"
DSM_API_USER="${DSM_API_USER:-$DSM_USER}"
DSM_API_PASSWORD="${DSM_API_PASSWORD:-}"
DSM_API_CONFIG="${DSM_API_CONFIG:-/hostconfig/media_watcher.conf}"

if [[ -r "$DSM_API_CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$DSM_API_CONFIG"
fi
PHOTO_API_TMP=""
PHOTO_API_COOKIE=""
PHOTO_API_TOKEN=""

photo_api_init() {
    # Do not leave a stale cookie/token marker after a failed login; the next
    # cleanup attempt must authenticate again instead of using an empty token.
    PHOTO_API_COOKIE=""
    PHOTO_API_TOKEN=""
    [[ -n "$DSM_API_PASSWORD" ]] || { echo "[PHOTO-API-ERROR] Set DSM_API_PASSWORD or configure $DSM_API_CONFIG" >&2; return 1; }
    command -v curl >/dev/null 2>&1 || { echo "[PHOTO-API-ERROR] curl unavailable" >&2; return 1; }
    command -v jq >/dev/null 2>&1 || { echo "[PHOTO-API-ERROR] jq unavailable; cleanup fails closed" >&2; return 1; }
    PHOTO_API_TMP=$(mktemp -d /tmp/media-watcher-api.XXXXXX) || return 1
    chmod 700 "$PHOTO_API_TMP"
    PHOTO_API_COOKIE="$PHOTO_API_TMP/cookies.txt"
    local login
    login=$(curl -fsS --connect-timeout 10 --max-time 30 -c "$PHOTO_API_COOKIE" -b "$PHOTO_API_COOKIE" \
        -X POST "$DSM_API_URL/auth.cgi" \
        --data-urlencode 'api=SYNO.API.Auth' --data-urlencode 'version=6' --data-urlencode 'method=login' \
        --data-urlencode "account=$DSM_API_USER" --data-urlencode "passwd=$DSM_API_PASSWORD" \
        --data-urlencode 'session=SynologyPhotos' --data-urlencode 'format=cookie' --data-urlencode 'enable_syno_token=yes') || {
        echo "[PHOTO-API-ERROR] DSM login request failed" >&2; return 1; }
    [[ "$(jq -r '.success // false' <<<"$login")" == "true" ]] || {
        echo "[PHOTO-API-ERROR] DSM login rejected: $(jq -r '.error.code // "unknown"' <<<"$login")" >&2; return 1; }
    PHOTO_API_TOKEN=$(jq -r '.data.SynoToken // empty' <<<"$login")
    [[ -n "$PHOTO_API_TOKEN" ]] || { echo "[PHOTO-API-ERROR] SynoToken missing" >&2; return 1; }
}
photo_api_call() {
    local api="$1" version="$2" method="$3"
    shift 3
    local response
    response=$(curl -fsS --connect-timeout 10 --max-time 45 -b "$PHOTO_API_COOKIE" -c "$PHOTO_API_COOKIE" \
        -X POST "$DSM_API_URL/entry.cgi" --data-urlencode "api=$api" \
        --data-urlencode "version=$version" --data-urlencode "method=$method" \
        --data-urlencode "SynoToken=$PHOTO_API_TOKEN" "$@") || return 1
    [[ "$(jq -r '.success // false' <<<"$response")" == "true" ]] || {
        echo "[PHOTO-API-ERROR] $api.$method failed: $(jq -c '.error // .' <<<"$response")" >&2; return 1; }
    printf '%s' "$response"
}
photo_api_cleanup_path() {
    local oldpath="$1" is_dir="$2" listing ids id relpath parent filename relparent folder_listing folder_ids folder_id item_listing response task
    [[ -n "$PHOTO_API_COOKIE" ]] || photo_api_init || return 1
    if [[ "$is_dir" == "1" ]]; then
        relpath="${oldpath#/volume1/photo}"; relpath="${relpath%/}"
        listing=$(photo_api_call 'SYNO.FotoTeam.Browse.Folder' 2 list --data-urlencode 'limit=1000' --data-urlencode 'offset=0') || return 1
        ids=$(jq -c --arg p "$relpath" '[.data.list[]? | select((.["folder.name"] // .name // .public.folder.name // "") == $p) | (.["folder.id"] // .id // .folder_id // .public.folder.id)] | map(select(. != null)) | unique' <<<"$listing")
        [[ "$(jq 'length' <<<"$ids")" -eq 1 ]] || { echo "[PHOTO-API-ERROR] folder ID not unique for $oldpath: $ids; refusing delete" >&2; return 1; }
        id=$(jq -r '.[0]' <<<"$ids")
        response=$(photo_api_call 'SYNO.FotoTeam.BackgroundTask.File' 1 delete --data-urlencode 'item_id=[]' --data-urlencode "folder_id=[$id]") || return 1
    else
        parent="${oldpath%/*}"; filename="${oldpath##*/}"; relparent="${parent#/volume1/photo}"
        [[ -n "$relparent" ]] || relparent="/"
        folder_listing=$(photo_api_call 'SYNO.FotoTeam.Browse.Folder' 2 list --data-urlencode 'limit=1000' --data-urlencode 'offset=0') || return 1
        folder_ids=$(jq -c --arg p "$relparent" '[.data.list[]? | select((.["folder.name"] // .name // .public.folder.name // "") == $p) | (.["folder.id"] // .id // .folder_id // .public.folder.id)] | map(select(. != null)) | unique' <<<"$folder_listing")
        [[ "$(jq 'length' <<<"$folder_ids")" -eq 1 ]] || { echo "[PHOTO-API-ERROR] parent folder not unique for $parent: $folder_ids; refusing delete" >&2; return 1; }
        folder_id=$(jq -r '.[0]' <<<"$folder_ids")
        item_listing=$(photo_api_call 'SYNO.FotoTeam.Browse.Item' 7 list --data-urlencode "folder_id=$folder_id" --data-urlencode 'limit=1000' --data-urlencode 'offset=0') || return 1
        ids=$(jq -c --arg n "$filename" '[.data.list[]? | select((.["item.name"] // .filename // .name // .["item.filename"] // "") == $n) | (.["item.id"] // .id // .item_id)] | map(select(. != null)) | unique' <<<"$item_listing")
        [[ "$(jq 'length' <<<"$ids")" -eq 1 ]] || { echo "[PHOTO-API-ERROR] item ID not unique for $oldpath: $ids; refusing delete" >&2; return 1; }
        id=$(jq -r '.[0]' <<<"$ids")
        response=$(photo_api_call 'SYNO.FotoTeam.BackgroundTask.File' 1 delete --data-urlencode "item_id=[$id]" --data-urlencode 'folder_id=[]') || return 1
    fi
    task=$(jq -r '.data.task_id // .data.id // empty' <<<"$response")
    echo "[PHOTO-API-DELETE-QUEUED] path=$oldpath id=$id task=${task:-unknown}"
}

MONITOR_DIRS=(
    "/media/Music"
    "/media/Photo"
    "/surveillance"
)

# Regex-escaped directory names excluded anywhere in monitored trees.
# Add/remove entries here; escape regex metacharacters such as '.' with '\\'.
IGNORE_DIR_NAMES=(
    "@eaDir"
    "@SSRECMETA"
    '\.@thumb'
    '\.@__thumb'
    "@SynoResource"
    '\.thumbnails'
    "thumbnails"
    "thumbs"
)

# File-name patterns excluded anywhere in monitored trees.
# These are regular expressions (not shell globs).
IGNORE_FILE_PATTERNS=(
    'SYNOPHOTO[^/]*'
    '\.DS_Store'
    '[Tt]humbs\.db'
    'desktop\.ini'
    '\._[^/]*'
    '[^/]*\.(thumb|thumbnail)'
)

# Use the known-working explicit regex rather than constructing it dynamically.
# Keep this aligned with the previously working watcher filter.
EXCLUDE_RE='(^|/)(@eaDir|@SSRECMETA|\.@thumb|\.@__thumb|@SynoResource|\.thumbnails|thumbnails|thumbs)(/|$)|(^|/)(SYNOPHOTO[^/]*|\.DS_Store|[Tt]humbs\.db|desktop\.ini|\._[^/]*|[^/]*\.(thumb|thumbnail))$'

EXISTING_DIRS=()

for dir in "${MONITOR_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        EXISTING_DIRS+=("$dir")
        echo "[START] Monitor: $dir"
    else
        echo "[WARNING] Folder tidak tersedia: $dir" >&2
    fi
done

if [ "${#EXISTING_DIRS[@]}" -eq 0 ]; then
    echo "[ERROR] Tidak ada folder yang bisa dimonitor." >&2
    exit 1
fi

RUN_DIR=$(mktemp -d /tmp/media-watcher.XXXXXX) || {
    echo "[ERROR] Gagal membuat direktori sementara." >&2
    exit 1
}

FIFO="$RUN_DIR/events"

mkfifo "$FIFO" || {
    rmdir "$RUN_DIR"
    echo "[ERROR] Gagal membuat FIFO." >&2
    exit 1
}

INOTIFY_PID=""

cleanup() {
    if [ -n "$INOTIFY_PID" ] &&
       kill -0 "$INOTIFY_PID" 2>/dev/null; then
        kill -TERM "$INOTIFY_PID" 2>/dev/null
        wait "$INOTIFY_PID" 2>/dev/null
    fi

    rm -rf "$RUN_DIR"
    [[ -n "$PHOTO_API_TMP" ]] && rm -rf "$PHOTO_API_TMP"
}

trap cleanup EXIT
trap 'exit 1' TERM INT HUP

echo "[START] Filter metadata aktif."
echo "[START] Ignore directories: ${IGNORE_DIR_NAMES[*]}"
echo "[START] Satu inotifywait untuk indexing dan permission pada mount 9P."

inotifywait -m -r \
    --exclude "$EXCLUDE_RE" \
    -e create,moved_from,moved_to,delete,close_write \
    --format '%e|%w%f' \
    "${EXISTING_DIRS[@]}" > "$FIFO" &

INOTIFY_PID=$!

while IFS='|' read -r event filepath; do
    echo "[INOTIFY-EVENT] $event|$filepath"
    case "$filepath" in
        /media/Music/*)
            DSM_FILEPATH="/volume1/music${filepath#/media/Music}"
            ;;
        /media/Photo/*)
            DSM_FILEPATH="/volume1/photo${filepath#/media/Photo}"
            ;;
        /surveillance/*)
            DSM_FILEPATH="/volume1/surveillance${filepath#/surveillance}"
            ;;
        *)
            continue
            ;;
    esac

    # Defensive metadata exclusion: inotifywait --exclude is not always reliable
    # for events crossing the QNAP/DSM 9P mount. Never chmod, index, or delete Photos
    # records for Synology thumbnail/metadata paths.
    if [[ "$filepath" =~ (^|/)(@eaDir|@SSRECMETA|\.@thumb|\.@__thumb|@SynoResource|\.thumbnails|thumbnails|thumbs)(/|$) ]] ||
       [[ "$filepath" =~ (^|/)(SYNOPHOTO[^/]*|\.DS_Store|[Tt]humbs\.db|desktop\.ini|\._[^/]*|[^/]*\.(thumb|thumbnail))$ ]]; then
        continue
    fi

    # Normalize permissions on DSM-created entries exposed through the QNAP bind mount.
    # Clear POSIX ACL entries when setfacl is available; chmod alone may not override
    # an inherited ACL that denies writes from QNAP SMB clients.
    if [[ "$event" != *DELETE* ]] &&
       [[ "$event" == *CREATE* || "$event" == *MOVED_TO* || "$event" == *CLOSE_WRITE* ]]; then
        if [[ -L "$filepath" ]]; then
            :
        elif [[ -d "$filepath" ]]; then
            if command -v setfacl >/dev/null 2>&1; then
                if ! setfacl -b -- "$filepath"; then
                    echo "[PERM-WARNING] setfacl -b gagal: $filepath" >&2
                fi
            fi
            if ! chmod 777 -- "$filepath"; then
                echo "[PERM-ERROR] chmod 777 gagal: $filepath" >&2
            fi
        elif [[ -f "$filepath" ]]; then
            if command -v setfacl >/dev/null 2>&1; then
                if ! setfacl -b -- "$filepath"; then
                    echo "[PERM-WARNING] setfacl -b gagal: $filepath" >&2
                fi
            fi
            if ! chmod 666 -- "$filepath"; then
                echo "[PERM-ERROR] chmod 666 gagal: $filepath" >&2
            fi
        fi
    fi

    # Surveillance Station needs permission/ACL normalization only; keep it quiet
    # during normal operation and never pass its files to synoindex.
    if [[ "$filepath" == /surveillance/* ]]; then
        continue
    fi

    IS_DIR=0
    if [[ "$event" == *ISDIR* ]]; then
        IS_DIR=1
    fi

    # Files may emit CREATE before writing finishes. For Photos, use the
    # Synology Photos basic indexer after CLOSE_WRITE or MOVED_TO.
    if [[ "$event" != *DELETE* && "$event" != *MOVED_FROM* &&
          "$IS_DIR" -eq 0 && "$event" == *CREATE* &&
          "$event" != *MOVED_TO* && "$event" != *CLOSE_WRITE* ]]; then
        continue
    fi

    if [[ "$filepath" == /media/Photo/* ]]; then
        if [[ "$event" == *MOVED_FROM* || "$event" == *DELETE* ]]; then
            echo "[PHOTO-API-DELETE] $DSM_FILEPATH"
            if ! photo_api_cleanup_path "$DSM_FILEPATH" "$IS_DIR"; then
                echo "[ERROR] Synology Photos cleanup failed; source not confirmed clean: $DSM_FILEPATH" >&2
            fi
            continue
        fi
        if [[ "$event" == *CLOSE_WRITE* || "$event" == *MOVED_TO* ||
              ( "$IS_DIR" -eq 1 && "$event" == *CREATE* ) ]]; then
            printf -v REMOTE_PHOTO_INDEX_CMD 'sudo -n %q -t basic -i %q' "$DSM_PHOTO_INDEX" "$DSM_FILEPATH"
            if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
                "${DSM_USER}@${DSM_IP}" "$REMOTE_PHOTO_INDEX_CMD" </dev/null; then
                echo "[ERROR] synofoto basic gagal: $DSM_FILEPATH" >&2
            else
                echo "[PHOTO-INDEX-BASIC] $DSM_FILEPATH"
            fi
        fi
        continue
    fi

    # Keep existing Music indexing behavior unchanged.
    if [[ "$event" == *MOVED_FROM* || "$event" == *DELETE* ]]; then
        if [[ "$IS_DIR" -eq 1 ]]; then ACTION="-D"; LABEL="INDEX-DELETE-DIR";
        else ACTION="-d"; LABEL="INDEX-DELETE"; fi
    else
        if [[ "$IS_DIR" -eq 1 ]]; then ACTION="-A"; LABEL="INDEX-ADD-DIR";
        else ACTION="-a"; LABEL="INDEX-ADD"; fi
    fi

    echo "[$LABEL] $DSM_FILEPATH"
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "${DSM_USER}@${DSM_IP}" "$DSM_SYNOINDEX $ACTION \"$DSM_FILEPATH\"" </dev/null; then
        echo "[ERROR] Perintah synoindex gagal: $DSM_FILEPATH (aksi=$ACTION)" >&2
    fi

done < "$FIFO"

wait "$INOTIFY_PID"
RC=$?

echo "[ERROR] inotifywait berhenti (exit=$RC)." >&2
exit 1
