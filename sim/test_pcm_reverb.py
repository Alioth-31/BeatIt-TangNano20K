"""Independent integer model + real RTL comparison at full 48k delay lengths.

The model uses independent lists per filter, not the RTL packed RAM scheduler.
Cases target signed overflow, channel delay, non-decaying quantization, stale
RAM after reset/bypass, parameter smoothing and frame budget. No external audio
device is needed; this is not an acoustic or final board acceptance test.
"""
import json
import math
import os
from pathlib import Path
import random
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from run_tests import find_tool
from build_hardware_probe import gowin_home

COMBS = (1215, 1317, 1410, 1518, 1599, 1683, 1764, 1845)
DIFFUSERS = (605, 480, 371, 245)
GAINS = (22000, 26000, 29000, 31200)

def trunc_div(value, denominator):
    return (abs(value) // denominator) * (-1 if value < 0 else 1)

def sat16(value):
    return max(-32768, min(32767, value))

def sat18(value):
    return max(-131072, min(131071, value))

class ReverbReference:
    def __init__(self):
        self.reset()

    def reset(self):
        self.lines = [[0] * n for n in COMBS + DIFFUSERS]
        self.pos = [0] * 12
        self.damping = [0] * 8
        self.wet = 0

    def step(self, dry, target, room, bypass=False, reset=False):
        if reset or bypass:
            self.reset()
        if bypass:
            return dry
        target = min(32768, target)
        self.wet += max(-64, min(64, target - self.wet))
        send = trunc_div(dry, 8)  # Q2 internal samples; physical send is dry/32
        total = 0
        for i in range(8):
            tap = self.lines[i][self.pos[i]]
            lp = trunc_div(self.damping[i] + tap, 2)
            value = sat18(send + trunc_div(lp * GAINS[room], 32768))
            self.damping[i] = lp
            self.lines[i][self.pos[i]] = value
            self.pos[i] = (self.pos[i] + 1) % len(self.lines[i])
            total += value
        value = trunc_div(total, 8)
        for i in range(8, 12):
            tap = self.lines[i][self.pos[i]]
            output = sat18(tap - trunc_div(value, 2))
            self.lines[i][self.pos[i]] = sat18(value + trunc_div(output, 2))
            self.pos[i] = (self.pos[i] + 1) % len(self.lines[i])
            value = output
        value = sat16(value * 4)  # Q2 -> PCM, then 16x wet-return gain
        return sat16(dry + trunc_div((value - dry) * self.wet, 32768))

class TestPcmReverb(unittest.TestCase):
    def test_signed_impulse_reset_and_parameter_stream_matches_rtl(self):
        build = ROOT / 'build/reverb'
        build.mkdir(parents=True, exist_ok=True)
        reference = ReverbReference()
        cases = []
        # Settle wet control silently, then impulse and enough room decay.
        cases.extend((0, 32768, 0, False, False) for _ in range(512))
        cases.append((32767, 32768, 0, False, False))
        cases.extend((0, 32768, 0, False, False) for _ in range(48000))
        cases.append((-32768, 32768, 1, False, True))
        cases.extend((0, 32768, 1, False, False) for _ in range(48000))
        # Extreme alternating inputs expose narrow intermediate sums/subtractions.
        cases.extend((32767 if i % 2 else -32768, 24576, 3, False, False) for i in range(6000))
        rng = random.Random(0xBEA717)
        cases.extend((rng.randrange(-32768, 32768), (0, 8192, 32768, 65535)[i % 4],
                      (i // 400) % 4, i % 1200 == 0, i == 2400) for i in range(4000))
        cases.append((0, 32768, 0, True, False))
        cases.extend((0, 32768, 0, False, False) for _ in range(4000))
        # Sustained extrema exercise the compensated wet-return limiter;
        # alternating extrema alone do not build up feedback/DC energy.
        overload_begin = len(cases)
        cases.extend((32767, 32768, 3, False, i == 0) for i in range(8000))
        cases.extend((-32768, 32768, 3, False, i == 0) for i in range(8000))
        overload_end = len(cases)
        cases.extend((0, 32768, 0, False, False) for _ in range(24000))
        overload_release_end = len(cases)
        # Real 10%-volume 32-voice peak is ~102 codes, not full-scale PCM.
        low_level_windows = []
        for amplitude in (102, 410):
            for room, wet in ((1, 4096), (0, 2048), (2, 8192)):
                cases.extend((round(amplitude * math.sin(2*math.pi*440*i/48000)),
                              wet, room, False, i == 0) for i in range(24000))
                tail_start = len(cases)
                cases.extend((0, wet, room, False, False) for _ in range(24000))
                low_level_windows.append((amplitude, room, wet, tail_start, len(cases)))
        cases.append((0, 32768, 0, True, False))
        cases.extend((0, 32768, 0, False, False) for _ in range(4000))
        expected = []
        vectors = build / 'vectors.txt'
        with vectors.open('w', encoding='ascii') as stream:
            for dry, wet, room, bypass, reset in cases:
                result = reference.step(dry, wet, room, bypass, reset)
                expected.append(result)
                stream.write(f'{dry} {wet} {room} {int(bypass)} {int(reset)} {result}\n')
        # Numeric tail is dense, decays, and reset/bypass never resurrects memory.
        tail = expected[513:48513]
        self.assertGreater(sum(v != 0 for v in tail[1000:12000]), 4000)
        early = sum(v*v for v in tail[:12000])
        late = sum(v*v for v in tail[-12000:])
        self.assertLess(late, early / 100)
        self.assertTrue(all(v == 0 for v in expected[-4000:]))
        self.assertEqual(max(expected[overload_begin:overload_end]), 32767)
        self.assertEqual(min(expected[overload_begin:overload_end]), -32768)
        recovery = expected[overload_end:overload_release_end]
        self.assertLess(sum(v*v for v in recovery[-4000:]), sum(v*v for v in recovery[:4000])/100)
        low_results = []
        for amplitude, room, wet, begin, end in low_level_windows:
            tail_samples = expected[begin:end]
            nonzero = [i for i, v in enumerate(tail_samples) if v]
            peak = max(map(abs, tail_samples))
            self.assertGreaterEqual(peak, 2, f"quantized tail lost: {amplitude=}, {room=}")
            self.assertGreater(len(nonzero), 500, f"tail erased: {amplitude=}, {room=}")
            self.assertGreater(max(nonzero), 2400, f"tail cut short: {amplitude=}, {room=}")
            low_results.append(dict(amplitude=amplitude, room=room, wet=wet,
                peak=peak, nonzero=len(nonzero), last_sample=max(nonzero)))
        iv, vvp = find_tool('iverilog'), find_tool('vvp')
        env = os.environ.copy()
        env['PATH'] = str(Path(iv).parent) + os.pathsep + env.get('PATH', '')
        for vendor in (False, True):
            label = 'numeric-gowin' if vendor else 'numeric'
            image = build / (label + '.vvp')
            compile_cmd = [iv, '-g2001', '-Wall', '-s', 'tb_pcm_reverb', '-o', str(image)]
            if vendor:
                home = gowin_home()
                compile_cmd += ['-DGOWIN_PRIMITIVES', str(home/'IDE/simlib/gw2a/prim_sim.v')]
            compile_cmd += ['rtl/pcm_reverb.v', 'sim/tb_pcm_reverb.v']
            compiled = subprocess.run(compile_cmd, cwd=ROOT, env=env, text=True, capture_output=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            # Icarus on Windows loses non-ASCII bytes in plusargs; cwd is the project.
            run = subprocess.run([vvp, str(image), '+vectors=' + vectors.relative_to(ROOT).as_posix()], cwd=ROOT,
                                 env=env, text=True, capture_output=True, timeout=300)
            (build / (label + '.log')).write_text(compiled.stdout + compiled.stderr + run.stdout + run.stderr)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn(f'PASS reverb vectors={len(cases)}', run.stdout)
        (build / 'numeric.json').write_text(json.dumps({'samples': len(cases), 'tail_early_energy': early,
            'tail_late_energy': late, 'late_to_early': late/early, 'tail_nonzero_samples': sum(v != 0 for v in tail),
            'low_level_tails': low_results, 'passed': True, 'gowin_multiplier': True,
            'scope': 'Full delay lengths, independent integer oracle, not hardware audio'}, indent=2))

if __name__ == '__main__':
    unittest.main()
