"""Build in an ASCII-only staging directory; collect ALL reports under build/.
Use --led for M0, --voices 4/8/16/32 for the synth. Does not program hardware.
"""
import argparse
import hashlib
import json
import html
import re
import stat
from pathlib import Path
import shutil
import subprocess
import time
from build_hardware_probe import gowin_home, gowin_stage_root, source_hashes as hash_sources

ROOT=Path(__file__).resolve().parents[1]

def copy_artifact(src,dst):
    dst=Path(dst)
    assert dst.resolve().is_relative_to((ROOT/'build').resolve())
    if dst.exists(): dst.chmod(stat.S_IREAD|stat.S_IWRITE)
    return shutil.copyfile(src,dst)

def timing_result(dest,label):
    report=dest/f'impl/pnr/{label}_tr_content.html'
    if not report.exists(): return None
    text=' '.join(html.unescape(re.sub('<[^>]+>',' ',report.read_text(errors='replace'))).split())
    setup=re.search(r'Numbers of Setup Violated Endpoints (\d+)',text)
    hold=re.search(r'Numbers of Hold Violated Endpoints (\d+)',text)
    freq=re.search(r'Max Frequency Summary:.*?sys_clk [\d.]+\(MHz\) ([\d.]+)\(MHz\)',text)
    clocks={m[1]:float(m[2]) for m in re.finditer(r'\d+ (\S+) (?:Base|Generated) [\d.]+ ([\d.]+)',text)}
    fmaxes={m[1]:float(m[3]) for m in re.finditer(r'\d+ (\S+) ([\d.]+)\(MHz\) ([\d.]+)\(MHz\)',text)}
    return dict(setup_violations=int(setup[1]) if setup else None,
                hold_violations=int(hold[1]) if hold else None,
                fmax_mhz=float(freq[1]) if freq else None,
                clock_frequencies_mhz=clocks,clock_fmax_mhz=fmaxes)

def timing_passed(timing,hdmi=False):
    if not timing or timing.get('setup_violations')!=0 or timing.get('hold_violations')!=0:return False
    if not hdmi:return True
    clocks=timing.get('clock_frequencies_mhz',{});fmax=timing.get('clock_fmax_mhz',{})
    expected={'sys_clk':49.152,'clk_video':27.0,'serial_clk':126.0,'pixel_clk':25.2}
    return all(abs(clocks.get(k,-1)-v)<0.002 for k,v in expected.items()) and all(fmax.get(k,0)>=expected[k] for k in ('sys_clk','pixel_clk'))
AUDIO_OPTION_NAMES = ('voices','led','app','transport','no_controls','waveform','tremolo','delay',
    'dc_block','live_tone','live_wave','dual_osc','independent_osc','osc2_waveform',
    'osc2_detune_shift','osc2_separate_rom','timing_opt','performance','hdmi','reverb','peripherals','guide','mono')

def add_audio_options(p):
    p.add_argument('--factory-calibration',type=Path,help='Embed measured XY calibration for standalone cold boot')
    p.add_argument('--mono',action='store_true',help='Add explicit mono-legato instrument patch; requires --app --performance')
    p.add_argument('--guide',action='store_true',help='Offline two-exercise LED guidance; requires --app --performance --peripherals')
    p.add_argument('--peripherals',action='store_true',help='Enable ADS1015 expression and TCA9534 key feedback; calibration is explicit over UART')
    p.add_argument('--hdmi',action='store_true',help='FPGA-generated 640x480 state/waveform (performance app)')
    p.add_argument('--performance',action='store_true',help='40-source MIDI/panel instrument profile (app only)')
    placement = p.add_mutually_exclusive_group()
    placement.add_argument('--timing-opt', action='store_true',
                           help='Use Gowin timing-priority placement and routing')
    placement.add_argument('--placement-opt', action='store_true',
                           help='Use Gowin timing-priority placement with default routing')
    p.add_argument('--waveform',type=int,choices=[0,1,2,3],default=0,help='0=sine, 1=saw, 2=pulse, 3=triangle')
    p.add_argument('--tremolo',action='store_true',help='Enable post-mix tremolo')
    p.add_argument('--delay',action='store_true',help='Enable 4096-sample echo')
    p.add_argument('--reverb',action='store_true',help='Enable mono 8-comb/4-allpass reverb; performance timbres select room/mix')
    p.add_argument('--dc-block',action='store_true',help='Enable post-mix DC blocker')
    p.add_argument('--live-tone',action='store_true',help='Enable real-time filter mode via UART (app only)')
    p.add_argument('--live-wave',action='store_true',help='Enable 32-sample waveform crossfade via UART (app only)')
    p.add_argument('--dual-osc',action='store_true',help='Two independent DDS per voice')
    p.add_argument('--independent-osc',action='store_true',help='Two independently enveloped and tuned DDS per voice; implies --dual-osc')
    p.add_argument('--osc2-waveform',type=int,choices=[0,1,2,3],default=0)
    p.add_argument('--osc2-detune-shift',type=int,choices=list(range(5,13)),default=7)
    p.add_argument('--osc2-separate-rom',action='store_true',help='P&R comparison: duplicate sine ROM')

def build_options(a):
    result={name:getattr(a,name,False) for name in AUDIO_OPTION_NAMES}
    if getattr(a, 'placement_opt', False):
        result['placement_opt'] = True
    if getattr(a,'factory_calibration_data',None):result['factory_calibration']=a.factory_calibration_data
    return result

def factory_calibration_header(profile):
    from hardware_ready import validate_profile
    rows=validate_profile(profile)
    words=[0,0]+[row[k] for row in rows for k in ('low','centre','high')]
    packed=sum((word&4095)<<(12*i) for i,word in enumerate(words))
    return (f"// Measured per-unit XY calibration; pressure is disabled.\n"
            f"localparam [95:0] BOOT_CALIBRATION=96'h{packed:024x};\n"
            "localparam [2:0] BOOT_CALIBRATION_MASK=3'b110;\n"
            "localparam [2:0] BOOT_ENABLE_MASK=3'b110;\n"
            f"localparam BOOT_INVERT_X=1'b{int(rows[0]['invert_x'])};\n").encode('ascii')

def normalize_audio_options(a,p):
    a.factory_calibration_data=None
    if getattr(a,'factory_calibration',None):
        if not a.app or not getattr(a,'performance',False) or not getattr(a,'peripherals',False):
            p.error('--factory-calibration requires --app --performance --peripherals')
        try:
            from hardware_ready import validate_profile
            rows=validate_profile(json.loads(Path(a.factory_calibration).read_text(encoding='utf-8')))
            a.factory_calibration_data={'schema':2,'channels':rows}
        except (OSError,ValueError,TypeError) as error:p.error('Invalid factory calibration: '+str(error))
    if getattr(a,'mono',False) and (not a.app or not getattr(a,'performance',False)):
        p.error('--mono requires --app --performance')
    if getattr(a,'guide',False) and (not a.app or not getattr(a,'performance',False) or not getattr(a,'peripherals',False)):
        p.error('--guide requires --app --performance --peripherals')
    if getattr(a,'peripherals',False) and not a.app:p.error('--peripherals requires --app')
    if getattr(a,'hdmi',False) and (not a.app or not getattr(a,'performance',False)):
        p.error('--hdmi requires --app --performance')
    if getattr(a,'performance',False):
        if not a.app:p.error('--performance requires --app')
        a.independent_osc=True;a.live_wave=True;a.live_tone=True
    if a.independent_osc:a.dual_osc=True

def build_label(a):
    label='led_smoke' if a.led else (f'app_{a.transport}_{a.voices}' if a.app else f'synth_{a.voices}')
    if a.no_controls:label+='_unwired'
    if a.dual_osc:
        label+=f'_dual_b{a.osc2_waveform}_dt{a.osc2_detune_shift}' + ('_rom2' if a.osc2_separate_rom else '_romshare')
    if a.independent_osc:label+='_independent'
    if not a.led and (a.waveform or a.tremolo or a.delay or a.dc_block or a.live_tone or a.live_wave):
        label+=f'_wave{a.waveform}' + ('_trm' if a.tremolo else '') + ('_dly' if a.delay else '') + ('_dc' if a.dc_block else '') + ('_tone' if a.live_tone else '') + ('_livewave' if a.live_wave else '')
    if getattr(a,'reverb',False):label+='_rev'
    if getattr(a,'peripherals',False):label+='_expr'
    if getattr(a,'guide',False):label+='_guide_phoneled'
    if getattr(a,'mono',False):label+='_mono'
    if getattr(a,'performance',False):label+='_performance_dry'
    if getattr(a,'hdmi',False):label+='_hdmi'
    if a.timing_opt:label+='_timing'
    elif getattr(a, 'placement_opt', False):label+='_place2'
    if getattr(a,'factory_calibration_data',None):
        label+='_cal'+hashlib.sha256(json.dumps(a.factory_calibration_data,sort_keys=True,separators=(',',':')).encode('ascii')).hexdigest()[:8]
    return label

def staged_source(name,data,a):
    # Use the same exact derivation for builds and the pre-programming guard.
    top='led_smoke_top' if a.led else ('nano20k_hdmi_top' if getattr(a,'hdmi',False) else ('nano20k_app_top' if a.app else 'nano20k_synth_top'))
    basename=Path(name).name
    if basename=='expression_boot.vh' and getattr(a,'factory_calibration_data',None):
        return factory_calibration_header(a.factory_calibration_data)
    text=data.decode('utf-8').replace('\r\n','\n')
    if basename=='hdmi_output.v' and getattr(a,'hdmi',False):
        return ('`define GOWIN_VIDEO\n'+text).encode('utf-8')
    if basename in ('sine_rom_pair.v','osc_envelope_ram.v','pcm_reverb.v','pitch_modulation.v','expression_mix.v'):
        return ('`define GOWIN_PRIMITIVES\n'+text).encode('utf-8')
    if basename==top+'.v' and not a.led:
        if a.app and not getattr(a,'hdmi',False):
            # These are an internal tap when the HDMI wrapper instantiates the
            # app. As the physical top, passive telemetry consumes no GPIOs.
            tap='output [5:0] led_n,\n  output [63:0] display_state,output signed [15:0] display_pcm,output display_valid,\n  output [63:0] guide_display_state);'
            internal='output [5:0] led_n);\n  wire [63:0] display_state,guide_display_state;wire signed [15:0] display_pcm;wire display_valid;'
            if text.count(tap)!=1:raise ValueError('Standalone app telemetry port anchor must occur exactly once')
            text=text.replace(tap,internal,1)
        settings=[('NUM_VOICES',4,a.voices),('WAVEFORM_MODE',0,a.waveform),
            ('FX_ENABLE',0,int(a.tremolo)),('FX_DELAY_ENABLE',0,int(a.delay)),
            ('FX_REVERB_ENABLE',0,int(getattr(a,'reverb',False))),
            ('FX_DC_ENABLE',0,int(a.dc_block)),('FX_TONE_ENABLE',0,int(a.live_tone)),
            ('FX_WAVE_LIVE',0,int(a.live_wave)),('DUAL_OSC_ENABLE',0,int(a.dual_osc)),
            ('INDEPENDENT_OSC_ENABLE',0,int(a.independent_osc)),('OSC2_WAVEFORM',0,a.osc2_waveform),
            ('OSC2_DETUNE_SHIFT',7,a.osc2_detune_shift),('OSC2_SHARE_ROM',1,int(not a.osc2_separate_rom))]
        if a.app:
            settings.append(('CONTROLS_ENABLED',1,int(not a.no_controls)))
            settings.append(('PERFORMANCE_ENABLED',0,int(getattr(a,'performance',False))))
            settings.append(('PERIPHERALS_ENABLED',0,int(getattr(a,'peripherals',False))))
            settings.append(('GUIDE_ENABLED',0,int(getattr(a,'guide',False))))
            settings.append(('MONO_ENABLED',0,int(getattr(a,'mono',False))))
        for parameter,old,value in settings:
            anchor=f'parameter {parameter}={old}'
            if text.count(anchor)!=1:raise ValueError(f'Audio source anchor must occur exactly once: {anchor}')
            text=text.replace(anchor,f'parameter {parameter}={value}',1)
        return text.encode('utf-8')
    sdc='led_smoke.sdc' if a.led else ('nano20k_app.sdc' if a.app else 'nano20k.sdc')
    if basename==sdc:return text.replace('// Mechanical','# Mechanical').encode('utf-8')
    return data

def prepare_audio_sources(stage,a):
    original=hash_sources(stage)
    for name in original:
        path=stage/name
        path.write_bytes(staged_source(name,path.read_bytes(),a))
    return dict(sources_sha256=original,staged_sources_sha256=hash_sources(stage),build_options=build_options(a))

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--voices',type=int,choices=[4,8,16,32],default=4)
    p.add_argument('--led',action='store_true')
    p.add_argument('--app',action='store_true',help='Build the protocol-enabled instrument')
    p.add_argument('--transport',choices=['usb','ble'],default='usb',help='App UART pin profile')
    p.add_argument('--no-controls',action='store_true',help='Explicit bench profile without external keys/encoders')
    add_audio_options(p)
    p.add_argument('--synth-only',action='store_true')
    p.add_argument('--timeout',type=int,default=600,help='Maximum Gowin wall time in seconds')
    a=p.parse_args()
    normalize_audio_options(a,p)
    if a.app and a.led:p.error('--app and --led cannot be combined')
    if a.no_controls and not a.app:p.error('--no-controls requires --app')
    if a.live_tone and not a.app:p.error('--live-tone requires --app')
    if a.live_wave and not a.app:p.error('--live-wave requires --app')
    if not a.dual_osc and (a.osc2_waveform or a.osc2_separate_rom or a.osc2_detune_shift!=7):
        p.error('--osc2-* requires --dual-osc')
    if a.osc2_separate_rom and a.osc2_waveform!=0:
        p.error('--osc2-separate-rom only applies to sine oscillator B')
    if a.led and a.dual_osc:p.error('--led cannot select dual oscillators')
    if a.led and (a.waveform or a.tremolo or a.delay or a.reverb or a.dc_block or a.live_tone or a.live_wave):p.error('--led cannot select audio effects')
    home=gowin_home()
    executable=home/'IDE/bin/gw_sh.exe'
    if not executable.is_file(): raise SystemExit('Set GOWIN_HOME to Gowin Education installation root')
    label=build_label(a)
    stamp=time.strftime('%Y%m%d_%H%M%S')
    # Long variant labels otherwise occur twice in Gowin's synthesis project
    # path and exceed its legacy 260-character limit. Reports keep full labels.
    stage_tag=hashlib.sha256(label.encode('ascii')).hexdigest()[:10]
    stage=gowin_stage_root()/f'nano20k_{stage_tag}_{stamp}'
    stage.mkdir(parents=True,exist_ok=False)
    shutil.copytree(ROOT/'rtl',stage/'rtl')
    shutil.copytree(ROOT/'constraints',stage/'constraints')
    provenance=prepare_audio_sources(stage,a)
    top='led_smoke_top' if a.led else ('nano20k_hdmi_top' if a.hdmi else ('nano20k_app_top' if a.app else 'nano20k_synth_top'))
    cst='led_smoke.cst' if a.led else (f'nano20k_app_{a.transport}'+('_hdmi' if a.hdmi else '')+'.cst' if a.app else 'nano20k_3923.cst')
    sdc='nano20k_hdmi.sdc' if a.hdmi else ('led_smoke.sdc' if a.led else ('nano20k_app.sdc' if a.app else 'nano20k.sdc'))
    lines=['set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7',
           f'set_option -top_module {top}', 'set_option -verilog_std v2001',
           'set_option -include_path {rtl}', 'set_option -use_sspi_as_gpio 1',
           'set_option -use_mspi_as_gpio 0', 'set_option -bit_security 0',
           'set_option -output_base_name '+label]
    if a.timing_opt or a.placement_opt:
        lines.append('set_option -place_option 2')
    if a.timing_opt:
        lines.append('set_option -route_option 1')
    for f in sorted((stage/'rtl').glob('*.v')): lines.append(f'add_file -type verilog {{rtl/{f.name}}}')
    lines += [f'add_file -type cst {{constraints/{cst}}}',f'add_file -type sdc {{constraints/{sdc}}}',
              'run syn' if a.synth_only else 'run all']
    (stage/'run.tcl').write_text('\n'.join(lines)+'\n',encoding='ascii')
    dest=ROOT/'build'/label
    dest.mkdir(exist_ok=True)
    log_path=dest/'gowin.log'
    with log_path.open('w',encoding='utf-8') as log:
        try:
            result=subprocess.run([str(executable),'run.tcl'],cwd=stage,stdout=log,stderr=subprocess.STDOUT,timeout=a.timeout)
        except subprocess.TimeoutExpired:
            log.write(f'\nERROR: Gowin exceeded {a.timeout} seconds; process stopped\n')
            result=subprocess.CompletedProcess([str(executable),'run.tcl'],124)
    for folder in ['impl']:
        if (stage/folder).exists(): shutil.copytree(stage/folder,dest/folder,dirs_exist_ok=True,copy_function=copy_artifact)
    shutil.copy2(stage/'run.tcl',dest/'run.tcl')
    text=log_path.read_text(encoding='utf-8',errors='replace')
    errors=[line for line in text.splitlines() if line.startswith('ERROR') or 'Syntax error' in line]
    files=[dest/f.relative_to(stage) for f in stage.rglob('*.fs')]
    ok=result.returncode==0 and not errors and (a.synth_only or bool(files))
    metadata=dict(label=label,top=top,transport=a.transport if a.app else None,controls_enabled=not a.no_controls,stage=str(stage),returncode=result.returncode,completed=ok,
                  errors=errors,bitstreams=[str(f.relative_to(ROOT)) for f in files],
                  bitstreams_sha256={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files})
    metadata.update(provenance)
    metadata['timing']=None if a.synth_only else timing_result(stage,label)
    metadata['timing_pass']=timing_passed(metadata['timing'],hdmi=a.hdmi)
    (dest/'build_result.json').write_text(json.dumps(metadata,indent=2),encoding='utf-8')
    print(text[-3000:]); print(f'Build completed={ok}; reports: {dest}',flush=True)
    print('Timing:',metadata['timing'],flush=True)
    raise SystemExit(0 if ok and (a.synth_only or metadata['timing_pass']) else 1)
if __name__=='__main__': main()
