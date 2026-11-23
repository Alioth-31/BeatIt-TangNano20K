"""Validate timestamped digital CSV from the Nano 20K's external I2S pads.

Standard library only. PCM is exported only when the entire capture passes.
Incomplete first/last slots are ignored; corrupt internal slots are failures.
"""
import argparse
import csv
import json
import math
from pathlib import Path
import statistics
import sys


class EdgeStatistics:
    """Bounded timing statistics; millions of raw digital samples need no list."""
    def __init__(self):
        self.count = 0
        self.first = self.last = None
        self.minimum = math.inf
        self.maximum = 0.0
        self.periods = []

    def add(self, time):
        if self.last is not None:
            period = time - self.last
            self.minimum = min(self.minimum, period)
            self.maximum = max(self.maximum, period)
            if len(self.periods) < 4096:
                self.periods.append(period)
        else:
            self.first = time
        self.last = time
        self.count += 1

    def frequency(self):
        if self.count < 2 or self.last <= self.first:
            return None
        return (self.count - 1) / (self.last - self.first)

    def irregular(self):
        if not self.periods:
            return False
        median = statistics.median(self.periods)
        # At 20 MHz, a 3.072 MHz cycle spans 6 or 7 capture samples.
        # A missing whole BCLK pulse creates a ~2x inter-edge interval.
        return self.minimum < median * 0.6 or self.maximum > median * 1.5


def analyze(source, args):
    errors = []
    error_count = 0

    def fail(message):
        nonlocal error_count
        error_count += 1
        if len(errors) < 100:
            errors.append(message)

    rising, falling = EdgeStatistics(), EdgeStatistics()
    ws_stats = [EdgeStatistics(), EdgeStatistics()]
    frames = []
    previous = None
    first_time = last_time = None
    key_edge = None
    ws_transition_waiting = False
    aligned = False
    slot_ws = None
    slot_bits = 0
    slot_word = 0
    slot_start = pcm_complete = None
    pending_left = None
    rows = 0
    half_periods = []
    half_min, half_max = math.inf, 0.0
    last_clock_edge = None
    columns = [args.time_column, args.bclk_column, args.ws_column, args.sd_column]
    if args.key_column:
        columns.append(args.key_column)

    with source.open("r", encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream, delimiter=args.delimiter)
        headers = reader.fieldnames or []
        missing = [column for column in columns if column not in headers]
        if missing:
            raise ValueError("Missing CSV columns: " + ", ".join(missing))
        if len(set(headers)) != len(headers):
            raise ValueError("Duplicate CSV header names are ambiguous")
        for line, raw in enumerate(reader, start=2):
            try:
                time = float(raw[args.time_column]) * args.time_scale
                if not math.isfinite(time):
                    raise ValueError("non-finite timestamp")
                values = []
                for column in columns[1:]:
                    value = raw[column].strip()
                    if value not in ("0", "1"):
                        raise ValueError(f"invalid logic value {value!r} in {column}")
                    values.append(int(value))
            except (ValueError, TypeError, AttributeError, KeyError) as error:
                fail(f"CSV line {line}: {error}")
                break
            bclk, ws, sd = values[:3]
            key = values[3] if args.key_column else None
            rows += 1
            if first_time is None:
                first_time = time
            last_time = time
            if previous is None:
                previous = (time, bclk, ws, sd, key)
                continue
            old_time, old_bclk, old_ws, old_sd, old_key = previous
            if time <= old_time:
                fail(f"CSV line {line}: timestamps must be strictly increasing")
                break
            if key_edge is None and args.key_column and old_key == 1 and key == 0:
                key_edge = time
            if ws != old_ws:
                if ws_transition_waiting:
                    fail(f"CSV line {line}: WS toggled more than once between BCLK sampling edges")
                ws_transition_waiting = True
            if (sd != old_sd or ws != old_ws) and bclk == 1:
                edge = "at rising BCLK" if old_bclk == 0 else "while BCLK is high"
                fail(f"CSV line {line}: SD/WS changed {edge}; no safe sampling setup")
            if bclk != old_bclk:
                if last_clock_edge is not None:
                    duration = time - last_clock_edge
                    half_min, half_max = min(half_min, duration), max(half_max, duration)
                    if len(half_periods) < 4096:
                        half_periods.append(duration)
                last_clock_edge = time
                if bclk == 0:
                    falling.add(time)
                else:
                    rising.add(time)
                    ws_transition_waiting = False
                    # The WS-change edge is the previous slot's final bit.
                    # The next rising edge carries the new channel's MSB.
                    if slot_ws is None:
                        slot_ws = ws
                    if ws != slot_ws:
                        ws_stats[ws].add(time)
                        if aligned:
                            width = slot_bits + 1
                            if width != 32:
                                fail(f"At {time:.12g}s: I2S slot has {width} bits, expected 32")
                                pending_left = None
                            else:
                                word = (slot_word << 1) | sd
                                if word & 0xffff:
                                    fail(f"At {time:.12g}s: nonzero 16-bit I2S padding")
                                sample = word >> 16
                                if sample & 0x8000:
                                    sample -= 0x10000
                                slot = dict(pcm=sample, start=slot_start,
                                            pcm_complete=pcm_complete, complete=time)
                                if slot_ws == 0:
                                    pending_left = slot
                                elif pending_left is not None:
                                    if pending_left["pcm"] != sample:
                                        fail(f"At {time:.12g}s: left/right PCM mismatch "
                                             f"({pending_left['pcm']} / {sample})")
                                    frames.append(dict(**pending_left, stereo_complete=time))
                                    pending_left = None
                        aligned = True
                        slot_ws = ws
                        slot_start = time
                        slot_bits = slot_word = 0
                        pcm_complete = None
                    elif aligned:
                        slot_word = ((slot_word << 1) | sd) & 0xffffffff
                        slot_bits += 1
                        if slot_bits == 16:
                            pcm_complete = time
                        if slot_bits == 32:
                            fail(f"At {time:.12g}s: missing WS boundary after 32-bit slot")
            previous = (time, bclk, ws, sd, key)

    if rising.irregular() or falling.irregular():
        fail("BCLK inter-edge gap/glitch indicates missing, extra, or dropped clock samples")
    if half_periods:
        median = statistics.median(half_periods)
        # Quantization gives 150/200 ns half cycles at 20 MHz. Reject runt
        # pulses and long held levels; do not silently interpolate edges.
        if half_min < median * 0.4 or half_max > median * 1.8:
            fail("BCLK half-cycle glitch/dropout or unsuitable capture resolution")
        if last_time - last_clock_edge > median * 2:
            fail("BCLK stopped before the captured timeline ended; this is not merely a partial last frame")
    for channel, stats in enumerate(ws_stats):
        if stats.irregular():
            fail(f"WS channel {channel} frame period is irregular")
    bclk_hz = rising.frequency()
    sample_hz = ws_stats[0].frequency()
    right_hz = ws_stats[1].frequency()
    expected_bclk = args.expected_sample_rate * 64
    for label, actual, expected in (("BCLK", bclk_hz, expected_bclk),
                                    ("LRCLK", sample_hz, args.expected_sample_rate),
                                    ("right WS cycle", right_hz, args.expected_sample_rate)):
        if actual is None:
            fail(f"{label} rate unavailable: too few observed edges")
        elif abs(actual / expected - 1) * 100 > args.rate_tolerance_percent:
            fail(f"{label} rate {actual:.6f} Hz differs from expected {expected:.6f} Hz "
                 f"by more than {args.rate_tolerance_percent:g}%")
    if len(frames) < args.min_frames:
        fail(f"Only {len(frames)} complete stereo frames; at least {args.min_frames} required")
    latency = None
    if args.key_column:
        if key_edge is None:
            fail("No raw active-low key edge (1 -> 0) observed; latency unavailable")
        else:
            baseline = [frame for frame in frames if frame["stereo_complete"] < key_edge]
            if len(baseline) < 3:
                fail("Latency requires at least three complete silent stereo frames before the key edge")
            if any(frame["pcm"] != 0 and frame["start"] < key_edge for frame in frames):
                fail("Audio was already nonzero before the raw key edge; latency cannot be attributed to it")
            response = next((frame for frame in frames
                             if frame["start"] >= key_edge and frame["pcm"] != 0), None)
            if response is None:
                fail("No nonzero PCM response after the raw key edge; latency unavailable")
            else:
                pcm_ms = (response["pcm_complete"] - key_edge) * 1000
                slot_ms = (response["complete"] - key_edge) * 1000
                stereo_ms = (response["stereo_complete"] - key_edge) * 1000
                latency = dict(raw_key_edge_time_s=key_edge,
                               first_nonzero_pcm_complete_time_s=response["pcm_complete"],
                               input_to_first_nonzero_pcm_ms=pcm_ms,
                               input_to_complete_left_slot_ms=slot_ms,
                               input_to_validated_stereo_frame_ms=stereo_ms,
                               digital_path_limit_ms=args.max_i2s_latency_ms,
                               digital_path_within_limit=slot_ms <= args.max_i2s_latency_ms,
                               note="Raw first key edge includes captured switch bounce; "
                                    "32-bit left-slot completion is a conservative digital I2S endpoint. "
                                    "MAX98357A and speaker/acoustic latency are not measured.")
                if slot_ms > args.max_i2s_latency_ms:
                    fail(f"Digital I2S latency {slot_ms:.6f} ms exceeds {args.max_i2s_latency_ms:g} ms")
    if args.require_nonzero and not any(frame["pcm"] for frame in frames):
        fail("Capture contains no nonzero PCM; audible test stimulus was required")
    report = dict(status="fail" if error_count else "pass", source=str(source.resolve()),
                  capture_source="User-supplied digital I2S CSV; instrument/hardware origin must be verified separately",
                  csv_rows=rows, capture_duration_s=(last_time - first_time) if rows else 0,
                  frames=len(frames), measured_bclk_hz=bclk_hz, measured_lrclk_hz=sample_hz,
                  measured_right_ws_cycle_hz=right_hz, expected_sample_rate_hz=args.expected_sample_rate,
                  rate_tolerance_percent=args.rate_tolerance_percent,
                  capture_sample_rate_hz=args.capture_sample_rate,
                  timestamp_quantization_bound_s=(1 / args.capture_sample_rate) if args.capture_sample_rate else None,
                  decoded_pcm_min=min((frame["pcm"] for frame in frames), default=None),
                  decoded_pcm_max=max((frame["pcm"] for frame in frames), default=None),
                  discarded_boundary_slots="Initial unaligned slot and final incomplete stereo frame",
                  latency=latency, speaker_latency_measured=False,
                  errors=errors, error_count=error_count, pcm_written=False)
    return report, [frame["pcm"] for frame in frames]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="Raw digital samples or all-channel edge-state CSV")
    parser.add_argument("--time-column", default="Time [s]")
    parser.add_argument("--bclk-column", default="BCLK")
    parser.add_argument("--ws-column", default="WS")
    parser.add_argument("--sd-column", default="SD")
    parser.add_argument("--key-column", help="Optional raw active-low key, captured on the same timeline")
    parser.add_argument("--time-scale", type=float, default=1.0, help="CSV time unit to seconds, e.g. 1e-6 for microseconds")
    parser.add_argument("--delimiter", default=",")
    parser.add_argument("--capture-sample-rate", type=float, help="Logic analyzer sample rate in Hz; use >=20000000")
    parser.add_argument("--expected-sample-rate", type=float, default=48000)
    parser.add_argument("--rate-tolerance-percent", type=float, default=1.0)
    parser.add_argument("--min-frames", type=int, default=3)
    parser.add_argument("--max-i2s-latency-ms", type=float, default=10.0)
    parser.add_argument("--require-nonzero", action="store_true", help="Fail an entirely silent capture")
    parser.add_argument("--report", type=Path, help="Default: CAPTURE.i2s.json")
    parser.add_argument("--pcm-output", type=Path, help="Default: CAPTURE.pcm.txt; one signed sample per line for FFT")
    args = parser.parse_args()
    for name in ("time_scale", "expected_sample_rate", "rate_tolerance_percent", "max_i2s_latency_ms"):
        value = getattr(args, name)
        if not math.isfinite(value) or value <= 0:
            parser.error(f"--{name.replace('_', '-')} must be positive and finite")
    if args.min_frames < 3:
        parser.error("--min-frames must be at least 3")
    if len(args.delimiter) != 1:
        parser.error("--delimiter must be one character")
    if args.capture_sample_rate is not None and (not math.isfinite(args.capture_sample_rate) or args.capture_sample_rate < 20000000):
        parser.error("--capture-sample-rate must be at least 20000000 Hz")
    report_path = args.report or args.capture.with_suffix(".i2s.json")
    pcm_path = args.pcm_output or args.capture.with_suffix(".pcm.txt")
    if len({args.capture.resolve(), report_path.resolve(), pcm_path.resolve()}) != 3:
        parser.error("Input capture, report, and PCM output must be different files")
    try:
        report, pcm = analyze(args.capture, args)
    except (OSError, ValueError, csv.Error) as error:
        report = dict(status="fail", source=str(args.capture.resolve()), errors=[str(error)],
                      error_count=1, pcm_written=False, speaker_latency_measured=False)
        pcm = []
    if report["status"] == "pass":
        pcm_path.parent.mkdir(parents=True, exist_ok=True)
        pcm_path.write_text("".join(f"{sample}\n" for sample in pcm), encoding="ascii")
        report["pcm_written"] = True
        report["pcm_output"] = str(pcm_path.resolve())
    elif pcm_path.exists():
        report["existing_pcm_output_untouched"] = str(pcm_path.resolve())
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    if report["status"] == "pass":
        print(f"PASS {report['frames']} stereo frames; LRCLK={report['measured_lrclk_hz']:.6f} Hz; "
              f"BCLK={report['measured_bclk_hz']:.6f} Hz")
        if report["latency"]:
            print(f"Raw key -> complete left I2S slot: {report['latency']['input_to_complete_left_slot_ms']:.6f} ms; "
                  "speaker latency unmeasured")
    else:
        for error in report["errors"]:
            print("FAIL " + error, file=sys.stderr)
    print(f"Report: {report_path.resolve()}")
    raise SystemExit(0 if report["status"] == "pass" else 1)


if __name__ == "__main__":
    main()
