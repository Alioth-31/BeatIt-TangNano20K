"""Literal performance wire fixtures; no serial device is opened."""
import sys
from pathlib import Path
import unittest
import struct
import json
import io
from contextlib import redirect_stdout,redirect_stderr
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import device_link as p


class PlannedPort:
    """A finite UART peer: answers only after the corresponding request."""
    def __init__(self,plan):
        self.plan=list(plan);self.buffer=bytearray();self.reads=0
    @property
    def in_waiting(self):return len(self.buffer)
    def write(self,wire):
        kind,sequence,payload=p.Decoder().feed(wire)[0]
        expected_kind,expected_payload,response_kind,response_payload=self.plan.pop(0)
        if (kind,payload)!=(expected_kind,expected_payload):
            raise AssertionError(f'unexpected request {(kind,payload)!r}')
        self.buffer.extend(p.encode(response_kind,sequence,response_payload))
        return len(wire)
    def flush(self):pass
    def read(self,count):
        self.reads+=1
        if not self.buffer:raise AssertionError('host waited after explicit rejection')
        out=bytes(self.buffer[:count]);del self.buffer[:count];return out


class ContractDevice:
    """Independent appliance state for exercising the acceptance/cleanup flow."""
    def __init__(self,fail_native=False,custom=False):
        self.config=[0,0,4,3 if custom else 0];self.revision=7
        self.patch=[2,3,1,0,-7] if custom else [0,0,2,2,0]
        self.notes=[dict(source=s,held=0,midi=0,instance=0) for s in range(32)]
        self.fail_native=fail_native;self.decoder=p.Decoder();self.gaps=0;self.transcript=[];self.events=[]
    def performance(self):
        return dict(zip(('root','scale','octave','timbre'),self.config),flags=0,
            selected_field=0,preview_value=0,play_keys=0,physical_debounced=0,
            active_count=sum(n['held'] for n in self.notes),revision=self.revision,
            frame_counter=99,hardware_available=0,reserved=0)
    def status(self):
        return dict(active=sum(n['held'] for n in self.notes),faults=0,
            remote_mask=sum(n['held']<<n['source'] for n in self.notes),physical_mask=0,
            volume=16384,bend=0,preset=self.patch[2],frame_counter=99)
    def key_pitches(self):
        degrees=((0,2,4,5,7,9,11,12),(0,2,3,5,7,8,10,12),tuple(range(8)))[self.config[1]]
        return dict(revision=self.revision,midi=[12*(self.config[2]+1)+self.config[0]+d for d in degrees])
    def set_performance(self,root,scale,octave,timbre):
        self.config=[root,scale,octave,timbre];self.revision=(self.revision+1)&65535
        self.patch=list(((0,0,2,2,0),(1,1,1,1,2),(3,2,0,2,-2),None,(3,1,2,2,0))[timbre])
    def request(self,kind,payload=b'',response=0x80,timeout=2):
        if kind==1:return bytes.fromhex('01 20 ff 80 bb 00 00 ff ff ff ff 01 01')
        if kind==0x20:
            if len(payload)!=4 or payload[0]>11 or payload[1]>2 or not 2<=payload[2]<=6 or payload[3]>2:return b'\x20\x01'
            self.set_performance(*payload);return b'\x20\x00'
        if kind==0x11:return b'\x11\x03'
        if kind==4:return bytes([self.patch[1]])
        if kind==5:return bytes([self.patch[0]])
        if kind==6:return struct.pack('<bB',self.patch[4],self.patch[3])
        if kind in (0x14,0x15):
            self.patch[1 if kind==0x14 else 0]=payload[0];self.config[3]=3
        elif kind==0x16:
            self.patch[4],self.patch[3]=struct.unpack('<bB',payload);self.config[3]=3
        else:raise AssertionError(f'unexpected contract request {kind}')
        return bytes((kind,0))
    def params(self,fields,volume,bend,preset):
        if fields&4:self.patch[2]=preset;self.config[3]=3
    def remote_note(self,source,action,midi=0,instance=0):
        note=self.notes[source]
        if action==2:return dict(note)
        if action==0:
            if instance!=note['instance']:raise p.ProtocolRejected(0x21,2)
            note['held']=0
        else:
            if instance!=(note['instance']+1)&65535:raise p.ProtocolRejected(0x21,2)
            note.update(held=1,midi=midi,instance=instance)
        return dict(note)
    def note_on(self,source,midi):
        note=self.remote_note(source,1,midi,(self.notes[source]['instance']+1)&65535)
        if self.fail_native and source==1:
            self.fail_native=False;raise RuntimeError('injected native-note failure')
        return note
    def note_off(self,receipt):return self.remote_note(receipt['source'],0,receipt['midi'],receipt['instance'])
    def silence_remote(self):
        for note in self.notes:note['held']=0
    def keepalive(self):
        return None


class PerformanceProtocolTests(unittest.TestCase):
    def test_performance_cli_soak_uses_native_notes_and_cleans_up_failures(self):
        class SoakDevice(ContractDevice):
            def __init__(self, failure):
                super().__init__(fail_native=failure=='allocation')
                self.failure=failure;self.reads=0;self.refreshes=0;self.native_sources=set()
            def keys(self, mask):
                # RTL retains SET_KEYS compatibility, restoring its fixed map
                # and replacing native instances on a native-to-legacy switch.
                for source,note in enumerate(self.notes):
                    held=(mask>>source)&1
                    if held and (not note['held'] or source in self.native_sources):
                        midi=(60,62,64,65,67,69,71,72)[source] if source<8 else 28+source
                        note.update(midi=midi,instance=(note['instance']+1)&65535)
                    note['held']=held
                self.native_sources.clear()
            def keepalive(self):
                self.refreshes+=1
                if self.failure=='crc':self.decoder.errors+=1
                if self.failure=='event_gap':self.gaps+=1
            def remote_note(self,source,action,midi=0,instance=0):
                note=super().remote_note(source,action,midi,instance)
                if action==1:self.native_sources.add(source)
                if action==2 and note['held'] and self.failure=='token':note['instance']+=1
                return note
            def silence_remote(self):
                if self.failure=='cleanup_crc' and any(n['held'] for n in self.notes):self.decoder.errors+=1
                super().silence_remote()
            def status(self):
                state=super().status();self.reads+=1
                state['frame_counter']=self.reads*7200
                if state['active'] and self.failure=='fault':state['faults']=1
                if state['active'] and self.failure=='mask':state['remote_mask']=0
                if state['active'] and self.failure=='stalled':state['frame_counter']=1
                return state
        output_root=Path(__file__).resolve().parents[1]/'build/closure'
        output_root.mkdir(parents=True,exist_ok=True)
        for failure in (None,'allocation','fault','mask','stalled','token','crc','event_gap','cleanup_crc'):
            with self.subTest(failure=failure):
                link=SoakDevice(failure);clock=[0.0]
                def sleep(seconds):clock[0]+=seconds
                output=output_root/f'cli-performance-soak-{failure}.json'
                argv=['device_link.py','--port','memory','--direct','--voices','32','--performance',
                      '--soak-seconds','0.4','--output',str(output)]
                with patch.object(sys,'argv',argv),patch('serial.Serial'),patch.object(p,'DeviceLink',return_value=link),\
                     patch.object(p.time,'monotonic',side_effect=lambda:clock[0]),patch.object(p.time,'sleep',side_effect=sleep),\
                     redirect_stdout(io.StringIO()),redirect_stderr(io.StringIO()),self.assertRaises(SystemExit) as exited:
                    p.main()
                report=json.loads(output.read_text(encoding='utf-8'))
                if failure is None:
                    self.assertEqual(exited.exception.code,0,report.get('error'))
                    self.assertTrue(report['soak']['passed']);self.assertGreater(link.refreshes,1)
                    self.assertEqual([n['midi'] for n in link.notes],list(range(60,92)))
                else:
                    self.assertNotEqual(exited.exception.code,0)
                    self.assertFalse(report['success'])
                self.assertFalse(any(n['held'] for n in link.notes))

    def test_native_keepalive_uses_empty_request_and_checks_ack(self):
        port=PlannedPort([(0x22,b'',0x80,b'\x22\x00')])
        p.DeviceLink(port).keepalive()
        self.assertFalse(port.plan)
        port=PlannedPort([(0x22,b'',0x80,b'\x22\x03')])
        with self.assertRaises(p.ProtocolRejected) as error:p.DeviceLink(port).keepalive()
        self.assertEqual(error.exception.status,3)

    def test_configuration_request_has_exact_four_byte_contract(self):
        self.assertEqual(p.performance_payload(2,0,4,1),bytes.fromhex('02 00 04 01'))
        for values in [(-1,0,4,0),(12,0,4,0),(0,3,4,0),(0,0,1,0),(0,0,7,0),(0,0,4,3)]:
            with self.subTest(values=values),self.assertRaises(ValueError):p.performance_payload(*values)

    def test_status_18_byte_fixture_keeps_revision_and_frame_endianness(self):
        payload=bytes.fromhex('02 01 04 03 03 02 06 81 83 20 34 12 78 56 34 12 00 00')
        self.assertEqual(p.parse_performance(payload),dict(root=2,scale=1,octave=4,timbre=3,flags=3,
            selected_field=2,preview_value=6,play_keys=0x81,physical_debounced=0x83,
            active_count=32,revision=0x1234,frame_counter=0x12345678,hardware_available=0,reserved=0))
        for index,value in [(0,12),(1,3),(2,1),(3,4),(4,8),(5,6),(9,33),(16,1),(17,1)]:
            bad=bytearray(payload);bad[index]=value
            with self.subTest(index=index),self.assertRaises(ValueError):p.parse_performance(bad)
        with self.assertRaises(ValueError):p.parse_performance(payload[:-1])

    def test_key_pitch_reply_is_revision_then_eight_midi_notes(self):
        payload=bytes.fromhex('ff ff 3e 40 42 43 45 47 49 4a')
        self.assertEqual(p.parse_key_pitches(payload),dict(revision=65535,midi=[62,64,66,67,69,71,73,74]))
        with self.assertRaises(ValueError):p.parse_key_pitches(payload[:-1])
        with self.assertRaises(ValueError):p.parse_key_pitches(payload[:-1]+b'\x80')

    def test_native_note_contract_validates_source_action_midi_and_token(self):
        self.assertEqual(p.remote_note_payload(31,1,127,65535),bytes.fromhex('1f 01 7f 00 ff ff'))
        self.assertEqual(p.parse_remote_note(bytes.fromhex('1f 01 7f ff ff')),
                         dict(source=31,held=1,midi=127,instance=65535))
        for values in [(32,1,60,1),(0,3,60,1),(0,1,128,1),(0,1,60,65536),(0,1,60,-1)]:
            with self.subTest(values=values),self.assertRaises(ValueError):p.remote_note_payload(*values)
        for payload in [b'',bytes.fromhex('20 01 3c 01 00'),bytes.fromhex('00 02 3c 01 00'),bytes.fromhex('00 01 80 01 00')]:
            with self.subTest(payload=payload),self.assertRaises(ValueError):p.parse_remote_note(payload)

    def test_read_command_error_ack_is_reported_immediately(self):
        for kind,response in [(2,0x82),(0x24,0x89),(0x25,0x8b),(0x21,0x8a)]:
            port=PlannedPort([(kind,b'',0x80,bytes((kind,3)))])
            with self.subTest(kind=kind),self.assertRaises(p.ProtocolRejected) as raised:
                p.DeviceLink(port).request(kind,response=response)
            self.assertEqual((raised.exception.kind,raised.exception.status),(kind,3))
            self.assertEqual(port.reads,1)

    def test_legacy_ack_api_still_returns_status_for_expected_rejection(self):
        port=PlannedPort([(0x11,bytes(range(8)),0x80,bytes((0x11,3)))])
        self.assertEqual(p.DeviceLink(port).request(0x11,bytes(range(8))),bytes((0x11,3)))

    def test_configuration_methods_use_assigned_commands_and_parse_responses(self):
        status=bytes.fromhex('02 00 04 01 00 00 01 00 00 00 02 00 00 10 00 00 00 00')
        port=PlannedPort([(0x20,b'\x02\x00\x04\x01',0x80,b'\x20\x00'),
            (0x24,b'',0x89,status),(0x25,b'',0x8b,bytes.fromhex('02 00 3e 40 42 43 45 47 49 4a'))])
        link=p.DeviceLink(port);link.set_performance(2,0,4,1)
        self.assertEqual(link.performance()['timbre'],1)
        self.assertEqual(link.key_pitches()['midi'],[62,64,66,67,69,71,73,74])
        self.assertEqual(port.plan,[])

    def test_rejected_configuration_raises_structured_status(self):
        link=p.DeviceLink(PlannedPort([(0x20,b'\x02\x00\x04\x01',0x80,b'\x20\x02')]))
        with self.assertRaises(p.ProtocolRejected) as raised:link.set_performance(2,0,4,1)
        self.assertEqual(raised.exception.status,2)

    def test_note_on_queries_current_instance_and_wraps_then_off_uses_receipt(self):
        port=PlannedPort([(0x21,bytes.fromhex('03 02 00 00 00 00'),0x8a,bytes.fromhex('03 00 3c ff ff')),
            (0x21,bytes.fromhex('03 01 45 00 00 00'),0x8a,bytes.fromhex('03 01 45 00 00')),
            (0x21,bytes.fromhex('03 00 45 00 00 00'),0x8a,bytes.fromhex('03 00 45 00 00'))])
        link=p.DeviceLink(port);receipt=link.note_on(3,69)
        self.assertEqual(receipt,dict(source=3,held=1,midi=69,instance=0))
        self.assertEqual(link.note_off(receipt)['held'],0)
        self.assertEqual(port.plan,[])

    def test_stale_off_error_preserves_replacement_receipt(self):
        port=PlannedPort([(0x21,bytes.fromhex('00 00 3c 00 01 00'),0x80,b'\x21\x02'),
            (0x21,bytes.fromhex('00 02 00 00 00 00'),0x8a,bytes.fromhex('00 01 3e 02 00'))])
        link=p.DeviceLink(port)
        with self.assertRaises(p.ProtocolRejected) as raised:
            link.note_off(dict(source=0,held=1,midi=60,instance=1))
        self.assertEqual(raised.exception.status,2)
        self.assertEqual(link.remote_note(0,2),dict(source=0,held=1,midi=62,instance=2))

    def test_wrong_source_or_on_receipt_is_rejected(self):
        for reply in [bytes.fromhex('01 01 3c 01 00'),bytes.fromhex('00 00 3c 01 00'),bytes.fromhex('00 01 3e 01 00'),bytes.fromhex('00 01 3c 02 00')]:
            link=p.DeviceLink(PlannedPort([(0x21,bytes.fromhex('00 01 3c 00 01 00'),0x8a,reply)]))
            with self.subTest(reply=reply),self.assertRaises(ValueError):link.remote_note(0,1,60,1)

    def test_directed_acceptance_checks_contract_then_restores_configuration_and_silence(self):
        link=ContractDevice()
        with patch.object(p.time,'sleep'):
            checks=p.performance_acceptance(link,voices=32)
        self.assertTrue(checks and all(c['passed'] for c in checks))
        self.assertTrue(any(c['name']=='all 32 native sources held' for c in checks))
        self.assertEqual(link.config,[0,0,4,0]);self.assertFalse(any(n['held'] for n in link.notes))

    def test_acceptance_restores_explicit_mono_patch(self):
        link=ContractDevice();link.set_performance(0,0,4,4)
        with patch.object(p.time,'sleep'):
            checks=p.performance_acceptance(link,voices=32)
        self.assertEqual(link.config,[0,0,4,4])
        self.assertTrue(all(c['passed'] for c in checks))

    def test_failed_acceptance_also_restores_custom_patch_and_silence(self):
        link=ContractDevice(fail_native=True,custom=True)
        with patch.object(p.time,'sleep'),self.assertRaisesRegex(RuntimeError,'injected native'):
            p.performance_acceptance(link,voices=32)
        self.assertEqual(link.config,[0,0,4,3]);self.assertEqual(link.patch,[2,3,1,0,-7])
        self.assertFalse(any(n['held'] for n in link.notes))

    def test_performance_cli_selects_new_acceptance_and_keeps_status_only_mode_read_only(self):
        output_root=Path(__file__).resolve().parents[1]/'build/closure';output_root.mkdir(parents=True,exist_ok=True)
        for acceptance in (False,True):
            link=ContractDevice()
            with self.subTest(acceptance=acceptance):
                output=output_root/('cli-performance-acceptance-test.json' if acceptance else 'cli-performance-status-test.json')
                argv=['device_link.py','--port','memory','--direct','--voices','32','--performance','--output',str(output)]
                if acceptance:argv.append('--acceptance')
                with patch.object(sys,'argv',argv),patch('serial.Serial'),patch.object(p,'DeviceLink',return_value=link),\
                     patch.object(p,'acceptance',side_effect=AssertionError('legacy SET_MAP acceptance selected')),\
                     patch.object(p.time,'sleep'),redirect_stdout(io.StringIO()),redirect_stderr(io.StringIO()),\
                     self.assertRaises(SystemExit) as exited:
                    p.main()
                self.assertEqual(exited.exception.code,0)
                report=json.loads(output.read_text(encoding='utf-8'))
                self.assertTrue(report['success']);self.assertIn('performance',report);self.assertIn('key_pitches',report)
                self.assertEqual('performance_checks' in report,acceptance)
                self.assertNotIn('checks',report)
                if not acceptance:self.assertEqual(link.revision,7)


if __name__=='__main__':unittest.main()
