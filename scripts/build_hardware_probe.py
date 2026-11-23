"""Build the separate UART/PCM hardware probe without touching the FPGA.

The vendor build runs in an ASCII-only staging directory; source hashes,
bitstream, logs and timing reports are copied to build/hardware_probe/.
"""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
LABEL = "hardware_probe"
ROM_PREPEND = "`define GOWIN_PRIMITIVES\n"


def gowin_home():
    home = os.environ.get('GOWIN_HOME')
    if not home:
        raise SystemExit('Set GOWIN_HOME to the Gowin EDA installation root')
    return Path(home).expanduser().resolve()


def gowin_stage_root():
    root = Path(os.environ.get('BEATIT_STAGE_DIR') or tempfile.gettempdir()).expanduser().resolve()
    if not str(root).isascii():
        raise SystemExit('Set BEATIT_STAGE_DIR to a short ASCII-only staging directory')
    return root


def probe_label(voices, independent=False):
    if voices not in (4, 8, 16, 32):
        raise ValueError("Probe voices must be4,8,16 or32")
    label=LABEL if voices == 4 else f"{LABEL}_{voices}"
    return label+("_independent" if independent else "")


def probe_key_mask(voices):
    probe_label(voices)  # Validate before shifting.
    return 0x55 if voices == 4 else (1 << voices) - 1


def make_probe_variant(source, voices, independent=False):
    """Exact asserted substitutions in a staging copy; never edit project RTL."""
    mask = probe_key_mask(voices)
    file = str(Path("rtl") / "hardware_probe_top.v")
    anchors = [
        (".NUM_VOICES(4)", f".NUM_VOICES({voices})"),
        ("wire [3:0] active;", f"wire [{voices-1}:0] active;"),
        ("wire [31:0] requested=phase_a4?32'h00000020:32'h00000055;",
         f"wire [31:0] requested=phase_a4?32'h00000020:32'h{mask:08x};"),
    ]
    substitutions = []
    for old, new in anchors:
        if source.count(old) != 1:
            raise ValueError(f"Probe source anchor must occur exactly once: {old}")
        if voices != 4:
            source = source.replace(old, new, 1)
            substitutions.append(dict(file=file, kind="replace", old=old, new=new, count=1))
    if independent:
        anchor=f'.NUM_VOICES({voices})'
        replacement=anchor+',.DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(1)'
        if source.count(anchor)!=1:raise ValueError('Probe dual DDS anchor mismatch')
        source=source.replace(anchor,replacement,1)
        substitutions.append(dict(file=file,kind='replace',old=anchor,new=replacement,count=1))
        anchor="17'd66048";replacement="17'd67456"
        if source.count(anchor)!=1:raise ValueError('Probe B frequency anchor mismatch')
        source=source.replace(anchor,replacement,1)
        substitutions.append(dict(file=file,kind='replace',old=anchor,new=replacement,count=1))
    return source, substitutions


def source_hashes(stage):
    return {
        str(file.relative_to(stage)): hashlib.sha256(file.read_bytes()).hexdigest()
        for folder in ("rtl", "constraints")
        for file in sorted((stage / folder).glob("*"))
        if file.is_file()
    }


def prepare_probe_sources(stage, voices, independent=False):
    """Return provenance for already copied source trees in a fresh stage."""
    original_hashes = source_hashes(stage)
    top = stage / "rtl" / "hardware_probe_top.v"
    variant, substitutions = make_probe_variant(top.read_text(encoding="utf-8"), voices, independent)
    if voices != 4 or independent:
        top.write_text(variant, encoding="utf-8", newline="\n")
    rom = stage / "rtl" / "sine_rom_pair.v"
    rom.write_text(ROM_PREPEND + rom.read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
    substitutions.append(dict(file=str(Path("rtl") / "sine_rom_pair.v"),
                              kind="prepend", old="", new=ROM_PREPEND, count=1))
    if independent:
        ram=stage/'rtl/osc_envelope_ram.v'
        ram.write_text(ROM_PREPEND+ram.read_text(encoding='utf-8'),encoding='utf-8',newline='\n')
        substitutions.append(dict(file=str(Path('rtl')/'osc_envelope_ram.v'),kind='prepend',old='',new=ROM_PREPEND,count=1))
    return dict(osc2_factor=67456 if independent else 66048,independent_osc=independent,voices=voices, key_mask=probe_key_mask(voices), a4_key_mask=0x20,
                sources_sha256=original_hashes, staged_sources_sha256=source_hashes(stage),
                stage_substitutions=substitutions)


def copy_artifact(source, target):
    target = Path(target)
    assert target.resolve().is_relative_to((ROOT / "build").resolve())
    if target.exists():
        target.chmod(stat.S_IREAD | stat.S_IWRITE)
    return shutil.copyfile(source, target)


def timing_result(stage, label=LABEL):
    report = stage / "impl" / "pnr" / f"{label}_tr_content.html"
    if not report.is_file():
        return None
    flat = " ".join(
        html.unescape(re.sub(r"<[^>]+>", " ", report.read_text(errors="replace"))).split()
    )
    setup = re.search(r"Numbers of Setup Violated Endpoints (\d+)", flat)
    hold = re.search(r"Numbers of Hold Violated Endpoints (\d+)", flat)
    frequencies = {}
    summary = flat.split("Max Frequency Summary:", 1)
    if len(summary) == 2:
        for name, required, achieved in re.findall(
            r"\b(sys_clk|ref_clk)\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)",
            summary[1],
        ):
            frequencies[name] = {
                "required_mhz": float(required),
                "achieved_mhz": float(achieved),
            }
    return {
        "setup_violations": int(setup[1]) if setup else None,
        "hold_violations": int(hold[1]) if hold else None,
        "frequencies": frequencies,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--voices", type=int, choices=(4, 8, 16, 32), default=4)
    parser.add_argument("--independent-osc",action="store_true")
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    label = probe_label(args.voices,args.independent_osc)
    home = gowin_home()
    tool = home / "IDE" / "bin" / "gw_sh.exe"
    if not tool.is_file():
        raise SystemExit("Set GOWIN_HOME to Gowin Education installation root")

    stage = gowin_stage_root() / (
        f"nano20k_{label}_{time.strftime('%Y%m%d_%H%M%S')}_{os.getpid()}"
    )
    stage.mkdir(parents=True, exist_ok=False)
    shutil.copytree(ROOT / "rtl", stage / "rtl")
    shutil.copytree(ROOT / "constraints", stage / "constraints")
    provenance = prepare_probe_sources(stage, args.voices,args.independent_osc)
    commands = [
        "set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7",
        "set_option -top_module hardware_probe_top",
        "set_option -verilog_std v2001",
        "set_option -include_path {rtl}",
        "set_option -use_sspi_as_gpio 1",
        "set_option -use_mspi_as_gpio 0",
        "set_option -bit_security 0",
        f"set_option -output_base_name {label}",
    ]
    commands.extend(
        f"add_file -type verilog {{rtl/{file.name}}}"
        for file in sorted((stage / "rtl").glob("*.v"))
    )
    commands.extend(
        (
            "add_file -type cst {constraints/hardware_probe.cst}",
            "add_file -type sdc {constraints/hardware_probe.sdc}",
            "run all",
        )
    )
    (stage / "run.tcl").write_text("\n".join(commands) + "\n", encoding="ascii")

    output = ROOT / "build" / label
    output.mkdir(parents=True, exist_ok=True)
    log_file = output / "gowin.log"
    with log_file.open("w", encoding="utf-8") as log:
        try:
            run = subprocess.run(
                [str(tool), "run.tcl"],
                cwd=stage,
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=args.timeout,
            )
        except subprocess.TimeoutExpired:
            log.write(f"\nERROR: Gowin exceeded {args.timeout} seconds\n")
            run = subprocess.CompletedProcess([str(tool), "run.tcl"], 124)
    if (stage / "impl").exists():
        shutil.copytree(
            stage / "impl", output / "impl",
            dirs_exist_ok=True, copy_function=copy_artifact,
        )
    shutil.copy2(stage / "run.tcl", output / "run.tcl")
    log_text = log_file.read_text(encoding="utf-8", errors="replace")
    errors = [
        line for line in log_text.splitlines()
        if line.startswith("ERROR") or "Syntax error" in line
    ]
    bitstreams = [
        output / file.relative_to(stage)
        for file in stage.rglob("*.fs")
    ]
    timing = timing_result(stage, label)
    complete = run.returncode == 0 and not errors and bool(bitstreams)
    timing_pass = bool(
        timing
        and timing["setup_violations"] == 0
        and timing["hold_violations"] == 0
        and "sys_clk" in timing["frequencies"]
        and "ref_clk" in timing["frequencies"]
    )
    result = {
        "label": label,
        "stage": str(stage),
        "returncode": run.returncode,
        "completed": complete,
        "errors": errors,
        "timing": timing,
        "timing_pass": timing_pass,
        "bitstreams": [str(file.relative_to(ROOT)) for file in bitstreams],
        "bitstreams_sha256": {
            str(file.relative_to(ROOT)): hashlib.sha256(file.read_bytes()).hexdigest()
            for file in bitstreams if file.is_file()
        },
    }
    result.update(provenance)
    (output / "build_result.json").write_text(
        json.dumps(result, indent=2), encoding="utf-8"
    )
    print(log_text[-3000:])
    print(f"Build completed={complete}; timing_pass={timing_pass}; reports: {output}")
    print("Timing:", timing)
    raise SystemExit(0 if complete and timing_pass else 1)


if __name__ == "__main__":
    main()
