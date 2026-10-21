#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash fix-powersave.sh"
    exit 1
fi

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

echo "==> Checking for wireless-tools..."
if ! command -v iwconfig &>/dev/null; then
    apt-get install -y wireless-tools
fi

IWCONFIG=$(command -v iwconfig)
IFACE=$(detect_wifi_iface)

if [[ -z "$IFACE" ]]; then
    echo "No wireless interface found yet. Continuing with persistent fixes."
else
    echo "==> Disabling power management on $IFACE..."
    "$IWCONFIG" "$IFACE" power off || true
fi

echo "==> Writing NetworkManager config..."
mkdir -p /etc/NetworkManager/conf.d
# conf.d files are read in alphabetical order and later files win, so this
# name has to sort after Ubuntu's default-wifi-powersave-on.conf. The old
# 99-wifi-powersave-off.conf sorted before it and had no effect.
rm -f /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf
tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf > /dev/null <<'CONF'
[connection]
wifi.powersave = 2
CONF

echo "==> Writing TLP config..."
# TLP defaults to WIFI_PWR_ON_BAT=on and reapplies it after NetworkManager and
# on every AC/battery switch, which turns power saving back on.
mkdir -p /etc/tlp.d
tee /etc/tlp.d/99-broadcom-wl.conf > /dev/null <<'CONF'
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=off
CONF
if command -v tlp &>/dev/null; then
    tlp start >/dev/null 2>&1 || true
fi

echo "==> Writing udev rule for persistence..."
mkdir -p /etc/udev/rules.d
tee /etc/udev/rules.d/81-wifi-powersave.rules > /dev/null <<EOF
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wl*", RUN+="$IWCONFIG %k power off"
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="$IWCONFIG %k power off"
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlp*", RUN+="$IWCONFIG %k power off"
EOF

echo "==> Installing Broadcom wl resume recovery hook..."
mkdir -p /lib/systemd/system-sleep
tee /lib/systemd/system-sleep/99-broadcom-wl-resume > /dev/null <<'EOF'
#!/bin/sh
set -u

# Broadcom wl can stop scanning after suspend/resume on older Apple laptops.
# Reloading wl restores Wi-Fi without rebooting the machine.
case "$1/$2" in
  post/*)
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    nmcli radio wifi off >/dev/null 2>&1 || true
    systemctl stop NetworkManager.service >/dev/null 2>&1 || true
    modprobe -r wl >/dev/null 2>&1 || true
    sleep 2
    modprobe wl >/dev/null 2>&1 || true
    systemctl start NetworkManager.service >/dev/null 2>&1 || true
    sleep 5
    nmcli radio wifi on >/dev/null 2>&1 || true
    ;;
esac
EOF
chmod 755 /lib/systemd/system-sleep/99-broadcom-wl-resume

echo "==> Installing manual Wi-Fi recovery command..."
mkdir -p /usr/local/sbin
tee /usr/local/sbin/fix-broadcom-wifi > /dev/null <<'EOF'
#!/bin/sh
set -u

# Usage:
#   sudo fix-broadcom-wifi
#   sudo fix-broadcom-wifi "Connection name"
#
# With no connection name, NetworkManager will autoconnect to the saved Wi-Fi
# profile it normally prefers.
CONNECTION="${1:-}"
PATH=/usr/sbin:/usr/bin:/sbin:/bin

systemctl stop NetworkManager.service
modprobe -r wl >/dev/null 2>&1 || true
sleep 2
modprobe wl
systemctl start NetworkManager.service
sleep 5
nmcli radio wifi on >/dev/null 2>&1 || true

if [ -n "$CONNECTION" ]; then
    nmcli connection up "$CONNECTION" || true
fi

nmcli device status
EOF
chmod 755 /usr/local/sbin/fix-broadcom-wifi

echo "==> Fixing netplan file permissions if present..."
if [[ -f /etc/netplan/01-network-manager-all.yaml ]]; then
    chmod 600 /etc/netplan/01-network-manager-all.yaml || true
fi

echo "==> Reloading udev rules..."
udevadm control --reload-rules
udevadm trigger --subsystem-match=net || true

echo "==> Reloading NetworkManager..."
if systemctl is-active --quiet NetworkManager.service; then
    systemctl restart NetworkManager.service || true
fi

echo ""
echo "Done! Broadcom wl power saving and resume recovery are installed."
echo "If Wi-Fi gets stuck again, run: sudo fix-broadcom-wifi"
