#!/bin/sh
# Install prebuilt CC33xx WiFi (+ optional BT) modules for BeagleY-AI
# Kernel: 6.12.49-vendor-k3-beagle (Armbian vendor k3-beagle)
# Usage: sudo sh install.sh [path-to-modules-dir]
set -eu

EXPECTED_KVER="6.12.49-vendor-k3-beagle"
KVER="$(uname -r)"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MOD_DIR="${1:-$SCRIPT_DIR/modules}"

if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: please run as root (sudo sh $0)" >&2
	exit 1
fi

if [ "$KVER" != "$EXPECTED_KVER" ]; then
	echo "ERROR: kernel mismatch: running '$KVER', expected '$EXPECTED_KVER'." >&2
	echo "Do NOT force-load modules compiled for another kernel." >&2
	exit 1
fi

for ko in cc33xx.ko cc33xx_sdio.ko; do
	if [ ! -f "$MOD_DIR/$ko" ]; then
		echo "ERROR: missing $MOD_DIR/$ko" >&2
		exit 1
	fi
	vm="$(modinfo -F vermagic "$MOD_DIR/$ko" 2>/dev/null || true)"
	case "$vm" in
		"$EXPECTED_KVER "*) ;;
		*)
			echo "ERROR: vermagic mismatch on $ko: '$vm'" >&2
			exit 1
			;;
	esac
done

DEST="/lib/modules/$KVER/updates"
mkdir -p "$DEST"
cp -f "$MOD_DIR/cc33xx.ko" "$MOD_DIR/cc33xx_sdio.ko" "$DEST/"
if [ -f "$MOD_DIR/btti_uart.ko" ]; then
	cp -f "$MOD_DIR/btti_uart.ko" "$DEST/"
fi

depmod -a "$KVER"

# Enable WiFi module auto-load on boot.
# btti_uart is NOT added to modules-load.d because this kernel lacks
# CONFIG_BT_LE and CONFIG_CFG80211_DEBUGFS (cc33xx BLE_ENABLE debugfs).
echo "cc33xx_sdio" > /etc/modules-load.d/cc33xx.conf

modprobe cc33xx_sdio

echo ""
echo "Installed and loaded cc33xx_sdio successfully."
iw dev || true
echo ""
echo "Next: configure Wi-Fi in /etc/netplan/20-wlan0.yaml (chmod 600):"
cat <<'YAML'
network:
  version: 2
  renderer: networkd
  wifis:
    wlan0:
      dhcp4: yes
      dhcp4-overrides:
        route-metric: 200
      dhcp6: yes
      dhcp6-overrides:
        route-metric: 200
      optional: true
      access-points:
        "YOUR_SSID":
          password: "YOUR_PASSWORD"
YAML
echo ""
echo "Then run: sudo chmod 600 /etc/netplan/20-wlan0.yaml && sudo netplan apply"
