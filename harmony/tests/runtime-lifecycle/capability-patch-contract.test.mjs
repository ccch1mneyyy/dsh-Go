import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';

// 固定官方资产参数；只读原文件，不改运行时配置。
const modules = process.argv[2];
if (!modules) throw Error('需固定DSH资产node_modules目录');
const require = createRequire(path.resolve(modules, 'capability-contract.cjs'));
const yaml = require('js-yaml');
const schema = yaml.DEFAULT_SCHEMA.extend([new yaml.Type('tag:yaml.org,2002:js', {
  kind: 'scalar', construct: value => ({ __jsExpr: value }),
})]);
const read = file => fs.readFileSync(path.join(modules, '@deepseek-ai', file), 'utf8');
const preset = name => yaml.load(read(`dsh-web-app/presets/${name}.patch.yml`), { schema })[0].insert[0];
const boot = read('dsh-app-boot/lib/index.js');
const begin = boot.indexOf('function applyEntryPatches(');
const end = boot.indexOf('\n/** Loader entry tree', begin);
assert(begin >= 0 && end > begin);
const context = vm.createContext({ structuredClone });
vm.runInContext(boot.slice(begin, end) + '\nglobalThis.apply = applyEntryPatches;', context);
const apply = (rows, patches) => context.apply(rows, patches, () => { throw Error('补丁目标不匹配'); });
const blocked = new Set(['tool-bash', 'tool-pwsh', 'tool-fs-search', 'persistent-shell', 'optional-persistent-terminals']);
function restrictRows(rows) {
  return rows.map(row => ({ ...structuredClone(row),
    ...(blocked.has(row.id) ? { disabled: true } : {}),
    ...(row.group && Array.isArray(row.config) ? { config: restrictRows(row.config) } : {}),
  }));
}
// 方案原型仅用于契约测试。真实接入还须处理自定义预设与所有Agent创建路径。
function proposal(rows, ohos) {
  if (!ohos) return [];
  return rows.flatMap(row => {
    if (['bash-sandbox', 'pwsh-sandbox', 'tool-bash', 'tool-pwsh', 'tool-fs-search', 'optional-persistent-terminals'].includes(row.id)) return [{ id: row.id, disabled: true }];
    if (row.name === '@deepseek-ai/dsh-agent-preset') return [{ id: row.id,
      config: { ...structuredClone(row.config), plugins: restrictRows(row.config.plugins) } }];
    return [];
  });
}
const original = [{ id: 'bash-sandbox' }, { id: 'tool-bash' }, { id: 'tool-fs-search' }, preset('standard'), preset('minimal')];
const before = JSON.stringify(original);

test('真实applyEntryPatches证明根禁用不影响预设内同名行', () => {
  const rows = apply(original, [{ id: 'tool-bash', disabled: true }]);
  assert.equal(rows[1].disabled, true);
  assert.notEqual(rows[3].config.plugins.find(row => row.id === 'tool-bash').disabled, true);
});
test('完整复制config后禁子行，真实Loader保留其它配置及原表达式', () => {
  const rows = apply(original, proposal(original, true));
  assert(rows.slice(0, 3).every(row => row.disabled === true));
  for (const name of ['tool-bash', 'tool-pwsh', 'tool-fs-search']) assert.equal(rows[3].config.plugins.find(row => row.id === name).disabled, true);
  assert.equal(rows[4].config.plugins.find(row => row.id === 'persistent-shell').disabled, true);
  assert.equal(rows[3].config.id, 'standard');
  assert.equal(rows[3].config.order, original[3].config.order);
  assert.equal(rows[3].config.plugins.length, original[3].config.plugins.length);
  for (const row of original[3].config.plugins.filter(row => !blocked.has(row.id))) {
    assert.equal(JSON.stringify(rows[3].config.plugins.find(item => item.id === row.id)), JSON.stringify(row));
  }
  assert.equal(JSON.stringify(original), before);
});
test('非OHOS路径原Android配置逐字序列化不变', () => {
  assert.equal(JSON.stringify(apply(original, proposal(original, false))), before);
});
test('真实mountPreset函数把已禁子行传给独立树，不依赖根同名id', async () => {
  const source = read('dsh-agent-preset-registry/lib/index.js');
  const start = source.indexOf('async function mountPreset('), finish = source.indexOf('\n//#endregion', start);
  assert(start >= 0 && finish > start);
  let mounted;
  // 这是原函数的边界契约：树、审计及预处理采用观察桩，不声称插件已激活或真机已验。
  class Tree { constructor() { this.root = { update: async rows => { mounted = rows; }, stop() {} }; } }
  const scope = vm.createContext({ PresetTree: Tree, scopeOf: () => 'fixed-scope',
    prepareProfileEntries: (_ctx, rows) => structuredClone(rows),
    auditRows: async () => ({ failed: [] }), leakedServices: () => [] });
  vm.runInContext(source.slice(start, finish) + '\nglobalThis.mount = mountPreset;', scope);
  const rows = apply(original, proposal(original, true));
  await scope.mount({ fiber: { await: async () => {} }, effect() {}, baseUrl: 'file:///fixed/' }, 'standard', rows[3].config.plugins);
  for (const id of ['tool-bash', 'tool-pwsh', 'tool-fs-search']) assert.equal(mounted.find(row => row.id === id).disabled, true);
  assert.equal(JSON.stringify(mounted), JSON.stringify(rows[3].config.plugins));
});
