"""Literal wire fixtures for the optional, volatile sensor calibration extension."""
import argparse
import struct
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_link as p
import build_gowin as build
from test_performance_protocol import PlannedPort
from test_performance_build import options

class ExpressionProtocolTests(unittest.TestCase):
    def test_signed_literal_request_and_reply(self):
        request=bytes.fromhex('01 03 9c ff bc 02 40 06')
        reply=bytes.fromhex('01 3f 56 04 9c ff bc 02 40 06 01 55 00 00')
        self.assertEqual(p.expression_payload(1,-100,700,1600,True,True),request)
        peer=PlannedPort([(0x26,request,0x80,b'\x26\x00'),(0x27,b'\x01',0x8c,reply)])
        link=p.DeviceLink(peer)
        link.set_expression(1,-100,700,1600,enable=True,invert_x=True)
        state=link.expression(1)
        self.assertEqual((state['low'],state['centre'],state['high'],state['raw']),(-100,700,1600,1110))
        self.assertTrue(state['active'] and state['calibrated'] and state['enabled'] and state['invert_x'])
        self.assertEqual(state['led_applied'],0x55)
        self.assertFalse(peer.plan)

    def test_default_calibration_does_not_enable_sensor(self):
        self.assertEqual(p.expression_payload(0,100,0,1600),bytes.fromhex('00 00 64 00 00 00 40 06'))

    def test_invalid_settings_and_rejections(self):
        for values in [(3,0,500,1000),(0,0,1,1000),(0,0,0,63),(1,-2049,0,2047),(1,-2048,0,2048),(2,0,79,1000)]:
            with self.subTest(values=values),self.assertRaises(ValueError):p.expression_payload(*values)
        with self.assertRaises(ValueError):p.expression_payload(2,0,500,1000,invert_x=True)
        peer=PlannedPort([(0x27,b'\x00',0x80,b'\x27\x03')])
        with self.assertRaises(p.ProtocolRejected):p.DeviceLink(peer).expression(0)
        for reply in (bytes(13),struct.pack('<BBhhhhBBBB',0,0,2048,0,0,0,0,0,0,0)):
            with self.assertRaises(ValueError):p.parse_expression(reply)

    def test_build_identity_and_primitive_mapping(self):
        for hdmi in (False,True):
            a=options(True);a.hdmi=hdmi;a.peripherals=True
            build.normalize_audio_options(a,argparse.ArgumentParser())
            self.assertTrue(build.build_options(a)['peripherals'])
            self.assertIn('_expr',build.build_label(a))
            name='nano20k_hdmi_top.v' if hdmi else 'nano20k_app_top.v'
            staged=build.staged_source('rtl/'+name,(build.ROOT/'rtl'/name).read_bytes(),a)
            self.assertIn(b'parameter PERIPHERALS_ENABLED=1',staged)
            for module in ('pitch_modulation','expression_mix'):
                self.assertTrue(build.staged_source('rtl/'+module+'.v',b'// module\n',a).startswith(b'`define GOWIN_PRIMITIVES\n'))

if __name__=='__main__':unittest.main()
