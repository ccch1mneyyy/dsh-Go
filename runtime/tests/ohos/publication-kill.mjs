import { spawn } from 'node:child_process';
import * as fs from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
import { createAtomicPublisher, cleanupOwnedTemporary } from '../../ohos/publication/atomic.mjs';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const self = fileURLToPath(import.meta.url);
const symbol = Symbol.for('dsh.go.ohos.publication');
function gate(phase, synchronous = false) {
  // writeSync is intentional: the synchronous native wrapper must not return
  // until the parent has observed this exact post-rename boundary.
  process.getBuiltinModule('fs').writeSync(1, `${JSON.stringify({ gate: phase })}\n`);
  if (synchronous) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
  setInterval(() => {}, 1000);
  return new Promise(() => {});
}

if (process.argv[2] === 'child') {
  const config = JSON.parse(await fs.readFile(process.argv[3], 'utf8'));
  const native = process._linkedBinding('dsh_ohos_publication');
  const receipt = config.receipt;
  const childFs = {
    link: fs.link,
    async open(path, ...args) {
      const handle = await fs.open(path, ...args);
      const isTemporary = receipt ? path === receipt.path : String(path).includes('.dsh-ohos-publish-');
      if (config.phase === 'created-unregistered' && isTemporary && args[0] === 'wx') {
        await gate(config.phase);
      }
      if (isTemporary || path === config.target) {
        const writeFile = handle.writeFile.bind(handle), sync = handle.sync.bind(handle);
        let writes = 0;
        handle.writeFile = async bytes => {
          await writeFile(bytes); writes++;
          if (writes === 1 && ((config.phase === 'mid-copy' && (config.baseline || isTemporary)) ||
              (config.phase === 'fallback-mid-copy' && path === config.target))) await gate(config.phase);
        };
        handle.sync = async () => {
          await sync();
          if (config.phase === 'after-sync' && isTemporary) await gate(config.phase);
        };
      }
      return handle;
    },
  };
  if (!config.baseline) {
    const options = {
      fs: { ...fs, ...childFs },
      renameNoReplace(source, target) {
        if (config.injectEINVAL) throw Object.assign(new Error('injected unsupported flag'), { code: 'EINVAL', syscall: 'renameat2' });
        native.renameNoReplace(source, target);
        if (config.phase === 'after-rename') gate(config.phase, true);
      },
    };
    if (receipt) {
      options.createTemporary = async ({ parent, fs: activeFs }) => {
        assert.equal(dirname(receipt.path), parent);
        const handle = await activeFs.open(receipt.path, 'r+');
        const info = await handle.stat({ bigint: true });
        assert.equal(String(info.dev), receipt.dev); assert.equal(String(info.ino), receipt.ino);
        assert.equal(info.size, 0n);
        return { path: receipt.path, handle };
      };
      options.registerTemporary = value => assert.deepEqual(value, receipt);
    }
    Object.defineProperty(globalThis, symbol, { value: { protocolVersion: 1, publish: createAtomicPublisher(options) } });
  }
  const { publishOhosExclusive } = await import(pathToFileURL(config.moduleFile));
  try {
    await publishOhosExclusive(config.source, config.target, childFs);
    process.stdout.write(`${JSON.stringify({ published: true })}\n`);
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ published: false, code: error.code, name: error.name, message: error.message })}\n`);
    if (!['EEXIST'].includes(error.code)) process.exitCode = 1;
  }
} else {
  const args = new Map();
  for (let i = 2; i < process.argv.length; i += 2) {
    if (!process.argv[i].startsWith('--') || !process.argv[i + 1]) throw new Error('expected --name value pairs');
    args.set(process.argv[i].slice(2), resolve(process.argv[i + 1]));
  }
  for (const name of ['node', 'preload', 'linked-lib', 'before-prefix', 'candidate-prefix', 'out']) {
    if (!args.has(name)) throw new Error(`missing --${name}`);
  }
  const directory = await fs.mkdtemp(join(tmpdir(), 'dsh-publication-kill-'));
  const env = { PATH: process.env.PATH, LANG: 'C.UTF-8', LD_PRELOAD: args.get('linked-lib'), DSH_GO_OHOS_SIM_PLATFORM: 'openharmony' };
  const rows = [], temporaryModules = [];
  const inputs = { node: process.version, nodeExecutable: args.get('node'),
    nodeSHA256: sha(await fs.readFile(args.get('node'))),
    linkedLibrary: args.get('linked-lib'), linkedLibrarySHA256: sha(await fs.readFile(args.get('linked-lib'))),
    simulationPreload: args.get('preload'), simulationPreloadSHA256: sha(await fs.readFile(args.get('preload'))),
    driverSHA256: sha(await fs.readFile(self)),
    atomicSourceSHA256: sha(await fs.readFile(new URL('../../ohos/publication/atomic.mjs', import.meta.url))) };
  async function state(path) {
    try { const bytes = await fs.readFile(path); return { exists: true, bytes: bytes.length, sha256: sha(bytes) }; }
    catch (error) { if (error.code === 'ENOENT') return { exists: false }; throw error; }
  }
  async function run(config, stopAtGate) {
    const path = join(directory, `config-${randomUUID()}.json`); await fs.writeFile(path, JSON.stringify(config));
    const child = spawn(args.get('node'), ['--jitless', '--import', args.get('preload'), self, 'child', path], { env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', killedAtGate = false, timedOut = false;
    const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, 15000);
    child.stdout.on('data', chunk => {
      stdout += chunk;
      if (stopAtGate && !killedAtGate && stdout.includes(`"gate":"${config.phase}"`)) {
        killedAtGate = true; child.kill('SIGKILL');
      }
    });
    child.stderr.on('data', chunk => { stderr += chunk; });
    return await new Promise((accept, reject) => {
      child.once('error', error => { clearTimeout(timer); reject(error); });
      child.once('close', (code, signal) => { clearTimeout(timer); accept({ code, signal, stdout, stderr, killedAtGate, timedOut }); });
    });
  }
  async function moduleFor(prefix, provider) {
    const original = join(prefix, 'node_modules/@deepseek-ai', provider, 'lib/index.js');
    const bytes = await fs.readFile(original);
    const moduleFile = join(dirname(original), `.m3-atomic-${randomUUID()}.mjs`);
    await fs.writeFile(moduleFile, Buffer.concat([bytes, Buffer.from('\nexport { publishOhosExclusive };\n')]), { flag: 'wx' });
    temporaryModules.push(moduleFile);
    return { moduleFile, providerSHA256: sha(bytes) };
  }
  try {
    for (const provider of ['dsh-attachment-local', 'dsh-session-persistence-jsonl']) {
      const before = await moduleFor(args.get('before-prefix'), provider);
      const candidate = await moduleFor(args.get('candidate-prefix'), provider);
      for (const phase of ['baseline-mid-copy', 'mid-copy', 'after-sync', 'after-rename', 'fallback-mid-copy', 'created-unregistered']) {
        const caseDirectory = join(directory, `${provider}-${phase}`); await fs.mkdir(caseDirectory);
        const source = join(caseDirectory, 'source'), target = join(caseDirectory, 'final');
        const bytes = Buffer.alloc(3 * 65536 + 17, 97); await fs.writeFile(source, bytes);
        const baseline = phase === 'baseline-mid-copy', unregistered = phase === 'created-unregistered';
        let receipt, recordPath;
        if (!baseline && !unregistered) {
          const path = join(caseDirectory, `.dsh-ohos-publish-${randomUUID()}.tmp`);
          const handle = await fs.open(path, 'wx', 0o600);
          const info = await handle.stat({ bigint: true });
          receipt = { path, dev: String(info.dev), ino: String(info.ino) };
          await handle.sync(); await handle.close();
          recordPath = join(directory, `registered-${randomUUID()}.json`);
          const record = await fs.open(recordPath, 'wx', 0o600);
          await record.writeFile(JSON.stringify(receipt)); await record.sync(); await record.close();
          assert.deepEqual(JSON.parse(await fs.readFile(recordPath, 'utf8')), receipt);
        }
        const config = { ...(baseline ? before : candidate), source, target, receipt, baseline,
          phase: baseline ? 'mid-copy' : phase, injectEINVAL: phase === 'fallback-mid-copy' };
        const first = await run(config, true);
        assert.equal(first.timedOut, false, first.stderr); assert.equal(first.killedAtGate, true, first.stderr);
        assert.equal(first.signal, 'SIGKILL');
        const sourceAfterKill = await state(source), finalAfterKill = await state(target);
        assert.equal(sourceAfterKill.sha256, sha(bytes));
        let temporaryAfterKill = receipt ? await state(receipt.path) : null, cleanup = null;
        if (baseline || phase === 'fallback-mid-copy') {
          assert.equal(finalAfterKill.bytes, 65536); assert.notEqual(finalAfterKill.sha256, sha(bytes));
        } else if (phase === 'after-rename') {
          assert.equal(finalAfterKill.sha256, sha(bytes)); assert.deepEqual(temporaryAfterKill, { exists: false });
        } else {
          assert.deepEqual(finalAfterKill, { exists: false });
          if (phase === 'mid-copy') assert.equal(temporaryAfterKill.bytes, 65536);
          if (phase === 'after-sync') assert.equal(temporaryAfterKill.sha256, sha(bytes));
        }
        if (receipt) cleanup = cleanupOwnedTemporary(JSON.parse(await fs.readFile(recordPath, 'utf8')));
        const unknownBeforeRetry = (await fs.readdir(caseDirectory)).filter(name => name.startsWith('.dsh-ohos-publish-'));
        if (unregistered) {
          assert.equal(unknownBeforeRetry.length, 1);
          temporaryAfterKill = await state(join(caseDirectory, unknownBeforeRetry[0]));
          assert.equal(temporaryAfterKill.bytes, 0);
        } else assert.deepEqual(unknownBeforeRetry, []);
        const retry = await run({ ...config, receipt: undefined, phase: 'retry', injectEINVAL: false }, false);
        assert.equal(retry.code, 0, retry.stderr); assert.equal(retry.timedOut, false);
        const retryResult = JSON.parse(retry.stdout.trim());
        const shouldExist = baseline || phase === 'fallback-mid-copy' || phase === 'after-rename';
        if (shouldExist) { assert.equal(retryResult.published, false); assert.equal(retryResult.code, 'EEXIST'); }
        else assert.equal(retryResult.published, true);
        const finalAfterRetry = await state(target);
        if (!baseline && phase !== 'fallback-mid-copy') assert.equal(finalAfterRetry.sha256, sha(bytes));
        else assert.equal(finalAfterRetry.bytes, 65536);
        assert.equal((await state(source)).sha256, sha(bytes));
        const unknownAfterRetry = (await fs.readdir(caseDirectory)).filter(name => name.startsWith('.dsh-ohos-publish-'));
        assert.deepEqual(unknownAfterRetry, unknownBeforeRetry);
        rows.push({ provider, phase, providerSHA256: config.providerSHA256,
          linkFailure: 'real O0 preload forces EACCES', nativeCommit: baseline ? 'not called' : (config.injectEINVAL ? 'injected EINVAL; legacy fallback' : 'real Linux renameat2'),
          registrationScope: receipt ? 'parent creates and persists path/dev/ino before child starts' : (unregistered ? 'no receipt; automatic cleanup deliberately not attempted' : 'old helper'),
          killedBy: first.signal, sourceAfterKill, finalAfterKill, temporaryAfterKill, cleanup,
          retry: retryResult, finalAfterRetry, unknownPreserved: unknownAfterRetry.length,
          requirement: baseline || phase === 'fallback-mid-copy' ? 'KNOWN_RISK_REPRODUCED' : (unregistered ? 'ATOMIC_RETRY_PASSED_AUTOMATIC_ORPHAN_RECOVERY_UNRESOLVED' : 'ATOMIC_VISIBILITY_AND_RECORDED_RECOVERY_PASSED'),
          firstProcess: first, retryProcess: retry });
      }
    }
    await fs.mkdir(dirname(args.get('out')), { recursive: true });
    await fs.writeFile(args.get('out'), JSON.stringify({ inputs,
      scope: 'real provider helper with export-only instrumentation; not public ATTACHMENT_CORRUPT mapping; Linux SIGKILL, not power loss or OHOS ABI',
      status: 'MEASURED_SCOPED_RESULTS_WITH_UNRESOLVED_AUTOMATIC_ORPHAN_RECOVERY', rows }, null, 2) + '\n');
    console.log(JSON.stringify({ out: args.get('out'), cases: rows.length, phases: rows.map(row => `${row.provider}:${row.phase}:${row.requirement}`) }, null, 2));
  } finally {
    for (const path of temporaryModules) await fs.rm(path, { force: true });
    await fs.rm(directory, { recursive: true, force: true });
  }
}
