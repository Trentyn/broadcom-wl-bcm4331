#!/bin/bash
set -euo pipefail

DRIVER_NAME=broadcom-wl
DRIVER_VERSION=6.30.223.271
DKMS_SRC=/usr/src/${DRIVER_NAME}-${DRIVER_VERSION}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_SCOPE="${KERNEL_SCOPE:-all}"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash install.sh"
    exit 1
fi

if [[ -e /run/ostree-booted ]]; then
    echo "Image-based systems (Fedora Silverblue, Kinoite, ...) are not supported: DKMS needs a writable /usr."
    exit 1
fi

if command -v apt-get &>/dev/null; then
    PKG_MANAGER=apt
    REQUIRED_PACKAGES=(build-essential dkms wireless-tools)
elif command -v dnf &>/dev/null; then
    PKG_MANAGER=dnf
    # dkms pulls in gcc, make and elfutils-libelf-devel.
    REQUIRED_PACKAGES=(dkms iw)
else
    echo "Neither apt-get nor dnf was found. This installer supports Debian/Ubuntu and Fedora."
    exit 1
fi

package_installed() {
    case "$PKG_MANAGER" in
        apt) dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q "install ok installed" ;;
        dnf) rpm -q "$1" &>/dev/null ;;
    esac
}

running_headers_package() {
    local kver
    kver="$(uname -r)"

    case "$PKG_MANAGER" in
        apt) printf 'linux-headers-%s\n' "$kver" ;;
        dnf)
            if [[ "$kver" == *+debug ]]; then
                printf 'kernel-debug-devel-%s\n' "${kver%+debug}"
            else
                printf 'kernel-devel-%s\n' "$kver"
            fi
            ;;
    esac
}

install_packages() {
    case "$PKG_MANAGER" in
        apt)
            apt-get update
            apt-get install -y "$@"
            ;;
        dnf)
            dnf install -y --refresh "$@"
            ;;
    esac
}

remove_conflicting_packages() {
    local conflicts=()

    case "$PKG_MANAGER" in
        apt)
            apt-get remove -y bcmwl-kernel-source broadcom-sta-dkms 2>/dev/null || true
            ;;
        dnf)
            # The RPM Fusion driver ships its own wl.ko.
            mapfile -t conflicts < <(rpm -qa 'akmod-wl' 'kmod-wl*' 'broadcom-wl')
            if ((${#conflicts[@]} > 0)); then
                dnf remove -y "${conflicts[@]}" || true
            fi
            ;;
    esac
}

regenerate_initramfs() {
    if command -v update-initramfs &>/dev/null; then
        update-initramfs -u
    elif command -v dracut &>/dev/null; then
        dracut --force --regenerate-all \
            || echo "Warning: dracut failed; the driver blacklist may not apply until the next kernel update."
    fi
}

install_missing_dependencies() {
    local missing=()
    local running_headers
    local pkg

    running_headers="$(running_headers_package)"

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
    if ! install_packages "${missing[@]}"; then
        # Fedora only keeps the newest kernel-devel in its repos, so this fails
        # whenever the machine is not running the newest kernel.
        if [[ "$PKG_MANAGER" == dnf ]] && [[ " ${missing[*]} " == *" $running_headers "* ]]; then
            echo "Could not install $running_headers for the running kernel."
            echo "Update and reboot into the newest kernel, then run this installer again:"
            echo "  sudo dnf upgrade --refresh 'kernel*' && sudo reboot"
        fi
        exit 1
    fi
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

    # wl may not take over a card that bcma was driving until the next boot, and
    # forcing it through the sysfs bind file has caused a kernel panic.
    if ((BCMA_WAS_LOADED)) && [[ -d /sys/module/wl ]]; then
        echo "==> wl is installed but has not attached to the card yet."
        echo "==> Reboot to finish. Do not bind wl to the card by hand: it can panic the kernel."
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
remove_conflicting_packages

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

# SELinux (Fedora): make sure the installed module carries the right label.
if command -v restorecon &>/dev/null; then
    restorecon -R /lib/modules 2>/dev/null || true
fi

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
BCMA_WAS_LOADED=0
if [[ -d /sys/module/bcma ]]; then
    BCMA_WAS_LOADED=1
fi
modprobe -r b43 b43legacy brcmsmac brcmfmac bcma ssb 2>/dev/null || true

echo "==> Loading wl..."
modprobe wl

echo "==> Making wl load on boot..."
mkdir -p /etc/modules-load.d
echo 'wl' > /etc/modules-load.d/broadcom-wl.conf
regenerate_initramfs

echo "==> Applying power management fix..."
bash "$SCRIPT_DIR/fix-powersave.sh" || echo "Warning: power management fix failed, run fix-powersave.sh manually after reboot"

run_smoke_checks

IFACE="$(detect_wifi_iface || true)"
echo ""
echo "Done! WiFi interface: ${IFACE:-(check: ip link)}"
echo "Connect: nmcli device wifi connect \"SSID\" password \"PASSWORD\""
