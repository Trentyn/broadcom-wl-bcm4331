#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_SCOPE="${KERNEL_SCOPE:-all}"
verified_any=0

detect_kernels() {
    case "$KERNEL_SCOPE" in
        running)
            printf '%s\n' "$(uname -r)"
            ;;
        all)
            local kdir
            shopt -s nullglob
            for kdir in /lib/modules/*; do
                if [[ -d "$kdir/build" ]]; then
                    printf '%s\n' "${kdir##*/}"
                fi
            done
            shopt -u nullglob
            ;;
        *)
            echo "Unsupported KERNEL_SCOPE=$KERNEL_SCOPE. Use 'all' or 'running'." >&2
            exit 1
            ;;
    esac
}

verify_build() {
    local kernel="$1"

    echo "==> Verifying build for ${kernel}..."
    make -C "/lib/modules/${kernel}/build" M="$SCRIPT_DIR" clean >/dev/null
    make -C "/lib/modules/${kernel}/build" M="$SCRIPT_DIR"
    verified_any=1
}

verify_runtime() {
    local iface=""

    echo "==> Verifying runtime state for $(uname -r)..."

    if ! modinfo wl >/dev/null 2>&1; then
        echo "wl is not installed for the running kernel." >&2
        exit 1
    fi

    if [[ ! -d /sys/module/wl ]]; then
        echo "wl is not currently loaded." >&2
        exit 1
    fi

    if command -v nmcli >/dev/null 2>&1; then
        iface="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
            | awk -F: '$2 == "wifi" { print $1; exit }' || true)"
    fi

    if [[ -z "$iface" ]] && command -v ip >/dev/null 2>&1; then
        iface="$(ip -o link show 2>/dev/null \
            | awk -F': ' '$2 ~ /^(wl|wlan|wlp)/ { print $2; exit }' || true)"
    fi

    if [[ -z "$iface" ]] && compgen -G '/sys/class/net/*' >/dev/null; then
        iface="$(find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' \
            | awk '/^(wl|wlan|wlp)/ { print; exit }' || true)"
    fi

    if [[ -z "$iface" ]]; then
        echo "No wireless interface is visible after loading wl." >&2
        exit 1
    fi

    echo "==> Runtime check passed on interface ${iface}."
}

while IFS= read -r kernel; do
    [[ -n "$kernel" ]] || continue
    verify_build "$kernel"
done < <(detect_kernels)

if ((verified_any == 0)); then
    echo "No installed kernels with headers were found to verify." >&2
    exit 1
fi

verify_runtime

echo "==> Verification complete."
