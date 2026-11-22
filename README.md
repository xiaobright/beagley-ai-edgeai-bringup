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
| `Booting fw image ...` then `Boot failed: -22`, **no other log line** | ELF has no `.resource_table`; `rproc_elf_load_rsc_table()` returns `-EINVAL` silently | §15.4② — add the 16-byte empty table; locate it with `set_graph_function=rproc_boot` |
| `remoteproc2` stays `offline`, `Direct firmware load ... failed with error -2` | no `j722s-mcu-r5f0_0-fw` in the image | §15.2 — build one, or ignore it |
| `echo stop` returns 0 but the state does not change and dmesg stays empty | `rproc->power` refcount is > 1 | `stop` once more; if it still holds, see the row below |
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
| `echo stop > .../remoteprocN/state` hangs 5 s → `timeout waiting for rproc completion event` / `can't stop rproc: -16` | stopping needs a mailbox handshake the firmware does not implement (`vision_apps` and bare-metal firmware alike) | only `reboot`. §15.6 |

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
#    with a self-built MCU firmware: running / running / running / attached / running

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

## 15. The on-chip MCU (R5F)

### 14.1 Three R5Fs, and which one you may touch

| sysfs | bus address | core | role | safe to use |
|---|---|---|---|---|
| `remoteproc2` | `79000000.r5f` | **MCU R5F0_0** | free, no firmware shipped | ✅ |
| `remoteproc3` | `78000000.r5f` | WKUP R5F0_0 | Device Manager (TISCI) | ❌ `attached` |
| `remoteproc4` | `78400000.r5f` | MAIN R5F0_0 | `vision_apps` `mcu2_0` | ⚠️ TIDL needs it |

```sh
for i in 0 1 2 3 4; do echo -n "remoteproc$i $(cat /sys/class/remoteproc/remoteproc$i/name): "; cat /sys/class/remoteproc/remoteproc$i/state; done
# remoteproc0 7e000000.dsp: running      <- C7x-0 (TIDL detect)
# remoteproc1 7e200000.dsp: running      <- C7x-1 (TIDL classify)
# remoteproc2 79000000.r5f: offline      <- MCU R5F, no firmware in the image
# remoteproc3 78000000.r5f: attached     <- DM firmware, never touch
# remoteproc4 78400000.r5f: running      <- vision_apps
```

### 14.2 Why it is always `offline`

```sh
cat /sys/class/remoteproc/remoteproc2/firmware    # j722s-mcu-r5f0_0-fw
ls /lib/firmware/j722s-mcu-r5f0_0-fw               # No such file
```

```
[ 6.167951] remoteproc remoteproc2: 79000000.r5f is available
[ 6.168207] remoteproc remoteproc2: Direct firmware load for j722s-mcu-r5f0_0-fw failed with error -2
```

Nothing is misconfigured. The TI PSDK image simply only ships firmware for the
two C7x and the MAIN R5F; the MCU R5F one is yours to write. **As soon as
`/lib/firmware/j722s-mcu-r5f0_0-fw` exists, remoteproc autoboots it on every
boot** — no service, no DT change.

### 14.3 What it can do — and the hard limit on this board

Cortex-R5F @ 400 MHz, 32 KiB ATCM + 32 KiB BTCM, MPU (no MMU), ECC on TCM,
plus 1 MiB (`@a1000000`) + 15 MiB (`@a1100000`) of DDR carveout. Its selling
point is determinism: unaffected by Linux scheduling or page faults, keeps
running if Linux dies.

The catch on BeagleY-AI is that **the MCU-domain peripherals are not broken
out**:

| peripheral | address | DT status | 40-pin header |
|---|---|---|---|
| MCU_I2C0 | `0x04900000` | **okay**, already owned by Linux (100 kHz) | yes (`hat/mcu_i2c0`) |
| MCU_GPIO0 | `0x04201000` | **okay**, Linux `gpiochip515`, 24 lines | — |
| MCU_UART0 | `0x04a00000` | disabled | ❌ no pinmux |
| MCU_SPI0 / SPI1 | `0x04b00000` / `0x04b10000` | disabled | ❌ no pinmux |
| MCU_MCAN0 / MCAN1 | `0x04e08000` / `0x04e18000` | disabled | ❌ no pinmux |

They are `disabled` in Linux (so nominally free for the R5F), but the board DTS
defines **no pinctrl group at all** for MCU UART/SPI/MCAN, and none of those pins
reach the header. The only MCU-domain function on the 40-pin header is MCU_I2C0,
and Linux owns it.

So: driving real I/O from the R5F requires soldering to test points. Without
that it is just "an extra 400 MHz core that can read and write DDR" — decide
whether that is worth your time before starting.

**Measured verdict (this project ended up disabling it)**: running it costs
about **0.05 W** extra (USB power meter) while giving this board nothing it can
drive and no workload that genuinely needs the core — so it was reverted after
verification. The walkthrough is kept because the three boot constraints and the
unstoppable-`stop` trap apply to other boards too.

### 14.4 Running your own bare-metal firmware (no TI SDK)

All the difficulty is in three conventions.

**① Where the code goes: BTCM sits at R5F address `0x0`**

The DT node has `ti,atcm-enable = 0`, `ti,btcm-enable = 1`, `ti,loczrama = 0`,
and `ti_k3_r5_remoteproc.c` maps it as:

```c
if (!strcmp(data->mems[i].name, "atcm"))
        kproc->mem[i].dev_addr = core->loczrama ? 0 : K3_R5_TCM_DEV_ADDR;   /* 0x41010000 */
else
        kproc->mem[i].dev_addr = core->loczrama ? K3_R5_TCM_DEV_ADDR : 0;
```

`loczrama = 0` → **BTCM is at address `0x0`** (bus address `0x79020000`). The
boot vector comes from the ELF entry point, so **the vector table must be at
`0x0` and entry must be `0x0`**.

Careful: MAIN R5F (`78400000`) has `loczrama = 1`, so its ATCM is at `0x0` and
TI's `vx_app_rtos_linux_mcu2_0.out` also has entry `0x0` — same number,
different memory. That similarity misleads people.

**② The ELF must contain a `.resource_table` section**

This one hurts: on this kernel `rproc_elf_load_rsc_table()` returns `-EINVAL`
when the section is missing, **and logs nothing at all**:

```
remoteproc remoteproc2: Booting fw image j722s-mcu-r5f0_0-fw, size 6952
remoteproc remoteproc2: Boot failed: -22
```

No hint whatsoever. ftrace is the only way in:

```sh
echo rproc_boot > /sys/kernel/tracing/set_graph_function
echo 2 > /sys/kernel/tracing/max_graph_depth
echo function_graph > /sys/kernel/tracing/current_tracer
echo start > /sys/class/remoteproc/remoteproc2/state
grep -v 'printk\|console\|prb_\|nbcon' /sys/kernel/tracing/trace | tail -30
```

```
k3_r5_rproc_prepare()          |   811.675 us
rproc_elf_get_boot_addr()      |     1.870 us
rproc_elf_load_rsc_table()     |     3.315 us   <- returns -22
k3_r5_rproc_unprepare()        |   948.800 us   <- rollback
```

A 16-byte empty table fixes it:

```c
struct resource_table { uint32_t ver, num, reserved[2]; } __attribute__((packed));
__attribute__((section(".resource_table"), used))
static const struct resource_table rsc_tbl = { .ver = 1, .num = 0 };
```

`num = 0` registers no virtio/rpmsg device, which is what a standalone firmware
wants.

**③ ARM state, caches off**

`k3_r5_rproc_configure()` clears `PROC_BOOT_CFG_FLAG_R5_TEINIT` ("always enable
ARM mode"), so the core comes out of reset in ARM state (not Thumb) with caches
off. Compile with `-marm`, write the entry stub in `.arm` assembly, and touch
DDR by physical address — caches being off is a feature here, every store is a
real bus transaction.

The complete buildable version is in [`mcu-r5f/`](mcu-r5f/) — 184 bytes, plain
`arm-none-eabi-gcc`, no SDK, no libc:

```sh
sudo apt install -y --no-install-recommends gcc-arm-none-eabi binutils-arm-none-eabi
cd mcu-r5f && make
sudo cp r5fw.elf /lib/firmware/j722s-mcu-r5f0_0-fw
sudo sh -c 'echo start > /sys/class/remoteproc/remoteproc2/state'
dmesg | tail -3        # remoteproc remoteproc2: remote processor 79000000.r5f is now up
```

> Build it on a PC or in WSL, not on the board. 184 bytes compile instantly on
> an A53, but the moment the MCU+ SDK is involved you are looking at tens of
> thousands of files.
>
> Measured clean build of the same firmware: **95 ms** on WSL (x86_64, 32 cores)
> versus **229 ms** on the A53 (4 cores @ 1.2 GHz) — only 2.4x, because this is
> all process-spawn overhead (`make` + `gcc` + `cc1` + `as` + `ld`, five forks).
> The gap only matters once the file count is real.
>
> The toolchain costs **535 MB** (on-board gcc + binutils, or ~900 MB in WSL with
> newlib) and can be removed afterwards without invalidating an ELF you already
> built: `apt-get remove -y gcc-arm-none-eabi binutils-arm-none-eabi`.

The firmware writes a heartbeat and a handshake word into DDR `0xa1100000` (the
carveout the DT hands to it).

### 14.5 Verifying A53 ↔ R5F in both directions

`no-map` carveouts are outside the kernel linear map, so `/dev/mem` can mmap
them directly:

```python
import mmap, os, struct
f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(f, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xa1100000)
print(struct.unpack("<5I", m[:20]))          # (0xc0de, heartbeat, cmd, echo, stat)
m[8:12] = struct.pack("<I", 0x12345678)      # write cmd
# reading echo back should give ~0x12345678 = 0xedcba987
```

Measured:

```
MAGIC=0x0000c0de HEART=97178 CMD=0x00000000 ECHO=0xffffffff STAT=0x1
MAGIC=0x0000c0de HEART=124690 CMD=0x00000000 ECHO=0xffffffff STAT=0x1   <- counting up
wrote CMD=0x12345678  ->  ECHO=0xedcba987  (expect 0xedcba987)  MATCH
wrote CMD=0xdeadbeef  ->  ECHO=0x21524110  (expect 0x21524110)  MATCH
heartbeat: 408290 -> 423585 in 1.000s = 15289 iters/s
```

15,289 iterations/s × a 7-instruction delay loop ≈ 65 µs per iteration, about
26k cycles at 400 MHz — consistent with the R5F's rated clock. (The MCU domain
clock tree belongs to the DM firmware and never appears in Linux
`clk_summary`, so there is no harder number to be had.)

### 14.6 ⚠️ The big trap: your own firmware cannot be stopped

```sh
echo stop > /sys/class/remoteproc/remoteproc2/state
# hangs 5.1 s, then:
# platform 79000000.r5f: k3_r5_rproc_stop: timeout waiting for rproc completion event
# remoteproc remoteproc2: can't stop rproc: -16
# state is still "running"
```

TI's K3 remoteproc does not stop a core by asserting reset — it **pings the
firmware over the mailbox and waits for an acknowledgement**. A bare-metal
firmware implements no such handshake, so it waits out the 5-second timeout and
returns `-EBUSY`. The `remoteproc4` row in §9 has exactly the same root cause.

Consequence: **the only way to reset that core or load new firmware is a
reboot.** Repeating `stop` does not help, and having the refcount at zero makes
no difference.

### 14.7 If you need stop/restart, use TI's IPC stack

The supported path is MCU+ SDK's `ipc_rpmsg_echo_linux`, which brings the
mailbox handshake, virtio channels and a real resource table:

1. Download `mcu_plus_sdk_am67a` (TI website, account required, 1.5–2 GB)
2. `examples/drivers/ipc/ipc_rpmsg_echo_linux/am67a-evm/r5fss0-0_freertos/`
   (pick `mcu-r5fss0-0` for the MCU domain)
3. Cross-compile → `ipc_rpmsg_echo_linux_r5fss0-0_freertos_ti-arm-clang.out`
4. Rename to `j722s-mcu-r5f0_0-fw` and install it
5. On Linux use `ti-rpmsg-char` (`/dev/rpmsg_ctrlN` → `/dev/rpmsgN`)

`rpmsg_ctrl0..3` and `rpmsg0..6` already exist on the board — they are the
virtio endpoints reserved for C7x/R5F. Only that path gives you graceful stop,
firmware-side `printf` forwarding and `/dev/rpmsgN` character devices.

### 14.8 Back to stock

```sh
rm -f /lib/firmware/j722s-mcu-r5f0_0-fw
reboot
# remoteproc2 returns to offline, factory state
```

---

## 16. One-line summary

Almost every problem on this board is of the form **"it installs cleanly, then
silently does nothing"**: wrong DTB, missing DKMS rebuild, IRQ conflict, missing
OPP table, AE driving the frame black, a detector that only keeps dogs.

So the debugging order is always the same: **read `dmesg` and `GST_DEBUG=3` for
the real error — never trust the top-level "Unable to init TIOVX module".**

---

## License

MIT. Corrections and additions via issue/PR are welcome.
