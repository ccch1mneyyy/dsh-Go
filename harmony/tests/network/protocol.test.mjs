// 真实上游fixture与本地mock，不连接模型供应商，不发起付费请求。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, rm, copyFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
const directory = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(directory, '../../..');
const source = path.join(root, 'harmony/entry/src/main/ets/network');
const temp = await mkdtemp(path.join(directory, '.test-'));
await copyFile(path.join(source, 'protocol.ts'), path.join(temp, 'protocol.ts'));
await writeFile(path.join(temp, 'package.json'), '{"type":"module"}');
const coreSource = await readFile(path.join(source, 'ClientCore.ts'), 'utf8');
await writeFile(path.join(temp, 'ClientCore.ts'), coreSource.replaceAll("'./protocol'", "'./protocol.ts'"));
const p = await import(pathToFileURL(path.join(temp, 'protocol.ts')).href);
const { ClientCore } = await import(pathToFileURL(path.join(temp, 'ClientCore.ts')).href);
test.after(async () => { await rm(temp, { recursive: true, force: true }); });

test('登录URL编码令牌，Cookie提取不混入属性', () => {
  assert.equal(p.loginUrl('https://host', 'a&b#c'), 'https://host/?token=a%26b%23c');
  assert.equal(p.parseAuthCookie('other=one; Path=/, dsh-auth-port=v1.secret; HttpOnly'), 'dsh-auth-port=v1.secret');
  assert.throws(() => p.normalizeBaseUrl('https://user:secret@host'));
  assert.throws(() => p.normalizeBaseUrl('https://host/?token=secret'));
});
test('上游RPC fixture读出列表及业务错误，并拒绝错配响应', async () => {
  const exchanges = JSON.parse(await readFile(path.join(root, 'packages/dsh_client/test/fixtures/rpc_exchanges.json'), 'utf8'));
  const entry = exchanges.find(e => e.endpoint === 'session/list');
  assert.deepEqual(p.readRpc(JSON.stringify(entry.response), entry.response.rpcId), { items: [] });
  const failure = exchanges.find(e => e.response.result.ok === false);
  assert.throws(() => p.readRpc(JSON.stringify(failure.response), 'other'), /gateway\/internal/);
  assert.throws(() => p.readRpc(JSON.stringify(entry.response), 'other'), /不匹配/);
  const open = JSON.parse(p.openFollow('f', 's'));
  assert.deepEqual(open.payload.args.request.address, { kind: 'session', sessionId: 's' });
});
test('完整真实回复fixture：去重、隐去上下文、流式内容提交后不双显', async () => {
  const lines = (await readFile(path.join(root, 'packages/dsh_client/test/fixtures/follow_reply_ok.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
  const transcript = new p.Transcript();
  let result;
  for (const frame of lines) { result = transcript.accept(frame); transcript.accept(frame.type === 'event' ? frame : { type: 'ignored' }); }
  assert.equal(result.messages.length, 2);
  assert.equal(result.messages[0].role, 'user');
  assert.equal(result.messages[1].text, 'OK');
  assert.equal(result.messages[1].streaming, false);
  assert.equal(result.running, false);
  assert.throws(() => transcript.accept({ type: 'event', event: { type: 'turn/start', seq: 999 } }), /缺口/);
});
test('正在生成的快照只显示文本压缩块，不泄露推理或工具参数', () => {
  const transcript = new p.Transcript();
  const result = transcript.accept({type:'snapshot', cursor:4, records:[], assistantStream:{revision:3,
    activeAttempt:{attemptId:'a', stream:[{type:'reasoning-chunks',texts:['private reasoning']},
      {type:'tool-call-chunks',args:['tool input']}, {type:'text-chunks',texts:['visible']}]}}});
  assert.equal(result.messages[0].text, 'visible');
  assert.equal(result.running, true);
});

class MockTransport {
  calls = []; sent = []; callback = () => {}; lost = () => {};
  async request(url, method, body, cookie) {
    this.calls.push({ url, method, body, cookie });
    if (method === 'GET') return { status: 303, cookies: 'dsh-auth-test=v1.mock; Path=/', body: '' };
    const request = JSON.parse(body);
    let value = {};
    if (request.method === 'session/list') value = { items: [{sessionId: 's', running: false}] };
    if (request.method === 'session/create') value = { sessionId: 'new' };
    return { status: 200, cookies: '', body: JSON.stringify({type: 'server-response', rpcId: request.rpcId, result: {ok: true, value}}) };
  }
  async open(url, cookie, callback, lost) {
    assert.equal(url, 'ws://localhost:3080/api/remote.mux');
    assert.equal(cookie, 'dsh-auth-test=v1.mock');
    this.callback = callback; this.lost = lost;
    return { send: async text => {
      this.sent.push(JSON.parse(text));
      const frame = JSON.parse(text);
      if (frame.endpoint === '$events') callback(JSON.stringify({type:'item', streamId:frame.streamId, value:{type:'ready',clientId:'mock'}}));
    }, close: () => {} };
  }
}
test('mock端到端：真实路径/信封、queue发送、关闭及断线不取消任务', async () => {
  const transport = new MockTransport(); const client = new ClientCore(transport);
  await client.connect('http://localhost:3080', 'mock');
  assert.equal((await client.listSessions())[0].sessionId, 's');
  assert.equal(await client.createSession('/tmp/ws'), 'new');
  await client.watchSession('s', () => {}); await client.sendPrompt('s', 'hello');
  const prompt = transport.calls.find(c => c.url.endsWith('/api/session/prompt'));
  assert.equal(JSON.parse(prompt.body).payload.args.request.mode, 'queue');
  await client.cancelSession('s');
  assert.equal(transport.calls.filter(c => c.url.endsWith('/api/session/cancel')).length, 1);
  transport.lost('本地mock断线'); client.disconnect();
  assert.equal(transport.calls.filter(c => c.url.endsWith('/api/session/cancel')).length, 1);
  await assert.rejects(client.sendPrompt('s', 'again'), /尚未连接/);
});

test('连接期间onLost保留具体原因，不被关闭或连接取消错误覆盖', async () => {
  for (const rejectOpen of [false, true]) {
    const reason = 'WebSocket 错误，平台错误码 2300007';
    let closed = 0;
    const transport = new MockTransport();
    transport.open = async (_url, _cookie, _message, lost) => {
      lost(reason);
      if (rejectOpen) throw new Error('连接已关闭');
      return { send: async () => {}, close: () => { closed += 1; } };
    };
    const client = new ClientCore(transport);
    const notices = [];
    client.onDisconnect = message => notices.push(message);
    await assert.rejects(client.connect('http://localhost:3080', 'mock'), error => error.message === reason);
    assert.deepEqual(notices, [reason]);
    assert.equal(closed, rejectOpen ? 0 : 1);
    await assert.rejects(client.sendPrompt('s', '不应发送'), /尚未连接/);
    assert.equal(transport.calls.filter(call => call.method === 'POST').length, 0);
  }
});
