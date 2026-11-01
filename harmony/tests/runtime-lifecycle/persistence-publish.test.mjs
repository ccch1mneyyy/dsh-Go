import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { test } from 'node:test';
import { patchPersistence } from '../../plugins/dsh_runtime_ohos/assets/persistence-publish.mjs';

// 使用实际固定资产，避免只测手写副本。调用方明确提供不含凭据的包源码路径。
const filename = process.env.DSH_PERSISTENCE_SOURCE;
if (!filename) throw new Error('请设置 DSH_PERSISTENCE_SOURCE 为固定资产的持久化源码');
const original = fs.readFileSync(filename, 'utf8');
const patched = patchPersistence(original, 'file:///fixture/persistence-publish.mjs');
function extract(name) {
  const start = patched.indexOf(`async function ${name}(`);
  assert.ok(start >= 0);
  const end = patched.indexOf('\n}', start);
  return patched.slice(start, end + 2);
}
function harness({ collision = false, syncFailure = false, platform = 'openharmony' } = {}) {
  const events = [];
  const syncError = Object.assign(new Error('固定同步错误'), { code: 'EIO' });
  let consumed = false;
  const context = {
    process: { platform },
    harmonyPublishNoReplace() {
      events.push('publish');
      if (collision) throw Object.assign(new Error('固定冲突'), { code: 'EEXIST' });
      consumed = true;
    },
    isEEXIST: e => e.code === 'EEXIST',
    syncDirectory: async () => { events.push('sync'); if (syncFailure) throw syncError; },
    dirname: () => '/fixture', scheduler: { yield: async () => {} },
    writeSyncedTemp: async () => ({ path: '/fixture/stage', bytes: 7, digest: 'fixed' }),
    identity: x => x,
    removeCommittedTemporary: async () => { events.push('cleanup'); assert.equal(consumed, false); },
    removeTemporary: async () => { events.push('cleanup-error'); assert.equal(consumed, false); },
    inspectExpectedCurrent: async (_path, _internals, verify) => { await verify(); return { identity: 'identity' }; },
    JsonlGenerationSourceChangedError: Error,
  };
  const internals = {
    platform, barrier: async name => events.push(name),
    fs: { stat: async () => 'identity', link: async () => { events.push('link'); } },
  };
  vm.createContext(context);
  vm.runInContext(extract('publishCurrentExclusive') + '\n' + extract('publishPreparedMigration') + '\nglobalThis.api={publishCurrentExclusive,publishPreparedMigration};', context);
  const migrate = () => context.api.publishPreparedMigration({ sourcePath: '/fixture/old', currentPath: '/fixture/current', compression: false,
    verifyCurrentFile: async () => ({ bytes: 7, digest: 'fixed' }), format: {} }, '.tmp', { events: [], header: { id: 'fixed' } }, 'identity', internals);
  return { events, context, internals, migrate, syncError };
}
test('补丁幂等且旧覆盖rename迁移为排他发布', () => {
  assert.equal(patchPersistence(patched, 'file:///fixture/persistence-publish.mjs'), patched);
  const legacy = original.replace('await internals.fs.link(staged, currentPath);', 'if (process.platform === "openharmony") { await rename(staged, currentPath); } else { await internals.fs.link(staged, currentPath); } /* HARMONY_LINK_FALLBACK */')
    .replace('await link(tmp, finalPath);', 'if (process.platform === "openharmony") { await rename(tmp, finalPath); } else { await link(tmp, finalPath); }');
  assert.equal(patchPersistence(legacy, 'file:///fixture/persistence-publish.mjs'), patched);
  assert.throws(() => patchPersistence(original.replace('await link(tmp, finalPath);', ''), 'file:///fixture/helper.mjs'), /PATCH_MISMATCH/);
});
test('发布冲突返回false且不消费源或同步目录', async () => {
  const h = harness({ collision: true });
  assert.equal(await h.context.api.publishCurrentExclusive('stage', 'current', h.internals), false);
  assert.deepEqual(h.events, ['publish']);
});
test('迁移成功后先标记源被消费，再同步目录与验证', async () => {
  const h = harness();
  assert.equal(await h.migrate(), 'identity');
  assert.deepEqual(h.events, ['before-source-check', 'publish', 'sync', 'after-publication']);
});
test('发布后目录同步失败保留原错误，不清理已消费源', async () => {
  const h = harness({ syncFailure: true });
  await assert.rejects(h.migrate(), e => e === h.syncError);
  assert.deepEqual(h.events, ['before-source-check', 'publish', 'sync']);
});
test('冲突分支验证已有目标并清理未消费stage', async () => {
  const h = harness({ collision: true });
  assert.equal(await h.migrate(), 'identity');
  assert.deepEqual(h.events, ['before-source-check', 'publish', 'after-publication', 'cleanup']);
});
test('其它POSIX平台继续使用原link与目录同步', async () => {
  const h = harness({ platform: 'linux' });
  assert.equal(await h.context.api.publishCurrentExclusive('stage', 'current', h.internals), true);
  assert.deepEqual(h.events, ['link', 'sync']);
});
test('新建会话冲突不能替换既有日志，失败清理临时文件', async () => {
  const start = patched.indexOf('\tasync materializePosix(');
  assert.ok(start >= 0);
  const end = patched.indexOf('\n\t}', start) + 3;
  const events = [];
  const conflict = Object.assign(new Error('固定冲突'), { code: 'EEXIST' });
  const ctx = { process: { platform: 'openharmony' }, mkdir: async () => {}, dirname: () => '/fixture',
    harmonyPublishNoReplace: () => { events.push('publish'); throw conflict; },
    rm: async () => events.push('cleanup'), link: () => { throw new Error('不应使用link'); } };
  vm.createContext(ctx);
  vm.runInContext(`class Store { ${patched.slice(start, end)} }; globalThis.store=new Store();`, ctx);
  Object.assign(ctx.store, { root: '/fixture', syncDirPosix: async () => {}, rejectExistingLog: async () => {}, writeSyncedTempFile: async () => '/fixture/tmp' });
  await assert.rejects(ctx.store.materializePosix('/fixture/project', '/fixture/session', '/fixture/final', 'fixed', 'fixed'), e => e === conflict);
  assert.deepEqual(events, ['publish', 'cleanup']);
});
