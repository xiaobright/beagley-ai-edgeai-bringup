# MCU R5F bare-metal demo (J722S / AM67A on BeagleY-AI)

Minimal firmware for **`remoteproc2` = `79000000.r5f` = MCU R5F0_0**, the one
R5F core on this SoC that nothing else uses. No TI MCU+ SDK, no libc — one
`start.S`, one `r5fw.c`, a linker script and a Makefile, 184 bytes of output.

It boots the core, writes a heartbeat into the DDR carveout the device tree
hands to `remoteproc2` (`0xa1100000`), and echoes a word written by the A53.
That is enough to prove the whole path: reset release via TISCI, firmware load,
execution, and bidirectional data exchange with Linux.

## Build

```sh
sudo apt install -y --no-install-recommends gcc-arm-none-eabi binutils-arm-none-eabi
make
```

Build on a PC or in WSL. 184 bytes compile instantly anywhere, but the moment a
real SDK is involved the A53 becomes painful.

## Install and boot

```sh
sudo cp r5fw.elf /lib/firmware/j722s-mcu-r5f0_0-fw
sudo sh -c 'echo start > /sys/class/remoteproc/remoteproc2/state'
dmesg | tail -3
# remoteproc remoteproc2: remote processor 79000000.r5f is now up
```

Once the file exists the core **autoboots on every boot** — no service needed.
To go back to stock: `rm /lib/firmware/j722s-mcu-r5f0_0-fw` and reboot.

## Verify from Linux

```sh
python3 - <<'EOF'
import mmap, os, struct
f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(f, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xa1100000)
print("magic=0x%08x heart=%d" % struct.unpack("<2I", m[:8]))
m[8:12] = struct.pack("<I", 0x12345678)          # CMD
print("echo=0x%08x  (expect 0xedcba987)" % struct.unpack("<I", m[12:16]))
EOF
```

Shared page layout (word indexes from `0xa1100000`):

| idx | offset | name | written by | meaning |
|---|---|---|---|---|
| 0 | +0x00 | MAGIC | R5F | `0x0000c0de` once at startup |
| 1 | +0x04 | HEART | R5F | increments forever |
| 2 | +0x08 | CMD | Linux | command word |
| 3 | +0x0c | ECHO | R5F | `~CMD` |
| 4 | +0x10 | STAT | R5F | bit0 = alive |

## Three non-obvious constraints

1. **BTCM is at R5F address `0x0`.** The DT has `ti,loczrama = 0`, so the driver
   places BTCM (`0x79020000` on the bus) at device address `0`. The vector table
   must therefore live at `0x0` and the ELF entry point must be `0x0`.
   (MAIN R5F has `loczrama = 1`, which puts its *ATCM* at `0x0` — same entry
   value, different memory.)

2. **The ELF must contain a `.resource_table` section.** `rproc_elf_load_rsc_table()`
   in this kernel returns `-EINVAL` when it is missing and prints nothing, so all
   you see is `Boot failed: -22`. A 16-byte table with `ver = 1, num = 0` is
   enough; `num = 0` registers no virtio/rpmsg device.

3. **ARM state, caches off.** `k3_r5_rproc_configure()` clears
   `PROC_BOOT_CFG_FLAG_R5_TEINIT`, so the core starts in ARM mode with caches
   disabled. Compile with `-marm` and drive DDR by physical address; uncached
   stores mean every write is a real bus transaction.

## Known limitation: you cannot stop it

```sh
echo stop > /sys/class/remoteproc/remoteproc2/state
# 5.1 s later:
# platform 79000000.r5f: k3_r5_rproc_stop: timeout waiting for rproc completion event
# remoteproc remoteproc2: can't stop rproc: -16
```

TI's K3 remoteproc stops a core by pinging the firmware over the mailbox and
waiting for an ack. Bare-metal firmware has no such handshake, so the driver
times out and returns `-EBUSY`. **Reboot is the only way to reset the core or
load different firmware.** If you need graceful stop/restart, build the
firmware with the MCU+ SDK `ipc_rpmsg_echo_linux` example, which implements the
IPC handshake and virtio channels.

## Measured

```
MAGIC=0x0000c0de HEART=97178 CMD=0x00000000 ECHO=0xffffffff STAT=0x1
MAGIC=0x0000c0de HEART=124690 CMD=0x00000000 ECHO=0xffffffff STAT=0x1
wrote CMD=0x12345678  ->  ECHO=0xedcba987  (expect 0xedcba987)  MATCH
wrote CMD=0xdeadbeef  ->  ECHO=0x21524110  (expect 0x21524110)  MATCH
heartbeat: 408290 -> 423585 in 1.000s = 15289 iters/s
```

15,289 iterations/s against a 7-instruction delay loop ≈ 65 µs per iteration,
about 26k cycles at 400 MHz, consistent with the R5F's rated clock. The MCU
domain clock tree is owned by the DM firmware, so Linux `clk_summary` shows no
R5F clock and there is no harder measurement to make.

## Hardware note

The R5F's own peripherals are not reachable on this board. MCU_I2C0 is on the
40-pin header but Linux already owns it; MCU_UART0, MCU_SPI0/1 and MCU_MCAN0/1
are `disabled` in the DT yet have **no pinctrl groups** and never reach the
header. Driving real I/O from this core requires soldering to test points.
