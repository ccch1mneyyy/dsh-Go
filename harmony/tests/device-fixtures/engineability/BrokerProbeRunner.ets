import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import client from 'libbroker_client.so';
import broker from 'libdsh_broker.so';
import control from 'libdsh_control.so';
import { HarmonyBrokerHost } from './HarmonyBrokerHost';
import { HarmonyTaskDriver } from './HarmonyTaskDriver';
import { SpawnSpec } from './broker/parent-broker.js';
interface ClientDiagnostic { mode: string; checkpoint: string; failureCause: string; timedOut: boolean; stderrObservedBytes: number; stderrMaxChunkBytes: number; ready: boolean; called: boolean; done: boolean; stdoutBytes: number; stderrBytes: number; inputBytes: number; exitCode: number | null; signalled: boolean; }
interface ClientResult { phase: string; parallel: number; completed: number; stdoutVerified: boolean; stderrVerified: boolean; cancelled: boolean; exit7Verified: boolean; throwVerified: boolean; rejectVerified: boolean; exitCasesCompleted: number; exitDiagnosticClasses: string[]; reaped: boolean; modelRequestSent: boolean; code?: string; diagnostic?: ClientDiagnostic; }
interface Report { phase: string; stage: string; client?: ClientResult; nativeReturn: number; exited: boolean; callbacks: boolean; eof: boolean; signal: number; released: boolean; hostSettled: boolean; }
let running: boolean = false;
function delay(): Promise<void> { return new Promise<void>((resolve) => setTimeout(resolve, 20)); }
function save(path: string, report: Report): void { const f = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY); try { fs.writeSync(f.fd, JSON.stringify(report)); } finally { fs.closeSync(f); } }
async function copy(context: common.Context, directory: string, name: string): Promise<void> {
  const data = await context.resourceManager.getRawFileContent(name);
  const f = fs.openSync(directory + '/' + name, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
  try { fs.writeSync(f.fd, data.slice().buffer); } finally { fs.closeSync(f); }
}
export async function runBrokerProbe(context: common.Context, installedRoot: string): Promise<void> {
  if (running) return; running = true;
  const report: Report = { phase: 'STARTING', stage: 'FIXTURE', nativeReturn: -1, exited: false, callbacks: false, eof: false, signal: -1, released: false, hostSettled: false };
  const file = context.filesDir + '/broker-probe.json';
  let host: HarmonyBrokerHost | undefined = undefined; let handle = -1; let pid = -1;
  try {
    save(file, report);
    const generation = 'broker-probe-' + Date.now(); const directory = context.filesDir + '/' + generation;
    fs.mkdirSync(directory);
    await copy(context, directory, 'broker-client.mjs'); await copy(context, directory, 'subprocess-ohos.mjs');
    if (control.watch() !== 0) throw new Error('WATCH_FAILED');
    report.stage = 'BROKER_CREATE';
    const connection = broker.create();
    if (connection.error !== 0 || connection.handle === undefined || connection.fd === undefined) throw new Error('BROKER_CREATE_FAILED');
    handle = connection.handle;
    const bootstrap = installedRoot + '/opt/dsh/node_modules/@deepseek-ai/dsh-ptc-runtime-node/lib/process.js';
    const driver = new HarmonyTaskDriver(installedRoot, '/ohos/node', bootstrap);
    report.stage = 'HOST_CREATE';
    host = new HarmonyBrokerHost(handle, generation, driver, (spec: SpawnSpec): boolean => driver.accepts(spec));
    report.stage = 'CLIENT_START';
    pid = client.launch(directory, connection.fd, generation, bootstrap);
    if (pid <= 0) throw new Error('CLIENT_START_FAILED');
    if (broker.attached(handle) !== 0) throw new Error('BROKER_ATTACH_FAILED');
    host.start(); report.stage = 'CLIENT_RUNNING';
    let bytes = new Uint8Array(0); let clientSeen = false; let nativeSeen = false;
    const deadline = Date.now() + 90000;
    while (Date.now() < deadline) {
      const state = client.status(pid);
      if (state.auditErrno !== 0 && state.auditErrno !== 11) throw new Error('AUDIT_READ_FAILED');
      if (bytes.length + state.audit.length > 4096) throw new Error('AUDIT_LIMIT');
      const next = new Uint8Array(bytes.length + state.audit.length); next.set(bytes); next.set(state.audit, bytes.length); bytes = next;
      let newline = bytes.indexOf(10);
      while (newline >= 0) {
        const text = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes.slice(0, newline)); bytes = bytes.slice(newline + 1);
        const data = JSON.parse(text) as Record<string, Object>;
        if (Object.keys(data).length === 1 && Number.isSafeInteger(data['nativeReturn']) && !nativeSeen) {
          nativeSeen = true; report.nativeReturn = Number(data['nativeReturn']);
        } else if (!clientSeen && (data['phase'] === 'BROKER_CLIENT_OK' || data['phase'] === 'BROKER_CLIENT_FAILED')) {
          const expected = (data['code'] === undefined ? 13 : 14) + (data['diagnostic'] === undefined ? 0 : 1);
          if (Object.keys(data).length !== expected) throw new Error('CLIENT_SCHEMA');
          for (const key of ['parallel', 'completed']) if (!Number.isSafeInteger(data[key]) || Number(data[key]) < 0 || Number(data[key]) > 100) throw new Error('CLIENT_SCHEMA');
          for (const key of ['stdoutVerified', 'stderrVerified', 'cancelled', 'exit7Verified', 'throwVerified', 'rejectVerified', 'reaped', 'modelRequestSent']) if (typeof data[key] !== 'boolean') throw new Error('CLIENT_SCHEMA');
          if (data['modelRequestSent'] !== false) throw new Error('CLIENT_SCHEMA');
          if (!Number.isSafeInteger(data['exitCasesCompleted']) || Number(data['exitCasesCompleted']) < 0 || Number(data['exitCasesCompleted']) > 3) throw new Error('CLIENT_SCHEMA');
          const classes = data['exitDiagnosticClasses'] as string[];
          const allowedClasses: string[] = ['empty', 'fixed-throw', 'fixed-reject'];
          if (!Array.isArray(classes) || classes.length > 3 || !classes.every((value: string, index: number) => value === allowedClasses[index])) throw new Error('CLIENT_SCHEMA');
          if (data['diagnostic'] !== undefined) {
            const diagnostic = data['diagnostic'] as Record<string, Object>;
            if (Object.keys(diagnostic).length !== 14 || !['normal', 'cancel', 'exit7', 'throw', 'reject'].includes(String(diagnostic['mode'])) || !['START', 'READY', 'CALL', 'DONE', 'EARLY_DONE', 'OTHER_FRAME'].includes(String(diagnostic['checkpoint']))) throw new Error('CLIENT_SCHEMA');
            if (!['none', 'timer', 'stdout-content-or-limit', 'stderr-limit', 'control-frame'].includes(String(diagnostic['failureCause']))) throw new Error('CLIENT_SCHEMA');
            for (const key of ['ready', 'called', 'done', 'signalled', 'timedOut']) if (typeof diagnostic[key] !== 'boolean') throw new Error('CLIENT_SCHEMA');
            for (const key of ['stdoutBytes', 'stderrBytes', 'inputBytes', 'stderrObservedBytes', 'stderrMaxChunkBytes']) if (!Number.isSafeInteger(diagnostic[key]) || Number(diagnostic[key]) < 0 || Number(diagnostic[key]) > 1048576) throw new Error('CLIENT_SCHEMA');
            if (diagnostic['exitCode'] !== null && (!Number.isSafeInteger(diagnostic['exitCode']) || Number(diagnostic['exitCode']) < 0 || Number(diagnostic['exitCode']) > 255)) throw new Error('CLIENT_SCHEMA');
          }
          if (data['code'] !== undefined && !['BROKER_CLIENT_ERROR', 'PROTOCOL_ERROR', 'OUTPUT_MISMATCH', 'CANCEL_FAILED', 'REAP_FAILED', 'TIMEOUT', 'EXIT_CASE_FAILED'].includes(String(data['code']))) throw new Error('CLIENT_SCHEMA');
          report.client = data as Object as ClientResult; clientSeen = true;
        } else throw new Error('AUDIT_SCHEMA');
        newline = bytes.indexOf(10);
      }
      report.exited = state.exited === 1; report.signal = state.signal; report.eof = state.auditEof === 1;
      report.callbacks = control.exited(pid) === 1 && control.signal(pid) === state.signal;
      if (report.exited && report.callbacks && report.eof) {
        const result = report.client;
        report.phase = bytes.length === 0 && nativeSeen && report.nativeReturn === 0 && state.signal === 0 && result !== undefined && result.phase === 'BROKER_CLIENT_OK' && result.parallel === 2 && result.completed === 2 && result.stdoutVerified && result.stderrVerified && result.cancelled && result.exit7Verified && result.throwVerified && result.rejectVerified && result.exitCasesCompleted === 3 && result.exitDiagnosticClasses.length === 3 && result.reaped && !result.modelRequestSent ? 'BROKER_PROBE_OK' : 'BROKER_CLIENT_FAILED'; break;
      }
      await delay();
    }
    if (report.phase === 'STARTING') report.phase = 'BROKER_PROBE_TIMEOUT';
  } catch (_) { report.phase = 'BROKER_PROBE_FAILED'; }
  finally {
    if (pid > 0) {
      if (!report.exited) client.stop(pid);
      const deadline = Date.now() + 5000;
      while (Date.now() < deadline && !(report.exited && report.callbacks && report.eof)) {
        const state = client.status(pid); report.exited = state.exited === 1; report.signal = state.signal; report.eof = state.auditEof === 1;
        report.callbacks = control.exited(pid) === 1 && control.signal(pid) === state.signal;
        if (!(report.exited && report.callbacks && report.eof)) await delay();
      }
      if (report.exited && report.callbacks && report.eof) { report.released = client.release(pid) === 1; if (report.released) control.forget(pid); }
    }
    try { if (host !== undefined) { await host.shutdown(); report.hostSettled = true; } else if (handle > 0) report.hostSettled = broker.close(handle) === 0; } catch (_) {}
    if (!report.released || !report.hostSettled) report.phase = 'BROKER_CLEANUP_FAILED';
    save(file, report); running = false;
  }
}
