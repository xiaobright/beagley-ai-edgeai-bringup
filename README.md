# BeagleY-AI (TI AM67A / J722S) + EdgeAI: bring-up notes

Everything needed to get a BeagleY-AI from a blank SD card to a working
**GPU + VPAC ISP + C7x/TIDL + hardware video encode + cpufreq** stack, plus a
table of every error signature that is *not* documented anywhere.

**中文版: [README.zh-CN.md](README.zh-CN.md)**

- Board: BeagleY-AI, TI AM67A / J722S, 4 GB LPDDR4
- OS: Armbian 26.08.0-trunk noble, kernel `6.12.49-vendor-k3-beagle`
- AI stack: TI EdgeAI PSDK 11.02.01.03 (`ti-edgeai` 11.2.1-beagley.1 debs)
- Tested: 2026-11-22, on real hardware, every command and number below was run

---

## 0. How to read this

This is organised **by symptom, not by procedure**, because the entry point for
most people (and for an AI assistant) is an error message, not "chapter 3".
**Section 9 is the important one** — a table of `exact error → root cause → fix`.
The rest is the ordered path plus verification commands.

If you just want it working: sections 1 → 8 in order.
If something is broken: jump to section 9 and search your error text verbatim.

### What you end up with (all measured)

| Capability | Status | Measured |
|---|---|---|
| CPU DVFS | 200M / 400M / 600M / 800M / 1G / 1.25G / 1.4G | 1.4 GHz, 4 cores, 60 s, no errors |
| GPU (PowerVR BXS-4-64) | OpenGL ES 3.2 | `/dev/dri/card1` + `renderD128` |
| JPEG encoder (e5010) | 1080p | 39.7 fps |
| H.264 / HEVC encode (wave5) | 1080p / 720p | 38.6 / 79.3 fps (1080p at ~31% CPU) |
| C7x + TIDL inference | detector + classifier on both cores | 12.3 ms / 7.5 ms, `cpu_fallback = 0` |
| IMX219 + VPAC ISP | 1080p30 | ISP alone: 30.09 fps |
| camera → ISP → H.264 | 1080p | 29.7 fps (27.8 fps verified by decode) |
| camera → ISP → detect → HTTP | 1080p | 6.4–7.8 fps (bottleneck is a software colour convert, see 8.4) |
| Power | — | 5.4 W idle, 6.1 W with 4 cores at 1.4 GHz |

---

## 1. Which OS (short answer)

| Route | Kernel | C7x / TIDL | GPU | Verdict |
|---|---|---|---|---|
| BeagleBoard Debian | mainline `v7.3.x-k3` | ❌ | ✅ | Debian ecosystem only, no AI |
| BeagleBoard TI EdgeAI image | vendor | ✅ | hit or miss | frozen at 2025-09 (PSDK 11.00), too old |
| **Armbian vendor + EdgeAI debs** | vendor 6.12 | ✅ | ✅ (needs work, §5) | **the path in this document** |
| Self-built Yocto | vendor | ✅ | ✅ | the only officially supported full path, but expensive to build |

The hard constraint: **EdgeAI requires a vendor kernel**, because it needs the
`vision-apps-*` memory carveouts in the device tree. A mainline kernel cannot
provide them.

---

## 2. Flashing and first boot

Image: `armbian-beagley-ai-noble-vendor-6.12.49-*-mid-v11.2.1-beagley.1.img.xz`

> ⚠️ **The GNOME variant (`-gnome-wayland-mid-`) does not boot on the 4 GB board.**
> Symptom: red LED only, 2.1 W, no HDMI, no network, power button does nothing.
> The *same card and the same power supply* with the `minimal` variant boots
> immediately. Use `minimal` and install a desktop yourself if you want one.

Flash with balenaEtcher. Plug in Ethernet, find the IP on your router.

Default credentials: `root` / `1234` (forced password change on first login).

---

## 3. Installing EdgeAI (the biggest trap lives here)

Install the deb set with `dpkg -i`. **Do not reboot yet** — fix the device tree
first, otherwise the C7x will fail to load its firmware.

### 3.1 Why editing `fdtfile` in `armbianEnv.txt` does nothing

The Armbian habit is to set `fdtfile=` in `armbianEnv.txt`. On this board the
boot chain is `uEnv.txt` → `bootcmd_ti_mmc`, which does its own `setenv fdtfile`
and **never reads `armbianEnv.txt`** — silently, with no warning.

Result: EdgeAI is installed, but the base DTB (without `vision-apps` carveouts)
is loaded, and the C7x firmware load fails:

```
remoteproc: bad phdr da 0xa3ffec00
remoteproc: Failed to load program segments: -22
```

### 3.2 The fix: overwrite the DTB filename

```sh
# camera-less EdgeAI DTB
cp -f /boot/dtb/ti/k3-am67a-beagley-ai-edgeai.dtb /boot/dtb/ti/k3-am67a-beagley-ai.dtb

# or, if you want the IMX219 camera (recommended; §7 patches it further)
cp -f /boot/dtb/ti/k3-am67a-beagley-ai-edgeai-csi0-imx219.dtb \
      /boot/dtb/ti/k3-am67a-beagley-ai.dtb
```

> `bootcmd` only ever loads the file named `k3-am67a-beagley-ai.dtb`, so
> overwriting is the only option.

### 3.3 Run the vendor self-test

```sh
validate-j722s-edgeai
```

Expected: `TI EDGEAI RUNTIME VALIDATION: PASS`.

If it hangs, stop the gatekeeper service first — it fights over the TIDL/TIOVX
locks:

```sh
systemctl disable --now ti-edgeai-dachshund-gatekeeper
```

---

## 4. Verify the C7x is actually up

```sh
for i in 0 1 2 3 4; do echo -n "remoteproc$i: "; cat /sys/class/remoteproc/remoteproc$i/state; done
```

```
remoteproc0: running      # C7x-0
remoteproc1: running      # C7x-1
remoteproc2: offline      # MCU R5F (idle)
remoteproc3: attached     # WKUP R5F = Device Manager firmware
remoteproc4: running      # MAIN R5F = vision_apps
```

Device Manager firmware version shows up in `dmesg` as
`ti-sci 44043000.system-controller: ABI: 4.0 (firmware rev 0x000b '11.2.13')`.

---

## 5. Restoring the GPU (it silently disappears after installing EdgeAI)

### 5.1 Symptom

`/dev/dri` only has `card0`, `eglinfo` shows no PowerVR. **No error anywhere** —
easy to conclude the board simply has no GPU.

### 5.2 Root cause

Armbian ships the GPU driver as a **DKMS module** (`pvrsrvkm.ko`). The EdgeAI
debs replace the kernel but do not trigger a DKMS rebuild, so the module only
exists for the previous kernel:

```sh
dkms status
# ti-img-rogue-driver/25.3.xxx, <old kernel>, aarch64: installed   <- old kernel only
```

### 5.3 Fix

```sh
export PVR_BUILD_DIR=am62p_linux        # AM67A uses the am62p build directory
export WINDOW_SYSTEM=wayland
dkms install ti-img-rogue-driver/<version> -k $(uname -r) --force
```

Known-good invocation:

```sh
dkms install ti-img-rogue-driver/25.3.6908880+git20260225+d241b0d5df40 \
    -k $(uname -r) --force
```

Verify:

```sh
ls /dev/dri                      # card1 and renderD128 must appear
eglinfo 2>/dev/null | head -20   # PowerVR B-Series BXS-4-64 / OpenGL ES 3.2
```

> The alternative is lifting `pvrsrvkm.ko` out of the official GNOME image
> (loop-mount the `.img` under WSL), but rebuilding via DKMS is the correct fix.

---

## 6. Fixing the e5010 JPEG encoder (interrupt conflict)

### 6.1 Symptom

```sh
dmesg | grep -i e5010
# genirq: Flags mismatch irq 14. 00000004 (e5010) vs. 00214084 (pinctrl)
# e5010 fd20000.e5010: probe failed: -EBUSY
```

Hardware JPEG encoding is completely unavailable.

### 6.2 Root cause

In the DTB, `pinctrl@f4000` and `e5010@fd20000` **both claim GIC SPI 98 (`0x62`)**.

Upstream `k3-am62a-main.dtsi` defines:

```dts
main_pmx0: pinctrl@f4000 {
	compatible = "pinctrl-single";
	reg = <0x00 0xf4000 0x00 0x25c>;
	#pinctrl-cells = <1>;
	pinctrl-single,register-width = <32>;
	pinctrl-single,function-mask = <0xffffffff>;
};
```

— no `interrupts`, no `interrupt-controller`, no `#interrupt-cells`. Those three
lines were added by whoever built the DTB you are running.

### 6.3 Fix: strip the three properties from `pinctrl@f4000`

```sh
dtc -I dtb -O dts -o /tmp/base.dts /boot/dtb/ti/k3-am67a-beagley-ai.dtb

python3 - <<'PY'
import re
src = open('/tmp/base.dts').read()
out, inside, removed = [], False, []
for line in src.splitlines(True):
    if re.search(r"pinctrl@f4000\s*\{", line):
        inside = True
    elif inside and line.strip() == "};":
        inside = False
    elif inside:
        s = line.strip()
        if s.startswith(('interrupts =', 'interrupt-controller;', '#interrupt-cells')):
            removed.append(s)
            continue
    out.append(line)
open('/tmp/fixed.dts', 'w').write(''.join(out))
print("removed:", removed)
PY

dtc -I dts -O dtb -o /boot/dtb/ti/k3-am67a-beagley-ai.dtb /tmp/fixed.dts
```

`removed` should contain exactly three entries. After reboot:

```sh
dmesg | grep e5010
# e5010 fd20000.e5010: Device registered as /dev/video8
```

Verify throughput (1080p):

```sh
v4l2-ctl --list-devices            # confirm which node e5010 got; numbering varies
gst-launch-1.0 -q v4l2src device=/dev/video8 io-mode=dmabuf num-buffers=100 ! \
  video/x-raw,width=1920,height=1080,format=NV12 ! v4l2jpegenc ! fakesink
# expect ~39.7 fps
```

> A `linux-dtb` package upgrade overwrites this. See §12 for freezing.

---

## 7. Camera: IMX219 + VPAC ISP

### 7.1 Which connector

CSI0 (silk `CSI0`) goes through `cdns_csi2rx.30101000`. CSI1 shares a PHY with
DSI0 — you cannot use a display and a camera on those two at the same time.

### 7.2 Configure the media pipeline

Confirm node numbering first — **it depends on probe order**:

```sh
v4l2-ctl --list-devices
# j721e-csi2rx (platform:30102000.ticsi2rx): /dev/video2 … /dev/video7   <- capture on video2
# wave5-dec / wave5-enc: /dev/video0, /dev/video1
# e5010: /dev/video8
```

Assumes `video2` for capture and `/dev/v4l-subdev2` for the sensor:

```sh
M=/dev/media0
media-ctl -d $M -r
media-ctl -d $M --set-v4l2 '"imx219 4-0010":0[fmt:SRGGB8_1X8/1920x1080]'
media-ctl -d $M --set-v4l2 '"cdns_csi2rx.30101000.csi-bridge":0[fmt:SRGGB8_1X8/1920x1080]'
media-ctl -d $M --set-v4l2 '"cdns_csi2rx.30101000.csi-bridge":1[fmt:SRGGB8_1X8/1920x1080]'
media-ctl -d $M --set-v4l2 '"30102000.ticsi2rx":0[fmt:SRGGB8_1X8/1920x1080]'
media-ctl -d $M --set-v4l2 '"30102000.ticsi2rx":1[fmt:SRGGB8_1X8/1920x1080]'
```

**`media-ctl -r` wipes the formats** — you must re-apply them afterwards,
otherwise the pipeline goes to PLAYING and delivers zero frames (see §9).

### 7.3 Run the ISP

```sh
DCC=/opt/imaging/imx219/linear

v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl exposure=1400
v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl analogue_gain=180

gst-launch-1.0 -v \
  v4l2src device=/dev/video2 io-mode=dmabuf ! \
  video/x-bayer,width=1920,height=1080,format=rggb,framerate=30/1 ! \
  tiovxisp sensor-name=SENSOR_SONY_IMX219_RPI \
    dcc-isp-file=$DCC/dcc_viss_1920x1080.bin \
    format-msb=7 \
    sink_0::dcc-2a-file=$DCC/dcc_2a_1920x1080.bin \
    sink_0::ae-mode=1 \
    sink_0::device=/dev/v4l-subdev2 ! \
  video/x-raw,format=NV12,width=1920,height=1080 ! \
  videoconvert ! jpegenc ! multifilesink location=/tmp/frame%02d.jpg
```

Three things that are not documented anywhere and cost me hours:

1. **`dcc-2a-file` is a PAD property**, so it must be `sink_0::dcc-2a-file=...`.
   Writing `dcc-2a-file=...` gives
   `no property "dcc-2a-file" in element "tiovxisp"`.
   `dcc-isp-file` on the other hand *is* an element property. Inconsistent.
2. **`format-msb=7`** — 8-bit Bayer fed to a 10-bit ISP. Without it the image is
   dark and green-shifted.
3. **`ae-mode=1` (manual AE) plus explicit exposure/gain** — the default auto AE
   will drive `exposure` down to 91 and `analogue_gain` to 0 in a dim scene,
   producing an all-black frame.

### 7.4 Throughput baseline (1080p, 18 s each, counted by `fpsdisplaysink`)

| Segment | Pipeline | fps |
|---|---|---|
| A | sensor → ISP → NV12 | **30.09** |
| B | A + `videoconvert` NV12→BGR | **9.75** ← the bottleneck |
| C | A + `v4l2h264enc` → file | **29.70** |
| D | tee → {BGR} + {H.264} | 12.26 |

**The ISP and the hardware encoder are both fine. The cost is a CPU-side
NV12→BGR conversion**: ~70 ms per 1080p frame against a 33 ms budget.

---

## 8. TIDL end-to-end (the bundled gatekeeper demo)

### 8.1 Start it

```sh
# /etc/default/ti-edgeai-dachshund-gatekeeper
GATEKEEPER_SOURCE=camera        # or "video" for the bundled dachshund clip
GATEKEEPER_VIDEO=/usr/share/ti-edgeai-dachshund-gatekeeper/dachshund-demo.mp4
GATEKEEPER_PORT=8088

systemctl start ti-edgeai-dachshund-gatekeeper
curl -s http://127.0.0.1:8088/api/status | python3 -m json.tool
```

Open `http://<board-ip>:8088` for the stream and the boxes.

### 8.2 ⚠️ The detector only keeps dogs

```python
COCO_DOG_LABEL = 16  # contiguous model index; the COCO category id is 18
if int(label) != COCO_DOG_LABEL or score < self.threshold:
    continue
```

Point it at a person, a hand, a chair — `present` stays `false` forever and the
UI says nothing. **Do not test with your hand**; you will conclude the pipeline
is broken (I did).

### 8.3 Measured

| Metric | Camera source | Bundled video |
|---|---|---|
| fps | 6.4–7.8 | **13.4** |
| detector | 283 nodes, all on C7x-0, 10.5–12.3 ms | `present=true`, score 0.75 |
| classifier | not triggered | Dachshund 0.987, C7x-1, 71 ops, 7.5 ms |
| decision state machine | WATCHING | **AUTHORIZED** |
| `acceleration.active` | false | **true** |
| `cpu_fallback` | 0 | 0 |

The camera path is slower purely because of §7.4-B — not because of the hardware.

### 8.4 Making the camera path faster

`tiovxmultiscaler` (hardware scaling on VPAC) currently **negotiates caps
successfully and then emits zero frames** (§9). So the options are:

- make `appsink` receive **NV12** and convert with
  `cv2.cvtColor(buf, cv2.COLOR_YUV2BGR_NV12)` — OpenCV has NEON paths and is far
  faster than the ORC-based `videoconvert`;
- or `videoscale` down to 640×480 before converting.

---

## 9. Error signature table (**the useful part**)

| Error / symptom | Root cause | Fix |
|---|---|---|
| `remoteproc: bad phdr da 0xa3ffec00` / `Failed to load program segments: -22` | base DTB loaded, no `vision-apps` carveouts (`fdtfile` ignored by the boot script) | §3.2 — `cp` over `k3-am67a-beagley-ai.dtb` |
| `/dev/dri` has only `card0`, no PowerVR in `eglinfo`, **no error** | DKMS module not rebuilt for the new kernel | §5.3 — `dkms install ... -k $(uname -r) --force` |
| `genirq: Flags mismatch irq N. (e5010) vs. (pinctrl)` → `-EBUSY` | `pinctrl@f4000` claims GIC SPI 98 | §6.3 — delete three properties |
| `Unable to init TIOVX module` | **three unrelated causes share this one string**: 2A config path is NULL / VPAC VISS node creation failed / DMA allocation failed | run with `GST_DEBUG=3` to see the real one |
| `Unable to open 2A config file: (null)` | no `dcc-2a-file`, or supplied as an element property | use `sink_0::dcc-2a-file=...` |
| `TIVX_CMD_NODE_CREATE failed for node ... com.ti.hwa.vpac_viss` | VISS hardware instance unavailable: previous pipeline killed without releasing it, or CMA allocation failed | reboot first; if it persists check CMA |
| `no property "dcc-2a-file" in element "tiovxisp"` | it is a pad property | `sink_0::dcc-2a-file=` |
| Pipeline reaches PLAYING, caps negotiated, **zero frames**, output file 0 bytes | ① formats not re-applied after `media-ctl -r` ② VISS wedged ③ `tiovxmultiscaler` itself | re-apply formats; then reboot |
| `cma: __cma_alloc ... alloc failed` / `dma alloc of size 33554432 failed` | CMA fragmentation — 896 MB total but no contiguous 32 MB | reboot; avoid concurrent wave5 encode + ISP |
| `e5010` probe fails although the DTB looks patched | `linux-dtb` upgrade restored the file | §12 recovery script |
| Camera output all black (Y max ≈ 8) | auto AE drove exposure to 91 and gain to 0 | `sink_0::ae-mode=1` + manual exposure/gain |
| Camera output dark and green | 8-bit Bayer alignment not declared | add `format-msb=7` |
| Striped JPEG straight from ISP NV12 | stride mismatch | insert `videoconvert` |
| gatekeeper `present` never becomes true | detector keeps COCO class 16 (dog) only | use a real dog, or `--source video` to validate the chain |
| `onnxruntime ... GPU device discovery failed: /sys/class/drm/card1/device/vendor` | PowerVR exposes no `vendor` sysfs attribute | harmless, ignore |
| `pkill -f 'while :'` does not stop load generators | `sh` in a tight loop defers SIGTERM | `pkill -9 -f`, or use a script with `timeout` |
| `validate-j722s-edgeai` hangs | gatekeeper and the self-test fight over the TIDL/TIOVX lock | `systemctl disable --now ti-edgeai-dachshund-gatekeeper`, then reboot |
| `echo stop > .../remoteproc4/state` → `timedout waiting for rproc completion event` | vision_apps firmware has no graceful stop | move `/lib/firmware/j722s-c71_*-fw` symlinks away, then reboot |

---

## 10. Adding cpufreq (and unlocking 1.4 GHz)

### 10.1 Symptom and root cause

`/sys/devices/system/cpu/cpufreq/` does not exist and the cluster is pinned at
**1.2 GHz** — not the 1.4 GHz on the product page.

The driver is present (`CONFIG_CPUFREQ_DT=y`, `dt_cpufreq_probe` is in
`kallsyms`). What fails is the instantiation check in `cpufreq-dt-platdev`:

```c
match = of_match_node(allowlist, np);   /* only ti,am625 / am62a7 / am62p5 */
if (match) goto create_pdev;
if (cpu0_node_has_opp_v2_prop() && !of_match_node(blocklist, np)) goto create_pdev;
```

BeagleY reports `beagle,am67a-beagley-ai` / `ti,j722s` — not in the allowlist —
and the DT has no OPP table on `cpu0`, so the platform device is never created.

### 10.2 Verify 1.4 GHz safely before touching the DTB

Do not gamble on boot. Probe it at runtime with a throwaway module:

```c
// a53test.c
#include <linux/module.h>
#include <linux/clk.h>
#include <linux/clk-provider.h>
#include <linux/of.h>

static int rate = 1400000000;
module_param(rate, int, 0444);

static int __init t(void) {
    struct clk *c = of_clk_get(of_find_node_by_path("/cpus/cpu@0"), 0);
    if (IS_ERR(c))
        return PTR_ERR(c);
    pr_info("a53test: %lu -> set=%d -> %lu\n",
            clk_get_rate(c), clk_set_rate(c, rate), clk_get_rate(c));
    clk_put(c);
    return -EINVAL;      /* force unload */
}
module_init(t);
MODULE_LICENSE("GPL");
```

```sh
insmod a53test.ko rate=1400000000; dmesg | grep a53test
# a53test: 1000000000 -> set=0 -> 1400000000
# set=0 means the DM firmware accepted the rate
```

### 10.3 Patch the OPP table into the DTB

Add one table under `/cpus`, and two properties to every `cpu@N`:

```dts
	cpus {
		cpu_opp_table: opp-table {
			compatible = "operating-points-v2";
			opp-shared;
			phandle = <0x1f0>;

			opp-200000000  { opp-hz = /bits/ 64 <200000000>;  opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
			opp-400000000  { opp-hz = /bits/ 64 <400000000>;  opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
			opp-600000000  { opp-hz = /bits/ 64 <600000000>;  opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
			opp-800000000  { opp-hz = /bits/ 64 <800000000>;  opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
			opp-1000000000 { opp-hz = /bits/ 64 <1000000000>; opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
			opp-1250000000 { opp-hz = /bits/ 64 <1250000000>; opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
			opp-1400000000 { opp-hz = /bits/ 64 <1400000000>; opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
		};

		cpu@0 {
			/* ... */
			operating-points-v2 = <0x1f0>;
			#cooling-cells = <0x02>;
			clocks = <0x07 0x87 0x00>;
		};
	};
```

`phandle` values are numbers in a decompiled DTS; pick an unused one (e.g.
`0x1f0`) and reference it from all four CPU nodes.

Verify:

```sh
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
# 200000 400000 600000 800000 1000000 1250000 1400000
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_driver   # cpufreq-dt
```

### 10.4 Proving DVFS actually works

Fixed workload at three frequencies — time must be inversely proportional:

| Frequency | Time |
|---|---|
| 200 MHz | 17.5 s |
| 600 MHz | 5.5 s |
| 1200 MHz | 2.75 s |

Adding `#cooling-cells` also registers a `cpufreq-cpu0` cooling device, so
thermal management can now throttle by frequency, not just spin the fan.

### 10.5 There is no cpuidle — don't chase it

Upstream `k3-am62.dtsi`, `k3-j722s.dtsi` and `k3-am67a-beagley-ai.dts` contain
**no** `cpu-idle-states` and no `psci-suspend-param`. This is not a missing
property; TI has never described J722S low-power states in mainline. Inventing
idle states is high risk (idle is entered hundreds of times per second) and is
not recommended.

---

## 11. Power measurements (USB power meter, 5 V)

| Scenario | Power |
|---|---|
| Idle, frequency not unlocked (pinned 1.2 GHz) | 5.4 W |
| Idle, capped at 600 MHz | **5.4 W (no change)** |
| Idle, C7x firmware stopped | 5.2 W |
| 4 cores loaded @ 1.2 GHz | 6.0 W |
| 4 cores loaded @ 1.4 GHz | **6.1 W** |

1. **Downclocking buys nothing at idle** — without cpuidle the CPU only lowers
   its clock and never enters a low-power state; A53 dynamic power is a small
   slice to begin with.
2. **1.2 → 1.4 GHz costs 0.1 W (+1.7%) at full load and gains 17% throughput.**
   Keep 1.4 GHz — it is also better for burst work (race to idle).
3. **5.4 W is the board floor.** Four A53 cores at 1.4 GHz contribute 0.7 W
   total; the other ~5 W is LPDDR4, PHY/SerDes, PMIC losses, and the always-on
   vision_apps firmware on the C7x + R5F pair.

> **On the "5 V 0.8 A (≈4 W)" figure people report from a fresh install:** that
> is a minimal image with no EdgeAI firmware, no GPU driver, no camera. Once
> configured you additionally power the 2× C7x + MAIN R5F firmware, the GPU
> (`pvrsrvkm` + `card1`), the wave5/e5010/csi2rx/imx219/cdns3 driver set,
> ~207 enabled clock gates, and a 1 Gbps Ethernet PHY. 5.4 W is the realistic
> fully-on floor.

---

## 12. Maintenance: freeze the versions

The dependency chain is brittle — kernel ↔ DTB ↔ DKMS module ↔ EdgeAI firmware
ABI must move together, and one `apt upgrade` can break three of them at once:

```sh
apt-mark hold \
  linux-image-vendor-k3-beagle linux-dtb-vendor-k3-beagle \
  linux-headers-vendor-k3-beagle linux-u-boot-beagley-ai-vendor \
  armbian-bsp-cli-beagley-ai-vendor armbian-firmware \
  ti-img-rogue-driver-am62p-dkms ti-img-rogue-firmware-am62p \
  ti-img-rogue-tools-am62p ti-img-rogue-umlibs-am62p \
  ti-edgeai ti-edgeai-firmware-j722s
```

Verify with a simulation — **`apt list --upgradable` ignores holds and will
still list them**, which is misleading:

```sh
apt-get -s upgrade | grep -E '^(Inst|Remv) (linux|ti-img|ti-edgeai|armbian)'
# expect no output
```

### 12.1 Keep a golden DTB

```sh
mkdir -p /root/dtb-good
cp /boot/dtb/ti/k3-am67a-beagley-ai.dtb /root/dtb-good/k3-am67a-beagley-ai.dtb.golden
```

### 12.2 Recovery script

```sh
#!/bin/sh
# /root/reapply-edgeai-dtb.sh
GOLD=/root/dtb-good/k3-am67a-beagley-ai.dtb.golden
DST=/boot/dtb/ti/k3-am67a-beagley-ai.dtb
[ -f "$GOLD" ] || { echo "golden DTB missing"; exit 1; }
cp -f "$DST" "$DST.replaced-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
cp -f "$GOLD" "$DST"; sync
echo "restored; reboot required"
```

If you ever do want to upgrade the kernel, the order matters:

```sh
apt-mark unhold linux-image-vendor-k3-beagle linux-dtb-vendor-k3-beagle \
                linux-headers-vendor-k3-beagle linux-u-boot-beagley-ai-vendor
apt upgrade
sh /root/reapply-edgeai-dtb.sh          # carveouts + e5010 fix + OPP table
PVR_BUILD_DIR=am62p_linux WINDOW_SYSTEM=wayland \
  dkms install ti-img-rogue-driver/<new version> -k $(uname -r) --force
reboot
```

---

## 13. Post-change self-check

```sh
# 1. C7x / R5F firmware
for i in 0 1 2 3 4; do echo -n "remoteproc$i: "; cat /sys/class/remoteproc/remoteproc$i/state; done
#    expect: running / running / offline / attached / running

# 2. GPU
ls /dev/dri/                       # expect: card0 card1 renderD128

# 3. JPEG encoder
dmesg | grep e5010                 # expect: "registered as /dev/videoN"

# 4. cpufreq
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies

# 5. TIDL chain
systemctl stop ti-edgeai-dachshund-gatekeeper
validate-j722s-edgeai              # expect: PASS
```

---

## 14. Known-unfixable / still broken upstream

Configuration will not help here:

| Issue | Status |
|---|---|
| cpuidle / deep sleep | upstream never described J722S idle states; not possible |
| `tiovxmultiscaler` emits zero frames | caps negotiate, no data, no error (plugin bug) |
| VISS wedges after several `tiovxisp` sessions | reboot is the only recovery |
| `tiovxisp` reports one string for three different failures | use `GST_DEBUG=3` to disambiguate |
| gatekeeper converts 1080p NV12→BGR on the CPU | demo design issue; 30 fps drops to 9.75 |
| GNOME image does not boot on the 4 GB board | use `minimal` |
| mainline `powervr` driver aborts on probe | use the DKMS `pvrsrvkm` instead |

---

## 15. One-line summary

Almost every problem on this board is of the form **"it installs cleanly, then
silently does nothing"**: wrong DTB, missing DKMS rebuild, IRQ conflict, missing
OPP table, AE driving the frame black, a detector that only keeps dogs.

So the debugging order is always the same: **read `dmesg` and `GST_DEBUG=3` for
the real error — never trust the top-level "Unable to init TIOVX module".**

---

## License

MIT. Corrections and additions via issue/PR are welcome.
