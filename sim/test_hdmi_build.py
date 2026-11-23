import argparse
import contextlib
import io
import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from test_performance_build import options
import build_gowin as build

class HdmiBuildTests(unittest.TestCase):
    def test_hdmi_is_distinct_and_selects_wrapper_parameter(self):
        a=options(True);a.hdmi=True
        build.normalize_audio_options(a,argparse.ArgumentParser())
        self.assertTrue(build.build_options(a)['hdmi'])
        self.assertIn('_hdmi',build.build_label(a))
        source=(build.ROOT/'rtl/nano20k_hdmi_top.v').read_bytes()
        staged=build.staged_source('rtl/nano20k_hdmi_top.v',source,a).decode()
        self.assertIn('parameter NUM_VOICES=32',staged)
        self.assertIn('parameter PERFORMANCE_ENABLED=1',staged)
        self.assertIn('`define GOWIN_VIDEO',build.staged_source('rtl/hdmi_output.v',b'// wrapper\n',a).decode())

    def test_hdmi_cannot_silently_target_legacy_or_no_performance(self):
        for app,performance in [(False,True),(True,False)]:
            a=options(performance);a.hdmi=True;a.app=app
            with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):
                build.normalize_audio_options(a,argparse.ArgumentParser())

    def test_old_callers_without_hdmi_do_not_change_label(self):
        a=options(True);build.normalize_audio_options(a,argparse.ArgumentParser())
        self.assertFalse(build.build_options(a)['hdmi'])
        self.assertNotIn('_hdmi',build.build_label(a))

    def test_missing_video_clock_cannot_pass_programming_gate(self):
        audio_only=dict(setup_violations=0,hold_violations=0,fmax_mhz=51)
        self.assertFalse(build.timing_passed(audio_only,hdmi=True))
        self.assertTrue(build.timing_passed(audio_only))
        complete=dict(audio_only,clock_frequencies_mhz={'sys_clk':49.152,'clk_video':27,'serial_clk':126,'pixel_clk':25.2},clock_fmax_mhz={'sys_clk':51,'pixel_clk':30})
        self.assertTrue(build.timing_passed(complete,hdmi=True))
        complete['clock_frequencies_mhz']['serial_clk']=125
        self.assertFalse(build.timing_passed(complete,hdmi=True))

    def test_timing_reader_requires_actual_clock_summary(self):
        fixture=build.ROOT/'build/hdmi/clock_fixture'
        path=fixture/'impl/pnr';path.mkdir(parents=True,exist_ok=True)
        (path/'display_tr_content.html').write_text('Numbers of Setup Violated Endpoints 0 Numbers of Hold Violated Endpoints 0 Clock Summary: 1 sys_clk Base 20.345 49.152 2 clk_video Base 37.037 27.000 3 serial_clk Generated 7.937 126.000 4 pixel_clk Generated 39.683 25.200 Max Frequency Summary: 1 sys_clk 49.152(MHz) 50.1(MHz) 2 pixel_clk 25.200(MHz) 80.0(MHz)')
        timing=build.timing_result(fixture,'display')
        self.assertTrue(build.timing_passed(timing,hdmi=True))

if __name__=='__main__':unittest.main()
