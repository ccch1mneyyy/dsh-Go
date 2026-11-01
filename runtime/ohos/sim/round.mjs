import http from 'node:http';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { startFakeModel } from './fake-model.mjs';

const { values } = parseArgs({ options: {
  prefix: { type: 'string' }, out: { type: 'string' }, mode: { type: 'string', default: 'jit' },
  platform: { type: 'boolean', default: false },
  patch: { type: 'string', multiple: true, default: [] },
  import: { type: 'string', multiple: true, default: [] },
  'expose-internals': { type: 'boolean', default: false },
} });
if (!values.prefix || !values.out || !['jit', 'jitless', 'sim'].includes(values.mode)) {
  throw new Error('usage: node round.mjs --prefix <locked patched DSH prefix> --out <new case directory> --mode jit|jitless|sim');
}
const prefix = resolve(values.prefix);
const out = resolve(values.out);
await mkdir(out, { recursive: false }); // A measurement never silently reuses another case's home.
const workspace = join(out, 'workspace');
await mkdir(workspace);
const require = createRequire(join(prefix, 'package.json'));
const { WebSocket } = require('ws'); // Already in the locked DSH dependency tree.
const model = await startFakeModel(workspace);
const overlay = join(out, 'model.patch.yml');
await writeFile(overlay, JSON.stringify([
  { id: 'llm-pi-ai', config: { providers: { 'ohos-fake': {
    api: 'openai-completions', baseURL: model.baseURL, apiKeyEnv: 'DSH_OHOS_TEST_KEY',
    retryPolicy: { mode: 'normal', maxRetries: 0 },
    models: [{ id: 'ohos-script', contextWindow: 32768, maxTokens: 4096, reasoningEfforts: false }],
  } } } },
  { id: 'agent-default-model', config: { provider: 'ohos-fake', model: 'ohos-script' } },
  { id: 'session-title-llm', disabled: true },
], null, 2)); // JSON is valid YAML and cannot inject expressions from paths.

function exchange(url, { body, cookie } = {}) {
  return new Promise((accept, reject) => {
    const bytes = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
    const req = http.request(url, {
      method: bytes ? 'POST' : 'GET', headers: {
        ...(cookie ? { Cookie: cookie } : {}),
        ...(bytes ? { 'content-type': 'application/json', 'content-length': bytes.length } : {}),
      },
    }, (res) => {
      const chunks = []; let size = 0;
      res.on('data', (data) => {
        size += data.length;
        if (size > 16 * 1024 * 1024) res.destroy(new Error('test HTTP response limit'));
        else chunks.push(data);
      });
      res.on('end', () => accept({ status: res.statusCode, headers: res.headers, text: Buffer.concat(chunks).toString('utf8') }));
      res.on('error', reject);
    });
    req.on('error', reject);
    req.setTimeout(15000, () => req.destroy(new Error('test HTTP timeout')));
    req.end(bytes);
  });
}

const flags = [];
if (values.mode !== 'jit') flags.push('--jitless');
if (values['expose-internals']) flags.push('--expose-internals');
if (values.mode === 'sim') flags.push('--import', fileURLToPath(new URL('./preload.mjs', import.meta.url)));
for (const name of values.import) flags.push('--import', resolve(name));
const env = {
  PATH: process.env.PATH, LANG: 'C.UTF-8', DSH_HOME: join(out, 'home'),
  DSH_OHOS_TEST_KEY: 'ohos-local-fixture-only', DSH_PERMISSION_MODE: 'workspace-write',
};
if (values.mode === 'sim') env.DSH_GO_OHOS_SIM = '1';
if (values.platform) env.DSH_GO_OHOS_SIM_PLATFORM = 'openharmony';
const args = [...flags, join(prefix, 'node_modules/@deepseek-ai/dsh/lib/bin.js'), 'web'];
for (const name of [...values.patch, overlay]) args.push('--patch', resolve(name));
args.push('--host', '127.0.0.1', '--port', '0', '--no-open');
const report = { mode: values.mode, platformOverride: values.platform, node: process.version, status: 'BLOCKED', stage: 'startup', approvals: 0, events: [], modelRequests: model.requests };
const start = performance.now();
const engine = spawn(process.execPath, args, { env, cwd: workspace, stdio: ['ignore', 'pipe', 'pipe'] });
const engineClosed = new Promise((resolve) => engine.once('close', resolve));
let engineLog = '', socket, cookie, launchToken, clientId;
const ready = Promise.withResolvers();
const startupTimer = setTimeout(() => ready.reject(new Error('engine startup deadline')), 45000);
const consume = (data) => {
  engineLog += data.toString('utf8');
  if (engineLog.length > 4 * 1024 * 1024) { ready.reject(new Error('engine diagnostic limit')); engine.kill(); return; }
  const match = /dsh web: (http:\/\/127\.0\.0\.1:\d+\/\?token=[A-Za-z0-9_-]+)/u.exec(engineLog);
  if (match) ready.resolve(new URL(match[1]));
};
engine.stdout.on('data', consume); engine.stderr.on('data', consume);
engine.once('error', ready.reject);
engine.once('exit', (code, signal) => ready.reject(new Error(`engine exited before readiness: ${code ?? signal}`)));

try {
  const launch = await ready.promise;
  clearTimeout(startupTimer);
  report.urlReadyMs = performance.now() - start;
  launchToken = launch.searchParams.get('token');
  const login = await exchange(launch);
  if (login.status !== 303) throw new Error(`launch token exchange returned ${login.status}`);
  cookie = login.headers['set-cookie']?.find((item) => item.startsWith('dsh-auth-'))?.split(';')[0];
  if (!cookie) throw new Error('launch exchange did not return dsh-auth cookie');
  const base = launch.origin;
  const rpc = async (endpoint, args = {}) => {
    const rpcId = randomUUID();
    const response = await exchange(new URL(`/api/${endpoint}`, base), {
      cookie, body: { type: 'client-request', rpcId, method: endpoint, payload: { args } },
    });
    if (response.status !== 200) throw new Error(`RPC ${endpoint}: HTTP ${response.status}`);
    const wire = JSON.parse(response.text);
    if (wire.rpcId !== rpcId || wire.type !== 'server-response') throw new Error(`RPC ${endpoint}: invalid envelope`);
    if (wire.result?.ok !== true) throw new Error(`RPC ${endpoint}: ${wire.result?.error?.code}: ${wire.result?.error?.message}`);
    return wire.result.value;
  };
  const frames = [], waiters = new Set();
  let muxError;
  function waitFrame(predicate) {
    if (muxError) return Promise.reject(muxError);
    const found = frames.find(predicate);
    if (found) return Promise.resolve(found);
    return new Promise((resolve, reject) => {
      const entry = { predicate, resolve: (frame) => { clearTimeout(entry.timer); waiters.delete(entry); resolve(frame); } };
      entry.timer = setTimeout(() => { waiters.delete(entry); reject(new Error(`mux deadline at ${report.stage}`)); }, 45000);
      entry.reject = (error) => { clearTimeout(entry.timer); waiters.delete(entry); reject(error); };
      waiters.add(entry);
    });
  }
  const fail = (error) => { muxError = error; for (const waiter of [...waiters]) waiter.reject(error); };
  socket = new WebSocket(base.replace('http:', 'ws:') + '/api/remote.mux', { headers: { Cookie: cookie }, handshakeTimeout: 15000 });
  socket.on('error', fail);
  socket.on('close', () => fail(new Error('mux closed')));
  socket.on('message', (bytes) => {
    try {
      const frame = JSON.parse(bytes.toString());
      frames.push(frame);
      if (frame.type === 'error') { fail(new Error(`mux ${frame.streamId}: ${frame.error?.code}`)); return; }
      const value = frame.value;
      if (value?.type === 'ready') clientId = value.clientId;
      if (value?.type === 'waterfall' && value.event === 'approval/request') {
        report.approvals++;
        rpc('$events/result', { clientId, eventId: value.eventId, outcome: { kind: 'result', value: 'allowed-once' } }).catch(fail);
      }
      if (value?.type === 'event') report.events.push(value.event);
      for (const waiter of [...waiters]) if (waiter.predicate(frame)) waiter.resolve(frame);
    } catch (error) { fail(error); }
  });
  await once(socket, 'open', { signal: AbortSignal.timeout(15000) });
  socket.send(JSON.stringify({ type: 'open', streamId: 'host', endpoint: '$events', payload: { args: {} } }));
  await waitFrame((frame) => frame.streamId === 'host' && frame.value?.type === 'ready');
  report.hostReadyMs = performance.now() - start;
  report.stage = 'session/create';
  const { sessionId } = await rpc('session/create', { request: { cwd: workspace, agentPreset: 'standard' } });
  report.stage = 'session/follow';
  socket.send(JSON.stringify({ type: 'open', streamId: 'session', endpoint: 'session/follow', payload: { args: { request: { address: { kind: 'session', sessionId }, assistantStream: true, maxMessages: 100 } } } }));
  await waitFrame((frame) => frame.streamId === 'session' && frame.value?.type === 'snapshot');
  report.stage = 'round';
  const roundStart = performance.now();
  await rpc('session/prompt', { request: { requestId: randomUUID(), sessionId, mode: 'queue', content: [{ type: 'text', text: 'O0 scripted file, search, shell and approval round.' }] } });
  const end = await waitFrame((frame) => frame.streamId === 'session' && frame.value?.event?.type === 'turn/end');
  report.firstRoundMs = performance.now() - roundStart;
  report.turnEnd = end.value.event.data;
  if (report.turnEnd.reason?.kind !== 'completed') {
    const reason = report.turnEnd.reason;
    throw new Error(`turn ended ${reason?.kind}: ${reason?.error?.code ?? ''} ${reason?.error?.message ?? ''}`);
  }
  const expected = ['write', 'edit', 'read', 'grep', 'bash'];
  const requested = model.requests.filter((row) => row.requestedTool).map((row) => row.requestedTool);
  if (JSON.stringify(requested) !== JSON.stringify(expected)) throw new Error('model did not finish all five tool steps');
  const results = report.events.filter((event) => event.type === 'tool/result');
  if (results.length !== 5 || results.some((event) => event.data.message?.isError !== false)) {
    throw new Error('at least one real tool failed; inspect tool/result events');
  }
  if (!results[2].data.message.content.some((part) => part.text?.includes('修改后内容'))) throw new Error('read result missing edited content');
  if (!results[3].data.message.content.some((part) => part.text?.includes('修改后内容'))) throw new Error('grep result missing edited content');
  if (!results[4].data.message.content.some((part) => part.text?.includes('shell-ok'))) throw new Error('bash result missing marker');
  const contents = await readFile(model.file, 'utf8');
  if (contents !== '修改后内容\n') throw new Error('file side effect did not match the script');
  if (report.approvals < 1) throw new Error('round did not exercise an approval');
  report.status = 'PASS';
  report.stage = 'complete';
} catch (error) {
  report.error = { name: error.name, message: error.message };
} finally {
  clearTimeout(startupTimer);
  socket?.terminate();
  if (engine.pid && engine.exitCode === null && engine.signalCode === null) {
    const force = setTimeout(() => engine.kill('SIGKILL'), 5000);
    engine.kill('SIGTERM'); await engineClosed; clearTimeout(force);
  }
  await engineClosed; // Includes spawn failure and drains stdout/stderr before writing evidence.
  await model.close();
  if (launchToken) engineLog = engineLog.replaceAll(launchToken, '<launch-token>');
  if (cookie) engineLog = engineLog.replaceAll(cookie, '<session-cookie>');
  engineLog = engineLog.replace(/([?&]token=)[^\s\x1b]+/gu, '$1<redacted>');
  await writeFile(join(out, 'engine.log'), engineLog);
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ status: report.status, stage: report.stage, urlReadyMs: report.urlReadyMs,
    hostReadyMs: report.hostReadyMs, firstRoundMs: report.firstRoundMs, approvals: report.approvals, error: report.error }));
  if (report.status !== 'PASS') process.exitCode = 1;
}
