import { mkdir, access, writeFile } from 'node:fs/promises';
import { join, isAbsolute, basename } from 'node:path';
import { runToolCapabilitiesProbe } from './tool-capabilities-probe.mjs';
import { runRealToolsProbe } from './real-tools-probe.mjs';
import { createFixtureConversation, readFixtureConversationAfterRestart } from './real-conversation-probe.mjs';

// 临时验收入口，仅显式全新测试home使用；不作为主应用业务入口。
export async function runLocalAcceptance(ctx, { installedRoot, fresh }) {
  if (!isAbsolute(installedRoot) || !isAbsolute(fresh) || !/^engine-tools-probe-[0-9]+$/.test(basename(fresh))) throw Error('ACCEPTANCE_SCOPE_INVALID');
  const report = { phase: 'LOCAL_ACCEPTANCE_RUNNING', stage: 'setup', capabilityErrorCode: '', conversationStage: 'not-started', coldRead: false, passed: false,
    capabilitiesPassed: false, toolsPassed: false, conversationPassed: false, differentProcess: false,
    userEvent: false, assistantEvent: false, userPersisted: false, assistantPersisted: false,
    streamed: false, loopbackRequests: 0, sseFrames: 0, otherModelsBlocked: 0,
    credentialHeaderAbsent: true, paidModelRequestSent: false, disposed: false };
  const save = () => writeFile(join(fresh, 'local-acceptance.json'), JSON.stringify(report), { mode: 0o600 });
  const fixtureParent = join(fresh, 'tools-fixtures');
  const fixtureDirectory = join(fresh, 'conversation-fixtures');
  const capabilityCodes = new Set(['', 'CAPABILITY_PROVIDER_MISSING', 'CAPABILITY_PTC_WIRE_MISMATCH', 'CAPABILITY_MINIMAL_IMAGE_MISSING', 'CAPABILITY_ADVERTISED_UNSUPPORTED', 'CAPABILITY_EMPTY_PRESET', 'CAPABILITY_STANDARD_FILES_MISSING', 'CAPABILITY_MODEL_ATTEMPT', 'CAPABILITY_PROBE_ERROR', 'CAPABILITY_DISPOSE_FAILED']);
  const conversationStages = new Set(['import', 'guard', 'listen', 'register', 'create', 'followup', 'idle', 'verify-events', 'dispose-agent', 'persistence', 'manifest', 'complete', 'cleanup', 'cold-manifest', 'cold-process', 'cold-persistence']);
  await mkdir(fixtureParent, { recursive: true, mode: 0o700 });
  await mkdir(fixtureDirectory, { recursive: true, mode: 0o700 });
  try {
    try { await access(join(fixtureDirectory, 'conversation-fixture.json')); report.coldRead = true; }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (report.coldRead) {
      report.stage = 'cold-read'; await save();
      const cold = await readFixtureConversationAfterRestart(ctx, { fixtureDirectory });
      report.conversationStage = conversationStages.has(cold.stage) ? cold.stage : 'not-started';
      for (const key of ['differentProcess', 'userPersisted', 'assistantPersisted']) report[key] = cold[key] === true;
      report.conversationPassed = cold.phase === 'FIXTURE_CONVERSATION_COLD_READ_OK';
      report.passed = report.conversationPassed;
      report.phase = report.passed ? 'LOCAL_ACCEPTANCE_COLD_READ_OK' : 'LOCAL_ACCEPTANCE_FAILED';
    } else {
      report.stage = 'capabilities'; await save();
      const capabilities = await runToolCapabilitiesProbe(ctx, { fixtureParent });
      report.capabilityErrorCode = capabilityCodes.has(capabilities.errorCode) ? capabilities.errorCode : 'CAPABILITY_PROBE_ERROR';
      report.capabilitiesPassed = capabilities.phase === 'CAPABILITY_PROBE_OK' && capabilities.disposeConfirmed === true;
      report.stage = 'tools'; await save();
      const tools = await runRealToolsProbe(ctx, { fixtureParent, installedRoot });
      await writeFile(join(fresh, 'real-tools-probe.json'), JSON.stringify(tools), { mode: 0o600 });
      report.toolsPassed = tools.phase === 'REAL_TOOLS_PROBE_OK' && tools.disposeConfirmed === true;
      report.stage = 'conversation'; await save();
      const conversation = await createFixtureConversation(ctx, { installedRoot, fixtureDirectory });
      report.conversationStage = conversationStages.has(conversation.stage) ? conversation.stage : 'not-started';
      for (const key of ['userEvent', 'assistantEvent', 'userPersisted', 'assistantPersisted', 'streamed', 'credentialHeaderAbsent', 'disposed']) report[key] = conversation[key] === true;
      for (const key of ['loopbackRequests', 'sseFrames', 'otherModelsBlocked']) {
        if (!Number.isSafeInteger(conversation[key]) || conversation[key] < 0 || conversation[key] > 65535) throw Error('ACCEPTANCE_COUNT_INVALID');
        report[key] = conversation[key];
      }
      report.conversationPassed = conversation.phase === 'FIXTURE_CONVERSATION_CREATED' && report.disposed;
      report.passed = report.capabilitiesPassed && report.toolsPassed && report.conversationPassed;
      report.phase = report.passed ? 'LOCAL_ACCEPTANCE_AWAITING_RESTART' : 'LOCAL_ACCEPTANCE_FAILED';
    }
    report.stage = 'complete';
  } catch { report.phase = 'LOCAL_ACCEPTANCE_FAILED'; }
  await save(); return report;
}
