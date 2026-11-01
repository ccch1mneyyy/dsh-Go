from pathlib import Path
import re,json,hashlib
root=Path(__file__).resolve().parent;r=root/'node-v24.2.0'
make=(r/'out/libnode.target.mk').read_text()
line=next(x for x in make.splitlines() if x.startswith('$(obj)/gen/node_javascript.cc: $(builddir)/node_js2c'))
paths=re.findall(r'\$\(srcdir\)/([^\s]+)',line)
changes=[]
for name in paths:
 p=r/name
 if p.suffix not in ('.js','.mjs'):continue
 b=p.read_bytes(); after=b.replace(b'\r\n',b'\n')
 if after==b:continue
 changes.append({'path':name,'oldBytes':len(b),'newBytes':len(after),'crlf':b.count(b'\r\n'),'oldSha256':hashlib.sha256(b).hexdigest(),'newSha256':hashlib.sha256(after).hexdigest()})
 p.write_bytes(after)
if changes:
 (root/'builtin-input-line-ending-fix.json').write_text(json.dumps({'reason':'js2c raw literal CRLF length mismatch verified in ELF','changes':changes},indent=2))
assert paths, '未找到实际 js2c 依赖，拒绝静默跳过'
assert all(b'\r\n' not in (r/name).read_bytes() for name in paths if (r/name).suffix in ('.js','.mjs'))
print('规范内置脚本输入行尾文件数',len(changes),flush=True)
