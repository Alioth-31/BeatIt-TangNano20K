"""Compare a GW2AR-18 SRAM readback with the corresponding Gowin .fs file.

UG290 Table 7-8 documents 1,342 SRAM addresses of 3,376 bits each for
GW2A-18.  This script compares that readback window to the first 3,376
bits of the first 1,342 3,440-bit configuration rows in the .fs file.
It makes no claim about the remaining .fs columns or rows.

Exit status is 0 for an exact match, 1 for bit differences, and 2 for
malformed input.  A JSON report is always written for valid input.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_FS = PROJECT / "build/synth_4/impl/pnr/synth_4.fs"
DEFAULT_READBACK = PROJECT / "build/synth_4/sram_readback.txt"
DEFAULT_REPORT = PROJECT / "build/synth_4/sram_readback_verification.json"
SRAM_ROWS = 1342
SRAM_WIDTH = 3376
FS_ROW_WIDTH = 3440


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_bit_lines(path: Path) -> tuple[bytes, list[tuple[int, str]], list[str]]:
    raw = path.read_bytes()
    bit_lines: list[tuple[int, str]] = []
    comments: list[str] = []
    for line_number, raw_line in enumerate(raw.splitlines(), start=1):
        line = raw_line.strip()
        if line and set(line) <= {ord("0"), ord("1")}:
            bit_lines.append((line_number, line.decode("ascii")))
        elif line.startswith(b"//"):
            comments.append(line.decode("utf-8", errors="replace"))
        elif line:
            raise ValueError(f"{path}: unexpected content at line {line_number}")
    return raw, bit_lines, comments


def compare(fs_path: Path, readback_path: Path) -> dict:
    fs_raw, fs_bit_lines, comments = read_bit_lines(fs_path)
    readback_raw, readback_lines, _ = read_bit_lines(readback_path)

    fs_rows = [(line_number, bits) for line_number, bits in fs_bit_lines
               if len(bits) == FS_ROW_WIDTH]
    if len(fs_rows) < SRAM_ROWS:
        raise ValueError(
            f"{fs_path}: only {len(fs_rows)} rows of {FS_ROW_WIDTH} bits; "
            f"need at least {SRAM_ROWS}"
        )
    if len(readback_lines) != SRAM_ROWS:
        raise ValueError(
            f"{readback_path}: {len(readback_lines)} bit rows; expected {SRAM_ROWS}"
        )
    bad_widths = [(number, len(bits)) for number, bits in readback_lines
                  if len(bits) != SRAM_WIDTH]
    if bad_widths:
        raise ValueError(f"{readback_path}: unexpected readback row widths: {bad_widths[:10]}")

    expected_rows = [bits[:SRAM_WIDTH] for _, bits in fs_rows[:SRAM_ROWS]]
    actual_rows = [bits for _, bits in readback_lines]
    row_results = []
    mismatches = []
    zero_to_one = 0
    one_to_zero = 0
    for index, ((fs_line, _), (readback_line, actual), expected) in enumerate(
        zip(fs_rows[:SRAM_ROWS], readback_lines, expected_rows), start=1
    ):
        positions_0_to_1 = [position for position, (want, got) in enumerate(
            zip(expected, actual)) if want == "0" and got == "1"]
        positions_1_to_0 = [position for position, (want, got) in enumerate(
            zip(expected, actual)) if want == "1" and got == "0"]
        different_bits = len(positions_0_to_1) + len(positions_1_to_0)
        zero_to_one += len(positions_0_to_1)
        one_to_zero += len(positions_1_to_0)
        row_results.append({"row_1_based": index, "different_bits": different_bits})
        if different_bits:
            mismatches.append({
                "row_1_based": index,
                "fs_file_line_1_based": fs_line,
                "readback_file_line_1_based": readback_line,
                "expected_ones": expected.count("1"),
                "actual_ones": actual.count("1"),
                "different_bits": different_bits,
                "zero_to_one_columns_0_based": positions_0_to_1,
                "one_to_zero_columns_0_based": positions_1_to_0,
            })

    compared_bits = SRAM_ROWS * SRAM_WIDTH
    different_bits = zero_to_one + one_to_zero
    header = {}
    for comment in comments:
        if ":" in comment:
            key, value = comment[2:].split(":", 1)
            header[key.strip()] = value.strip()
    return {
        "format_version": 1,
        "comparison": "FS configuration rows 1..1342, columns 0..3375, against SRAM readback",
        "documented_geometry": {
            "device_family": "GW2A-18",
            "reference": "Gowin UG290-2.8.1E, Table 7-8",
            "readback_rows": SRAM_ROWS,
            "readback_bits_per_row": SRAM_WIDTH,
        },
        "fs": {
            "path": str(fs_path.resolve()),
            "sha256": sha256_bytes(fs_raw),
            "configuration_rows": len(fs_rows),
            "configuration_bits_per_row": FS_ROW_WIDTH,
            "compared_payload_sha256": sha256_bytes("".join(expected_rows).encode("ascii")),
            "header": {key: header[key] for key in
                       ("Device", "CheckSum", "UserCode", "CRCCheck", "SecurityBit")
                       if key in header},
        },
        "readback": {
            "path": str(readback_path.resolve()),
            "sha256": sha256_bytes(readback_raw),
            "rows": len(readback_lines),
            "bits_per_row": SRAM_WIDTH,
            "payload_sha256": sha256_bytes("".join(actual_rows).encode("ascii")),
            "ones": sum(row.count("1") for row in actual_rows),
            "zeros": sum(row.count("0") for row in actual_rows),
        },
        "result": {
            "exact_match": different_bits == 0,
            "compared_rows": SRAM_ROWS,
            "matching_rows": SRAM_ROWS - len(mismatches),
            "mismatching_rows": len(mismatches),
            "compared_bits": compared_bits,
            "matching_bits": compared_bits - different_bits,
            "different_bits": different_bits,
            "zero_to_one_bits": zero_to_one,
            "one_to_zero_bits": one_to_zero,
        },
        "not_compared": {
            "fs_columns_per_compared_row": FS_ROW_WIDTH - SRAM_WIDTH,
            "additional_fs_configuration_rows": len(fs_rows) - SRAM_ROWS,
        },
        "row_results": row_results,
        "mismatches": mismatches,
        "interpretation_limit": (
            "This is a positional bit comparison of the documented SRAM readback "
            "window. It does not identify the function of different bit positions "
            "or compare the remaining FS columns and rows."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fs", type=Path, default=DEFAULT_FS)
    parser.add_argument("--readback", type=Path, default=DEFAULT_READBACK)
    parser.add_argument("--output", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()
    try:
        report = compare(args.fs, args.readback)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Invalid input: {error}", file=sys.stderr)
        return 2
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n",
                           encoding="utf-8")
    result = report["result"]
    print(f"{result['matching_rows']}/{result['compared_rows']} rows match; "
          f"{result['different_bits']}/{result['compared_bits']} bits differ; "
          f"report: {args.output}")
    return 0 if result["exact_match"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
