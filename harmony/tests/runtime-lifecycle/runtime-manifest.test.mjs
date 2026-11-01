import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { verifyRuntimeManifest } from '../../plugins/dsh_runtime_ohos/assets/runtime-manifest.mjs';
const root = fs.mkdtempSync(path.join(process.argv[2], 'manifest-test-'));
const manifest = path.join(root, 'harmony-assets-manifest.json');
const name = 'opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js';
const entry = path.join(root, name);
fs.mkdirSync(path.dirname(entry), { recursive: true });
fs.writeFileSync(entry, 'FIXED');
const digest = createHash('sha256').update('FIXED').digest('hex');
const write = map => fs.writeFileSync(manifest, JSON.stringify(map));
assert.throws(() => verifyRuntimeManifest(root), /RUNTIME_MANIFEST_UNREADABLE/);
fs.writeFileSync(manifest, '{');
assert.throws(() => verifyRuntimeManifest(root), /RUNTIME_MANIFEST_UNREADABLE/);
for (const invalid of [null, [], 'text', { [name]: 'bad' }, ...['../escape', '/absolute', 'a/../b', 'a/./b', 'a//b', 'C:/escape', 'a\\b'].map(key => ({ [name]: digest, [key]: digest }))]) {
  write(invalid); assert.throws(() => verifyRuntimeManifest(root), /RUNTIME_MANIFEST_INVALID/);
}
write({}); assert.throws(() => verifyRuntimeManifest(root), /RUNTIME_MANIFEST_ENTRY_MISSING/);
write({ [name]: digest });
assert.deepEqual(verifyRuntimeManifest(root), { files: [{ path: name, sha256: digest }] });
fs.writeFileSync(entry, 'CHANGED');
assert.throws(() => verifyRuntimeManifest(root), /ENTRY_HASH_MISMATCH/);
fs.unlinkSync(entry);
assert.throws(() => verifyRuntimeManifest(root), /RUNTIME_ENTRY_UNREADABLE/);
console.log('清单缺失、坏JSON、非法结构、路径逃逸、入口缺失、篡改拒绝及有效入口通过');
