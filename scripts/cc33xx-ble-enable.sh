#!/bin/bash
# Enable TI CC33xx BLE 5.4 controller via cc33xx debugfs after Wi-Fi/firmware init.
set -euo pipefail

# Wait up to 30s for cc33xx debugfs ble_enable entry
ble_file=""
for _ in $(seq 1 60); do
  ble_file=$(ls /sys/kernel/debug/ieee80211/phy*/cc33xx/ble_enable 2>/dev/null | head -n 1 || true)
  if [ -n "$ble_file" ] && [ -e "$ble_file" ]; then
    break
  fi
  sleep 0.5
done

if [ -z "$ble_file" ] || [ ! -e "$ble_file" ]; then
  echo "cc33xx-ble-enable: debugfs ble_enable not found after timeout" >&2
  exit 1
fi

cur=$(cat "$ble_file" 2>/dev/null || echo 0)
if [ "$cur" != "1" ]; then
  echo 1 > "$ble_file"
fi

# Wait up to 15s for hci0 to register via btti_uart
for _ in $(seq 1 30); do
  if [ -d /sys/class/bluetooth/hci0 ]; then
    break
  fi
  sleep 0.5
done

if [ ! -d /sys/class/bluetooth/hci0 ]; then
  echo "cc33xx-ble-enable: hci0 did not appear after enabling BLE" >&2
  exit 1
fi

# Clear any soft rfkill block on bluetooth without requiring the rfkill binary
for rf in /sys/class/rfkill/rfkill*; do
  if [ -f "$rf/type" ] && [ "$(cat "$rf/type" 2>/dev/null)" = "bluetooth" ]; then
    if [ "$(cat "$rf/soft" 2>/dev/null)" != "0" ]; then
      echo 0 > "$rf/soft" 2>/dev/null || true
    fi
  fi
done

# Ensure HCI device is UP (do not call btmgmt here: BlueZ btmgmt blocks on /dev/null stdin under systemd)
if command -v hciconfig >/dev/null 2>&1; then
  hciconfig hci0 up < /dev/null >/dev/null 2>&1 || true
fi

exit 0
