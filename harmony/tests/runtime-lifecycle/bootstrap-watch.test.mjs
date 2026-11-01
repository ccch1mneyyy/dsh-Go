import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs, { watch as esmWatch } from 'node:fs';
import { watch as esmPromisesWatch, readFile } from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import vm from 'node:vm';

const source = (await readFile(new URL('../../plugins/dsh_runtime_ohos/assets/probe-bootstrap.mjs', import.meta.url), 'utf8')).replaceAll('\r\n', '\n');
const start = source.indexOf('  try {\n    const noWatch =');
const end = source.indexOf('  } catch (watchPatchError) { }', start);
assert(start > 0 && end > start);
const patch = source.slice(start, end + '  } catch (watchPatchError) { }'.length);

async function withWatchPatch(check) {
  const originalWatch = fs.watch, originalPromisesWatch = fs.promises.watch;
  try {
    // 直接使用真实内建模块及同步函数；不创建 watcher、不加载 DSH 或用户配置。
    vm.runInNewContext(patch, { fs, syncBuiltinESMExports });
    await check();
  } finally {
    fs.watch = originalWatch;
    fs.promises.watch = originalPromisesWatch;
    syncBuiltinESMExports();
  }
  assert.equal(esmWatch, originalWatch);
  assert.equal(esmPromisesWatch, originalPromisesWatch);
}

test('watch 替换同步到真实 ESM 命名绑定', () => withWatchPatch(() => {
  assert.equal(esmWatch, fs.watch);
  assert.equal(esmPromisesWatch, fs.promises.watch);
  assert.match(source, /import \{ syncBuiltinESMExports \} from 'node:module';/);
}));

test('默认与命名 fs.watch 都同步抛出 ENOSYS', () => withWatchPatch(() => {
  for (const watch of [fs.watch, esmWatch]) {
    assert.throws(() => watch('/unused'), { code: 'ENOSYS' });
  }
}));

test('promises.watch 保留异步迭代器并在迭代时拒绝 ENOSYS', () => withWatchPatch(async () => {
  for (const watch of [fs.promises.watch, esmPromisesWatch]) {
    const iterator = watch('/unused');
    // 旧实现返回拒绝的 Promise；先消费拒绝以免失败回归产生未处理拒绝。
    if (typeof iterator.catch === 'function') iterator.catch(() => {});
    assert.equal(typeof iterator[Symbol.asyncIterator], 'function');
    assert.equal(iterator[Symbol.asyncIterator](), iterator);
    await assert.rejects(iterator.next(), { code: 'ENOSYS' });
  }
}));
