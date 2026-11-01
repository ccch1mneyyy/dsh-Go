import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

const entryName = 'opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js';
// 此处核验清单结构与 CLI 入口，不宣称逐文件启动校验。
export function verifyRuntimeManifest(installed) {
  let map;
  try { map = JSON.parse(fs.readFileSync(path.join(installed, 'harmony-assets-manifest.json'), 'utf8')); }
  catch { throw new Error('RUNTIME_MANIFEST_UNREADABLE'); }
  if (!map || typeof map !== 'object' || Array.isArray(map)) throw new Error('RUNTIME_MANIFEST_INVALID');
  const files = Object.entries(map).map(([name, sha256]) => {
    if (!name || /[\\:\x00-\x1f]/.test(name) || name.split('/').some(part => !part || part === '.' || part === '..') ||
        typeof sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(sha256)) throw new Error('RUNTIME_MANIFEST_INVALID');
    return { path: name, sha256 };
  });
  const pinned = files.find(item => item.path === entryName);
  if (!pinned) throw new Error('RUNTIME_MANIFEST_ENTRY_MISSING');
  let digest;
  try {
    const root = fs.realpathSync(installed);
    const entry = fs.realpathSync(path.join(root, ...entryName.split('/')));
    const relative = path.relative(root, entry);
    if (relative === '..' || relative.startsWith('..' + path.sep) || path.isAbsolute(relative)) throw new Error();
    digest = createHash('sha256').update(fs.readFileSync(entry)).digest('hex');
  } catch { throw new Error('RUNTIME_ENTRY_UNREADABLE'); }
  if (digest !== pinned.sha256) throw new Error('ENTRY_HASH_MISMATCH');
  return { files };
}
