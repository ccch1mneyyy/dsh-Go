import nativeTask from 'libdsh_ptc_task.so';
import control from 'libdsh_control.so';
import { Task, TaskDriver, SpawnSpec, Cancellation, StartFailure, StreamName, ExitFacts } from './broker/parent-broker.js';
interface StreamRead { data: Uint8Array; eof: boolean; }
function delay(): Promise<void> { return new Promise<void>((resolve) => setTimeout(resolve, 10)); }
function signalName(signal: number): string {
  const names: Record<number, string> = { 1: 'SIGHUP', 2: 'SIGINT', 4: 'SIGILL', 6: 'SIGABRT', 7: 'SIGBUS', 8: 'SIGFPE', 9: 'SIGKILL', 11: 'SIGSEGV', 13: 'SIGPIPE', 15: 'SIGTERM', 31: 'SIGSYS' };
  const name = names[signal]; if (name === undefined) throw new Error('PTC_SIGNAL_UNKNOWN'); return name;
}
class HarmonyTask implements Task {
  private pid: number;
  private eof: boolean[] = [false, false, false, false];
  private statusBytes: Uint8Array = new Uint8Array(0);
  private reaping: Promise<void> | undefined = undefined;
  private stopRequested: boolean = false;
  private ended: boolean = false;
  constructor(pid: number) { this.pid = pid; }
  private readIndex(index: number, maxBytes: number): StreamRead {
    const value = nativeTask.read(this.pid, index, maxBytes);
    if (value.error !== 0 || value.bytes.length > maxBytes || (maxBytes === 0 && value.bytes.length !== 0)) throw new Error('PTC_READ_FAILED');
    if (value.eof === 1) this.eof[index] = true;
    const result: StreamRead = { data: value.bytes, eof: this.eof[index] }; return result;
  }
  read(stream: StreamName, maxBytes: number): StreamRead {
    return this.readIndex(stream === 'control' ? 0 : stream === 'stdout' ? 1 : 2, maxBytes);
  }
  writeControl(data: Uint8Array): number { return nativeTask.write(this.pid, data); }
  endControl(): void { if (this.ended) return; if (nativeTask.end(this.pid) !== 0) throw new Error('PTC_END_FAILED'); this.ended = true; }
  stop(): void {
    if (this.stopRequested || nativeTask.status(this.pid).exited === 1) return;
    const code = nativeTask.stop(this.pid);
    if (code !== 0 && nativeTask.status(this.pid).exited !== 1) throw new Error('PTC_STOP_FAILED');
    this.stopRequested = true;
  }
  private observe(): void {
    if (this.eof[3]) return;
    const value = this.readIndex(3, 17);
    if (this.statusBytes.length + value.data.length > 16) throw new Error('PTC_EXIT_RECORD_INVALID');
    const next = new Uint8Array(this.statusBytes.length + value.data.length); next.set(this.statusBytes); next.set(value.data, this.statusBytes.length); this.statusBytes = next;
  }
  pollExit(): ExitFacts | null {
    this.observe();
    const state = nativeTask.status(this.pid);
    if (state.exited !== 1 || !this.eof[3]) return null;
    if (control.exited(this.pid) !== 1 || control.signal(this.pid) !== state.signal) return null;
    if (state.signal !== 0) { const facts: ExitFacts = { exitCode: null, signal: signalName(state.signal) }; return facts; }
    if (this.statusBytes.length !== 16) throw new Error('PTC_EXIT_RECORD_MISSING');
    const view = new DataView(this.statusBytes.buffer);
    const source = view.getUint32(8, true), code = view.getUint32(12, true);
    if (view.getUint32(0, true) !== 0x44534858 || view.getUint32(4, true) !== 1 || (source !== 1 && source !== 2) || code > 255) throw new Error('PTC_EXIT_RECORD_INVALID');
    const facts: ExitFacts = { exitCode: code, signal: null }; return facts;
  }
  reap(): Promise<void> {
    if (this.reaping === undefined) this.reaping = this.releaseAfterExit(); return this.reaping;
  }
  private async releaseAfterExit(): Promise<void> {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      // 已进入回收阶段，丢弃剩余任务输出，只等待真实EOF，不向用户返回正文。
      for (let index = 0; index < 4; index++) if (!this.eof[index]) this.readIndex(index, 65536);
      const state = nativeTask.status(this.pid);
      if (state.exited === 1 && control.exited(this.pid) === 1 && control.signal(this.pid) === state.signal && this.eof.every((value: boolean) => value)) {
        if (nativeTask.release(this.pid) !== 1) throw new Error('PTC_RELEASE_FAILED');
        control.forget(this.pid); return;
      }
      await delay();
    }
    throw new Error('PTC_REAP_TIMEOUT');
  }
}
export class HarmonyTaskDriver implements TaskDriver {
  private installedRoot: string;
  private executable: string;
  private bootstrapPath: string;
  constructor(installedRoot: string, executable: string, bootstrapPath: string) {
    this.installedRoot = installedRoot; this.executable = executable; this.bootstrapPath = bootstrapPath;
  }
  accepts(spec: SpawnSpec): boolean {
    // 97真机确认父目录FD全部EACCES，绝不把workspace cwd换成根目录。
    return spec.cwd === '/' && spec.argv.length === 4 && spec.argv[0] === this.executable && spec.argv[2] === this.bootstrapPath &&
      /^--max-old-space-size=[0-9]+$/.test(spec.argv[1]) && /^[0-9]+$/.test(spec.argv[3]) && Object.keys(spec.envSet).length === 0;
  }
  async start(spec: SpawnSpec, cancellation: Cancellation): Promise<Task | StartFailure> {
    if (!this.accepts(spec)) { const failure: StartFailure = { startFailed: true, reaped: true, code: 'PTC_SPEC_UNSUPPORTED' }; return failure; }
    if (cancellation.aborted) { const failure: StartFailure = { startFailed: true, reaped: true, code: 'PTC_START_CANCELLED' }; return failure; }
    const heap = Number(spec.argv[1].slice('--max-old-space-size='.length)), limit = Number(spec.argv[3]);
    if (!Number.isSafeInteger(heap) || heap < 16 || heap > 4096 || !Number.isSafeInteger(limit) || limit < 1 || limit > 134217728) {
      const failure: StartFailure = { startFailed: true, reaped: true, code: 'PTC_LIMIT_UNSUPPORTED' }; return failure;
    }
    if (control.watch() !== 0) { const failure: StartFailure = { startFailed: true, reaped: true, code: 'PTC_WATCH_FAILED' }; return failure; }
    const pid = nativeTask.launch(this.installedRoot, spec.cwd, limit, heap);
    // native负码必须保证从未建立子进程；原生异常不捕获成无遗留。
    if (pid <= 0) { const failure: StartFailure = { startFailed: true, reaped: true, code: 'PTC_START_FAILED' }; return failure; }
    return new HarmonyTask(pid);
  }
}
