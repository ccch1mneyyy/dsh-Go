import task from 'libtask_probe.so';
import control from 'libdsh_control.so';
import { fileIo as fs } from '@kit.CoreFileKit';

interface Capture {
  pid: number;
  stdout: string;
  stderr: string;
  channel: string;
  exited: boolean;
  signal: number;
  bothCallbacks: boolean;
  pipesClosed: boolean;
  stopCode: number;
  released: boolean;
}
interface ProbeReport {
  phase: string;
  completed: number;
  outputs: boolean;
  callbacks: boolean;
  cancellation: boolean;
  pipesClosed: boolean;
  slotsReused: boolean;
  code: number;
  stdout: string;
  stderr: string;
  channel: string;
  diagnosticLibrary: boolean;
}
interface PublishReport { exited: boolean; callbacks: boolean; pipesClosed: boolean; released: boolean; signal: number; result: string; }
// 仅识别当前已实测库的完整固定诊断前缀；未知输出仍判失败。
const startupDiagnostics = ['start-entered', 'after-sea-args', 'before-uv-setup-args',
  'after-uv-setup-args', 'before-platform-init', 'before-platform-signal-defaults',
  'after-platform-signal-defaults', 'after-platform-init', 'before-uv-hrtime',
  'after-uv-hrtime', 'before-stdio-inheritance-init', 'after-stdio-inheritance-init',
  'before-default-loop', 'after-default-loop'].map((item: string) => '[dsh-ohos-startup] ' + item + '\n').join('');
function taskStderr(value: string): string {
  return value.startsWith(startupDiagnostics) ? value.substring(startupDiagnostics.length) : value;
}
let running: boolean = false;
function delay(): Promise<void> { return new Promise<void>(resolve => { setTimeout(resolve, 100); }); }

// 临时固定任务验收入口；不接受命令、用户代码或凭据。
async function capture(mode: number, directory: string = ''): Promise<Capture> {
  const pid = task.launch(mode, directory);
  const result: Capture = { pid, stdout: '', stderr: '', channel: '', exited: false,
    signal: -1, bothCallbacks: false, pipesClosed: false, stopCode: -1, released: false };
  if (pid <= 0) return result;
  const deadline = Date.now() + 15000;
  let stopped = false;
  while (Date.now() < deadline) {
    const state = task.status(pid);
    result.stdout = (result.stdout + state.stdout).slice(0, 128);
    result.stderr = (result.stderr + state.stderr).slice(0, 8192);
    result.channel = (result.channel + state.control).slice(0, 8192);
    result.exited = state.exited === 1;
    result.signal = state.signal;
    result.bothCallbacks = control.exited(pid) === 1 && control.signal(pid) === state.signal;
    result.pipesClosed = state.stdoutEof === 1 && state.stderrEof === 1 && state.controlEof === 1;
    if (mode === 1 && !stopped && result.channel.includes('TASK_READY\n')) {
      result.stopCode = task.stop(pid);
      stopped = true;
    }
    if (result.exited && result.bothCallbacks && result.pipesClosed) break;
    await delay();
  }
  if (!result.exited) {
    task.stop(pid);
    for (let i = 0; i < 30; i++) {
      await delay();
      if (task.status(pid).exited === 1) { result.exited = true; break; }
    }
  }
  if (result.exited) result.released = task.release(pid) === 1;
  if (result.released && result.bothCallbacks) control.forget(pid);
  return result;
}
function normalPassed(item: Capture): boolean {
  return item.pid > 0 && item.stdout === '42\n' && taskStderr(item.stderr) === 'TASK_STDERR\n' &&
    item.channel.includes('TASK_READY\n') && item.channel.includes('NODE_RETURN_0\n') &&
    item.exited && item.signal === 0 && item.bothCallbacks && item.pipesClosed && item.released;
}
function save(file: string, report: ProbeReport | PublishReport): void {
  const handle = fs.openSync(file, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
  try { fs.writeSync(handle.fd, JSON.stringify(report)); } finally { fs.closeSync(handle); }
}
export async function runTaskProbe(filesDir: string): Promise<void> {
  if (running) return;
  running = true;
  const file = filesDir + '/task-probe.json';
  const report: ProbeReport = { phase: 'STARTING', completed: 0, outputs: false,
    callbacks: false, cancellation: false, pipesClosed: false, slotsReused: false, code: 0, stdout: '', stderr: '', channel: '', diagnosticLibrary: false };
  try {
    save(file, report);
    const publish = await capture(2, filesDir + '/publish-probe-' + Date.now());
    save(filesDir + '/publish-probe.json', { exited: publish.exited, callbacks: publish.bothCallbacks,
      pipesClosed: publish.pipesClosed, released: publish.released, signal: publish.signal, result: publish.channel });
    const capability = await capture(3);
    save(filesDir + '/sandbox-probe.json', { exited: capability.exited, callbacks: capability.bothCallbacks,
      pipesClosed: capability.pipesClosed, released: capability.released, signal: capability.signal, result: capability.channel });
    const first = await capture(0);
    report.stdout = first.stdout; report.stderr = first.stderr; report.channel = first.channel;
    report.diagnosticLibrary = first.stderr.startsWith(startupDiagnostics);
    report.outputs = first.stdout === '42\n' && taskStderr(first.stderr) === 'TASK_STDERR\n' && first.channel.includes('NODE_RETURN_0\n');
    report.callbacks = first.exited && first.signal === 0 && first.bothCallbacks;
    report.pipesClosed = first.pipesClosed;
    report.code = first.pid <= 0 ? first.pid : first.signal;
    if (!normalPassed(first)) { report.phase = 'NORMAL_FAILED'; save(file, report); return; }
    report.completed++;
    const parallel = await Promise.all([capture(0), capture(0)]);
    if (!parallel.every(item => normalPassed(item))) { report.phase = 'PARALLEL_FAILED'; save(file, report); return; }
    report.completed += 2;
    const timeout = await capture(1);
    report.cancellation = timeout.stopCode === 0 && timeout.exited && timeout.bothCallbacks && timeout.pipesClosed && timeout.released;
    if (!report.cancellation) { report.phase = 'CANCEL_FAILED'; save(file, report); return; }
    report.completed++;
    for (let i = 0; i < 9; i++) {
      const item = await capture(0);
      if (!normalPassed(item)) { report.phase = 'REUSE_FAILED'; save(file, report); return; }
      report.completed++;
    }
    report.slotsReused = true;
    report.phase = 'TASK_PROBE_OK';
    save(file, report);
  } catch (_) { report.phase = 'HARNESS_FAILED'; save(file, report); }
  finally { running = false; }
}
