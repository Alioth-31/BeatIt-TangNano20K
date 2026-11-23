import hashlib,json,sys,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
sys.path.insert(0,str(Path(__file__).resolve().parent))
import program_flash as f
from test_performance_build import options
import build_gowin as b

class FlashGuardTests(unittest.TestCase):
 def fixture(self):
  root=f.ROOT/'build/flash-tests';root.mkdir(exist_ok=True)
  a=options(True);a.hdmi=False;b.normalize_audio_options(a,__import__('argparse').ArgumentParser())
  folder=root/'build'/b.build_label(a);folder.mkdir(parents=True,exist_ok=True)
  image=folder/'image.fs';image.write_bytes(b'fixture-not-an-image')
  relative=str(image.relative_to(root))
  data={'completed':True,'timing_pass':True,'bitstreams':[relative],
        'bitstreams_sha256':{relative:hashlib.sha256(image.read_bytes()).hexdigest()}}
  (folder/'build_result.json').write_text(json.dumps(data),encoding='utf-8')
  return root,a,folder,image,data
 def test_external_verify_operation_and_address_are_fixed(self):
  c=f.flash_command('programmer.exe','image.fs',609,1)
  self.assertEqual(c[c.index('--operation_index')+1],'37')
  self.assertEqual(c[c.index('--spiaddr')+1],'0x000000')
  self.assertNotIn('--bulk-erase',c)
 def test_source_guard_runs_and_tampered_bitstream_is_rejected(self):
  root,a,folder,image,data=self.fixture()
  with patch.object(f.sram,'validate_audio_variant') as guard:
   self.assertEqual(f.validated_image(a,root)[1],image.resolve());guard.assert_called_once()
   image.write_bytes(b'tampered')
   with self.assertRaisesRegex(ValueError,'digest mismatch'):f.validated_image(a,root)
 def test_incomplete_or_failed_build_cannot_be_programmed(self):
  root,a,folder,image,data=self.fixture();data['timing_pass']=False
  (folder/'build_result.json').write_text(json.dumps(data),encoding='utf-8')
  with self.assertRaises(ValueError):f.validated_image(a,root)

if __name__=='__main__':unittest.main()
