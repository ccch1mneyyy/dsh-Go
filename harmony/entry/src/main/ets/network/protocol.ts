// 协议依据本仓库 packages/dsh_client 的 Dart 实现；沿用仓库 AGPL-3.0 许可。
export interface SessionSummary { sessionId: string; title: string; cwd: string; running: boolean; agentAvailable: boolean; }
export interface ChatMessage { id: string; role: string; text: string; streaming: boolean; }
export interface FollowUpdate { messages: ChatMessage[]; running: boolean; status: string; }
interface Content { type: string; text?: string; }
interface Source { kind?: string; }
interface Message { id?: string; role?: string; content?: Content[]; source?: Source; }
interface EventData extends Message { message?: Message; }
interface WireEvent { type: string; seq: number; data?: EventData; }
interface WireRecord { event?: WireEvent; }
interface Chunk { type: string; text?: string; }
interface StoredChunk { type: string; chunk?: Chunk; texts?: string[]; }
interface Attempt { attemptId: string; stream?: StoredChunk[]; }
interface AssistantBaseline { revision?: number; activeAttempt?: Attempt; }
interface AssistantFrame { type: string; revision: number; attemptId: string; chunk?: Chunk; }
export interface FollowItem { type: string; clientId?: string; cursor?: number; records?: WireRecord[]; assistantStream?: AssistantBaseline; event?: WireEvent; frame?: AssistantFrame; }
export interface WireError { code?: string; message?: string; }
export interface MuxFrame { type: string; streamId: string; value?: FollowItem; error?: WireError; }
interface SessionProjection { title?: string; values?: SessionProjection; }
interface WireSession { sessionId: string; cwd?: string; running?: boolean; agentAvailable?: boolean; origin?: string; parentSessionId?: string; projections?: SessionProjection; }
export interface RpcValue { items?: WireSession[]; sessionId?: string; }
interface RpcResult { ok: boolean; value?: RpcValue; error?: WireError; }
interface RpcEnvelope { type: string; rpcId: string; result: RpcResult; }
interface Address { kind: string; sessionId: string; }
interface TurnWindow { minMessages: number; minTurns: number; }
interface Request { cwd?: string; sessionId?: string; address?: Address; requestId?: string; mode?: string; content?: Content[]; clientTimeZone?: string; assistantStream?: boolean; maxMessages?: number; turnWindow?: TurnWindow; }
// DSH要求空对象；命名类避免ArkTS把字面量推断为不明确的Object。
class EmptyRequest {}
export interface RpcArgs { _request?: EmptyRequest; request?: Request; }
interface RpcPayload { args: RpcArgs; }
interface RpcRequest { type: string; rpcId: string; method: string; payload: RpcPayload; }
interface OpenFrame { type: string; streamId: string; endpoint: string; payload: RpcPayload; }
interface CancelFrame { type: string; streamId: string; }

export function normalizeBaseUrl(input: string): string {
  const value = input.trim().replace(/\/+$/, '');
  if (!/^https?:\/\/(\[[0-9a-fA-F:]+\]|[^\s/:?#@]+)(:\d+)?(\/[^\s?#]*)?$/.test(value)) {
    throw new Error('请输入不含账号、查询参数或片段的 HTTP(S) 主机地址');
  }
  return value;
}
export function loginUrl(base: string, token: string): string {
  if (!token.trim()) throw new Error('启动令牌不能为空');
  return base + '/?token=' + encodeURIComponent(token);
}
export function socketUrl(base: string): string { return base.replace(/^http/, 'ws') + '/api/remote.mux'; }
export function parseAuthCookie(raw: string): string {
  const match = raw.match(/(?:^|[\n,;]\s*)(dsh-auth-[^\s=;,]+)=([^\s;,]+)/);
  if (!match) throw new Error('登录响应没有 DSH 会话 Cookie');
  return match[1] + '=' + match[2];
}
export function rpcRequest(method: string, id: string, args: RpcArgs): string {
  const request: RpcRequest = { type: 'client-request', rpcId: id, method: method, payload: { args: args } };
  return JSON.stringify(request);
}
export function readRpc(text: string, id: string): RpcValue {
  const value = JSON.parse(text) as RpcEnvelope;
  if (!value || value.type !== 'server-response' || !value.result) throw new Error('DSH RPC 响应格式错误');
  if (value.result.ok === false) throw new Error('DSH 拒绝请求：' + (value.result.error?.code ?? '未知业务错误'));
  if (value.result.ok !== true || value.rpcId !== id) throw new Error('DSH RPC 请求标识不匹配');
  return value.result.value ?? {};
}
export function listArgs(): RpcArgs { return { _request: new EmptyRequest() }; }
export function createArgs(cwd: string): RpcArgs { return cwd ? { request: { cwd: cwd } } : { request: {} }; }
export function promptArgs(sessionId: string, text: string, id: string): RpcArgs {
  if (!text.trim()) throw new Error('消息不能为空');
  return { request: { sessionId: sessionId, requestId: id, mode: 'queue', content: [{ type: 'text', text: text }], clientTimeZone: 'Asia/Shanghai' } };
}
export function cancelArgs(id: string): RpcArgs { return { request: { sessionId: id } }; }
export function openEvents(id: string): string { return openStream('$events', id, {}); }
export function cancelStream(id: string): string {
  const frame: CancelFrame = { type: 'cancel', streamId: id };
  return JSON.stringify(frame);
}
export function openFollow(id: string, sessionId: string): string {
  return openStream('session/follow', id, { request: { address: { kind: 'session', sessionId: sessionId }, assistantStream: true, maxMessages: 500, turnWindow: { minMessages: 50, minTurns: 2 } } });
}
function openStream(endpoint: string, id: string, args: RpcArgs): string {
  const frame: OpenFrame = { type: 'open', streamId: id, endpoint: endpoint, payload: { args: args } };
  return JSON.stringify(frame);
}
export function parseMux(text: string): MuxFrame {
  const frame = JSON.parse(text) as MuxFrame;
  if (!frame || typeof frame.streamId !== 'string' || !frame.streamId || !['item', 'end', 'error'].includes(frame.type)) throw new Error('DSH 流帧格式错误');
  return frame;
}
export function sessionsFrom(value: RpcValue): SessionSummary[] {
  if (!Array.isArray(value.items)) throw new Error('DSH 会话列表格式错误');
  return value.items.filter((s: WireSession) => s.origin !== 'subagent' && !s.parentSessionId).map((s: WireSession): SessionSummary => {
    return { sessionId: s.sessionId, cwd: s.cwd ?? '', title: s.projections?.title ?? s.projections?.values?.title ?? s.sessionId, running: s.running === true, agentAvailable: s.agentAvailable === true };
  });
}

// 只投影普通文本，不把上下文注入、推理或工具参数当作用户对话。
export class Transcript {
  private messages: ChatMessage[] = [];
  private cursor: number = -1;
  private revision: number = 0;
  private baseline: boolean = false;
  private running: boolean = false;
  private attempt: string = '';
  accept(item: FollowItem): FollowUpdate {
    if (item.type === 'snapshot') {
      this.messages = []; this.cursor = -1; this.revision = item.assistantStream?.revision ?? 0; this.baseline = true; this.running = false; this.attempt = '';
      for (const record of item.records ?? []) { if (record.event) this.event(record.event); }
      this.cursor = item.cursor ?? this.cursor;
      const active = item.assistantStream?.activeAttempt;
      if (active) {
        this.attempt = active.attemptId; this.running = true;
        for (const part of active.stream ?? []) {
          if (part.chunk?.type === 'text-delta') this.delta(part.chunk.text ?? '');
          if (part.type === 'text-chunks') {
            for (const text of part.texts ?? []) this.delta(text);
          }
        }
      }
    } else {
      if (!this.baseline) throw new Error('DSH 流缺少初始快照，请重新连接');
      if (item.type === 'event' && item.event) {
        if (item.event.seq > this.cursor + 1) throw new Error('DSH 历史流出现缺口，请重新打开会话');
        this.event(item.event);
      }
      if (item.type === 'assistant-stream' && item.frame) {
        const frame = item.frame;
        if (frame.revision <= this.revision) return this.current();
        if (frame.revision !== this.revision + 1) throw new Error('DSH 文本流出现缺口，请重新打开会话');
        this.revision = frame.revision;
        if (frame.type === 'start') this.attempt = frame.attemptId;
        if (frame.type === 'chunk' && frame.chunk?.type === 'text-delta') this.delta(frame.chunk.text ?? '');
        if (frame.type === 'end') this.attempt = '';
      }
    }
    return this.current();
  }
  private current(): FollowUpdate { return { messages: this.messages.slice(), running: this.running, status: this.running ? '远程运行中' : '已同步' }; }
  private delta(text: string): void {
    if (!text || !this.attempt) return;
    const id = 'stream:' + this.attempt;
    const existing = this.messages.find((m: ChatMessage) => m.id === id);
    if (existing) existing.text += text;
    else this.messages.push({ id: id, role: 'assistant', text: text, streaming: true });
  }
  private event(event: WireEvent): void {
    if (!Number.isInteger(event.seq)) throw new Error('DSH 历史序号无效');
    if (event.seq <= this.cursor) return;
    this.cursor = event.seq;
    if (event.type === 'turn/start') this.running = true;
    if (event.type === 'turn/end') this.running = false;
    const data = event.data;
    let message: Message | undefined;
    if (event.type === 'user/message' && data?.source?.kind === 'user') message = data;
    if (event.type === 'assistant/message') {
      message = data?.message;
      this.messages = this.messages.filter((m: ChatMessage) => !m.streaming);
    }
    if (!message) return;
    const text = (message.content ?? []).filter((c: Content) => c.type === 'text').map((c: Content) => c.text ?? '').join('');
    if (text) this.messages.push({ id: message.id ?? String(event.seq), role: event.type === 'user/message' ? 'user' : 'assistant', text: text, streaming: false });
  }
}
