import { mkdtemp } from 'node:fs/promises';
import { join, isAbsolute } from 'node:path';
import { randomUUID } from 'node:crypto';
const unsupported = ['bash', 'pwsh', 'glob', 'grep', 'terminal_open', 'terminal_send', 'terminal_read', 'terminal_signal', 'terminal_close', 'terminal_list'];
// schemas是注册目录，wireSchemas才是PTC折叠后的模型入口；SDK目录才代表绑定能力。
export function inspectToolCapabilities(tools, agent) {
  const registered = tools.schemas(agent).map(item => item.name);
  const model = tools.wireSchemas(agent).schemas.map(item => item.name);
  const bound = tools.sdkSchemas(agent).map(item => item.name);
  return { registeredCount: registered.length, schemaCount: model.length, bindingCount: bound.length,
    unexpectedRegistered: unsupported.filter(name => registered.includes(name)),
    unexpectedSchemas: unsupported.filter(name => model.includes(name)),
    unexpectedBindings: unsupported.filter(name => bound.includes(name)),
    ptcWireOnly: model.length === 1 && model[0] === 'run_code',
    readPresent: bound.includes('read'), writePresent: bound.includes('write'),
    editPresent: bound.includes('edit'), readImagePresent: bound.includes('read_image') };
}
// 只建新测试Agent并枚举真实注册目录，不执行工具、不提交模型请求、不调用restrict。
export async function runToolCapabilitiesProbe(ctx, { fixtureParent }) {
  if (!isAbsolute(fixtureParent)) throw Error('CAPABILITY_PROBE_PATH_INVALID');
  const report = { phase: 'CAPABILITY_PROBE_STARTING', standard: null, minimal: null,
    modelAttemptsBlocked: 0, modelRequestSent: false, disposeConfirmed: false, errorCode: '' };
  const handles = [];
  const stopModels = ctx.on('llm/stream', () => { report.modelAttemptsBlocked++; throw Error('TEST_MODEL_FORBIDDEN'); }, { global: true });
  try {
    if (ctx.subprocess?.ohosIsolatedPtc !== true) throw Error('CAPABILITY_PROVIDER_MISSING');
    for (const preset of ['standard', 'minimal']) {
      const directory = await mkdtemp(join(fixtureParent, 'capability-'));
      const handle = await ctx.agents.create({ sessionId: 'session-ohos-capabilities-' + randomUUID(), meta: { cwd: directory }, agentOptions: {},
        setup: async scope => { await ctx.agentPresets.mount(scope, preset); scope.tools.presentAs('ptc'); } });
      handles.push(handle);
      const result = inspectToolCapabilities(ctx.tools, handle.agent);
      report[preset] = result;
      if (result.unexpectedRegistered.length || result.unexpectedSchemas.length || result.unexpectedBindings.length) throw Error('CAPABILITY_ADVERTISED_UNSUPPORTED');
      if (!result.ptcWireOnly) throw Error('CAPABILITY_PTC_WIRE_MISMATCH');
      // run_code本身不能冒充有效工具绑定：空SDK目录明确失败。
      if (!result.bindingCount) throw Error('CAPABILITY_EMPTY_PRESET');
      if (preset === 'standard' && (!result.readPresent || !result.writePresent)) throw Error('CAPABILITY_STANDARD_FILES_MISSING');
      if (preset === 'minimal' && !result.readImagePresent) throw Error('CAPABILITY_MINIMAL_IMAGE_MISSING');
    }
    if (report.modelAttemptsBlocked) throw Error('CAPABILITY_MODEL_ATTEMPT');
    report.phase = 'CAPABILITY_PROBE_OK';
  } catch (error) {
    report.phase = 'CAPABILITY_PROBE_FAILED';
    const allowed = ['CAPABILITY_PROVIDER_MISSING', 'CAPABILITY_PTC_WIRE_MISMATCH', 'CAPABILITY_MINIMAL_IMAGE_MISSING', 'CAPABILITY_ADVERTISED_UNSUPPORTED', 'CAPABILITY_EMPTY_PRESET', 'CAPABILITY_STANDARD_FILES_MISSING', 'CAPABILITY_MODEL_ATTEMPT'];
    report.errorCode = allowed.includes(error?.message) ? error.message : 'CAPABILITY_PROBE_ERROR';
  } finally {
    try { for (const handle of handles) await handle.dispose(); report.disposeConfirmed = true; }
    catch (_) { report.phase = 'CAPABILITY_PROBE_FAILED'; report.errorCode = 'CAPABILITY_DISPOSE_FAILED'; }
    stopModels();
  }
  return report;
}
