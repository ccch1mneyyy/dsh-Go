import { mkdtemp, mkdir, readFile, access } from 'node:fs/promises';
import { join, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
const checkCodes = new Set(['PTC_TOOL_RESULT_FAILED', 'PLATFORM_ENFORCEMENT_MISSING', 'DENIAL_CODE_MISSING', 'WORKSPACE_CONTEXT_MISMATCH', 'PLATFORM_RUNTIME_REQUIRED', 'PHYSICAL_CONTENT_MISMATCH', 'READONLY_FILE_CREATED', 'OUTSIDE_FILE_CREATED', 'CROSS_FILE_CREATED', 'HOLD_TIMEOUT', 'REVOKED_RUN_SUCCEEDED', 'REVOKED_WRITE_COMMITTED', 'MODEL_ATTEMPT_DETECTED']);
class ProbeFailure extends Error {}
const errorNames = new Set(['Error', 'TypeError', 'RangeError', 'ReferenceError', 'SyntaxError', 'AbortError']);
// 仅自己的固定检查码可输出；外部异常不读取message。
function safeFailure(error) {
  return error instanceof ProbeFailure && checkCodes.has(error.message) ? { errorCode: error.message } : { errorCode: 'EXTERNAL_ERROR', errorName: errorNames.has(error?.name) ? error.name : 'other' };
}
// 只供父在已有空凭据测试DSH上下文显式调用；不自动获取全局ctx、不枚举会话。
export async function runRealToolsProbe(ctx, { fixtureParent, installedRoot }) {
  if (!isAbsolute(fixtureParent) || !isAbsolute(installedRoot)) throw Error('PROBE_PATH_INVALID');
  const report = { phase: 'STARTING', stage: 'setup', writeRead: false, readOnlyDenied: false, outsideDenied: false,
    concurrentWorkspaces: false, crossWriteDenied: false, revokeStopped: false, disposeConfirmed: false,
    modelAttemptsBlocked: 0, modelRequestSent: false, ptcErrorKind: 'none', bindingErrorCode: 'none', linkErrorCode: 'none', hookAvailable: false };
  const handles = [], effects = []; const agents = new Set(); const denied = [];
  let releaseHeld = () => {}; let heldResolve; const held = new Promise(r => { heldResolve = r; });
  let revokeAgent, holdEnabled = false;
  const hadKindHook = Object.hasOwn(globalThis, '__dshPtcProbeKind');
  const previousKindHook = globalThis.__dshPtcProbeKind;
  const ptcKinds = new Set(['none', 'exception', 'invalid-output', 'worker-exit', 'timeout', 'abort', 'output-limit', 'protocol', 'sandbox-unavailable']);
  const bindingCodes = new Set(['CODE_RUN_FAILED', 'UNKNOWN_TOOL', 'INVALID_TOOL_OUTPUT', 'INVALID_ARGS', 'ABORTED', 'ABORTED_BEFORE_DISPATCH', 'FS_SANDBOX_DENIED', 'FS_ABORTED', 'FS_AMBIGUOUS_EDIT', 'FS_EDIT_NOT_FOUND', 'FS_IO_ERROR', 'FS_NOT_DIRECTORY', 'FS_NOT_FOUND', 'FS_NOT_OBSERVED', 'FS_NOT_REGULAR_FILE', 'FS_NOT_TEXT', 'FS_PERMISSION_DENIED', 'FS_STALE_VERSION', 'FS_TOO_LARGE']);
  const check = (value, code) => { if (!value) throw new ProbeFailure(code); };
  const missing = async path => { try { await access(path); return false; } catch (error) { if (error.code === 'ENOENT') return true; throw error; } };
  try {
  // 临时验收只接收kind，结束恢复；不接收结果对象、错误正文或路径。
  globalThis.__dshPtcProbeKind = kind => {
    const classified = kind == null ? 'none' : ptcKinds.has(kind) ? kind : 'other';
    if (report.ptcErrorKind === 'none' && classified !== 'none') report.ptcErrorKind = classified;
  };
  const { setSandboxMode } = await import(pathToFileURL(join(installedRoot, 'opt/dsh/node_modules/@deepseek-ai/dsh-sandbox-policy/lib/index.js')).href);
  // 仅阻断，不调用next，不读取options/凭据。测试期间全上下文模型请求都不允许。
  effects.push(ctx.on('llm/stream', () => { report.modelAttemptsBlocked++; throw Error('TEST_MODEL_FORBIDDEN'); }, { global: true }));
  effects.push(ctx.on('tools/result', (exec, result) => {
    if (report.stage === 'write-read' && report.bindingErrorCode === 'none' && agents.has(exec.agent) && ['read', 'write'].includes(exec.name) && result.isError) {
      const code = result.error?.info?.code;
      report.bindingErrorCode = code == null ? 'none' : bindingCodes.has(code) ? code : 'other';
    }
    if (agents.has(exec.agent) && exec.name === 'write' && result.isError && result.error?.info?.code === 'FS_SANDBOX_DENIED') denied.push(exec.agent);
  }, { global: true }));
  effects.push(ctx.on('tools/execute', async (exec, next) => {
    if (holdEnabled && exec.agent === revokeAgent && exec.name === 'write' && exec.arguments.file_path === 'revoke.txt') {
      holdEnabled = false; heldResolve(); await new Promise(r => { releaseHeld = r; });
    }
    return next();
  }, { global: true }));
  let sequence = 0;
  async function run(agent, code, signal = AbortSignal.timeout(20000)) {
    return ctx.tools.execute({ callId: 'ohos-tools-probe-' + (++sequence), name: 'run_code', agent,
      arguments: { code, description: '鸿蒙固定无模型工具验收', timeoutMs: 15000 }, signal });
  }
  async function expectValue(agent, code, expected) {
    const outcome = await run(agent, code);
    if (outcome.isError || outcome.value?.result !== expected || outcome.value?.sandbox?.enforcement !== 'partial') {
      const value = outcome.value?.result;
      const valueType = value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value;
      const allowedCodes = new Set(['CODE_RUN_FAILED', 'UNKNOWN_TOOL', 'INVALID_TOOL_OUTPUT', 'ABORTED', 'ABORTED_BEFORE_DISPATCH', 'FS_SANDBOX_DENIED']);
      // 真实工具错误结构是error.info；不读取message或从正文提取PTC失败原因。
      report.toolDiagnostic ??= {
        toolIsError: outcome.isError === true,
        resultMatches: value === expected,
        partialMatches: outcome.value?.sandbox?.enforcement === 'partial',
        valueType: ['undefined', 'null', 'array', 'object', 'string', 'number', 'boolean'].includes(valueType) ? valueType : 'other',
        toolErrorCode: allowedCodes.has(outcome.error?.info?.code) ? outcome.error.info.code : 'other',
      };
    }
    check(!outcome.isError && outcome.value?.result === expected, 'PTC_TOOL_RESULT_FAILED');
    check(outcome.value?.sandbox?.enforcement === 'partial', 'PLATFORM_ENFORCEMENT_MISSING');
  }
  async function expectDenied(agent, path) {
    const count = denied.length;
    await expectValue(agent, `try { await tools.write({file_path:${JSON.stringify(path)},content:'FORBIDDEN_FIXED'}); return false; } catch (error) { return error.name === 'ToolCallError' && error.toolName === 'write'; }`, true);
    check(denied.length === count + 1 && denied.at(-1) === agent, 'DENIAL_CODE_MISSING');
  }
    const root = await mkdtemp(join(fixtureParent, 'real-tools-'));
    const dirs = [join(root, 'a'), join(root, 'b')]; for (const directory of dirs) await mkdir(directory);
    for (const directory of dirs) {
      const handle = await ctx.agents.create({ sessionId: 'session-ohos-probe-' + randomUUID(), meta: { cwd: directory },
        agentOptions: {}, setup: async (scope) => {
          await ctx.agentPresets.mount(scope, 'standard');
          scope.tools.presentAs('ptc'); scope.tools.restrict({ allow: ['read', 'write'] });
        } });
      handles.push(handle); agents.add(handle.agent); setSandboxMode(handle.agent.session, 'workspace-write');
      const policy = ctx.sandboxPolicy.resolve({ session: handle.agent.session });
      check(policy.workspaceRoot === directory, 'WORKSPACE_CONTEXT_MISMATCH');
      const resolved = ctx.ptcRuntime.resolve({ program: 'return 0', bindings: [], cwd: directory, sandboxPolicy: policy });
      check(resolved.cwd === directory && resolved.workerCwd === '/' && resolved.executionScope === 'isolated-bindings', 'PLATFORM_RUNTIME_REQUIRED');
    }
    const [a, b] = handles.map(handle => handle.agent);
    report.stage = 'write-read';
    await Promise.all([['A', a], ['B', b]].map(async ([letter, agent]) => {
      const text = 'FIXED_' + letter;
      await expectValue(agent, `await tools.write({file_path:'same.txt',content:${JSON.stringify(text)}}); const value=await tools.read({file_path:'same.txt'}); return value.lines.map(line=>line.text).join('\\n');`, text);
    }));
    check(await readFile(join(dirs[0], 'same.txt'), 'utf8') === 'FIXED_A' && await readFile(join(dirs[1], 'same.txt'), 'utf8') === 'FIXED_B', 'PHYSICAL_CONTENT_MISMATCH');
    report.writeRead = true; report.concurrentWorkspaces = true;
    report.stage = 'read-only'; setSandboxMode(a.session, 'read-only');
    await expectDenied(a, 'readonly.txt'); check(await missing(join(dirs[0], 'readonly.txt')), 'READONLY_FILE_CREATED'); report.readOnlyDenied = true;
    setSandboxMode(a.session, 'workspace-write');
    report.stage = 'outside'; await expectDenied(a, '../outside.txt'); check(await missing(join(root, 'outside.txt')), 'OUTSIDE_FILE_CREATED'); report.outsideDenied = true;
    report.stage = 'cross-session'; await expectDenied(a, join(dirs[1], 'cross.txt')); check(await missing(join(dirs[1], 'cross.txt')), 'CROSS_FILE_CREATED'); report.crossWriteDenied = true;
    report.stage = 'revoke'; revokeAgent = a; holdEnabled = true;
    const pending = run(a, `await tools.write({file_path:'revoke.txt',content:'MUST_NOT_COMMIT'}); return true;`);
    try { await Promise.race([held, new Promise((_, reject) => setTimeout(() => reject(new ProbeFailure('HOLD_TIMEOUT')), 15000))]);
      setSandboxMode(a.session, 'read-only');
    } finally { releaseHeld(); }
    const cancelled = await pending; check(cancelled.isError, 'REVOKED_RUN_SUCCEEDED');
    check(await missing(join(dirs[0], 'revoke.txt')), 'REVOKED_WRITE_COMMITTED'); report.revokeStopped = true;
    check(report.modelAttemptsBlocked === 0, 'MODEL_ATTEMPT_DETECTED');
    report.phase = 'REAL_TOOLS_PROBE_OK'; report.stage = 'complete';
  } catch (error) { report.phase = 'REAL_TOOLS_PROBE_FAILED'; Object.assign(report, safeFailure(error)); }
  finally {
    if (hadKindHook) globalThis.__dshPtcProbeKind = previousKindHook;
    else delete globalThis.__dshPtcProbeKind;
    releaseHeld();
    try { for (const handle of handles) await handle.dispose(); report.disposeConfirmed = true; }
    catch (error) { report.phase = 'REAL_TOOLS_CLEANUP_FAILED'; Object.assign(report, safeFailure(error)); }
    for (const dispose of effects.reverse()) { try { await dispose(); } catch (error) { report.phase = 'REAL_TOOLS_CLEANUP_FAILED'; Object.assign(report, safeFailure(error)); } }
  }
  return report;
}
