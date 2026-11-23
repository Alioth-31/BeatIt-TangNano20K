"""NanoSynth protocol codec and USB acceptance (control/status, never PCM).

Use --port COM6 --acceptance on the USB app bitstream. BL616 console is
switched to FPGA UART without changing its firmware or saved clock settings.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import struct
import time

ROOT=Path(__file__).resolve().parents[1]
HELLO,GET_STATUS,SET_STATE,SET_MAP,SET_KEYS,SET_PARAMS=1,2,0x10,0x11,0x12,0x13
ACK,HELLO_REPLY,STATUS,EVENT,PARAM_EVENT=0x80,0x81,0x82,0x83,0x84
GET_INPUTS,INPUTS=3,0x85
GET_TONE,GET_WAVE,GET_OSC2=4,5,6
SET_TONE,SET_WAVE,SET_OSC2,SET_OSC_TEST=0x14,0x15,0x16,0x17
TONE,WAVE,OSC2=0x86,0x87,0x88
SET_PERFORMANCE,REMOTE_NOTE,GET_PERFORMANCE,GET_KEY_PITCHES=0x20,0x21,0x24,0x25
KEEPALIVE=0x22
PERFORMANCE,REMOTE_NOTE_REPLY,KEY_PITCHES=0x89,0x8a,0x8b
SET_EXPRESSION,GET_EXPRESSION,EXPRESSION=0x26,0x27,0x8c
SET_GUIDE,GET_GUIDE,GUIDE=0x28,0x29,0x8d


def guide_payload(enabled,song,tempo,action=0):
    if enabled not in (0,1) or song not in (0,1) or tempo not in (0,1,2,3) or action not in (0,1,2):
        raise ValueError('guide enable/song/tempo/action range')
    return bytes((enabled,song,tempo,action))


def parse_guide(payload):
    if len(payload)!=16:raise ValueError('GUIDE length')
    values=struct.unpack('<14BH',payload)
    if (values[0]>1 or values[1]>1 or values[2]>3 or values[3]&~15 or values[4]>15 or
            values[11]>5 or values[12]>1 or values[13]>1):raise ValueError('GUIDE range/reserved')
    result=dict(zip(('enabled','song','tempo','flags','step','target_keys','led_target','led_applied',
                     'play_keys','missed','wrong','blocked_reason','led_available','monophonic','revision'),values))
    for bit,name in enumerate(('running','ready','compatible','done')):result[name]=bool(values[3]&(1<<bit))
    return result


class ProtocolRejected(RuntimeError):
    """A matching FPGA error ACK, including the original command/status."""
    def __init__(self,kind,status):
        self.kind=kind;self.status=status
        super().__init__(f'FPGA rejected type 0x{kind:02x}: status {status}')

def select_bridge(port,mode):
    if mode not in ('uart','spi'):raise ValueError('BL616 bridge mode')
    for command in (b'\x18',b'\x03',b'\r',('choose '+mode+'\r').encode('ascii')):
        port.write(command);port.flush();time.sleep(0.2)
    port.reset_input_buffer()

def crc16(data):
    value=0xffff
    for byte in data:
        value^=byte<<8
        for _ in range(8):value=((value<<1)^0x1021 if value&0x8000 else value<<1)&0xffff
    return value

def encode(kind,sequence,payload=b''):
    if len(payload)>64:raise ValueError('payload >64')
    body=struct.pack('<BBHB',1,kind,sequence&65535,len(payload))+payload
    return b'\xa5\x5a'+body+struct.pack('<H',crc16(body))

class Decoder:
    def __init__(self):self.buffer=bytearray();self.errors=0
    def feed(self,data):
        result=[]
        for byte in data:
            self.buffer.append(byte)
            while len(self.buffer)>=2:
                if self.buffer[:2]!=b'\xa5\x5a':del self.buffer[0];continue
                if len(self.buffer)<7:break
                size=self.buffer[6]+9
                if self.buffer[2]!=1 or size>73:
                    self.errors+=1;del self.buffer[0];continue
                if len(self.buffer)<size:break
                if crc16(self.buffer[2:size-2])!=int.from_bytes(self.buffer[size-2:size],'little'):
                    self.errors+=1;del self.buffer[0];continue
                result.append((self.buffer[3],int.from_bytes(self.buffer[4:6],'little'),bytes(self.buffer[7:size-2])))
                del self.buffer[:size]
        return result

def params_payload(fields,volume,bend,preset):
    if not 1<=fields<=7:raise ValueError('parameter field mask')
    if fields&1 and not 0<=volume<=65535:raise ValueError('volume range')
    if fields&2 and not -32<=bend<=32:raise ValueError('bend range')
    if fields&4 and not 0<=preset<=2:raise ValueError('preset range')
    return struct.pack('<BHbB',fields,volume if fields&1 else 0,bend if fields&2 else 0,preset if fields&4 else 0)

def osc2_payload(bend,preset):
    if not -32<=bend<=32 or not 0<=preset<=2:raise ValueError('oscillator parameter range')
    return struct.pack('<bB',bend,preset)

def osc_test_payload(oscillator,operation,increment=0,voices=32):
    if not 0<=oscillator<64 or oscillator%32>=voices or operation not in range(4):raise ValueError('oscillator identity/operation')
    if operation==1 and not 1<=increment<=0x7fffffff:raise ValueError('oscillator frequency range')
    return struct.pack('<BBI',oscillator,operation,increment)

def expression_payload(channel,low,centre,high,enable=False,invert_x=False):
    if channel not in (0,1,2) or (invert_x and channel!=1):raise ValueError('expression channel/inversion')
    if not -2048<=low<high<=2047:raise ValueError('signed ADC calibration range')
    if channel==0:
        if centre!=0 or high-low<64:raise ValueError('pressure centre/span')
    elif centre-low<80 or high-centre<80:raise ValueError('axis centre/deadband span')
    return struct.pack('<BBhhh',channel,int(bool(enable)) | (int(bool(invert_x))<<1),low,centre,high)


def parse_expression(payload):
    if len(payload)!=14:raise ValueError('EXPRESSION length')
    channel,flags,raw,low,centre,high,led_available,led_applied,last_error,fault=struct.unpack('<BBhhhhBBBB',payload)
    if (channel>2 or flags&~63 or any(not -2048<=v<=2047 for v in (raw,low,centre,high)) or
            led_available>1 or last_error>3 or fault>1):raise ValueError('EXPRESSION range/reserved')
    return dict(channel=channel,calibrated=bool(flags&1),enabled=bool(flags&2),invert_x=bool(flags&4),
                adc_available=bool(flags&8),sample_valid=bool(flags&16),active=bool(flags&32),
                raw=raw,low=low,centre=centre,high=high,led_available=bool(led_available),
                led_applied=led_applied,last_error=last_error,arithmetic_fault=bool(fault))


def parse_status(payload):
    if len(payload)!=18:raise ValueError('STATUS length')
    values=struct.unpack('<BBIIHbBI',payload)
    if values[0]>32 or not -32<=values[5]<=32 or values[6]>2:raise ValueError('STATUS range')
    return dict(zip(['active','faults','remote_mask','physical_mask','volume','bend','preset','frame_counter'],values))

def parse_inputs(payload):
    if len(payload)!=2:raise ValueError('INPUTS length')
    return dict(raw_keys_n=payload[0],debounced_held=payload[1])


def performance_payload(root,scale,octave,timbre):
    if not 0<=root<=11 or scale not in (0,1,2) or not 2<=octave<=6 or timbre not in (0,1,2,4):
        raise ValueError('performance configuration range')
    return bytes((root,scale,octave,timbre))


def parse_performance(payload):
    if len(payload)!=18:raise ValueError('PERFORMANCE length')
    values=struct.unpack('<10BHI2B',payload)
    if (values[0]>11 or values[1]>2 or not 2<=values[2]<=6 or values[3]>4 or
            (values[3]==4 and not values[4]&4) or
            values[4]&~7 or values[5]>5 or values[9]>32 or values[12]!=0 or values[13]!=0):
        raise ValueError('PERFORMANCE range/reserved')
    return dict(zip(('root','scale','octave','timbre','flags','selected_field','preview_value',
                     'play_keys','physical_debounced','active_count','revision','frame_counter',
                     'hardware_available','reserved'),values))


def parse_key_pitches(payload):
    if len(payload)!=10:raise ValueError('KEY_PITCHES length')
    if any(note>127 for note in payload[2:]):raise ValueError('KEY_PITCHES MIDI range')
    return dict(revision=int.from_bytes(payload[:2],'little'),midi=list(payload[2:]))


def remote_note_payload(source,action,midi=0,instance=0):
    if not 0<=source<32 or action not in (0,1,2) or not 0<=midi<=127 or not 0<=instance<=65535:
        raise ValueError('remote note source/action/MIDI/instance range')
    return struct.pack('<BBBBH',source,action,midi,0,instance)


def parse_remote_note(payload):
    if len(payload)!=5:raise ValueError('REMOTE_NOTE reply length')
    source,held,midi,instance=struct.unpack('<BBBH',payload)
    if source>31 or held>1 or midi>127:raise ValueError('REMOTE_NOTE reply range')
    return dict(source=source,held=held,midi=midi,instance=instance)


class DeviceLink:
    def __init__(self,port):
        self.port=port;self.decoder=Decoder();self.sequence=0;self.events=[];self.transcript=[];self.event_sequence=None;self.gaps=0
    def request(self,kind,payload=b'',response=ACK,timeout=2):
        seq=self.sequence;self.sequence=(seq+1)&65535
        wire=encode(kind,seq,payload);self.port.write(wire);self.port.flush()
        self.transcript.append(dict(direction='tx',type=kind,sequence=seq,payload=payload.hex(),time=time.monotonic()))
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            data=self.port.read(max(1,min(4096,self.port.in_waiting)))
            received=None;rejected=None
            for msg_type,msg_seq,msg_payload in self.decoder.feed(data):
                self.transcript.append(dict(direction='rx',type=msg_type,sequence=msg_seq,payload=msg_payload.hex(),time=time.monotonic()))
                if msg_type in (EVENT,PARAM_EVENT):
                    if self.event_sequence is not None and msg_seq!=(self.event_sequence+1)&65535:self.gaps+=1
                    self.event_sequence=msg_seq;self.events.append((msg_type,msg_seq,msg_payload))
                if msg_type==ACK and msg_seq==seq and response!=ACK:
                    if len(msg_payload)!=2 or msg_payload[0]!=kind:raise RuntimeError('ACK request type mismatch')
                    if msg_payload[1]:rejected=ProtocolRejected(kind,msg_payload[1])
                if msg_type==response and msg_seq==seq:
                    if response==ACK and (len(msg_payload)!=2 or msg_payload[0]!=kind):raise RuntimeError('ACK request type mismatch')
                    received=msg_payload
            if rejected is not None:raise rejected
            if received is not None:return received
        raise TimeoutError(f'FPGA response timeout for type 0x{kind:02x}, sequence {seq}')
    def keys(self,mask):
        payload=self.request(SET_KEYS,struct.pack('<I',mask))
        if payload[1]:raise RuntimeError(f'SET_KEYS rejected: {payload[1]}')
    def params(self,fields,volume,bend,preset):
        payload=self.request(SET_PARAMS,params_payload(fields,volume,bend,preset))
        if payload[1]:raise RuntimeError(f'SET_PARAMS rejected: {payload[1]}')
    def status(self):return parse_status(self.request(GET_STATUS,response=STATUS))
    def set_guide(self,enabled,song,tempo,action=0):
        ack=self.request(SET_GUIDE,guide_payload(enabled,song,tempo,action))
        if ack[1]:raise ProtocolRejected(SET_GUIDE,ack[1])
    def guide(self):return parse_guide(self.request(GET_GUIDE,response=GUIDE))
    def set_expression(self,channel,low,centre,high,enable=False,invert_x=False):
        ack=self.request(SET_EXPRESSION,expression_payload(channel,low,centre,high,enable,invert_x))
        if ack[1]:raise ProtocolRejected(SET_EXPRESSION,ack[1])
    def expression(self,channel):
        if channel not in (0,1,2):raise ValueError('expression channel')
        state=parse_expression(self.request(GET_EXPRESSION,bytes([channel]),response=EXPRESSION))
        if state['channel']!=channel:raise ValueError('EXPRESSION channel mismatch')
        return state
    def set_performance(self,root,scale,octave,timbre):
        ack=self.request(SET_PERFORMANCE,performance_payload(root,scale,octave,timbre))
        if ack[1]:raise ProtocolRejected(SET_PERFORMANCE,ack[1])
    def performance(self):return parse_performance(self.request(GET_PERFORMANCE,response=PERFORMANCE))
    def key_pitches(self):return parse_key_pitches(self.request(GET_KEY_PITCHES,response=KEY_PITCHES))
    def remote_note(self,source,action,midi=0,instance=0):
        receipt=parse_remote_note(self.request(REMOTE_NOTE,remote_note_payload(source,action,midi,instance),response=REMOTE_NOTE_REPLY))
        if receipt['source']!=source:raise ValueError('REMOTE_NOTE receipt source mismatch')
        if action!=2 and (receipt['instance']!=instance or receipt['held']!=action or (action==1 and receipt['midi']!=midi)):
            raise ValueError('REMOTE_NOTE receipt does not match requested instance/action/MIDI')
        return receipt
    def note_on(self,source,midi):
        if not 0<=midi<=127:raise ValueError('remote note MIDI range')
        current=self.remote_note(source,2)
        return self.remote_note(source,1,midi,(current['instance']+1)&65535)
    def note_off(self,receipt):
        return self.remote_note(receipt['source'],0,receipt['midi'],receipt['instance'])
    def keepalive(self):
        ack=self.request(KEEPALIVE)
        if ack[1]:raise ProtocolRejected(KEEPALIVE,ack[1])
    def silence_remote(self):
        # Legacy SET_KEYS=0 remains a supported all-source release in this profile.
        # Query after that mutation so each explicit off uses the latest token.
        self.keys(0)
        for source in range(32):
            receipt=self.remote_note(source,2)
            if receipt['held']:self.note_off(receipt)

def acceptance(link,hold_seconds=1.2,voices=4):
    checks=[]
    def check(name,condition,details=None):
        checks.append(dict(name=name,passed=bool(condition),details=details))
        if not condition:raise AssertionError(name)
    hello=link.request(HELLO,response=HELLO_REPLY)
    check('hello contract',len(hello)==13 and hello[0]==1 and hello[1]==voices and hello[2]&15==15 and int.from_bytes(hello[3:7],'little')==48000,hello.hex())
    original=link.status()
    check('initial fault flags',original['faults']==0,original)
    try:
        link.keys(0);link.params(7,32768,-32,2)
        state=link.status()
        check('signed params applied',(state['volume'],state['bend'],state['preset'])==(32768,-32,2),state)
        link.params(1,65535,0,0)
        state=link.status()
        check('partial params preserve other fields',(state['volume'],state['bend'],state['preset'])==(65535,-32,2),state)
        test_mask=0x55 if voices==4 else (1<<voices)-1
        link.keys(test_mask);time.sleep(0.03)
        state=link.status()
        check('all active FPGA voice slots',state['remote_mask']==test_mask and state['active']==voices and state['faults']==0,state)
        # A damaged packet may not alter the authoritative state.
        bad=bytearray(encode(SET_KEYS,0xeeee,bytes(4)));bad[-1]^=0x80
        link.port.write(bad);link.port.flush();time.sleep(0.03)
        state=link.status();check('bad CRC ignored',state['remote_mask']==test_mask,state)
        ack=link.request(SET_MAP,bytes(range(8)))
        check('mapping rejected while held',ack[1]==2,ack.hex())
        ack=link.request(SET_PARAMS,b'\x04\x00\x00\x00\x03')
        check('invalid preset rejected',ack[1]==1,ack.hex())
        # GET_STATUS does not keep remote notes alive.
        start=time.monotonic();time.sleep(hold_seconds)
        state=link.status();check('remote watchdog releases notes',state['remote_mask']==0 and state['active']==0 and state['faults']==0,state)
        link.keys(0)
        ack=link.request(SET_MAP,bytes(range(8)))
        check('idle mapping accepted',ack[1]==0,ack.hex())
        link.params(7,16384,0,0)
        time.sleep(0.01);link.status()
        parameter_events=[e for e in link.events if e[0]==PARAM_EVENT]
        check('device parameter telemetry',len(parameter_events)>=3 and all(len(e[2])==8 for e in parameter_events),len(parameter_events))
        check('event sequence and CRC',link.gaps==0 and link.decoder.errors==0,dict(gaps=link.gaps,crc_errors=link.decoder.errors))
        return checks
    finally:
        link.keys(0);link.params(7,original['volume'],original['bend'],original['preset'])

def independent_acceptance(link,voices):
    checks=[]
    def check(name,condition,details=None):
        checks.append(dict(name=name,passed=bool(condition),details=details))
        if not condition:raise AssertionError(name)
    hello=link.request(HELLO,response=HELLO_REPLY)
    check('independent control capability',len(hello)==13 and hello[1]==voices and hello[2]&0x40!=0,hello.hex())
    original_b=link.request(GET_OSC2,response=OSC2)
    original_a=link.status()
    original_modes={}
    for bit,get,reply in [(0x10,GET_WAVE,WAVE),(0x20,GET_TONE,TONE)]:
        if hello[2]&bit:original_modes[get]=link.request(get,response=reply)
    try:
        for bend,preset in [(-32,1),(32,2),(0,0)]:
            ack=link.request(SET_OSC2,osc2_payload(bend,preset))
            readback=link.request(GET_OSC2,response=OSC2)
            state=link.status()
            check(f'B controls {bend}/{preset} preserve A',ack[1]==0 and readback==osc2_payload(bend,preset) and (state['bend'],state['preset'])==(original_a['bend'],original_a['preset']),readback.hex())
        for get,original in original_modes.items():
            set_type,reply=(SET_WAVE,WAVE) if get==GET_WAVE else (SET_TONE,TONE)
            for mode in range(4):
                ack=link.request(set_type,bytes([mode]))
                check(f'mode {set_type:02x}/{mode}',ack[1]==0 and link.request(get,response=reply)==bytes([mode]))
        mask=(1<<voices)-1
        link.keys(mask)
        for oscillator in list(range(voices))+list(range(32,32+voices)):
            # A slot identity is distinct from the physical/MIDI key identity.
            step=round((300+oscillator*3)*2**32/48000)
            for operation in (1,2,3):
                ack=link.request(SET_OSC_TEST,osc_test_payload(oscillator,operation,step if operation==1 else 0,voices))
                check(f'indexed oscillator {oscillator} operation {operation}',ack[1]==0)
            link.keys(mask)
            check(f'oscillator {oscillator} no audio fault',link.status()['faults']==0)
        ack=link.request(SET_OSC_TEST,osc_test_payload(0,0,voices=voices))
        check('diagnostic masks/frequency restored',ack[1]==0)
        link.keys(0);time.sleep(0.35);link.keys(mask);time.sleep(0.01)
        state=link.status();check('retrigger full dual engine',state['active']==voices and state['faults']==0,state)
        return checks
    finally:
        link.keys(0)
        link.request(SET_OSC_TEST,osc_test_payload(0,0,voices=voices))
        link.request(SET_OSC2,original_b)
        for get,value in original_modes.items():link.request(SET_WAVE if get==GET_WAVE else SET_TONE,value)


def performance_acceptance(link,voices=32):
    """Exercise device authority/native instances; never certify pads or sound."""
    checks=[]
    def check(name,condition,details=None):
        checks.append(dict(name=name,passed=bool(condition),details=details))
        if not condition:raise AssertionError(name)
    hello=link.request(HELLO,response=HELLO_REPLY)
    check('performance capability',len(hello)==13 and hello[1]==voices and bool(hello[2]&0x80),hello.hex())
    original=link.performance();original_a=link.status()
    check('idle normal panel',not original['flags']&3 and original['physical_debounced']==0 and original['play_keys']==0,original)
    original_wave=link.request(GET_WAVE,response=WAVE)
    original_tone=link.request(GET_TONE,response=TONE)
    original_b=link.request(GET_OSC2,response=OSC2)
    config_fields=('root','scale','octave','timbre')
    try:
        link.silence_remote();time.sleep(0.35)
        for scale,expected in [(0,[62,64,66,67,69,71,73,74]),
                               (1,[62,64,65,67,69,70,72,74]),
                               (2,[62,63,64,65,66,67,68,69])]:
            link.set_performance(2,scale,4,0)
            state=link.performance();pitches=link.key_pitches()
            check(f'D scale {scale} atomic mapping',tuple(state[f] for f in config_fields)==(2,scale,4,0)
                  and pitches['revision']==state['revision'] and pitches['midi']==expected,dict(state=state,pitches=pitches))
        before=link.performance();before_pitches=link.key_pitches()
        for payload in [bytes((12,0,4,0)),bytes((0,3,4,0)),bytes((0,0,1,0)),bytes((0,0,7,0)),bytes((0,0,4,3)),bytes(3)]:
            ack=link.request(SET_PERFORMANCE,payload);after=link.performance()
            check(f'invalid config {payload.hex()} rejected atomically',ack==bytes((SET_PERFORMANCE,1))
                  and all(after[f]==before[f] for f in (*config_fields,'revision'))
                  and link.key_pitches()==before_pitches,after)
        ack=link.request(SET_MAP,bytes(range(8)))
        check('legacy mapping explicitly unsupported',ack==bytes((SET_MAP,3)),ack.hex())
        # Validate existing audible controls as numeric state, without naming
        # these patches as real sampled instruments or claiming listening QA.
        for timbre,wave,tone,a_env,b_env,b_bend in [(0,0,0,2,2,0),(1,1,1,1,1,2),(2,3,2,0,2,-2)]:
            link.set_performance(2,0,4,timbre)
            state=link.performance();a=link.status()
            actual_wave=link.request(GET_WAVE,response=WAVE);actual_tone=link.request(GET_TONE,response=TONE)
            b=link.request(GET_OSC2,response=OSC2)
            check(f'timbre {timbre} waveform/tone/envelopes readback',state['timbre']==timbre
                  and actual_wave==bytes((wave,)) and actual_tone==bytes((tone,))
                  and a['preset']==a_env and b==osc2_payload(b_bend,b_env),
                  dict(state=state,wave=actual_wave.hex(),tone=actual_tone.hex(),a_preset=a['preset'],b=b.hex()))
        first=link.note_on(0,69);second=link.note_on(1,69)
        check('two native sources retain the same MIDI independently',link.remote_note(0,2)['held']==1
              and link.remote_note(1,2)['held']==1 and link.status()['remote_mask']==3,dict(first=first,second=second))
        link.note_off(first)
        check('releasing one same-pitch source preserves the other',link.remote_note(0,2)['held']==0
              and link.remote_note(1,2)['held']==1 and link.status()['remote_mask']==2)
        link.note_off(second)
        stale=link.note_on(2,60);replacement=link.note_on(2,62)
        try:link.note_off(stale)
        except ProtocolRejected as error:check('stale native off rejected',error.status==2,str(error))
        else:check('stale native off rejected',False)
        check('stale off preserves replacement instance',link.remote_note(2,2)==replacement,replacement)
        link.note_off(replacement);time.sleep(0.35)
        receipts=[link.note_on(source,60+source%12) for source in range(32)]
        time.sleep(0.03)
        state=link.status();panel=link.performance()
        check('all 32 native sources held',state['remote_mask']==0xffffffff and state['active']==voices
              and panel['active_count']==voices and state['faults']==0,dict(status=state,panel=panel))
        check('all native source receipts remain current',all(link.remote_note(r['source'],2)==r for r in receipts))
        for _ in range(6):
            link.keepalive();time.sleep(0.22)
        state=link.status()
        check('native sustain across watchdog preserves pitch and instances',state['remote_mask']==0xffffffff
              and state['active']==voices and state['faults']==0
              and all(link.remote_note(r['source'],2)==r for r in receipts),state)
        for receipt in receipts:link.note_off(receipt)
        time.sleep(0.35);state=link.status()
        check('all native sources released',state['remote_mask']==0 and state['active']==0 and state['faults']==0,state)
        check('performance telemetry CRC and event continuity',link.decoder.errors==0 and link.gaps==0,
              dict(crc_errors=link.decoder.errors,event_gaps=link.gaps))
        return checks
    finally:
        try:link.silence_remote()
        finally:
            link.set_performance(original['root'],original['scale'],original['octave'],
                                 2 if original['timbre']==3 else original['timbre'])
            if original['timbre']==3:
                # SET_PERFORMANCE only accepts built-ins; restore custom patch
                # through its original explicit waveform/tone/envelope APIs.
                for kind,value in [(SET_WAVE,original_wave),(SET_TONE,original_tone),(SET_OSC2,original_b)]:
                    ack=link.request(kind,value)
                    if ack[1]:raise ProtocolRejected(kind,ack[1])
                link.params(4,original_a['volume'],original_a['bend'],original_a['preset'])
            time.sleep(0.35)
            restored=link.performance();quiet=link.status()
            check('original performance restored and remote audio idle',
                  all(restored[f]==original[f] for f in config_fields)
                  and quiet['remote_mask']==0 and quiet['active']==0 and quiet['faults']==0,
                  dict(performance=restored,status=quiet,scope='FPGA protocol/status only; I2S pads and acoustic output unmeasured'))


def soak(link,voices,seconds,native=False):
    if seconds<=0:raise ValueError('soak duration must be positive')
    mask=(1<<voices)-1;reads=0;previous_tick=None;worst_gap=0;report=None
    try:
        if native:
            if link.performance()['timbre']==4:
                raise ValueError('all-voice soak requires a polyphonic preset')
            link.silence_remote()
            receipts=[link.note_on(source,60+source) for source in range(voices)]
        start=time.monotonic();deadline=start+seconds
        while time.monotonic()<deadline:
            if native:link.keepalive()
            else:link.keys(mask)
            state=link.status();reads+=1
            # Only initial voice allocation may be incomplete; faults and a
            # lost held-key mask must fail even on the first status response.
            if state['faults'] or state['remote_mask']!=mask or (state['active']!=voices and reads>1):
                raise AssertionError(f'soak state: {state}')
            if previous_tick is not None:
                gap=(state['frame_counter']-previous_tick)&0xffffffff
                if gap==0:raise AssertionError('audio frame counter stalled')
                worst_gap=max(worst_gap,gap)
            previous_tick=state['frame_counter']
            time.sleep(min(0.15,max(0,deadline-time.monotonic())))
        if link.decoder.errors or link.gaps:raise AssertionError('soak telemetry CRC/sequence error')
        if native and any(link.remote_note(r['source'],2)!=r for r in receipts):
            raise AssertionError('soak native source pitch/instance changed')
        report=dict(passed=True,seconds=round(time.monotonic()-start,3),status_reads=reads,
                    max_frame_gap=worst_gap,final_status=state,scope='FPGA UART status/faults; I2S and acoustic output unmeasured')
        return report
    finally:
        if native:
            link.silence_remote();time.sleep(0.35)
            if report is not None:
                idle=link.status()
                if idle['active'] or idle['remote_mask'] or idle['faults']:
                    raise AssertionError(f'soak release failed: {idle}')
                if link.decoder.errors or link.gaps:
                    raise AssertionError('soak cleanup telemetry CRC/sequence error')
                report['idle_status']=idle
        else:link.keys(0)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',required=True)
    parser.add_argument('--voices',type=int,choices=[4,8,16,32],default=4)
    parser.add_argument('--independent-osc',action='store_true',help='Validate dual DDS control extensions')
    parser.add_argument('--soak-seconds',type=float,default=0,help='Keep all voice slots active and check status/faults')
    parser.add_argument('--acceptance',action='store_true')
    parser.add_argument('--performance',action='store_true',help='Read performance state; with --acceptance, validate native notes and patch/configuration contracts')
    parser.add_argument('--inputs',action='store_true',help='Read synchronized raw pins and debounced input mask')
    parser.add_argument('--expression',action='store_true',help='Read ADC diagnostics and X/Y calibration; channel 0 is reserved')
    parser.add_argument('--guide',action='store_true',help='Read offline guide config, progress and delivered LED state')
    parser.add_argument('--set-guide',nargs=4,type=int,metavar=('ENABLE','SONG','TEMPO','ACTION'),help='Volatile guide: song 0/1; tempo 0..3=60/90/120/150 BPM; action 0=pause 1=start 2=rewind')
    parser.add_argument('--calibrate',nargs=4,type=int,metavar=('CHANNEL','LOW','CENTRE','HIGH'),help='Volatile signed joystick calibration; channel 1=X, 2=Y; pressure removed')
    parser.add_argument('--enable-expression',action='store_true',help='With --calibrate, explicitly enable this sensor; otherwise it stays disabled')
    parser.add_argument('--invert-x',action='store_true',help='With --calibrate 1, reverse X bend')
    parser.add_argument('--direct',action='store_true',help='Already bridged / external adapter; skip BL616 console selection')
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    if args.performance and args.independent_osc:parser.error('--performance uses its own patch readback checks; omit --independent-osc')
    if (args.enable_expression or args.invert_x) and not args.calibrate:parser.error('expression enable/inversion requires --calibrate')
    if args.calibrate:
        if args.calibrate[0] not in (1,2):parser.error('Pressure control was removed; calibrate joystick channels 1/2 only')
        try:expression_payload(*args.calibrate,enable=args.enable_expression,invert_x=args.invert_x)
        except ValueError as error:parser.error(str(error))
    if args.set_guide:
        try:guide_payload(*args.set_guide)
        except ValueError as error:parser.error(str(error))
    import serial
    folder=f'performance_usb_{args.voices}' if args.performance else f'app_usb_{args.voices}'
    output=args.output or ROOT/'build'/folder/('usb_acceptance_'+datetime.now().strftime('%Y%m%d_%H%M%S')+'.json')
    output.parent.mkdir(parents=True,exist_ok=True)
    report=dict(source='FPGA live UART control/status; I2S pads, speaker and BLE latency unmeasured',port=args.port,success=False)
    link=None
    try:
        with serial.Serial(args.port,115200,timeout=0.05,write_timeout=1) as port:
            if not args.direct:
                # Explicit shell selection; no firmware/clock setting is changed.
                select_bridge(port,'uart')
            link=DeviceLink(port)
            if args.set_guide:link.set_guide(*args.set_guide)
            if args.calibrate:link.set_expression(*args.calibrate,enable=args.enable_expression,invert_x=args.invert_x)
            if args.performance:
                if args.acceptance:report['performance_checks']=performance_acceptance(link,voices=args.voices)
                report['hello']=link.request(HELLO,response=HELLO_REPLY).hex()
                report['performance']=link.performance();report['key_pitches']=link.key_pitches();report['status']=link.status()
            elif args.acceptance:report['checks']=acceptance(link,voices=args.voices)
            if args.independent_osc:report['oscillator_checks']=independent_acceptance(link,args.voices)
            if args.soak_seconds:report['soak']=soak(link,args.voices,args.soak_seconds,native=args.performance)
            if not args.performance and not args.acceptance and not args.independent_osc and not args.soak_seconds:
                report['hello']=link.request(HELLO,response=HELLO_REPLY).hex();report['status']=link.status()
            if args.inputs:report['inputs']=parse_inputs(link.request(GET_INPUTS,response=INPUTS))
            if args.expression or args.calibrate:report['expression']=[link.expression(channel) for channel in range(3)]
            if args.guide or args.set_guide:report['guide']=link.guide()
            report['success']=True
    except Exception as error:
        report['error']=f'{type(error).__name__}: {error}'
    if link:
        report['transcript']=link.transcript;report['events']=len(link.events)
        report['decoder_errors']=link.decoder.errors;report['event_gaps']=link.gaps
    output.write_text(json.dumps(report,indent=2,ensure_ascii=False),encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='transcript'},indent=2,ensure_ascii=False));print('Report:',output)
    raise SystemExit(0 if report['success'] else 1)

if __name__=='__main__':main()
