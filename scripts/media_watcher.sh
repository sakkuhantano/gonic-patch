#!/bin/bash

DSM_IP="192.168.10.3"
DSM_USER="hendry"
DSM_SYNOINDEX="/usr/syno/bin/synoindex"
DSM_PHOTO_INDEX="/var/packages/SynologyPhotos/target/usr/bin/synofoto-bin-index-tool"

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
    '\\.@thumb'
    '\\.@__thumb'
    "@SynoResource"
    '\\.thumbnails'
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

# Build the inotifywait regex from the lists above.
IGNORE_DIR_ALT=""
for name in "${IGNORE_DIR_NAMES[@]}"; do
    [[ -n "$IGNORE_DIR_ALT" ]] && IGNORE_DIR_ALT+="|"
    IGNORE_DIR_ALT+="$name"
done

IGNORE_FILE_ALT=""
for pattern in "${IGNORE_FILE_PATTERNS[@]}"; do
    [[ -n "$IGNORE_FILE_ALT" ]] && IGNORE_FILE_ALT+="|"
    IGNORE_FILE_ALT+="($pattern)"
done

EXCLUDE_RE=""
if [[ -n "$IGNORE_DIR_ALT" ]]; then
    EXCLUDE_RE="(^|/)($IGNORE_DIR_ALT)(/|$)"
fi
if [[ -n "$IGNORE_FILE_ALT" ]]; then
    [[ -n "$EXCLUDE_RE" ]] && EXCLUDE_RE+="|"
    EXCLUDE_RE+="(^|/)($IGNORE_FILE_ALT)$"
fi

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
            if [[ "$IS_DIR" -eq 1 ]]; then ACTION="-D"; LABEL="PHOTO-INDEX-DELETE-DIR";
            else ACTION="-d"; LABEL="PHOTO-INDEX-DELETE"; fi
            echo "[$LABEL] $DSM_FILEPATH"
            if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
                "${DSM_USER}@${DSM_IP}" "$DSM_SYNOINDEX $ACTION \"$DSM_FILEPATH\"" </dev/null; then
                echo "[ERROR] synoindex cleanup gagal: $DSM_FILEPATH (aksi=$ACTION)" >&2
            fi
            continue
        fi

        if [[ "$event" == *CLOSE_WRITE* || "$event" == *MOVED_TO* ||
              ( "$IS_DIR" -eq 1 && "$event" == *CREATE* ) ]]; then
            if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
                "${DSM_USER}@${DSM_IP}" "\"$DSM_PHOTO_INDEX\" -t basic -i \"$DSM_FILEPATH\"" </dev/null; then
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
