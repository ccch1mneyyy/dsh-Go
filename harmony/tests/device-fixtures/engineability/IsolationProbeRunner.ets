import isolation from 'libisolation_probe.so';
import control from 'libdsh_control.so';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

interface Wire {
  entered?: boolean; controlPresent?: boolean; fixturePresent?: boolean;
  nativeChecked?: boolean; nodeLoaded?: boolean; independentUid?: boolean;
  allowPathDenied?: boolean; denyPathDenied?: boolean; denyWriteDenied?: boolean; fixtureFdReadable?: boolean;
  allowErrno?: number; denyErrno?: number; writeErrno?: number; fixtureErrno?: number;
  passed?: boolean; nodeReturn?: number; nativeFailure?: number;
}
interface Report {
  phase: string; launchCode: number; exited: boolean; callbacks: boolean; eof: boolean; released: boolean;
  cancelled: boolean; signal: number; nativeIsolation: boolean; nodeIsolation: boolean; nodeLoaded: boolean;
  nodeReturn: number; nativeFailure: number; passed: boolean;
  reportBytes: number; parsedLines: number; readErrno: number; entered: boolean; fixturePresent: boolean;
}
let running: boolean = false;
function delay(): Promise<void> { return new Promise<void>(resolve => { setTimeout(resolve, 100); }); }
function save(file: string, report: Report): void {
  const fd = fs.openSync(file, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try { fs.writeSync(fd.fd, JSON.stringify(report)); } finally { fs.closeSync(fd); }
}
function restricted(value: Wire): boolean {
  return value.independentUid === true && value.allowPathDenied === true && value.denyPathDenied === true &&
    value.denyWriteDenied === true && value.fixtureFdReadable === true;
}
// 仅在本次新建目录中造两个非私密fixture；不接收用户文件路径，也不回退普通模式。
export async function runIsolationProbe(context: common.Context): Promise<void> {
  if (running) return;
  running = true;
  const report: Report = { phase: 'STARTING', launchCode: 0, exited: false, callbacks: false, eof: false,
    released: false, cancelled: false, signal: -1, nativeIsolation: false, nodeIsolation: false,
    nodeLoaded: false, nodeReturn: -1, nativeFailure: 0, passed: false,
    reportBytes: 0, parsedLines: 0, readErrno: 0, entered: false, fixturePresent: false };
  const file = context.filesDir + '/isolation-probe.json';
  let pid = -1;
  let wire = '';
  try {
    save(file, report);
    if (control.watch() !== 0) throw new Error('WATCH_FAILED');
    const directory = context.filesDir + '/isolation-probe-' + Date.now();
    fs.mkdirSync(directory);
    pid = isolation.launch(directory);
    report.launchCode = pid > 0 ? 0 : pid;
    if (pid <= 0) { report.phase = 'LAUNCH_FAILED'; return; }
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      const current = isolation.status(pid);
      wire += current.report;
      report.reportBytes = wire.length;
      if (current.readErrno !== 0 && current.readErrno !== 11) report.readErrno = current.readErrno;
      if (wire.length > 8192) throw new Error('OUTPUT_TOO_LONG');
      report.exited = current.exited === 1;
      report.signal = current.signal;
      report.callbacks = report.exited && control.exited(pid) === 1 && control.signal(pid) === current.signal;
      report.eof = current.eof === 1;
      if (report.exited && report.callbacks && report.eof) break;
      await delay();
    }
    if (report.eof && wire.trim().length === 0) report.phase = 'EMPTY_REPORT';
    else if (report.eof) {
      report.phase = 'FINISHED';
      const lines = wire.trim().split('\n');
      for (const line of lines) {
        try {
          const item = JSON.parse(line) as Wire;
          report.parsedLines++;
          if (item.entered === true) { report.entered = item.controlPresent === true; report.fixturePresent = item.fixturePresent === true; }
          if (item.nativeChecked === true) report.nativeIsolation = restricted(item) &&
            [1, 2, 13].includes(item.allowErrno ?? -1) && [1, 2, 13].includes(item.denyErrno ?? -1) &&
            [1, 2, 13].includes(item.writeErrno ?? -1) && item.fixtureErrno === 0;
          if (item.nodeLoaded === true) { report.nodeLoaded = true; report.nodeIsolation = restricted(item) && item.passed === true; }
          if (typeof item.nodeReturn === 'number' && Number.isInteger(item.nodeReturn)) report.nodeReturn = item.nodeReturn;
          if (typeof item.nativeFailure === 'number' && Number.isInteger(item.nativeFailure) && item.nativeFailure > 0 && item.nativeFailure < 100) report.nativeFailure = item.nativeFailure;
        } catch (_) { report.phase = 'INVALID_REPORT'; break; }
      }
    } else report.phase = 'INCOMPLETE';
  } catch (_) { report.phase = 'HARNESS_FAILED'; }
  finally {
    if (pid > 0) {
      if (!report.exited) report.cancelled = isolation.stop(pid) === 0;
      for (let i = 0; i < 50; i++) {
        const current = isolation.status(pid);
        report.exited = current.exited === 1;
        report.signal = current.signal;
        report.callbacks = report.exited && control.exited(pid) === 1 && control.signal(pid) === current.signal;
        report.eof = current.eof === 1;
        if (report.exited && report.callbacks && report.eof) break;
        await delay();
      }
      if (report.exited && report.eof) report.released = isolation.release(pid) === 1;
      if (report.released && report.callbacks) control.forget(pid);
    }
    report.passed = report.phase === 'FINISHED' && report.entered && report.fixturePresent && report.readErrno === 0 && report.nativeIsolation && report.nodeIsolation && report.nodeLoaded &&
      report.nodeReturn === 0 && report.nativeFailure === 0 && report.exited && report.callbacks && report.eof &&
      report.released && !report.cancelled && report.signal === 0;
    save(file, report);
    running = false;
  }
}
