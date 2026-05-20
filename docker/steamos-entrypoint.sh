#!/usr/bin/env bash
set -Eeuo pipefail

# Accept Pterodactyl startup args like: SERVER_PORT=32222
for arg in "$@"; do
    if [[ "$arg" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        export "$arg"
    fi
done

cd /home/container

mkdir -p \
    /home/container/images \
    /home/container/disks \
    /home/container/ovmf \
    /home/container/runtime

log() {
    echo "[steamos-qemu] $*"
}

fail() {
    echo "[steamos-qemu] ERROR: $*" >&2
    exit 1
}

bool_true() {
    case "${1:-false}" in
        1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

RUN_MODE="${RUN_MODE:-install}"
STEAMOS_IMAGE_FILE="${STEAMOS_IMAGE_FILE:-steamdeck-repair-20250521.10-3.7.7.img.bz2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-80G}"
RAM_SIZE="${RAM_SIZE:-8G}"
CPU_CORES="${CPU_CORES:-4}"
WEB_PORT="${WEB_PORT:-${SERVER_PORT:-8006}}"
DISK_BUS="${DISK_BUS:-virtio}"
SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"
QEMU_ARGUMENTS="${QEMU_ARGUMENTS:-}"
FORCE_RECREATE_DISK="${FORCE_RECREATE_DISK:-false}"
RESET_OVMF="${RESET_OVMF:-false}"

BASE_INPUT="/home/container/${STEAMOS_IMAGE_FILE}"
BASE_IMG="/home/container/images/steamdeck-recovery.img"
VM_DISK="/home/container/disks/steamos.qcow2"
OVMF_VARS="/home/container/ovmf/OVMF_VARS.fd"

log "Starting SteamOS QEMU entrypoint."
log "UID/GID: $(id)"
log "RUN_MODE=${RUN_MODE}"
log "WEB_PORT=${WEB_PORT}"
log "VM_DISK=${VM_DISK}"
log "STEAMOS_IMAGE_FILE=${STEAMOS_IMAGE_FILE}"
log "DISK_BUS=${DISK_BUS}"

if bool_true "$RESET_OVMF"; then
    log "RESET_OVMF=true; removing persistent OVMF vars."
    rm -f "$OVMF_VARS"
fi

if bool_true "$FORCE_RECREATE_DISK"; then
    log "FORCE_RECREATE_DISK=true; removing VM disk."
    rm -f "$VM_DISK"
fi

case "$RUN_MODE" in
    install|recovery|run) ;;
    *) fail "Invalid RUN_MODE='${RUN_MODE}'. Valid values: install, recovery, run." ;;
esac

if [[ "$RUN_MODE" == "install" || "$RUN_MODE" == "recovery" ]]; then
    if [[ ! -f "$BASE_IMG" ]]; then
        [[ -f "$BASE_INPUT" ]] || fail "Missing SteamOS image: ${BASE_INPUT}. Upload it manually to /home/container."

        case "$BASE_INPUT" in
            *.bz2)
                log "Decompressing ${BASE_INPUT} to ${BASE_IMG}. This can take a while."
                bzip2 -dc "$BASE_INPUT" > "$BASE_IMG"
                ;;
            *.img|*.raw)
                log "Copying raw image to ${BASE_IMG}."
                cp -f "$BASE_INPUT" "$BASE_IMG"
                ;;
            *)
                fail "Unsupported image format. Expected .img.bz2, .img, or .raw."
                ;;
        esac
    else
        log "Existing decompressed recovery image found: ${BASE_IMG}"
    fi
fi

if [[ ! -f "$VM_DISK" ]]; then
    log "Creating VM disk ${VM_DISK} with size ${VM_DISK_SIZE}."
    qemu-img create -f qcow2 "$VM_DISK" "$VM_DISK_SIZE"
else
    log "Existing VM disk found: ${VM_DISK}"
fi

if [[ "$RUN_MODE" == "run" && ! -f "$VM_DISK" ]]; then
    fail "RUN_MODE=run but ${VM_DISK} does not exist. Boot RUN_MODE=install first and install SteamOS."
fi

OVMF_CODE=""
OVMF_VARS_TEMPLATE=""

for path in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/ovmf/OVMF.fd \
    /usr/share/qemu/OVMF.fd
do
    if [[ -f "$path" ]]; then
        OVMF_CODE="$path"
        break
    fi
done

for path in \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd
do
    if [[ -f "$path" ]]; then
        OVMF_VARS_TEMPLATE="$path"
        break
    fi
done

[[ -n "$OVMF_CODE" ]] || fail "OVMF_CODE firmware not found."
[[ -n "$OVMF_VARS_TEMPLATE" ]] || fail "OVMF_VARS template not found."

if [[ ! -f "$OVMF_VARS" ]]; then
    log "Creating persistent OVMF vars from ${OVMF_VARS_TEMPLATE}."
    cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"
fi

MACHINE_ARGS=(-machine q35,accel=tcg)
CPU_ARGS=(-cpu max)
KVM_ARGS=()

if [[ -e /dev/kvm ]]; then
    MACHINE_ARGS=(-machine q35,accel=kvm)
    CPU_ARGS=(-cpu host)
    KVM_ARGS=(-enable-kvm)
    log "KVM is available."
else
    log "WARNING: /dev/kvm is not available. Using TCG software emulation."
    log "SteamOS may be unusably slow without KVM."
fi

DISK_ARGS=()

add_system_disk() {
    case "$DISK_BUS" in
        virtio)
            DISK_ARGS+=(
                -drive "file=${VM_DISK},if=none,id=systemdisk,format=qcow2"
                -device "virtio-blk-pci,drive=systemdisk,bootindex=${1}"
            )
            ;;
        sata)
            DISK_ARGS+=(
                -drive "file=${VM_DISK},if=none,id=systemdisk,format=qcow2"
                -device "ide-hd,drive=systemdisk,bus=ide.0,bootindex=${1}"
            )
            ;;
        *)
            fail "Invalid DISK_BUS='${DISK_BUS}'. Valid values: virtio, sata."
            ;;
    esac
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
