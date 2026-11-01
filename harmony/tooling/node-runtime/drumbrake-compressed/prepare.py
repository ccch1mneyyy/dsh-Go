"""只应用固定Node源码补丁；拒绝混合状态和未核实源码，不启动编译。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent
manifest = json.loads((root / 'source-manifest.json').read_text(encoding='utf-8'))
patch = root / 'node-v24.2.0-ohos.patch'
digest = lambda data: hashlib.sha256(data).hexdigest()
if digest(patch.read_bytes()) != manifest['patchSha256']:
    raise SystemExit('补丁摘要不匹配')
# 核对未修改的启动/异常/Undici关键文件，防止旧诊断代码混入。
unchanged = json.loads((root / 'unchanged-source-check.json').read_text())
for name, expected in unchanged.items():
    if digest((args.source / name).read_bytes().replace(b'\r\n', b'\n')) != expected['sha256']:
        raise SystemExit('原版关键源码摘要不匹配：' + name)
state = []
for name, expected in manifest['files'].items():
    actual = digest((args.source / name).read_bytes())
    if actual == expected['before']:
        state.append('before')
    elif actual == expected['after']:
        state.append('after')
    else:
        raise SystemExit('源码摘要不匹配：' + name)
if len(set(state)) != 1:
    raise SystemExit('拒绝混合或部分补丁状态')
if state[0] == 'before':
    subprocess.run(['git', '-c', 'core.autocrlf=false', 'apply', '--check', str(patch)], cwd=args.source, check=True)
    if not args.check:
        subprocess.run(['git', '-c', 'core.autocrlf=false', 'apply', str(patch)], cwd=args.source, check=True)
        for name, expected in manifest['files'].items():
            if digest((args.source / name).read_bytes()) != expected['after']:
                raise SystemExit('应用后摘要不匹配：' + name)
print(json.dumps({'files': len(state), 'inputState': state[0], 'dryRun': args.check, 'verified': True}))
