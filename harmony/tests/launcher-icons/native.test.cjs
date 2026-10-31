const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const repository = path.resolve(__dirname, '../../..');
const source = fs.readFileSync(path.join(repository, 'app/ohos/entry/src/main/ets/plugins/DshLauncherIconPlugin.ets'), 'utf8');
const javascript = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText;

function harness(initial = '', options = {}) {
  let selected = initial;
  let queries = 0;
  let handler;
  const setters = [];
  const bundle = {
    getAlternateIcons: async () => {
      queries++;
      if (options.queryError) throw { code: 17700311 };
      if (options.icons) return options.icons;
      return ['night', 'frost', 'ink'].map(iconName => ({ iconName, enabled: selected === iconName }));
    },
    setAlternateIcon: async name => {
      setters.push(name);
      if (options.setError) throw { code: 17700310 };
      if (options.wait) await options.wait;
      if (!options.unchanged) selected = name;
    },
  };
  const exports = {};
  vm.runInNewContext(javascript, {
    exports,
    require: name => {
      if (name === '@ohos.bundle.bundleManager') return { default: bundle };
      return { MethodChannel: class { setMethodCallHandler(value) { handler = value; } } };
    },
  });
  const plugin = new exports.default();
  plugin.onAttachedToEngine({ getBinaryMessenger: () => ({}) });
  return {
    plugin, setters, queries: () => queries, handler: () => handler,
    invoke: (method, id) => new Promise(resolve => plugin.onMethodCall({ method, argument: () => id }, {
      success: value => resolve({ kind: 'success', value: Object.fromEntries(value) }),
      error: (code, _message, detail) => resolve({ kind: 'error', code, detail }),
      notImplemented: () => resolve({ kind: 'missing' }),
    })),
  };
}

(async () => {
  let passed = 0;
  const initial = harness();
  assert.deepEqual(await initial.invoke('state'), { kind: 'success', value: { current: 'mist', mask: null } });
  passed++;
  for (const variant of ['night', 'frost', 'ink']) {
    assert.equal((await harness(variant).invoke('state')).value.current, variant);
    passed++;
  }
  const change = harness();
  assert.equal((await change.invoke('set', 'night')).value.current, 'night');
  assert.deepEqual(change.setters, ['night']);
  assert.equal(change.queries(), 2);
  passed++;
  const restore = harness('frost');
  assert.equal((await restore.invoke('set', 'mist')).value.current, 'mist');
  assert.deepEqual(restore.setters, ['']);
  passed++;
  const repeated = harness();
  assert.equal((await repeated.invoke('set', 'mist')).value.current, 'mist');
  assert.deepEqual(repeated.setters, []);
  passed++;
  const invalid = harness();
  assert.equal((await invalid.invoke('set', 'unexpected')).code, 'unknown');
  assert.equal(invalid.queries(), 0);
  assert.deepEqual(await invalid.invoke('other'), { kind: 'missing' });
  passed++;
  assert.equal((await harness('', { queryError: true }).invoke('state')).detail, 17700311);
  assert.equal((await harness('', { setError: true }).invoke('set', 'night')).detail, 17700310);
  assert.equal((await harness('', { unchanged: true }).invoke('set', 'night')).kind, 'error');
  passed++;
  assert.equal((await harness('', { icons: [{ iconName: 'other', enabled: true }] }).invoke('state')).kind, 'error');
  assert.equal((await harness('', { icons: [{ iconName: 'night', enabled: true }, { iconName: 'ink', enabled: true }] }).invoke('state')).kind, 'error');
  passed++;
  let finish;
  const pending = harness('', { wait: new Promise(resolve => { finish = resolve; }) });
  let completed = false;
  const request = pending.invoke('set', 'ink').then(value => { completed = true; return value; });
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(completed, false);
  finish();
  assert.equal((await request).value.current, 'ink');
  initial.plugin.onDetachedFromEngine();
  assert.equal(initial.handler(), null);
  passed++;

  const app = JSON.parse(fs.readFileSync(path.join(repository, 'app/ohos/AppScope/app.json5'), 'utf8')).app;
  assert.deepEqual(app.alternateIcons.map(icon => icon.name), ['night', 'frost', 'ink']);
  const hash = filename => crypto.createHash('sha256').update(fs.readFileSync(filename)).digest('hex');
  for (const [variant, suffix] of [['mist', ''], ['night', '_night'], ['frost', '_frost'], ['ink', '_ink']]) {
    const resource = variant === 'mist' ? app.icon : app.alternateIcons.find(icon => icon.name === variant).icon;
    assert.equal(hash(path.join(repository, `app/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher${suffix}.png`)),
      hash(path.join(repository, `app/ohos/AppScope/resources/base/media/${resource.replace('$media:', '')}.png`)));
  }
  passed++;
  console.log(JSON.stringify({ passed, data: '固定BundleManager替身与原图字节校验，未切换设备图标' }));
})().catch(error => { console.error(error); process.exitCode = 1; });
