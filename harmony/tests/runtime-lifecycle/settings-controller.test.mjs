import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const modules = process.argv[2];
if (!modules) throw Error('需传入固定发行资产node_modules路径');
const require = createRequire(path.resolve(modules, 'settings-controller-test.cjs'));
const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)).href);
const patch = require('js-yaml').load(await readFile(new URL('../../plugins/dsh_runtime_ohos/assets/platform-diagnostic.patch.yml', import.meta.url), 'utf8'));
assert.equal(patch.find(row => row.id === 'settings-controller').disabled, false);
const { Context } = await load('cordis');
const { default: Registry } = await load('dsh-typert-registry');
const { default: Gateway } = await load('dsh-api-gateway');
const { default: SettingsController } = await load('dsh-api-settings-controller');
const { TYPERT } = await load('dsh-api-settings-controller/typert');
const ctx = new Context();
const values = new Map();
const fixture = 'fixed-test-value-not-a-real-key';
let resolveCalls = 0, setCalls = 0, unsetCalls = 0, documentCalls = 0, openCalls = 0;
let rejectWrite = false;
const refusals = () => Object.assign(new Error('固定拒绝说明'), { value: fixture, cause: new Error(fixture) });
const descriptor = { ns: 'fixture', autoGenerate: false, schema: {}, value: {}, base: {}, user: {}, applies: 'live', secrets: [{ path: ['secret'], set: true, value: fixture }], revision: 1, privateValue: fixture };
const settings = {
  writable: true,
  describe(options) { assert.deepEqual(options, { redactSecrets: true }); return [descriptor]; },
  async update() { if (rejectWrite) throw refusals(); },
  async replace() { if (rejectWrite) throw refusals(); },
  async mutate() { if (rejectWrite) throw refusals(); },
  async prepareDocument() { documentCalls++; return '/fixed-test/settings.yml'; }
};
const credentials = {
  resolve() { resolveCalls++; throw Error('禁止解析凭据值'); },
  async describe(ref) { return { configured: values.has(ref), writable: true, ...values.has(ref) ? { source: 'file' } : {}, value: fixture }; },
  async set(ref, value) { setCalls++; if (rejectWrite) throw refusals(); values.set(ref, value); },
  async unset(ref) { unsetCalls++; if (rejectWrite) throw refusals(); values.delete(ref); }
};
const peer = { principal: { kind: 'owner' }, signal: new AbortController().signal };
const signal = new AbortController().signal;
try {
  ctx.provide('settings', settings);
  ctx.provide('credentials', credentials);
  ctx.provide('remoteAccess', { decide() { throw Error('本测试仅允许 owner 调用'); } });
  await ctx.plugin(Registry);
  ctx.typert.register(TYPERT);
  await ctx.plugin(Gateway, {});
  await ctx.plugin(SettingsController, { openTextFile() { openCalls++; throw Error('固定平台不支持编辑器'); } });
  assert(ctx.settingsController && ctx.credentialsController);
  const rpc = (endpoint, args = {}) => ctx.typertGateway.invokeRpc(endpoint, { args }, signal, peer);
  assert.deepEqual(await rpc('credentials/describe', { refs: ['TEST_KEY'] }), { ok: true, value: { TEST_KEY: { configured: false, writable: true } } });
  assert.deepEqual(await rpc('credentials/set', { ref: 'TEST_KEY', value: fixture }), { ok: true, value: undefined });
  assert.equal(values.get('TEST_KEY'), fixture);
  assert.deepEqual(await rpc('credentials/describe', { refs: ['TEST_KEY'] }), { ok: true, value: { TEST_KEY: { configured: true, source: 'file', writable: true } } });
  assert.deepEqual(await rpc('credentials/unset', { ref: 'TEST_KEY' }), { ok: true, value: undefined });
  assert.equal(values.has('TEST_KEY'), false);
  assert.equal(setCalls, 1); assert.equal(unsetCalls, 1); assert.equal(resolveCalls, 0);
  const described = await rpc('settings/describe');
  assert.equal(described.ok, true);
  assert.equal(JSON.stringify(described).includes(fixture), false);
  for (const method of ['update', 'replace', 'mutate']) {
    const args = { ns: 'fixture', expectedRevision: 1, [method === 'update' ? 'patch' : method === 'replace' ? 'section' : 'ops']: method === 'mutate' ? [] : {} };
    const result = await rpc('settings/' + method, args);
    assert.equal(result.ok, true);
    assert.equal(JSON.stringify(result).includes(fixture), false);
  }
  rejectWrite = true;
  for (const [endpoint, args, code, details] of [
    ['credentials/set', { ref: 'TEST_KEY', value: fixture }, 'credential/rejected', { ref: 'TEST_KEY' }],
    ['credentials/unset', { ref: 'TEST_KEY' }, 'credential/rejected', { ref: 'TEST_KEY' }],
    ['settings/update', { ns: 'fixture', patch: {}, expectedRevision: 1 }, 'settings/rejected', { ns: 'fixture' }]
  ]) {
    const failure = await rpc(endpoint, args);
    assert.deepEqual(failure, { ok: false, error: { code, message: '固定拒绝说明', details } });
    assert.equal(JSON.stringify(failure).includes(fixture), false);
  }
  const invalid = await rpc('credentials/set', { ref: 'INVALID-REF', value: fixture });
  assert.equal(invalid.error.code, 'gateway/bad-request');
  assert.equal(JSON.stringify(invalid).includes(fixture), false);
  assert.equal(resolveCalls, 0); assert.equal(documentCalls, 0); assert.equal(openCalls, 0);
  const opened = await rpc('settings/openSettingsDocument');
  assert.equal(opened.error.code, 'gateway/internal');
  assert.equal(documentCalls, 1); assert.equal(openCalls, 1);
  console.log(JSON.stringify({ credentialsMounted: true, statusOnly: true, setUnset: true, settingsRedacted: true, errorCauseExcluded: true, resolveCalls, editorExplicitOnly: true }));
} finally {
  await ctx.fiber.dispose();
}
