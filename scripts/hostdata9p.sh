#!/bin/sh

# DSM/QEMU may mount the 9P shares after the rc.d bootstrap starts.
MUSIC_SRC="/volume1/virtio9p/hostdata0"
PHOTO_SRC="/volume1/virtio9p/hostdata2"
SURV_SRC="/volume1/virtio9p/hostdata1"
MUSIC_DST="/volume1/music"
PHOTO_DST="/volume1/photo"
SURV_DST="/volume1/surveillance"
WAIT_SECONDS=120

is_9p_mounted()
{
    mount | grep -F -q " on $1 type 9p "
}

wait_for_9p()
{
    TARGET="$1"
    WAITED=0

    while [ "$WAITED" -lt "$WAIT_SECONDS" ]; do
        if is_9p_mounted "$TARGET"; then
            echo "[hostdata9p] source 9P siap: $TARGET"
            return 0
        fi
        sleep 2
        WAITED=$((WAITED + 2))
    done

    echo "[hostdata9p] ERROR: menunggu mount 9P timeout setelah ${WAIT_SECONDS}s: $TARGET"
    return 1
}

bind_mount()
{
    SRC="$1"
    DST="$2"

    if [ ! -d "$SRC" ]; then
        echo "[hostdata9p] ERROR: source tidak tersedia: $SRC"
        return 1
    fi

    if ! is_9p_mounted "$SRC"; then
        echo "[hostdata9p] ERROR: source bukan mount 9P: $SRC"
        return 1
    fi

    if [ ! -d "$DST" ]; then
        if ! mkdir -p "$DST"; then
            echo "[hostdata9p] ERROR: gagal membuat target: $DST"
            return 1
        fi
    fi

    if is_9p_mounted "$DST"; then
        echo "[hostdata9p] target sudah mounted sebagai 9P: $DST"
        return 0
    fi

    # Overlay the local DSM directory/filesystem with the intended share.
    # Do not unmount the underlying filesystem.
    if mount --bind "$SRC" "$DST"; then
        if is_9p_mounted "$DST"; then
            echo "[hostdata9p] bind mount berhasil: $SRC -> $DST"
            return 0
        fi

        echo "[hostdata9p] ERROR: bind mount tidak terverifikasi sebagai 9P: $DST"
        return 1
    fi

    echo "[hostdata9p] ERROR: bind mount gagal: $SRC -> $DST"
    return 1
}

case "$1" in
    start)
        echo "[hostdata9p] START"

        # Wait for QEMU/DSM to publish the source shares before binding them.
        wait_for_9p "$MUSIC_SRC" || exit 1
        wait_for_9p "$PHOTO_SRC" || exit 1

        bind_mount "$MUSIC_SRC" "$MUSIC_DST" || exit 1
        bind_mount "$PHOTO_SRC" "$PHOTO_DST" || exit 1

        # Surveillance may be mounted directly at its final destination by DSM,
        # or under /volume1/virtio9p/hostdata1. Handle both boot layouts.
        if is_9p_mounted "$SURV_DST"; then
            echo "[hostdata9p] Surveillance sudah mounted langsung: $SURV_DST"
        elif is_9p_mounted "$SURV_SRC"; then
            bind_mount "$SURV_SRC" "$SURV_DST" || exit 1
        else
            echo "[hostdata9p] WARNING: source Surveillance belum tersedia; tidak mengubah target"
        fi

        echo "[hostdata9p] START selesai"
        ;;

    stop)
        echo "[hostdata9p] STOP"

        # Only detach Music/Photo bind mounts. Never unmount the source shares
        # or Surveillance, which DSM may mount directly at its final path.
        for TARGET in "$MUSIC_DST" "$PHOTO_DST"; do
            if is_9p_mounted "$TARGET"; then
                if umount "$TARGET"; then
                    echo "[hostdata9p] bind mount dilepas: $TARGET"
                else
                    echo "[hostdata9p] ERROR: gagal melepas bind mount: $TARGET"
                fi
            else
                echo "[hostdata9p] tidak melepas target non-9P: $TARGET"
            fi
        done
        ;;

    restart)
        "$0" stop || exit 1
        "$0" start
        ;;

    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac

exit 0
