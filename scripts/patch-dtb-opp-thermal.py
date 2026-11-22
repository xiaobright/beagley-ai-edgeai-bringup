#!/usr/bin/env python3
"""Apply all BeagleY-AI EdgeAI DTB fixes in one idempotent pass.

Fixes applied to an unpatched (or partially patched) EdgeAI DTB:
  1. e5010 JPEG IRQ conflict: remove dummy interrupts/interrupt-controller/
     #interrupt-cells from pinctrl@f4000 (which collide with e5010 GIC SPI 98).
  2. A53 cpufreq (200M..1.4G): add /cpus/opp-table (opp-shared) and
     operating-points-v2 + #cooling-cells on cpu@0..3.
  3. Thermal throttling: add 80 C passive trips and bind cpu@0 (cpufreq-cpu0)
     in main0/1/2-thermal cooling-maps while keeping existing pwm-fan maps.

Usage:
  sudo python3 patch-dtb-opp-thermal.py \
      /boot/dtb/ti/k3-am67a-beagley-ai-edgeai-csi0-imx219.dtb \
      /tmp/k3-am67a-beagley-ai-patched.dtb
"""
import argparse
import pathlib
import re
import subprocess
import sys
import tempfile

RATES = [
    200_000_000,
    400_000_000,
    600_000_000,
    800_000_000,
    1_000_000_000,
    1_250_000_000,
    1_400_000_000,
]
LATENCY_NS = 2_000_000


def alloc_free_phandles(text: str, count: int) -> list[str]:
    used = {int(x, 16) for x in re.findall(r"phandle = <(0x[0-9a-fA-F]+)>;", text)}
    res = []
    cand = 0x1F0
    while len(res) < count:
        if cand not in used:
            res.append(f"0x{cand:x}")
            used.add(cand)
        cand += 1
    return res


def strip_pinctrl_irq(text: str) -> tuple[str, list[str]]:
    out, inside, removed = [], False, []
    depth = 0
    for line in text.splitlines(True):
        if not inside and re.search(r"^\t\tpinctrl@f4000\s*\{", line):
            inside = True
            depth = 1
            out.append(line)
            continue
        if inside:
            depth += line.count("{") - line.count("}")
            if depth == 1:
                s = line.strip()
                if s.startswith(("interrupts =", "interrupt-controller;", "#interrupt-cells")):
                    removed.append(s)
                    continue
            if depth <= 0:
                inside = False
        out.append(line)
    return "".join(out), removed


def add_cpu_opp(text: str, opp_ph: str) -> tuple[str, bool]:
    m_cpu0 = re.search(r"\t\tcpu@0\s*\{(.*?)\n\t\t\};", text, re.S)
    if not m_cpu0:
        sys.exit("ERROR: cpu@0 node not found")
    if "operating-points-v2" in m_cpu0.group(1):
        return text, False

    table_lines = [
        "",
        "\t\tcpu_opp_table: opp-table {",
        '\t\t\tcompatible = "operating-points-v2";',
        "\t\t\topp-shared;",
        f"\t\t\tphandle = <{opp_ph}>;",
    ]
    for hz in RATES:
        table_lines += [
            "",
            f"\t\t\topp-{hz} {{",
            f"\t\t\t\topp-hz = /bits/ 64 <{hz}>;",
            "\t\t\t\topp-microvolt = <850000>;",
            f"\t\t\t\tclock-latency-ns = <{LATENCY_NS}>;",
            "\t\t\t};",
        ]
    table_lines += ["\t\t};", ""]
    table = "\n".join(table_lines)

    anchor = "\tcpus {\n\t\t#address-cells = <0x01>;\n\t\t#size-cells = <0x00>;\n"
    if anchor not in text:
        sys.exit("ERROR: /cpus anchor not found in DTS")
    text = text.replace(anchor, anchor + table, 1)

    count = 0

    def repl_cpu(m: re.Match[str]) -> str:
        nonlocal count
        count += 1
        body = m.group(0)
        props = f"\t\t\toperating-points-v2 = <{opp_ph}>;\n\t\t\t#cooling-cells = <0x02>;\n"
        return body.replace("\t\t\tclocks = <", props + "\t\t\tclocks = <", 1)

    text, _ = re.subn(r"\t\tcpu@[0-3] \{(?:[^}]*)\};", repl_cpu, text)
    if count != 4:
        sys.exit(f"ERROR: expected 4 cpu nodes, patched {count}")
    return text, True


def add_thermal_cooling(text: str, trip_phs: list[str]) -> tuple[str, bool]:
    if "trip-passive0" in text or "map-cpu0" in text:
        return text, False

    m_cpu = re.search(r"\t\tcpu@0\s*\{(.*?)\n\t\t\};", text, re.S)
    if not m_cpu:
        sys.exit("ERROR: cpu@0 node not found")
    m_ph = re.search(r"phandle = <(0x[0-9a-fA-F]+)>;", m_cpu.group(1))
    if not m_ph:
        sys.exit("ERROR: cpu@0 phandle not found")
    cpu0_ph = m_ph.group(1)

    # Extract main0..2 thermal blocks cleanly and patch each zone
    for idx, zone_name in enumerate(("main0-thermal", "main1-thermal", "main2-thermal")):
        trip_ph = trip_phs[idx]
        m_zone = re.search(
            rf"(\t\t{zone_name}\s*\{{.*?\n\t\t\}};)", text, re.S
        )
        if not m_zone:
            sys.exit(f"ERROR: {zone_name} not found")
        zone = m_zone.group(1)

        # Insert passive trip right before closing "};" of trips { ... }
        trip_block = (
            "\n\t\t\t\ttrip-passive"
            + str(idx)
            + " {\n"
            + "\t\t\t\t\ttemperature = <80000>;\n"
            + "\t\t\t\t\thysteresis = <5000>;\n"
            + '\t\t\t\t\ttype = "passive";\n'
            + f"\t\t\t\t\tphandle = <{trip_ph}>;\n"
            + "\t\t\t\t};\n"
            + "\t\t\t};"
        )
        m_trips = re.search(r"(\t\t\ttrips\s*\{.*?\n)(\t\t\t\};)", zone, re.S)
        if not m_trips:
            sys.exit(f"ERROR: trips block missing in {zone_name}")
        new_trips = m_trips.group(1) + trip_block
        zone_patched = zone[: m_trips.start()] + new_trips + zone[m_trips.end() :]

        map_entry = (
            "\t\t\t\tmap-cpu0 {\n"
            + f"\t\t\t\t\ttrip = <{trip_ph}>;\n"
            + f"\t\t\t\t\tcooling-device = <{cpu0_ph} 0xffffffff 0xffffffff>;\n"
            + "\t\t\t\t};\n"
        )
        if "\t\t\tcooling-maps {" in zone_patched:
            m_cm = re.search(r"(\t\t\tcooling-maps\s*\{.*?\n)(\t\t\t\};)", zone_patched, re.S)
            if not m_cm:
                sys.exit(f"ERROR: cooling-maps closing brace missing in {zone_name}")
            zone_patched = (
                zone_patched[: m_cm.start()]
                + m_cm.group(1)
                + "\n"
                + map_entry
                + m_cm.group(2)
                + zone_patched[m_cm.end() :]
            )
        else:
            cm_block = "\n\t\t\tcooling-maps {\n\n" + map_entry + "\t\t\t};\n\t\t};"
            zone_patched = zone_patched[:-4] + cm_block  # replace trailing "\n\t\t};"
            if not zone_patched.endswith("\t\t};"):
                sys.exit(f"ERROR: unexpected ending in {zone_name}")

        text = text.replace(zone, zone_patched, 1)

    return text, True


def verify_dts(chk: str) -> None:
    va_cnt = chk.count("vision-apps")
    if va_cnt < 30:
        sys.exit(f"VERIFY FAILED: vision-apps count={va_cnt} (expected >= 30)")
    m_pmx = re.search(r"^\t\tpinctrl@f4000\s*\{(.*?)\n\t\t\};", chk, re.M | re.S)
    if not m_pmx:
        sys.exit("VERIFY FAILED: pinctrl@f4000 missing")
    # Check only direct properties of pinctrl@f4000 before first child node
    header = m_pmx.group(1).split("{", 1)[0]
    if "interrupts" in header or "interrupt-controller" in header:
        sys.exit("VERIFY FAILED: pinctrl@f4000 still has interrupt properties")
    for hz in RATES:
        if f"opp-{hz}" not in chk:
            sys.exit(f"VERIFY FAILED: missing opp-{hz}")
    for token in ("map1 {", "map2 {", "map3 {", "trip-passive0 {", "trip-passive1 {", "trip-passive2 {"):
        if token not in chk:
            sys.exit(f"VERIFY FAILED: missing {token}")
    if chk.count("map-cpu0 {") != 3:
        sys.exit(f"VERIFY FAILED: expected 3 map-cpu0 entries, got {chk.count('map-cpu0 {')}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("input_dtb", help="Source EdgeAI DTB path")
    ap.add_argument("output_dtb", help="Output patched DTB path")
    args = ap.parse_args()

    in_path = pathlib.Path(args.input_dtb)
    out_path = pathlib.Path(args.output_dtb)
    if not in_path.is_file():
        sys.exit(f"ERROR: input DTB not found: {in_path}")

    with tempfile.TemporaryDirectory() as td:
        td_path = pathlib.Path(td)
        src_dts = td_path / "in.dts"
        mod_dts = td_path / "mod.dts"
        chk_dts = td_path / "chk.dts"
        tmp_dtb = td_path / "out.dtb"

        subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", str(src_dts), str(in_path)], check=True)
        text = src_dts.read_text()

        phs = alloc_free_phandles(text, 4)
        text, removed = strip_pinctrl_irq(text)
        text, opp_added = add_cpu_opp(text, phs[0])
        text, th_added = add_thermal_cooling(text, phs[1:4])

        mod_dts.write_text(text)
        r = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(tmp_dtb), str(mod_dts)],
                           capture_output=True, text=True)
        if r.returncode:
            print(r.stderr[-2000:], file=sys.stderr)
            sys.exit("ERROR: dtc compile failed")

        subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", str(chk_dts), str(tmp_dtb)], check=True)
        verify_dts(chk_dts.read_text())

        out_path.write_bytes(tmp_dtb.read_bytes())
        print(f"Patched DTB written -> {out_path} ({out_path.stat().st_size} bytes)")
        print(f"  pinctrl@f4000 removed: {removed}")
        print(f"  cpufreq OPP added:     {opp_added}")
        print(f"  thermal maps added:    {th_added}")


if __name__ == "__main__":
    main()
