#!/bin/sh
# Configure IMX219 + CSI2RX media pipeline on CSI0 (run after each reboot).
set -eu
M=/dev/media0
media-ctl -d "$M" -r
media-ctl -d "$M" --set-v4l2 '"imx219 4-0010":0[fmt:SRGGB8_1X8/1920x1080]'
media-ctl -d "$M" --set-v4l2 '"cdns_csi2rx.30101000.csi-bridge":0[fmt:SRGGB8_1X8/1920x1080]'
media-ctl -d "$M" --set-v4l2 '"cdns_csi2rx.30101000.csi-bridge":1[fmt:SRGGB8_1X8/1920x1080]'
media-ctl -d "$M" --set-v4l2 '"30102000.ticsi2rx":0[fmt:SRGGB8_1X8/1920x1080]'
media-ctl -d "$M" --set-v4l2 '"30102000.ticsi2rx":1[fmt:SRGGB8_1X8/1920x1080]'
v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl "exposure=${1:-1759}"
v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl "analogue_gain=${2:-232}"
echo "camera pipeline ready"
