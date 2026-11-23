"""Program a timing-passed build to volatile SRAM using Gowin's native driver.
Scan for the cable and use the reported USB location.
No flash erase/program operations are exposed by this script.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from build_hardware_probe import make_probe_variant, probe_key_mask, probe_label, source_hashes, ROM_PREPEND
from build_hardware_probe import gowin_stage_root

ROOT=Path(__file__).resolve().parents[1]
from build_gowin import add_audio_options, build_label, build_options, staged_source, normalize_audio_options, timing_passed

MIN_VERIFIED_PROGRAMMER=(1,9,12,4)


def validate_probe_variant(metadata, voices, root=ROOT, independent=False):
    """Validate staged variant provenance before any board operation."""
    if (metadata.get('voices') != voices or metadata.get('label') != probe_label(voices,independent) or metadata.get('independent_osc',False)!=independent
            or metadata.get('key_mask') != probe_key_mask(voices)
            or metadata.get('a4_key_mask') != 0x20 or metadata.get('osc2_factor',66048)!=(67456 if independent else 66048)):
        raise SystemExit('Probe variant metadata absent/mismatched; rebuild first')
    top_name=str(Path('rtl')/'hardware_probe_top.v')
    rom_name=str(Path('rtl')/'sine_rom_pair.v')
    try:
        variant, substitutions=make_probe_variant((root/top_name).read_text(encoding='utf-8'), voices,independent)
    except ValueError as error:
        raise SystemExit(f'Probe source substitution no longer applies: {error}')
    substitutions.append(dict(file=rom_name, kind='prepend', old='', new=ROM_PREPEND, count=1))
    if independent:substitutions.append(dict(file=str(Path('rtl')/'osc_envelope_ram.v'),kind='prepend',old='',new=ROM_PREPEND,count=1))
    if metadata.get('stage_substitutions') != substitutions:
        raise SystemExit('Probe stage substitution metadata mismatched; rebuild first')
    original=metadata.get('sources_sha256',{})
    staged=metadata.get('staged_sources_sha256',{})
    expected_names=set(source_hashes(root))
    if not expected_names or set(original) != expected_names or set(staged) != expected_names:
        raise SystemExit('Staged source manifest absent/incomplete; rebuild probe first')
    stage=Path(metadata.get('stage','')).resolve()
    if set(source_hashes(stage)) != expected_names:
        raise SystemExit('Staged source files absent/incomplete; rebuild probe first')
    for name,digest in original.items():
        path=(root/name).resolve()
        if not path.is_relative_to(root.resolve()) or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
            raise SystemExit(f'Source changed since build: {name}; rebuild first')
        if name==top_name and (voices!=4 or independent):
            expected=variant.encode('utf-8')
        elif name==rom_name or (independent and name==str(Path('rtl')/'osc_envelope_ram.v')):
            expected=(ROM_PREPEND+path.read_text(encoding='utf-8')).encode('utf-8')
        else:
            expected=path.read_bytes()
        if hashlib.sha256(expected).hexdigest()!=staged[name]:
            raise SystemExit(f'Staged source derivation mismatch: {name}; rebuild first')
        staged_path=(stage/name).resolve()
        if not staged_path.is_relative_to(stage) or not staged_path.is_file() or hashlib.sha256(staged_path.read_bytes()).hexdigest()!=staged[name]:
            raise SystemExit(f'Staged source changed since build: {name}; rebuild first')

def validate_audio_variant(metadata,args,root=ROOT):
    if metadata.get('label')!=build_label(args) or metadata.get('build_options')!=build_options(args):
        raise SystemExit('Audio build profile mismatched; rebuild first')
    original=metadata.get('sources_sha256',{});staged=metadata.get('staged_sources_sha256',{})
    names=set(source_hashes(root));stage=Path(metadata.get('stage','')).resolve()
    if not names or set(original)!=names or set(staged)!=names or set(source_hashes(stage))!=names:
        raise SystemExit('Audio source manifest absent/incomplete; rebuild first')
    for name,digest in original.items():
        path=(root/name).resolve()
        if not path.is_relative_to(root.resolve()) or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
            raise SystemExit(f'Source changed since build: {name}; rebuild first')
        try:expected=staged_source(name,path.read_bytes(),args)
        except ValueError as error:raise SystemExit(f'Audio source derivation no longer applies: {error}')
        if hashlib.sha256(expected).hexdigest()!=staged[name]:
            raise SystemExit(f'Staged source derivation mismatch: {name}; rebuild first')
        actual=(stage/name).resolve()
        if not actual.is_relative_to(stage) or not actual.is_file() or hashlib.sha256(actual.read_bytes()).hexdigest()!=staged[name]:
            raise SystemExit(f'Staged source changed since build: {name}; rebuild first')


def programmer_version(exe):
    help_run=subprocess.run([str(exe),'--help'],cwd=exe.parent,capture_output=True,timeout=20)
    output=(help_run.stdout+help_run.stderr).decode(errors='replace')
    match=re.search(r'Version V(\d+)\.(\d+)\.(\d+)\.(\d+)',output)
    if help_run.returncode or not match:
        raise SystemExit('Could not determine Gowin Programmer version')
    return tuple(map(int,match.groups()))

def programmer_executable():
    install = os.environ.get('GOWIN_PROGRAMMER_HOME') or os.environ.get('GOWIN_HOME')
    if not install:
        raise SystemExit('Set GOWIN_PROGRAMMER_HOME to the Gowin Programmer installation root')
    executable = Path(install).expanduser().resolve() / 'Programmer/bin/programmer_cli.exe'
    if not executable.is_file():
        raise SystemExit(f'Gowin Programmer executable was not found: {executable}')
    return executable


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--voices',type=int,choices=[4,8,16,32],default=4)
    p.add_argument('--led',action='store_true')
    p.add_argument('--probe',action='store_true',help='Program the temporary UART hardware probe')
    p.add_argument('--app',action='store_true',help='Program the protocol-enabled instrument')
    p.add_argument('--transport',choices=['usb','ble'],default='usb')
    p.add_argument('--no-controls',action='store_true',help='Select the unwired bench build')
    add_audio_options(p)
    p.add_argument('--location',type=int,help='USB location returned by --list')
    p.add_argument('--bridge-port',help='Restore BL616 SPI download mode on this COM port before programming')
    p.add_argument('--cable-index',type=int,default=1,help='Gowin cable TYPE index, not enumeration position')
    p.add_argument('--list',action='store_true',help='Read-only USB cable inventory')
    p.add_argument('--verify',action='store_true',help='SRAM Program and Verify (operation 4)')
    p.add_argument('--dry-run',action='store_true',help='Validate build and show command without accessing board')
    a=p.parse_args()
    normalize_audio_options(a,p)
    if a.probe and ((a.dual_osc and not a.independent_osc) or a.live_wave or a.live_tone or a.waveform or a.tremolo or a.delay or a.reverb or a.dc_block):p.error('Audio flags require an audio build, not --probe')
    if sum([a.led,a.probe,a.app])>1: p.error('--led, --probe and --app are mutually exclusive')
    if a.no_controls and not a.app:p.error('--no-controls requires --app')
    exe=programmer_executable()
    if a.list:
        result=subprocess.run([str(exe),'--scan-cables','F'],cwd=exe.parent,timeout=20)
        raise SystemExit(result.returncode)
    if a.location is None: p.error('--location is required; use --list first')
    version=programmer_version(exe)
    version_text=f'{version[0]}.{version[1]}.{version[2]}.{version[3]:02d}'
    if a.verify and version < MIN_VERIFIED_PROGRAMMER:
        raise SystemExit(
            f'Programmer V{version_text} is older than the tested '
            'V1.9.12.04 required for verified writes'
        )
    label=probe_label(a.voices,a.independent_osc) if a.probe else build_label(a)
    dest=ROOT/'build'/label
    metadata=json.loads((dest/'build_result.json').read_text())
    if not metadata['completed'] or not metadata['timing_pass']:
        raise SystemExit('Build or timing did not pass; rebuild before programming')
    if a.hdmi and not timing_passed(metadata.get('timing'),hdmi=True):
        raise SystemExit('HDMI clocks/timing absent or mismatched; rebuild before programming')
    for name,digest in metadata['sources_sha256'].items():
        path=ROOT/name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
            raise SystemExit(f'Source changed since build: {name}; rebuild first')
    if a.probe:
        validate_probe_variant(metadata,a.voices,independent=a.independent_osc)
    else:
        validate_audio_variant(metadata,a)
    relative=metadata['bitstreams'][0]
    fs=ROOT/relative
    digest=hashlib.sha256(fs.read_bytes()).hexdigest()
    if metadata.get('bitstreams_sha256',{}).get(relative)!=digest:
        raise SystemExit('Bitstream digest absent/mismatched; rebuild with current build_gowin.py')
    stamp=time.strftime('%Y%m%d_%H%M%S')
    stage=gowin_stage_root()/f'nano20k_program_{label}_{stamp}'
    stage.mkdir(parents=True,exist_ok=False)
    # The profile is already in the directory name. Repeating it in the file
    # name exceeds Programmer's legacy MAX_PATH limit for complete FX builds.
    staged=stage/'image.fs'
    shutil.copyfile(fs,staged) # Programmer requires an ASCII staging path.
    cable=['--cable-index',str(a.cable_index),'--location',str(a.location)]
    command=[str(exe),'--device','GW2AR-18C','--operation_index','4' if a.verify else '2',*cable,'--fsFile',str(staged)]
    if a.dry_run:
        print(json.dumps(dict(command=command,sha256=digest),indent=2)); return
    if a.bridge_port:
        import serial
        from device_link import select_bridge
        with serial.Serial(a.bridge_port,115200,timeout=0.2,write_timeout=1) as port:
            select_bridge(port,'spi')
    scan=subprocess.run([str(exe),'--scan',*cable],cwd=exe.parent,capture_output=True,timeout=20)
    scan_text=(scan.stdout+scan.stderr).decode(errors='replace')
    (dest/f'scan_{stamp}.log').write_text(scan_text,encoding='utf-8')
    if scan.returncode or '0x0000081b' not in scan_text.lower():
        raise SystemExit('Expected GW2AR device ID 0x0000081B not detected; inspect scan log')
    run=subprocess.run(command,cwd=exe.parent,capture_output=True,timeout=60)
    output=(run.stdout+run.stderr).decode(errors='replace')
    log_name=f'program_{stamp}.log'
    (dest/log_name).write_text(output,encoding='utf-8')
    ok=run.returncode==0 and 'Finished.' in output and 'fail' not in output.lower()
    result=dict(success=ok,returncode=run.returncode,mode='SRAM Program and Verify' if a.verify else 'SRAM Program',
                verified=bool(ok and a.verify),programmer_version=version_text,
                bitstream_sha256=digest,log=log_name,command=command)
    (dest/f'program_{stamp}.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('\n'.join(line for line in output.splitlines() if '%' not in line))
    print(json.dumps(result,indent=2))
    raise SystemExit(0 if ok else 1)

if __name__=='__main__': main()
