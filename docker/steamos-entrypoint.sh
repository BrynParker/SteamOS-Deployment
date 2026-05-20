#!/usr/bin/env bash
}

add_recovery_disk() {
    case "$DISK_BUS" in
        virtio)
            DISK_ARGS+=(
                -drive "file=${BASE_IMG},if=none,id=recoverydisk,format=raw,readonly=on"
                -device "virtio-blk-pci,drive=recoverydisk,bootindex=${1}"
            )
            ;;
        sata)
            DISK_ARGS+=(
                -drive "file=${BASE_IMG},if=none,id=recoverydisk,format=raw,readonly=on"
                -device "ide-hd,drive=recoverydisk,bus=ide.1,bootindex=${1}"
            )
            ;;
        *)
            fail "Invalid DISK_BUS='${DISK_BUS}'. Valid values: virtio, sata."
            ;;
    esac
}

if [[ "$RUN_MODE" == "install" || "$RUN_MODE" == "recovery" ]]; then
    add_recovery_disk 1
    add_system_disk 2
    log "Booting SteamOS recovery image. Use VNC/noVNC and select Re-image Device."
else
    add_system_disk 1
    log "Booting installed SteamOS disk."
fi

log "Starting noVNC/websockify on 0.0.0.0:${WEB_PORT} -> localhost:5900."
rm -f /home/container/runtime/novnc.log
websockify --web=/usr/share/novnc/ "0.0.0.0:${WEB_PORT}" localhost:5900 > /home/container/runtime/novnc.log 2>&1 &

sleep 1
if ! pgrep -f "websockify.*${WEB_PORT}" >/dev/null 2>&1; then
    log "WARNING: websockify did not appear to start. noVNC log follows:"
    cat /home/container/runtime/novnc.log || true
fi

EXTRA_ARGS=()
if [[ -n "$QEMU_ARGUMENTS" ]]; then
    read -r -a EXTRA_ARGS <<< "$QEMU_ARGUMENTS"
fi

log "Viewer: open the server allocation/port ${WEB_PORT} in a browser."
log "Launching QEMU now."

exec qemu-system-x86_64 \
    "${MACHINE_ARGS[@]}" \
    "${KVM_ARGS[@]}" \
    "${CPU_ARGS[@]}" \
    -smp "$CPU_CORES" \
    -m "$RAM_SIZE" \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,file=${OVMF_VARS}" \
    "${DISK_ARGS[@]}" \
    -device virtio-vga \
    -device virtio-net-pci,netdev=n0 \
    -netdev "user,id=n0,hostfwd=tcp::${SSH_HOST_PORT}-:22" \
    -usb \
    -device qemu-xhci \
    -device usb-tablet \
    -boot menu=on \
    -vnc 127.0.0.1:0 \
    -monitor none \
    -serial stdio \
    -D /home/container/runtime/qemu.log \
    -d guest_errors \
    "${EXTRA_ARGS[@]}"
