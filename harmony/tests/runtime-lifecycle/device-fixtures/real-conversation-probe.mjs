import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { join, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';

const PROVIDER = 'ohos-fixture-loopback';
const MODEL = 'fixed-local-sse';
const PROMPT = 'DSH_FIXED_LOCAL_PROMPT';
const ANSWER = 'DSH_FIXED_LOCAL_REPLY';
const nonceKey = Symbol.for('dsh.ohos.fixture.process-nonce');
globalThis[nonceKey] ??= randomUUID();
function check(value) { if (!value) throw Error('FIXTURE_CHECK_FAILED'); }
function textMatches(message, role, text) {
  return message?.role === role && Array.isArray(message.content)
    && message.content.length === 1 && message.content[0].type === 'text' && message.content[0].text === text;
}
function inspect(events) {
  return {
    userPersisted: events.some(e => e.type === 'user/message' && textMatches(e.data, 'user', PROMPT)),
    assistantPersisted: events.some(e => e.type === 'assistant/message' && textMatches(e.data?.message, 'assistant', ANSWER)
      && e.data.message.source?.provider === PROVIDER && e.data.message.source?.model === MODEL),
  };
}
async function readExact(ctx, sessionId) {
  const stored = await ctx.sessionPersistence.open(sessionId, 'read');
  try { return inspect((await stored.read()).events); }
  finally { await stored.close(); }
}

// 只能从父新建的空凭据上下文调用；不接入用户主会话、不枚举持久化目录。
export async function createFixtureConversation(ctx, { installedRoot, fixtureDirectory }) {
  check(isAbsolute(installedRoot) && isAbsolute(fixtureDirectory));
  const report = { phase: 'FIXTURE_CONVERSATION_FAILED', stage: 'import', loopbackRequests: 0, sseFrames: 0,
    streamed: false, userEvent: false, assistantEvent: false, userPersisted: false, assistantPersisted: false,
    otherModelsBlocked: 0, credentialHeaderAbsent: true, paidModelRequestSent: false, disposed: false };
  const disposers = []; let agentHandle, server;
  const sessionId = 'session-ohos-conversation-' + randomUUID();
  const signal = AbortSignal.timeout(20000);
  try {
    const { LlmAdapter, createUserMessage } = await import(pathToFileURL(join(installedRoot, 'opt/dsh/node_modules/@deepseek-ai/dsh-llm/lib/index.js')).href);
    report.stage = 'guard';
    // 阻断器跟随整个fresh上下文销毁，避免测试结束后后台标题任务转向真实供应商。
    ctx.on('llm/stream', (options, next) => {
      if (options.provider !== PROVIDER || options.model !== MODEL) {
        report.otherModelsBlocked++; throw Error('FIXTURE_OTHER_MODEL_BLOCKED');
      }
      return next();
    }, { global: true });
    report.stage = 'listen';
    server = createServer(async (request, response) => {
      try {
        check(request.method === 'POST' && request.url === '/v1/chat/completions');
        report.credentialHeaderAbsent &&= request.headers.authorization === undefined;
        check(report.credentialHeaderAbsent);
        let body = ''; for await (const chunk of request) { body += chunk; check(body.length <= 2048); }
        const input = JSON.parse(body);
        check(input.model === MODEL && input.stream === true && input.messages?.length === 1
          && input.messages[0].role === 'user' && input.messages[0].content === PROMPT);
        report.loopbackRequests++;
        response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
        for (const text of ['DSH_FIXED_', 'LOCAL_REPLY']) response.write('data: ' + JSON.stringify({
          id: 'fixture-completion', object: 'chat.completion.chunk', model: MODEL,
          choices: [{ index: 0, delta: { content: text }, finish_reason: null }],
        }) + '\n\n');
        response.end('data: ' + JSON.stringify({ id: 'fixture-completion', object: 'chat.completion.chunk', model: MODEL,
          choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] }) + '\n\ndata: [DONE]\n\n');
      } catch { response.writeHead(400); response.end(); }
    });
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    const endpoint = `http://127.0.0.1:${server.address().port}/v1/chat/completions`;
    class FixtureAdapter extends LlmAdapter {
      async resolveModel(provider, model) {
        check(provider === PROVIDER && model === MODEL);
        return { provider, id: model, name: model, context: { contextWindow: 32768 } };
      }
      async *stream(options) {
        check(options.provider === PROVIDER && options.model === MODEL);
        check(options.messages.some(m => textMatches(m, 'user', PROMPT)));
        // 只向已绑定回环服务发送固定夹具文字，不发送上下文、配置或认证头。
        const response = await fetch(endpoint, { method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ model: MODEL, stream: true, messages: [{ role: 'user', content: PROMPT }] }),
          signal: options.signal === undefined ? signal : AbortSignal.any([signal, options.signal]), redirect: 'error' });
        check(response.ok && response.headers.get('content-type') === 'text/event-stream');
        yield { type: 'block-start', index: 0, blockType: 'text' };
        let pending = '', text = '', stopped = false, done = false;
        const decoder = new TextDecoder();
        for await (const chunk of response.body) {
          pending += decoder.decode(chunk, { stream: true }); check(pending.length <= 8192);
          let split;
          while ((split = pending.indexOf('\n\n')) >= 0) {
            const frame = pending.slice(0, split); pending = pending.slice(split + 2);
            check(frame.startsWith('data: ')); const data = frame.slice(6);
            if (data === '[DONE]') { check(stopped); done = true; continue; }
            check(!done); const event = JSON.parse(data); check(event.model === MODEL);
            const choice = event.choices?.[0]; check(choice?.index === 0);
            report.sseFrames++;
            if (choice.finish_reason === 'stop') stopped = true;
            else {
              check(!stopped && typeof choice.delta?.content === 'string'); text += choice.delta.content;
              check(ANSWER.startsWith(text)); yield { type: 'text-delta', index: 0, text: choice.delta.content };
            }
          }
        }
        check(done && stopped && pending === '' && text === ANSWER);
        report.streamed = true;
        yield { type: 'block-end', index: 0, block: { type: 'text', text } };
        yield { type: 'finish', reason: { kind: 'stop' } };
      }
    }
    report.stage = 'register';
    disposers.push(ctx.llm.registerAdapter([PROVIDER], new FixtureAdapter()));
    disposers.push(ctx.on('session/event', (session, event) => {
      if (session.id !== sessionId) return;
      const observed = inspect([event]); report.userEvent ||= observed.userPersisted; report.assistantEvent ||= observed.assistantPersisted;
    }, { global: true }));
    report.stage = 'create';
    agentHandle = await ctx.agents.create({ sessionId, meta: { cwd: fixtureDirectory }, agentOptions: { provider: PROVIDER, model: MODEL }, signal });
    report.stage = 'followup';
    agentHandle.agent.followup(createUserMessage({ content: [{ type: 'text', text: PROMPT }], source: { kind: 'user', rpcId: 'fixed-fixture-prompt' } }));
    report.stage = 'idle';
    await Promise.race([agentHandle.agent.whenIdle(), new Promise((_, reject) => signal.addEventListener('abort', () => reject(Error('FIXTURE_TIMEOUT')), { once: true }))]);
    report.stage = 'verify-events';
    check(report.userEvent && report.assistantEvent && report.streamed && report.loopbackRequests === 1 && report.sseFrames === 3);
    report.stage = 'dispose-agent';
    await agentHandle.dispose(); agentHandle = undefined;
    report.stage = 'persistence';
    Object.assign(report, await readExact(ctx, sessionId)); check(report.userPersisted && report.assistantPersisted);
    report.stage = 'manifest';
    await writeFile(join(fixtureDirectory, 'conversation-fixture.json'), JSON.stringify({ sessionId, processNonce: globalThis[nonceKey] }), { flag: 'wx', mode: 0o600 });
    report.phase = 'FIXTURE_CONVERSATION_CREATED'; report.stage = 'complete';
  } catch { report.phase = 'FIXTURE_CONVERSATION_FAILED'; }
  finally {
    try { await agentHandle?.dispose(); for (const dispose of disposers.reverse()) await dispose();
      if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); } report.disposed = true;
    } catch { report.phase = 'FIXTURE_CONVERSATION_CLEANUP_FAILED'; report.stage = 'cleanup'; }
  }
  return report;
}

// 父必须重启原运行引擎并使用相同独立测试数据根后再调用；本函数不伪造重启。
export async function readFixtureConversationAfterRestart(ctx, { fixtureDirectory }) {
  const report = { phase: 'FIXTURE_CONVERSATION_COLD_READ_FAILED', stage: 'cold-manifest', differentProcess: false, userPersisted: false, assistantPersisted: false, paidModelRequestSent: false };
  try {
    check(isAbsolute(fixtureDirectory));
    const marker = JSON.parse(await readFile(join(fixtureDirectory, 'conversation-fixture.json'), 'utf8'));
    check(/^session-ohos-conversation-[0-9a-f-]{36}$/.test(marker.sessionId));
    report.stage = 'cold-process';
    report.differentProcess = marker.processNonce !== globalThis[nonceKey]; check(report.differentProcess);
    report.stage = 'cold-persistence';
    Object.assign(report, await readExact(ctx, marker.sessionId));
    check(report.userPersisted && report.assistantPersisted); report.phase = 'FIXTURE_CONVERSATION_COLD_READ_OK'; report.stage = 'complete';
  } catch { }
  return report;
}
