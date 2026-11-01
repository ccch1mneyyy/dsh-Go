"""仅生成独立测试运行包，不修改输入正式包或签名配置。"""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--production-zip', type=Path, required=True)
parser.add_argument('--test-zip', type=Path, required=True)
args = parser.parse_args()
if args.production_zip.resolve() == args.test_zip.resolve():
    raise SystemExit('测试输出不得覆盖正式包')
root = Path(__file__).parent
mapping = {
    'transport/run-loopback-smoke.mjs': 'acceptance-bootstrap.mjs',
    'scripts/patch-ptc-runtime.mjs': 'patch-ptc-runtime-diagnostic.mjs',
}
for name in ['real-tools-probe.mjs', 'tool-capabilities-probe.mjs', 'real-conversation-probe.mjs', 'local-acceptance-probe.mjs']:
    mapping['transport/' + name] = name
with zipfile.ZipFile(args.production_zip) as archive:
    files = {name: archive.read(name) for name in archive.namelist() if not name.endswith('/')}
for name, local in mapping.items():
    files[name] = (root / local).read_bytes()
files['harmony-assets-manifest.json'] = json.dumps({name: hashlib.sha256(data).hexdigest()
    for name, data in sorted(files.items()) if name != 'harmony-assets-manifest.json'}, sort_keys=True).encode()
args.test_zip.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.test_zip, 'w', zipfile.ZIP_DEFLATED) as archive:
    directories = {parent.as_posix() + '/' for name in files for parent in Path(name).parents if str(parent) != '.'}
    for name in sorted(directories):
        entry = zipfile.ZipInfo(name, (2026, 11, 1, 0, 0, 0))
        entry.external_attr = (0o40755 << 16) | 0x10
        archive.writestr(entry, b'')
    for name, data in sorted(files.items()):
        entry = zipfile.ZipInfo(name, (2026, 11, 1, 0, 0, 0))
        entry.external_attr = 0o100644 << 16
        entry.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(entry, data)
print(json.dumps({'testOnly': True, 'files': len(files)}))
