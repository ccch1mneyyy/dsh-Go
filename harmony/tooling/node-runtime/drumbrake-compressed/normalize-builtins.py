"""只规范js2c规则真正引用的JS/MJS；防止Windows CRLF引起原始字面量长度失配。"""
import argparse
from pathlib import Path
import re
parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, required=True)
args = parser.parse_args()
source = args.source
make = (source / 'out/libnode.target.mk').read_text()
rules = [line for line in make.splitlines() if line.startswith('$(obj)/gen/node_javascript.cc: $(builddir)/node_js2c')]
if len(rules) != 1:
    raise SystemExit('js2c依赖规则缺失或不唯一')
names = re.findall(r'\$\(srcdir\)/([^\s]+)', rules[0])
if not names:
    raise SystemExit('js2c输入列表为空')
changed = 0
for name in names:
    file = source / name
    if file.suffix not in ('.js', '.mjs'):
        continue
    before = file.read_bytes()
    after = before.replace(b'\r\n', b'\n')
    if before != after:
        file.write_bytes(after)
        changed += 1
print('已检查js2c实际依赖，规范文件数：', changed)
