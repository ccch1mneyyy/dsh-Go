import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { patchOhosToolCapability, installOhosToolCapabilities } from '../../plugins/dsh_runtime_ohos/scripts/patch-tool-capabilities.mjs';
const modules = process.argv[2], work = process.argv[3];
if (!modules || !work) throw Error('需固定node_modules与D盘测试工作目录');
fs.mkdirSync(work, { recursive: true });
const dir = fs.mkdtempSync(path.join(work, 'capability-'));
const require = createRequire(path.resolve(modules, 'guard-test.cjs'));
const load = spec => import(pathToFileURL(require.resolve(spec)).href);
const { Context } = await load('@deepseek-ai/cordis');
const { default: SystemPrompt } = await load('@deepseek-ai/dsh-system-prompt');
const { default: Tools } = await load('@deepseek-ai/dsh-tools');
const names = ['dsh-tool-bash', 'dsh-tool-pwsh', 'dsh-tool-fs-search', 'dsh-tool-terminal', 'dsh-tool-bash-persistent', 'dsh-tool-pwsh-persistent', 'dsh-terminal-bash'];
const plugins = [];
for (const name of names) {
  const file = require.resolve('@deepseek-ai/' + name);
  const original = fs.readFileSync(file, 'utf8');
  const patched = patchOhosToolCapability(original, name);
  // 只改变临时测试副本的import解析位置，实际工具apply/Config/inject/export来自原模块。
  const relocated = patched.replace(/^(import[^\n]+from )"([^".][^"]*)"/gm, (all, prefix, spec) => spec.startsWith('node:') ? all : `${prefix}"${pathToFileURL(require.resolve(spec)).href}"`);
  const target = path.join(dir, name + '.mjs'); fs.writeFileSync(target, relocated);
  const plugin = await import(pathToFileURL(target).href);
  const baseline = await import(pathToFileURL(file).href);
  assert.deepEqual(plugin.inject, baseline.inject);
  assert.deepEqual(Object.keys(plugin).sort(), Object.keys(baseline).sort());
  assert.equal(fs.readFileSync(file, 'utf8'), original);
  plugins.push({ plugin, baseline, name });
}
async function enumerate(marker, patched, selected = names.slice(0, 3)) {
  const ctx = new Context();
  try {
    await ctx.plugin(SystemPrompt); await ctx.plugin(Tools);
    // 提供注册必需的能力对象，所有实际执行入口故意拒绝；本测试不调用shell/模型/网络。
    ctx.provide('subprocess', { ...(marker === undefined ? {} : { ohosIsolatedPtc: marker }), spawn() { throw Error('禁止执行'); } });
    ctx.provide('shell', { sandboxMode: undefined });
    ctx.provide('shellEnv', {}); ctx.provide('workingDirectory', {});
    ctx.provide('terminals', { registerBackend() {} }); ctx.provide('sandboxPolicy', {});
    for (const item of plugins.filter(item => selected.includes(item.name))) await ctx.plugin(patched ? item.plugin : item.baseline,
      item.name === 'dsh-tool-fs-search' ? { sampleOverCapGlobResults: false } : { enableRunInBackground: false });
    return { names: ctx.tools.schemas().map(tool => tool.name).sort(), bindings: ctx.tools.sdkSchemas().map(tool => tool.name).sort(), schemas: ctx.tools.schemas(), sdkSchemas: ctx.tools.sdkSchemas() };
  } finally { await ctx.fiber.dispose(); }
}
test('真实工具插件及ToolsService注册：OHOS marker不广告bash/pwsh/glob/grep', async () => {
  const result = await enumerate(true, true); assert.deepEqual(result, { names: [], bindings: [], schemas: [], sdkSchemas: [] });
});
test('Android或远程marker缺失/false与未修改模块真实schema注册一致', async () => {
  const expected = await enumerate(undefined, false);
  assert.deepEqual(expected.names, ['bash', 'glob', 'grep', 'pwsh']);
  assert.deepEqual(await enumerate(undefined, true), expected);
  assert.deepEqual(await enumerate(false, true), expected);
});
test('未知模块、重复补丁、源码锚点变化均拒绝，不写入原文件', () => {
  assert.throws(() => patchOhosToolCapability('other', 'dsh-tool-bash'), /MISMATCH/);
  assert.throws(() => patchOhosToolCapability('function apply(ctx, config = {}) {', 'unknown'), /MISMATCH/);
  const text = patchOhosToolCapability('function apply(ctx, config = {}) {', 'dsh-tool-bash');
  assert.throws(() => patchOhosToolCapability(text, 'dsh-tool-bash'), /MISMATCH/);
});



test('持久shell/终端原插件入口能力guard：真实工具目录不广告，markerfalse保原schema', async () => {
  for (const name of names.slice(3)) {
    const baseline = await enumerate(false, false, [name]);
    assert.deepEqual(await enumerate(false, true, [name]), baseline);
    const result = await enumerate(true, true, [name]);
    assert.deepEqual(result.names, []); assert.deepEqual(result.bindings, []);
  }
});
test('固定摘要安装器幂等、篡改拒绝，非OHOS不读文件且不改配置', () => {
  const installed = fs.mkdtempSync(path.join(work, 'install-'));
  for (const name of names) {
    const target = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai', name, 'lib/index.js');
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(require.resolve('@deepseek-ai/' + name), target);
  }
  assert.deepEqual(installOhosToolCapabilities('/missing-test-root', 'android'), { checked: 0, changed: 0 });
  assert.deepEqual(installOhosToolCapabilities(installed, 'openharmony'), { checked: 7, changed: 7 });
  assert.deepEqual(installOhosToolCapabilities(installed, 'openharmony'), { checked: 7, changed: 0 });
  const bad = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai/dsh-tool-terminal/lib/index.js');
  fs.appendFileSync(bad, '\n// 篡改测试');
  assert.throws(() => installOhosToolCapabilities(installed, 'openharmony'), /DIGEST_MISMATCH/);
});


test('真实PTC scope区分模型run_code与SDK绑定，空minimal不能由run_code冒充', async () => {
  const { inspectToolCapabilities } = await import('./device-fixtures/tool-capabilities-probe.mjs');
  const { createScope } = await load('@deepseek-ai/dsh-scope');
  const { defineTool } = await load('@deepseek-ai/dsh-tools');
  const ctx = new Context();
  let scoped;
  try {
    await ctx.plugin(SystemPrompt); await ctx.plugin(Tools);
    ctx.provide('ptcRuntime', { language: 'typescript' });
    const key = {}; scoped = createScope(ctx, key); await scoped.ctx.fiber.await();
    scoped.ctx.get('tools').presentAs('ptc'); await scoped.ctx.fiber.await();
    const empty = inspectToolCapabilities(ctx.tools, key);
    assert.equal(empty.ptcWireOnly, true); assert.equal(empty.schemaCount, 1);
    assert.equal(empty.bindingCount, 0); assert.equal(empty.readImagePresent, false);
    const disposers = ['read', 'write'].map(name => scoped.ctx.get('tools').register(defineTool({
      name, description: '固定测试能力', parameters: {},
      output: { schema: { type: 'string' }, render: () => [] }, execute: async () => '',
    })));
    const standard = inspectToolCapabilities(ctx.tools, key);
    assert.equal(standard.schemaCount, 1); assert.equal(standard.bindingCount, 2);
    assert.equal(standard.readPresent, true); assert.equal(standard.writePresent, true);
    for (const dispose of disposers) dispose();
    scoped.ctx.get('tools').register(defineTool({ name: 'read_image', description: '固定测试能力', parameters: {},
      output: { schema: { type: 'string' }, render: () => [] }, execute: async () => '' }));
    const minimal = inspectToolCapabilities(ctx.tools, key);
    assert.equal(minimal.ptcWireOnly, true); assert.equal(minimal.bindingCount, 1);
    assert.equal(minimal.readImagePresent, true); assert.equal(minimal.readPresent, false);
  } finally { if (scoped) await scoped.dispose(); await ctx.fiber.dispose(); }
});
