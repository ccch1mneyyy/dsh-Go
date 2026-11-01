const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '../../..');

function load(name, connection = {}, i18n = {}) {
  const exports = {};
  const code = ts.transpileModule(fs.readFileSync(path.join(root,
    `app/ohos/entry/src/main/ets/plugins/${name}.ets`), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  vm.runInNewContext(code, {
    exports,
    require: name => name === '@kit.NetworkKit' ? { connection }
      : name === '@kit.LocalizationKit' ? { i18n }
      : { hilog: { info() {}, error() {} } },
  });
  const plugin = new exports.default();
  plugin.context = { filesDir: '/fixture/app-files' };
  return method => new Promise(resolve => plugin.onMethodCall({ method }, {
    success: value => resolve(value),
    error: code => resolve({ error: code }),
    notImplemented: () => resolve({ missing: true }),
  }));
}

(async () => {
  let reads = 0;
  const network = (available, value) => ({
    hasDefaultNet: async () => available,
    isDefaultNetMetered: async () => { reads++; return value; },
  });
  for (const metered of [true, false]) {
    assert.equal(await load('DshRuntimePlugin', network(true, metered))('networkMetered'), metered);
  }
  assert.equal(reads, 2);
  assert.equal(await load('DshRuntimePlugin', network(false, false))('networkMetered'), null);
  assert.equal(reads, 2, '离线时不把系统默认false当作非计费网络');
  for (const failAt of ['hasDefaultNet', 'isDefaultNetMetered']) {
    const sdk = network(true, false);
    sdk[failAt] = async () => { throw new Error('系统服务失败'); };
    assert.equal(await load('DshRuntimePlugin', sdk)('networkMetered'), null);
  }
  assert.equal(await load('DshRuntimePlugin')('batteryExempt'), null);
  const layout = Object.fromEntries(await load('DshRuntimePlugin')('getStorageLayout'));
  assert.deepEqual(layout, { version: 1, dataRoot: '/fixture/app-files/engine-data' });
  const bootstrap = fs.readFileSync(path.join(root,
    'harmony/plugins/dsh_runtime_ohos/assets/probe-bootstrap.mjs'), 'utf8');
  for (const [env, folder] of [['DSH_HOME', 'dsh-home'], ['DSH_AGENTS_HOME', 'agents'], ['HOME', 'home']]) {
    assert(bootstrap.includes(`${env}: path.join(fresh, '${folder}')`));
  }
  assert.equal(await load('DshAppPlugin', {}, { getTimeZone: () => ({ getID: () => 'America/Phoenix' }) })('getTimeZoneId'), 'America/Phoenix');
  assert.equal((await load('DshAppPlugin', {}, { getTimeZone: () => { throw new Error('失败'); } })('getTimeZoneId')).error, 'UNAVAILABLE');
  assert.equal((await load('DshAppPlugin')('bringToFront')).missing, true);
  console.log('系统网络/时区原源码替身测试通过：计费、非计费、离线、异常、未知电池与时区失败。');
})().catch(error => { console.error(error); process.exitCode = 1; });
