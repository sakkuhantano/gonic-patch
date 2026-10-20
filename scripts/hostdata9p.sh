#!/bin/sh

# QEMU virtio-9p shares are already mounted by DSM at these paths.
HOSTDATA="/volume1/virtio9p/hostdata0"
HOSTDATA1="/volume1/virtio9p/hostdata2"
SURV="/volume1/surveillance"

is_9p_mounted()
{
    mount | grep -F -q " on $1 type 9p "
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

    # Bind over the target if it currently shows an ordinary local directory
    # or a local filesystem. Do not unmount that underlying filesystem.
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

        # Do not mount the virtio tags a second time: DSM/QEMU already mounted
        # them under /volume1/virtio9p (and surveillance at /volume1/surveillance).
        bind_mount "$HOSTDATA" "/volume1/music" || exit 1
        bind_mount "$HOSTDATA1" "/volume1/photo" || exit 1

        if is_9p_mounted "$SURV"; then
            echo "[hostdata9p] share surveillance sudah mounted: $SURV"
        else
            echo "[hostdata9p] WARNING: share surveillance tidak terdeteksi sebagai 9P: $SURV"
        fi

        echo "[hostdata9p] START selesai"
        ;;

    stop)
        echo "[hostdata9p] STOP"

        # Only detach the two share bind mounts when they are 9P mounts.
        # Never unmount /volume1/surveillance or the original DSM filesystem
        # mounts at /volume1/music and /volume1/photo.
        for TARGET in "/volume1/music" "/volume1/photo"; do
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
