"""BeatIt first-connection inspection and measured ADS1015 calibration.

Reuses device_link; changes volatile calibration only on calibrate/apply.
No firmware programming, Flash writes or inferred default sensor endpoints.
"""
import argparse
from datetime import datetime,timezone
import json
from pathlib import Path
import statistics
import time

import device_link as protocol

ROOT=Path(__file__).resolve().parents[1]


def inspect(link):
    hello=link.request(protocol.HELLO,response=protocol.HELLO_REPLY)
    if len(hello)!=13:raise RuntimeError('设备能力回复长度错误')
    state=link.status();panel=link.performance();guide=link.guide()
    channels=[link.expression(i) for i in (1,2)]
    digital_ok=(hello[0]==1 and hello[1]==32 and bool(hello[2]&0x80)
                and int.from_bytes(hello[3:7],'little')==48000 and state['faults']==0
                and link.decoder.errors==0 and link.gaps==0)
    adc=all(s['adc_available'] and s['sample_valid'] and not s['arithmetic_fault'] for s in channels)
    leds=bool(guide['led_available']) and all(s['led_available'] for s in channels)
    expression=adc and all(s['calibrated'] and s['enabled'] and s['active'] for s in channels)
    inputs_idle=(state['active']==0 and state.get('remote_mask',0)==0 and panel.get('physical_debounced',0)==0
                 and panel.get('play_keys',0)==0)
    pending=[]
    if not digital_ok:pending.append('数字链路或音频故障检查未通过')
    if not adc:pending.append('ADS1015尚未提供两个有效摇杆通道')
    if not leds:pending.append('TCA9534键灯驱动尚未在线')
    if not expression:pending.append('摇杆尚未完成校准并启用')
    if not inputs_idle:pending.append('仍有音符活动或实体按键输入未释放；请核对接线与上拉')
    return dict(digital_link_ok=digital_ok,peripherals_present=adc and leds,expression_ready=expression,
                inputs_idle=inputs_idle,
                adc_ready=adc,led_ready=leds,pending=pending,status=state,performance=panel,
                guide=guide,expression=channels,decoder_errors=link.decoder.errors,event_gaps=link.gaps,
                scope='接口与状态检查；实体按键、LED顺序、声音、HDMI画面及端到端延迟另行实测')


def validate_profile(profile):
    if not isinstance(profile,dict) or type(profile.get('schema')) is not int or profile['schema'] not in (1,2):
        raise ValueError('校准文件schema必须为2（兼容旧版1）')
    expected=(0,1,2) if profile['schema']==1 else (1,2)
    rows=profile.get('channels')
    if not isinstance(rows,list) or len(rows)!=len(expected):raise ValueError('必须包含X/Y两个通道；旧版文件需保留原三通道结构')
    checked={}
    for row in rows:
        if not isinstance(row,dict):raise ValueError('通道校准必须是对象')
        for key in ('channel','low','centre','high'):
            if type(row.get(key)) is not int:raise ValueError(f'{key}必须为整数')
        channel=row['channel'];inverse=row.get('invert_x',False)
        if channel in checked or channel not in expected:raise ValueError('通道集合不正确或存在重复')
        if type(inverse) is not bool:raise ValueError('invert_x必须为布尔值')
        protocol.expression_payload(channel,row['low'],row['centre'],row['high'],True,inverse)
        checked[channel]={k:row[k] for k in ('channel','low','centre','high')}
        checked[channel]['invert_x']=inverse
    # Pressure was removed from the instrument. Old files may be imported,
    # but channel 0 is never sent back to the appliance.
    return [checked[i] for i in (1,2)]


def capture_profile(link,prompt=input,samples=32):
    if samples<3:raise ValueError('每个位置至少采样三次')
    readings=[]
    instructions=((1,'将摇杆推到最左端'),(1,'松开摇杆，让它自动回中'),(1,'将摇杆推到最右端'),
                  (2,'将摇杆推到一个前后端点'),(2,'松开摇杆，让它自动回中'),(2,'将摇杆推到另一个前后端点'))
    for channel,message in instructions:
        prompt(message+'，保持位置后按回车；采样约一秒。')
        values=[]
        for _ in range(samples):
            state=link.expression(channel)
            if not state['adc_available'] or not state['sample_valid'] or state['arithmetic_fault']:
                raise RuntimeError('ADC未在线、转换无效或发生算术故障；未生成校准')
            values.append(state['raw']);time.sleep(0.03)
        readings.append(dict(channel=channel,position=message,median=int(statistics.median(values)),
                             minimum=min(values),maximum=max(values)))
    v=[r['median'] for r in readings]
    profile={'schema':2,'channels':[
        dict(channel=1,low=min(v[0],v[2]),centre=v[1],high=max(v[0],v[2]),invert_x=v[0]>v[2]),
        dict(channel=2,low=min(v[3],v[5]),centre=v[4],high=max(v[3],v[5]),invert_x=False)],
        'measurements':readings}
    try:validate_profile(profile)
    except ValueError as error:
        error.rejected_profile=profile
        raise
    return profile


def apply_profile(link,profile):
    rows=validate_profile(profile) # Validate all channels before the first SET.
    before=inspect(link)
    if not before['digital_link_ok'] or not before['adc_ready']:
        raise RuntimeError('数字链路或ADC未就绪，未写入校准')
    try:
        # Stage every channel disabled; enable only after all values read back.
        for enabled in (False,True):
            if enabled and not inspect(link)['adc_ready']:
                raise RuntimeError('启用前ADC已离线或转换失效')
            for row in rows:
                current=link.expression(row['channel'])
                if not current['adc_available'] or not current['sample_valid'] or current['arithmetic_fault']:
                    raise RuntimeError('校准期间ADC离线或转换失效')
                link.set_expression(row['channel'],row['low'],row['centre'],row['high'],
                                    enable=enabled,invert_x=row['invert_x'])
                actual=link.expression(row['channel'])
                if not actual['adc_available'] or not actual['sample_valid'] or actual['arithmetic_fault']:
                    raise RuntimeError('校准回读时ADC离线或转换失效')
                if (any(actual[k]!=row[k] for k in ('low','centre','high','invert_x'))
                        or not actual['calibrated'] or actual['enabled']!=enabled):
                    raise RuntimeError(f"通道{row['channel']}校准回读不一致")
        time.sleep(0.06)
        state=inspect(link)
        if not state['digital_link_ok'] or not state['expression_ready']:
            raise RuntimeError('校准写入后通道未进入有效状态')
        return state
    except BaseException as error:
        cleanup=[]
        for row in rows:
            try:link.set_expression(row['channel'],row['low'],row['centre'],row['high'],enable=False,invert_x=row['invert_x'])
            except Exception as issue:cleanup.append(f"通道{row['channel']}停用失败：{issue}")
        if cleanup and hasattr(error,'add_note'):error.add_note('; '.join(cleanup))
        raise


def main():
    parser=argparse.ArgumentParser(description='BeatIt接口检查、实际端点校准及校准恢复')
    parser.add_argument('--port',required=True)
    parser.add_argument('--direct',action='store_true',help='BL616已切换UART时使用')
    parser.add_argument('--profile',type=Path,default=ROOT/'build/hardware-ready/calibration.json')
    parser.add_argument('--output',type=Path,default=ROOT/'build/hardware-ready/report.json')
    parser.add_argument('--require-peripherals',action='store_true',help='check时要求ADC和键灯在线')
    parser.add_argument('--require-calibrated',action='store_true',help='check时要求摇杆两通道已校准启用')
    parser.add_argument('--require-idle',action='store_true',help='启动验收要求全部演奏输入已释放')
    parser.add_argument('action',choices=('check','calibrate','apply'))
    args=parser.parse_args();report={'success':False,'created_utc':datetime.now(timezone.utc).isoformat()};code=1
    try:
        # Reject invalid files before opening or changing a device.
        profile=json.loads(args.profile.read_text(encoding='utf-8')) if args.action=='apply' else None
        if profile is not None:validate_profile(profile)
        import serial
        with serial.Serial(args.port,115200,timeout=0.05,write_timeout=1) as port:
            if not args.direct:protocol.select_bridge(port,'uart')
            link=protocol.DeviceLink(port)
            if args.require_idle and args.action!='check' and not inspect(link)['inputs_idle']:
                raise RuntimeError('演奏输入尚未释放，未应用校准；请先核对按键接线和上拉')
            if args.action=='calibrate':
                initial=inspect(link)
                if not initial['digital_link_ok'] or not initial['adc_ready']:
                    raise RuntimeError('ADC未就绪，请先运行check并核对接线')
                print('请松开全部琴键。校准只改变当前FPGA运行配置。')
                profile=capture_profile(link)
                args.profile.parent.mkdir(parents=True,exist_ok=True)
                if args.profile.exists():args.profile.with_suffix('.previous.json').write_bytes(args.profile.read_bytes())
                pending_profile=args.profile.with_suffix(args.profile.suffix+'.tmp')
                pending_profile.write_text(json.dumps(profile,indent=2,ensure_ascii=False),encoding='utf-8')
                pending_profile.replace(args.profile)
            state=inspect(link) if args.action=='check' else apply_profile(link,profile)
            ready=(state['digital_link_ok'] and (not args.require_peripherals or state['peripherals_present'])
                   and (not args.require_calibrated or state['expression_ready'])
                   and (not args.require_idle or state['inputs_idle']))
            report.update(success=ready,state=state,action=args.action)
            code=0 if ready else 2
    except (Exception,KeyboardInterrupt) as error:
        if isinstance(error,KeyboardInterrupt):code=130
        report.update(error=str(error) or '用户中断，操作未完成',cleanup_notes=getattr(error,'__notes__',[]))
        if hasattr(error,'rejected_profile'):report['rejected_calibration']=error.rejected_profile
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2,ensure_ascii=False),encoding='utf-8')
    if report['success']:
        print('数字接口检查通过；外设仍有下列待办。' if report['state']['pending'] else '检查通过。')
    else:print('检查未通过或仍有待办：',report.get('error',report.get('state',{}).get('pending')))
    for message in report.get('state',{}).get('pending',[]):print('待办：'+message)
    print('报告：',args.output)
    raise SystemExit(code)


if __name__=='__main__':main()
