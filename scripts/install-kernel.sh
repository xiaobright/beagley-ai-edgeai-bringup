#!/bin/bash
# Install the prebuilt full 6.12.49-vendor-k3-beagle kernel (with CC33xx Wi-Fi 6 + BLE 5.4,
# rebuilt PowerVR pvrsrvkm.ko, and practical USB/CAN/FS/WireGuard modules) onto BeagleY-AI.
#
# Preserves /boot/dtb/ti/k3-am67a-beagley-ai.dtb and /boot/uEnv.txt untouched, and creates
# .orig backups before replacing any kernel, module, header, or initramfs file.
#
# Usage: sudo bash install-kernel.sh [path-to-kernel-6.12.49-vendor-k3-beagle-full.tar.gz]
set -euo pipefail

KVER="6.12.49-vendor-k3-beagle"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DEFAULT_TAR="kernel-${KVER}-full.tar.gz"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: please run as root (sudo bash $0 ...)" >&2
  exit 1
fi

if [ "$(uname -m)" != "aarch64" ]; then
  echo "ERROR: expected aarch64 host, got $(uname -m)" >&2
  exit 1
fi

if [ "$(uname -r)" != "$KVER" ]; then
  echo "ERROR: expected running kernel '$KVER', got '$(uname -r)'." >&2
  exit 1
fi

TAR_PATH="${1:-}"
if [ -z "$TAR_PATH" ]; then
  if [ -f "./$DEFAULT_TAR" ]; then
    TAR_PATH="./$DEFAULT_TAR"
  elif [ -f "$SCRIPT_DIR/$DEFAULT_TAR" ]; then
    TAR_PATH="$SCRIPT_DIR/$DEFAULT_TAR"
  else
    echo "ERROR: specify path to $DEFAULT_TAR (e.g. sudo bash $0 $DEFAULT_TAR)" >&2
    exit 1
  fi
fi

if [ ! -f "$TAR_PATH" ]; then
  echo "ERROR: file not found: $TAR_PATH" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d /tmp/kstage.XXXXXX)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "=== 1. Creating .orig rollback backups ==="
[ -f /boot/Image.orig ] || cp /boot/Image /boot/Image.orig
[ -f "/boot/config-${KVER}.orig" ] || cp "/boot/config-${KVER}" "/boot/config-${KVER}.orig"
[ -f "/boot/System.map-${KVER}.orig" ] || cp "/boot/System.map-${KVER}" "/boot/System.map-${KVER}.orig"
[ -d "/lib/modules/${KVER}.orig" ] || cp -a "/lib/modules/${KVER}" "/lib/modules/${KVER}.orig"

HDR="/usr/src/linux-headers-${KVER}"
if [ -d "$HDR" ] && [ ! -f /root/headers-sync-orig.tar.gz ]; then
  tar -C "$HDR" -czf /root/headers-sync-orig.tar.gz \
    Module.symvers .config include/config include/generated 2>/dev/null || true
fi

mkdir -p /root/boot-orig
if [ -f "/boot/initrd.img-${KVER}" ] && [ ! -f "/root/boot-orig/initrd.img-${KVER}" ]; then
  cp "/boot/initrd.img-${KVER}" "/root/boot-orig/initrd.img-${KVER}"
fi
if [ -f /boot/uInitrd ] && [ ! -f /root/boot-orig/uInitrd ]; then
  cp /boot/uInitrd /root/boot-orig/uInitrd
fi

echo "=== 2. Extracting kernel bundle ==="
tar -xzf "$TAR_PATH" -C "$WORK_DIR"
for req in "boot/Image" "boot/config-${KVER}" "boot/System.map-${KVER}" "lib/modules/${KVER}"; do
  if [ ! -e "${WORK_DIR}/${req}" ]; then
    echo "ERROR: bundle missing ${req}" >&2
    exit 1
  fi
done

echo "=== 3. Installing /boot files (VFAT-safe plain cp, leaving DTB & uEnv.txt untouched) ==="
cp "${WORK_DIR}/boot/Image" /boot/Image
cp "${WORK_DIR}/boot/config-${KVER}" "/boot/config-${KVER}"
cp "${WORK_DIR}/boot/System.map-${KVER}" "/boot/System.map-${KVER}"

echo "=== 4. Installing /lib/modules/${KVER} & syncing headers ==="
rm -rf "/lib/modules/${KVER}"
mv "${WORK_DIR}/lib/modules/${KVER}" "/lib/modules/${KVER}"
if [ -d "$HDR" ]; then
  ln -sfn "$HDR" "/lib/modules/${KVER}/build"
  if [ -d "${WORK_DIR}/headers-sync" ]; then
    cp "${WORK_DIR}/headers-sync/Module.symvers" "${HDR}/Module.symvers"
    cp "${WORK_DIR}/headers-sync/.config" "${HDR}/.config"
    rm -rf "${HDR}/include/config" "${HDR}/include/generated"
    cp -a "${WORK_DIR}/headers-sync/include/config" "${HDR}/include/"
    cp -a "${WORK_DIR}/headers-sync/include/generated" "${HDR}/include/"
  fi
fi

depmod -a "$KVER"

echo "=== 5. Updating initramfs for ${KVER} ==="
if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u -k "$KVER"
fi

echo "=== 6. Configuring auto-loaded modules & BLE startup service ==="
cat <<'EOF' > /etc/modules-load.d/cc33xx.conf
cc33xx_sdio
btti_uart
EOF

if [ -f "${SCRIPT_DIR}/cc33xx-ble-enable.sh" ]; then
  cp "${SCRIPT_DIR}/cc33xx-ble-enable.sh" /usr/local/sbin/cc33xx-ble-enable.sh
else
  cat <<'EOF' > /usr/local/sbin/cc33xx-ble-enable.sh
#!/bin/bash
set -euo pipefail
ble_file=""
for _ in $(seq 1 60); do
  ble_file=$(ls /sys/kernel/debug/ieee80211/phy*/cc33xx/ble_enable 2>/dev/null | head -n 1 || true)
  [ -n "$ble_file" ] && [ -e "$ble_file" ] && break
  sleep 0.5
done
[ -n "$ble_file" ] && [ -e "$ble_file" ] || exit 1
[ "$(cat "$ble_file" 2>/dev/null || echo 0)" = "1" ] || echo 1 > "$ble_file"
for _ in $(seq 1 30); do
  [ -d /sys/class/bluetooth/hci0 ] && break
  sleep 0.5
done
[ -d /sys/class/bluetooth/hci0 ] || exit 1
for rf in /sys/class/rfkill/rfkill*; do
  if [ -f "$rf/type" ] && [ "$(cat "$rf/type" 2>/dev/null)" = "bluetooth" ]; then
    [ "$(cat "$rf/soft" 2>/dev/null)" = "0" ] || echo 0 > "$rf/soft" 2>/dev/null || true
  fi
done
if command -v hciconfig >/dev/null 2>&1; then
  hciconfig hci0 up < /dev/null >/dev/null 2>&1 || true
fi
EOF
fi
chmod 0755 /usr/local/sbin/cc33xx-ble-enable.sh

cat <<'EOF' > /etc/systemd/system/cc33xx-ble-enable.service
[Unit]
Description=Enable TI CC33xx BLE controller via cc33xx debugfs
After=bluetooth.service network.target sys-kernel-debug.mount
Wants=bluetooth.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/cc33xx-ble-enable.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cc33xx-ble-enable.service

if ! command -v bluetoothd >/dev/null 2>&1; then
  echo "=== Installing bluez (userspace Bluetooth daemon) ==="
  if apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bluez; then
    echo "bluez installed cleanly."
  else
    echo "WARNING: failed to auto-install bluez (check network). Run: sudo apt-get install --no-install-recommends bluez" >&2
  fi
fi

sync
echo ""
echo "Kernel bundle installed successfully. Please reboot to switch to the new kernel:"
echo "  sudo reboot"
echo ""
echo "Rollback backups preserved at:"
echo "  /boot/Image.orig, /boot/config-${KVER}.orig, /boot/System.map-${KVER}.orig"
echo "  /lib/modules/${KVER}.orig, /root/headers-sync-orig.tar.gz, /root/boot-orig/"
