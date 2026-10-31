import 'dart:typed_data';

/// File access over the already trusted SSH connection, independent of Codex RPC.
abstract class CodexHostFiles {
  Future<Map<String, dynamic>> stat(String path);
  Future<Uint8List> read(String path, int offset, int length);
  Future<String> upload(String name, Uint8List bytes);
  Future<Map<String, dynamic>> inspect(Map<String, dynamic> request);
}

/// Only rollout paths returned by Codex are supplied. Reads messages and usage,
/// never executes message text, and bounds each line, scan time and output.
const rolloutInspector = r'''
import json, sys, time, unicodedata
q=json.load(sys.stdin)
def fold(s):
    return ''.join(chr(ord(c)-65248) if 65281<=ord(c)<=65374 else ' ' if c=='\u3000' else c for c in s).lower()
terms=fold(q.get('query','')).split()
hits=[]; partial=False; deadline=time.monotonic()+7
usage=None
for thread in q.get('threads',[]):
    if time.monotonic()>deadline:
        partial=True; break
    path=thread.get('path')
    if not path: continue
    try:
        with open(path,'rb') as f:
            if q.get('usage'):
                f.seek(0,2); size=f.tell(); f.seek(max(0,size-8*1024*1024))
                if size>8*1024*1024: f.readline()
            while True:
                if time.monotonic()>deadline:
                    partial=True; break
                line=f.readline(4*1024*1024)
                if not line: break
                if not line.endswith(b'\n'):
                    partial=True
                    while line and not line.endswith(b'\n'): line=f.readline(65536)
                    continue
                try: row=json.loads(line)
                except (ValueError,UnicodeError): continue
                p=row.get('payload',{})
                if q.get('usage'):
                    if row.get('type')=='event_msg' and p.get('type')=='token_count' and p.get('info'):
                        usage=p['info']
                    continue
                if row.get('type')!='response_item' or p.get('type')!='message' or p.get('role') not in ('user','assistant'): continue
                text='\n'.join(c.get('text','') for c in p.get('content',[]) if isinstance(c,dict) and c.get('type') in ('input_text','output_text','text'))
                hay=fold(text)
                if terms and all(t in hay for t in terms):
                    at=hay.find(terms[0]); start=max(0,at-70)
                    hits.append({'sessionId':thread['id'],'snippet':('…' if start else '')+text[start:start+260]})
                    break
    except (OSError,ValueError):
        partial=True
    if len(hits)>=100:
        partial=True; break
print(json.dumps({'items':hits,'hasMore':partial,'usage':usage},ensure_ascii=True))
''';
