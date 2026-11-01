import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const modules = process.argv[2];
if (!modules) throw Error('需传入固定发行资产node_modules路径');
const require = createRequire(path.resolve(modules, 'account-controller-test.cjs'));
const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)).href);
const patch = require('js-yaml').load(await readFile(new URL('../../plugins/dsh_runtime_ohos/assets/platform-diagnostic.patch.yml', import.meta.url), 'utf8'));
assert.equal(patch.find(row => row.id === 'account-controller').disabled, false);
const { Context } = await load('cordis');
const { default: Registry } = await load('dsh-typert-registry');
const { default: Gateway } = await load('dsh-api-gateway');
const { default: AccountController } = await load('dsh-api-account-controller');
const { TYPERT } = await load('dsh-api-account-controller/typert');
const ctx = new Context();
const client = { version: 'fixed-test', locale: 'zh-CN', timezoneOffsetSeconds: 28800 };
const origin = 'http://127.0.0.1:38081';
const fixtureToken = 'fixed-private-token-not-a-real-grant';
let state = { status: 'credential-stored', links: { usageUrl: 'https://platform.deepseek.com/usage', topUpUrl: 'https://platform.deepseek.com/top_up' }, attempt: null };
let starts = 0, cancels = 0, signOuts = 0, tokenReads = 0, watchesClosed = 0;
const account = {
  async getState() { return structuredClone(state); },
  async *watch() { try { yield structuredClone(state); } finally { watchesClosed++; } },
  async startSignIn(metadata, callbackOrigin, loginSource) {
    starts++; assert.deepEqual(metadata, client); assert.equal(callbackOrigin, origin); assert.equal(loginSource, 'web');
    state = { ...state, attempt: { id: 'fixed-attempt', phase: 'waiting-browser', authorizeUrl: 'https://platform.deepseek.com/dsh/authorize?fixed=test', expiresAt: 1000 } };
    return structuredClone(state);
  },
  async cancelSignIn(attemptId) {
    cancels++; assert.equal(attemptId, 'fixed-attempt');
    state = { ...state, attempt: { id: attemptId, phase: 'cancelled' } };
    return structuredClone(state);
  },
  async signOut() { signOuts++; throw Error('禁止测试自动注销已有会话'); },
  async resolveToken() { tokenReads++; return fixtureToken; },
  async getPlatformSession() { tokenReads++; return { token: fixtureToken }; }
};
const peer = { principal: { kind: 'owner' }, signal: new AbortController().signal };
const signal = new AbortController().signal;
const safe = result => { assert.equal(JSON.stringify(result).includes(fixtureToken), false); return result; };
try {
  // 仅使用内存安全账号；不挂真实凭据服务、不调用登录网页或现有 live 测试。
  ctx.provide('deepseekAccount', account);
  ctx.provide('agents', { list: () => [] });
  ctx.provide('remoteAccess', { decide() { throw Error('本测试仅允许 owner 调用'); } });
  await ctx.plugin(Registry);
  ctx.typert.register(TYPERT);
  await ctx.plugin(Gateway, {});
  await ctx.plugin(AccountController);
  assert(ctx.accountController);
  const rpc = async (endpoint, args = {}) => safe(await ctx.typertGateway.invokeRpc(endpoint, { args }, signal, peer));
  assert.deepEqual(await rpc('account/getState'), { ok: true, value: state });
  assert.equal(state.status, 'credential-stored');
  assert.equal(starts, 0); assert.equal(signOuts, 0);
  const stream = await ctx.typertGateway.stream({ namespace: 'account', method: 'watch', args: {}, peer, signal });
  const iterator = stream[Symbol.asyncIterator]();
  try { assert.deepEqual(safe((await iterator.next()).value), state); }
  finally { await iterator.return(); }
  assert.equal(watchesClosed, 1); assert.equal(signOuts, 0);
  // 直接设置隔离夹具为未登录；绝不通过 signOut 清理现有会话。
  state = { ...state, status: 'signed-out' };
  const started = await rpc('account/startSignIn', { client, callbackOrigin: origin, loginSource: 'web' });
  assert.equal(started.ok, true); assert.equal(started.value.attempt.phase, 'waiting-browser');
  assert.equal(starts, 1);
  const cancelled = await rpc('account/cancelSignIn', { attemptId: 'fixed-attempt' });
  assert.equal(cancelled.ok, true); assert.equal(cancelled.value.attempt.phase, 'cancelled');
  assert.equal(cancels, 1);
  for (const endpoint of ['account/resolveToken', 'account/getPlatformSession']) {
    const result = await rpc(endpoint);
    assert.equal(result.ok, false); assert.equal(result.error.code, 'gateway/invocation-unavailable');
  }
  assert.equal(tokenReads, 0); assert.equal(signOuts, 0);
  console.log(JSON.stringify({ accountMounted: true, existingSessionPreserved: true, getStateWatch: true, startCancel: true, privateTokenEndpointsAbsent: true, tokenReads, signOuts }));
} finally {
  await ctx.fiber.dispose();
}
