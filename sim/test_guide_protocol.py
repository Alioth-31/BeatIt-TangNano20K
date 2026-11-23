"""Literal guide wire fixtures and build identity; no Android dependency."""
import argparse
import struct
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
sys.path.insert(0,str(Path(__file__).resolve().parent))
import device_link as p
import build_gowin as build
from test_performance_protocol import PlannedPort
from test_performance_build import options

class GuideProtocolTests(unittest.TestCase):
    def test_configuration_and_actual_delivery_status(self):
        request=bytes.fromhex('01 01 02 01')
        response=bytes.fromhex('01 01 02 07 00 15 15 04 80 02 03 00 01 00 34 12')
        self.assertEqual(p.guide_payload(1,1,2,1),request)
        peer=PlannedPort([(0x28,request,0x80,b'\x28\x00'),(0x29,b'',0x8d,response)])
        link=p.DeviceLink(peer);link.set_guide(1,1,2,1);state=link.guide()
        self.assertEqual((state['target_keys'],state['led_target'],state['led_applied']),(0x15,0x15,4))
        self.assertEqual((state['missed'],state['wrong'],state['revision']),(2,3,0x1234))
        self.assertTrue(state['running'] and state['ready'] and state['compatible'])
        self.assertFalse(state['done']);self.assertFalse(peer.plan)

    def test_invalid_ranges_and_unsupported_reply(self):
        for args in [(2,0,0,0),(0,2,0,0),(0,0,4,0),(0,0,0,3),(-1,0,0,0)]:
            with self.subTest(args=args),self.assertRaises(ValueError):p.guide_payload(*args)
        valid=bytearray.fromhex('01 01 02 07 00 15 15 04 80 02 03 00 01 00 34 12')
        for index,value in ((0,2),(1,2),(2,4),(3,16),(4,16),(11,6),(12,2),(13,2)):
            bad=valid.copy();bad[index]=value
            with self.subTest(index=index),self.assertRaises(ValueError):p.parse_guide(bad)
        with self.assertRaises(ValueError):p.parse_guide(valid[:-1])
        peer=PlannedPort([(0x29,b'',0x80,b'\x29\x03')])
        with self.assertRaises(p.ProtocolRejected):p.DeviceLink(peer).guide()

    def test_expanded_panel_field_in_existing_state(self):
        response=struct.pack('<10BHI2B',0,0,4,0,1,5,2,0,0,0,1,100,0,0)
        self.assertEqual(p.parse_performance(response)['selected_field'],5)

    def test_build_flag_and_standalone_telemetry(self):
        parser=argparse.ArgumentParser();build.add_audio_options(parser)
        self.assertTrue(parser.parse_args(['--guide']).guide)
        for hdmi in (False,True):
            a=options(True);a.hdmi=hdmi;a.peripherals=True;a.guide=True
            build.normalize_audio_options(a,parser)
            self.assertTrue(build.build_options(a)['guide']);self.assertIn('_guide',build.build_label(a))
            name='nano20k_hdmi_top.v' if hdmi else 'nano20k_app_top.v'
            staged=build.staged_source('rtl/'+name,(build.ROOT/'rtl'/name).read_bytes(),a)
            self.assertIn(b'parameter GUIDE_ENABLED=1',staged)
            if not hdmi:self.assertNotIn(b'display_state',staged.split(b');',1)[0])
        for performance,peripherals in ((False,True),(True,False)):
            a=options(performance);a.peripherals=peripherals;a.guide=True
            with self.assertRaises(SystemExit):build.normalize_audio_options(a,parser)

if __name__=='__main__':unittest.main()
