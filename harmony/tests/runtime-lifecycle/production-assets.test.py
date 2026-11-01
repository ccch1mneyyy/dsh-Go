"""正式资源边界回归：测试夹具只能经显式独立输出注入。"""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parents[2]
work = Path(tempfile.mkdtemp(prefix='production-assets-', dir=sys.argv[1]))
source = work / 'source'
(source / 'opt').mkdir(parents=True)
(source / 'probe').mkdir()
entry = source / 'opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js'
entry.parent.mkdir(parents=True)
entry.write_text('FIXED')
(source / 'probe' / 'unwanted-test.mjs').write_text('TEST_ONLY')
production = work / 'production.zip'
subprocess.run([sys.executable, str(root / 'plugins/dsh_runtime_ohos/package-runtime.py'), '--source', str(source), '--output', str(production)], check=True)
with zipfile.ZipFile(production) as archive:
    names = archive.namelist()
    assert 'probe/session-list-probe.mjs' in names
    assert 'probe/unwanted-test.mjs' not in names
    assert not any(word in name for name in names for word in ['real-tools', 'real-conversation', 'local-acceptance', 'tool-capabilities-probe'])
    bootstrap = archive.read('transport/run-loopback-smoke.mjs').decode()
    for marker in ['DSH_HARMONY_REAL_TOOLS_PROBE', '__dshBootContext', 'stageMark', 'services.json', 'entries.json', 'diagnostic.json']:
        assert marker not in bootstrap
    assert 'process.stdout.write = sink()' in bootstrap
    assert 'process.stderr.write = sink()' in bootstrap
    assert '__dshEndpointReady' in bootstrap and 'DSH_START_TIMEOUT' in bootstrap
    assert '__dshPtcProbeKind' not in archive.read('scripts/patch-ptc-runtime.mjs').decode()
installed = work / 'installed'
with zipfile.ZipFile(production) as archive:
    archive.extractall(installed)
subprocess.run(['node', '--input-type=module', '-e', "const {verifyRuntimeManifest}=await import(process.argv[1]); verifyRuntimeManifest(process.argv[2]);", (installed / 'transport/runtime-manifest.mjs').as_uri(), str(installed)], check=True)
test_zip = work / 'test-only.zip'
subprocess.run([sys.executable, str(Path(__file__).parent / 'device-fixtures/inject-test-runtime.py'), '--production-zip', str(production), '--test-zip', str(test_zip)], check=True)
with zipfile.ZipFile(test_zip) as archive:
    assert 'transport/local-acceptance-probe.mjs' in archive.namelist()
    manifest = json.loads(archive.read('harmony-assets-manifest.json'))
    for name, digest in manifest.items():
        assert hashlib.sha256(archive.read(name)).hexdigest() == digest
print('正式包排除夹具、保留认证smoke/私密sink/错误生命周期；独立测试注入与全部摘要通过。')
