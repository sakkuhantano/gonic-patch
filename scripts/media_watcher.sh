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
PHOTO_API_SID=""
PHOTO_API_TOKEN=""

photo_api_init() {
    [[ -n "$DSM_API_PASSWORD" ]] || { echo "[PHOTO-API-ERROR] Set DSM_API_PASSWORD or configure $DSM_API_CONFIG" >&2; return 1; }
    command -v curl >/dev/null 2>&1 || { echo "[PHOTO-API-ERROR] curl unavailable" >&2; return 1; }
    command -v jq >/dev/null 2>&1 || { echo "[PHOTO-API-ERROR] jq unavailable; cleanup fails closed" >&2; return 1; }

    PHOTO_API_TMP=$(mktemp -d /tmp/media-watcher-api.XXXXXX) || return 1
    chmod 700 "$PHOTO_API_TMP"
    PHOTO_API_COOKIE="$PHOTO_API_TMP/cookies.txt"

    local login
    login=$(curl -fsS --connect-timeout 10 --max-time 30 \
        -c "$PHOTO_API_COOKIE" -b "$PHOTO_API_COOKIE" \
        -X POST "$DSM_API_URL/auth.cgi" \
        --data-urlencode 'api=SYNO.API.Auth' \
        --data-urlencode 'version=6' \
        --data-urlencode 'method=login' \
        --data-urlencode "account=$DSM_API_USER" \
        --data-urlencode "passwd=$DSM_API_PASSWORD" \
        --data-urlencode 'session=SynologyPhotos' \
        --data-urlencode 'format=cookie' \
        --data-urlencode 'enable_syno_token=yes') || {
        echo "[PHOTO-API-ERROR] DSM login request failed" >&2
        return 1
    }

    [[ "$(jq -r '.success // false' <<<"$login")" == "true" ]] || {
        echo "[PHOTO-API-ERROR] DSM login rejected: $(jq -r '.error.code // "unknown"' <<<"$login")" >&2
        return 1
    }

    PHOTO_API_TOKEN=$(jq -r '.data.SynoToken // .data.synotoken // empty' <<<"$login")
    PHOTO_API_SID=$(jq -r '.data.sid // .data.Sid // empty' <<<"$login")

    [[ -n "$PHOTO_API_TOKEN" ]] || { echo "[PHOTO-API-ERROR] SynoToken missing" >&2; return 1; }
    [[ -n "$PHOTO_API_SID" ]] || { echo "[PHOTO-API-ERROR] sid missing" >&2; return 1; }
}

photo_api_call() {
    local api="$1" version="$2" method="$3"
    shift 3
    local response
    response=$(curl -fsS --connect-timeout 10 --max-time 45 \
        -b "$PHOTO_API_COOKIE" -c "$PHOTO_API_COOKIE" \
        -X POST "$DSM_API_URL/entry.cgi" \
        --data-urlencode "api=$api" \
        --data-urlencode "version=$version" \
        --data-urlencode "method=$method" \
        --data-urlencode "SynoToken=$PHOTO_API_TOKEN" \
        --data-urlencode "_sid=$PHOTO_API_SID" \
        "$@") || return 1

    # Session mati → re-login sekali lalu retry
    if [[ "$(jq -r '.error.code // empty' <<<"$response")" == "119" ]]; then
        echo "[PHOTO-API] session 119, re-login..." >&2
        PHOTO_API_COOKIE=""
        PHOTO_API_TOKEN=""
        PHOTO_API_SID=""
        photo_api_init || return 1
        response=$(curl -fsS --connect-timeout 10 --max-time 45 \
            -b "$PHOTO_API_COOKIE" -c "$PHOTO_API_COOKIE" \
            -X POST "$DSM_API_URL/entry.cgi" \
            --data-urlencode "api=$api" \
            --data-urlencode "version=$version" \
            --data-urlencode "method=$method" \
            --data-urlencode "SynoToken=$PHOTO_API_TOKEN" \
            --data-urlencode "_sid=$PHOTO_API_SID" \
            "$@") || return 1
    fi

    [[ "$(jq -r '.success // false' <<<"$response")" == "true" ]] || {
        echo "[PHOTO-API-ERROR] $api.$method failed: $(jq -c '.error // .' <<<"$response")" >&2
        return 1
    }
    printf '%s' "$response"
}
photo_api_read_call() {
    local api="$1" version="$2" method="$3"
    shift 3
    local response
    # Browse/list requests are issued as GET, matching the successful DSM
    # diagnostics; keep mutation requests on photo_api_call (POST).
    response=$(curl -fsS --connect-timeout 10 --max-time 45 -G \
        -b "$PHOTO_API_COOKIE" -c "$PHOTO_API_COOKIE" \
        "$DSM_API_URL/entry.cgi" --data-urlencode "api=$api" \
        --data-urlencode "version=$version" --data-urlencode "method=$method" \
        --data-urlencode "SynoToken=$PHOTO_API_TOKEN" --data-urlencode "_sid=$PHOTO_API_SID" "$@") || return 1
    [[ "$(jq -r '.success // false' <<<"$response")" == "true" ]] || {
        echo "[PHOTO-API-ERROR] $api.$method failed: $(jq -c '.error // .' <<<"$response")" >&2; return 1; }
    printf '%s' "$response"
}

# BackgroundTask.File is a JSON-format Photos API. Its write token is sent in
# the X-SYNO-TOKEN header (the normal Browse.Item endpoint above tolerates the
# legacy form parameter, but BackgroundTask.File can reject that with error 119).
photo_api_background_delete() {
    local response api='SYNO.FotoTeam.BackgroundTask.File'
    local item_ids="$1" folder_ids="$2"

    local request
    request() {
        curl -fsS --connect-timeout 10 --max-time 45 \
            -b "$PHOTO_API_COOKIE" -c "$PHOTO_API_COOKIE" \
            -H "X-SYNO-TOKEN: $PHOTO_API_TOKEN" \
            -X POST "$DSM_API_URL/entry.cgi" \
            --data-urlencode "api=$api" \
            --data-urlencode 'version=1' \
            --data-urlencode 'method=delete' \
            --data-urlencode "item_id=$item_ids" \
            --data-urlencode "folder_id=$folder_ids" \
            --data-urlencode "_sid=$PHOTO_API_SID"
    }

    response=$(request) || return 1
    if [[ "$(jq -r '.error.code // empty' <<<"$response")" == "119" ]]; then
        echo "[PHOTO-API] BackgroundTask.File returned 119; re-login and retry with X-SYNO-TOKEN" >&2
        PHOTO_API_COOKIE=""
        PHOTO_API_TOKEN=""
        PHOTO_API_SID=""
        photo_api_init || return 1
        response=$(request) || return 1
    fi
    [[ "$(jq -r '.success // false' <<<"$response")" == "true" ]] || {
        echo "[PHOTO-API-ERROR] $api.delete failed: $(jq -c '.error // .' <<<"$response")" >&2
        return 1
    }
    printf '%s' "$response"
}
# Wait for Photos' asynchronous delete task to finish before considering a
# folder rename/delete cleanup complete. BackgroundTask.File returns "waiting"
# immediately; without polling, the old folder can remain visible in Photos.
photo_api_wait_task() {
    local task_id="$1" timeout_seconds="${2:-30}" response status elapsed=0

    [[ "$task_id" =~ ^[0-9]+$ ]] || {
        echo "[PHOTO-API-TASK-ERROR] invalid task ID: $task_id" >&2
        return 1
    }

    while (( elapsed < timeout_seconds )); do
        response=$(photo_api_read_call 'SYNO.Foto.BackgroundTask.Info' 1 get_status \
            --data-urlencode "id=[$task_id]") || {
            echo "[PHOTO-API-TASK-ERROR] cannot read status for task=$task_id" >&2
            return 1
        }
        status=$(jq -r --arg id "$task_id" \
            '[.. | objects | select((.id? | tostring) == $id and (.status? | type) == "string") | .status][0] // empty' \
            <<<"$response") || return 1

        case "$status" in
            done)
                echo "[PHOTO-API-TASK-DONE] id=$task_id"
                return 0
                ;;
            waiting|processing|aborting)
                ;;
            *)
                echo "[PHOTO-API-TASK-ERROR] unexpected status for task=$task_id: ${response:0:1000}" >&2
                return 1
                ;;
        esac
        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo "[PHOTO-API-TASK-TIMEOUT] id=$task_id timeout=${timeout_seconds}s; task may still be running" >&2
    return 1
}

photo_api_folder_id_for_path() {
    local fullpath="$1" relpath component current_path="" current_id=1
    local listing matches count offset page_matches all_matches
    local -a parts=()

    # Only resolve paths inside the Synology Photos Shared Space root.
    [[ "$fullpath" == "/volume1/photo" || "$fullpath" == "/volume1/photo/"* ]] || {
        echo "[PHOTO-API-ERROR] refusing path outside /volume1/photo: $fullpath" >&2
        return 1
    }
    relpath="${fullpath#/volume1/photo}"
    relpath="${relpath%/}"
    [[ -n "$relpath" ]] || { printf '1'; return 0; }

    IFS='/' read -r -a parts <<< "${relpath#/}"
    for component in "${parts[@]}"; do
        [[ -n "$component" ]] || continue
        current_path+="/$component"
        offset=0
        all_matches='[]'
        while :; do
            listing=$(photo_api_read_call 'SYNO.FotoTeam.Browse.Folder' 2 list \
                --data-urlencode "id=$current_id" \
                --data-urlencode 'limit=1000' \
                --data-urlencode "offset=$offset") || return 1
            page_matches=$(jq -c --arg p "$current_path" \
                '[.data.list[]? | select(.name == $p) | .id] | map(select(. != null))' \
                <<<"$listing") || return 1
            all_matches=$(jq -cn --argjson a "$all_matches" --argjson b "$page_matches" '$a + $b | unique') || return 1
            count=$(jq '.data.list | length' <<<"$listing") || return 1
            (( count < 1000 )) && break
            offset=$((offset + count))
        done

        matches=$(jq -c 'unique' <<<"$all_matches") || return 1
        match_count=$(jq 'length' <<<"$matches") || return 1
        if [[ "$match_count" -eq 0 ]]; then
            # A MOVED_FROM event is delivered after the physical rename has
            # happened. Photos may already have dropped the old folder from
            # Browse.Folder, so signal "not found" separately from API errors.
            echo "[PHOTO-API-FOLDER-NOT-FOUND] path=$current_path parent_id=$current_id" >&2
            return 2
        fi
        [[ "$match_count" -eq 1 ]] || {
            echo "[PHOTO-API-ERROR] folder path component not unique: $current_path (parent ID $current_id, matches $matches)" >&2
            return 1
        }
        current_id=$(jq -r '.[0]' <<<"$matches") || return 1
        [[ "$current_id" =~ ^[0-9]+$ ]] || {
            echo "[PHOTO-API-ERROR] invalid folder ID for $current_path" >&2
            return 1
        }
    done
    printf '%s' "$current_id"
}

photo_api_cleanup_path() {
    local oldpath="$1" is_dir="$2" id folder_id parent filename item_listing ids response task
    [[ -n "$PHOTO_API_COOKIE" ]] || photo_api_init || return 1

    if [[ "$is_dir" == "1" ]]; then
		# kalau folder fisik sudah hilang, skip; kalau masih ada:
		if [[ -d "${filepath}/@eaDir" ]]; then
			rm -rf -- "${filepath}/@eaDir" && \
				echo "[PHOTO-EADIR-CLEAN] ${filepath}/@eaDir"
		fi	
        # MOVED_FROM arrives after the rename, so the old path may already
        # be absent from Photos' folder listing. Retry briefly for index/API lag.
        # If it remains absent, do not run parent basic_reindex: rescanning the
        # renamed parent can recreate the old name as a ghost folder.
        local resolve_rc resolve_attempt
        id=""
        for resolve_attempt in 1 2 3; do
            if id=$(photo_api_folder_id_for_path "$oldpath"); then
                break
            else
                resolve_rc=$?
            fi
            if [[ "$resolve_rc" -eq 2 ]]; then
                sleep 1
                continue
            fi
            return 1
        done
        if [[ -z "$id" ]]; then
            echo "[PHOTO-API-FOLDER-ABSENT] old folder no longer listed by Photos; skipping delete and parent reindex: $oldpath"
            return 0
        fi
        [[ "$id" =~ ^[0-9]+$ ]] || {
            echo "[PHOTO-API-ERROR] invalid folder ID for $oldpath; refusing delete" >&2
            return 1
        }
        # Use the same authenticated Photos background-task endpoint as file
        # deletion. Folder deletes require item_id=[] and folder_id=[ID].
        response=$(photo_api_background_delete '[]' "[$id]") || return 1
        echo "[PHOTO-API-FOLDER-DELETE-RESP] $response"
        task=$(jq -r '.data.task_info.id // empty' <<<"$response")
        if [[ -z "$task" ]]; then
            echo "[PHOTO-API-ERROR] BackgroundTask.File folder delete succeeded without task_info.id: $response" >&2
            return 1
        fi
        echo "[PHOTO-API-FOLDER-DELETE-TASK] id=$task status=$(jq -r '.data.task_info.status // "unknown"' <<<"$response")"

        # Do not report success just because DSM accepted the task. Wait for
        # completion, then verify the old folder name is absent from its parent.
        photo_api_wait_task "$task" 30 || return 1
        parent="${oldpath%/*}"
        filename="${oldpath##*/}"
        folder_id=$(photo_api_folder_id_for_path "$parent") || return 1
        local folder_verify folder_count folder_still_present folder_attempt folder_offset photo_relative_path
        photo_relative_path="${oldpath#/volume1/photo}"
        folder_still_present=1
        for folder_attempt in 1 2 3; do
            folder_offset=0
            folder_still_present=0
            while :; do
                folder_verify=$(photo_api_read_call 'SYNO.FotoTeam.Browse.Folder' 2 list \
                    --data-urlencode "id=$folder_id" \
                    --data-urlencode 'limit=1000' \
                    --data-urlencode "offset=$folder_offset") || return 1
                if jq -e --arg p "$photo_relative_path" \
                    '.data.list[]? | select(.name == $p)' \
                    <<<"$folder_verify" >/dev/null; then
                    folder_still_present=1
                fi
                folder_count=$(jq '.data.list | length' <<<"$folder_verify") || return 1
                (( folder_count < 1000 )) && break
                folder_offset=$((folder_offset + folder_count))
            done
            [[ "$folder_still_present" -eq 0 ]] && break
            sleep 1
        done
        if [[ "$folder_still_present" -ne 0 ]]; then
            echo "[PHOTO-API-VERIFY-ERROR] folder still listed after task completion: path=$oldpath id=$id task=$task" >&2
            return 1
        fi
        echo "[PHOTO-API-FOLDER-DELETE-VERIFIED] path=$oldpath id=$id task=$task"
    else
		parent="${filepath%/*}"
		filename="${filepath##*/}"
		eadir_entry="${parent}/@eaDir/${filename}"
		if [[ -e "$eadir_entry" ]]; then
			rm -rf -- "$eadir_entry" && \
				echo "[PHOTO-EADIR-CLEAN] $eadir_entry" || \
				echo "[PHOTO-EADIR-ERROR] gagal hapus $eadir_entry" >&2
		fi	
        parent="${oldpath%/*}"
        filename="${oldpath##*/}"
        folder_id=$(photo_api_folder_id_for_path "$parent") || return 1
        item_listing=$(photo_api_read_call 'SYNO.FotoTeam.Browse.Item' 7 list \
            --data-urlencode "folder_id=$folder_id" \
            --data-urlencode 'limit=1000' --data-urlencode 'offset=0') || return 1
        ids=$(jq -c --arg n "$filename" \
            '[.data.list[]? | select(.filename == $n) | .id] | map(select(. != null)) | unique' \
            <<<"$item_listing") || return 1
        [[ "$(jq 'length' <<<"$ids")" -eq 1 ]] || {
            echo "[PHOTO-API-ERROR] item ID not unique for $oldpath: $ids; refusing delete" >&2
            return 1
        }
        id=$(jq -r '.[0]' <<<"$ids") || return 1
        [[ "$id" =~ ^[0-9]+$ ]] || {
            echo "[PHOTO-API-ERROR] invalid item ID for $oldpath; refusing delete" >&2
            return 1
        }
        # Use the Photos background delete task. This endpoint requires the
        # SynoToken write header; keep the synchronous Browse.Item delete only
        # as a historical fallback, not the primary delete path.
        response=$(photo_api_background_delete "[$id]" '[]') || return 1
        echo "[PHOTO-API-DELETE-RESP] $response"
        task=$(jq -r '.data.task_info.id // empty' <<<"$response")
        if [[ -z "$task" ]]; then
            echo "[PHOTO-API-ERROR] BackgroundTask.File.delete succeeded without task_info.id: $response" >&2
            return 1
        fi
        echo "[PHOTO-API-DELETE-TASK] id=$task status=$(jq -r '.data.task_info.status // "unknown"' <<<"$response")"

        # Confirm the background task actually removed the item from the list.
        # the item. Read the parent folder back and verify the filename is gone.
        # If it remains, return failure so the caller runs scoped basic_reindex.
        local verify_offset verify_count verify_listing still_present attempt
        still_present=1
        for attempt in 1 2 3; do
            verify_offset=0
            still_present=0
            while :; do
                verify_listing=$(photo_api_read_call 'SYNO.FotoTeam.Browse.Item' 7 list \
                    --data-urlencode "folder_id=$folder_id" \
                    --data-urlencode 'limit=1000' \
                    --data-urlencode "offset=$verify_offset") || return 1
                if jq -e --arg n "$filename" \
                    '.data.list[]? | select(.filename == $n)' \
                    <<<"$verify_listing" >/dev/null; then
                    still_present=1
                fi
                verify_count=$(jq '.data.list | length' <<<"$verify_listing") || return 1
                (( verify_count < 1000 )) && break
                verify_offset=$((verify_offset + verify_count))
            done
            [[ "$still_present" -eq 0 ]] && break
            sleep 1
        done
        if [[ "$still_present" -ne 0 ]]; then
            echo "[PHOTO-API-VERIFY-ERROR] delete returned success but item still listed: path=$oldpath id=$id" >&2
            return 1
        fi
        echo "[PHOTO-API-DELETE-VERIFIED] path=$oldpath id=$id task=$task"
    fi
    task=$(jq -r '.data.task_info.id // .data.task_id // .data.id // empty' <<<"$response")
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
    "@Recycle"
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
EXCLUDE_RE='(^|/)(@eaDir|@Recycle|@SSRECMETA|\.@thumb|\.@__thumb|@SynoResource|\.thumbnails|thumbnails|thumbs)(/|$)|(^|/)(SYNOPHOTO[^/]*|\.DS_Store|[Tt]humbs\.db|desktop\.ini|\._[^/]*|[^/]*\.(thumb|thumbnail))$'

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
    if [[ "$filepath" =~ (^|/)(@eaDir|@Recycle|@SSRECMETA|\.@thumb|\.@__thumb|@SynoResource|\.thumbnails|thumbnails|thumbs)(/|$) ]] ||
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
				echo "[ERROR] Synology Photos cleanup failed: $DSM_FILEPATH" >&2
				parent="${DSM_FILEPATH%/*}"
				[[ -z "$parent" || "$parent" == "$DSM_FILEPATH" ]] && parent="/volume1/photo"
				printf -v REMOTE_PHOTO_REINDEX_CMD 'sudo -n %q -t basic_reindex -i %q' \
					"$DSM_PHOTO_INDEX" "$parent"
				if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
					"${DSM_USER}@${DSM_IP}" "$REMOTE_PHOTO_REINDEX_CMD" </dev/null; then
					echo "[PHOTO-REINDEX-ERROR] basic_reindex gagal: $parent" >&2
				else
					echo "[PHOTO-REINDEX] fallback basic_reindex $parent"
				fi
			fi
			continue
		fi
		# Do not index a directory on CREATE: users may rename it immediately,
		# and Photos can process the queued index request after MOVED_FROM,
		# resurrecting the old folder name. Index moved-in/renamed directories
		# on MOVED_TO, and index newly written files on CLOSE_WRITE instead.
		if [[ "$event" == *CLOSE_WRITE* || "$event" == *MOVED_TO* ]]; then
			printf -v REMOTE_PHOTO_INDEX_CMD 'sudo -n %q -t basic -i %q' \
				"$DSM_PHOTO_INDEX" "$DSM_FILEPATH"
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
