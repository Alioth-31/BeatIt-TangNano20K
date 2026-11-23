"""Export the latest successful build as an editable Gowin GUI snapshot."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET
from build_hardware_probe import gowin_home
from build_gowin import ROOT, copy_artifact, add_audio_options, build_label, normalize_audio_options, timing_passed
from program_sram import validate_audio_variant

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--voices',type=int,choices=[4,8,16,32],default=4)
    p.add_argument('--app',action='store_true')
    p.add_argument('--transport',choices=['usb','ble'],default='usb')
    p.add_argument('--no-controls',action='store_true')
    add_audio_options(p)
    p.set_defaults(led=False)
    a=p.parse_args()
    normalize_audio_options(a,p)
    if a.no_controls and not a.app:p.error('--no-controls requires --app')
    label=build_label(a)
    dest=ROOT/'build'/label
    meta=json.loads((dest/'build_result.json').read_text())
    if not meta['completed'] or not meta['timing_pass']: raise SystemExit('A passing build is required')
    if a.hdmi and not timing_passed(meta.get('timing'),hdmi=True): raise SystemExit('Complete HDMI clock timing is required')
    for name,digest in meta['sources_sha256'].items():
        path=ROOT/name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
            raise SystemExit('Source changed since build: '+name)
    validate_audio_variant(meta,a)
    stage=Path(meta['stage'])
    name='gui_'+time.strftime('%H%M%S')
    gui=stage/name
    lines=[f'create_project -name {name} -dir {{{stage.as_posix()}}} -pn GW2AR-LV18QN88C8/I7 -device_version C',
           f'file copy {{{(stage/"rtl").as_posix()}}} {{rtl}}',
           f'file copy {{{(stage/"constraints").as_posix()}}} {{constraints}}']
    lines += [line for line in (stage/'run.tcl').read_text().splitlines() if not line.startswith('run ')]
    lines += ['run close']
    script=stage/(name+'.tcl'); script.write_text('\n'.join(lines)+'\n')
    exe=gowin_home()/'IDE/bin/gw_sh.exe'
    result=subprocess.run([str(exe),str(script)],cwd=stage,capture_output=True,timeout=30)
    (dest/'gui_export.log').write_bytes(result.stdout+result.stderr)
    project=gui/(name+'.gprj')
    if result.returncode or not project.exists(): raise SystemExit('GUI export failed; see gui_export.log')
    for node in ET.parse(project).findall('.//File'):
        if not (gui/node.attrib['path']).is_file(): raise SystemExit('GUI source missing: '+node.attrib['path'])
    shutil.copytree(gui,dest/'gui',dirs_exist_ok=True,copy_function=copy_artifact)
    info=dict(ascii_project=str(project),project_copy=str(dest/'gui'/project.name),
              note='Build snapshot; edit primary rtl/ then rebuild/export for subsequent revisions.')
    (dest/'gui_project.json').write_text(json.dumps(info,indent=2),encoding='utf-8')
    print(json.dumps(info,indent=2))

if __name__=='__main__': main()
