import probe from 'libexit_probe.so';
import control from 'libdsh_control.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
interface ExitResult {
  mode: number; ready: boolean; getterUnavailable: boolean; addonLoadFailed: boolean;
  returnHookUnavailable: boolean; exited: boolean; callbacks: boolean; eof: boolean;
  signal: number; recordValid: boolean; source: number; code: number;
  cancelled: boolean; released: boolean; passed: boolean;
}
interface ExitReport { phase: string; completed: number; results: ExitResult[]; }
let running: boolean = false;
function delay(): Promise<void> { return new Promise<void>(resolve => { setTimeout(resolve, 20); }); }
function append(first: Uint8Array, second: Uint8Array, limit: number): Uint8Array {
  if (first.length + second.length > limit) throw new Error('FIXED_LIMIT');
  const value = new Uint8Array(first.length + second.length); value.set(first); value.set(second, first.length); return value;
}
async function capture(mode: number): Promise<ExitResult> {
  const result: ExitResult = { mode: mode, ready: false, getterUnavailable: false, addonLoadFailed: false,
    returnHookUnavailable: false, exited: false, callbacks: false, eof: false, signal: -1,
    recordValid: false, source: -1, code: -1, cancelled: false, released: false, passed: false };
  const pid = probe.launch(mode); if (pid <= 0) return result;
  let output = new Uint8Array(0); let record = new Uint8Array(0); let complete = false;
  try {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const state = probe.status(pid);
      output = append(output, state.stdout, 256); record = append(record, state.status, 32);
      // 只解析固定stdout诊断，不记录异常堆栈或任何流正文。
      const text = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(output);
      result.ready = text === 'OBSERVER_READY\n';
      result.getterUnavailable = text === 'GETTER_UNAVAILABLE\n';
      result.addonLoadFailed = text === 'ADDON_LOAD_FAILED\n';
      result.returnHookUnavailable = text.includes('RETURN_HOOK_UNAVAILABLE\n');
      if (mode === 5 && result.ready && !result.cancelled) {
        result.cancelled = probe.stop(pid) === 0;
        if (!result.cancelled) throw new Error('STOP_FAILED');
      }
      result.exited = state.exited === 1; result.signal = state.signal;
      result.callbacks = control.exited(pid) === 1 && control.signal(pid) === state.signal;
      result.eof = state.stdoutEof === 1 && state.stderrEof === 1 && state.controlEof === 1 && state.statusEof === 1;
      if (result.exited && result.callbacks && result.eof) {
        if (record.length === 16) {
          const view = new DataView(record.buffer, record.byteOffset, record.byteLength);
          result.source = view.getUint32(8, true); result.code = view.getInt32(12, true);
          result.recordValid = view.getUint32(0, true) === 0x44534858 && view.getUint32(4, true) === 1 && (result.source === 1 || result.source === 2);
        }
        const expected = [0, 7, 1, 1, 3];
        complete = result.ready && (mode === 5 ? record.length === 0 && result.cancelled && result.signal !== 0 :
          result.recordValid && result.code === expected[mode] && result.source === (mode === 4 ? 2 : 1) && result.signal === 0);
        break;
      }
      await delay();
    }
  } catch (_) {
    // 仅保留固定状态，不透传错误正文。
  } finally {
    if (!result.exited) probe.stop(pid);
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline && !(result.exited && result.callbacks && result.eof)) {
      const state = probe.status(pid);
      result.exited = state.exited === 1; result.signal = state.signal;
      result.callbacks = control.exited(pid) === 1 && control.signal(pid) === state.signal;
      result.eof = state.stdoutEof === 1 && state.stderrEof === 1 && state.controlEof === 1 && state.statusEof === 1;
      if (!(result.exited && result.callbacks && result.eof)) await delay();
    }
    if (result.exited && result.callbacks) {
      result.released = probe.release(pid) === 1;
      if (result.released) control.forget(pid);
    }
  }
  result.passed = complete && result.exited && result.callbacks && result.eof && result.released;
  return result;
}
function save(path: string, report: ExitReport): void {
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try { fs.writeSync(file.fd, JSON.stringify(report)); } finally { fs.closeSync(file); }
}
export async function runExitProbe(filesDir: string): Promise<void> {
  if (running) return; running = true;
  const report: ExitReport = { phase: 'STARTING', completed: 0, results: [] };
  const file = filesDir + '/exit-probe.json';
  try {
    save(file, report); if (control.watch() !== 0) throw new Error('WATCH_FAILED');
    for (let mode = 0; mode < 6; mode++) {
      const result = await capture(mode); report.results.push(result);
      if (!result.passed) { report.phase = 'FIXTURE_FAILED'; save(file, report); return; }
      report.completed++; save(file, report);
    }
    report.phase = 'EXIT_OBSERVER_OK'; save(file, report);
  } catch (_) { report.phase = 'HARNESS_FAILED'; save(file, report); }
  finally { running = false; }
}
