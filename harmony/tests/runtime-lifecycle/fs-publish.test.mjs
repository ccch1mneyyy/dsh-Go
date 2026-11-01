import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { patchFsPublish } from '../../plugins/dsh_runtime_ohos/assets/fs-publish.mjs';
const [sourcePath, addonPath, workRoot] = process.argv.slice(2);
if (!workRoot) throw Error('请提供固定原源码、同源原生publish测试插件、工作目录');
const original = await fs.readFile(sourcePath, 'utf8');
const patched = patchFsPublish(original, 'file:///fixture/persistence-publish.mjs');
assert.equal(patchFsPublish(patched, 'file:///fixture/persistence-publish.mjs'), patched);
assert.throws(() => patchFsPublish(original + '\n', 'file:///fixture/helper'), /HASH/);
const watch = '\tasync watch(target, changed, signal) {';
const watchPatched = watch + ' throw new Error("ENOSYS: fs.watch unsupported on openharmony"); /* HARMONY_NO_WATCH */';
const cached = patched.replace(watch, watchPatched);
assert.equal(patchFsPublish(cached, 'file:///fixture/persistence-publish.mjs'), cached);
assert.throws(() => patchFsPublish(cached + '\n', 'file:///fixture/persistence-publish.mjs'), /HASH/);
function extract(name) {
  const start = patched.indexOf(`async function ${name}(`);
  assert.ok(start >= 0);
  return patched.slice(start, patched.indexOf('\n}', start) + 2);
}
const native = createRequire(import.meta.url)(addonPath);
class FsError extends Error { constructor(message, code) { super(message); this.code = code; } }
let publications = 0, consumed = false;
const context = vm.createContext({ ...fs, ...path, Error, FsError, randomUUID,
  process: { platform: 'openharmony', pid: process.pid },
  throwIfAborted(signal) { if (signal?.aborted) throw new FsError('固定取消', 'FS_ABORTED'); },
  isAbortError: e => e.name === 'AbortError', isENOENT: e => e.code === 'ENOENT', isENOTDIR: e => e.code === 'ENOTDIR', isEEXIST: e => e.code === 'EEXIST',
  errorMessage: e => String(e.code ?? e.name), copyFileDaclWin32() {}, replaceFileWin32() {},
  harmonyFsPublishNoReplace(source, target) { publications++; native.publishNoReplaceSync(source, target); consumed = true; },
});
vm.runInContext(['removeStagingDirOrThrow', 'throwGuardedCreateFailure', 'writeFileAtomic'].map(extract).join('\n') + '\nglobalThis.writeAtomic=writeFileAtomic;', context);
await fs.mkdir(workRoot, { recursive: true });
const root = await fs.mkdtemp(path.join(workRoot, 'fs-publish-'));
const write = (target, text, signal, internals = {}) => context.writeAtomic(target, text, undefined, signal, internals, { displayPath: '固定目标' });
const target = path.join(root, 'new'); let staged;
await write(target, 'FIXED', undefined, { inspectTemp(value) { staged = value; } });
assert.equal(await fs.readFile(target, 'utf8'), 'FIXED'); assert.equal(consumed, true);
await assert.rejects(fs.stat(staged.tempPath), { code: 'ENOENT' });
await assert.rejects(fs.stat(staged.stagingDir), { code: 'ENOENT' });
await assert.rejects(write(target, 'FORBIDDEN'), { code: 'FS_NOT_OBSERVED' });
assert.equal(await fs.readFile(target, 'utf8'), 'FIXED');
const race = path.join(root, 'race');
const results = await Promise.allSettled([write(race, 'A'), write(race, 'B')]);
assert.equal(results.filter(x => x.status === 'fulfilled').length, 1);
assert.equal(results.find(x => x.status === 'rejected').reason.code, 'FS_NOT_OBSERVED');
assert.ok(['A', 'B'].includes(await fs.readFile(race, 'utf8')));
const cancel = new AbortController(), count = publications;
await assert.rejects(write(path.join(root, 'cancel'), 'NO', cancel.signal, { inspectTemp() { cancel.abort(); } }), { code: 'FS_ABORTED' });
assert.equal(publications, count); await assert.rejects(fs.stat(path.join(root, 'cancel')), { code: 'ENOENT' });
await write(path.join(root, 'cleanup'), 'KEEP', undefined, { removeStagingDir() { throw Error('固定清理失败'); } });
assert.equal(await fs.readFile(path.join(root, 'cleanup'), 'utf8'), 'KEEP');
let hooked = false;
await write(path.join(root, 'hook'), 'HOOK', undefined, { async linkFile(a, b) { hooked = true; await fs.link(a, b); } });
assert.equal(hooked, true);
context.process.platform = 'android'; const before = publications;
await write(path.join(root, 'android'), 'ANDROID'); assert.equal(publications, before);
console.log('真实源码/同源原生renameat2回归通过：排他新建、冲突、并发唯一赢家、取消、源消费、清理保目标、hook优先及Android原link。');
