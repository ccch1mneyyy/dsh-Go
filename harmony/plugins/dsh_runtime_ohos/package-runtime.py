"""打包已有固定资产；排除凭据、诊断文件及历史源码副本。"""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile
from scripts.patch_imagekit import patch_attachment_source, EXPECTED as IMAGEKIT_SOURCE_SHA

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assets = Path(__file__).parent / 'assets'
files = {}
for folder in ['opt']:
    for source in (args.source / folder).rglob('*'):
        if not source.is_file() or 'dsh.clean' in source.parts:
            continue
        if source.name == 'ohos-index.js':
            continue
        if source.name == '.credentials.yaml' or source.suffix in ['.log', '.bak']:
            continue
        files[source.relative_to(args.source).as_posix()] = source
files['transport/run-loopback-smoke.mjs'] = assets / 'probe-bootstrap.mjs'
files['transport/runtime-manifest.mjs'] = assets / 'runtime-manifest.mjs'
files['transport/persistence-publish.mjs'] = assets / 'persistence-publish.mjs'
files['transport/fs-publish.mjs'] = assets / 'fs-publish.mjs'
for name in ['subprocess-ohos.mjs', 'subprocess-ohos-loader.mjs', 'ohos-runtime-setup.mjs']:
    files['transport/' + name] = assets / name
files['scripts/patch-ptc-runtime.mjs'] = Path(__file__).parent / 'scripts' / 'patch-ptc-runtime.mjs'
files['scripts/patch-tool-capabilities.mjs'] = Path(__file__).parent / 'scripts' / 'patch-tool-capabilities.mjs'
files['probe/session-list-probe.mjs'] = assets / 'session-list-probe.mjs'
files['transport/cordis-min.yml'] = assets / 'platform-diagnostic.patch.yml'
# 原AttachmentStore在打包时一次性改写；未知原版在创建输出前停止。
attachment = 'opt/dsh/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js'
overrides = {attachment: patch_attachment_source(files[attachment].read_bytes())}
files[attachment.rsplit('/', 1)[0] + '/ohos-imagekit.mjs'] = assets / 'imagekit/ohos-imagekit.mjs'
for name in ['backend.mjs','container.mjs','encoded-icc.mjs','header-reader.mjs','container-worker.mjs']:
    files['transport/imagekit/' + name] = assets / 'imagekit' / name
provenance = 'transport/imagekit/patch-manifest.json'
files[provenance] = assets / 'imagekit/ohos-imagekit.mjs'
overrides[provenance] = json.dumps({'sourceSha256': IMAGEKIT_SOURCE_SHA, 'patchedSha256': hashlib.sha256(overrides[attachment]).hexdigest(), 'transformVersion': 'request-image-imagekit-candidate-v2'}, sort_keys=True).encode()
def contents(name, file):
    return overrides[name] if name in overrides else file.read_bytes()
manifest = {name: hashlib.sha256(contents(name, file)).hexdigest() for name, file in sorted(files.items())}
directories = set()
for name in files:
    for parent in Path(name).parents:
        if str(parent) != '.': directories.add(parent.as_posix() + '/')
args.output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for name in sorted(directories):
        info = zipfile.ZipInfo(name, (2026, 11, 1, 0, 0, 0))
        info.external_attr = (0o40755 << 16) | 0x10
        archive.writestr(info, b'')
    for name, file in sorted(files.items()):
        info = zipfile.ZipInfo(name, (2026, 11, 1, 0, 0, 0))
        info.external_attr = 0o100644 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, contents(name, file))
    archive.writestr('harmony-assets-manifest.json', json.dumps(manifest, sort_keys=True))
print(json.dumps({'files': len(files), 'archiveSha256': hashlib.sha256(args.output.read_bytes()).hexdigest()}))
