// 固定只读RPC探针：令牌只从stdin内存接收；不列出会话内容、不调用模型。
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

export function loopbackBase(value) {
  const uri = new URL(value);
  if (uri.protocol !== 'http:' || uri.hostname !== '127.0.0.1' || !uri.port || uri.pathname !== '/' || uri.search || uri.hash || uri.username || uri.password) throw new Error('只允许不含凭据的127.0.0.1根地址与显式端口');
  return uri;
}
function exchange(uri, method, headers = {}, body = '') {
  return new Promise((resolve, reject) => {
    const request = http.request(uri, { method, headers }, response => {
      const chunks = []; let bytes = 0;
      response.on('data', chunk => { bytes += chunk.length; if (bytes > 8 * 1024 * 1024) response.destroy(new Error('响应超出探针上限')); else chunks.push(chunk); });
      response.on('error', reject);
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, text: Buffer.concat(chunks).toString('utf8') }));
    });
    request.setTimeout(10000, () => request.destroy(new Error('本地请求超时')));
    request.on('error', reject); request.end(body);
  });
}
export async function probe(baseUrl, token) {
  const base = loopbackBase(baseUrl);
  if (typeof token !== 'string' || !/^[A-Za-z0-9._~%-]+$/.test(token)) throw new Error('启动令牌格式不符');
  const login = new URL(base); login.searchParams.set('token', token);
  const exchanged = await exchange(login, 'GET');
  if (![302, 303].includes(exchanged.status)) throw new Error(`启动令牌交换HTTP ${exchanged.status}`);
  const cookie = (exchanged.headers['set-cookie'] ?? []).map(item => item.split(';', 1)[0]).find(item => item.startsWith('dsh-auth-'));
  if (!cookie) throw Object.assign(new Error('启动响应缺少认证Cookie'), { code: 'LOGIN_COOKIE_MISSING' });
  const rpcId = randomUUID();
  const request = JSON.stringify({ type: 'client-request', rpcId, method: 'session/list', payload: { args: { _request: {} } } });
  const reply = await exchange(new URL('/api/session/list', base), 'POST', { Cookie: cookie, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(request) }, request);
  if (reply.status !== 200) throw new Error(`session/list HTTP ${reply.status}`);
  const envelope = JSON.parse(reply.text);
  if (envelope.result?.ok === false) {
    const code = envelope.result.error?.code;
    const failure = new Error('只读接口返回失败');
    failure.code = typeof code === 'string' && /^[A-Za-z0-9_/-]{1,70}$/.test(code)
      ? 'RPC_' + code.replaceAll('/', '_').replaceAll('-', '_').toUpperCase() : 'RPC_FAILED';
    throw failure;
  }
  if (envelope.type !== 'server-response' || envelope.rpcId !== rpcId || envelope.result?.ok !== true || !Array.isArray(envelope.result.value?.items)) throw Object.assign(new Error('session/list协议验证失败'), { code: 'SESSION_LIST_INVALID_ENVELOPE' });
  return { tokenExchange: true, sessionList: true, sessionCount: envelope.result.value.items.length, modelRequestSent: false };
}
async function selfTest() {
  const assert = await import('node:assert/strict');
  for (const input of ['https://127.0.0.1:38081/', 'http://localhost:38081/', 'http://example.com:38081/', 'http://127.0.0.1:38081/?token=test']) assert.throws(() => loopbackBase(input));
  let requests = 0;
  let failRpc = false;
  const server = http.createServer(async (request, response) => {
    requests++;
    if (request.method === 'GET') {
      assert.equal(new URL(request.url, 'http://fixture').searchParams.get('token'), 'fixture-token');
      response.writeHead(303, { 'Set-Cookie': 'dsh-auth-fixture=v1.fixture; HttpOnly; SameSite=Strict', Location: './' }); response.end(); return;
    }
    assert.equal(request.url, '/api/session/list'); assert.equal(request.headers.cookie, 'dsh-auth-fixture=v1.fixture');
    let body = ''; for await (const chunk of request) body += chunk;
    const rpc = JSON.parse(body); assert.equal(rpc.method, 'session/list'); assert.deepEqual(rpc.payload, { args: { _request: {} } });
    response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify({ type: 'server-response', rpcId: rpc.rpcId, result: failRpc ? { ok: false, error: { code: 'session/not-ready', message: '不允许输出的服务端说明' } } : { ok: true, value: { items: [] } } }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    assert.deepEqual(await probe(`http://127.0.0.1:${server.address().port}/`, 'fixture-token'), { tokenExchange: true, sessionList: true, sessionCount: 0, modelRequestSent: false });
    assert.equal(requests, 2);
    failRpc = true;
    await assert.rejects(probe(`http://127.0.0.1:${server.address().port}/`, 'fixture-token'), { code: 'RPC_SESSION_NOT_READY', message: '只读接口返回失败' });
    console.log('6项本地协议检查通过；仅HTTP夹具，未启动DSH或模型');
  } finally { await new Promise(resolve => server.close(resolve)); }
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    if (process.argv[2] === '--self-test') await selfTest();
    else {
      let input = ''; for await (const chunk of process.stdin) { input += chunk; if (input.length > 8192) throw new Error('探针输入过大'); }
      const request = JSON.parse(input);
      console.log(JSON.stringify(await probe(request.baseUrl, request.token)));
    }
  } catch (error) {
    const code = typeof error?.code === 'string' && /^[A-Z0-9_]{1,80}$/.test(error.code) ? error.code : 'DSH_PROBE_FAILED';
    console.error(JSON.stringify({ phase: 'PROBE_FAILED', code, modelRequestSent: false }));
    process.exitCode = 1;
  }
}
