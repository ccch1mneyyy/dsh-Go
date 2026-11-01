import persistence from 'libpersistence_probe.so';
import control from 'libdsh_control.so';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

interface RaceResult {
  modelRequestSent: boolean; publicPersistenceApi: boolean; rpcCollisionTest: boolean; passed: boolean;
  bothPublicCreatesReturned: boolean; oneDurableWinner: boolean; loserCategory: string;
  ownershipConflictObserved: boolean; publishConflictObserved: boolean; typedExistenceConflictObserved: boolean;
  onePhysicalLog: boolean; coldHeaderMatchesWinner: boolean; coldEmptyLog: boolean;
  existingCreateRejected: boolean; physicalLogUnchanged: boolean; cleanupOk: boolean;
  failedStage: string; errorCategory: string;
}
interface NativeResult { nodeReturn?: number; nativeFailure?: number; }
interface Report {
  phase: string; exited: boolean; callbacks: boolean; eof: boolean; released: boolean; signal: number;
  cancelled: boolean; protocolOk: boolean; nodeReturn: number; nativeFailure: number; passed: boolean;
  race?: RaceResult;
}
let running: boolean = false;
function delay(): Promise<void> { return new Promise<void>(resolve => { setTimeout(resolve, 100); }); }
function save(file: string, report: Report): void {
  const handle = fs.openSync(file, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try { fs.writeSync(handle.fd, JSON.stringify(report)); } finally { fs.closeSync(handle); }
}
function category(value: string): string {
  return ['EEXIST', 'EACCES', 'EPERM', 'ENOSYS', 'EINVAL', 'ENOENT', 'EXDEV', 'EIO',
    'SessionAlreadyExistsError', 'SessionAlreadyOwnedError', 'OTHER'].includes(value) ? value : 'OTHER';
}
function stage(value: string): string {
  return ['arguments', 'fresh-directory', 'import-public-packages', 'mount-independent-backends',
    'create-unmaterialized', 'concurrent-flush', 'close-racing-handles', 'cold-backend-open',
    'reject-existing-create'].includes(value) ? value : '';
}
// 重建白名单字段，禁止把原生输出字符串、路径或未知字段写进最终报告。
function safeRace(value: RaceResult): RaceResult {
  return { modelRequestSent: value.modelRequestSent === true, publicPersistenceApi: value.publicPersistenceApi === true,
    rpcCollisionTest: value.rpcCollisionTest === true, passed: value.passed === true,
    bothPublicCreatesReturned: value.bothPublicCreatesReturned === true, oneDurableWinner: value.oneDurableWinner === true,
    loserCategory: category(value.loserCategory), ownershipConflictObserved: value.ownershipConflictObserved === true,
    publishConflictObserved: value.publishConflictObserved === true, typedExistenceConflictObserved: value.typedExistenceConflictObserved === true,
    onePhysicalLog: value.onePhysicalLog === true, coldHeaderMatchesWinner: value.coldHeaderMatchesWinner === true,
    coldEmptyLog: value.coldEmptyLog === true, existingCreateRejected: value.existingCreateRejected === true,
    physicalLogUnchanged: value.physicalLogUnchanged === true, cleanupOk: value.cleanupOk === true,
    failedStage: stage(value.failedStage), errorCategory: category(value.errorCategory) };
}
export async function runPersistenceProbe(context: common.Context, installedRoot: string): Promise<void> {
  if (running) return;
  running = true;
  const file = context.filesDir + '/persistence-probe.json';
  const report: Report = { phase: 'STARTING', exited: false, callbacks: false, eof: false, released: false,
    signal: -1, cancelled: false, protocolOk: false, nodeReturn: -1, nativeFailure: 0, passed: false };
  let pid = -1;
  let wire = '';
  let overflow = false;
  try {
    save(file, report);
    if (control.watch() !== 0) throw new Error('WATCH_FAILED');
    const directory = context.filesDir + '/persistence-probe-' + Date.now();
    fs.mkdirSync(directory);
    const bytes = context.resourceManager.getRawFileContentSync('session-persistence-race.mjs');
    const script = fs.openSync(directory + '/session-persistence-race.mjs', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(script.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)); }
    finally { fs.closeSync(script); }
    pid = persistence.launch(installedRoot, directory);
    if (pid <= 0) { report.phase = 'LAUNCH_FAILED'; save(file, report); return; }
    const deadline = Date.now() + 120000;
    while (Date.now() < deadline) {
      const current = persistence.status(pid);
      wire += current.report;
      if (wire.length > 16384) { overflow = true; break; }
      report.exited = current.exited === 1;
      report.signal = current.signal;
      report.callbacks = report.exited && control.exited(pid) === 1 && control.signal(pid) === current.signal;
      report.eof = current.eof === 1;
      if (report.exited && report.callbacks && report.eof) break;
      await delay();
    }
    if (!overflow && report.eof) {
      const lines = wire.trim().split('\n');
      if (lines.length === 2) {
        const raw = JSON.parse(lines[0]) as RaceResult;
        const end = JSON.parse(lines[1]) as NativeResult;
        report.race = safeRace(raw);
        if (typeof end.nodeReturn === 'number' && Number.isInteger(end.nodeReturn)) report.nodeReturn = end.nodeReturn;
        report.protocolOk = raw.modelRequestSent === false && raw.publicPersistenceApi === true && raw.rpcCollisionTest === false && typeof raw.passed === 'boolean' && typeof end.nodeReturn === 'number';
      } else if (lines.length === 1) {
        const error = JSON.parse(lines[0]) as NativeResult;
        if (typeof error.nativeFailure === 'number' && Number.isInteger(error.nativeFailure) && error.nativeFailure > 0 && error.nativeFailure < 100) report.nativeFailure = error.nativeFailure;
      }
    }
    report.phase = 'FINISHED';
  } catch (_) { report.phase = 'HARNESS_FAILED'; }
  finally {
    if (pid > 0) {
      if (!report.exited) { report.cancelled = persistence.stop(pid) === 0; }
      for (let i = 0; i < 50; i++) {
        const current = persistence.status(pid);
        report.exited = current.exited === 1;
        report.signal = current.signal;
        report.callbacks = report.exited && control.exited(pid) === 1 && control.signal(pid) === current.signal;
        report.eof = current.eof === 1;
        if (report.exited && report.callbacks && report.eof) break;
        await delay();
      }
      if (report.exited && report.eof) report.released = persistence.release(pid) === 1;
      if (report.released && report.callbacks) control.forget(pid);
    }
    report.passed = report.phase === 'FINISHED' && report.protocolOk && report.nodeReturn === 0 && report.race?.passed === true &&
      report.exited && report.callbacks && report.eof && report.released && report.signal === 0 && !report.cancelled;
    save(file, report);
    running = false;
  }
}
