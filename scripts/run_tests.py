"""Run from any directory. Production RTL is compiled strictly as Verilog-2001."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from build_hardware_probe import gowin_home

ROOT = Path(__file__).resolve().parents[1]

def find_tool(name):
    candidates = [os.environ.get(name.upper()), shutil.which(name)]
    for value in candidates:
        if value and Path(value).is_file():
            return value
    raise RuntimeError(f'{name} unavailable; set {name.upper()} to executable path')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('tests', nargs='*')
    parser.add_argument('--report', type=Path, help='Separate result file for targeted runs; defaults to test_results.json only for the full suite')
    args = parser.parse_args()
    iv, vvp = find_tool('iverilog'), find_tool('vvp')
    build = ROOT / 'build'
    build.mkdir(exist_ok=True)
    env = os.environ.copy()
    env['PATH'] = str(Path(iv).parent) + os.pathsep + str(Path(iv).parent.parent/'lib') + os.pathsep + env.get('PATH', '')
    tests = args.tests or [p.stem for p in sorted((ROOT / 'sim').glob('tb_*.v'))]
    report=args.report or build / ('targeted_test_results.json' if args.tests else 'test_results.json')
    report.parent.mkdir(parents=True,exist_ok=True)
    results = []
    for test in tests:
        configs = [(v,False) for v in [4,8,16,32]] if test in ('tb_polyphony','tb_dual_osc_core','tb_independent_oscillators','tb_live_wave','tb_activity_count') else [(None,False)]
        if test in ('tb_rom','tb_dual_rom_compare','tb_osc_envelope_ram','tb_a_state_ram_equivalence','tb_pitch_modulation','tb_expression_mix'): configs.append((None,True))
        if test == 'tb_osc_envelope_ram':configs += [('frequency',False),('frequency',True)]
        if test == 'tb_independent_oscillators': configs.append((32,True))
        if test in ('tb_pending_retrigger','tb_review_release_repress'): configs.append(('independent',False))
        if test == 'tb_phase_boundaries': configs = [(None,False),('compat',False)]
        if test == 'tb_temporal_storage_equivalence': configs = [(None,False),('compat',False),(None,True),('compat',True)]
        if test == 'tb_full64_audio': configs = [(None,False),('performance',False)]
        if test == 'tb_hdmi_wire':configs = [(None,True)]
        if test == 'tb_hdmi_capture':configs += [('wide',False)]
        if test == 'tb_guide_bridge':configs += [('mono',False)]
        for voices,vendor in configs:
            label = test + (f'_{voices}' if voices else '') + ('_gowin' if vendor else '')
            image = build / (label + '.vvp')
            cmd = [iv, '-g2001', '-Wall', '-Irtl', '-s', test, '-o', str(image)]
            if voices == 'compat':
                cmd += [f'-P{test}.INDEP=0']
            elif voices == 'wide':
                cmd += [f'-P{test}.W=128']
            elif voices == 'mono':
                cmd += [f'-P{test}.MONO=1']
            elif voices == 'frequency':
                cmd += [f'-P{test}.W=32',f'-P{test}.A=6']
            elif voices == 'independent':
                cmd += [f'-P{test}.INDEP=1']
            elif voices == 'performance':
                cmd += [f'-P{test}.PERF=1']
            elif voices:
                cmd += [f'-P{test}.N={voices}']
            if vendor:
                home=gowin_home()
                cmd += ['-DGOWIN_PRIMITIVES']
                if test=='tb_hdmi_wire':cmd+=['-DGOWIN_VIDEO']
                cmd += [str(home/'IDE/simlib/gw2a/prim_sim.v')]
            cmd += [str(p.relative_to(ROOT)) for p in sorted((ROOT / 'rtl').glob('*.v'))]
            cmd += [f'sim/{test}.v']
            start = time.monotonic()
            compiled = subprocess.run(cmd, cwd=ROOT, env=env, text=True, errors='replace', capture_output=True)
            log = compiled.stdout + compiled.stderr
            code = compiled.returncode
            if code == 0:
                try:
                    run = subprocess.run([vvp, str(image)], cwd=ROOT, env=env, text=True, errors='replace',
                                         capture_output=True, timeout=900)
                    log += run.stdout + run.stderr
                    code = run.returncode
                    if 'PASS' not in run.stdout or 'FAIL' in run.stdout or 'ERROR:' in run.stdout:
                        code = code or 1
                except subprocess.TimeoutExpired:
                    log += '\nFAIL simulation wall-time timeout (900 seconds)\n'
                    code = 1
            (build / (label + '.log')).write_text(log, encoding='utf-8')
            passed = code == 0
            results.append(dict(test=label, passed=passed, seconds=round(time.monotonic()-start, 2)))
            checkpoint=report.with_suffix(report.suffix+'.tmp')
            checkpoint.write_text(json.dumps(results,indent=2),encoding='utf-8')
            checkpoint.replace(report)
            print(f'{label}: {"PASS" if passed else "FAIL"}', flush=True)
            if not passed:
                print(log[-6000:])
    raise SystemExit(0 if results and all(r['passed'] for r in results) else 1)

if __name__ == '__main__':
    main()
