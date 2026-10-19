#!/bin/bash

DSM_IP="192.168.10.3"
DSM_USER="hendry"
DSM_SYNOINDEX="/usr/syno/bin/synoindex"

MONITOR_DIRS=(
    "/media/Music"
    "/media/Photo"
)

# Ignore Synology-generated metadata, thumbnails, and common OS sidecar files.
EXCLUDE_RE='(^|/)(@eaDir|\.@thumb|\.@__thumb|@SynoResource|\.thumbnails|thumbnails|thumbs)(/|$)|(^|/)(SYNOPHOTO[^/]*|\.DS_Store|[Tt]humbs\.db|desktop\.ini|\._[^/]*|[^/]*\.(thumb|thumbnail))

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

echo "[START] Filter metadata Synology aktif."
echo "[START] Satu inotifywait untuk indexing dan permission pada mount 9P."

inotifywait -m -r \
    --exclude "$EXCLUDE_RE" \
    -e create,moved_to,delete,close_write \
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
        *)
            continue
            ;;
    esac

    # Fix permissions for DSM-originated changes visible through the 9P bind mount.
    # These operations do not copy files and do not trigger synoindex themselves.
    if [[ "$event" != *DELETE* ]] &&
       [[ "$event" == *CREATE* || "$event" == *MOVED_TO* || "$event" == *CLOSE_WRITE* ]]; then
        if [[ -L "$filepath" ]]; then
            :
        elif [[ -d "$filepath" ]]; then
            if ! chmod 777 -- "$filepath"; then
                echo "[PERM-ERROR] chmod 777 gagal: $filepath" >&2
            fi
        elif [[ -f "$filepath" ]]; then
            if ! chmod 666 -- "$filepath"; then
                echo "[PERM-ERROR] chmod 666 gagal: $filepath" >&2
            fi
        fi
    fi

    # CLOSE_WRITE is permission-only: keep the existing indexing behavior unchanged.
    if [[ "$event" == *CLOSE_WRITE* &&
          "$event" != *CREATE* &&
          "$event" != *MOVED_TO* ]]; then
        continue
    fi

    IS_DIR=0
    if [[ "$event" == *ISDIR* ]]; then
        IS_DIR=1
    fi

    if [[ "$event" == *DELETE* ]]; then
        if [ "$IS_DIR" -eq 1 ]; then
            ACTION="-D"
            LABEL="INDEX-DELETE-DIR"
        else
            ACTION="-d"
            LABEL="INDEX-DELETE"
        fi
    else
        if [ "$IS_DIR" -eq 1 ]; then
            ACTION="-A"
            LABEL="INDEX-ADD-DIR"
        else
            ACTION="-a"
            LABEL="INDEX-ADD"
        fi
    fi

    echo "[$LABEL] $DSM_FILEPATH"

    if ! ssh -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        "${DSM_USER}@${DSM_IP}" \
        "$DSM_SYNOINDEX $ACTION \"$DSM_FILEPATH\"" </dev/null; then
        echo "[ERROR] Perintah synoindex gagal: $DSM_FILEPATH (aksi=$ACTION)" >&2
    fi

done < "$FIFO"

wait "$INOTIFY_PID"
RC=$?

echo "[ERROR] inotifywait berhenti (exit=$RC)." >&2
exit 1



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

echo "[START] Filter metadata Synology aktif."
echo "[START] Menjalankan satu inotifywait."

inotifywait -m -r \
    --exclude "$EXCLUDE_RE" \
    -e create,moved_to,delete \
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
        *)
            continue
            ;;
    esac

    IS_DIR=0
    if [[ "$event" == *ISDIR* ]]; then
        IS_DIR=1
    fi

    if [[ "$event" == *DELETE* ]]; then
        if [ "$IS_DIR" -eq 1 ]; then
            ACTION="-D"
            LABEL="INDEX-DELETE-DIR"
        else
            ACTION="-d"
            LABEL="INDEX-DELETE"
        fi
    else
        if [ "$IS_DIR" -eq 1 ]; then
            ACTION="-A"
            LABEL="INDEX-ADD-DIR"
        else
            ACTION="-a"
            LABEL="INDEX-ADD"
        fi
    fi

    echo "[$LABEL] $DSM_FILEPATH"

    if ! ssh -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        "${DSM_USER}@${DSM_IP}" \
        "$DSM_SYNOINDEX $ACTION \"$DSM_FILEPATH\"" </dev/null; then
        echo "[ERROR] Perintah synoindex gagal: $DSM_FILEPATH (aksi=$ACTION)" >&2
    fi

done < "$FIFO"

wait "$INOTIFY_PID"
RC=$?

echo "[ERROR] inotifywait berhenti (exit=$RC)." >&2
exit 1

