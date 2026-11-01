// scriptver-130：鸿蒙本机引擎启动器；认证地址仅交给宿主，不暴露原始日志。
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
import { verifyRuntimeManifest } from './runtime-manifest.mjs';
import { prepareOhosRuntime, brokerOptions } from './ohos-runtime-setup.mjs';
import { patchPersistence } from './persistence-publish.mjs';
import { patchFsPublish } from './fs-publish.mjs';
import { installOhosToolCapabilities } from '../scripts/patch-tool-capabilities.mjs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const bootstrapReport = process.argv[4];
import { createHash } from 'node:crypto';
export function parseLaunch(line, port) {
  const match = /http:\/\/127\.0\.0\.1:([0-9]+)\/\?token=([A-Za-z0-9._~%-]+)/.exec(line);
  return match && Number(match[1]) === port ? { baseUrl: `http://127.0.0.1:${port}/`, token: match[2] } : undefined;
}
export function publishOnce(state, result, write) {
  if (state.complete) return false;
  state.complete = true; write(result); return true;
}
async function main() {
  const [installed, fresh, reportFile, portText] = process.argv.slice(2);
  if (![installed, fresh, reportFile].every(value => value && path.isAbsolute(value))) throw new Error('BAD_ARGUMENTS');
  const port = Number(portText);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('BAD_PORT');
  const entry = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js');
  const manifest = verifyRuntimeManifest(installed);
  // 复用宿主提供的目录：由宿主决定是否清理，不再强制要求全新路径。
  // DSH 的 boot 阶段必须能在 node_modules 里解析到平台绑定包，
  // 否则报 host preparation failed: No usable native binding found。
  const platformRoot = path.join(installed, 'opt/dsh/node_modules/node-addon-require-builtin-openharmony-arm64');
  try {
    fs.mkdirSync(platformRoot, { recursive: true, mode: 0o700 });
    const platformManifest = path.join(platformRoot, 'package.json');
    if (!fs.existsSync(platformManifest)) {
      fs.writeFileSync(platformManifest, JSON.stringify({
        name: 'node-addon-require-builtin-openharmony-arm64',
        version: '0.1.9',
        main: 'index.cjs',
        type: 'commonjs',
      }), { mode: 0o600 });
    }
    const platformEntry = path.join(platformRoot, 'index.cjs');
    if (!fs.existsSync(platformEntry)) {
      const source = [
        "'use strict';",
        "const path = require('node:path');",
        "if (process.platform !== 'openharmony') throw new Error('UNSUPPORTED_PLATFORM');",
        "const root = process.env.DSH_HARMONY_NATIVE_LIBRARY_DIR;",
        "if (!root || !path.isAbsolute(root)) throw new Error('SIGNED_LIBRARY_DIRECTORY_MISSING');",
        "const library = path.join(root, 'libdsh_require_builtin.so');",
        "const binding = { exports: {} };",
        "process.dlopen(binding, library);",
        "Object.defineProperty(binding.exports, 'bindingPath', { value: library });",
        "module.exports = binding.exports;",
        "",
      ].join(String.fromCharCode(10));
      fs.writeFileSync(platformEntry, source, { mode: 0o600 });
    }
  } catch (error) {
    // staging 失败不阻塞，让 DSH 自己报错。
  }
  // 鸿蒙不支持 flock 系统调用：把 DSH 的 flock 实现改走签名平台库（libdsh_flock.so）。
  // 幂等：已适配过则跳过。
  try {
    const systemPackage = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai/node-addon-system-openharmony-arm64');
    fs.mkdirSync(systemPackage, { recursive: true, mode: 0o700 });
    const systemManifest = path.join(systemPackage, 'package.json');
    if (!fs.existsSync(systemManifest)) {
      fs.writeFileSync(systemManifest, JSON.stringify({
        name: '@deepseek-ai/node-addon-system-openharmony-arm64',
        version: '0.1.2',
        main: 'index.cjs',
        type: 'commonjs',
      }), { mode: 0o600 });
    }
    const systemEntry = path.join(systemPackage, 'index.cjs');
    if (!fs.existsSync(systemEntry)) {
      const source = [
        "'use strict';",
        "const path = require('node:path');",
        "if (process.platform !== 'openharmony') throw new Error('UNSUPPORTED_PLATFORM');",
        "const root = process.env.DSH_HARMONY_NATIVE_LIBRARY_DIR;",
        "if (!root || !path.isAbsolute(root)) throw new Error('SIGNED_LIBRARY_DIRECTORY_MISSING');",
        "const binding = { exports: {} };",
        "process.dlopen(binding, path.join(root, 'libdsh_flock.so'));",
        "module.exports = binding.exports;",
        "",
      ].join(String.fromCharCode(10));
      fs.writeFileSync(systemEntry, source, { mode: 0o600 });
    }
    const flockFile = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai/node-addon-system/lib/flock.js');
    if (fs.existsSync(flockFile)) {
      const original = fs.readFileSync(flockFile).toString('utf8');
      if (!original.includes('node-addon-system-openharmony-arm64')) {
        const anchorLine = '    const { platform, arch } = process;';
        const patch = "    if (process.platform === 'openharmony') {\n"
          + "        binding = createRequire(import.meta.url)('@deepseek-ai/node-addon-system-openharmony-arm64');\n"
          + "        return binding;\n"
          + "    }\n";
        if (original.split(anchorLine).length === 2) {
          fs.writeFileSync(flockFile, original.replace(anchorLine, patch + anchorLine), { mode: 0o600 });
        }
      }
    }
  } catch (error) {
    // flock 适配失败不阻塞启动，交由 DSH 自己报错。
  }

  // 排他发布必须保留 EEXIST；普通 rename 会覆盖并发创建的会话。
  const persistence = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js');
  const persistenceSource = fs.readFileSync(persistence, 'utf8');
  const patchedPersistence = patchPersistence(persistenceSource, new URL('./persistence-publish.mjs', import.meta.url).href);
  if (patchedPersistence !== persistenceSource) fs.writeFileSync(persistence, patchedPersistence, { mode: 0o600 });

  // 文件工具的新建发布也必须保留排他性；固定源码不匹配时停止启动。
  const fsLocalPublish = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js');
  const fsPublishSource = fs.readFileSync(fsLocalPublish, 'utf8');
  const patchedFsPublish = patchFsPublish(fsPublishSource, new URL('./persistence-publish.mjs', import.meta.url).href);
  if (patchedFsPublish !== fsPublishSource) fs.writeFileSync(fsLocalPublish, patchedFsPublish, { mode: 0o600 });


  // 在原版 web-app 完成启动审计并生成真实认证地址后通知宿主。
  const webApp = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai/dsh-web-app/lib/index.js');
  const readyAnchor = 'if (config.printUrl) console.log(`dsh web: ${authenticatedUrl}`);';
  let webSource = fs.readFileSync(webApp, 'utf8');
  if (!webSource.includes('HARMONY_ENDPOINT_READY')) {
    if (webSource.split(readyAnchor).length !== 2) throw new Error('WEB_READY_PATCH_MISMATCH');
    webSource = webSource.replace(readyAnchor,
      'if (typeof globalThis.__dshEndpointReady === "function") globalThis.__dshEndpointReady(authenticatedUrl, connectionCtx); /* HARMONY_ENDPOINT_READY */ ' + readyAnchor);
    fs.writeFileSync(webApp, webSource, { mode: 0o600 });
  }

  // 鸿蒙没有 systemd：其 systemd-run / systemctl 的同步 spawnSync 探测会永久阻塞启动。
  try {
    const subprocessFile = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js');
    if (fs.existsSync(subprocessFile)) {
      let code = fs.readFileSync(subprocessFile).toString('utf8');
      if (!code.includes('HARMONY_NO_SYSTEMD')) {
        code = code.replace('function probeLinuxScope(internals = {}) {',
          'function probeLinuxScope(internals = {}) {\n\tif (process.platform === "openharmony") return; /* HARMONY_NO_SYSTEMD */', 1);
        fs.writeFileSync(subprocessFile, code, { mode: 0o600 });
      }
    }
  } catch (error) { }

  // 鸿蒙没有 systemd：这些探测里的同步 spawnSync 在鸿蒙上会永久阻塞 boot。
  try {
    const sp = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js');
    if (fs.existsSync(sp)) {
      let code = fs.readFileSync(sp).toString('utf8');
      if (!code.includes('HARMONY_NO_SYSTEMD_ALL')) {
        const guard = 'if (process.platform === ' + String.fromCharCode(34) + 'openharmony' + String.fromCharCode(34) + ') return; /* HARMONY_NO_SYSTEMD_ALL */';
        for (const fn of ['probeLinuxBootstrap', 'probeLinuxScope', 'probeLinuxManager']) {
          code = code.replace('function ' + fn + '(internals = {}) {', 'function ' + fn + '(internals = {}) { ' + guard);
        }
        fs.writeFileSync(sp, code, { mode: 0o600 });
      }
    }
  } catch (error) { }

  fs.mkdirSync(fresh, { recursive: true, mode: 0o700 });
  const folders = ['home', 'dsh-home', 'agents', 'tmp', 'workspace', 'config', 'cache'];
  for (const name of folders) fs.mkdirSync(path.join(fresh, name), { recursive: true, mode: 0o700 });
  // 如资产包含旧版无凭据初始化模板，仅补充尚不存在的配置。
  try {
    const source = path.join(installed, 'transport', 'preinit-dsh-home');
    if (fs.existsSync(source)) {
      const copyDir = (from, to) => {
        fs.mkdirSync(to, { recursive: true, mode: 0o700 });
        for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
          const f = path.join(from, entry.name);
          const t = path.join(to, entry.name);
          if (entry.isDirectory()) copyDir(f, t);
          else if (entry.name !== '.credentials.yaml' && !fs.existsSync(t)) fs.copyFileSync(f, t);
        }
      };
      copyDir(source, path.join(fresh, 'dsh-home'));
      // credentials-local 会拒绝启动在「权限宽于 owner」的凭据文件上。
      // 只处理这个文件，避免递归 chmod 带来的不确定开销。
      try {
        const credFile = path.join(fresh, 'dsh-home', '.credentials.yaml');
        if (fs.existsSync(credFile)) fs.chmodSync(credFile, 0o600);
      } catch (chmodErr) { }
    }
  } catch (error) { }

  // 仅移除旧探针自动生成且摘要完全匹配的禁用清单，不覆盖用户配置。
  const oldPatch = path.join(fresh, 'dsh-home', 'cordis.patch.yml');
  if (fs.existsSync(oldPatch) && createHash('sha256').update(fs.readFileSync(oldPatch)).digest('hex') ===
      '641f50e72bbcce8996af2daa2a2a359b60ac025cdfaef708c97ea133b445c521f') fs.unlinkSync(oldPatch);
  let startupStage = 'CLI_IMPORT';
  const safeLocation = error => {
    const stack = typeof error?.stack === 'string' ? error.stack : '';
    for (const line of stack.split('\n').slice(1, 12)) {
      const builtin = /node:([a-zA-Z0-9_/-]+):([0-9]+):([0-9]+)/.exec(line);
      if (builtin) return `NODE_${builtin[1].replaceAll('/', '_').replaceAll('-', '_').toUpperCase()}_L${builtin[2]}`.slice(0, 80);
      for (let index = 0; index < manifest.files.length; index++) {
        const name = manifest.files[index].path;
        if (!/\.(?:cjs|mjs|js)$/.test(name)) continue;
        const knownPath = path.join(installed, ...name.split('/'));
        const position = line.indexOf(knownPath);
        if (position < 0) continue;
        const location = /^:([0-9]+):([0-9]+)/.exec(line.slice(position + knownPath.length));
        return `ASSET_${index}${location ? `_L${location[1]}_C${location[2]}` : ''}`;
      }
    }
    return startupStage;
  };
  const safeCode = error => {
    if (typeof error?.code === 'string' && /^[A-Z0-9_]{1,80}$/.test(error.code)) return error.code;
    const login = /启动令牌交换HTTP ([0-9]{3})/.exec(error?.message ?? '');
    const list = /session\/list HTTP ([0-9]{3})/.exec(error?.message ?? '');
    if (/unsupported platform|platform .*not supported|not support.*openharmony/i.test(error?.message ?? '')) return 'DSH_UNSUPPORTED_PLATFORM';
    if (error?.name === 'ReferenceError') {
      const names = ['require', 'module', 'exports', '__dirname', '__filename', 'process', 'global', 'globalThis', 'crypto', 'fetch', 'WebSocket', 'Buffer', 'setTimeout', 'clearTimeout', 'navigator', 'URL', 'TextEncoder', 'AbortController', 'console', 'performance', 'localStorage', 'structuredClone', 'File', 'Blob', 'MessageChannel', 'ReadableStream', 'WritableStream', 'TransformStream', 'StartupError', 'startupStage', 'Event', 'EventTarget', 'CustomEvent'];
      const missing = /^([A-Za-z_$][A-Za-z0-9_$]*) is not defined$/.exec(error.message ?? '');
      if (missing && names.includes(missing[1])) return `REFERENCE_${missing[1].toUpperCase()}`;
      if (/before initialization/.test(error.message ?? '')) return 'REFERENCE_BEFORE_INITIALIZATION';
    }
    if (['TypeError', 'SyntaxError', 'RangeError', 'ReferenceError'].includes(error?.name)) return `DSH_${error.name.toUpperCase()}`;
    return login ? `LOGIN_HTTP_${login[1]}` : list ? `SESSION_LIST_HTTP_${list[1]}` : 'DSH_SMOKE_FAILED';
  };
  const save = result => {
    const text = JSON.stringify({ modelRequestSent: false, ...result }) + String.fromCharCode(10);
    fs.writeFileSync(reportFile, text, { mode: 0o600 });
  };
  let started = false, stopping = false;
  const completion = { complete: false };
  const failure = (code, error) => {
    publishOnce(completion, { phase: 'FAILED', code, failedAt: safeLocation(error) }, save);
  };
  let watchdog;
  const stop = () => { if (stopping) return; stopping = true; clearTimeout(watchdog); setTimeout(() => process.kill(process.pid, 'SIGTERM'), 50); };
  async function ready(launch) {
    if (started || completion.complete) return; started = true;
    // 端点已就绪：撤掉启动超时看门狗，否则 90 秒后会把常驻服务 SIGTERM 掉。
    if (watchdog) { clearTimeout(watchdog); watchdog = undefined; }
    // 用真实令牌交换和只读接口验证服务，令牌始终留在进程私有内存/文件。
    try {
      const { probe } = await import(pathToFileURL(path.join(installed, 'probe/session-list-probe.mjs')).href);
      const verified = await probe(launch.baseUrl, launch.token);
      fs.writeFileSync(path.join(path.dirname(reportFile), 'verification.json'),
        JSON.stringify({ phase: 'SESSION_LIST_OK', ...verified }), { mode: 0o644 });
    } catch (error) {
      failure(safeCode(error), error);
      stop();
      return;
    }
    publishOnce(completion, {
      phase: 'DSH_ENDPOINT_READY',
      base_url: launch.baseUrl,
      access_token: launch.token,
      modelRequestSent: false,
    }, value => {
      try { fs.writeFileSync(reportFile, JSON.stringify(value) + '\n', { mode: 0o600 }); } catch {}
    });
  }

  globalThis.__dshEndpointReady = (url) => {
    const launch = parseLaunch(url, port);
    if (!launch) { failure('INVALID_LOCAL_ENDPOINT'); stop(); return; }
    void ready(launch);
  };

  // 整行在私有内存中消费；其他原始日志直接丢弃，禁止父UI展示基础探针的全日志。
  function sink() {
    let partial = '';
    return (chunk, encoding, callback) => {
      partial += Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk);
      let newline;
      while ((newline = partial.indexOf('\n')) >= 0) {
        const line = partial.slice(0, newline); partial = partial.slice(newline + 1);
        const launch = parseLaunch(line, port); if (launch) void ready(launch);
      }
      if (partial.length > 65536) partial = '';
      const done = typeof encoding === 'function' ? encoding : callback;
      if (typeof done === 'function') process.nextTick(done);
      return true;
    };
  }
  process.stdout.write = sink();
  process.stderr.write = sink();
  process.on('unhandledRejection', error => { failure(safeCode(error), error); stop(); });
  process.on('uncaughtException', error => { failure(safeCode(error), error); stop(); });
  process.on('exit', code => { if (!completion.complete) failure(`DSH_EXIT_${code}`); });
  const privateBroker = brokerOptions(process.env);
  const nativeDirectory = process.env.DSH_HARMONY_NATIVE_LIBRARY_DIR;
  if (!nativeDirectory || !path.isAbsolute(nativeDirectory)) throw new Error('SIGNED_LIBRARY_DIRECTORY_MISSING');
  for (const name of Object.keys(process.env)) delete process.env[name];
  Object.assign(process.env, { DSH_HARMONY_NATIVE_LIBRARY_DIR: nativeDirectory, DSH_HARMONY_DURABLE_ROOT: path.dirname(fresh), HOME: path.join(fresh, 'home'), USERPROFILE: path.join(fresh, 'home'), APPDATA: path.join(fresh, 'config'), LOCALAPPDATA: path.join(fresh, 'cache'), XDG_CONFIG_HOME: path.join(fresh, 'config'), XDG_CACHE_HOME: path.join(fresh, 'cache'), DSH_HOME: path.join(fresh, 'dsh-home'), DSH_AGENTS_HOME: path.join(fresh, 'agents'), TMPDIR: path.join(fresh, 'tmp'), TMP: path.join(fresh, 'tmp'), TEMP: path.join(fresh, 'tmp'), DSH_TELEMETRY_DISABLED: '1', NARB_DISABLE_NATIVE_CACHE: '1', NO_COLOR: '1', TZ: 'Asia/Shanghai' });
  if (privateBroker !== null) Object.assign(process.env, { DSH_HARMONY_BROKER_FD: String(privateBroker.fd), DSH_HARMONY_BROKER_GENERATION: privateBroker.generation });
  // 鸿蒙禁止第三方应用建硬链接：附件落盘的 link() 会失败（甚至阻塞）。
  // 改成 link 失败即回退 copyFile，保留原 EEXIST 语义。
  try {
    const att = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js');
    if (fs.existsSync(att)) {
      let code = fs.readFileSync(att).toString('utf8');
      if (!code.includes('HARMONY_LINK_FALLBACK_ATT')) {
        code = code.replace(
          'import { chmod, link, mkdir, open, readFile, rename, rm, unlink, writeFile } from "node:fs/promises";',
          'import { chmod, link as nodeLink, copyFile, mkdir, open, readFile, rename, rm, unlink, writeFile } from "node:fs/promises";' +
          String.fromCharCode(10) +
          'const link = async (a, b) => { try { return await nodeLink(a, b); } catch (e) { if (!e || !["EACCES", "EPERM", "ENOTSUP", "EXDEV"].includes(e.code)) throw e; return await copyFile(a, b, constants.COPYFILE_EXCL); } }; /* HARMONY_LINK_FALLBACK_ATT */', 1);
        const durableAnchor = 'await ensureDurableDirectory(home, parse(home).root);';
        if (code.split(durableAnchor).length !== 2) throw new Error('ATTACHMENT_DURABLE_PATCH_MISMATCH');
        code = code.replace(durableAnchor,
          'let boundary = parse(home).root; if (process.platform === "openharmony") { const configured = process.env.DSH_HARMONY_DURABLE_ROOT; if (!configured || !home.startsWith(resolve(configured) + "/")) throw new Error("ATTACHMENT_OUTSIDE_SANDBOX"); boundary = resolve(configured); } await ensureDurableDirectory(home, boundary); /* HARMONY_DURABLE_BOUNDARY */');
        fs.writeFileSync(att, code, { mode: 0o600 });
      }
    }
  } catch (attErr) { }

  // fs-local 的 watch 走 node:fs 的 watch 绑定，运行时改 fs.watch 改不到 ESM 绑定，
  // 这里直接改源码：鸿蒙没有可用 inotify，watch 会同步死锁整个事件循环。
  try {
    const fsLocal = path.join(installed, 'opt/dsh/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js');
    if (fs.existsSync(fsLocal)) {
      let code = fs.readFileSync(fsLocal).toString('utf8');
      if (!code.includes('HARMONY_NO_WATCH')) {
        code = code.replace('	async watch(target, changed, signal) {',
          '	async watch(target, changed, signal) { throw new Error("ENOSYS: fs.watch unsupported on openharmony"); /* HARMONY_NO_WATCH */', 1);
        fs.writeFileSync(fsLocal, code, { mode: 0o600 });
      }
    }
  } catch (fsLocalError) { }

  // 鸿蒙没有可用的 inotify：fs.watch 会同步死锁，表现为整个事件循环停住（watchdog 都不触发）。
  // 改成快速失败，让依赖方走自己的 watch-unsupported 降级路径。
  try {
    const noWatch = () => { throw Object.assign(new Error('ENOSYS: fs.watch is not supported on openharmony'), { code: 'ENOSYS' }); };
    fs.watch = noWatch;
    if (fs.promises) {
      fs.promises.watch = async function* () { throw Object.assign(new Error('ENOSYS: fs.promises.watch is not supported on openharmony'), { code: 'ENOSYS' }); };
    }
    syncBuiltinESMExports();
  } catch (watchPatchError) { }

  process.chdir(path.join(fresh, 'workspace'));
  installOhosToolCapabilities(installed);
  const platformPatch = prepareOhosRuntime(installed, process.env);
  process.argv = [process.execPath, entry, 'web', '--patch', platformPatch, '--host', '127.0.0.1', '--port', String(port), '--no-open'];
  save({ phase: 'DSH_STARTING', stdoutExposed: false, stderrExposed: false });
  watchdog = setTimeout(() => { failure("DSH_START_TIMEOUT"); stop(); }, 90000);

  try {
    const cli = await import(pathToFileURL(entry).href);
    if (typeof cli.runCli !== 'function') throw new Error('DSH_CLI_ENTRY_MISSING');
    startupStage = 'CLI_RUN';
    await cli.runCli();
    await new Promise(() => {});
  } catch (error) { failure(safeCode(error), error); stop(); }
}
if (process.argv[2] === '--self-test') {
  const assert = await import('node:assert/strict');
  assert.deepEqual(parseLaunch('dsh web: http://127.0.0.1:38081/?token=fixture-only', 38081), { baseUrl: 'http://127.0.0.1:38081/', token: 'fixture-only' });
  assert.equal(parseLaunch('dsh web: http://127.0.0.1:38082/?token=fixture-only', 38081), undefined);
  assert.equal(parseLaunch('dsh web: http://example.com:38081/?token=fixture-only', 38081), undefined);
  const reports = [], completion = { complete: false };
  assert.equal(publishOnce(completion, { phase: 'FAILED', code: 'DSH_START_TIMEOUT' }, value => reports.push(value)), true);
  assert.equal(publishOnce(completion, { phase: 'SESSION_LIST_OK' }, value => reports.push(value)), false);
  assert.deepEqual(reports, [{ phase: 'FAILED', code: 'DSH_START_TIMEOUT' }]);
  console.log('4项检查通过：3项登录解析+超时后迟到成功不覆盖；未加载DSH');
} else main().catch(error => {
  const code = typeof error.code === 'string' && /^[A-Z0-9_]{1,80}$/.test(error.code) ? error.code : /^[A-Z0-9_]{1,80}$/.test(error.message) ? error.message : 'DSH_PREFLIGHT_FAILED';
  if (bootstrapReport && path.isAbsolute(bootstrapReport)) {
    try { fs.writeFileSync(bootstrapReport, JSON.stringify({ phase: 'PREFLIGHT_FAILED', code, modelRequestSent: false }) + '\n', { mode: 0o600 }); } catch {}
  }
  process.exitCode = 1;
});
