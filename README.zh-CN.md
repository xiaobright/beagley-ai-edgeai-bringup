# BeagleY-AI (TI AM67A / J722S) EdgeAI 完整折腾指南

**English: [README.md](README.md)**

这是一份给 **4GB 版 BeagleY-AI** 用的实战指南。目标很简单：**既保留像 Debian/Ubuntu 一样好用的 `apt` 软件生态，又把板子上的全套 TI 硬件加速和无线外设全部跑起来**（双核 C7x AI 推理、PowerVR GPU、VPAC ISP 图像处理、H.264/H.265/JPEG 硬编、CPU 1.4GHz 调频 + 80°C 温控降频、板载 Wi-Fi 6 + BLE 5.4 低功耗蓝牙、常见 USB/CAN/WireGuard/存储驱动）。

- **测试平台**：BeagleY-AI（TI AM67A / J722S，4 GB LPDDR4）+ IMX219（CSI0）
- **操作系统**：Armbian 26.08（Ubuntu 24.04 Noble minimal），自编增强版内核 `6.12.49-vendor-k3-beagle`
- **AI 软件栈**：TI EdgeAI PSDK 11.02.01.03（`ti-edgeai` `v11.2.1-beagley.1` deb 包）
- **实测日期**：2026-11-22（文内命令与实测数据均已在真实硬件上跑通）

> **不想自己编译？直接用现成二进制包：**
> 本仓库 [GitHub Release `v1.2.0`](https://github.com/xiaobright/beagley-ai-edgeai-bringup/releases/tag/v1.2.0) 已经打好了全部耗时产物：
> 1. `kernel-6.12.49-vendor-k3-beagle-full.tar.gz` —— 开启了板载 Wi-Fi 6 + BLE 5.4、常用 USB/CAN/WireGuard/exFAT/NTFS3 驱动的完整升级内核包（已自带重编好的 GPU `pvrsrvkm.ko` 与头文件同步文件，配合 [`scripts/install-kernel.sh`](scripts/install-kernel.sh) 一键安装并自动备份 `.orig`）
> 2. `k3-am67a-beagley-ai-edgeai-csi0-imx219-patched.dtb` —— 修好全部硬件补丁的设备树（含 4GB EdgeAI 内存预留、CSI0 IMX219、e5010 中断修复、1.4GHz 调频、80°C 温控降频）
> 3. `r5fw.elf` —— 附录用的片上 MCU 裸机测试固件
> 4. `SHA256SUMS` —— 以上产物校验清单（如只需单独 Wi-Fi `.ko` 不想换内核，旧包仍在 [`v1.1.0`](https://github.com/xiaobright/beagley-ai-edgeai-bringup/releases/tag/v1.1.0)）
>
> 按 **1 → 9** 节顺序做就能 10 分钟配齐；遇到报错直接跳到 **第 10 节「报错速查表」**。

---

## 1. 先看结果：这块板子到底能跑成什么样

| 硬件能力 | 当前状态 | 实测结果 |
|---|---|---|
| 板载 Wi-Fi 6（TI CC3300） | ✅ 已打通 | 2.4GHz Wi-Fi 6（`HE-MCS 7`），接收协商速率 86 Mbps，开机自动连网 |
| 板载蓝牙（CC3300 BLE 5.4） | ✅ 已打通 | TI BLE 5.4（`version 13` / `hci0`），开机通过 `cc33xx-ble-enable.service` 自动唤醒，`btmgmt find -l` 可扫描设备并与 Wi-Fi 6 共存 |
| 常用外设 / 工业 / 文件系统 | ✅ 已补齐 | 内核增开 UASP、CH341/PL2303 串口、USB 声卡、RNDIS、`uinput`、SocketCAN (`gs_usb`/`slcan`/`peak_usb`/`mcp251x`)、GPIO PPS、WireGuard、exFAT、NTFS3（KVM 保持关闭） |
| CPU 调频 + 温控保护 | ✅ 已补齐 | 7 档频率（200M ~ 1.4GHz），80°C 自动触发被动降频，60s 满载 54.8°C |
| GPU（PowerVR BXS-4-64） | ✅ 已打通 | OpenGL ES 3.2，`/dev/dri/card1` + `renderD128`（`v1.2.0` 内核包已内置；原核需见第 6 节重编 DKMS） |
| JPEG 硬编码（e5010） | ✅ 已打通 | 1080p 约 **39.7 fps**（已解决原厂 DTB 中断冲突） |
| H.264 / HEVC 硬编（wave5） | ✅ 已打通 | H.264 1080p **38.6 fps** / 720p **79.3 fps**，HEVC 1080p **39.6 fps** |
| C7x 双核 AI 推理（TIDL） | ✅ 已打通 | MobileNetV1 **4.67 ms**（34/34 算子）、RegNetX **8.36 ms**（103/103 节点），零 CPU 回落 |
| IMX219 摄像头 + ISP | ✅ 已打通 | 1080p 30.09 fps；接 H.264 录像 29.7 fps |
| 整机功耗（USB 功率计） | — | 空载 **5.4 W**，四核 1.4GHz 满载 **6.1 W** |

---

## 2. 为什么选这套系统（别踩选型坑）

| 方案 | 内核 | C7x AI 加速 | GPU | 软件生态 (`apt`) | 结论 |
|---|---|---|---|---|---|
| BeagleBoard 官方 Debian 13 | 主线 `v7.3.x-k3` | ❌ 不支持 | ✅ | ✅ 极好 | 官方维护者已明确不再跟进 TI EdgeAI 移植 |
| BeagleBoard TI EdgeAI 镜像 | vendor | ✅ | 不稳定 | ❌ 无 `apt`（Yocto） | 停留在 2025-09（PSDK 11.00），加装软件极痛苦 |
| **Armbian Noble + TI EdgeAI deb** | vendor `6.12.49` | ✅ | ✅（需手工重编 DKMS） | ✅ Ubuntu 24.04 `apt` | **本教程方案：兼顾硬件加速与现代软件包管理** |
| 从头自建 TI Yocto | vendor | ✅ | ✅ | ❌ 无 `apt` | 官方唯一完全支持路径，但构建、改包门槛极高 |

核心原因很简单：**TI 的 AI 协处理器（C7x + R5F）依赖大量专属内存预留（carveout）和私有 IPC 接口，主线内核根本带不起来。** 而 TI 工程师在 Sandbox 仓库（[`BeagleY-EdgeAI-Demos`](https://github.com/TexasInstruments-Sandbox/BeagleY-EdgeAI-Demos)）把 PSDK 11.02 打包成了 Ubuntu 24.04 的 `.deb` 包，正好解决了 "既要 `apt` 又要 AI 加速" 的矛盾。

---

## 3. 刷机与安装 EdgeAI 基础包

### 3.1 刷写镜像（一定要选 Minimal 版）

从 [`BeagleY-EdgeAI-Demos v11.2.1-beagley.1`](https://github.com/TexasInstruments-Sandbox/BeagleY-EdgeAI-Demos/releases/tag/v11.2.1-beagley.1) 下载 **Minimal** 镜像：

- 镜像名：`armbian-beagley-ai-noble-vendor-6.12.49-minimal-base-20260715.img.xz`

> **⚠️ 千万别刷同页面里的 GNOME 桌面版镜像（`-gnome-wayland-mid-`）**
> 实测在 4GB BeagleY-AI 上，GNOME 版刷进同一张卡、接同一个 5V/3A 电源，上电只有红灯、功耗卡在 2.1W、HDMI 无输出、网口不亮、电源键无反应；换 Minimal 版立刻正常启动。真要桌面，启动后再自己装轻量桌面即可。

用 balenaEtcher 或 `dd` 写入 TF 卡，插上网线通电，路由器后台找到 IP 后 SSH 登录（默认账号 `root` / `1234`，首次登录会要求改密码并创建新用户）。

### 3.2 安装 EdgeAI deb 包

按该仓库的 [`STOCK_ARMBIAN_INSTALL.md`](https://github.com/TexasInstruments-Sandbox/BeagleY-EdgeAI-Demos/blob/main/docs/STOCK_ARMBIAN_INSTALL.md) 下载并运行安装脚本：

```sh
TAG=v11.2.1-beagley.1
BASE="https://github.com/TexasInstruments-Sandbox/BeagleY-EdgeAI-Demos/releases/download/${TAG}"
ASSET="beagley-edgeai-all-debs-j722s-psdk-11.02.01.03.tar.xz"

curl -fLO "${BASE}/${ASSET}"
tar -xJf "${ASSET}"
cd beagley-edgeai-j722s-psdk-11.02.01.03

# 先 dry-run 预检，不改动系统
sudo ./install-j722s-release.sh --debs debs --kernel kernel --camera imx219 --dry-run

# 确认无误后正式安装（没有摄像头就把 imx219 改成 none）
sudo ./install-j722s-release.sh --debs debs --kernel kernel --camera imx219 --reboot
```

> 装完重启先别急着怀疑为什么 AI 没跑起来——下面第 4 步才是决定 C7x 能不能起得来的关键。

---

## 4. 换设备树（DTB）—— 最容易卡死的一步

### 4.1 为什么改 `armbianEnv.txt` 没用？

很多玩 Armbian 的人会去改 `/boot/armbianEnv.txt` 里的 `fdtfile=...`。但 BeagleY-AI 的实际启动流程是 `/boot/uEnv.txt` → `bootcmd_ti_mmc`，**U-Boot 硬编码了加载 `/boot/dtb/ti/k3-am67a-beagley-ai.dtb`，压根不看 `armbianEnv.txt` 里的 `fdtfile`**，也不会给你任何错误提示。

后果就是：系统悄悄用了原版没有预留 EdgeAI 内存的 DTB，开机后 C7x 加载固件直接失败（`dmesg` 会看到 `remoteproc: bad phdr da 0xa3ffec00`）。

### 4.2 一步到位的修法（包含 4 个重要硬件修复）

在启动使用的这个 DTB 里，我们需要同时解决 4 件事：
1. **启用 EdgeAI 内存预留 + CSI0 摄像头**（来自官方 `k3-am67a-beagley-ai-edgeai-csi0-imx219.dtb`）；
2. **修复 e5010 JPEG 硬编码器中断冲突**：TI 公共设备树 `k3-am62p-j722s-common-main.dtsi` 给 `pinctrl@f4000` 填了个给深度休眠占坑的假中断号 `GIC_SPI 98`，正好和 `e5010` 硬件冲突，导致 JPEG 硬编 probe 直接报 `-EBUSY`。删掉 `pinctrl@f4000` 里的 `interrupts` / `interrupt-controller` / `#interrupt-cells` 三行即可；
3. **解锁 CPU 变频与 1.4GHz 主频**：原厂 DTB 没写 `opp-table`，CPU 永远钉死在 1.2GHz。加上 200M ~ 1.4GHz 共 7 档 OPP 表即可；
4. **挂上 80°C 自动温控降频**：光有风扇还不够，在 `main0` / `main1` / `main2` 三个温区加上 80°C 被动降温节点（`trip-passive` + `cooling-maps` 绑定 `cpu@0`），温度真飙到 80°C 以上会自动限频保护芯片。

#### 方式 A（最省事）：直接下载 Release 里做好的完整 DTB

如果你插了 IMX219 摄像头在 CSI0 上（没插也不影响开机），直接下我们编好测通的成品文件：

```sh
mkdir -p /root/dtb-good
curl -fL "https://github.com/xiaobright/beagley-ai-edgeai-bringup/releases/download/v1.2.0/k3-am67a-beagley-ai-edgeai-csi0-imx219-patched.dtb" \
  -o /root/dtb-good/k3-am67a-beagley-ai.dtb.golden

# 校验 SHA256（必须是 10227dd8aa5bebafdd39d4f36a73e4ea3c49b0d6ec2208499300936e740fdc54）
sha256sum /root/dtb-good/k3-am67a-beagley-ai.dtb.golden

# 备份原版后覆盖并重启
cp -n /boot/dtb/ti/k3-am67a-beagley-ai.dtb /boot/dtb/ti/k3-am67a-beagley-ai.dtb.orig
cp -f /root/dtb-good/k3-am67a-beagley-ai.dtb.golden /boot/dtb/ti/k3-am67a-beagley-ai.dtb
sync
reboot
```

#### 方式 B：用仓库脚本在本地从头打补丁

如果你不想装 CSI0 摄像头（用 `k3-am67a-beagley-ai-edgeai.dtb`），或者想自己检查 DTB 改了什么，可以直接用本仓库的 [`scripts/patch-dtb-opp-thermal.py`](scripts/patch-dtb-opp-thermal.py)：

```sh
sudo apt-get install -y device-tree-compiler
sudo python3 scripts/patch-dtb-opp-thermal.py \
  /boot/dtb/ti/k3-am67a-beagley-ai-edgeai-csi0-imx219.dtb \
  /root/dtb-good/k3-am67a-beagley-ai.dtb.golden

sudo cp -n /boot/dtb/ti/k3-am67a-beagley-ai.dtb /boot/dtb/ti/k3-am67a-beagley-ai.dtb.orig
sudo cp -f /root/dtb-good/k3-am67a-beagley-ai.dtb.golden /boot/dtb/ti/k3-am67a-beagley-ai.dtb
sync && sudo reboot
```

### 4.3 重启后确认 DTB 全部生效

```sh
# 1. C7x 双核与 MAIN R5F 必须起来
for i in 0 1 2 3 4; do echo -n "remoteproc$i: "; cat /sys/class/remoteproc/remoteproc$i/state; done
# 期望输出：running / running / offline / attached / running

# 2. e5010 JPEG 编码器注册成功（没有 Flags mismatch）
dmesg | grep e5010
# 期望输出：e5010 fd20000.e5010: Device registered as /dev/video8（编号可能不同）

# 3. CPU 7 档变频已解锁到 1.4GHz
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
# 期望输出：200000 400000 600000 800000 1000000 1250000 1400000

# 4. 温控策略同时绑定了风扇 (pwm-fan) 和 CPU 降频 (cpufreq-cpu0)
ls -l /sys/class/thermal/thermal_zone0/cdev*
```

---

## 5. 补全板载 Wi-Fi 6 + BLE 5.4 低功耗蓝牙（以及实用外设驱动）

### 5.1 为什么默认只有骨架、没有无线和常用外设？

板载 TI CC3300（Wi-Fi 6 + BLE 5.4）芯片已经接在 SDIO (`mmc2:0001:2`) 和串口 (`serial0-0`) 上，`/lib/firmware/ti-connectivity/cc33xx_*.bin` 固件也全都在。但原版 `6.12.49-vendor-k3-beagle` 内核默认留了几个缺口：
- 没编 `CONFIG_CC33XX` / `CONFIG_CC33XX_SDIO`（没有 Wi-Fi）；
- 关闭了 `CONFIG_BT_LE`（经典蓝牙有，唯独没开低功耗蓝牙，而 CC3300 只支持 BLE 5.4）和 `CONFIG_CFG80211_DEBUGFS`（导致 `cc33xx` 的 `ble_enable` 唤醒入口不存在，`btti_uart` 永远等不到握手帧）；
- 同时关闭了一批开发板高频用到的模块（UASP USB 3 硬盘盒加速、CH341/PL2303 串口、USB 声卡、手机 USB RNDIS、`uinput`、SocketCAN `gs_usb`/`slcan`/`peak_usb`/`mcp251x`、GPIO PPS、WireGuard、exFAT、NTFS3）。

我们提供了**两种装法**：
- **方案 A（推荐，`v1.2.0` 完整升级内核包）**：一步把 Wi-Fi 6 + BLE 5.4 + 上述外设驱动全打开，且保持内核心脏版本号 `6.12.49-vendor-k3-beagle` 和你的 EdgeAI DTB 不变，包内已直接附带给新内核重编好的 PowerVR GPU 驱动 `pvrsrvkm.ko`，所有原系统文件都会先保留 `.orig` 备份；
- **方案 B（只要 Wi-Fi、不想动原内核）**：仅单独安装 `v1.1.0` 的 `cc33xx.ko` + `cc33xx_sdio.ko` 模块（或自己在板子上 38 秒原生编译），不启用板载 BLE。

---

### 5.2 方案 A（完整方案，推荐）：一键安装 `v1.2.0` 增强内核（含 Wi-Fi 6 + BLE 5.4）

> 如需自己在 PC/WSL 交叉编译同款内核，源码为 mainline `linux-6.12.49` + TI/BeagleBoard `6.12.49-ti-arm64-r56` 补丁集，构建工具需额外安装 `dwarves`（`pahole`）和 `zstd`。

#### ① 下载、校验并安装内核包

```sh
TAG=v1.2.0
BASE="https://github.com/xiaobright/beagley-ai-edgeai-bringup/releases/download/${TAG}"

curl -fLO "${BASE}/kernel-6.12.49-vendor-k3-beagle-full.tar.gz"
curl -fLO "${BASE}/SHA256SUMS"
grep kernel-6.12.49-vendor-k3-beagle-full.tar.gz SHA256SUMS | sha256sum -c

sudo bash scripts/install-kernel.sh kernel-6.12.49-vendor-k3-beagle-full.tar.gz
sudo reboot
```

[`scripts/install-kernel.sh`](scripts/install-kernel.sh) 会自动完成以下动作（**绝不覆盖 `/boot/dtb/ti/k3-am67a-beagley-ai.dtb` 和 `/boot/uEnv.txt`**）：
1. 保留完整回滚备份：`/boot/{Image,config-*,System.map-*}.orig`、`/lib/modules/6.12.49-vendor-k3-beagle.orig`、`/root/headers-sync-orig.tar.gz`、`/root/boot-orig/{initrd.img-*,uInitrd}`；
2. 安装新内核 `/boot/Image`、`/lib/modules/6.12.49-vendor-k3-beagle`（含重建好的 `updates/dkms/pvrsrvkm.ko`），并同步内核头文件符号供后续 DKMS 使用；
3. 更新 `uInitrd`（`update-initramfs -u -k 6.12.49-vendor-k3-beagle`）；
4. 写入 `/etc/modules-load.d/cc33xx.conf`（开机加载 `cc33xx_sdio` 与 `btti_uart`）、安装 `bluez`（加 `--no-install-recommends`，不触发 hold 包），并启用 `cc33xx-ble-enable.service`。

#### ② 重启后验证 Wi-Fi 6 与 BLE 5.4

```sh
# 1. 确认 Wi-Fi 接口已上线
iw dev
sudo ip link set wlan0 up
sudo iw dev wlan0 scan | grep -E 'SSID:|signal:' | head -n 20

# 2. 确认板载 TI BLE 5.4 控制器（hci0, version 13, manufacturer 13）
sudo btmgmt info
# 应看到：current settings: powered le secure-conn

# 3. 扫描周边 BLE 设备（测试 10 秒）
sudo timeout 10 btmgmt find -l
```

> **关于 BLE 的两个实际小坑：**
> 1. **CC3300 只有 BLE（没有经典蓝牙 BR/EDR）**，所以跑 `hciconfig -a` 时末尾会报错 `Can't read local name on hci0: Input/output error (5)`，这是 `hciconfig` 去查询经典蓝牙名称导致的正常现象，以 `btmgmt info` / `btmgmt find -l` 或 `bluetoothctl` 结果为准；
> 2. **开机唤醒脚本里不要直接调 `btmgmt`**：BlueZ 5.72 的 `btmgmt` 在无 TTY（`stdin=/dev/null`）的 `systemd` 服务中会永久阻塞，因此 [`scripts/cc33xx-ble-enable.sh`](scripts/cc33xx-ble-enable.sh) 仅负责向 `/sys/kernel/debug/ieee80211/phy*/cc33xx/ble_enable` 写入 `1`、解除可能存在的 rfkill 软阻塞并拉起 `hci0`，由 `bluetoothd`（默认 `AutoEnable=true`）接管上电。

#### ③ 如需回滚到原始内核

```sh
sudo cp -f /boot/Image.orig /boot/Image
sudo cp -f /boot/config-6.12.49-vendor-k3-beagle.orig /boot/config-6.12.49-vendor-k3-beagle
sudo cp -f /boot/System.map-6.12.49-vendor-k3-beagle.orig /boot/System.map-6.12.49-vendor-k3-beagle
sudo rm -rf /lib/modules/6.12.49-vendor-k3-beagle
sudo mv /lib/modules/6.12.49-vendor-k3-beagle.orig /lib/modules/6.12.49-vendor-k3-beagle
sudo cp -f /root/boot-orig/uInitrd /boot/uInitrd
sudo systemctl disable --now cc33xx-ble-enable.service
sync && sudo reboot
```

---

### 5.3 方案 B（仅需 Wi-Fi、不动原内核）：安装或编译独立 `.ko`

如果你希望保留原始 `/boot/Image` 不动（放弃板载 BLE），可直接下载 [`v1.1.0`](https://github.com/xiaobright/beagley-ai-edgeai-bringup/releases/tag/v1.1.0) 中的 `cc33xx-drivers-6.12.49-vendor-k3-beagle.tar.gz`，或自行在板端 38 秒原生编译模块：

```sh
curl -fLO "https://github.com/xiaobright/beagley-ai-edgeai-bringup/releases/download/v1.1.0/cc33xx-drivers-6.12.49-vendor-k3-beagle.tar.gz"
tar -xzf cc33xx-drivers-6.12.49-vendor-k3-beagle.tar.gz
sudo sh install.sh
```

自己从源码编模块时**不要从 `kernel.org` 下主线 6.12**（主线不含 `cc33xx`），应从 `beagleboard/linux` 分支 `v6.12.49-ti-arm64-r56` 拉取 `drivers/net/wireless/ti/cc33xx/` 和同级 `net/mac80211/*.h` 后在板端编译：

```sh
cd src-drivers/cc33xx
make -j4 -C /lib/modules/$(uname -r)/build M="$PWD" \
  CONFIG_CC33XX=m CONFIG_CC33XX_SDIO=m modules
modinfo cc33xx.ko cc33xx_sdio.ko | grep -E 'filename|vermagic|depends'
sudo make -C /lib/modules/$(uname -r)/build M="$PWD" \
  CONFIG_CC33XX=m CONFIG_CC33XX_SDIO=m modules_install
sudo depmod -a
echo cc33xx_sdio | sudo tee /etc/modules-load.d/cc33xx.conf
sudo modprobe cc33xx_sdio
```

### 5.4 配置开机自动连 Wi-Fi（保持有线网不断）

板子上默认走 `systemd-networkd` + `netplan`，`10-dhcp-all-interfaces.yaml` 只管有线网口 `e*`。新增一个 `/etc/netplan/20-wlan0.yaml`：

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
        "你的WiFi名称":
          password: "你的WiFi密码"
EOF
sudo chmod 600 /etc/netplan/20-wlan0.yaml
sudo netplan apply
```

这里有三个小细节，都是实测踩出来的：
1. **`dhcp4-overrides` 和 `dhcp6-overrides` 的 `route-metric` 必须写一样**，否则 `netplan apply` 直接报错拒绝生效；
2. **`route-metric: 200` 比有线网 `eth0` 的默认 `100` 大**：这样同时插着网线和连着 Wi-Fi 时，默认流量优先走千兆有线，不会把你的有线 SSH 连断；拔掉网线时自动切到 Wi-Fi；
3. **`optional: true`**：带去没有这个热点的环境开机时，不会卡在等联网阶段耽误启动。

实测效果：`wlan0` 连接 2.4GHz Wi-Fi 6 路由器，握手 `HE-MCS 7`（86.0 MBit/s RX），重启后自动拿 IP 上网，与 BLE 5.4 扫描共存且不影响 `eth0`。注：CC3300 为单天线 2.4GHz 单流芯片，不支持 5GHz，实测可用吞吐约 20–40 Mbps 属于正常水平。

---

## 6. 恢复 GPU（PowerVR BXS-4-64）

> 如果你按第 5 节方案 A 安装了 `v1.2.0` 完整内核包，包里已经自带编好的 `pvrsrvkm.ko`，直接跳过重编看下方验证命令即可。

装完 EdgeAI deb 包后（或自己重编内核后），Armbian 自带的 GPU 驱动（`ti-img-rogue-driver`）需要为当前内核重编一次 DKMS，否则 `/dev/dri` 下只剩 `card0`、没有 `card1` 和 `renderD128`，GPU 会静默失效。

```sh
VER=$(dkms status | grep ti-img-rogue-driver | head -1 | sed 's/.*ti-img-rogue-driver\/\([^,]*\),.*/\1/')
sudo PVR_BUILD_DIR=am62p_linux WINDOW_SYSTEM=wayland \
  dkms install "ti-img-rogue-driver/${VER}" -k "$(uname -r)" --force
sudo modprobe pvrsrvkm
```

验证：

```sh
ls /dev/dri/                      # 必须看到 card0  card1  renderD128
eglinfo 2>/dev/null | head -n 20  # 应看到 PowerVR B-Series BXS-4-64 / OpenGL ES 3.2
```

---

## 7. 摄像头（IMX219）+ ISP + 硬件编码

### 7.1 物理接法与开机后初始化

- 摄像头排线插在 **`CSI0`** 口（`CSI1` 和 `DSI0` 屏幕共用 PHY，插屏就不能用 `CSI1`）。
- 每次重启后，必须先用 `media-ctl` 配置整条媒体管线格式（如果执行过 `media-ctl -r` 清空了配置，必须重跑，否则 GStreamer 不会报错但一帧不出）。直接运行仓库里的 [`scripts/setup-camera.sh`](scripts/setup-camera.sh)：

```sh
sudo sh scripts/setup-camera.sh
```

> 节点编号（`/dev/video2`、`/dev/v4l-subdev2` 等）可能随开机探针顺序变化，如报错找不到设备，先用 `v4l2-ctl --list-devices` 确认 `j721e-csi2rx` 和 `e5010` 对应的编号。

### 7.2 跑通 VPAC ISP 抓拍

```sh
DCC=/opt/imaging/imx219/linear

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
```

三个容易踩的细节：
1. `dcc-2a-file` 是 **pad 属性**，必须写成 `sink_0::dcc-2a-file=`；而 `dcc-isp-file` 是 element 属性；
2. 8-bit Bayer 必须加 `format-msb=7`，否则画面明显偏暗偏绿；
3. 自动 AE 在暗光场景可能把曝光压到全黑，调试阶段建议加 `sink_0::ae-mode=1` 手动设曝光/增益。

### 7.3 视频与 JPEG 硬编码测试

```sh
# 1. JPEG 硬编压测（e5010），1080p 约 39.7 fps
gst-launch-1.0 -q videotestsrc num-buffers=100 ! \
  video/x-raw,width=1920,height=1080,format=NV12 ! v4l2jpegenc ! fakesink

# 2. 摄像头 -> ISP -> H.264 硬编录像（wave5），1080p 约 29.7 fps
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

> 注：ISP 输出 NV12 直接进 `v4l2jpegenc` 会因为 stride 对齐出现横条纹，中间插一个 `videoconvert` 可避免；而接 `v4l2h264enc` 可直出无需转换。

---

## 8. 验证 AI 推理（C7x + TIDL）

先运行 TI 安装器自带的严格冒烟测试（会强制禁用 CPU fallback，确保算子真正跑在双核 C7x 上）：

```sh
# 如果开着 gatekeeper 服务，先停掉，否则两个程序会抢 TIOVX/TIDL 锁导致卡死
sudo systemctl disable --now ti-edgeai-dachshund-gatekeeper
sudo validate-j722s-edgeai
```

看到末尾输出 `TI EDGEAI RUNTIME VALIDATION: PASS` 即全部通过（新内核重测：ONNX `regnetx-200mf` 103/103 节点全卸载到 C7x 平均 **8.36 ms**；TFLite `mobilenet_v1` 34/34 算子全卸载平均 **4.67 ms**）。

如果想开浏览器看官方实时检测 Demo（`http://<板子IP>:8088`）：

```sh
sudo systemctl start ti-edgeai-dachshund-gatekeeper
curl -s http://127.0.0.1:8088/api/status | python3 -m json.tool
```

> **提示**：这个 Gatekeeper demo 代码里**写死了只认 COCO 第 16 类（狗）**！对着人、手或其它物体测试时永远显示 `present: false`，不是坏了，切换 demo 里自带的视频源就能看到识别和品种分类结果。

---

## 9. 锁死关键软件版本（防止一次 `apt upgrade` 毁掉整机）

这套环境的**内核 ↔ DTB ↔ GPU DKMS ↔ TI EdgeAI 固件 ↔ TI 定制 GStreamer** 必须严格锁步。普通 `apt upgrade` 一旦升级内核、覆盖 DTB 或只升级半套驱动，就会立刻导致 C7x、GPU、JPEG 或摄像头报废。

把这 **15 个关键包**全部加入 `hold`（已补全之前容易遗漏的两个 `+ti1` 定制 GStreamer 包和 `libgbm1-pvr`）：

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
```

检查效果（`apt list --upgradable` 会无视 hold，要用 `apt-get -s upgrade` 模拟确认）：

```sh
apt-mark showhold | wc -l          # 期望：15
apt-get -s upgrade | grep -E '^(Inst|Remv) (linux-|ti-img|ti-edgeai|armbian-|gstreamer|libgbm1-pvr)'
# 期望没有任何输出
```

万一哪天手滑覆盖了 `/boot/dtb/ti/k3-am67a-beagley-ai.dtb`，执行仓库里的 [`scripts/reapply-edgeai-dtb.sh`](scripts/reapply-edgeai-dtb.sh) 恢复 `/root/dtb-good/k3-am67a-beagley-ai.dtb.golden` 并重启即可。

---

## 10. 报错速查表（直接按报错原文检索）

| 你看到的报错 / 现象 | 真正原因 | 怎么解决 |
|---|---|---|
| `remoteproc: bad phdr da 0xa3ffec00` / `Failed to load program segments: -22` | 还在用原厂 DTB，没有预留 EdgeAI 共享内存（`armbianEnv.txt` 的 `fdtfile` 被启动脚本忽略了） | 第 4 节：直接把修好的 DTB 覆盖到 `/boot/dtb/ti/k3-am67a-beagley-ai.dtb` |
| `/dev/dri` 下只有 `card0`，`eglinfo` 里没有 PowerVR（**无任何报错**） | EdgeAI 换了内核但没给新内核重编 GPU DKMS 模块 | 第 6 节：`dkms install ti-img-rogue-driver/... -k $(uname -r) --force` |
| `genirq: Flags mismatch irq ... (e5010) vs. (pinctrl)` → `-EBUSY` | TI 公共 DTS 里 `pinctrl@f4000` 写了假中断号 98，和 e5010 冲突 | 第 4 节：用修好的 DTB（删掉了 `pinctrl@f4000` 三行中断属性） |
| 刷完 `-gnome-wayland-mid-` 镜像上电只亮红灯、2.1W、无显示无网络 | 4GB 板子带不动该桌面镜像首启 | 第 3.1 节：改刷 `minimal` 镜像 |
| `Unable to init TIOVX module` | **三种故障全报这一句**，必须加 `GST_DEBUG=3` 看真实报错 | 按下面三条对应排查 |
| `Unable to open 2A config file: (null)` 或 `no property "dcc-2a-file"` | `dcc-2a-file` 是 pad 属性而不是元素属性 | 写成 `sink_0::dcc-2a-file=...` |
| `TIVX_CMD_NODE_CREATE failed ... com.ti.hwa.vpac_viss` | 上次异常杀掉管线导致 VISS 硬件状态机卡死，或 CMA 内存不足 | 先 `reboot`；反复出现检查可用 CMA |
| `cma: __cma_alloc ... alloc failed` / `dma alloc of size 33554432 failed` | 运行久了连续物理内存碎片化，wave5 申请不到 32MB 连续块 | `reboot` 释放内存碎片，避免同时开太多视频管线 |
| GStreamer `PLAYING` 但 0 帧输出、文件 0 字节 | ① 跑过 `media-ctl -r` 忘了重设格式；② VISS 卡死；③ 用了 `tiovxmultiscaler` | 先重跑 `setup-camera.sh`；不行就重启并避开 `tiovxmultiscaler` |
| 摄像头拍出来全黑 / 偏绿偏暗 | 自动 AE 在暗处把曝光压到最低；或没告诉 ISP 是 8-bit Bayer | 加 `format-msb=7` 和 `sink_0::ae-mode=1` 手动调曝光 |
| `validate-j722s-edgeai` 运行后一直卡住不动 | `ti-edgeai-dachshund-gatekeeper` 后台占着 TIDL/TIOVX 锁 | `sudo systemctl disable --now ti-edgeai-dachshund-gatekeeper` 后重启 |
| `netplan apply` 报 `route-metric has the same value in both dhcp4_overrides and dhcp6_overrides` | 开启了 `dhcp6: yes`，但只给 `dhcp4-overrides` 配了 metric | 第 5.4 节：同时写 `dhcp4-overrides` 和 `dhcp6-overrides` |
| `fatal error: ../net/mac80211/ieee80211_i.h: No such file` | 手动编 `cc33xx` 时只拷了驱动目录，漏了同级 `net/mac80211/*.h` | 第 5.3 节：补全 `net/mac80211/*.h`（或直接用 Release 成品包） |
| `echo stop > .../remoteprocN/state` 卡 5 秒报 `-16` (`-EBUSY`) | K3 停止固件需要固件端配合应答 mailbox，自编裸机固件与部分 TI 固件没实现停止握手 | 无法热停核，直接 `reboot` |
| `onnxruntime ... Failed to open "/sys/class/drm/card1/device/vendor"` | PowerVR sysfs 节点规范差异导致的无害警告 | 可安全忽略，不影响 TIDL 硬件推理 |
| `Can't read local name on hci0: Input/output error (5)` | CC3300 是纯 BLE 芯片，没有经典蓝牙名，但 `hciconfig -a` 去读经典蓝牙名称 | 属正常提示，改用 `btmgmt info` / `btmgmt find -l` 或 `bluetoothctl` 验证 |

---

## 11. 已知官方未修限制 & 功耗 / 温控实测

### 11.1 目前上游无解的问题（遇到不用白费力气）

- **没有 `cpuidle` 深度休眠**：TI 上游 J722S 设备树从未描述低功耗空闲状态。实测空载把 CPU 最高频率限制到 600MHz，整机功耗依然是 **5.4W**（降频对空载省电几乎无用，而 1.2GHz → 1.4GHz 满载功耗只多 0.1W 性能却提升 17%，所以放开跑 1.4GHz 最划算）。
- **`tiovxmultiscaler` 插件无输出**：caps 协商成功但不吐帧，无报错。导致在 1080p 摄像头 AI 管线里如果接软件 `videoconvert` 转 BGR，单核 CPU 会吃满，帧率掉到 **6.4–9.75 fps**（可在应用侧改用 OpenCV NEON `COLOR_YUV2BGR_NV12` 或先缩放缓解）。
- **频繁启停 `tiovxisp` 偶发 VISS 卡死**：目前只能重启恢复。
- **主线 `powervr` 驱动崩溃**：必须按第 6 节用 TI DDK 的 `pvrsrvkm`，不要去解黑名单用主线驱动。

### 11.2 温控降频实测（已通过 DTB 补齐）

- **风扇策略**（`thermal_zone0`）：40°C / 48°C / 60°C 三档渐进调节 `pwm-fan`。
- **被动降频策略**（`thermal_zone0` / `thermal_zone1` / `thermal_zone2`）：80°C（`80000` m°C，回差 `5000`）绑定 `cpufreq-cpu0`（`step_wise` 策略）。
- 实测验证：向 `/sys/class/thermal/thermal_zone0/emul_temp` 写入 `85000` 模拟 85°C 高温时，`cooling_device0/cur_state` 自动切到 `1`，`scaling_max_freq` 立即从 `1400000` 压降到 `1250000`（手动验证 state 4 可压到 `600000`）；清除 `emul_temp`（写 `0`）后立刻恢复 1.4GHz。

---

## 12. 附录：片上 MCU（Cortex-R5F）裸机开发说明

板子上共有 3 个 Cortex-R5F 核：
- `remoteproc3`（`78000000.r5f`，WKUP 域）：跑系统电源与时钟管理的 Device Manager（`attached`），**绝对别碰**。
- `remoteproc4`（`78400000.r5f`，MAIN 域）：跑 `vision_apps`（`running`），TIDL / ISP 要用。
- `remoteproc2`（`79000000.r5f`，MCU 域）：默认 `offline`（出厂没放固件），唯一可自由折腾的核。

注意硬件限制：**BeagleY-AI 没有把 MCU 域的 UART/SPI/CAN 引到 40pin 排针上**，只留了共享内存和极少测试点，跑起来空载多耗约 0.05W，实用场景有限。我们把一个 184 字节的极简双向通信 Demo 源码留在了 [`mcu-r5f/`](mcu-r5f/)（对应 Release 里的 `r5fw.elf`），详细踩坑记录（BTCM 映射 `0x0` 约定、必需的 16 字节 `.resource_table` 段、ARM 模式要求）见 [`mcu-r5f/README.md`](mcu-r5f/README.md)。

---

## 仓库目录导航

- [`scripts/install-kernel.sh`](scripts/install-kernel.sh) —— 一键安装 `v1.2.0` 完整内核（含 BLE 5.4、常用外设驱动及重编好的 GPU 驱动，自动留 `.orig` 备份）
- [`scripts/cc33xx-ble-enable.sh`](scripts/cc33xx-ble-enable.sh) —— 开机通过 debugfs 唤醒板载 CC3300 BLE 5.4 控制器脚本
- [`scripts/install-cc33xx.sh`](scripts/install-cc33xx.sh) —— 仅在原内核上安装预编译 Wi-Fi 模块脚本（`v1.1.0`）
- [`scripts/patch-dtb-opp-thermal.py`](scripts/patch-dtb-opp-thermal.py) —— 一键为原版 EdgeAI DTB 打上 e5010 + 1.4GHz OPP + 80°C 温控补丁
- [`scripts/reapply-edgeai-dtb.sh`](scripts/reapply-edgeai-dtb.sh) —— 恢复黄金 DTB 脚本
- [`scripts/setup-camera.sh`](scripts/setup-camera.sh) —— IMX219 CSI0 媒体管线初始化脚本
- [`mcu-r5f/`](mcu-r5f/) —— MCU Cortex-R5F 极简裸机通信 Demo
