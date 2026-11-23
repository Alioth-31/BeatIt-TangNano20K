import argparse,json,os,subprocess,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
sys.path.insert(0,str(Path(__file__).resolve().parent))
import build_gowin as build
from test_performance_build import options
from run_tests import find_tool

class FactoryBootTests(unittest.TestCase):
 def profile(self):return {'schema':2,'channels':[
  dict(channel=1,low=100,centre=800,high=1500,invert_x=True),
  dict(channel=2,low=160,centre=810,high=1470,invert_x=False)]}
 def test_profile_is_bound_to_image_identity_and_staging(self):
  folder=build.ROOT/'build/factory-tests';folder.mkdir(exist_ok=True)
  path=folder/'calibration.json';path.write_text(json.dumps(self.profile()),encoding='utf-8')
  a=options(True);a.peripherals=True;a.factory_calibration=path
  build.normalize_audio_options(a,argparse.ArgumentParser())
  self.assertIn('_cal',build.build_label(a));self.assertEqual(build.build_options(a)['factory_calibration'],self.profile())
  header=build.staged_source('rtl/expression_boot.vh',(build.ROOT/'rtl/expression_boot.vh').read_bytes(),a)
  self.assertIn(b"3'b110",header);self.assertIn(b"BOOT_INVERT_X=1'b1",header)
  a.factory_calibration_data=None
  self.assertNotIn('_cal',build.build_label(a))
 def test_factory_requires_peripheral_profile(self):
  a=options(True);a.factory_calibration=Path('missing.json')
  with self.assertRaises(SystemExit):build.normalize_audio_options(a,argparse.ArgumentParser())
 def test_compiled_factory_values_survive_reset(self):
  folder=build.ROOT/'build/factory-tests';folder.mkdir(exist_ok=True)
  header=build.factory_calibration_header(self.profile())
  (folder/'expression_boot.vh').write_bytes(header)
  words=(0,0,100,800,1500,160,810,1470)
  packed=sum((n&4095)<<(12*i) for i,n in enumerate(words))
  iv,vvp=find_tool('iverilog'),find_tool('vvp');env=os.environ.copy()
  env['PATH']=str(Path(iv).parent)+os.pathsep+str(Path(iv).parent.parent/'lib')+os.pathsep+env.get('PATH','')
  image=folder/'factory.vvp'
  cmd=[iv,'-g2001','-I'+str(folder),'-Irtl','-s','tb_factory_expression',
       '-Ptb_factory_expression.EXPECTED=96\'h'+f'{packed:024x}','-o',str(image)]
  cmd += [str(p.relative_to(build.ROOT)) for p in sorted((build.ROOT/'rtl').glob('*.v'))]
  cmd += ['sim/reference/tb_factory_expression.v']
  c=subprocess.run(cmd,cwd=build.ROOT,env=env,capture_output=True,text=True,errors='replace')
  self.assertEqual(c.returncode,0,c.stderr)
  r=subprocess.run([vvp,str(image)],cwd=build.ROOT,env=env,capture_output=True,text=True,timeout=20)
  self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertIn('PASS',r.stdout)
  (folder/'factory.log').write_text(r.stdout+r.stderr,encoding='utf-8')

if __name__=='__main__':unittest.main()
