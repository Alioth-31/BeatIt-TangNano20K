"""Black-box tests using an independent standard-I2S wire fixture."""
import csv
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "analyze_i2s_capture.py"
SCRATCH = Path(tempfile.gettempdir())
BCLK = 3072000


def wire_capture(samples, right=None, frequency=BCLK, key_bit=None):
    """One delay bit, sixteen MSB-first PCM bits, fifteen trailing zeros.

    A new WS level starts at the delay bit. The preceding channel's final
    padding bit overlaps that boundary, as in Philips I2S. This transmitter
    fixture never imports the analyzer or its helpers.
    """
    right = samples if right is None else right
    bits = []
    for left, other in zip(samples, right):
        for channel, value in ((0, left), (1, other)):
            payload = [(value & (1 << shift)) != 0 for shift in range(15, -1, -1)]
            bits.extend((channel, int(bit)) for bit in [0] + payload + [0] * 15)
    rows = [[0.0, 0, 0, 0, 1]]
    period = 1.0 / frequency
    for index, (ws, sd) in enumerate(bits):
        key = int(key_bit is None or index < key_bit)
        rows.append([(index + 1) * period, 0, ws, sd, key])
        rows.append([(index + 1.5) * period, 1, ws, sd, key])
    return rows


class I2SCaptureTests(unittest.TestCase):
    def analyze(self, rows, extra=(), headers=None):
        SCRATCH.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            source = Path(directory) / "wire.csv"
            with source.open("w", newline="", encoding="utf-8") as stream:
                writer = csv.writer(stream)
                writer.writerow(headers or ["Time [s]", "BCLK", "WS", "SD", "KEY_N"])
                writer.writerows(rows)
            process = subprocess.run(
                [sys.executable, "-X", "utf8", str(SCRIPT), str(source), *extra],
                capture_output=True, text=True,
            )
            report_path = source.with_suffix(".i2s.json")
            self.assertTrue(report_path.exists(), process.stderr)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            pcm_path = source.with_suffix(".pcm.txt")
            pcm = [int(line) for line in pcm_path.read_text().splitlines()] if pcm_path.exists() else None
            return process, report, pcm

    def assert_rejected(self, rows, reason, extra=()):
        process, report, pcm = self.analyze(rows, extra)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(report["status"], "fail")
        self.assertTrue(any(reason.lower() in error.lower() for error in report["errors"]), report)
        self.assertIsNone(pcm, "A failed capture must not export PCM that appears validated")

    def test_signed_pcm_one_bit_delay_and_padding(self):
        # A missing I2S delay, reversed bit order, unsigned conversion, or
        # wrong frame pairing changes these hand-picked full-range samples.
        values = [0, 32767, -32768, -28108, 4660, -1, 1, 0, 42]
        process, report, pcm = self.analyze(wire_capture(values))
        self.assertEqual(process.returncode, 0, process.stderr + process.stdout)
        self.assertEqual(report["status"], "pass")
        self.assertEqual(pcm, [32767, -32768, -28108, 4660, -1, 1, 0])
        self.assertEqual(report["frames"], 7)
        self.assertAlmostEqual(report["measured_bclk_hz"], 3072000, places=3)
        self.assertAlmostEqual(report["measured_lrclk_hz"], 48000, places=3)
        self.assertFalse(report["speaker_latency_measured"])

    def test_truncated_beginning_and_tail_realign_without_inventing_frames(self):
        # Starting halfway into a slot must wait for a real WS boundary;
        # incomplete final stereo audio must not leak into PCM export.
        rows = wire_capture([11, 22, 33, 44, 55, 66, 77, 88, 99])
        process, report, pcm = self.analyze(rows[27:-179])
        self.assertEqual(process.returncode, 0, process.stderr + process.stdout)
        self.assertEqual(pcm, [22, 33, 44, 55, 66, 77])
        self.assertEqual(report["frames"], 6)

    def test_sampled_20mhz_csv_remains_valid_with_timestamp_quantization(self):
        # Real logic-analyzer samples quantize an asynchronous BCLK edge.
        edges = wire_capture([0, -32768, 32767, -1, 0, 42, 90, 0])
        rows = []
        cursor = 0
        for index in range(int(edges[-1][0] * 20000000) + 1):
            time = index / 20000000
            while cursor + 1 < len(edges) and edges[cursor + 1][0] <= time:
                cursor += 1
            rows.append([time, *edges[cursor][1:]])
        process, report, pcm = self.analyze(rows, ["--capture-sample-rate", "20000000"])
        self.assertEqual(process.returncode, 0, process.stderr + process.stdout)
        self.assertEqual(pcm, [-32768, 32767, -1, 0, 42, 90])
        self.assertLess(abs(report["measured_bclk_hz"] - 3072000), 1000)

    def test_nonzero_padding_is_rejected(self):
        rows = wire_capture([0, 1, 2, 3, 4, 5, 6])
        # First observed complete left slot, data bit 23 (padding).
        rows[1 + 2 * (64 + 23)][3] = 1
        rows[2 + 2 * (64 + 23)][3] = 1
        self.assert_rejected(rows, "padding")

    def test_left_and_right_mismatch_is_rejected(self):
        self.assert_rejected(wire_capture([0, 10, 20, 30, 40, 50], [0, 11, 20, 30, 40, 50]), "left/right")

    def test_early_ws_transition_is_rejected(self):
        rows = wire_capture([0, 10, 20, 30, 40, 50])
        for row in rows[1 + 2 * (64 + 18):1 + 2 * (64 + 32)]:
            row[2] = 1
        self.assert_rejected(rows, "slot")

    def test_ws_glitch_between_sampling_edges_is_not_hidden_by_pcm_decode(self):
        rows = wire_capture([0, 10, 20, 30, 40, 50, 60])
        position = 1 + 2 * (64 + 20)
        falling = rows[position]
        rows[position + 1:position + 1] = [
            [falling[0] + 0.1 / BCLK, 0, 1, falling[3], 1],
            [falling[0] + 0.2 / BCLK, 0, 0, falling[3], 1],
        ]
        self.assert_rejected(rows, "WS")

    def test_missing_clock_pulse_is_rejected(self):
        rows = wire_capture([0, 10, 20, 30, 40, 50, 60])
        rows[2 + 2 * (64 + 9)][1] = 0
        self.assert_rejected(rows, "BCLK")

    def test_clock_stops_at_capture_tail_is_not_excused_as_partial_frame(self):
        rows = wire_capture([0, 10, 20, 30, 40, 50, 60])
        rows.append([rows[-1][0] + 0.001, *rows[-1][1:]])
        self.assert_rejected(rows, "BCLK")

    def test_data_changing_at_rising_clock_is_rejected(self):
        rows = wire_capture([0, 10, 20, 30, 40, 50])
        rows[2 + 2 * (64 + 1)][3] = 1
        self.assert_rejected(rows, "rising")

    def test_wrong_sample_clock_fails_even_for_correct_bitstream(self):
        self.assert_rejected(wire_capture([0, 10, 20, 30, 40, 50], frequency=3200000), "rate")

    def test_too_short_capture_has_no_meaningful_stereo_evidence(self):
        self.assert_rejected(wire_capture([0, 1, 2]), "complete stereo")

    def test_nonmonotonic_time_or_unknown_logic_level_is_rejected(self):
        rows = wire_capture([0, 10, 20, 30, 40, 50])
        rows[190][0] = rows[189][0] - 0.001
        self.assert_rejected(rows, "timestamp")
        rows = wire_capture([0, 10, 20, 30, 40, 50])
        rows[200][3] = "X"
        self.assert_rejected(rows, "logic")

    def test_explicit_columns_and_microsecond_time_scale(self):
        rows = wire_capture([0, 1234, -1234, 2000, -2000, 7, 0])
        for row in rows:
            row[0] *= 1000000
        flags = ["--time-column", "Timestamp", "--bclk-column", "D0", "--ws-column", "D1",
                 "--sd-column", "D2", "--time-scale", "0.000001"]
        process, report, pcm = self.analyze(rows, flags, ["Timestamp", "D0", "D1", "D2", "D3"])
        self.assertEqual(process.returncode, 0, process.stderr + process.stdout)
        self.assertEqual(pcm, [1234, -1234, 2000, -2000, 7])
        self.assertAlmostEqual(report["measured_lrclk_hz"], 48000, places=3)

    def test_raw_key_edge_to_complete_pcm_and_slot_is_measured(self):
        rows = wire_capture([0] * 7 + [1234] * 5, key_bit=5 * 64)
        process, report, pcm = self.analyze(rows, ["--key-column", "KEY_N"])
        self.assertEqual(process.returncode, 0, process.stderr + process.stdout)
        latency = report["latency"]
        # Input at bit 320 falling edge; nonzero PCM completes at rising
        # bit 464, and its left 32-bit slot completes at rising bit 480.
        self.assertAlmostEqual(latency["input_to_first_nonzero_pcm_ms"], 144.5 / 3072, places=6)
        self.assertAlmostEqual(latency["input_to_complete_left_slot_ms"], 160.5 / 3072, places=6)
        self.assertTrue(latency["digital_path_within_limit"])
        self.assertFalse(report["speaker_latency_measured"])

    def test_preexisting_audio_or_missing_key_edge_cannot_prove_latency(self):
        self.assert_rejected(wire_capture([1234] * 12, key_bit=5 * 64), "already nonzero", ["--key-column", "KEY_N"])
        self.assert_rejected(wire_capture([0] * 12), "key edge", ["--key-column", "KEY_N"])

    def test_audio_already_decoded_in_inflight_stereo_frame_is_not_a_key_response(self):
        # Stereo-frame completion happens after this key edge, but the
        # nonzero left PCM word was already received before it.
        self.assert_rejected(wire_capture([0] * 6 + [1234] * 6, key_bit=6 * 64 + 20),
                             "already nonzero", ["--key-column", "KEY_N"])

    def test_long_digital_path_latency_fails_ten_ms_limit(self):
        self.assert_rejected(wire_capture([0] * 500 + [1234] * 5, key_bit=4 * 64), "latency", ["--key-column", "KEY_N"])

    def test_key_edge_inside_already_nonzero_pcm_word_cannot_prove_latency(self):
        self.assert_rejected(wire_capture([0] * 6 + [1234] * 6, key_bit=6 * 64 + 12),
                             "already nonzero", ["--key-column", "KEY_N"])

    def test_no_response_after_key_edge_fails_latency_measurement(self):
        self.assert_rejected(wire_capture([0] * 12, key_bit=4 * 64), "nonzero", ["--key-column", "KEY_N"])


if __name__ == "__main__":
    unittest.main()
