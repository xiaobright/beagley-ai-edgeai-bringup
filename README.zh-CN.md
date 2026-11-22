# BeagleY-AI (TI AM67A / J722S) EdgeAI 从零到完整可用

**English: [README.md](README.md)**

> 适用：Armbian 26.08 vendor 镜像 + TI EdgeAI PSDK 11.02（deb 包方式）
> 内核：`6.12.49-vendor-k3-beagle`
> 实测日期：2026-11-22
> 本文所有命令和数字都在一块 4GB BeagleY-AI 上跑通过

---

## 0. 先说怎么用这份文档

这份文档是**按"症状"组织的**，不是按流程组织的。原因：现在多半是 AI 帮你查，而 AI 的入口是报错信息。
所以第 9 节的「错误签名 → 根因 → 修法」对照表是最有价值的部分，其他节是配套的完整流程和验证命令。

如果你只想让它能用，按 1→8 顺序做；如果中间炸了，直接跳到第 9 节搜报错原文。

**最终能得到什么**（全部实测）：

| 能力 | 状态 | 实测数字 |
|---|---|---|
| CPU 变频 | 200M / 400M / 600M / 800M / 1G / 1.25G / 1.4G | 1.4G 四核满载 60s 无异常 |
| GPU（PowerVR BXS-4-64） | OpenGL ES 3.2 | `/dev/dri/card1` + `renderD128` |
| JPEG 硬编（e5010） | 1080p | 39.7 fps |
| H.264 / HEVC 硬编（wave5） | 1080p / 720p | 38.6 / 79.3 fps（1080p 各 ~31% CPU） |
| C7x + TIDL 推理 | 检测 + 分类双核并行 | 检测 12.3ms / 分类 7.5ms，cpu_fallback=0 |
| IMX219 + VPAC ISP | 1080p30 | ISP 本身 30.09 fps |
| 摄像头→ISP→H.264 | 1080p | 29.7 fps（录制回读 27.8 fps 有效） |
| 摄像头→ISP→检测→HTTP 出流 | 1080p | 6.4–7.8 fps（瓶颈是软件色彩转换，见 8.3） |
| 功耗 | — | 空载 5.4W，四核满载 1.4GHz 6.1W |

---

## 1. 选哪套系统（结论先行）

| 路线 | 内核 | C7x/TIDL | GPU | 结论 |
|---|---|---|---|---|
| BeagleBoard 官方 Debian | mainline `v7.3.x-k3` | ❌ | ✅ | 只有 Debian 生态，没有 AI |
| BeagleBoard 的 TI EdgeAI 镜像 | vendor | ✅ | 看运气 | 冻结在 2025-09（PSDK 11.00），太旧 |
| **Armbian vendor + EdgeAI deb** | vendor 6.12 | ✅ | ✅（需自己修，见 5） | **本文路线**，最新且可维护 |
| 自建 Yocto | vendor | ✅ | ✅ | 唯一官方完整路径，但构建成本高 |

关键点：**EdgeAI 必须 vendor 内核**（需要 `vision-apps` 内存 carveout），mainline 内核给不了。

---

## 2. 刷写 & 首次启动

镜像：`armbian-beagley-ai-noble-vendor-6.12.49-*-mid-v11.2.1-beagley.1.img.xz`

> ⚠️ **GNOME 变体（`-gnome-wayland-mid-`）在 4GB 板子上不启动**：上电只有红灯、功耗 2.1W、无 HDMI、无网络、按按钮无反应。
> 同一张卡、同一个电源换 `minimal` 立刻正常。所以**直接用 minimal**，桌面自己装。

刷写用 balenaEtcher 即可。写完第一次上电，用网线接路由器，在路由器后台找 IP。

默认账号：`root` / `1234`（首次登录会强制改密码）。

---

## 3. 装 EdgeAI（最大的坑在这）

拿到 EdgeAI 的 deb 包集合后 `dpkg -i` 安装。装完**不要急着重启**，先处理 DTB，否则 C7x 起不来。

### 3.1 为什么 `armbianEnv.txt` 改 `fdtfile` 没用

Armbian 习惯是改 `armbianEnv.txt` 里的 `fdtfile=`。但这块板子的启动链是
`uEnv.txt` → `bootcmd_ti_mmc`，它自己 `setenv fdtfile`，**根本不读 `armbianEnv.txt`**，而且没有任何警告。

结果：EdgeAI 装好了，但跑的是不含 `vision-apps` carveout 的原版 DTB，C7x 加载固件时炸：

```
remoteproc: bad phdr da 0xa3ffec00
remoteproc: Failed to load program segments: -22
```

### 3.2 正确做法：直接替换 DTB 文件名

```sh
cp -f /boot/dtb/ti/k3-am67a-beagley-ai-edgeai.dtb      /boot/dtb/ti/k3-am67a-beagley-ai.dtb
# 要摄像头的话（推荐）用 CSI0+IMX219 那版，后面第 7 节还要给它打补丁
cp -f /boot/dtb/ti/k3-am67a-beagley-ai-edgeai-csi0-imx219.dtb /boot/dtb/ti/k3-am67a-beagley-ai.dtb
```

> 注意：bootcmd 只认 `k3-am67a-beagley-ai.dtb` 这一个文件名，所以只能"覆盖"。

### 3.3 装完先跑一遍官方自检

```sh
validate-j722s-edgeai
```

期望结果：`TI EDGEAI RUNTIME VALIDATION: PASS`。

如果卡住不动，先关掉 gatekeeper 服务再试：

```sh
systemctl disable --now ti-edgeai-dachshund-gatekeeper
```

（gatekeeper 和自检会抢 TIDL/TIOVX 的锁，两个同时跑必卡。）

---

## 4. 确认 C7x 真的起来了

```sh
for i in 0 1 2 3 4; do echo -n "remoteproc$i: "; cat /sys/class/remoteproc/remoteproc$i/state; done
```

正常应该是：

```
remoteproc0: running      # C7x-0
remoteproc1: running      # C7x-1
remoteproc2: offline      # MCU R5F（空闲）
remoteproc3: attached     # WKUP R5F = Device Manager 固件
remoteproc4: running      # MAIN R5F = vision_apps
```

> `ti-sci 44043000.system-controller: ABI: 4.0 (firmware rev 0x000b '11.2.13')` 是 DM 固件版本，装完可以在 dmesg 里对一下。

---

## 5. 恢复 GPU（EdgeAI 装完 GPU 会"消失"）

### 5.1 症状

`/dev/dri` 只剩 `card0`，`eglinfo` 没有 PowerVR。**没有任何报错**，很容易以为这板子本来就没 GPU。

### 5.2 根因

Armbian 的 GPU 驱动是 **DKMS 模块** `pvrsrvkm.ko`。EdgeAI 的 deb 换了内核，但没触发 DKMS 重建，模块只对旧内核编译过。

```sh
dkms status
# ti-img-rogue-driver/25.3.xxx, <旧内核>, aarch64: installed   ← 只有旧内核
```

### 5.3 修法

```sh
export PVR_BUILD_DIR=am62p_linux        # AM67A 走 am62p 的构建目录
export WINDOW_SYSTEM=wayland
dkms install ti-img-rogue-driver/$(dkms status | grep ti-img-rogue | head -1 | sed 's/.*ti-img-rogue-driver\/\([^,]*\),.*/\1/') \
    -k $(uname -r) --force
```

实测可用的完整写法：

```sh
dkms install ti-img-rogue-driver/25.3.6908880+git20260225+d241b0d5df40 -k $(uname -r) --force
```

验证：

```sh
ls /dev/dri                      # 应有 card1 和 renderD128
eglinfo 2>/dev/null | head -20   # 应显示 PowerVR B-Series BXS-4-64 / OpenGL ES 3.2
```

> 另一条路是从官方 GNOME 镜像里把 `pvrsrvkm.ko` 抠出来（WSL loop 挂载镜像即可），但 DKMS 重建是正解。

---

## 6. 修 e5010 JPEG 编码器（中断冲突）

### 6.1 症状

```sh
dmesg | grep -i e5010
# genirq: Flags mismatch irq 14. 00000004 (e5010) vs. 00214084 (pinctrl)
# e5010 fd20000.e5010: probe failed: -EBUSY
```

JPEG 硬编完全不可用。

### 6.2 根因

DTB 里 `pinctrl@f4000` 和 `e5010@fd20000` **都声明了 GIC SPI 98（0x62）**。
上游 `k3-am62a-main.dtsi` 的 `main_pmx0: pinctrl@f4000` 只有四行（compatible/reg/pinctrl-cells/function-mask），
**没有** `interrupts` / `interrupt-controller` / `#interrupt-cells` —— 这三行是多出来的。

### 6.3 修法：删掉 pinctrl@f4000 里的三种属性

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
            removed.append(s); continue
    out.append(line)
open('/tmp/fixed.dts', 'w').write(''.join(out))
print("removed:", removed)
PY

dtc -I dts -O dtb -o /boot/dtb/ti/k3-am67a-beagley-ai.dtb /tmp/fixed.dts
```

期望 `removed` 里正好三项。重启后：

```sh
dmesg | grep e5010
# e5010 fd20000.e5010: Device registered as /dev/video2   ← 编号可能不同
```

验证性能（1080p）：

```sh
v4l2-ctl --list-devices          # 先确认 e5010 是哪个节点，编号会随 probe 顺序变
# e5010 (platform:fd20000.e5010):
#         /dev/video8              ← 以下用 video8

gst-launch-1.0 -q v4l2src device=/dev/video8 io-mode=dmabuf num-buffers=100 ! \
  video/x-raw,width=1920,height=1080,format=NV12 ! v4l2jpegenc ! fakesink
# 期望 ≈ 39.7 fps
```

> 注意：`linux-dtb` 包升级会把 DTB 覆盖回去，这个补丁会丢。见第 10 节冻结。

---

## 7. 摄像头 IMX219 + VPAC ISP

### 7.1 接哪个口

CSI0（标 `CSI0`）走 `cdns_csi2rx.30101000`。CSI1 和 DSI0 是复用同一个 PHY，插了屏就不能插相机。

### 7.2 配置媒体管线

先确认节点编号（**每次开机 probe 顺序可能不同**）：

```sh
v4l2-ctl --list-devices
# j721e-csi2rx (platform:30102000.ticsi2rx):  /dev/video2 … /dev/video7   ← 采集用 video2
# wave5-dec:  /dev/video0, /dev/video1
# wave5-enc:  /dev/video0 或 /dev/video1
# e5010:      /dev/video8
```

以下按 `video2` 为 CSI 采集节点、`/dev/v4l-subdev2` 为 sensor 子设备：

```sh
M=/dev/media0
media-ctl -d $M -r
media-ctl -d $M --set-v4l2 '"imx219 4-0010":0[fmt:SRGGB8_1X8/1920x1080]'
media-ctl -d $M --set-v4l2 '"cdns_csi2rx.30101000.csi-bridge":0[fmt:SRGGB8_1X8/1920x1080]'
media-ctl -d $M --set-v4l2 '"cdns_csi2rx.30101000.csi-bridge":1[fmt:SRGGB8_1X8/1920x1080]'
media-ctl -d $M --set-v4l2 '"30102000.ticsi2rx":0[fmt:SRGGB8_1X8/1920x1080]'
media-ctl -d $M --set-v4l2 '"30102000.ticsi2rx":1[fmt:SRGGB8_1X8/1920x1080]'
```

**`media-ctl -r` 会清掉格式，之后必须重新配**，否则管线能 PLAYING 但一帧不出（见图 9 第 6 条）。

### 7.3 跑 ISP

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

三个必须注意的点（踩过才知道）：

1. **`dcc-2a-file` 是 pad 属性**，必须写 `sink_0::dcc-2a-file=`；写成 `dcc-2a-file=` 会报
   `no property "dcc-2a-file" in element "tiovxisp"`。而 `dcc-isp-file` 是 element 属性。两者不一致。
2. **`format-msb=7`**：8-bit Bayer 送进 10-bit ISP，不写会偏色偏暗。
3. **`ae-mode=1`（手动曝光）+ 手动设 exposure/gain**：默认自动 AE 在暗场景会把 exposure 压到 91、gain 归零，出来全黑。

### 7.4 性能基线（1080p，各跑 18s，`fpsdisplaysink` 计数）

| 段 | 管线 | fps |
|---|---|---|
| A | sensor → ISP → NV12 | **30.09** |
| B | A + `videoconvert` NV12→BGR | **9.75** ← 瓶颈 |
| C | A + `v4l2h264enc` → 文件 | **29.70** |
| D | tee → {BGR} + {H.264} | 12.26 |

**结论：ISP 和硬编都不慢，慢的是 CPU 上的 NV12→BGR。** 1080p 一帧要 ~70ms（预算 33ms）。

---

## 8. TIDL 端到端（官方 gatekeeper demo）

### 8.1 启动

```sh
# /etc/default/ti-edgeai-dachshund-gatekeeper
GATEKEEPER_SOURCE=camera        # 或 video（内置狗视频）
GATEKEEPER_VIDEO=/usr/share/ti-edgeai-dachshund-gatekeeper/dachshund-demo.mp4
GATEKEEPER_PORT=8088

systemctl start ti-edgeai-dachshund-gatekeeper
curl -s http://127.0.0.1:8088/api/status | python3 -m json.tool
```

浏览器打开 `http://<板子IP>:8088` 能看到画面和检测框。

### 8.2 ⚠️ 检测器只认狗

```python
COCO_DOG_LABEL = 16  # COCO 类别 ID 是 18，但模型输出是连续索引 16
if int(label) != COCO_DOG_LABEL or score < self.threshold:
    continue
```

**对着人、手、任何非犬类物体，永远是 `present=false`**，而且 UI 上没有任何提示。
不要拿人手去试，会以为管线坏了——我在这上面浪费了一轮。

### 8.3 实测

| 指标 | 摄像头源 | 内置狗视频 |
|---|---|---|
| 帧率 | 6.4–7.8 fps | **13.4 fps** |
| 检测 | 283 节点全在 C7x-0，10.5–12.3 ms | present=true, score 0.75 |
| 分类 | 未触发 | Dachshund 0.987，C7x-1，71 op，7.5 ms |
| 决策状态机 | WATCHING | **AUTHORIZED** |
| `acceleration.active` | false | **true** |
| `cpu_fallback` | 0 | 0 |

摄像头源只有 7.8 fps、视频源 13.4 fps，**差距全在 8.3 那个软件 BGR 转换**上，不是硬件能力问题。

### 8.4 想提高摄像头帧率

`tiovxmultiscaler`（VPAC 硬件缩放）目前**协商成功但零帧输出**（见第 9 节第 5 条），所以只能：
- 把 `appsink` 改成直接收 NV12，Python 侧用 `cv2.cvtColor(nv12, COLOR_YUV2BGR_NV12)`（OpenCV 有 NEON 优化，比 ORC 的 `videoconvert` 快得多）
- 或者先 `videoscale` 到 640x480 再转换

---

## 9. 错误签名速查表（**最有用的一节**）

| 报错 / 症状 | 根因 | 修法 |
|---|---|---|
| `remoteproc: bad phdr da 0xa3ffec00` / `Failed to load program segments: -22` | 跑的是原版 DTB，没有 `vision-apps` carveout（`fdtfile` 被 boot 脚本忽略） | 3.2：直接 `cp` 覆盖 `k3-am67a-beagley-ai.dtb` |
| `Booting fw image ...` 紧接 `Boot failed: -22`，**没有任何其它日志** | ELF 缺 `.resource_table` 段，`rproc_elf_load_rsc_table()` 静默返回 `-EINVAL` | 15.4②：补 16 字节空资源表；定位靠 `set_graph_function=rproc_boot` |
| `remoteproc2` 永远 `offline`，`Direct firmware load ... failed with error -2` | 镜像里没有 `j722s-mcu-r5f0_0-fw` | 15.2：自己编一个放进去，或干脆不管 |
| `/dev/dri` 只有 `card0`，`eglinfo` 没 PowerVR，**无报错** | EdgeAI 换内核后 DKMS 没重建 | 5.3：`dkms install ti-img-rogue-driver/<ver> -k $(uname -r) --force` |
| `genirq: Flags mismatch irq N. (e5010) vs. (pinctrl)` → `-EBUSY` | DTB 里 `pinctrl@f4000` 抢了 GIC SPI 98 | 6.3：删三行中断属性 |
| `Unable to init TIOVX module` | **三种完全不同的原因共用这一句**：2A 配置文件为 null / VPAC VISS 节点创建失败 / DMA 分配失败 | 开 `GST_DEBUG=3` 才看得到真相，见下 |
| `Unable to open 2A config file: (null)` | 没给 `dcc-2a-file`，或写成了 element 属性 | 用 `sink_0::dcc-2a-file=...` |
| `TIVX_CMD_NODE_CREATE failed for node ... com.ti.hwa.vpac_viss` | VISS 硬件实例创建失败：可能是上次管线被 kill 没释放，或 CMA 分配失败 | 先 `reboot`；仍失败看 CMA（见下） |
| `no property "dcc-2a-file" in element "tiovxisp"` | `dcc-2a-file` 是 pad 属性 | 写 `sink_0::dcc-2a-file=` |
| 管线 PLAYING、caps 协商成功，但**一帧不出**，文件 0 字节 | ① `media-ctl -r` 后没重配格式 ② VISS 卡死 ③ tiovxmultiscaler 本身有问题 | 先重配格式；再 reboot |
| `cma: __cma_alloc ... alloc failed` / `dma alloc of size 33554432 failed` | CMA 碎片化，896MB 总量但拿不到连续 32MB | 重启；或错开 wave5 编码与 ISP 并发 |
| `e5010` probe 失败但 DTB 看着对 | `linux-dtb` 升级把补丁覆盖了 | 10.2 的恢复脚本 |
| 摄像头出图全黑（Y max ≈ 8） | 自动 AE 把 exposure 压到 91、gain 归零 | `sink_0::ae-mode=1` + 手动 `exposure`/`analogue_gain` |
| 摄像头出图偏绿/偏暗 | 8-bit Bayer 没告诉 ISP 对齐方式 | 加 `format-msb=7` |
| ISP NV12 直接进 `v4l2jpegenc` 出条纹 | stride 不匹配 | 中间插 `videoconvert` |
| gatekeeper `present` 永远 false | 检测器只保留 COCO 第 16 类（狗） | 换真狗，或用 `--source video` 的内置视频验证链路 |
| `onnxruntime ... GPU device discovery failed: /sys/class/drm/card1/device/vendor` | PowerVR 没有 `vendor` sysfs 节点 | 无害，忽略 |
| `pkill -f 'while :'` 杀不掉满载进程 | `sh` 紧循环对 SIGTERM 不响应 | `pkill -9 -f`，或用带 `timeout` 的脚本 |
| `validate-j722s-edgeai` 卡死 | gatekeeper 和自检抢 TIDL/TIOVX 锁 | `systemctl disable --now ti-edgeai-dachshund-gatekeeper` 后重启 |
| `echo stop > .../remoteprocN/state` 卡 5 秒报 `timeout waiting for rproc completion event` / `can't stop rproc: -16` | 停核要靠 mailbox 握手，固件不支持优雅停止（`vision_apps` 固件、裸机固件都这样） | 只有 `reboot`。见 15.6 |

---

## 10. 补 cpufreq（解锁 1.4GHz）

### 10.1 症状与根因

`/sys/devices/system/cpu/cpufreq/` 不存在，四核钉死在 **1.2GHz**（不是标称的 1.4GHz）。

不是驱动没编——`CONFIG_CPUFREQ_DT=y`、`dt_cpufreq_probe` 都在内核里。是 `cpufreq-dt-platdev` 的判定没过：

```c
match = of_match_node(allowlist, np);   // 只有 ti,am625 / am62a7 / am62p5
if (match) goto create_pdev;
if (cpu0_node_has_opp_v2_prop() && !of_match_node(blocklist, np)) goto create_pdev;
```

BeagleY 的 compatible 是 `beagle,am67a-beagley-ai` / `ti,j722s`，不在 allowlist，DT 又没给 cpu0 挂 OPP 表。

### 10.2 先安全验证 1.4GHz 能不能跑

不要直接写进 DT 赌启动。用一个一次性模块在运行时试：

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
    if (IS_ERR(c)) return PTR_ERR(c);
    pr_info("a53test: %ld -> set=%d -> %ld\n",
            clk_get_rate(c), clk_set_rate(c, rate), clk_get_rate(c));
    clk_put(c);
    return -EINVAL;   /* 强制卸载 */
}
module_init(t);
MODULE_LICENSE("GPL");
```

```sh
insmod a53test.ko rate=1400000000; dmesg | grep a53test
# a53test: 1000000000 -> set=0 -> 1400000000     ← set=0 说明 DM 固件接受
```

### 10.3 打 OPP 表补丁

在 `/cpus` 下加一个 `cpu_opp_table`，每个 `cpu@N` 加两行：

```dts
	cpus {
		cpu_opp_table: opp-table {
			compatible = "operating-points-v2";
			opp-shared;
			phandle = <0x1f0>;

			opp-200000000 { opp-hz = /bits/ 64 <200000000>;  opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
			opp-400000000 { opp-hz = /bits/ 64 <400000000>;  opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
			opp-600000000 { opp-hz = /bits/ 64 <600000000>;  opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
			opp-800000000 { opp-hz = /bits/ 64 <800000000>;  opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
			opp-1000000000 { opp-hz = /bits/ 64 <1000000000>; opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
			opp-1250000000 { opp-hz = /bits/ 64 <1250000000>; opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
			opp-1400000000 { opp-hz = /bits/ 64 <1400000000>; opp-microvolt = <850000>; clock-latency-ns = <2000000>; };
		};

		cpu@0 {
			...
			operating-points-v2 = <0x1f0>;
			#cooling-cells = <0x02>;
			clocks = <0x07 0x87 0x00>;
		};
	};
```

> 在反编译出来的 dts 里 phandle 是数字。手写一个没被占用的（比如 `0x1f0`），四个 cpu 节点都引用它。

验证：

```sh
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
# 200000 400000 600000 800000 1000000 1250000 1400000
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_driver    # cpufreq-dt
```

### 10.4 变频是否真的生效

固定工作量测三次不同频率，耗时应该和频率成反比：

| 频率 | 耗时 |
|---|---|
| 200 MHz | 17.5 s |
| 600 MHz | 5.5 s |
| 1200 MHz | 2.75 s |

顺便：加了 `#cooling-cells` 之后会多一个 `cpufreq-cpu0` 冷却设备，热管理可以靠降频而不只是风扇。

### 10.5 cpuidle 没有，别指望

上游 `k3-am62.dtsi` / `k3-j722s.dtsi` / `k3-am67a-beagley-ai.dts` **全都没有** `cpu-idle-states` 和 `psci-suspend-param`。不是漏了属性，是 TI 没在 mainline 描述 J722S 的低功耗状态。自己编 idle state 风险极高（idle 是每秒几百次的高频路径），不建议。

---

## 11. 功耗实测（USB 功率计，5V）

| 场景 | 功耗 |
|---|---|
| 空载，频率未解锁（1.2GHz 钉死） | 5.4 W |
| 空载，上限 600MHz | **5.4 W（无变化）** |
| 空载，停 C7x 固件 | 5.2 W |
| 四核满载 @1.2GHz | 6.0 W |
| 四核满载 @1.4GHz | **6.1 W** |

三点：

1. **降频对空载零帮助**——没有 cpuidle，空闲只降频不进低功耗态。
2. **1.2→1.4GHz 满载只多 0.1W（+1.7%），性能 +17%**，所以 1.4G 该开着。
3. **5.4W 是板级地板**：四核 A53 满载总共只贡献 0.7W，剩下 5W 是 LPDDR4、各种 PHY/SerDes、PMIC 损耗和常驻在 C7x+R5F 上的固件。

> **关于"刚装好时是 5V 0.8A(≈4W)"**：那是最小镜像刚起来、EdgeAI 固件还没跑、GPU 驱动没装、相机没插的状态，
> 而且 0.8A 只有一位小数。配好之后额外上电的东西包括：
> 2×C7x + MAIN R5F 上的 vision_apps 固件、GPU 的 `pvrsrvkm` 与 `card1`、
> wave5 / e5010 / csi2rx / imx219 / cdns3 全套驱动、207 个已使能时钟门控、1Gbps 以太网 PHY。
> 所以 5.4W 才是"全开"的真实地板。

---

## 12. 维护：把版本钉死

这套东西的依赖很脆（内核 ↔ DTB ↔ DKMS 模块 ↔ EdgeAI 固件 ABI 必须版本锁步），一次 `apt upgrade` 能同时弄坏三处：

```sh
apt-mark hold \
  linux-image-vendor-k3-beagle linux-dtb-vendor-k3-beagle \
  linux-headers-vendor-k3-beagle linux-u-boot-beagley-ai-vendor \
  armbian-bsp-cli-beagley-ai-vendor armbian-firmware \
  ti-img-rogue-driver-am62p-dkms ti-img-rogue-firmware-am62p \
  ti-img-rogue-tools-am62p ti-img-rogue-umlibs-am62p \
  ti-edgeai ti-edgeai-firmware-j722s
```

验证（`apt list --upgradable` **会照样列出来，它不看 hold**，要看模拟结果）：

```sh
apt-get -s upgrade | grep -E '^(Inst|Remv) (linux|ti-img|ti-edgeai|armbian)'
# 应该没有输出
```

### 12.1 存一份黄金 DTB

```sh
mkdir -p /root/dtb-good
cp /boot/dtb/ti/k3-am67a-beagley-ai.dtb /root/dtb-good/k3-am67a-beagley-ai.dtb.golden
```

### 12.2 恢复脚本

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

如果需要升级内核，正确顺序是：

```sh
apt-mark unhold linux-image-vendor-k3-beagle linux-dtb-vendor-k3-beagle \
                linux-headers-vendor-k3-beagle linux-u-boot-beagley-ai-vendor
apt upgrade
sh /root/reapply-edgeai-dtb.sh                       # 找回 carveout + e5010 修复 + OPP
PVR_BUILD_DIR=am62p_linux WINDOW_SYSTEM=wayland \
  dkms install ti-img-rogue-driver/<新版本> -k $(uname -r) --force
reboot
```

---

## 13. 开机自检（改完任何东西都跑一遍）

```sh
# 1. C7x / R5F 固件
for i in 0 1 2 3 4; do echo -n "remoteproc$i: "; cat /sys/class/remoteproc/remoteproc$i/state; done
#    期望：running / running / offline / attached / running

# 2. GPU
ls /dev/dri/                       # 期望：card0 card1 renderD128

# 3. JPEG 硬编
dmesg | grep e5010                 # 期望："registered as /dev/videoN"

# 4. 变频
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies

# 5. C7x 推理链路
systemctl stop ti-edgeai-dachshund-gatekeeper
validate-j722s-edgeai              # 期望：PASS
```

---

## 14. 已知无法解决 / 上游未修的

这些不是配置问题，是上游状态，看到不用再折腾：

| 问题 | 状态 |
|---|---|
| cpuidle / 深度休眠 | 上游从未描述 J722S 的 idle states，做不了 |
| `tiovxmultiscaler` 零帧输出 | caps 协商成功但无数据，无报错（疑似插件 bug） |
| 连续多次 `tiovxisp` 会话后 VISS 卡死 | 只能 reboot 恢复 |
| `tiovxisp` 报错笼统（三种原因一句话） | 只能靠 `GST_DEBUG=3` 自己辨别 |
| gatekeeper 用 CPU 转 1080p NV12→BGR | demo 设计问题，帧率从 30 掉到 9.75 |
| GNOME 镜像在 4GB 板上不启动 | 用 minimal |
| mainline `powervr` 驱动 probe 崩溃 | 用 DKMS 的 `pvrsrvkm` |

---

## 15. 片内 MCU（R5F）

### 15.1 三个 R5F，能碰哪个

| sysfs | 总线地址 | 核 | 用途 | 能碰吗 |
|---|---|---|---|---|
| `remoteproc2` | `79000000.r5f` | **MCU R5F0_0** | 空着，镜像里没给固件 | ✅ |
| `remoteproc3` | `78000000.r5f` | WKUP R5F0_0 | Device Manager（TISCI） | ❌ `attached` |
| `remoteproc4` | `78400000.r5f` | MAIN R5F0_0 | `vision_apps` 的 `mcu2_0` | ⚠️ TIDL 要用 |

```sh
for i in 0 1 2 3 4; do echo -n "remoteproc$i $(cat /sys/class/remoteproc/remoteproc$i/name): "; cat /sys/class/remoteproc/remoteproc$i/state; done
# remoteproc0 7e000000.dsp: running      <- C7x-0（TIDL 检测）
# remoteproc1 7e200000.dsp: running      <- C7x-1（TIDL 分类）
# remoteproc2 79000000.r5f: offline      <- MCU R5F，没固件
# remoteproc3 78000000.r5f: attached     <- DM 固件，别动
# remoteproc4 78400000.r5f: running      <- vision_apps
```

### 15.2 为什么它一直 offline

```sh
cat /sys/class/remoteproc/remoteproc2/firmware    # j722s-mcu-r5f0_0-fw
ls /lib/firmware/j722s-mcu-r5f0_0-fw               # No such file
```

```
[ 6.167951] remoteproc remoteproc2: 79000000.r5f is available
[ 6.168207] remoteproc remoteproc2: Direct firmware load for j722s-mcu-r5f0_0-fw failed with error -2
```

不是配置错。TI 的 PSDK 镜像只给了两个 C7x 和 MAIN R5F 的固件，MCU R5F 的留给你自己编。
**只要 `/lib/firmware/j722s-mcu-r5f0_0-fw` 存在，开机就会 autoboot**，不用改 DT、不用加 service。

### 15.3 它能干什么 —— 以及这块板上的硬限制

Cortex-R5F @ 400MHz，32 KiB ATCM + 32 KiB BTCM，有 MPU 无 MMU，TCM 带 ECC，DDR 侧分到
1 MiB（`@a1000000`）+ 15 MiB（`@a1100000`）。卖点是**确定性**：不受 Linux 调度和缺页影响，
Linux 崩了它照跑。

但 BeagleY-AI 上 MCU 域的外设**没引出来**：

| 外设 | 地址 | DT 状态 | 40pin 排针 |
|---|---|---|---|
| MCU_I2C0 | `0x04900000` | **okay**，Linux 已占（100kHz） | 有（`hat/mcu_i2c0`） |
| MCU_GPIO0 | `0x04201000` | **okay**，Linux `gpiochip515`，24 线 | — |
| MCU_UART0 | `0x04a00000` | disabled | ❌ 无 pinmux |
| MCU_SPI0 / SPI1 | `0x04b00000` / `0x04b10000` | disabled | ❌ 无 pinmux |
| MCU_MCAN0 / MCAN1 | `0x04e08000` / `0x04e18000` | disabled | ❌ 无 pinmux |

它们在 Linux 里是 `disabled`（名义上归 R5F 用），但板级 DTS 里**完全没有**给 MCU
UART/SPI/MCAN 定义 pinctrl 组，引脚也没走到排针。全板 MCU 域引到 40pin 的只有 MCU_I2C0，
而它归 Linux。

所以：**想让 R5F 驱动物理 I/O 得飞线到测试点**。不飞线的话它就只是"一个能读写 DDR 的
400MHz 附加核"，动手前先想清楚值不值。

**实测结论（本项目最终选择关掉）**：跑起来多耗约 **0.05 W**（USB 功率计实测），
而这块板上它没有任何可驱动的外设，也没有非它不可的活，所以验证完就回退了。
下面保留全过程，是因为三个启动约定和 `stop` 掉不掉的坑对别的板子同样成立。

### 15.4 自己写裸机固件（不装 TI SDK）

难点全在三个约定上。

**① 代码放哪：BTCM 在 R5F 视角的 `0x0`**

DT 里是 `ti,atcm-enable = 0` / `ti,btcm-enable = 1` / `ti,loczrama = 0`，驱动
（`ti_k3_r5_remoteproc.c`）这样映射：

```c
if (!strcmp(data->mems[i].name, "atcm"))
        kproc->mem[i].dev_addr = core->loczrama ? 0 : K3_R5_TCM_DEV_ADDR;   /* 0x41010000 */
else
        kproc->mem[i].dev_addr = core->loczrama ? K3_R5_TCM_DEV_ADDR : 0;
```

`loczrama = 0` → **BTCM 在地址 `0x0`**（总线地址 `0x79020000`）。启动向量取自 ELF 的
entry point，所以**向量表必须放 `0x0`、entry 也必须是 `0x0`**。

注意别被带偏：MAIN R5F（`78400000`）是 `loczrama = 1`，ATCM 在 `0x0`，TI 官方
`vx_app_rtos_linux_mcu2_0.out` 的 entry 也是 `0x0` —— 同一个数字，不同的存储器。

**② ELF 里必须有 `.resource_table` 段**

这条最坑：这个内核的 `rproc_elf_load_rsc_table()` 找不到该段就返回 `-EINVAL`，
而且**一行日志都不打**：

```
remoteproc remoteproc2: Booting fw image j722s-mcu-r5f0_0-fw, size 6952
remoteproc remoteproc2: Boot failed: -22
```

完全没有线索，只能上 ftrace：

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
rproc_elf_load_rsc_table()     |     3.315 us   <- 就是它返回 -22
k3_r5_rproc_unprepare()        |   948.800 us   <- 回滚
```

补个 16 字节空表就过：

```c
struct resource_table { uint32_t ver, num, reserved[2]; } __attribute__((packed));
__attribute__((section(".resource_table"), used))
static const struct resource_table rsc_tbl = { .ver = 1, .num = 0 };
```

`num = 0` 表示不注册任何 virtio/rpmsg 设备，正好适合独立固件。

**③ 状态：ARM 模式、cache 关**

`k3_r5_rproc_configure()` 会清掉 `PROC_BOOT_CFG_FLAG_R5_TEINIT`（"always enable ARM
mode"），核释放出来是 ARM 状态（不是 Thumb），cache 也没开。所以编译加 `-marm`，
入口用 `.arm` 汇编，直接按物理地址访问 DDR——cache 没开反而是好事，写出去就是总线上
真实的事务。

完整可编译版本在 [`mcu-r5f/`](mcu-r5f/)，184 字节，纯 `arm-none-eabi-gcc`，无 SDK 无 libc：

```sh
sudo apt install -y --no-install-recommends gcc-arm-none-eabi binutils-arm-none-eabi
cd mcu-r5f && make
sudo cp r5fw.elf /lib/firmware/j722s-mcu-r5f0_0-fw
sudo sh -c 'echo start > /sys/class/remoteproc/remoteproc2/state'
dmesg | tail -3        # remoteproc remoteproc2: remote processor 79000000.r5f is now up
```

> 在 PC 或 WSL 上编，别在板子上编。184 字节的东西 A53 也编得动，但一上 MCU+ SDK
> 就是几万个文件。
>
> 实测同一份固件 clean build：WSL（x86_64 32 核）**95 ms**，A53（4 核 1.2GHz）**229 ms**，
> 只差 2.4 倍，因为这点代码全是进程启动开销（`make`+`gcc`+`cc1`+`as`+`ld` 五次 fork）。
> 真正拉开差距要上量。
>
> 工具链占 **535 MB**（板上）或 ~900 MB（WSL 带 newlib），用完可以卸掉，不影响已编好的 ELF：
> `apt-get remove -y gcc-arm-none-eabi binutils-arm-none-eabi`。

固件做的事：往 DDR `0xa1100000`（DT 分给它的那个 carveout）写心跳和握手字。

### 15.5 验证 A53 ↔ R5F 双向通

`no-map` 的 carveout 不在内核线性映射里，`/dev/mem` 可以直接 mmap：

```python
import mmap, os, struct
f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(f, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xa1100000)
print(struct.unpack("<5I", m[:20]))          # (0xc0de, 心跳, cmd, echo, stat)
m[8:12] = struct.pack("<I", 0x12345678)      # 写 cmd
# 读回 echo 应为 ~0x12345678 = 0xedcba987
```

实测：

```
MAGIC=0x0000c0de HEART=97178 CMD=0x00000000 ECHO=0xffffffff STAT=0x1
MAGIC=0x0000c0de HEART=124690 CMD=0x00000000 ECHO=0xffffffff STAT=0x1   <- 心跳在涨
wrote CMD=0x12345678  ->  ECHO=0xedcba987  (expect 0xedcba987)  MATCH
wrote CMD=0xdeadbeef  ->  ECHO=0x21524110  (expect 0x21524110)  MATCH
heartbeat: 408290 -> 423585 in 1.000s = 15289 iters/s
```

15,289 次/秒 × 每轮 7 条指令的延时循环 ≈ 65µs 一轮，按 400MHz 算约 26k 周期/轮，
与 R5F 标称频率自洽。（MCU 域时钟树归 DM 固件管，Linux `clk_summary` 里看不到 R5F
的时钟，拿不到更硬的数。）

### 15.6 ⚠️ 最大的坑：自己写的固件 `stop` 不掉

```sh
echo stop > /sys/class/remoteproc/remoteproc2/state
# 卡 5.1 秒，然后：
# platform 79000000.r5f: k3_r5_rproc_stop: timeout waiting for rproc completion event
# remoteproc remoteproc2: can't stop rproc: -16
# state 仍然是 running
```

TI 的 K3 remoteproc 停核不是拉 reset，而是**通过 mailbox 通知固件"该退了"，再等固件
回应答**。裸机固件没这个握手，于是等满 5 秒超时、返回 `-EBUSY`。§9 里 `remoteproc4`
那条 `timedout waiting for rproc completion event` 是同一个根因。

后果：**只能重启板子才能复位这个核、换新固件**。反复 `stop` 没用，引用计数归零也没用。

### 15.7 想要能正常 stop/restart，就用 TI 的 IPC 栈

正规路线是 MCU+ SDK 的 `ipc_rpmsg_echo_linux`，自带 mailbox 握手、virtio 通道和真正的
资源表：

1. 下 `mcu_plus_sdk_am67a`（TI 官网，要账号，1.5–2GB）
2. `examples/drivers/ipc/ipc_rpmsg_echo_linux/am67a-evm/r5fss0-0_freertos/`
   （MCU 域选 `mcu-r5fss0-0`）
3. 交叉编译 → `ipc_rpmsg_echo_linux_r5fss0-0_freertos_ti-arm-clang.out`
4. 改名成 `j722s-mcu-r5f0_0-fw` 装进去
5. Linux 侧用 `ti-rpmsg-char`（`/dev/rpmsg_ctrlN` → `/dev/rpmsgN`）收发

板子上 `rpmsg_ctrl0..3`、`rpmsg0..6` 这些节点本来就有，是留给 C7x/R5F 的 virtio 端点。
走这条路才有：优雅停止、固件端 `printf` 回传、`/dev/rpmsgN` 字符设备。

### 15.8 想恢复干净

```sh
rm -f /lib/firmware/j722s-mcu-r5f0_0-fw
reboot
# remoteproc2 回到 offline，和出厂一致
```

---

## 16. 一句话总结

这块板子的问题几乎全在**"装完不报错但功能没有"**这一类：DTB 选错、DKMS 没重建、中断冲突、OPP 表缺失、AE 把画面压黑、检测器只认狗。
所以排查的顺序永远是：**先看 `dmesg` 和 `GST_DEBUG=3` 的真实错误，不要相信上层那句 "Unable to init TIOVX module"。**
