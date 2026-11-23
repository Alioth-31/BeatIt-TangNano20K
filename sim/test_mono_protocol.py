import argparse
import struct
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import device_link as link
import build_gowin as build


class MonoProtocolTests(unittest.TestCase):
    def test_explicit_patch_and_capability_roundtrip(self):
        self.assertEqual(link.performance_payload(0,0,4,4),b'\0\0\4\4')
        payload=struct.pack('<10BHI2B',0,0,4,4,4,0,4,1,1,1,7,123,0,0)
        state=link.parse_performance(payload)
        self.assertEqual((state['timbre'],state['flags']),(4,4))
        with self.assertRaises(ValueError):link.performance_payload(0,0,4,3)
        with self.assertRaises(ValueError):link.parse_performance(payload[:4]+b'\0'+payload[5:])

    def test_mono_build_is_explicit_and_guarded(self):
        p=argparse.ArgumentParser();build.add_audio_options(p)
        a=p.parse_args(['--mono','--performance'])
        a.app=True;a.led=False;a.transport='usb';a.voices=32;a.no_controls=True
        build.normalize_audio_options(a,p)
        self.assertTrue(build.build_options(a)['mono'])
        self.assertIn('_mono',build.build_label(a))


if __name__=='__main__':unittest.main()
