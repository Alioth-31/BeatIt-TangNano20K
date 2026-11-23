"""Probe configuration generation and programming guards; no board access."""
import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import build_hardware_probe as builder
import program_sram as programmer
import build_gowin as audio
from types import SimpleNamespace


class ProbeVariantsTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='probe_variant_test_')
        self.stage=Path(self.temp.name)
        shutil.copytree(ROOT/'rtl',self.stage/'rtl')
        shutil.copytree(ROOT/'constraints',self.stage/'constraints')

    def tearDown(self):
        self.temp.cleanup()

    def prepare(self,voices):
        metadata=builder.prepare_probe_sources(self.stage,voices)
        metadata.update(stage=str(self.stage),label=builder.probe_label(voices))
        return metadata

    def test_cli_accepts_variant_before_compilation(self):
        # Timeout0 stops the compiler; source generation must still complete.
        # Before this feature, argparse rejects --voices with exit2.
        # Use a disposable source root so this negative build cannot overwrite
        # an already validated hardware_probe_8 artifact in the real project.
        command=("import sys; from pathlib import Path; sys.path.insert(0,sys.argv[1]); "
                 "import build_hardware_probe as b; b.ROOT=Path(sys.argv[2]); "
                 "sys.argv=['build_hardware_probe.py','--voices','8','--timeout','0']; b.main()")
        run=subprocess.run([sys.executable,'-c',command,str(ROOT/'scripts'),str(self.stage)],
                           cwd=ROOT,capture_output=True,text=True)
        self.assertNotEqual(run.returncode,2,run.stderr)
        metadata=json.loads((self.stage/'build'/'hardware_probe_8'/'build_result.json').read_text())
        self.assertEqual(metadata['voices'],8)
        self.assertEqual(metadata['key_mask'],255)
        stage=Path(metadata['stage'])
        top=(stage/'rtl'/'hardware_probe_top.v').read_text()
        self.assertIn('synth_core #(.NUM_VOICES(8)) core(',top)
        self.assertIn('wire [7:0] active;',top)
        self.assertIn("requested=phase_a4?32'h00000020:32'h000000ff;",top)

    def test_legacy_four_keeps_label_mask_and_original_source_bytes(self):
        metadata=self.prepare(4)
        self.assertEqual(metadata['label'],'hardware_probe')
        self.assertEqual(metadata['key_mask'],0x55)
        self.assertEqual((self.stage/'rtl'/'hardware_probe_top.v').read_bytes(),
                         (ROOT/'rtl'/'hardware_probe_top.v').read_bytes())
        programmer.validate_probe_variant(metadata,4)

    def test_expanded_width_mask_and_hashes_are_derived_from_current_source(self):
        # Test the generated working HDL, not a mock emitter.
        for voices,width,mask in ((8,7,'000000ff'),(16,15,'0000ffff'),(32,31,'ffffffff')):
            with self.subTest(voices=voices):
                source=(ROOT/'rtl'/'hardware_probe_top.v').read_text()
                generated,substitutions=builder.make_probe_variant(source,voices)
                self.assertIn(f'.NUM_VOICES({voices})',generated)
                self.assertIn(f'wire [{width}:0] active;',generated)
                self.assertIn(f"requested=phase_a4?32'h00000020:32'h{mask};",generated)
                self.assertEqual(len(substitutions),3)
                self.assertTrue(all(item['count']==1 for item in substitutions))

    def test_source_anchor_mismatch_fails_instead_of_silently_building_four(self):
        source=(ROOT/'rtl'/'hardware_probe_top.v').read_text()
        with self.assertRaises(ValueError):
            builder.make_probe_variant(source.replace('.NUM_VOICES(4)','.NUM_VOICES(3)'),32)
        with self.assertRaises(ValueError):
            builder.make_probe_variant(source+'\nwire [3:0] active;\n',8)

    def test_stage_tamper_is_rejected_before_programming(self):
        metadata=self.prepare(32)
        programmer.validate_probe_variant(metadata,32)
        file=self.stage/'rtl'/'hardware_probe_top.v'
        file.write_text(file.read_text().replace("32'hffffffff","32'h000000ff"))
        with self.assertRaisesRegex(SystemExit,'Staged source'):
            programmer.validate_probe_variant(metadata,32)

    def test_tampered_manifest_and_variant_selection_are_rejected(self):
        metadata=self.prepare(16)
        bad=copy.deepcopy(metadata);bad['key_mask']=255
        with self.assertRaisesRegex(SystemExit,'variant'):
            programmer.validate_probe_variant(bad,16)
        with self.assertRaisesRegex(SystemExit,'variant'):
            programmer.validate_probe_variant(metadata,8)
        bad=copy.deepcopy(metadata);bad['stage_substitutions'][0]['new']='.NUM_VOICES(4)'
        with self.assertRaisesRegex(SystemExit,'substitution'):
            programmer.validate_probe_variant(bad,16)
        bad=copy.deepcopy(metadata);name='rtl\\hardware_probe_top.v'
        bad['staged_sources_sha256'][name]='0'*64
        with self.assertRaisesRegex(SystemExit,'Staged source'):
            programmer.validate_probe_variant(bad,16)

    def test_omitting_required_files_from_both_manifests_is_rejected(self):
        metadata=self.prepare(32)
        omitted_sets=[['rtl\\hardware_probe_top.v'],['rtl\\sine_rom_pair.v'],
                      ['rtl\\synth_core.v'],['constraints\\hardware_probe.cst'],
                      ['constraints\\hardware_probe.sdc'],
                      ['rtl\\hardware_probe_top.v','rtl\\sine_rom_pair.v']]
        for names in omitted_sets:
            with self.subTest(omitted=names):
                bad=copy.deepcopy(metadata)
                for name in names:
                    del bad['sources_sha256'][name]
                    del bad['staged_sources_sha256'][name]
                with self.assertRaisesRegex(SystemExit,'incomplete'):
                    programmer.validate_probe_variant(bad,32)
        # Reproduce the review's specific bypass: omit both transformed files,
        # then stage a four-voice core under a claimed32-voice metadata record.
        bad=copy.deepcopy(metadata)
        for name in omitted_sets[-1]:
            del bad['sources_sha256'][name];del bad['staged_sources_sha256'][name]
        top=self.stage/'rtl'/'hardware_probe_top.v'
        top.write_text(top.read_text().replace('.NUM_VOICES(32)','.NUM_VOICES(4)'))
        with self.assertRaisesRegex(SystemExit,'incomplete'):
            programmer.validate_probe_variant(bad,32)

    def test_audio_full_profile_and_stage_are_both_validated(self):
        args=SimpleNamespace(voices=32,led=False,app=True,transport='usb',no_controls=False,
            waveform=0,tremolo=True,delay=True,dc_block=True,live_tone=True,live_wave=True,
            dual_osc=True,independent_osc=True,osc2_waveform=0,osc2_detune_shift=7,osc2_separate_rom=False,timing_opt=False)
        metadata=audio.prepare_audio_sources(self.stage,args)
        metadata.update(stage=str(self.stage),label=audio.build_label(args))
        programmer.validate_audio_variant(metadata,args)
        self.assertIn('parameter INDEPENDENT_OSC_ENABLE=1',(self.stage/'rtl/nano20k_app_top.v').read_text())
        bad=copy.deepcopy(metadata);bad['build_options']['independent_osc']=False
        with self.assertRaisesRegex(SystemExit,'profile'):
            programmer.validate_audio_variant(bad,args)
        bad=copy.deepcopy(metadata);del bad['staged_sources_sha256']['rtl\\synth_core.v']
        with self.assertRaisesRegex(SystemExit,'incomplete'):
            programmer.validate_audio_variant(bad,args)
        top=self.stage/'rtl/nano20k_app_top.v'
        top.write_text(top.read_text().replace('parameter NUM_VOICES=32','parameter NUM_VOICES=4'))
        with self.assertRaisesRegex(SystemExit,'Staged source'):
            programmer.validate_audio_variant(metadata,args)

    def test_independent_probe_is_explicit_and_guarded(self):
        metadata=builder.prepare_probe_sources(self.stage,32,independent=True)
        metadata.update(stage=str(self.stage),label=builder.probe_label(32,independent=True))
        programmer.validate_probe_variant(metadata,32,independent=True)
        top=(self.stage/'rtl/hardware_probe_top.v').read_text()
        self.assertIn('.DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(1)',top)
        self.assertTrue((self.stage/'rtl/osc_envelope_ram.v').read_text().startswith(builder.ROM_PREPEND))
        with self.assertRaisesRegex(SystemExit,'variant'):
            programmer.validate_probe_variant(metadata,32,independent=False)


if __name__=='__main__':
    unittest.main()
