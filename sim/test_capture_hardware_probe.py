"""Offline contract checks for the hardware probe UART capture analyzer."""

import json
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "capture_hardware_probe.py"
SCRATCH = Path(tempfile.gettempdir())
FS = 1500
MIDI_NOTES = [60, 62, 64, 65, 67, 69, 71, 72] + list(range(36, 60))
FREQUENCIES = [440.0 * 2 ** ((note - 69) / 12) for note in MIDI_NOTES]


def tone(notes):
    t = np.arange(3000, dtype=np.float64) / FS
    wave = sum(np.sin(2 * np.pi * frequency * t) for frequency in notes)
    return np.rint(wave * (11000 / len(notes))).astype(np.int16)


def record(samples):
    return b"".join(f"{int(sample) & 0xFFFF:04X}\n".encode("ascii") for sample in samples)


class CaptureAnalyzerTests(unittest.TestCase):
    def run_fixture(self, data, voices=None, independent=False):
        SCRATCH.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            raw = Path(directory) / "fixture.raw"
            raw.write_bytes(data)
            command = [sys.executable, "-X", "utf8", str(SCRIPT), "--analyze-existing", str(raw)]
            if voices is not None:
                command += ["--voices", str(voices)]
            if independent:command += ['--independent-osc']
            process = subprocess.run(command, capture_output=True, text=True)
            result_path = raw.with_suffix(".json")
            self.assertTrue(result_path.exists(), process.stderr)
            output = json.loads(result_path.read_text(encoding="utf-8"))
            return process, output

    @staticmethod
    def fixture(voices, omitted=None):
        keys = [0, 2, 4, 6] if voices == 4 else list(range(voices))
        if omitted is not None:
            keys.remove(omitted)
        return (b"#RATE 48000\n#A4\n" + record(tone([440.0]))
                + b"#CH\n" + record(tone([FREQUENCIES[key] for key in keys]))
                + b"#A4\n")

    def test_default_four_voices_records_configuration_and_exact_key_ids(self):
        process, output = self.run_fixture(self.fixture(4))
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(output.get("voices"), 4)
        self.assertEqual(output.get("expected_key_ids"), {"A4": [5], "CH": [0, 2, 4, 6]})

    def test_explicit_four_eight_sixteen_and_thirtytwo_voice_chords_pass(self):
        for voices in (4, 8, 16, 32):
            with self.subTest(voices=voices):
                process, output = self.run_fixture(self.fixture(voices), voices=voices)
                self.assertEqual(process.returncode, 0, process.stderr)
                self.assertEqual(output["voices"], voices)
                self.assertEqual(output["expected_key_ids"]["CH"],
                                 [0, 2, 4, 6] if voices == 4 else list(range(voices)))
                peaks = output["phase_results"]["CH"]["peaks"]
                self.assertEqual(len(peaks), voices)
                self.assertEqual(len({peak["measured_hz"] for peak in peaks}), voices)
                ordered = sorted(peaks, key=lambda peak: peak["expected_hz"])
                for left, right in zip(ordered, ordered[1:]):
                    self.assertLessEqual(left["search_upper_hz"], right["search_lower_hz"])

    def test_any_single_missing_voice_fails_thirtytwo_voice_acceptance(self):
        # A correct 31-tone spectrum must never stand in for all 32 oscillators.
        # In particular C2=65.406 Hz and C#2=69.296 Hz are close neighbours.
        for omitted in range(32):
            with self.subTest(omitted=omitted):
                process, output = self.run_fixture(self.fixture(32, omitted), voices=32)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(output["status"], "fail")
                self.assertEqual(output["voices"], 32)
                self.assertTrue(any(f"{FREQUENCIES[omitted]:.3f}" in error
                                    for error in output["errors"]), output["errors"])

    def test_sixtyfour_tones_and_each_missing_oscillator(self):
        frequencies=FREQUENCIES+[f*67456/65536 for f in FREQUENCIES]
        a4=[440,440*67456/65536]
        def fixture(omitted=None):
            chord=[f for i,f in enumerate(frequencies) if i!=omitted]
            return b'#RATE 48000\n#A4\n'+record(tone(a4))+b'#CH\n'+record(tone(chord))+b'#A4\n'
        process,result=self.run_fixture(fixture(),voices=32,independent=True)
        self.assertEqual(process.returncode,0,process.stderr)
        self.assertEqual(result['oscillator_count'],64)
        self.assertEqual(len(result['phase_results']['CH']['peaks']),64)
        for omitted in range(64):
            with self.subTest(oscillator=omitted):
                process,result=self.run_fixture(fixture(omitted),voices=32,independent=True)
                self.assertNotEqual(process.returncode,0,'missing oscillator incorrectly accepted')

    def test_thirtytwo_voice_capture_keeps_loss_and_rate_checks(self):
        data = self.fixture(32).replace(b"#RATE 48000", b"#RATE 46000")
        process, output = self.run_fixture(data, voices=32)
        self.assertNotEqual(process.returncode, 0)
        self.assertTrue(any("outside 48 kHz" in error for error in output["errors"]))
        data = self.fixture(32)
        marker = data.index(b"#CH\n") + 4
        process, output = self.run_fixture(data[:marker] + data[marker + 5:], voices=32)
        self.assertNotEqual(process.returncode, 0)
        self.assertTrue(any("2999" in error for error in output["errors"]))

    def test_capture_defaults_use_separate_voice_output_directories_without_hardware(self):
        spec = importlib.util.spec_from_file_location("hardware_probe_analyzer", SCRIPT)
        analyzer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(analyzer)
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            for voices in (4, 8, 16, 32):
                def fake_capture(port, seconds, raw_path):
                    raw_path.write_bytes(self.fixture(voices))
                    return {"bytes_received": raw_path.stat().st_size, "elapsed_seconds": seconds}
                with patch.object(analyzer, "OUTPUT_DIR", Path(directory) / "hardware_probe"), \
                        patch.object(analyzer, "capture_serial", fake_capture), \
                        patch.object(sys, "argv", [str(SCRIPT), "--port", "TEST-PORT", "--voices", str(voices)]), \
                        contextlib.redirect_stdout(io.StringIO()):
                    try:
                        result = analyzer.main()
                    except SystemExit as exc:
                        self.fail(f"capture CLI must accept the explicit voice configuration: {exc}")
                    self.assertEqual(result, 0)
                expected = Path(directory) / ("hardware_probe" if voices == 4 else f"hardware_probe_{voices}")
                captures = list(expected.glob("uart_capture_*.json"))
                self.assertEqual(len(captures), 1)
                self.assertEqual(json.loads(captures[0].read_text(encoding="utf-8"))["voices"], voices)

    def test_completed_a4_and_chord_segments_pass_spectral_checks(self):
        # If the parser swaps signedness or analyzes across phase markers,
        # the output frequencies or min/max assertions must fail.
        a4 = tone([440.0])
        chord = tone([261.6255653, 329.6275569, 391.9954360, 493.8833013])
        data = (b"choose uart\r\n#A4\n" + record(a4[:1500]) + b"#RATE 48000\n"
                + record(a4[1500:]) + b"#CH\n" + record(chord) + b"#A4\n")
        process, output = self.run_fixture(data)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(output["status"], "pass")
        self.assertEqual(output["source"], "FPGA UART streamed internal PCM; I2S pad and acoustic output unmeasured")
        self.assertEqual(output["reference_sample_rate_hz"], 48000)
        self.assertEqual(output["phase_results"]["A4"]["samples"], 3000)
        self.assertEqual(output["phase_results"]["CH"]["samples"], 3000)
        self.assertLess(output["phase_results"]["A4"]["min_pcm"], 0)
        self.assertGreater(output["phase_results"]["A4"]["max_pcm"], 0)
        self.assertEqual(len(output["phase_results"]["CH"]["peaks"]), 4)
        for peak in output["phase_results"]["A4"]["peaks"] + output["phase_results"]["CH"]["peaks"]:
            self.assertLess(abs(peak["measured_hz"] - peak["expected_hz"]), 1)

    def test_no_complete_chord_segment_is_reported_as_failure(self):
        data = b"#A4\n" + record(tone([440.0])) + b"#CH\n"
        process, output = self.run_fixture(data)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(output["status"], "fail")
        self.assertIn("CH", output["errors"][0])
        self.assertIsNone(output["reference_sample_rate_hz"])

    def test_dropped_pcm_record_fails_even_when_tone_is_detectable(self):
        a4 = tone([440.0])
        chord = tone([261.6255653, 329.6275569, 391.9954360, 493.8833013])
        data = (b"#RATE 48000\n#A4\n" + record(a4[:1000]) + record(a4[1001:])
                + b"#CH\n" + record(chord) + b"#A4\n")
        process, output = self.run_fixture(data)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(output["status"], "fail")
        self.assertTrue(any("2999" in error for error in output["errors"]))

    def test_malformed_record_inside_complete_phase_fails(self):
        a4 = tone([440.0])
        chord = tone([261.6255653, 329.6275569, 391.9954360, 493.8833013])
        data = (b"#RATE 48000\n#A4\n" + record(a4[:1000]) + b"BROKEN\n"
                + record(a4[1000:]) + b"#CH\n" + record(chord) + b"#A4\n")
        process, output = self.run_fixture(data)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(output["status"], "fail")
        self.assertTrue(any("malformed" in error.lower() for error in output["errors"]))

    def test_missing_independent_rate_record_fails(self):
        a4 = tone([440.0])
        chord = tone([261.6255653, 329.6275569, 391.9954360, 493.8833013])
        data = b"#A4\n" + record(a4) + b"#CH\n" + record(chord) + b"#A4\n"
        process, output = self.run_fixture(data)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(output["status"], "fail")
        self.assertTrue(any("#RATE" in error for error in output["errors"]))

    def test_later_dropped_segment_fails_even_with_other_good_segments(self):
        a4 = tone([440.0])
        chord = tone([261.6255653, 329.6275569, 391.9954360, 493.8833013])
        data = (b"#RATE 48000\n#A4\n" + record(a4) + b"#CH\n"
                + record(chord) + b"#A4\n" + record(a4[:-1])
                + b"#CH\n" + record(chord) + b"#A4\n")
        process, output = self.run_fixture(data)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(output["status"], "fail")
        self.assertTrue(any("2999" in error for error in output["errors"]))


if __name__ == "__main__":
    unittest.main()

