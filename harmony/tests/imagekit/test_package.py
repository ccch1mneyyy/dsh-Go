"""便携打包／源码契约测试；仅新固定输入目录，不读用户配置或原生成包。"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
sys.dont_write_bytecode=True
REPO=Path(__file__).resolve().parents[3]
PLUGIN=REPO/'harmony/plugins/dsh_runtime_ohos'
spec=importlib.util.spec_from_file_location('fixed_imagekit_patch',PLUGIN/'scripts/patch_imagekit.py')
patch=importlib.util.module_from_spec(spec);spec.loader.exec_module(patch)
sha=lambda value:hashlib.sha256(value).hexdigest()

class Contracts(unittest.TestCase):
 def test_fixed_source_inverse_and_unknown_rejected(self):
  changed=patch.patch_attachment_source(SOURCE)
  self.assertNotEqual(SOURCE,changed);self.assertEqual(sha(SOURCE),patch.EXPECTED)
  restored=changed.decode()
  for before,after in reversed(patch.REPLACEMENTS):
   self.assertEqual(restored.count(after),1);restored=restored.replace(after,before)
  self.assertEqual(restored.encode(),SOURCE)
  for invalid in [SOURCE+b'\n',changed]:
   with self.assertRaises(ValueError):patch.patch_attachment_source(invalid)

 def make_source(self,label,source):
  root=ROOT/label
  files={'opt/dsh/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js':source,
   'opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js':b'throw Error("FIXED_CLI_MUST_NOT_RUN");',
   'opt/dsh/node_modules/@deepseek-ai/dsh-attachment-local/LICENSE':b'fixed-license-sentinel',
   'opt/dsh/node_modules/fixed/.credentials.yaml':b'FIXED_SECRET_SENTINEL',
   'opt/dsh/node_modules/fixed/private.log':b'FIXED_LOG_SENTINEL',
   'opt/dsh/node_modules/fixed/backup.bak':b'FIXED_BACKUP_SENTINEL'}
  for name,data in files.items():
   file=root/name;file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(data)
  return root

 def test_packaged_manifest_helpers_and_privacy(self):
  root=self.make_source('good',SOURCE);out=ROOT/'good.zip'
  result=subprocess.run([sys.executable,str(MERGED_PLUGIN/'package-runtime.py'),'--source',str(root),'--output',str(out)],capture_output=True,timeout=30)
  self.assertEqual(result.returncode,0)
  with zipfile.ZipFile(out) as archive:
   names=archive.namelist();self.assertEqual(len(names),len(set(names)))
   files={n:archive.read(n) for n in names if not n.endswith('/')};manifest=json.loads(files['harmony-assets-manifest.json'])
   self.assertEqual(manifest,{n:sha(data) for n,data in files.items() if n!='harmony-assets-manifest.json'})
   self.assertFalse(any(n.endswith(('.credentials.yaml','.log','.bak')) for n in names))
   self.assertEqual(files['opt/dsh/node_modules/@deepseek-ai/dsh-attachment-local/LICENSE'],b'fixed-license-sentinel')
   owner='opt/dsh/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js'
   self.assertEqual(files[owner],patch.patch_attachment_source(SOURCE))
   self.assertIn('transport/imagekit/backend.mjs',files)
   for name in ['backend.mjs','container.mjs','encoded-icc.mjs','header-reader.mjs','container-worker.mjs']:
    self.assertEqual(files['transport/imagekit/'+name],(PLUGIN/'assets/imagekit'/name).read_bytes())
   helper=files[owner.rsplit('/',1)[0]+'/ohos-imagekit.mjs'].decode()
   self.assertIn('../../../../../../transport/imagekit/backend.mjs',helper)
   provenance=json.loads(files['transport/imagekit/patch-manifest.json'])
   self.assertEqual(provenance['sourceSha256'],patch.EXPECTED);self.assertEqual(provenance['patchedSha256'],sha(files[owner]))
   self.assertEqual(provenance['transformVersion'],'request-image-imagekit-candidate-v2')

 def test_bad_source_stops_before_output(self):
  root=self.make_source('bad',SOURCE+b'\n');out=ROOT/'must-not-exist.zip'
  result=subprocess.run([sys.executable,str(MERGED_PLUGIN/'package-runtime.py'),'--source',str(root),'--output',str(out)],capture_output=True,timeout=30)
  self.assertNotEqual(result.returncode,0);self.assertFalse(out.exists())

 def test_bootstrap_boundary_marker_and_portable_build(self):
  bootstrap=(PLUGIN/'assets/probe-bootstrap.mjs').read_text(encoding='utf8')
  host=(REPO/'app/ohos/entry/src/main/ets/plugins/DshRuntimePlugin.ets').read_text(encoding='utf8')
  self.assertIn('DSH_HARMONY_DURABLE_ROOT: fresh',bootstrap)
  self.assertNotIn('HARMONY_LINK_FALLBACK_ATT',bootstrap)
  self.assertNotIn('copyFile(a, b, constants.COPYFILE_EXCL)',bootstrap)
  self.assertIn('scriptver-151',bootstrap);self.assertIn('scriptver-151',host)
  build=(REPO/'harmony/tooling/build-imagekit-addon.ps1').read_text(encoding='utf8')
  for name in ['NativeSdk','NodeSource','NodeLibrary','OutputDirectory']:self.assertIn('[string]$'+name,build)
  self.assertIn('-DNAPI_VERSION=8',build);self.assertIn('libnode.so',build);self.assertIn('libace_napi',build)
  for root in [PLUGIN,REPO/'harmony/tooling',REPO/'harmony/tests/imagekit']:
   for file in root.rglob('*'):
    if file.suffix in ['.mjs','.py','.ps1','.c'] and file.is_file():self.assertIsNone(re.search(r'(?<![A-Za-z])[A-Za-z]:[/\\]',file.read_text(encoding='utf8')),file.name)

if __name__=='__main__':
 parser=argparse.ArgumentParser()
 parser.add_argument('--modules-root',type=Path,required=True)
 parser.add_argument('--output-root',type=Path,required=True)
 parser.add_argument('--baseline-repo',type=Path,default=REPO)
 args=parser.parse_args()
 SOURCE=(args.modules_root/'@deepseek-ai/dsh-attachment-local/lib/index.js').read_bytes()
 args.output_root.mkdir(parents=True,exist_ok=True);ROOT=Path(tempfile.mkdtemp(prefix='package-host-',dir=args.output_root))
 MERGED_PLUGIN=ROOT/'merged-plugin'
 shutil.copytree(args.baseline_repo/'harmony/plugins/dsh_runtime_ohos',MERGED_PLUGIN,ignore=shutil.ignore_patterns('__pycache__'))
 shutil.copytree(PLUGIN,MERGED_PLUGIN,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
 result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
 report=dict(schema=1,kind='imagekit-packager-host',passed=result.wasSuccessful(),checks=result.testsRun,deviceUsed=False,productionIntegrated=False)
 (ROOT/'safe.json').write_text(json.dumps(report,indent=2),encoding='utf8')
 raise SystemExit(0 if result.wasSuccessful() else 1)
