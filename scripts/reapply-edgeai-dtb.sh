#!/bin/sh
# Restore the known-good BeagleY-AI DTB (EdgeAI carveouts + CSI0/IMX219 +
# e5010 IRQ fix + A53 1.4GHz OPP + 80C passive thermal throttling).
# Used after any linux-dtb upgrade that overwrites /boot/dtb/ti/k3-am67a-beagley-ai.dtb.
set -eu
GOLD=/root/dtb-good/k3-am67a-beagley-ai.dtb.golden
DST=/boot/dtb/ti/k3-am67a-beagley-ai.dtb

[ -f "$GOLD" ] || { echo "FATAL: golden DTB missing: $GOLD" >&2; exit 1; }

[ -f "$DST" ] && cp -f "$DST" "$DST.replaced-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

cp -f "$GOLD" "$DST"
sync

echo "Restored golden DTB -> $DST ($(stat -c %s "$DST") bytes)"
echo "Reboot required."
