import duplex from 'libduplex_probe.so';
import control from 'libdsh_control.so';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

interface BootNamespace { global: string; names: string[]; }
interface BootData { code: string; namespaces: BootNamespace[]; maxOutputBytes: number; }
interface BootFrame { type: string; data: BootData; }
interface Outcome {
  ready: boolean; call: boolean; done: boolean; exited: boolean;
  callbacks: boolean; eof: boolean; released: boolean; cancelled: boolean;
  signal: number; exitEvent: boolean; exitCode: number; stderrKnown: boolean; returned: boolean; returnCode: number; passed: boolean;
}
interface Report { phase: string; completed: number; outcomes: Outcome[]; }
// 只允许已知诊断构建的固定前缀；它不构成执行成功证据。
const startupDiagnostics = ['start-entered', 'after-sea-args', 'before-uv-setup-args',
  'after-uv-setup-args', 'before-platform-init', 'before-platform-signal-defaults',
  'after-platform-signal-defaults', 'after-platform-init', 'before-uv-hrtime',
  'after-uv-hrtime', 'before-stdio-inheritance-init', 'after-stdio-inheritance-init',
  'before-default-loop', 'after-default-loop'].map((item: string) => '[dsh-ohos-startup] ' + item + '\n').join('');
// 精确识别固定EOF错误及当前fixture/Node内部栈，不放行任意异常正文。
function knownEarlyEof(value: string, script: string): boolean {
  const lines = value.replace(/\r\n/g, '\n').split('\n');
  if (lines.length !== 12) return false;
  const location = 'file://' + script;
  const header = lines[0];
  if (!header.startsWith(location + ':') || !/^\d+$/.test(header.substring(location.length + 1))) return false;
  if (lines[1].trim() !== 'if (!this.closed) this.failure(/* @__PURE__ */ new Error("control channel ended before the program settled"), "io");' || lines[2].trim() !== '^') return false;
  if (lines[3] !== '' || lines[4] !== 'Error: control channel ended before the program settled') return false;
  const frame = '    at Socket.onEnd (' + location + ':';
  if (!lines[5].startsWith(frame) || !/^\d+:\d+\)$/.test(lines[5].substring(frame.length))) return false;
  return /^    at Socket.emit \(node:events:\d+:\d+\)$/.test(lines[6]) &&
    /^    at endReadableNT \(node:internal\/streams\/readable:\d+:\d+\)$/.test(lines[7]) &&
    /^    at process.processTicksAndRejections \(node:internal\/process\/task_queues:\d+:\d+\)$/.test(lines[8]) &&
    lines[9] === '' && lines[10] === 'Node.js v24.2.0' && lines[11] === '';
}
let running: boolean = false;
function delay(): Promise<void> { return new Promise<void>(resolve => { setTimeout(resolve, 20); }); }
function save(path: string, report: Report): void {
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try { fs.writeSync(file.fd, JSON.stringify(report)); } finally { fs.closeSync(file); }
}
async function send(pid: number, json: string): Promise<void> {
  const body = new util.TextEncoder().encodeInto(json);
  const wire = new Uint8Array(body.length + 4);
  new DataView(wire.buffer).setUint32(0, body.length);
  wire.set(body, 4);
  let offset = 0;
  const deadline = Date.now() + 2000;
  while (offset < wire.length) {
    const count = duplex.write(pid, wire.slice(offset));
    if (count < 0 || Date.now() >= deadline) throw new Error('WRITE_FAILED');
    offset += count;
    if (count === 0) await delay();
  }
}
// 只运行固定程序，不从用户输入、会话、模型或凭据生成代码。
async function capture(script: string, mode: string): Promise<Outcome> {
  const result: Outcome = { ready: false, call: false, done: false, exited: false,
    callbacks: false, eof: false, released: false, cancelled: false, signal: -1, exitEvent: false, exitCode: -1, stderrKnown: false, returned: false, returnCode: -1, passed: false };
  const pid = duplex.launch(script);
  if (pid <= 0) return result;
  let input = new Uint8Array(0);
  let protocolOk = false;
  let output = new Uint8Array(0);
  let diagnostic = new Uint8Array(0);
  try {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const state = duplex.status(pid);
      if (state.stderr.length > 0) {
        if (diagnostic.length + state.stderr.length > 8192) throw new Error('DIAGNOSTIC_LIMIT');
        const merged = new Uint8Array(diagnostic.length + state.stderr.length);
        merged.set(diagnostic); merged.set(state.stderr, diagnostic.length); diagnostic = merged;
      }
      if (state.stdout.length > 0) {
        if (output.length + state.stdout.length > 64) throw new Error('OUTPUT_LIMIT');
        const merged = new Uint8Array(output.length + state.stdout.length);
        merged.set(output); merged.set(state.stdout, output.length); output = merged;
      }
      if (state.control.length > 0) {
        if (input.length + state.control.length > 131080) throw new Error('INPUT_LIMIT');
        const merged = new Uint8Array(input.length + state.control.length);
        merged.set(input); merged.set(state.control, input.length); input = merged;
      }
      while (input.length >= 4) {
        const size = new DataView(input.buffer, input.byteOffset, 4).getUint32(0);
        if (size === 0 || size > 65536) throw new Error('FRAME_LIMIT');
        if (input.length < size + 4) break;
        const text = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(input.slice(4, size + 4));
        input = input.slice(size + 4);
        const frame = JSON.parse(text) as Record<string, Object>;
        if (frame['type'] === 'ready' && !result.ready) {
          result.ready = true;
          if (mode === 'eof') {
            if (duplex.end(pid) !== 0) throw new Error('END_FAILED');
          } else {
            const code = mode === 'cancel' ? 'await new Promise(()=>{});' : 'return await fixture.add([20,22]);';
            const boot: BootFrame = { type: 'boot', data: { code: code,
              namespaces: [{ global: 'fixture', names: ['add'] }], maxOutputBytes: 4096 } };
            await send(pid, JSON.stringify(boot));
            if (mode === 'cancel') {
              result.cancelled = duplex.stop(pid) === 0;
              if (!result.cancelled) throw new Error('CANCEL_FAILED');
            }
          }
        } else if (mode === 'complete' && frame['type'] === 'call' && result.ready && !result.call) {
          if (frame['id'] !== 1 || frame['global'] !== 'fixture' || frame['name'] !== 'add' ||
            JSON.stringify(frame['args']) !== '[{"kind":"array","length":2},20,22]') throw new Error('BINDING_FAILED');
          result.call = true;
          await send(pid, '{"type":"reply","id":1,"ok":true,"value":[42]}');
        } else if (mode === 'complete' && frame['type'] === 'done' && result.call && !result.done) {
          if (frame['error'] !== undefined || JSON.stringify(frame['value']) !== '[42]') throw new Error('RESULT_FAILED');
          result.done = true;
          if (duplex.end(pid) !== 0) throw new Error('END_FAILED');
        } else throw new Error('PROTOCOL_FAILED');
      }
      result.exited = state.exited === 1;
      result.signal = state.signal;
      result.callbacks = control.exited(pid) === 1 && control.signal(pid) === state.signal;
      result.eof = state.stdoutEof === 1 && state.stderrEof === 1 && state.controlEof === 1;
      if (result.exited && result.callbacks && result.eof) {
        const returned = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(output);
        result.exitEvent = returned.startsWith('NODE_EXIT_0\n') || returned.startsWith('NODE_EXIT_1\n');
        result.exitCode = returned.startsWith('NODE_EXIT_0\n') ? 0 : returned.startsWith('NODE_EXIT_1\n') ? 1 : -1;
        result.returned = returned.endsWith('NODE_RETURN_0\n') || returned.endsWith('NODE_RETURN_1\n');
        result.returnCode = returned.endsWith('NODE_RETURN_0\n') ? 0 : returned.endsWith('NODE_RETURN_1\n') ? 1 : -1;
        // exit事件与Start返回是不同事实；未处理拒绝可能直接退出，不伪造返回值。
        const exitMatches = mode === 'complete' ? returned === 'NODE_EXIT_0\nNODE_RETURN_0\n' :
          mode === 'eof' ? (returned === 'NODE_EXIT_1\n' || returned === 'NODE_EXIT_1\nNODE_RETURN_1\n') : returned === '';
        const stderr = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(diagnostic);
        const body = stderr.startsWith(startupDiagnostics) ? stderr.substring(startupDiagnostics.length) : stderr;
        result.stderrKnown = mode === 'eof' ? knownEarlyEof(body, script) : body === '';
        protocolOk = result.stderrKnown && exitMatches && input.length === 0 && result.ready && (mode === 'complete' ?
          result.call && result.done && result.signal === 0 : mode === 'cancel' ? result.cancelled && result.signal !== 0 : result.signal === 0);
        break;
      }
      await delay();
    }
  } catch (_) {
    // 固定失败状态；不保存异常正文、流内容或任何用户数据。
  } finally {
    if (!result.exited) duplex.stop(pid);
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline && !(result.exited && result.callbacks && result.eof)) {
      const state = duplex.status(pid);
      result.exited = state.exited === 1; result.signal = state.signal;
      result.callbacks = control.exited(pid) === 1 && control.signal(pid) === state.signal;
      result.eof = state.stdoutEof === 1 && state.stderrEof === 1 && state.controlEof === 1;
      if (!(result.exited && result.callbacks && result.eof)) await delay();
    }
    // 不在未确认退出时复用槽位，也不清掉其他兄弟任务的回调。
    if (result.exited && result.callbacks) {
      result.released = duplex.release(pid) === 1;
      if (result.released) control.forget(pid);
    }
  }
  result.passed = protocolOk && result.exited && result.callbacks && result.eof && result.released;
  return result;
}
export async function runDuplexProbe(context: common.Context): Promise<void> {
  if (running) return;
  running = true;
  const report: Report = { phase: 'STARTING', completed: 0, outcomes: [] };
  const file = context.filesDir + '/duplex-probe.json';
  try {
    save(file, report);
    if (control.watch() !== 0) throw new Error('WATCH_FAILED');
    const directory = context.filesDir + '/duplex-probe-' + Date.now();
    fs.mkdirSync(directory);
    const script = directory + '/process-fixture.mjs';
    const bytes = context.resourceManager.getRawFileContentSync('process-fixture.mjs');
    const dest = fs.openSync(script, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(dest.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)); }
    finally { fs.closeSync(dest); }
    for (let round = 0; round < 10; round++) {
      const pair = await Promise.all([capture(script, 'complete'), capture(script, 'complete')]);
      for (const item of pair) { report.outcomes.push(item); if (item.passed) report.completed++; }
      if (!pair.every((item: Outcome) => item.passed)) { report.phase = 'PARALLEL_FAILED'; save(file, report); return; }
      for (const mode of ['eof', 'cancel']) {
        const item = await capture(script, mode); report.outcomes.push(item);
        if (!item.passed) { report.phase = mode === 'eof' ? 'EOF_FAILED' : 'CANCEL_FAILED'; save(file, report); return; }
        report.completed++;
      }
      save(file, report);
    }
    report.phase = 'DUPLEX_PROBE_OK'; save(file, report);
  } catch (_) { report.phase = 'HARNESS_FAILED'; save(file, report); }
  finally { running = false; }
}
