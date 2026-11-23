"""Capture the temporary FPGA UART probe and analyze its internal PCM.

The probe streams one signed 16-bit sample per 32 audio frames. This measures
PCM produced on the FPGA; it does not measure the I2S output pins or speaker.
"""

import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import sys
import time

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "build" / "hardware_probe"
DECIMATION = 32
NOMINAL_AUDIO_HZ = 48000
SEGMENT_SAMPLES = 3000  # 2 s at 48 kHz / 32
TRIM_SAMPLES = 300       # Ignore 0.2 s of attack/release at each boundary.
SOURCE = "FPGA UART streamed internal PCM; I2S pad and acoustic output unmeasured"
VOICE_CHOICES = (4, 8, 16, 32)
SAMPLE_LINE = re.compile(rb"[0-9A-F]{4}")
RATE_LINE = re.compile(rb"#RATE ([0-9]{5})")


def capture_serial(port_name, seconds, raw_path):
    """Switch BL616 UART to the FPGA, then preserve exact received bytes."""
    import serial
    from device_link import select_bridge

    raw_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    byte_count = 0
    with raw_path.open("wb") as out, serial.Serial(
        port_name, 115200, timeout=0.2, write_timeout=1
    ) as port:
        port.reset_input_buffer()
        # Same console entry used by device_link/configure_clock; the bridge
        # may still be in SPI mode after a programmer operation.
        select_bridge(port,'uart')
        started=time.monotonic()
        deadline = started + seconds
        while time.monotonic() < deadline:
            chunk = port.read(4096)
            if chunk:
                out.write(chunk)
                byte_count += len(chunk)
    return {"bytes_received": byte_count,
            "elapsed_seconds": round(time.monotonic() - started, 3)}


def parse_records(raw):
    """Decode line records while retaining complete phase boundaries."""
    segments = []
    rates = []
    ignored = []
    malformed_rates = 0
    unframed_samples = 0
    current = None
    records = raw.split(b"\n")
    for line_number, original in enumerate(records, 1):
        if line_number == len(records) and not original:
            continue  # Final separator is not another UART record.
        line = original.rstrip(b"\r")
        if line in (b"#A4", b"#CH"):
            if current is not None:
                current["complete"] = True
            current = {"phase": line[1:].decode("ascii"),
                       "first_line": line_number, "complete": False,
                       "samples": [], "malformed_lines": 0,
                       "malformed_examples": []}
            segments.append(current)
        elif match := RATE_LINE.fullmatch(line):
            rates.append(int(match.group(1)))
        elif line.startswith(b"#RATE"):
            malformed_rates += 1
        elif SAMPLE_LINE.fullmatch(line):
            value = int(line, 16)
            sample = value - 65536 if value >= 32768 else value
            if current is None:
                unframed_samples += 1
            else:
                current["samples"].append(sample)
        elif current is None:
            if line and len(ignored) < 10:
                ignored.append(line.decode("ascii", errors="replace")[:120])
        else:
            current["malformed_lines"] += 1
            if len(current["malformed_examples"]) < 3:
                current["malformed_examples"].append(
                    line.decode("ascii", errors="replace")[:120])
    return segments, rates, ignored, malformed_rates, unframed_samples


def peak_near(expected_hz, spectrum, bins, floor, lower_hz, upper_hz):
    # Midpoint boundaries allocate every FFT bin to at most one expected tone.
    # A fixed +/-3 Hz window overlaps C2/C#2 in the 32-voice configuration.
    area = np.flatnonzero((bins >= lower_hz) & (bins < upper_hz))
    if not len(area):
        raise ValueError(f"No FFT bins around expected {expected_hz:.3f} Hz")
    index = area[np.argmax(spectrum[area])]
    amplitude = float(spectrum[index])
    return {"expected_hz": round(float(expected_hz), 6),
            "measured_hz": round(float(bins[index]), 4),
            "search_lower_hz": round(float(lower_hz), 6),
            "search_upper_hz": round(float(upper_hz), 6),
            "local_peak": bool(0<index<len(spectrum)-1 and spectrum[index]>spectrum[index-1] and spectrum[index]>=spectrum[index+1]),
            "amplitude": round(amplitude, 4),
            "above_background": round(amplitude / max(floor, 1e-9), 2)}


def analyze_phase(segment, expected_hz, sample_rate_hz):
    pcm = np.asarray(segment["samples"], dtype=np.int32)
    stable = pcm[TRIM_SAMPLES:-TRIM_SAMPLES].astype(np.float64)
    nfft = 131072
    spectrum = np.abs(np.fft.rfft(stable * np.hanning(len(stable)), n=nfft))
    bins = np.fft.rfftfreq(nfft, d=1 / sample_rate_hz)
    audible = spectrum[(bins >= 50) & (bins <= 700)]
    floor = float(np.median(audible))
    dominant = float(np.max(audible))
    ordered = sorted(expected_hz)
    windows = {}
    for index, frequency in enumerate(ordered):
        lower = max(frequency - 3, (ordered[index - 1] + frequency) / 2) if index else frequency - 3
        upper = min(frequency + 3, (frequency + ordered[index + 1]) / 2) if index + 1 < len(ordered) else frequency + 3
        windows[frequency] = (lower, upper)
    peaks = [peak_near(frequency, spectrum, bins, floor, *windows[frequency])
             for frequency in expected_hz]
    errors = []
    phase = segment["phase"]
    if len(pcm) != SEGMENT_SAMPLES:
        errors.append(f"{phase} complete segment has {len(pcm)} samples; expected exactly {SEGMENT_SAMPLES}")
    if int(pcm.min()) >= 0 or int(pcm.max()) <= 0:
        errors.append(f"{phase} PCM does not cross zero")
    for peak in peaks:
        if not peak['local_peak'] or abs(peak["measured_hz"] - peak["expected_hz"]) >= 1.0:
            errors.append(f"{phase} missing expected {peak['expected_hz']:.3f} Hz tone")
        elif peak["amplitude"] < max(floor * 20, dominant * 0.03):
            errors.append(f"{phase} weak {peak['expected_hz']:.3f} Hz tone")
    return {"samples": len(pcm), "stable_samples": len(stable),
            "min_pcm": int(pcm.min()), "max_pcm": int(pcm.max()),
            "rms_pcm": round(float(np.sqrt(np.mean(stable ** 2))), 3),
            "peaks": peaks}, errors


def expected_keys(voices):
    if voices not in VOICE_CHOICES:
        raise ValueError("voices must be 4, 8, 16 or 32")
    return {"A4": [5], "CH": [0, 2, 4, 6] if voices == 4 else list(range(voices))}


def analyze_capture(raw, source_name, voices=4, independent=False):
    key_ids = expected_keys(voices)
    segments, rates, ignored, malformed_rates, unframed = parse_records(raw)
    table = json.loads((ROOT / "docs" / "tables.json").read_text(encoding="utf-8"))
    notes = {item["key"]: item["frequency"] for item in table["notes"]}
    reference_hz = int(round(float(np.median(rates)))) if rates else None
    analysis_hz = (reference_hz or NOMINAL_AUDIO_HZ) / DECIMATION
    result = {
        "source": SOURCE,
        "voices": voices,
        "oscillator_count": voices*(2 if independent else 1),
        "independent_osc": independent,
        "expected_key_ids": key_ids,
        "raw_file": str(source_name),
        "raw_bytes": len(raw),
        "status": "fail",
        "reference_sample_rate_hz": reference_hz,
        "rate_readings_hz": rates,
        "decimated_analysis_rate_hz": analysis_hz,
        "frequency_basis": "27 MHz reference reported by FPGA" if rates else "nominal 48 kHz (unmeasured)",
        "ignored_lines": ignored,
        "malformed_rate_lines": malformed_rates,
        "unframed_samples": unframed,
        "segments": [{"phase": item["phase"], "complete": item["complete"],
                      "samples": len(item["samples"]), "first_line": item["first_line"],
                      "malformed_lines": item["malformed_lines"]}
                     for item in segments],
        "phase_results": {},
        "errors": [],
    }
    errors = result["errors"]
    if malformed_rates:
        errors.append(f"{malformed_rates} malformed #RATE records")
    # The first marked segment can be truncated while the USB UART bridge is
    # switching over. Every subsequent completed segment must be lossless.
    for segment in segments[1:]:
        if not segment["complete"]:
            continue
        count = len(segment["samples"])
        if count != SEGMENT_SAMPLES:
            errors.append(
                f"{segment['phase']} segment at line {segment['first_line']} has "
                f"{count} samples; expected exactly {SEGMENT_SAMPLES}")
        if segment["malformed_lines"]:
            errors.append(
                f"{segment['phase']} segment at line {segment['first_line']} has "
                f"{segment['malformed_lines']} malformed UART lines")
    if reference_hz is not None and not (47500 <= reference_hz <= 48500):
        errors.append(f"27 MHz reference gives {reference_hz} samples/s, outside 48 kHz +/- 500")
    if rates and max(rates) - min(rates) > 100:
        errors.append("27 MHz reference rate readings vary by more than 100 samples/s")
    for phase, keys in key_ids.items():
        complete = [item for item in segments if item["phase"] == phase and item["complete"]]
        if not complete:
            errors.append(f"No complete {phase} segment")
            continue
        segment = max(complete, key=lambda item: len(item["samples"]))
        if segment["malformed_lines"]:
            errors.append(
                f"{phase} complete segment has {segment['malformed_lines']} malformed UART lines: "
                f"{segment['malformed_examples']}")
        if len(segment["samples"]) <= 2 * TRIM_SAMPLES:
            errors.append(f"{phase} complete segment too short for spectral analysis")
            continue
        phase_result, phase_errors = analyze_phase(
            segment, [notes[key]*factor for factor in ([1,67456/65536] if independent else [1]) for key in keys], analysis_hz)
        phase_result["key_ids"] = keys
        result["phase_results"][phase] = phase_result
        errors.extend(phase_errors)
    if not rates:
        errors.append("No #RATE record from the independent 27 MHz reference")
    result["status"] = "pass" if not errors else "fail"
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", help="BL616/FPGA UART port for live capture")
    parser.add_argument("--seconds", type=float, default=10.0)
    parser.add_argument("--voices", type=int, choices=VOICE_CHOICES, default=4,
                        help="Programmed diagnostic voice count (default: 4)")
    parser.add_argument("--independent-osc",action="store_true",help="Analyze the independently enveloped dual DDS probe")
    parser.add_argument("--analyze-existing", type=Path,
                        help="Analyze an existing raw UART capture without opening hardware")
    args = parser.parse_args()
    if args.analyze_existing:
        raw_path = args.analyze_existing.resolve()
        capture_details = None
    else:
        if not args.port:
            parser.error("--port is required for live capture")
        if args.seconds <= 0:
            parser.error("--seconds must be positive")
        output_dir = OUTPUT_DIR if args.voices == 4 else OUTPUT_DIR.parent / f"hardware_probe_{args.voices}"
        if args.independent_osc:output_dir=output_dir.with_name(output_dir.name+"_independent")
        output_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        raw_path = output_dir / f"uart_capture_{stamp}.raw"
        raw_path.touch()
        try:
            capture_details = capture_serial(args.port, args.seconds, raw_path)
        except Exception as exc:
            capture_details = {"capture_error": str(exc)}
    try:
        result = analyze_capture(raw_path.read_bytes(), raw_path, voices=args.voices,independent=args.independent_osc)
    except Exception as exc:
        result = {"status": "fail", "source": SOURCE,
                  "voices": args.voices, "expected_key_ids": expected_keys(args.voices),
                  "raw_file": str(raw_path), "errors": [f"Analysis error: {exc}"]}
    if capture_details is not None:
        result["capture"] = {"port": args.port,
                             "seconds_requested": args.seconds, **capture_details}
        if "capture_error" in capture_details:
            result["errors"].insert(0, "UART capture failed: " + capture_details["capture_error"])
            result["status"] = "fail"
    output = raw_path.with_suffix(".json")
    output.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"{result['status'].upper()} {output}")
    for error in result["errors"]:
        print(error, file=sys.stderr)
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
