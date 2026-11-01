import fs from '@ohos.file.fs';
import util from '@ohos.util';
import common from '@ohos.app.ability.common';
import cwd from 'libcwd_task.so';
import control from 'libdsh_control.so';
interface Result { phase: string; diagnostics: Record<string, Object>; exited: boolean; callbacks: boolean; eof: boolean; signal: number; released: boolean; parentOutputMatched: boolean; }
let running: boolean = false;
const booleans: string[] = ['independentUid', 'directory', 'fchdir', 'openat', 'openatMatched', 'relativeAttempted', 'relativeOpen', 'relativeMatched', 'sameFile', 'getcwd', 'outputDirectory', 'writeOpened', 'writeComplete', 'fsync'];
const numbers: string[] = ['statErrno', 'fchdirErrno', 'openatErrno', 'relativeErrno', 'getcwdErrno', 'outputDirectoryErrno', 'writeErrno', 'fsyncErrno', 'openatReadErrno', 'openatStatErrno', 'relativeReadErrno', 'relativeStatErrno', 'writeCallErrno'];
function delay(): Promise<void> { return new Promise<void>((resolve) => setTimeout(resolve, 25)); }
function write(path: string, text: string): void { const f = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC); try { fs.writeSync(f.fd, text); } finally { fs.closeSync(f); } }
// 仅原生目录能力观测；不声明 Node/PTC 的 cwd 或沙箱功能已通过。
export async function runCwdProbe(context: common.Context): Promise<void> {
  if (running) return; running = true;
  const result: Result = { phase: 'STARTING', diagnostics: {}, exited: false, callbacks: false, eof: false, signal: -1, released: false, parentOutputMatched: false };
  const report = context.filesDir + '/cwd-probe.json';
  const directory = context.filesDir + '/cwd-fixture-' + Date.now();
  let pid = -1; let bytes = new Uint8Array(0);
  try {
    write(report, JSON.stringify(result));
    if (control.watch() !== 0) throw new Error('WATCH_FAILED');
    fs.mkdirSync(directory); fs.mkdirSync(directory + '/output');
    write(directory + '/allow.txt', 'CWD_FIXED_ALLOWED');
    if (fs.readTextSync(directory + '/allow.txt') !== 'CWD_FIXED_ALLOWED') throw new Error('FIXTURE_FAILED');
    pid = cwd.launch(directory); if (pid <= 0) throw new Error('SPAWN_FAILED');
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const state = cwd.status(pid);
      if (bytes.length + state.audit.length > 4096) throw new Error('OUTPUT_LIMIT');
      const next = new Uint8Array(bytes.length + state.audit.length); next.set(bytes); next.set(state.audit, bytes.length); bytes = next;
      result.exited = state.exited === 1; result.signal = state.signal; result.eof = state.auditEof === 1;
      result.callbacks = control.exited(pid) === 1 && control.signal(pid) === state.signal;
      if (result.exited && result.callbacks && result.eof) break;
      await delay();
    }
    if (!(result.exited && result.callbacks && result.eof) || result.signal !== 0) throw new Error('PROCESS_FAILED');
    const text = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes);
    const data = JSON.parse(text) as Record<string, Object>;
    if (data['diagnosticFailure'] === 1 && data['independentUid'] === false && typeof data['directory'] === 'boolean' && Number.isSafeInteger(data['statErrno']) && Number(data['statErrno']) >= 0 && Object.keys(data).length === 4) {
      result.diagnostics = data; result.phase = 'CWD_ISOLATION_FAILED';
      throw new Error('ISOLATION_FAILED');
    }
    if (Object.keys(data).length !== booleans.length + numbers.length) throw new Error('SCHEMA_FAILED');
    for (const key of booleans) { if (typeof data[key] !== 'boolean') throw new Error('SCHEMA_FAILED'); result.diagnostics[key] = data[key]; }
    for (const key of numbers) { if (!Number.isSafeInteger(data[key]) || Number(data[key]) < 0) throw new Error('SCHEMA_FAILED'); result.diagnostics[key] = data[key]; }
    if (data['independentUid'] !== true) throw new Error('ISOLATION_FAILED');
    try { result.parentOutputMatched = fs.readTextSync(directory + '/output/result.txt') === 'CWD_FIXED_OUTPUT'; } catch (_) {}
    // 观察完成与所有操作成功分开，errno 拒绝是有效证据。
    result.phase = booleans.every((key: string) => data[key] === true) && numbers.every((key: string) => data[key] === 0) && result.parentOutputMatched ? 'NATIVE_CWD_OPERATIONS_OK' : 'NATIVE_CWD_LIMIT_OBSERVED';
  } catch (_) { if (result.phase === 'STARTING') result.phase = 'CWD_PROBE_FAILED'; }
  finally {
    if (pid > 0) {
      if (!result.exited) cwd.stop(pid);
      const deadline = Date.now() + 5000;
      while (Date.now() < deadline && !(result.exited && result.callbacks && result.eof)) {
        const state = cwd.status(pid); result.exited = state.exited === 1; result.signal = state.signal; result.eof = state.auditEof === 1;
        result.callbacks = control.exited(pid) === 1 && control.signal(pid) === state.signal;
        if (!(result.exited && result.callbacks && result.eof)) await delay();
      }
      if (result.exited && result.callbacks && result.eof) { result.released = cwd.release(pid) === 1; if (result.released) control.forget(pid); }
      if (!result.released) result.phase = 'CWD_CLEANUP_FAILED';
    }
    // 保留本轮新造 fixture 供父复核；不递归删除、不改权限。
    write(report, JSON.stringify(result)); running = false;
  }
}
