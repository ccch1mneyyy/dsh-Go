import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const [modules, output] = process.argv.slice(2);
if (!modules || !output) throw Error('需传入固定 rc4 node_modules 与独立测试输出目录');
const root = fileURLToPath(new URL('../../..', import.meta.url));
const require = createRequire(path.resolve(modules, 'web-ui-fixture.cjs'));
const yaml = require('js-yaml');
const schema = yaml.DEFAULT_SCHEMA.extend([new yaml.Type('tag:yaml.org,2002:js', {
  kind: 'scalar', construct: value => ({ expressionNotExecuted: value }),
})]);
const packageRoot = name => path.join(modules, '@deepseek-ai', name);
const source = (name, file) => fs.readFileSync(path.join(packageRoot(name), file), 'utf8');
const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)).href);
const core = ['ui-renderer', 'ui-settings', 'ui-theme', 'ui-layout', 'ui-session',
  'ui-conversation', 'ui-sidebar', 'ui-sidebar-right', 'ui-workspace', 'ui-input-trigger', 'ui-chat'];
const controls = ['ui-commands', 'ui-model-selection', 'ui-permission', 'ui-approval',
  'ui-user-questions', 'ui-brand-official', 'ui-settings-account'];
const restored = [...core, ...controls];
const restricted = ['entry-customization', 'ui-plugin-manager', 'plugin-manager',
  'terminal-controller', 'api-terminal-controller', 'terminal', 'subprocess-local',
  'ui-sidebar-terminal', 'directory-picker', 'open-in-app', 'ui-open-in-app',
  'office-to-pdf', 'ui-sidebar-documentpreview', 'ui-sidebar-browser', 'ui-sidebar-files',
  'schedule', 'ui-schedule', 'job-controller', 'ui-jobs', 'message-feedback', 'ui-message-feedback'];
const patchPath = path.join(root, 'harmony/plugins/dsh_runtime_ohos/assets/platform-diagnostic.patch.yml');
const patchText = fs.readFileSync(patchPath, 'utf8');
const patch = yaml.load(patchText);
for (const id of restored) {
  assert.equal(patch.filter(row => row.id === id).length, 1, `${id} 不得重复`);
  assert.equal(patch.find(row => row.id === id)?.disabled, false, `${id} 必须明确恢复`);
}
for (const id of restricted) assert.equal(patch.find(row => row.id === id)?.disabled, true, `${id} 必须继续禁用`);
assert.equal(patch.filter(row => row.id?.startsWith('ui-') && row.disabled === false).length, 18);
assert.equal(require('@deepseek-ai/dsh/package.json').version, '0.2.1-rc.4');

// 固定原 profile 与平台覆盖只作为数据读取，!!js 表达式不执行。
const rows = new Map();
for (const document of [yaml.load(source('dsh-base', 'cordis.patch.yml'), { schema }),
  yaml.load(source('dsh-web-app', 'cordis.patch.yml'), { schema }), patch]) {
  for (const row of document) {
    for (const insert of row.insert ?? []) rows.set(insert.id, { ...rows.get(insert.id), ...insert });
    if (row.id) rows.set(row.id, { ...rows.get(row.id), ...row });
  }
}
const { Context } = await load('cordis');
const { default: Modules } = await load('dsh-client-modules');
const ctx = new Context();
const entries = [...rows.values()].filter(row => row.name).map(row => ({
  options: { name: row.name }, disabled: row.disabled === true, fiber: {},
  parent: { tree: { ctx: { baseUrl: pathToFileURL(packageRoot('dsh-web-app') + '/').href } } },
}));
ctx.provide('loader', { entries: () => entries });
let graph;
try {
  await ctx.plugin(Modules);
  graph = ctx.clientModules.graph();
  for (const id of restored) assert(graph.entries.some(entry => entry.id === rows.get(id).name), `${id} 缺少真实 client 资产`);
  for (const id of restricted) {
    const name = rows.get(id)?.name;
    if (name) assert(!graph.entries.some(entry => entry.id === name), `${id} 不得进入 browser roster`);
  }
} finally { await ctx.fiber.dispose(); }

// 检验真实客户端导出的服务等待图，不执行其 apply、DOM 或任何 Remote。
const providers = {
  slots: 'ui-renderer', configForms: 'ui-settings', settingsSchema: 'ui-settings',
  theme: 'ui-theme', layout: 'ui-layout', uiSession: 'ui-session', uiWorkspace: 'ui-workspace',
  sidebarRight: 'ui-sidebar-right', uiConversation: 'ui-conversation', inputTriggers: 'ui-input-trigger',
  commandUi: 'ui-commands', locale: 'locale', shortcuts: 'shortcuts', fileUpload: 'file-upload',
  sessions: 'session-controller', workspaces: 'workspace-controller', resources: 'resources',
  remote: 'typert-gateway', remoteAccess: 'remote-access', connection: 'connection',
};
// typed namespace 由 api-remotes 的描述符挂载，服务存在不证明 Host 功能可执行。
const namespaceProvider = 'api-remotes';
const serviceChecks = [];
const host = new Context();
try {
  for (const id of restored) await host.plugin(await load(rows.get(id).name.replace('@deepseek-ai/', '')), {});
} finally { await host.fiber.dispose(); }
for (const id of restored) {
  const name = rows.get(id).name.replace('@deepseek-ai/', '');
  const client = source(name, 'lib/client.js');
  assert(client.includes('exports.inject = inject;'), `${id} 未导出预期 inject`);
  const match = [...client.matchAll(/const inject = (\[[\s\S]*?\]);/g)].at(-1);
  assert(match, `${id} 的依赖不是可静态核验的字符串数组`);
  const services = vm.runInNewContext(match[1]);
  const probe = new Context();
  let active = false;
  try {
    const fiber = probe.plugin({ inject: Array.from(services), apply() { active = true; } });
    if (services.length > 0) {
      await Promise.resolve();
      assert.equal(active, false, `${id} 不应在缺少服务时激活`);
    }
    for (const service of services) {
      const provider = service.startsWith('remote.') ? namespaceProvider : providers[service];
      assert(provider, `${id} 的 ${service} 没有已核提供者`);
      const row = rows.get(provider);
      assert(row && row.disabled !== true, `${id} 依赖的 ${provider} 被禁用`);
      assert(graph.entries.some(entry => entry.id === row.name), `${provider} 没有实际客户端模块`);
      probe.provide(service, {});
    }
    await fiber;
    assert.equal(active, true, `${id} 的依赖门仍未满足`);
    serviceChecks.push({ id, services: Array.from(services) });
  } finally { await probe.fiber.dispose(); }
}

// 用全新小输入跑正式 packager，核真实ZIP入口与摘要，不运行DSH CLI。
fs.mkdirSync(output, { recursive: true });
const fixture = fs.mkdtempSync(path.join(output, 'web-ui-package-'));
const entry = path.join(fixture, 'source/opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js');
fs.mkdirSync(path.dirname(entry), { recursive: true });
fs.writeFileSync(entry, '固定打包夹具，不执行');
const zip = path.join(fixture, 'runtime.zip');
const packager = path.join(root, 'harmony/plugins/dsh_runtime_ohos/package-runtime.py');
const run = spawnSync('python', [packager, '--source', path.join(fixture, 'source'), '--output', zip], { encoding: 'utf8' });
assert.equal(run.status, 0, run.stderr);
const verify = spawnSync('python', ['-c',
  'import zipfile,json,hashlib,sys; z=zipfile.ZipFile(sys.argv[1]); p=z.read("transport/cordis-min.yml"); assert p==open(sys.argv[2],"rb").read(); m=json.loads(z.read("harmony-assets-manifest.json")); assert m["transport/cordis-min.yml"]==hashlib.sha256(p).hexdigest(); print("正式ZIP平台补丁与清单摘要一致")',
  zip, patchPath], { encoding: 'utf8' });
assert.equal(verify.status, 0, verify.stderr);
fs.writeFileSync(path.join(output, 'web-ui-restoration-services.json'), JSON.stringify({
  restored, restricted, browserEntries: graph.entries.map(entry => entry.id), serviceChecks,
  boundary: '真实Cordis注入门+固定客户端inject数组；服务值为夹具空对象。未执行browser apply/DOM/RPC，不能视作网页全active或终端等后端可用。',
}, null, 2));
console.log(JSON.stringify({ restored: restored.length, restricted: restricted.length,
  browserEntries: graph.entries.length, serviceGates: serviceChecks.length, packageFixture: zip }));
