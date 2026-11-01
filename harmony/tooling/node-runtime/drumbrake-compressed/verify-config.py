"""比较实际configure结果与成功候选配置；只容许安装前缀不同。"""
import argparse
import ast
import json
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--config', type=Path, required=True)
args = parser.parse_args()
expected = json.loads((Path(__file__).resolve().parent / 'config-template.json').read_text())
actual = ast.literal_eval(args.config.read_text())
actual['variables']['node_prefix'] = '${INSTALL_PREFIX}'
if actual != expected:
    keys = sorted(k for k in set(actual.get('variables', {})) | set(expected['variables'])
                  if actual.get('variables', {}).get(k) != expected['variables'].get(k))
    print(json.dumps({'matches': False, 'differentVariableNames': keys, 'otherSectionsDiffer':
                      {k: v for k, v in actual.items() if k != 'variables'} !=
                      {k: v for k, v in expected.items() if k != 'variables'}}))
    raise SystemExit(1)
print(json.dumps({'matches': True, 'ignored': ['variables.node_prefix']}))
