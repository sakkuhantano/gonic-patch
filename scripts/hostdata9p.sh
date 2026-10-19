#!/bin/sh

HOSTDATA="/mnt/music"
HOSTDATA1="/mnt/photo"
SURV="/mnt/surveillance"

is_mounted()
{
    mount | grep -q " on $1 "
}

mount_9p()
{
    DEV="$1"
    TARGET="$2"

    mkdir -p "$TARGET"

    if ! is_mounted "$TARGET"; then
        mount -t 9p \
            -o trans=virtio,version=9p2000.L,msize=1048576,cache=mmap \
            "$DEV" "$TARGET"

        if is_mounted "$TARGET"; then
            echo "[hostdata9p] 9P mount berhasil: $DEV -> $TARGET"
        else
            echo "[hostdata9p] 9P mount GAGAL: $DEV -> $TARGET"
        fi
    else
        echo "[hostdata9p] 9P sudah mounted: $DEV -> $TARGET"
    fi
}

bind_mount()
{
    SRC="$1"
    DST="$2"

    mkdir -p "$DST"

    if [ -d "$SRC" ] && ! is_mounted "$DST"; then
        mount --bind "$SRC" "$DST"

        if is_mounted "$DST"; then
            echo "[hostdata9p] bind mount berhasil: $SRC -> $DST"
        else
            echo "[hostdata9p] bind mount GAGAL: $SRC -> $DST"
        fi
    else
        echo "[hostdata9p] bind mount sudah ada / source tidak tersedia: $SRC -> $DST"
    fi
}

case "$1" in
    start)
        echo "[hostdata9p] START"

        mount_9p hostdata0 "$HOSTDATA"
        mount_9p hostdata1 "$SURV"
	mount_9p hostdata2 "$HOSTDATA1"

        bind_mount "$HOSTDATA" "/volume1/music"
	bind_mount "$HOSTDATA1" "/volume1/photo"
        bind_mount "$SURV" "/volume1/surveillance"

        echo "[hostdata9p] START selesai"
        ;;

    stop)
        echo "[hostdata9p] STOP"

        umount "/volume1/surveillance" 2>/dev/null
        umount "/volume1/music" 2>/dev/null
	umount "/volume1/photo" 2>/dev/null

        umount "$SURV" 2>/dev/null
        umount "$HOSTDATA" 2>/dev/null
 	umount "$HOSTDATA1" 2>/dev/null
        ;;

    restart)
        "$0" stop
        sleep 1
        "$0" start
        ;;

    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac

exit 0
