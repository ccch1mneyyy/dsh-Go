import { UIAbility, Want, AbilityConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import legacyFileIo from '@ohos.fileio';
import { hilog } from '@kit.PerformanceAnalysisKit';

interface ToolDiagnostic {
  toolIsError: boolean; resultMatches: boolean; partialMatches: boolean;
  valueType: string; toolErrorCode: string;
}
interface ToolReport {
  phase: string; modelRequestSent: boolean; stage?: string; writeRead?: boolean;
  readOnlyDenied?: boolean; outsideDenied?: boolean; concurrentWorkspaces?: boolean;
  crossWriteDenied?: boolean; revokeStopped?: boolean; disposeConfirmed?: boolean;
  modelAttemptsBlocked?: number; errorCode?: string; errorName?: string;
  toolDiagnostic?: ToolDiagnostic;
  ptcErrorKind?: string; bindingErrorCode?: string;
  hookAvailable?: boolean; linkErrorCode?: string;
}
interface SafeMirror { status: string; content: string; terminal: boolean; }
export function validateLocalAcceptance(text: string): SafeMirror {
  const rejected: SafeMirror = { status: 'schema', content: '', terminal: false };
  if (text.length > 4096) return { status: 'length', content: '', terminal: false };
  let report: Record<string, string | boolean | number>;
  try { report = JSON.parse(text) as Record<string, string | boolean | number>; }
  catch (_) { return { status: 'parse', content: '', terminal: false }; }
  if (!report || typeof report !== 'object' || Array.isArray(report)) return rejected;
  const booleans = ['coldRead', 'passed', 'capabilitiesPassed', 'toolsPassed', 'conversationPassed', 'differentProcess', 'userEvent', 'assistantEvent', 'userPersisted', 'assistantPersisted', 'streamed', 'credentialHeaderAbsent', 'paidModelRequestSent', 'disposed'];
  const counts = ['loopbackRequests', 'sseFrames', 'otherModelsBlocked'];
  const keys = ['phase', 'stage', 'capabilityErrorCode', 'conversationStage', ...booleans, ...counts];
  if (Object.keys(report).length !== keys.length || Object.keys(report).some((key: string) => !keys.includes(key))) return rejected;
  if (!['LOCAL_ACCEPTANCE_RUNNING', 'LOCAL_ACCEPTANCE_AWAITING_RESTART', 'LOCAL_ACCEPTANCE_COLD_READ_OK', 'LOCAL_ACCEPTANCE_FAILED'].includes(report['phase'] as string) || !['setup', 'capabilities', 'tools', 'conversation', 'cold-read', 'complete'].includes(report['stage'] as string)) return rejected;
  if (booleans.some((key: string) => typeof report[key] !== 'boolean') || report['paidModelRequestSent'] !== false) return rejected;
  if (!['', 'CAPABILITY_PROVIDER_MISSING', 'CAPABILITY_ADVERTISED_UNSUPPORTED', 'CAPABILITY_EMPTY_PRESET', 'CAPABILITY_STANDARD_FILES_MISSING', 'CAPABILITY_MODEL_ATTEMPT', 'CAPABILITY_PROBE_ERROR', 'CAPABILITY_DISPOSE_FAILED', 'CAPABILITY_PTC_WIRE_MISMATCH', 'CAPABILITY_MINIMAL_IMAGE_MISSING'].includes(report['capabilityErrorCode'] as string)) return rejected;
  if (!['not-started', 'import', 'guard', 'listen', 'register', 'create', 'followup', 'idle', 'verify-events', 'dispose-agent', 'persistence', 'manifest', 'complete', 'cleanup', 'cold-manifest', 'cold-process', 'cold-persistence'].includes(report['conversationStage'] as string)) return rejected;
  if (counts.some((key: string) => typeof report[key] !== 'number' || !Number.isSafeInteger(report[key] as number) || (report[key] as number) < 0 || (report[key] as number) > 65535)) return rejected;
  return { status: 'ready', content: JSON.stringify(report), terminal: report['phase'] !== 'LOCAL_ACCEPTANCE_RUNNING' };
}
export function validateToolReport(text: string, startup: boolean): SafeMirror {
  const rejected: SafeMirror = { status: 'schema', content: '', terminal: false };
  if (text.length > 4096) return { status: 'length', content: '', terminal: false };
  let report: ToolReport;
  try { report = JSON.parse(text) as ToolReport; } catch (_) { return { status: 'parse', content: '', terminal: false }; }
  if (!report || Array.isArray(report) || typeof report !== 'object' || report.modelRequestSent !== false) return rejected;
  const keys = Object.keys(report);
  if (startup) {
    const codes = ['DSH_START_TIMEOUT', 'DSH_CLI_ENTRY_MISSING', 'DSH_SMOKE_FAILED', 'DSH_TYPEERROR', 'DSH_SYNTAXERROR', 'DSH_RANGEERROR', 'DSH_REFERENCEERROR', 'BAD_ARGUMENTS', 'BAD_PORT', 'ENTRY_HASH_MISMATCH', 'REAL_TOOLS_PROBE_SCOPE_INVALID', 'DSH_START_FAILED'];
    if (keys.length !== 3 || keys.some((key: string) => !['phase', 'errorCode', 'modelRequestSent'].includes(key)) || !['FAILED', 'PREFLIGHT_FAILED'].includes(report.phase) || typeof report.errorCode !== 'string' || !codes.includes(report.errorCode)) return rejected;
    return { status: 'ready', content: JSON.stringify(report), terminal: true };
  }
  if (['REAL_TOOLS_STARTING', 'REAL_TOOLS_HARNESS_FAILED'].includes(report.phase)) {
    if (keys.length !== 2 || keys.some((key: string) => !['phase', 'modelRequestSent'].includes(key))) return rejected;
    return { status: 'ready', content: JSON.stringify(report), terminal: report.phase === 'REAL_TOOLS_HARNESS_FAILED' };
  }
  const allowed = ['phase', 'stage', 'writeRead', 'readOnlyDenied', 'outsideDenied', 'concurrentWorkspaces', 'crossWriteDenied', 'revokeStopped', 'disposeConfirmed', 'modelAttemptsBlocked', 'modelRequestSent', 'errorCode', 'errorName', 'toolDiagnostic', 'ptcErrorKind', 'bindingErrorCode', 'hookAvailable', 'linkErrorCode'];
  const codes = ['PTC_TOOL_RESULT_FAILED', 'PLATFORM_ENFORCEMENT_MISSING', 'DENIAL_CODE_MISSING', 'WORKSPACE_CONTEXT_MISMATCH', 'PLATFORM_RUNTIME_REQUIRED', 'PHYSICAL_CONTENT_MISMATCH', 'READONLY_FILE_CREATED', 'OUTSIDE_FILE_CREATED', 'CROSS_FILE_CREATED', 'HOLD_TIMEOUT', 'REVOKED_RUN_SUCCEEDED', 'REVOKED_WRITE_COMMITTED', 'MODEL_ATTEMPT_DETECTED', 'EXTERNAL_ERROR'];
  if (keys.some((key: string) => !allowed.includes(key)) || !['STARTING', 'REAL_TOOLS_PROBE_OK', 'REAL_TOOLS_PROBE_FAILED', 'REAL_TOOLS_CLEANUP_FAILED'].includes(report.phase) || typeof report.stage !== 'string' || !['setup', 'write-read', 'read-only', 'outside', 'cross-session', 'revoke', 'complete'].includes(report.stage)) return rejected;
  if ([report.writeRead, report.readOnlyDenied, report.outsideDenied, report.concurrentWorkspaces, report.crossWriteDenied, report.revokeStopped, report.disposeConfirmed].some((value: boolean | undefined) => typeof value !== 'boolean')) return rejected;
  if (typeof report.modelAttemptsBlocked !== 'number' || !Number.isSafeInteger(report.modelAttemptsBlocked) || report.modelAttemptsBlocked < 0 || report.modelAttemptsBlocked > 1000000) return rejected;
  if (report.errorCode !== undefined && (typeof report.errorCode !== 'string' || !codes.includes(report.errorCode))) return rejected;
  if (report.errorName !== undefined && (typeof report.errorName !== 'string' || !['Error', 'TypeError', 'RangeError', 'ReferenceError', 'SyntaxError', 'AbortError', 'other'].includes(report.errorName))) return rejected;
  if (report.ptcErrorKind !== undefined && (typeof report.ptcErrorKind !== 'string' || !['none', 'exception', 'invalid-output', 'worker-exit', 'timeout', 'abort', 'output-limit', 'protocol', 'sandbox-unavailable', 'other'].includes(report.ptcErrorKind))) return rejected;
  if (report.bindingErrorCode !== undefined && (typeof report.bindingErrorCode !== 'string' || !['none', 'CODE_RUN_FAILED', 'UNKNOWN_TOOL', 'INVALID_TOOL_OUTPUT', 'ABORTED', 'ABORTED_BEFORE_DISPATCH', 'FS_SANDBOX_DENIED', 'INVALID_ARGS', 'FS_ABORTED', 'FS_AMBIGUOUS_EDIT', 'FS_EDIT_NOT_FOUND', 'FS_IO_ERROR', 'FS_NOT_DIRECTORY', 'FS_NOT_FOUND', 'FS_NOT_OBSERVED', 'FS_NOT_REGULAR_FILE', 'FS_NOT_TEXT', 'FS_PERMISSION_DENIED', 'FS_STALE_VERSION', 'FS_TOO_LARGE', 'other'].includes(report.bindingErrorCode))) return rejected;
  if (report.hookAvailable !== undefined && typeof report.hookAvailable !== 'boolean') return rejected;
  if (report.linkErrorCode !== undefined && (typeof report.linkErrorCode !== 'string' || !['none', 'EACCES', 'EPERM', 'EXDEV', 'ENOTSUP', 'EMLINK', 'EEXIST', 'ENOENT', 'ENOTDIR', 'EROFS', 'ENOSPC', 'EIO', 'other'].includes(report.linkErrorCode))) return rejected;
  if (report.toolDiagnostic !== undefined) {
    const d = report.toolDiagnostic;
    if (!d || typeof d !== 'object' || Array.isArray(d)) return rejected;
    const diagnosticKeys = Object.keys(d);
    if (diagnosticKeys.length !== 5 || diagnosticKeys.some((key: string) => !['toolIsError', 'resultMatches', 'partialMatches', 'valueType', 'toolErrorCode'].includes(key))) return rejected;
    if (typeof d.toolIsError !== 'boolean' || typeof d.resultMatches !== 'boolean' || typeof d.partialMatches !== 'boolean') return rejected;
    if (typeof d.valueType !== 'string' || !['undefined', 'null', 'array', 'object', 'string', 'number', 'boolean', 'other'].includes(d.valueType)) return rejected;
    if (typeof d.toolErrorCode !== 'string' || !['CODE_RUN_FAILED', 'UNKNOWN_TOOL', 'INVALID_TOOL_OUTPUT', 'ABORTED', 'ABORTED_BEFORE_DISPATCH', 'FS_SANDBOX_DENIED', 'other'].includes(d.toolErrorCode)) return rejected;
  }
  return { status: 'ready', content: JSON.stringify(report), terminal: report.phase !== 'STARTING' };
}

interface ToolsEntrySafe {
  stage: string;
  onCreateSeen: boolean;
  runRealToolsType: string;
  enablePrivateBrokerType: string;
  runRealToolsMatches: boolean;
  enablePrivateBrokerMatches: boolean;
  installPrefixMatches: boolean;
  dataPrefixMatches: boolean;
  endpointMatches: boolean;
  forwardStarted: boolean;
  errorName: string;
  resultMirror: string;
  startupMirror: string;
}

export default class ToolsProbeAbility extends UIAbility {
  // 临时真机验收入口；提交PR前移除。失败请求也不初始化Flutter。
  private pendingProbe: Want | undefined = undefined;
  private windowReady: boolean = false;
  private probeRoot: string = '';
  private mirrorTimer: number = -1;
  private mirrorRounds: number = 0;
  private entrySafe: ToolsEntrySafe = { stage: 'initial', onCreateSeen: false,
    runRealToolsType: 'undefined', enablePrivateBrokerType: 'undefined',
    runRealToolsMatches: false, enablePrivateBrokerMatches: false,
    installPrefixMatches: false, dataPrefixMatches: false, endpointMatches: false,
    forwardStarted: false, errorName: 'none', resultMirror: 'not-started', startupMirror: 'not-started' };

  private saveEntrySafe(stage: string): void {
    this.entrySafe.stage = stage;
    try {
      const target = this.context.filesDir + '/tools-entry-safe.json';
      const file = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(file.fd, JSON.stringify(this.entrySafe)); } finally { fs.closeSync(file); }
      legacyFileIo.chmodSync(target, 0o644);
    } catch (_) { hilog.error(0x0002, 'DshToolsProbe', '安全入口报告写入失败'); }
  }

  private entryError(error: Error, stage: string): void {
    this.entrySafe.errorName = ['Error', 'TypeError', 'RangeError', 'ReferenceError', 'SyntaxError', 'BusinessError'].includes(error?.name) ? error.name : 'other';
    this.saveEntrySafe(stage);
  }


  private validateToolsProbe(want: Want): void {
    const p = want.parameters ?? {};
    const installed = p['installedRoot'];
    const data = p['dataRoot'];
    const endpoint = p['endpointFile'];
    this.saveEntrySafe('context');
    try {
    const installPrefix = this.context.getApplicationContext().filesDir + '/engine-';
    const dataPrefix = this.context.filesDir + '/engine-tools-probe-';
    this.entrySafe.installPrefixMatches = typeof installed === 'string' && installed.startsWith(installPrefix) && /^[0-9]+$/.test(installed.slice(installPrefix.length));
    this.entrySafe.dataPrefixMatches = typeof data === 'string' && data.startsWith(dataPrefix) && /^[0-9]+$/.test(data.slice(dataPrefix.length));
    this.entrySafe.endpointMatches = typeof data === 'string' && endpoint === data + '-endpoint.json';
    this.saveEntrySafe('validated');
    if (p['runRealToolsProbe'] !== true || p['enablePrivateBroker'] !== true ||
      typeof installed !== 'string' || typeof data !== 'string' || typeof endpoint !== 'string' ||
      !installed.startsWith(installPrefix) || !/^[0-9]+$/.test(installed.slice(installPrefix.length)) ||
      !data.startsWith(dataPrefix) || !/^[0-9]+$/.test(data.slice(dataPrefix.length)) || endpoint !== data + '-endpoint.json') {
      this.saveEntrySafe('rejected');
      hilog.error(0x0002, 'DshToolsProbe', '临时工具验收参数无效'); return;
    }
    // 新代次清除本入口自己的旧镜像，不能把前轮结果当作当前结果。
    for (const name of ['tools-probe-result-safe.json', 'tools-probe-startup-safe.json', 'local-acceptance-safe.json']) {
      const previous = this.context.filesDir + '/' + name;
      if (fs.accessSync(previous)) fs.unlinkSync(previous);
    }
    // 冷启动沿用测试home，但结果必须属于本次进程，不能复用上轮终态报告。
    const previousAcceptance = data + '/local-acceptance.json';
    if (fs.accessSync(previousAcceptance)) fs.unlinkSync(previousAcceptance);
    this.probeRoot = data;
    this.pendingProbe = { bundleName: this.context.abilityInfo.bundleName, abilityName: 'EngineAbility',
      parameters: { installedRoot: installed, dataRoot: data, endpointFile: endpoint,
        enablePrivateBroker: true, runRealToolsProbe: true } };
    } catch (error) { this.entryError(error as Error, 'context-or-forward-failed'); }
  }

  private forwardPending(): void {
    if (!this.windowReady || this.pendingProbe === undefined || this.entrySafe.forwardStarted) return;
    const request = this.pendingProbe; this.pendingProbe = undefined;
    this.entrySafe.forwardStarted = true; this.saveEntrySafe('forward-started');
    try {
      this.context.startAbility(request).then(() => { this.saveEntrySafe('forward-resolved'); this.pollReports(); }).catch((error: Error) => {
        this.entryError(error, 'forward-failed');
      });
    } catch (error) { this.entryError(error as Error, 'forward-failed'); }
  }

  private mirrorOne(startup: boolean, acceptance: boolean = false): SafeMirror {
    const source = this.probeRoot + (acceptance ? '/local-acceptance.json' : startup ? '/real-tools-startup.json' : '/real-tools-probe.json');
    let text: string;
    try {
      if (!fs.accessSync(source)) return { status: 'missing', content: '', terminal: false };
      if (fs.statSync(source).size > 4096) return { status: 'length', content: '', terminal: false };
      text = fs.readTextSync(source, { length: 4097 });
    } catch (_) { return { status: 'read-failed', content: '', terminal: false }; }
    const checked = acceptance ? validateLocalAcceptance(text) : validateToolReport(text, startup);
    if (checked.status !== 'ready') return checked;
    try {
      const target = this.context.filesDir + (acceptance ? '/local-acceptance-safe.json' : startup ? '/tools-probe-startup-safe.json' : '/tools-probe-result-safe.json');
      const file = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(file.fd, checked.content); } finally { fs.closeSync(file); }
      legacyFileIo.chmodSync(target, 0o644);
    } catch (_) { return { status: 'write-failed', content: '', terminal: false }; }
    return checked;
  }

  private pollReports(): void {
    const result = this.mirrorOne(false);
    const startup = this.mirrorOne(true);
    const acceptance = this.mirrorOne(false, true);
    this.entrySafe.resultMirror = result.status;
    this.entrySafe.startupMirror = startup.status;
    this.mirrorRounds++;
    const finished = acceptance.terminal || startup.terminal;
    this.saveEntrySafe(finished ? 'mirror-terminal' : this.mirrorRounds >= 300 ? 'mirror-timeout' : 'mirror-polling');
    if (!finished && this.mirrorRounds < 300) this.mirrorTimer = setTimeout(() => { this.mirrorTimer = -1; this.pollReports(); }, 1000);
  }

  onDestroy(): void {
    if (this.mirrorTimer >= 0) clearTimeout(this.mirrorTimer);
    this.mirrorTimer = -1;
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.entrySafe.onCreateSeen = true;
    this.entrySafe.runRealToolsType = typeof want.parameters?.['runRealToolsProbe'];
    this.entrySafe.enablePrivateBrokerType = typeof want.parameters?.['enablePrivateBroker'];
    this.entrySafe.runRealToolsMatches = want.parameters?.['runRealToolsProbe'] === true;
    this.entrySafe.enablePrivateBrokerMatches = want.parameters?.['enablePrivateBroker'] === true;
    this.saveEntrySafe('on-create');
    this.validateToolsProbe(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.saveEntrySafe('window-create');
    try {
      windowStage.loadContent('pages/Engine', (error) => {
        if (error && error.code) { this.entryError(error, 'window-failed'); return; }
        this.windowReady = true; this.saveEntrySafe('window-ready');
        this.forwardPending();
      });
    } catch (error) { this.entryError(error as Error, 'window-failed'); }
  }
}
