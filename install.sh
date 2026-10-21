#!/bin/bash
set -euo pipefail

DRIVER_NAME=broadcom-wl
DRIVER_VERSION=6.30.223.271
DKMS_SRC=/usr/src/${DRIVER_NAME}-${DRIVER_VERSION}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIRED_PACKAGES=(build-essential dkms wireless-tools)
KERNEL_SCOPE="${KERNEL_SCOPE:-all}"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash install.sh"
    exit 1
fi

package_installed() {
    dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q "install ok installed"
}

install_missing_dependencies() {
    local missing=()
    local running_headers="linux-headers-$(uname -r)"
    local pkg

    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! package_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done

    if [[ -d "/lib/modules/$(uname -r)/build" ]]; then
        :
    elif ! package_installed "$running_headers"; then
        missing+=("$running_headers")
    fi

    if ((${#missing[@]} == 0)); then
        echo "==> Build dependencies already installed."
        return
    fi

    echo "==> Installing missing build dependencies: ${missing[*]}"
    apt-get update
    apt-get install -y "${missing[@]}"
}

detect_wifi_iface() {
    local iface=""

    if command -v nmcli &>/dev/null; then
        iface="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
            | awk -F: '$2 == "wifi" { print $1; exit }' || true)"
        if [[ -n "$iface" ]]; then
            printf '%s\n' "$iface"
            return 0
        fi
    fi

    iface="$(ip -o link show 2>/dev/null \
        | awk -F': ' '$2 ~ /^(wl|wlan|wlp)/ { print $2; exit }' || true)"
    if [[ -n "$iface" ]]; then
        printf '%s\n' "$iface"
        return 0
    fi

    find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
        | awk '/^(wl|wlan|wlp)/ { print; exit }'
}

selected_kernels() {
    case "$KERNEL_SCOPE" in
        running)
            printf '%s\n' "$(uname -r)"
            ;;
        all)
            local kdir
            shopt -s nullglob
            for kdir in /lib/modules/*; do
                printf '%s\n' "${kdir##*/}"
            done
            shopt -u nullglob
            ;;
        *)
            echo "Unsupported KERNEL_SCOPE=$KERNEL_SCOPE. Use 'all' or 'running'."
            exit 1
            ;;
    esac
}

rebuild_for_selected_kernels() {
    local kver
    local running
    local built_any=0
    local failed=()

    running="$(uname -r)"

    while IFS= read -r kver; do
        [[ -n "$kver" ]] || continue

        if [[ ! -d "/lib/modules/${kver}/build" ]]; then
            echo "==> Skipping ${kver}: kernel headers are not installed."
            continue
        fi

        echo "==> Building and installing via DKMS for ${kver}..."
        if dkms build -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}" -k "${kver}" \
            && dkms install -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}" -k "${kver}" --force; then
            built_any=1
        elif [[ "$kver" == "$running" ]]; then
            echo "DKMS build failed for the running kernel ${kver}."
            exit 1
        else
            # Leftover headers of an old kernel must not block the install
            # for the kernel that is actually in use.
            echo "Warning: DKMS build failed for ${kver}; continuing."
            failed+=("$kver")
        fi
    done < <(selected_kernels)

    if ((built_any == 0)); then
        echo "No selected kernels with headers were found under /lib/modules."
        exit 1
    fi

    if ((${#failed[@]} > 0)); then
        echo "Warning: wl was not built for: ${failed[*]}"
    fi
}

run_smoke_checks() {
    local iface
    local attempt

    echo "==> Running smoke checks..."

    if ! modinfo wl >/dev/null 2>&1; then
        echo "Smoke check failed: wl is not installed for the running kernel."
        exit 1
    fi

    modprobe wl

    for attempt in $(seq 1 20); do
        iface="$(detect_wifi_iface || true)"
        if [[ -d /sys/module/wl ]] && [[ -n "$iface" ]]; then
            echo "==> Smoke checks passed on interface ${iface}."
            return
        fi

        sleep 1
    done

    iface="$(detect_wifi_iface || true)"
    if [[ -d /sys/module/wl ]] && [[ -n "$iface" ]]; then
        echo "==> Smoke checks passed on interface ${iface}."
        return
    fi

    echo "Smoke check failed: wl or its network interface did not become ready."
    echo "Loaded modules matching wl:"
    lsmod | grep '^wl\b' || true
    echo "Detected network interfaces:"
    find /sys/class/net -mindepth 1 -maxdepth 1 -printf ' - %f\n' || true
    exit 1
}

install_missing_dependencies

echo "==> Removing conflicting Broadcom packages..."
apt-get remove -y bcmwl-kernel-source broadcom-sta-dkms 2>/dev/null || true

echo "==> Removing old DKMS entry (if any)..."
dkms remove "${DRIVER_NAME}/${DRIVER_VERSION}" --all 2>/dev/null || true

echo "==> Copying source to DKMS tree..."
rm -rf "$DKMS_SRC"
mkdir -p "$DKMS_SRC"
# Copy only the driver sources, not git metadata or local build output.
tar -C "$SCRIPT_DIR" \
    --exclude=.git --exclude=.agents --exclude=.codex \
    --exclude='*.o' --exclude='*.ko' --exclude='*.ko.zst' --exclude='*.cmd' \
    --exclude='*.mod' --exclude='*.mod.c' --exclude='*.d' \
    --exclude=modules.order --exclude=Module.symvers \
    --exclude=.cache.mk --exclude=.tmp_versions \
    -cf - . | tar -C "$DKMS_SRC" -xf -

echo "==> Registering source with DKMS..."
dkms add -m "${DRIVER_NAME}" -v "${DRIVER_VERSION}"

rebuild_for_selected_kernels

echo "==> Blacklisting conflicting drivers..."
tee /etc/modprobe.d/broadcom-wl.conf > /dev/null <<'CONF'
blacklist b43
blacklist b43legacy
blacklist brcmsmac
blacklist brcmfmac
blacklist bcma
blacklist ssb
CONF

echo "==> Unloading conflicting modules..."
modprobe -r b43 b43legacy brcmsmac brcmfmac bcma ssb 2>/dev/null || true

echo "==> Loading wl..."
modprobe wl

echo "==> Making wl load on boot..."
grep -q "^wl$" /etc/modules 2>/dev/null || echo 'wl' >> /etc/modules
update-initramfs -u

echo "==> Applying power management fix..."
bash "$SCRIPT_DIR/fix-powersave.sh" || echo "Warning: power management fix failed, run fix-powersave.sh manually after reboot"

run_smoke_checks

IFACE="$(detect_wifi_iface || true)"
echo ""
echo "Done! WiFi interface: ${IFACE:-(check: ip link)}"
echo "Connect: nmcli device wifi connect \"SSID\" password \"PASSWORD\""
