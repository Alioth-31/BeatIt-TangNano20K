"""The build/download identity must distinguish a reverb-enabled image."""
import argparse
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_performance_build import options
import build_gowin as build

class ReverbBuildTests(unittest.TestCase):
    def test_reverb_option_and_source_are_bound_to_image_identity(self):
        for hdmi in (False, True):
            a = options(True)
            a.hdmi = hdmi
            a.reverb = True
            build.normalize_audio_options(a, argparse.ArgumentParser())
            self.assertTrue(build.build_options(a)['reverb'])
            self.assertIn('_rev', build.build_label(a))
            name = 'nano20k_hdmi_top.v' if hdmi else 'nano20k_app_top.v'
            staged = build.staged_source('rtl/'+name, (build.ROOT/'rtl'/name).read_bytes(), a)
            self.assertIn(b'parameter FX_REVERB_ENABLE=1', staged)
            if not hdmi:
                header = staged.split(b');', 1)[0]
                self.assertNotIn(b'display_state', header, 'standalone app must not allocate telemetry GPIOs')
            self.assertTrue(build.staged_source('rtl/pcm_reverb.v', b'// reverb\n', a).startswith(b'`define GOWIN_PRIMITIVES\n'))

    def test_reverb_defaults_off_and_parser_accepts_it(self):
        parser = argparse.ArgumentParser()
        build.add_audio_options(parser)
        self.assertFalse(parser.parse_args([]).reverb)
        self.assertTrue(parser.parse_args(['--reverb']).reverb)
        a = options(True)
        build.normalize_audio_options(a, argparse.ArgumentParser())
        self.assertFalse(build.build_options(a)['reverb'])
        self.assertNotIn('_rev', build.build_label(a))

if __name__ == '__main__':
    unittest.main()
