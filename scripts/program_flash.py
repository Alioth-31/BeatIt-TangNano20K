"""Program and verify Nano20K external configuration Flash at address zero.

Explicit standalone deployment, reusing the SRAM programmer's source/profile
guards. Never writes the BL616 controller firmware or security/OTP settings.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time

import program_sram as sram
from build_hardware_probe import gowin_stage_root
from build_gowin import add_audio_options,normalize_audio_options,build_label,timing_passed

ROOT=Path(__file__).resolve().parents[1]


def validated_image(args,root=ROOT):
    folder=root/'build'/build_label(args)
    metadata=json.loads((folder/'build_result.json').read_text(encoding='utf-8'))
    if not metadata.get('completed') or not metadata.get('timing_pass'):
        raise ValueError('Build/timing must pass before Flash programming')
    if args.hdmi and not timing_passed(metadata.get('timing'),hdmi=True):
        raise ValueError('HDMI clocks/timing are not verified')
    sram.validate_audio_variant(metadata,args,root)
    if len(metadata.get('bitstreams',[]))!=1:raise ValueError('Expected exactly one bitstream')
    relative=metadata['bitstreams'][0];image=(root/relative).resolve()
    if not image.is_relative_to(root.resolve()):raise ValueError('Bitstream must be in this project')
    digest=hashlib.sha256(image.read_bytes()).hexdigest()
    if metadata.get('bitstreams_sha256',{}).get(relative)!=digest:
        raise ValueError('Bitstream digest mismatch; rebuild first')
    return folder,image,digest


def flash_command(exe,image,location,cable_index):
    # SUG502 table 4-3: 37 is exFlash Erase,Program,Verify thru GAO-Bridge.
    # 5/6 are embedded Flash and are not appropriate for GW2AR-18C.
    return [str(exe),'--device','GW2AR-18C','--operation_index','37',
            '--cable-index',str(cable_index),'--location',str(location),
            '--spiaddr','0x000000','--fsFile',str(image)]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--voices',type=int,choices=(4,8,16,32),default=32)
    p.add_argument('--app',action='store_true',required=True)
    p.add_argument('--transport',choices=('usb','ble'),default='ble')
    p.add_argument('--no-controls',action='store_true')
    add_audio_options(p)
    p.add_argument('--location',type=int,required=True)
    p.add_argument('--cable-index',type=int,default=1)
    p.add_argument('--bridge-port',help='BL616 COM port used to select SPI downloading')
    p.add_argument('--backup',type=Path,help='Existing full Flash dump to record for recovery')
    p.add_argument('--dry-run',action='store_true')
    a=p.parse_args();a.led=False
    normalize_audio_options(a,p)
    folder,image,digest=validated_image(a)
    exe=sram.programmer_executable()
    version=sram.programmer_version(exe)
    if version<sram.MIN_VERIFIED_PROGRAMMER:raise SystemExit('Use Programmer 1.9.12.04 or later')
    report=dict(success=False,mode='exFlash Erase,Program,Verify thru GAO-Bridge',
                bitstream_sha256=digest,programmer_version='.'.join(map(str,version)),
                build_profile=build_label(a),address=0,transport=a.transport,
                embedded_calibration=getattr(a,'factory_calibration_data',None))
    if a.backup:
        if not a.backup.is_file() or a.backup.stat().st_size<1024*1024:
            raise SystemExit('Expected a readable Flash backup of at least 1MiB')
        report['backup']={'path':str(a.backup.resolve()),'bytes':a.backup.stat().st_size,
                          'sha256':hashlib.sha256(a.backup.read_bytes()).hexdigest()}
    if a.dry_run:
        print(json.dumps(dict(command=flash_command(exe,image,a.location,a.cable_index),**report),indent=2));return
    stamp=time.strftime('%Y%m%d_%H%M%S')
    stage=gowin_stage_root()/('beatit_flash_'+stamp);stage.mkdir(parents=True,exist_ok=False)
    staged=stage/'image.fs';shutil.copyfile(image,staged)
    if hashlib.sha256(staged.read_bytes()).hexdigest()!=digest:raise SystemExit('Staged bitstream changed')
    if a.bridge_port:
        import serial
        from device_link import select_bridge
        with serial.Serial(a.bridge_port,115200,timeout=.2,write_timeout=1) as port:select_bridge(port,'spi')
    scan=subprocess.run([str(exe),'--scan','--cable-index',str(a.cable_index),'--location',str(a.location)],
                        cwd=exe.parent,capture_output=True,timeout=20)
    scan_text=(scan.stdout+scan.stderr).decode(errors='replace')
    (folder/f'flash_scan_{stamp}.log').write_text(scan_text,encoding='utf-8')
    if scan.returncode or '0x0000081b' not in scan_text.lower():
        raise SystemExit('Expected GW2AR ID 0x0000081B not found; inspect Flash scan log')
    command=flash_command(exe,staged,a.location,a.cable_index)
    run=subprocess.run(command,cwd=exe.parent,capture_output=True,timeout=300)
    log=(run.stdout+run.stderr).decode(errors='replace')
    name=f'flash_{stamp}.log';(folder/name).write_text(log,encoding='utf-8')
    report.update(success=run.returncode==0 and 'Finished.' in log and 'fail' not in log.lower(),
                  returncode=run.returncode,command=command,log=name)
    (folder/f'flash_{stamp}.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('\n'.join(line for line in log.splitlines() if '%' not in line))
    print(json.dumps(report,indent=2))
    raise SystemExit(0 if report['success'] else 1)


if __name__=='__main__':main()
