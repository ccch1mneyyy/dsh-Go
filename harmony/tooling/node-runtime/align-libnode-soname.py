from pathlib import Path
r=Path(__file__).resolve().parent/'node-v24.2.0'
p=r/'out/libnode.target.mk';s=p.read_text();assert 'libnode.so.137' in s or '$(obj).target/libnode.so:' in s
if 'libnode.so.137' in s:p.write_text(s.replace('libnode.so.137','libnode.so'))
print('libnode链接目标与SONAME为HAP正式libnode.so名称，保留已编译对象',flush=True)
