import argparse
import contextlib
import io
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import build_gowin as build

def options(performance=False):
    return SimpleNamespace(voices=32,led=False,app=True,transport='usb',no_controls=True,
        waveform=0,tremolo=False,delay=False,dc_block=False,live_tone=False,live_wave=False,
        dual_osc=False,independent_osc=False,osc2_waveform=0,osc2_detune_shift=7,
        osc2_separate_rom=False,timing_opt=False,performance=performance)

class PerformanceBuildTests(unittest.TestCase):
    def test_performance_selects_required_existing_audio_paths(self):
        a=options(True);build.normalize_audio_options(a,argparse.ArgumentParser())
        self.assertTrue(a.independent_osc and a.dual_osc and a.live_wave and a.live_tone)
        self.assertTrue(build.build_options(a)['performance'])
        self.assertNotEqual(build.build_label(a),build.build_label(options(False)))

    def test_performance_requires_protocol_top(self):
        a=options(True);a.app=False
        with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit) as error:
            build.normalize_audio_options(a,argparse.ArgumentParser())
        self.assertEqual(error.exception.code,2)

    def test_old_callers_without_flag_keep_compatible_profile(self):
        a=options(False);del a.performance
        build.normalize_audio_options(a,argparse.ArgumentParser())
        self.assertFalse(build.build_options(a)['performance'])
        self.assertEqual(build.build_label(a),'app_usb_32_unwired')

if __name__=='__main__':unittest.main()
