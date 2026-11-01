import duplex from 'libptc_task.so';
import control from 'libdsh_control.so';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

interface BootNamespace { global: string; names: string[]; }
interface BootData { code: string; namespaces: BootNamespace[]; maxOutputBytes: number; }
interface BootFrame { type: string; data: BootData; }
interface Outcome {
  descriptorNative: boolean; socketStat: boolean; statErrno: number; unixSocket: boolean; nameErrno: number;
  streamSocket: boolean; typeErrno: number; uvType: number; uvErrno: number;
  uncaught: boolean; exceptionName: string; exceptionCode: string; exceptionCategory: string;
  exceptionOrigin: string; exceptionLine: number; exceptionColumn: number;
  ready: boolean; call: boolean; done: boolean; exited: boolean;
  callbacks: boolean; eof: boolean; released: boolean; cancelled: boolean;
  nativeReady: boolean; independentUid: boolean; parentPathDenied: boolean; scriptFdReadOnly: boolean; parentPathErrno: number; scriptVerified: boolean; fdPatched: boolean; parentFixtureReadable: boolean; signal: number; exitEvent: boolean; exitCode: number; returned: boolean; returnCode: number; passed: boolean;
}
interface Report { phase: string; completed: number; outcomes: Outcome[]; }
let running: boolean = false;
let fixtureId: number = 0;
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
async function capture(installedRoot: string, directory: string, mode: string): Promise<Outcome> {
  const result: Outcome = { descriptorNative: false, socketStat: false, statErrno: 0, unixSocket: false, nameErrno: 0, streamSocket: false, typeErrno: 0, uvType: -1, uvErrno: 0, uncaught: false, exceptionName: '', exceptionCode: '', exceptionCategory: '', exceptionOrigin: '', exceptionLine: 0, exceptionColumn: 0, ready: false, call: false, done: false, exited: false,
    callbacks: false, eof: false, released: false, cancelled: false, nativeReady: false, independentUid: false, parentPathDenied: false, scriptFdReadOnly: false, parentPathErrno: 0, scriptVerified: false, fdPatched: false, parentFixtureReadable: false, signal: -1, exitEvent: false, exitCode: -1, returned: false, returnCode: -1, passed: false };
  const denied = directory + '/denied-' + Date.now() + '-' + (++fixtureId) + '.txt';
  const fixture = fs.openSync(denied, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try { fs.writeSync(fixture.fd, 'ISOLATED_FIXED_PARENT_ONLY'); } finally { fs.closeSync(fixture); }
  result.parentFixtureReadable = fs.readTextSync(denied) === 'ISOLATED_FIXED_PARENT_ONLY';
  const pid = duplex.launch(installedRoot, denied);
  if (pid <= 0) return result;
  let input = new Uint8Array(0);
  let protocolOk = false;
  let audit = new Uint8Array(0);
  try {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const state = duplex.status(pid);
      if (state.audit.length > 0) {
        if (audit.length + state.audit.length > 8192) throw new Error('AUDIT_LIMIT');
        const merged = new Uint8Array(audit.length + state.audit.length);
        merged.set(audit); merged.set(state.audit, audit.length); audit = merged;
      }
      let newline = audit.indexOf(10);
      while (newline >= 0) {
        const text = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(audit.slice(0, newline));
        audit = audit.slice(newline + 1);
        const item = JSON.parse(text) as Record<string, Object>;
        if (item['descriptorNative'] === true && !result.descriptorNative) {
          for (const key of ['statErrno', 'nameErrno', 'typeErrno', 'uvErrno']) {
            if (!Number.isSafeInteger(item[key]) || Number(item[key]) < 0) throw new Error('DIAGNOSTIC_INVALID');
          }
          if (!Number.isSafeInteger(item['uvType']) || Number(item['uvType']) < -1) throw new Error('DIAGNOSTIC_INVALID');
          result.descriptorNative = true; result.socketStat = item['socketStat'] === true;
          result.unixSocket = item['unixSocket'] === true; result.streamSocket = item['streamSocket'] === true;
          result.statErrno = Number(item['statErrno']); result.nameErrno = Number(item['nameErrno']);
          result.typeErrno = Number(item['typeErrno']); result.uvType = Number(item['uvType']); result.uvErrno = Number(item['uvErrno']);
        } else if (item['uncaught'] === true && !result.uncaught) {
          const name = String(item['name']); const code = String(item['code']);
          const category = String(item['category']); const origin = String(item['origin']);
          const line = Number(item['line']); const column = Number(item['column']);
          if (!['Error', 'TypeError', 'SyntaxError', 'RangeError', 'ReferenceError', 'other'].includes(name) ||
            !['ERR_INVALID_ARG_TYPE', 'ERR_INVALID_ARG_VALUE', 'ERR_INVALID_FD_TYPE', 'ERR_MODULE_NOT_FOUND',
              'ERR_UNSUPPORTED_ESM_URL_SCHEME', 'ERR_ACCESS_DENIED', 'EACCES', 'EPERM', 'ENOENT', 'EBADF',
              'EINVAL', 'ENOTSOCK', 'other'].includes(code) ||
            !['uv-cwd', 'control-limit', 'control-mode', 'control-eof', 'descriptor', 'unsupported', 'syntax', 'other'].includes(category) ||
            !['unhandledRejection', 'uncaughtException'].includes(origin) ||
            !Number.isSafeInteger(line) || line < 0 || !Number.isSafeInteger(column) || column < 0) throw new Error('DIAGNOSTIC_INVALID');
          result.uncaught = true; result.exceptionName = name; result.exceptionCode = code;
          result.exceptionCategory = category; result.exceptionOrigin = origin;
          result.exceptionLine = line; result.exceptionColumn = column;
        } else if (item['nativeReady'] === true && !result.nativeReady) {
          result.nativeReady = true; result.independentUid = item['independentUid'] === true;
          result.parentPathDenied = item['parentPathDenied'] === true;
          result.scriptFdReadOnly = item['scriptFdReadOnly'] === true;
          result.parentPathErrno = Number(item['parentPathErrno']);
        } else if (item['scriptVerified'] === true && !result.scriptVerified) {
          result.scriptVerified = true; result.fdPatched = item['fdPatched'] === true;
        } else if (item['nodeExit'] !== undefined && !result.exitEvent) {
          result.exitEvent = true; result.exitCode = Number(item['nodeExit']);
        } else if (item['nodeReturn'] !== undefined && !result.returned) {
          result.returned = true; result.returnCode = Number(item['nodeReturn']);
        } else throw new Error('AUDIT_FAILED');
        newline = audit.indexOf(10);
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
      result.eof = state.controlEof === 1 && state.auditEof === 1;
      if (result.exited && result.callbacks && result.eof) {
        const exitMatches = mode === 'complete' ? result.exitEvent && result.exitCode === 0 && result.returned && result.returnCode === 0 :
          mode === 'eof' ? result.exitEvent && result.exitCode === 1 && (!result.returned || result.returnCode === 1) : !result.exitEvent && !result.returned;
        const isolation = result.parentFixtureReadable && result.nativeReady && result.independentUid && result.parentPathDenied &&
          [1, 2, 13].includes(result.parentPathErrno) && result.scriptFdReadOnly && result.scriptVerified && result.fdPatched;
        // 仅主动提前断开用例接受原协议精确识别的EOF拒绝，其他异常保持失败。
        const exceptionMatches = !result.uncaught || (mode === 'eof' && result.exceptionCategory === 'control-eof' &&
          result.exceptionName === 'Error' && result.exceptionOrigin === 'unhandledRejection' &&
          result.exceptionLine === 227 && result.exceptionColumn === 50);
        protocolOk = exceptionMatches && isolation && exitMatches && audit.length === 0 && input.length === 0 && result.ready && (mode === 'complete' ?
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
      result.eof = state.controlEof === 1 && state.auditEof === 1;
      if (!(result.exited && result.callbacks && result.eof)) await delay();
    }
    // 不在未确认退出时复用槽位，也不清掉其他兄弟任务的回调。
    if (result.exited && result.callbacks) {
      result.released = duplex.release(pid) === 1;
      if (result.released) { control.forget(pid); fs.unlinkSync(denied); }
    }
  }
  result.passed = protocolOk && result.exited && result.callbacks && result.eof && result.released;
  return result;
}
export async function runIsolatedPtcProbe(context: common.Context, installedRoot: string): Promise<void> {
  if (running) return;
  running = true;
  const report: Report = { phase: 'STARTING', completed: 0, outcomes: [] };
  const file = context.filesDir + '/isolated-ptc-probe.json';
  try {
    save(file, report);
    if (control.watch() !== 0) throw new Error('WATCH_FAILED');
    const directory = context.filesDir + '/isolated-ptc-probe-' + Date.now();
    fs.mkdirSync(directory);
    for (let round = 0; round < 10; round++) {
      const pair = await Promise.all([capture(installedRoot, directory, 'complete'), capture(installedRoot, directory, 'complete')]);
      for (const item of pair) { report.outcomes.push(item); if (item.passed) report.completed++; }
      if (!pair.every((item: Outcome) => item.passed)) { report.phase = 'PARALLEL_FAILED'; save(file, report); return; }
      for (const mode of ['eof', 'cancel']) {
        const item = await capture(installedRoot, directory, mode); report.outcomes.push(item);
        if (!item.passed) { report.phase = mode === 'eof' ? 'EOF_FAILED' : 'CANCEL_FAILED'; save(file, report); return; }
        report.completed++;
      }
      save(file, report);
    }
    report.phase = 'ISOLATED_PTC_PROBE_OK'; save(file, report);
  } catch (_) { report.phase = 'HARNESS_FAILED'; save(file, report); }
  finally { running = false; }
}

interface NativeControlReport {
  phase: string; nativeReady: boolean; independentUid: boolean; parentPathDenied: boolean;
  scriptFdReadOnly: boolean; parentPathErrno: number; nativeControl: boolean;
  readMatched: boolean; readEof: boolean; writeComplete: boolean;
  readErrno: number; writeErrno: number; shutdownErrno: number;
  replyMatched: boolean; exited: boolean; callbacks: boolean; eof: boolean; released: boolean; signal: number;
}
let nativeRunning: boolean = false;
function saveNative(path: string, report: NativeControlReport): void {
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try { fs.writeSync(file.fd, JSON.stringify(report)); } finally { fs.closeSync(file); }
}
// 95只验证原生四字节及EOF，不启动Node，不属于PTC验收。
export async function runNativeControlProbe(context: common.Context, installedRoot: string): Promise<void> {
  if (nativeRunning) return; nativeRunning = true;
  const report: NativeControlReport = { phase: 'STARTING', nativeReady: false, independentUid: false,
    parentPathDenied: false, scriptFdReadOnly: false, parentPathErrno: 0, nativeControl: false,
    readMatched: false, readEof: false, writeComplete: false, readErrno: 0, writeErrno: 0,
    shutdownErrno: 0, replyMatched: false, exited: false, callbacks: false, eof: false, released: false, signal: -1 };
  const file = context.filesDir + '/native-control-probe.json';
  let pid = -1; let denied = '';
  try {
    saveNative(file, report);
    if (control.watch() !== 0) throw new Error('WATCH_FAILED');
    denied = context.filesDir + '/native-control-denied-' + Date.now() + '.txt';
    const fixture = fs.openSync(denied, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(fixture.fd, 'ISOLATED_FIXED_PARENT_ONLY'); } finally { fs.closeSync(fixture); }
    if (fs.readTextSync(denied) !== 'ISOLATED_FIXED_PARENT_ONLY') throw new Error('FIXTURE_FAILED');
    pid = duplex.launch(installedRoot, denied);
    if (pid <= 0) throw new Error('SPAWN_FAILED');
    const request = new Uint8Array([80, 57, 53, 63]); let offset = 0;
    const writeDeadline = Date.now() + 3000;
    while (offset < request.length) {
      const count = duplex.write(pid, request.slice(offset));
      if (count < 0 || count > request.length - offset || Date.now() > writeDeadline) throw new Error('WRITE_FAILED');
      offset += count; if (count === 0) await delay();
    }
    if (duplex.end(pid) !== 0) throw new Error('END_FAILED');
    let audit = new Uint8Array(0); let reply = new Uint8Array(0);
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const state = duplex.status(pid);
      if (reply.length + state.control.length > 4 || audit.length + state.audit.length > 8192) throw new Error('OUTPUT_LIMIT');
      const nextReply = new Uint8Array(reply.length + state.control.length); nextReply.set(reply); nextReply.set(state.control, reply.length); reply = nextReply;
      const nextAudit = new Uint8Array(audit.length + state.audit.length); nextAudit.set(audit); nextAudit.set(state.audit, audit.length); audit = nextAudit;
      let newline = audit.indexOf(10);
      while (newline >= 0) {
        const text = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(audit.slice(0, newline)); audit = audit.slice(newline + 1);
        const item = JSON.parse(text) as Record<string, Object>;
        if (item['nativeReady'] === true && !report.nativeReady) {
          report.nativeReady = true; report.independentUid = item['independentUid'] === true;
          report.parentPathDenied = item['parentPathDenied'] === true; report.scriptFdReadOnly = item['scriptFdReadOnly'] === true;
          report.parentPathErrno = Number(item['parentPathErrno']);
        } else if (item['nativeControl'] === true && !report.nativeControl) {
          for (const key of ['readErrno', 'writeErrno', 'shutdownErrno']) {
            if (!Number.isSafeInteger(item[key]) || Number(item[key]) < 0) throw new Error('DIAGNOSTIC_INVALID');
          }
          report.nativeControl = true; report.readMatched = item['readMatched'] === true;
          report.readEof = item['readEof'] === true; report.writeComplete = item['writeComplete'] === true;
          report.readErrno = Number(item['readErrno']); report.writeErrno = Number(item['writeErrno']); report.shutdownErrno = Number(item['shutdownErrno']);
        } else throw new Error('AUDIT_FAILED');
        newline = audit.indexOf(10);
      }
      report.replyMatched = reply.length === 4 && reply[0] === 80 && reply[1] === 57 && reply[2] === 53 && reply[3] === 33;
      report.exited = state.exited === 1; report.signal = state.signal;
      report.callbacks = control.exited(pid) === 1 && control.signal(pid) === state.signal;
      report.eof = state.controlEof === 1 && state.auditEof === 1;
      if (report.exited && report.callbacks && report.eof) {
        report.phase = report.nativeReady && report.independentUid && report.parentPathDenied && [1, 2, 13].includes(report.parentPathErrno) &&
          report.scriptFdReadOnly && report.nativeControl && report.readMatched && report.readEof && report.writeComplete &&
          report.readErrno === 0 && report.writeErrno === 0 && report.shutdownErrno === 0 && report.replyMatched && report.signal === 0 && audit.length === 0 ? 'NATIVE_CONTROL_OK' : 'NATIVE_CONTROL_FAILED';
        break;
      }
      await delay();
    }
    if (report.phase === 'STARTING') report.phase = 'NATIVE_CONTROL_TIMEOUT';
  } catch (_) { report.phase = 'NATIVE_CONTROL_FAILED'; }
  finally {
    if (pid > 0) {
      if (!report.exited) duplex.stop(pid);
      const deadline = Date.now() + 5000;
      while (Date.now() < deadline && !(report.exited && report.callbacks && report.eof)) {
        const state = duplex.status(pid); report.exited = state.exited === 1; report.signal = state.signal;
        report.callbacks = control.exited(pid) === 1 && control.signal(pid) === state.signal;
        report.eof = state.controlEof === 1 && state.auditEof === 1;
        if (!(report.exited && report.callbacks && report.eof)) await delay();
      }
      if (report.exited && report.callbacks) {
        report.released = duplex.release(pid) === 1;
        if (report.released) { control.forget(pid); fs.unlinkSync(denied); }
      }
      if (!report.released && report.phase === 'NATIVE_CONTROL_OK') report.phase = 'CLEANUP_FAILED';
    }
    saveNative(file, report); nativeRunning = false;
  }
}
