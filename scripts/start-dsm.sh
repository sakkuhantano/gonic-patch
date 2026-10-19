#!/bin/bash

QEMU="qemu-system-x86_64"

DSM_IP="192.168.10.3"
DSM_USER="hendry"
DSM_SHUTDOWN="/usr/syno/sbin/synopoweroff"

QEMU_PID=""

shutdown_dsm()
{
    echo "[DSM] Meminta DSM melakukan clean shutdown..."

    timeout 10s ssh \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o ServerAliveInterval=2 \
        -o ServerAliveCountMax=2 \
        "${DSM_USER}@${DSM_IP}" \
        "sudo -n ${DSM_SHUTDOWN}" < /dev/null || true
}

handle_stop()
{
    echo "[DSM] SIGTERM diterima. Memulai clean shutdown DSM..."

    shutdown_dsm

    if [ -n "$QEMU_PID" ]; then
        echo "[DSM] Menunggu QEMU PID $QEMU_PID keluar..."
        wait "$QEMU_PID"
    fi

    echo "[DSM] QEMU sudah keluar. Wrapper selesai."
    exit 0
}

trap handle_stop TERM INT


# TAP network
ip link delete tap-dsm 2>/dev/null || true

ip tuntap add dev tap-dsm mode tap
ip link set tap-dsm master qvs0
ip link set tap-dsm up
mkdir -p /hostconfig/qmp

# Start QEMU
$QEMU \
  -enable-kvm \
  -machine q35 \
  -cpu host \
  -smp 2 \
  -m 3072 \
  -qmp unix:/hostconfig/qmp/dsm.sock,server=on,wait=off \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS_4M.fd \
  -device qemu-xhci,id=usb \
  -drive file=/bootloader/rr.img,format=raw,if=none,id=rrboot \
  -device virtio-balloon-pci,id=balloon0 \
  -device usb-storage,drive=rrboot,bootindex=1 \
  -drive file=/dsm-storage/disk.qcow2,format=qcow2,if=none,id=dsm-disk \
  -device ide-hd,drive=dsm-disk,bus=ide.2,bootindex=2 \
  -virtfs local,path=/media/Music,mount_tag=hostdata0,security_model=passthrough,id=hostmusic0 \
  -virtfs local,path=/media/Photo,mount_tag=hostdata2,security_model=passthrough,id=hostphoto0 \
  -virtfs local,path=/surveillance,mount_tag=hostdata1,security_model=passthrough,id=hostsurveillance0 \
  -virtfs local,path=/hostconfig,mount_tag=hostconfig,security_model=passthrough,id=hostconfig0 \
  -netdev tap,id=net0,ifname=tap-dsm,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0,mac=52:54:00:92:00:03 \
  -nographic &

QEMU_PID=$!

echo "[DSM] QEMU started, PID=$QEMU_PID"

wait "$QEMU_PID"

RC=$?

echo "[DSM] QEMU exited, rc=$RC"

exit "$RC"
