"""Host codec fixtures also used by the real USB acceptance runner."""
import sys
from pathlib import Path
import unittest
import io
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import device_link as p

class ProtocolTests(unittest.TestCase):
    def test_soak_rejects_first_fault_or_wrong_mask(self):
        class Link:
            def __init__(self,state):
                self.state=state;self.sent=[];self.gaps=0
                self.decoder=p.Decoder()
            def keys(self,mask):self.sent.append(mask)
            def status(self):return self.state
        for state in [dict(active=32,faults=1,remote_mask=0xffffffff,frame_counter=1),
                      dict(active=32,faults=0,remote_mask=0,frame_counter=1)]:
            link=Link(state)
            clock=[0.0]
            def sleep(seconds):clock[0]+=seconds
            with patch.object(p.time,'monotonic',side_effect=lambda:clock[0]),patch.object(p.time,'sleep',side_effect=sleep):
                with self.assertRaises(AssertionError):p.soak(link,32,0.05)
            self.assertEqual(link.sent[-1],0)

    def test_soak_allows_initial_allocation_and_requires_progress(self):
        class Link:
            def __init__(self,stalled=False):
                self.sent=[];self.reads=0;self.gaps=0;self.decoder=p.Decoder();self.stalled=stalled
            def keys(self,mask):self.sent.append(mask)
            def status(self):
                self.reads+=1
                return dict(active=0 if self.reads==1 else 32,faults=0,remote_mask=0xffffffff,
                            frame_counter=1 if self.stalled else self.reads*7200)
        for stalled in [False,True]:
            link=Link(stalled);clock=[0.0]
            def sleep(seconds):clock[0]+=seconds
            with patch.object(p.time,'monotonic',side_effect=lambda:clock[0]),patch.object(p.time,'sleep',side_effect=sleep):
                if stalled:
                    with self.assertRaisesRegex(AssertionError,'stalled'):p.soak(link,32,0.2)
                else:self.assertTrue(p.soak(link,32,0.2)['passed'])
            self.assertEqual(link.sent[-1],0)

    def test_input_telemetry_distinguishes_raw_from_debounced(self):
        self.assertEqual(p.parse_inputs(bytes([0xfd,0x02])),dict(raw_keys_n=0xfd,debounced_held=2))
        with self.assertRaises(ValueError):p.parse_inputs(bytes(1))
    def test_response_and_later_event_in_same_read_are_both_retained(self):
        class MemoryPort:
            def __init__(self,data):self.input=io.BytesIO(data)
            @property
            def in_waiting(self):return len(self.input.getbuffer())-self.input.tell()
            def read(self,count):return self.input.read(count)
            def write(self,data):return len(data)
            def flush(self):pass
        event=bytes.fromhex('01 00 00 00 ff ff e0 02')
        port=MemoryPort(p.encode(p.ACK,0,bytes([p.SET_PARAMS,0]))+p.encode(p.PARAM_EVENT,5,event))
        link=p.DeviceLink(port)
        self.assertEqual(link.request(p.SET_PARAMS,p.params_payload(7,65535,-32,2)),bytes([p.SET_PARAMS,0]))
        self.assertEqual(link.events,[(p.PARAM_EVENT,5,event)])

    def test_crc_reference(self):
        self.assertEqual(p.crc16(b'123456789'),0x29b1)

    def test_independent_controls_validate_signed_bend_and_slot_identity(self):
        self.assertEqual(p.osc2_payload(-32,2),bytes([224,2]))
        self.assertEqual(p.osc_test_payload(32,1,39370534,voices=4),bytes([32,1])+int(39370534).to_bytes(4,'little'))
        for values in [(4,1,1,4),(36,2,0,4),(64,0,0,32),(0,4,0,32),(0,1,0,32)]:
            with self.assertRaises(ValueError):p.osc_test_payload(*values)
        for values in [(-33,0),(0,3)]:
            with self.assertRaises(ValueError):p.osc2_payload(*values)

    def test_wire_fixture_and_signed_params(self):
        frame=p.encode(0x12,0x1234,b'\x55\x00\x00\x80')
        self.assertEqual(frame[:7],bytes.fromhex('a5 5a 01 12 34 12 04'))
        self.assertEqual(p.params_payload(7,65535,-32,2),bytes.fromhex('07 ff ff e0 02'))
        self.assertEqual(p.Decoder().feed(frame),[(0x12,0x1234,b'\x55\x00\x00\x80')])

    def test_fragmented_noise_crc_recovery(self):
        good=p.encode(0x81,7,b'\x01')
        bad=bytearray(p.encode(0x82,8,b'\x01')); bad[-1]^=1
        decoder=p.Decoder()
        self.assertEqual(decoder.feed(b'noise'+bad+good[:3]),[])
        self.assertEqual(decoder.feed(good[3:]),[(0x81,7,b'\x01')])
        self.assertGreaterEqual(decoder.errors,1)

    def test_lengths_and_ranges(self):
        for values in [(0,0,0,0),(8,0,0,0),(1,65536,0,0),(2,0,-33,0),(4,0,0,3)]:
            with self.assertRaises(ValueError): p.params_payload(*values)
        with self.assertRaises(ValueError):p.encode(1,0,bytes(65))
        decoder=p.Decoder()
        self.assertEqual(decoder.feed(bytes.fromhex('a5 5a 01 12 00 00 ff')+p.encode(1,9,b'')),[(1,9,b'')])

    def test_status_wire_full_scale_negative_and_masks(self):
        payload=bytes.fromhex('04 00 55 00 00 80 20 00 00 00 ff ff e0 02 78 56 34 12')
        status=p.parse_status(payload)
        self.assertEqual(status,dict(active=4,faults=0,remote_mask=0x80000055,physical_mask=32,
                                     volume=65535,bend=-32,preset=2,frame_counter=0x12345678))
        with self.assertRaises(ValueError):p.parse_status(payload[:17])
        corrupt=bytearray(payload);corrupt[12]=33
        with self.assertRaises(ValueError):p.parse_status(corrupt)

if __name__=='__main__':unittest.main()
