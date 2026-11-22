# BeagleY-AI (TI AM67A / J722S) EdgeAI Bring-Up Guide

**中文版: [README.zh-CN.md](README.zh-CN.md)**

A practical, hardware-verified guide to running the full TI EdgeAI hardware stack on a **4 GB BeagleY-AI** on top of standard Ubuntu `apt` (Armbian Noble) — **without** having to build a Yocto image or rebuild the whole Linux kernel.

- **Board**: BeagleY-AI (TI AM67A / J722S, 4 GB LPDDR4) + IMX219 on CSI0
- **OS**: Armbian 26.08 (Ubuntu 24.04 Noble minimal), kernel `6.12.49-vendor-k3-beagle`
- **AI Stack**: TI EdgeAI PSDK 11.02.01.03 (`ti-edgeai` `v11.2.1-beagley.1` debs)
- **Tested**: 2026-11-22 (every command and benchmark below was measured on real hardware)

> **Want prebuilt binaries so you don't have to compile anything?**
> Download the ready-to-use files from [GitHub Release `v1.1.0`](https://github.com/xiaobright/beagley-ai-edgeai-bringup/releases/tag/v1.1.0):
> 1. `k3-am67a-beagley-ai-edgeai-csi0-imx219-patched.dtb` — Golden DTB with 4 GB EdgeAI carveouts, CSI0 IMX219, e5010 IRQ fix, 1.4 GHz CPU OPP table, and 80 °C passive thermal throttling
> 2. `cc33xx-drivers-6.12.49-vendor-k3-beagle.tar.gz` — Prebuilt onboard Wi-Fi 6 kernel modules + `install.sh`
> 3. `r5fw.elf` — Minimal bare-metal Cortex-R5F test firmware (Appendix)
>
> Follow **Sections 1 → 9** in order for a clean setup, or jump straight to **Section 10 (Error Lookup Table)** if you hit an error.

---

## 1. What Works & Measured Baselines

| Capability | Status | Measured Result |
|---|---|---|
| Onboard Wi-Fi 6 (TI CC3300) | ✅ Working | 2.4 GHz Wi-Fi 6 (`HE-MCS 7`), 86.0 MBit/s RX PHY rate, auto-connect on boot |
| Onboard Bluetooth (CC3300 BLE) | ❌ Not active | `btti_uart.ko` builds & loads, but kernel disables `CONFIG_BT_LE` & `CONFIG_CFG80211_DEBUGFS` (§5.5) |
| CPU DVFS + Thermal Throttling | ✅ Fixed | 7 steps (200 MHz – 1.4 GHz); 80 °C passive throttling bound in all 3 thermal zones; 60 s load @ 54.8 °C |
| GPU (PowerVR BXS-4-64) | ✅ Working | OpenGL ES 3.2 via `/dev/dri/card1` + `renderD128` (requires DKMS rebuild, §6) |
| JPEG Encoder (e5010) | ✅ Working | ~**39.7 fps** @ 1080p (after fixing the DTB IRQ collision) |
| H.264 / HEVC Encode (wave5) | ✅ Working | H.264 **38.6 fps** @ 1080p / **79.3 fps** @ 720p; HEVC **39.6 fps** @ 1080p |
| Dual C7x + TIDL Inference | ✅ Working | MobileNetV1 **4.62 ms** (34/34 ops), RegNetX **7.29 ms** (103/103 nodes), `cpu_fallback = 0` |
| IMX219 + VPAC ISP | ✅ Working | **30.09 fps** @ 1080p; ISP → H.264 encode **29.7 fps** |
| Power Draw (USB meter) | — | **5.4 W** idle, **6.1 W** (4 cores @ 1.4 GHz full load) |

---

## 2. Why This OS Choice

| Option | Kernel | C7x / TIDL | GPU | Package Manager | Verdict |
|---|---|---|---|---|---|
| BeagleBoard Official Debian 13 | mainline `v7.3.x-k3` | ❌ | ✅ | ✅ `apt` | Maintainers explicitly stopped rebuilding TI's EdgeAI stack for Debian |
| BeagleBoard TI EdgeAI Image | vendor | ✅ | inconsistent | ❌ None (Yocto) | Frozen at 2025-09 (PSDK 11.00); hard to add normal packages |
| **Armbian Noble + TI EdgeAI debs** | vendor `6.12.49` | ✅ | ✅ (DKMS fix) | ✅ Ubuntu 24.04 `apt` | **This guide: full EdgeAI acceleration + standard `apt` ecosystem** |
| Custom TI Yocto Build | vendor | ✅ | ✅ | ❌ None | Only officially supported full path, high build overhead |

The hard technical constraint is that TI's C7x/R5F accelerators depend on vendor kernel drivers and exact `vision-apps-*` reserved-memory carveouts in the device tree, which mainline kernels lack. Using TI Sandbox's [`BeagleY-EdgeAI-Demos`](https://github.com/TexasInstruments-Sandbox/BeagleY-EdgeAI-Demos) deb packages on Armbian Ubuntu Noble solves both problems at once.

---

## 3. Flashing & Installing EdgeAI Base Packages

### 3.1 Flash the **Minimal** Image (Do Not Use the GNOME Image)

Download from [`BeagleY-EdgeAI-Demos v11.2.1-beagley.1`](https://github.com/TexasInstruments-Sandbox/BeagleY-EdgeAI-Demos/releases/tag/v11.2.1-beagley.1):

- `armbian-beagley-ai-noble-vendor-6.12.49-minimal-base-20260715.img.xz`

> **⚠️ Do NOT flash the `-gnome-wayland-mid-` image on a 4 GB BeagleY-AI.**
> On the exact same microSD card and 5 V / 3 A power supply, the GNOME image gets stuck at red LED / 2.1 W with no HDMI, no Ethernet, and unresponsive power button; the `minimal` image boots immediately. Install a lightweight desktop afterward via `apt` if you need a GUI.

Flash with balenaEtcher or `dd`, connect Ethernet, find the board's IP on your router, and log in over SSH (`root` / `1234`, changed on first login).

### 3.2 Install TI EdgeAI 11.02 Packages

```sh
TAG=v11.2.1-beagley.1
BASE="https://github.com/TexasInstruments-Sandbox/BeagleY-EdgeAI-Demos/releases/download/${TAG}"
ASSET="beagley-edgeai-all-debs-j722s-psdk-11.02.01.03.tar.xz"

curl -fLO "${BASE}/${ASSET}"
tar -xJf "${ASSET}"
cd beagley-edgeai-j722s-psdk-11.02.01.03

# Dry-run check first
sudo ./install-j722s-release.sh --debs debs --kernel kernel --camera imx219 --dry-run

# Install (replace `imx219` with `none` if you have no CSI camera)
sudo ./install-j722s-release.sh --debs debs --kernel kernel --camera imx219 --reboot
```

---

## 4. Fix the Device Tree (DTB) — The Most Common Failure Point

### 4.1 Why `armbianEnv.txt` `fdtfile=` Is Ignored

Unlike typical Armbian boards, this boot chain runs `/boot/uEnv.txt` → `bootcmd_ti_mmc`, which hardcodes loading `/boot/dtb/ti/k3-am67a-beagley-ai.dtb` and **silently ignores `fdtfile=` in `/boot/armbianEnv.txt`**. Without the EdgeAI DTB, C7x fails to boot firmware with `remoteproc: bad phdr da 0xa3ffec00`.

### 4.2 Four Fixes Applied to the Active DTB

1. **EdgeAI 4 GB carveouts + CSI0 IMX219** (from `k3-am67a-beagley-ai-edgeai-csi0-imx219.dtb`).
2. **e5010 JPEG IRQ conflict**: TI's `k3-am62p-j722s-common-main.dtsi` assigns a dummy deep-sleep wakeup interrupt (`GIC_SPI 98`) to `pinctrl@f4000`, which collides with `e5010@fd20000` (`-EBUSY`). Removing `interrupts`, `interrupt-controller`, and `#interrupt-cells` from `pinctrl@f4000` fixes JPEG hardware encoding immediately.
3. **1.4 GHz CPU DVFS**: Adds `/cpus/opp-table` (200 MHz – 1.4 GHz) and binds `operating-points-v2` + `#cooling-cells` to `cpu@0..3` so `cpufreq-dt` probes (instead of sitting locked at 1.2 GHz).
4. **80 °C Passive Thermal Throttling**: Adds 80 °C passive trips (`hysteresis = 5000`) and binds `cpufreq-cpu0` in `cooling-maps` across `main0-thermal`, `main1-thermal`, and `main2-thermal` while keeping the `pwm-fan` maps intact.

#### Option A (Fastest): Download Prebuilt Golden DTB from Release `v1.1.0`

```sh
sudo mkdir -p /root/dtb-good
sudo curl -fL "https://github.com/xiaobright/beagley-ai-edgeai-bringup/releases/download/v1.1.0/k3-am67a-beagley-ai-edgeai-csi0-imx219-patched.dtb" \
  -o /root/dtb-good/k3-am67a-beagley-ai.dtb.golden

# Verify SHA256: 10227dd8aa5bebafdd39d4f36a73e4ea3c49b0d6ec2208499300936e740fdc54
sha256sum /root/dtb-good/k3-am67a-beagley-ai.dtb.golden

sudo cp -n /boot/dtb/ti/k3-am67a-beagley-ai.dtb /boot/dtb/ti/k3-am67a-beagley-ai.dtb.orig
sudo cp -f /root/dtb-good/k3-am67a-beagley-ai.dtb.golden /boot/dtb/ti/k3-am67a-beagley-ai.dtb
sync && sudo reboot
```

#### Option B: Patch Your Own DTB with the Repo Script

```sh
sudo apt-get install -y device-tree-compiler
sudo python3 scripts/patch-dtb-opp-thermal.py \
  /boot/dtb/ti/k3-am67a-beagley-ai-edgeai-csi0-imx219.dtb \
  /root/dtb-good/k3-am67a-beagley-ai.dtb.golden

sudo cp -n /boot/dtb/ti/k3-am67a-beagley-ai.dtb /boot/dtb/ti/k3-am67a-beagley-ai.dtb.orig
sudo cp -f /root/dtb-good/k3-am67a-beagley-ai.dtb.golden /boot/dtb/ti/k3-am67a-beagley-ai.dtb
sync && sudo reboot
```

### 4.3 Verify After Reboot

```sh
for i in 0 1 2 3 4; do echo -n "remoteproc$i: "; cat /sys/class/remoteproc/remoteproc$i/state; done
# Expected: running / running / offline / attached / running

dmesg | grep e5010
# Expected: e5010 fd20000.e5010: Device registered as /dev/video8 (number may vary)

cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
# Expected: 200000 400000 600000 800000 1000000 1250000 1400000

ls -l /sys/class/thermal/thermal_zone0/cdev*
# Expected: cdev0..2 -> pwm-fan, cdev3 -> cpufreq-cpu0
```

---

## 5. Onboard Wi-Fi 6 (TI CC3300) & Bluetooth Status

### 5.1 Why Wi-Fi Doesn't Work Out of the Box

The CC3300 SDIO device (`mmc2:0001:2`, `0x0097:0x4077`), DTB node (`ti,cc3300`), and firmware files (`/lib/firmware/ti-connectivity/cc33xx_*.bin`) are all present, **but Armbian left `# CONFIG_CC33XX is not set` in the kernel config**.

Because `CONFIG_MODVERSIONS` and `CONFIG_MODULE_SIG` are both **disabled**, and the board has matching kernel headers + `Module.symvers` + the exact same `gcc 13.3.0`, you do **not** need to rebuild the whole kernel — compiling `cc33xx.ko` and `cc33xx_sdio.ko` out-of-tree works cleanly.

### 5.2 Option A (Recommended): Install Prebuilt Release Modules

For `6.12.49-vendor-k3-beagle`:

```sh
curl -fLO "https://github.com/xiaobright/beagley-ai-edgeai-bringup/releases/download/v1.1.0/cc33xx-drivers-6.12.49-vendor-k3-beagle.tar.gz"
tar -xzf cc33xx-drivers-6.12.49-vendor-k3-beagle.tar.gz
sudo sh install.sh

iw dev
sudo ip link set wlan0 up
sudo iw dev wlan0 scan | grep -E 'SSID:|signal:' | head -n 20
```

### 5.3 Option B: Build from Source Yourself

> **Do NOT use mainline `kernel.org` `linux-6.12.49`!** Mainline 6.12 does not contain `cc33xx`.
> The exact matching source is `https://github.com/beagleboard/linux`, branch **`v6.12.49-ti-arm64-r56`** (verified commit `8fb21420a704ea36aaf66df8288ed8ee9da2762d`, whose `Kconfig` and `Makefile` match `/lib/modules/6.12.49-vendor-k3-beagle/build/drivers/net/wireless/ti/cc33xx/` byte-for-byte).
>
> Also copy all `.h` files from `net/mac80211/` into a sibling `../net/mac80211/` directory because `cc33xx/main.c` and `debugfs.c` use `#include "../net/mac80211/ieee80211_i.h"`.

Once your directory has `src-drivers/cc33xx/` and `src-drivers/net/mac80211/*.h`, build natively on the board (~38 seconds):

```sh
cd src-drivers/cc33xx
make -j4 -C /lib/modules/$(uname -r)/build M="$PWD" \
  CONFIG_CC33XX=m CONFIG_CC33XX_SDIO=m modules

modinfo cc33xx.ko cc33xx_sdio.ko | grep -E 'filename|vermagic|depends'
# Must say: vermagic: 6.12.49-vendor-k3-beagle SMP preempt mod_unload aarch64

sudo make -C /lib/modules/$(uname -r)/build M="$PWD" \
  CONFIG_CC33XX=m CONFIG_CC33XX_SDIO=m modules_install
sudo depmod -a
echo cc33xx_sdio | sudo tee /etc/modules-load.d/cc33xx.conf
sudo modprobe cc33xx_sdio
```

### 5.4 Auto-Connect via Netplan (Without Breaking `eth0`)

`/etc/netplan/10-dhcp-all-interfaces.yaml` only matches `e*` interfaces. Create `/etc/netplan/20-wlan0.yaml`:

```sh
sudo tee /etc/netplan/20-wlan0.yaml >/dev/null <<'EOF'
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
EOF
sudo chmod 600 /etc/netplan/20-wlan0.yaml
sudo netplan apply
```

Key notes:
- Both `dhcp4-overrides` and `dhcp6-overrides` **must** specify the same `route-metric` (`200`), or `netplan apply` fails.
- Metric `200` keeps wired `eth0` (metric `100`) as the default gateway so SSH over Ethernet never drops.
- `optional: true` prevents boot delays when Wi-Fi is out of range.
- CC3300 is 2.4 GHz 1×1 Wi-Fi 6 only (no 5 GHz); measured PHY link hit `HE-MCS 7` (86.0 MBit/s RX), real throughput ~20–40 Mbps.

### 5.5 Onboard Bluetooth Status (`btti_uart.ko`)

`btti_uart.ko` (from `drivers/bluetooth/btti_uart.c` + `h4_recv.h`) builds cleanly and is included in the Release tarball, **but `install.sh` intentionally does not auto-load it** because of two kernel config limits in `6.12.49-vendor-k3-beagle`:
1. `cc33xx` only exposes its `BLE_ENABLE` firmware trigger via debugfs (`/sys/kernel/debug/ieee80211/phy0/cc33xx/ble_enable`), which is missing because `# CONFIG_CFG80211_DEBUGFS is not set`;
2. The kernel has **`# CONFIG_BT_LE is not set`** (only Classic BR/EDR is compiled in), whereas CC3300/BM3301 only supports **BLE 5.4**.

Unless you rebuild the full kernel with `CONFIG_BT_LE=y` and `CONFIG_CFG80211_DEBUGFS=y`, use a USB Bluetooth dongle if you need Bluetooth.

---

## 6. Restore the GPU (PowerVR BXS-4-64)

Installing the EdgeAI kernel replaces the running kernel without rebuilding `ti-img-rogue-driver` via DKMS, so `/dev/dri` silently loses `card1` and `renderD128` with zero warnings. Rebuild it for the running kernel:

```sh
VER=$(dkms status | grep ti-img-rogue-driver | head -1 | sed 's/.*ti-img-rogue-driver\/\([^,]*\),.*/\1/')
sudo PVR_BUILD_DIR=am62p_linux WINDOW_SYSTEM=wayland \
  dkms install "ti-img-rogue-driver/${VER}" -k "$(uname -r)" --force
sudo modprobe pvrsrvkm

ls /dev/dri/                      # Expect: by-path  card0  card1  renderD128
eglinfo 2>/dev/null | head -n 20  # Expect: PowerVR B-Series BXS-4-64 / OpenGL ES 3.2
```

---

## 7. IMX219 Camera + VPAC ISP + Hardware Video/JPEG Encode

- Connect IMX219 to **CSI0** (`CSI1` shares its PHY with `DSI0`).
- After every reboot (or after any `media-ctl -r`), initialize the media links with [`scripts/setup-camera.sh`](scripts/setup-camera.sh):

```sh
sudo sh scripts/setup-camera.sh
```

Check `v4l2-ctl --list-devices` if `/dev/video2` or `/dev/v4l-subdev2` numbers shift across boots.

### ISP Snapshot & Hardware Encode Commands

```sh
DCC=/opt/imaging/imx219/linear

# 1. IMX219 -> VPAC ISP -> JPEG snapshots
gst-launch-1.0 -v \
  v4l2src device=/dev/video2 io-mode=dmabuf num-buffers=5 ! \
  video/x-bayer,width=1920,height=1080,format=rggb,framerate=30/1 ! \
  tiovxisp sensor-name=SENSOR_SONY_IMX219_RPI \
    dcc-isp-file=$DCC/dcc_viss_1920x1080.bin \
    format-msb=7 \
    sink_0::dcc-2a-file=$DCC/dcc_2a_1920x1080.bin \
    sink_0::ae-mode=1 \
    sink_0::device=/dev/v4l-subdev2 ! \
  video/x-raw,format=NV12,width=1920,height=1080 ! \
  videoconvert ! jpegenc ! multifilesink location=/tmp/frame%02d.jpg

# 2. e5010 hardware JPEG benchmark (~39.7 fps @ 1080p)
gst-launch-1.0 -q videotestsrc num-buffers=100 ! \
  video/x-raw,width=1920,height=1080,format=NV12 ! v4l2jpegenc ! fakesink

# 3. IMX219 -> VPAC ISP -> wave5 H.264 encode (29.7 fps @ 1080p)
gst-launch-1.0 -e \
  v4l2src device=/dev/video2 io-mode=dmabuf num-buffers=300 ! \
  video/x-bayer,width=1920,height=1080,format=rggb,framerate=30/1 ! \
  tiovxisp sensor-name=SENSOR_SONY_IMX219_RPI \
    dcc-isp-file=$DCC/dcc_viss_1920x1080.bin format-msb=7 \
    sink_0::dcc-2a-file=$DCC/dcc_2a_1920x1080.bin \
    sink_0::ae-mode=1 sink_0::device=/dev/v4l-subdev2 ! \
  video/x-raw,format=NV12,width=1920,height=1080 ! \
  v4l2h264enc ! h264parse ! mpegtsmux ! filesink location=/tmp/cam.ts
```

Three critical `tiovxisp` details:
1. `dcc-2a-file` is a **pad property** (`sink_0::dcc-2a-file=...`), whereas `dcc-isp-file` is an element property.
2. `format-msb=7` is mandatory for 8-bit Bayer input (omitting it produces dark/green images).
3. `sink_0::ae-mode=1` + manual `exposure`/`analogue_gain` avoids auto-AE crushing dark scenes to black.
4. Feeding `tiovxisp` NV12 directly into `v4l2jpegenc` causes stride striping; insert `videoconvert` in between (`v4l2h264enc` accepts ISP NV12 directly).

---

## 8. Verify C7x + TIDL AI Inference

```sh
sudo systemctl disable --now ti-edgeai-dachshund-gatekeeper
sudo validate-j722s-edgeai
```

Must finish with `TI EDGEAI RUNTIME VALIDATION: PASS` (measured: ONNX `regnetx-200mf` 103/103 nodes in **7.29 ms**, TFLite `mobilenet_v1` 34/34 ops in **4.62 ms**, `cpu_ep_fallback=disabled`).

To view the web UI demo at `http://<BOARD_IP>:8088`:

```sh
sudo systemctl start ti-edgeai-dachshund-gatekeeper
curl -s http://127.0.0.1:8088/api/status | python3 -m json.tool
```

> Note: `gatekeeper` hardcodes `COCO_DOG_LABEL = 16` — pointing the camera at a person or hand always returns `present: false`. Use a dog photo or the bundled video clip to test end-to-end classification.

---

## 9. Hold All 15 Critical Packages (Protect Your Setup from `apt upgrade`)

Hold all **15** interdependent packages (including the two pinned `+ti1` GStreamer packages and `libgbm1-pvr`):

```sh
sudo apt-mark hold \
  armbian-bsp-cli-beagley-ai-vendor \
  armbian-firmware \
  gstreamer1.0-plugins-good \
  libgbm1-pvr \
  libgstreamer-plugins-good1.0-0 \
  linux-dtb-vendor-k3-beagle \
  linux-headers-vendor-k3-beagle \
  linux-image-vendor-k3-beagle \
  linux-u-boot-beagley-ai-vendor \
  ti-edgeai \
  ti-edgeai-firmware-j722s \
  ti-img-rogue-driver-am62p-dkms \
  ti-img-rogue-firmware-am62p \
  ti-img-rogue-tools-am62p \
  ti-img-rogue-umlibs-am62p

apt-mark showhold | wc -l    # Expect: 15
apt-get -s upgrade | grep -E '^(Inst|Remv) (linux-|ti-img|ti-edgeai|armbian-|gstreamer|libgbm1-pvr)'
# Expect empty output
```

If `/boot/dtb/ti/k3-am67a-beagley-ai.dtb` ever gets overwritten, restore your golden copy with [`scripts/reapply-edgeai-dtb.sh`](scripts/reapply-edgeai-dtb.sh) and reboot.

---

## 10. Error Signature Lookup Table

| Error / Symptom | Root Cause | Fix |
|---|---|---|
| `remoteproc: bad phdr da 0xa3ffec00` / `Failed to load program segments: -22` | Wrong DTB loaded (`armbianEnv.txt` `fdtfile` is ignored by `uEnv.txt`) | §4: overwrite `/boot/dtb/ti/k3-am67a-beagley-ai.dtb` |
| `/dev/dri` only has `card0`, no PowerVR (silent) | `pvrsrvkm` DKMS not rebuilt for EdgeAI kernel | §6: `dkms install ti-img-rogue-driver/... -k $(uname -r) --force` |
| `genirq: Flags mismatch irq ... (e5010) vs. (pinctrl)` → `-EBUSY` | Dummy wakeup IRQ 98 on `pinctrl@f4000` collides with `e5010` | §4: use patched DTB (strips 3 IRQ props from `pinctrl@f4000`) |
| `-gnome-wayland-mid-` image stuck at red LED / 2.1 W | GNOME image fails to boot on 4 GB BeagleY-AI | §3.1: flash the `minimal` image |
| `Unable to init TIOVX module` | Shared generic error for 3 unrelated causes | Run with `GST_DEBUG=3` and check the next 3 rows |
| `Unable to open 2A config file: (null)` or `no property "dcc-2a-file"` | `dcc-2a-file` is a pad property | Use `sink_0::dcc-2a-file=...` |
| `TIVX_CMD_NODE_CREATE failed ... com.ti.hwa.vpac_viss` | VISS HWA wedged from prior killed pipeline or CMA exhaustion | `reboot`; check CMA if persistent |
| `cma: __cma_alloc ... alloc failed` / `dma alloc of size 33554432 failed` | CMA fragmented; wave5 cannot allocate 32 MB contiguous | `reboot` to clear fragmentation |
| Pipeline `PLAYING` with 0 frames / 0-byte file | Forgot `setup-camera.sh` after `media-ctl -r`, VISS wedged, or `tiovxmultiscaler` used | Run `setup-camera.sh`; avoid `tiovxmultiscaler` |
| Camera frames all black or dim/green | Auto-AE crushed exposure or missing `format-msb=7` | Add `format-msb=7` and `sink_0::ae-mode=1` |
| `validate-j722s-edgeai` hangs | `ti-edgeai-dachshund-gatekeeper` holds TIDL/TIOVX lock | `sudo systemctl disable --now ti-edgeai-dachshund-gatekeeper` & reboot |
| `netplan apply` errors on `dhcp4_overrides` vs `dhcp6_overrides` | `dhcp6: yes` requires matching `dhcp6-overrides: { route-metric: 200 }` | §5.4: set both metrics identically |
| `fatal error: ../net/mac80211/ieee80211_i.h: No such file` | Out-of-tree `cc33xx` build missing internal `mac80211` headers | §5.3: include `net/mac80211/*.h` from `beagleboard/linux` (or use Release tarball) |
| `echo stop > .../remoteprocN/state` times out after 5 s (`-16`) | K3 firmware stop requires mailbox handshake not implemented by bare-metal / some TI firmwares | `reboot` |
| `onnxruntime ... Failed to open "/sys/class/drm/card1/device/vendor"` | Harmless warning (PowerVR lacks `vendor` sysfs file) | Ignore |

---

## 11. Known Upstream Limits, Power & Thermal Throttling

- **No `cpuidle`**: Upstream J722S DTS defines no `cpu-idle-states`. Capping A53 max frequency at 600 MHz still draws **5.4 W** idle, while unlocking 1.4 GHz adds only **0.1 W** at full 4-core load (**6.1 W** vs 6.0 W) for +17% performance.
- **`tiovxmultiscaler` emits 0 frames** even after successful caps negotiation; avoid it and use NEON OpenCV (`COLOR_YUV2BGR_NV12`) in Python instead of `videoconvert` if you need higher camera AI throughput.
- **VISS can wedge** after multiple `tiovxisp` runs until reboot.
- **Mainline `powervr` driver panics** on probe (`external abort`); always use TI's DKMS `pvrsrvkm`.
- **Thermal throttling verified**: Writing `85000` (85 °C) to `/sys/class/thermal/thermal_zone0/emul_temp` triggers `cooling_device0/cur_state = 1`, capping `scaling_max_freq` from `1400000` to `1250000` (and manual state `4` caps to `600000`); clearing `emul_temp` (`0`) immediately restores `1400000`.

---

## 12. Appendix: Bare-Metal On-Chip MCU (`Cortex-R5F`)

Only `remoteproc2` (`79000000.r5f`, MCU domain) is free (`remoteproc3` is the system Device Manager — never touch; `remoteproc4` runs `vision_apps`). Because BeagleY-AI exposes no MCU-domain UART/SPI/MCAN pins on the 40-pin header without soldering test points, we kept the MCU idle in daily use (~0.05 W saved) and preserved the 184-byte bare-metal shared-memory test (`15,289 iters/s`, `r5fw.elf` in Release `v1.1.0`) under [`mcu-r5f/`](mcu-r5f/). See [`mcu-r5f/README.md`](mcu-r5f/README.md) for the three mandatory K3 boot rules (BTCM at `0x0`, `.resource_table` section, `-marm`).

---

## Repository Contents

- [`scripts/install-cc33xx.sh`](scripts/install-cc33xx.sh) — Prebuilt CC33xx Wi-Fi module installer
- [`scripts/patch-dtb-opp-thermal.py`](scripts/patch-dtb-opp-thermal.py) — Idempotent DTB patcher (e5010 IRQ + 1.4 GHz OPP + 80 °C thermal maps)
- [`scripts/reapply-edgeai-dtb.sh`](scripts/reapply-edgeai-dtb.sh) — Restore golden DTB after accidental overwrite
- [`scripts/setup-camera.sh`](scripts/setup-camera.sh) — IMX219 CSI0 media pipeline setup
- [`mcu-r5f/`](mcu-r5f/) — Minimal Cortex-R5F bare-metal demo
