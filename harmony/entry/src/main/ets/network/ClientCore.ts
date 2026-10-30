// 与上游 Dart 客户端协议对应；沿用仓库 AGPL-3.0 许可。
import { normalizeBaseUrl, loginUrl, socketUrl, parseAuthCookie, rpcRequest, readRpc, listArgs, createArgs, promptArgs, cancelArgs, openEvents, openFollow, cancelStream, parseMux, sessionsFrom, Transcript } from './protocol';
import type { SessionSummary, FollowUpdate, RpcArgs, RpcValue } from './protocol';

export interface HttpReply { status: number; body: string; cookies: string; }
export interface SocketPort { send(text: string): Promise<void>; close(): void; }
export interface Transport {
  request(url: string, method: string, body: string, cookie: string): Promise<HttpReply>;
  open(url: string, cookie: string, onMessage: (text: string) => void, onLost: (message: string) => void): Promise<SocketPort>;
}

export class ClientCore {
  public onDisconnect: (message: string) => void = (_message: string): void => {};
  private transport: Transport;
  private base: string = '';
  private cookie: string = '';
  private socket: SocketPort | undefined;
  private eventsId: string = '';
  private followId: string = '';
  private connected: boolean = false;
  private epoch: number = 0;
  private counter: number = 0;
  private transcript: Transcript = new Transcript();
  private listener: (update: FollowUpdate) => void = (_update: FollowUpdate): void => {};
  private readyResolve: (() => void) | undefined;
  private readyReject: ((error: Error) => void) | undefined;
  constructor(transport: Transport) { this.transport = transport; }

  async connect(baseUrl: string, token: string): Promise<void> {
    this.disconnect();
    const epoch = this.epoch;
    this.base = normalizeBaseUrl(baseUrl);
    // 保存本次连接的底层失败，避免清理动作或open的后续拒绝覆盖诊断。
    let connectionFailure: Error | undefined;
    try {
      const reply = await this.transport.request(loginUrl(this.base, token), 'GET', '', '');
      if (epoch !== this.epoch) throw new Error('连接已取消');
      if (reply.status !== 302 && reply.status !== 303) throw new Error('DSH 登录失败，HTTP ' + String(reply.status));
      this.cookie = parseAuthCookie(reply.cookies);
      this.eventsId = this.id();
      const ready = new Promise<void>((resolve, reject) => { this.readyResolve = resolve; this.readyReject = reject; });
      // 在WebSocket连接期间ready也可能被断线拒绝，立即附加处理避免悬空拒绝。
      ready.catch((_error: Error) => {});
      const socket = await this.transport.open(socketUrl(this.base), this.cookie,
        (text: string) => { if (epoch === this.epoch) this.receive(text); },
        (message: string) => {
          if (epoch === this.epoch) { connectionFailure = new Error(message); this.lost(message); }
        });
      if (epoch !== this.epoch) { socket.close(); throw connectionFailure ?? new Error('连接已取消'); }
      this.socket = socket;
      await socket.send(openEvents(this.eventsId));
      const timer = setTimeout(() => { this.readyReject?.(new Error('等待 DSH ready 握手超时')); }, 15000);
      try { await ready; } finally { clearTimeout(timer); this.readyResolve = undefined; this.readyReject = undefined; }
      if (epoch !== this.epoch) throw new Error('连接已取消');
      this.connected = true;
    } catch (error) { if (epoch === this.epoch) this.disconnect(); throw connectionFailure ?? (error as Error); }
  }
  async listSessions(): Promise<SessionSummary[]> { return sessionsFrom(await this.call('session/list', listArgs())); }
  async createSession(cwd: string = ''): Promise<string> {
    const value = await this.call('session/create', createArgs(cwd));
    if (!value.sessionId) throw new Error('DSH 新会话响应缺少 sessionId');
    return value.sessionId;
  }
  async watchSession(sessionId: string, listener: (update: FollowUpdate) => void): Promise<void> {
    this.requireConnection();
    const previous = this.followId;
    this.followId = this.id(); this.transcript = new Transcript(); this.listener = listener;
    if (previous) await this.socket!.send(cancelStream(previous));
    // 这里只取消旧的订阅，不取消远程模型任务。
    await this.socket!.send(openFollow(this.followId, sessionId));
  }
  async sendPrompt(sessionId: string, text: string): Promise<string> {
    const requestId = this.id();
    await this.call('session/prompt', promptArgs(sessionId, text, requestId));
    return requestId;
  }
  async cancelSession(sessionId: string): Promise<void> {
    // 唯一发送session/cancel的入口；仅由用户显式停止按钮调用。
    await this.call('session/cancel', cancelArgs(sessionId));
  }
  disconnect(): void {
    this.epoch += 1; this.connected = false; this.cookie = '';
    this.readyReject?.(new Error('连接已关闭')); this.readyReject = undefined; this.readyResolve = undefined;
    const socket = this.socket; this.socket = undefined; this.followId = ''; this.eventsId = '';
    socket?.close();
  }
  close(): void { this.disconnect(); }
  private id(): string { this.counter += 1; return 'harmony-' + Date.now().toString(36) + '-' + this.counter.toString(36) + '-' + Math.random().toString(36).slice(2); }
  private requireConnection(): void { if (!this.connected || !this.socket) throw new Error('尚未连接 DSH，请重新连接'); }
  private async call(endpoint: string, args: RpcArgs): Promise<RpcValue> {
    this.requireConnection(); const epoch = this.epoch; const id = this.id();
    const response = await this.transport.request(this.base + '/api/' + endpoint, 'POST', rpcRequest(endpoint, id, args), this.cookie);
    if (epoch !== this.epoch) throw new Error('连接已更换，请刷新后重试');
    if (response.status !== 200) {
      if (response.status === 401 || response.status === 403) this.lost('DSH 认证失效或主机信任检查拒绝连接');
      throw new Error('DSH 请求失败，HTTP ' + String(response.status));
    }
    return readRpc(response.body, id);
  }
  private receive(text: string): void {
    try {
      const frame = parseMux(text);
      if (frame.streamId === this.eventsId) {
        if (this.readyResolve) {
          if (frame.type !== 'item' || frame.value?.type !== 'ready' || !frame.value.clientId) throw new Error('DSH ready 握手格式不兼容');
          this.readyResolve(); this.readyResolve = undefined;
        } else if (frame.type !== 'item') this.lost('DSH 主机事件流已结束');
        // 审批与提问暂不答复，避免自动授权。
      } else if (frame.streamId === this.followId) {
        if (frame.type === 'error') throw new Error('DSH 订阅失败：' + (frame.error?.code ?? '未知错误'));
        if (frame.type === 'end') throw new Error('DSH 会话订阅已结束，请重新打开');
        if (!frame.value) throw new Error('DSH 订阅缺少数据');
        this.listener(this.transcript.accept(frame.value));
      }
    } catch (error) { this.lost(error instanceof Error ? error.message : 'DSH 流解析失败'); }
  }
  private lost(message: string): void {
    this.readyReject?.(new Error(message));
    this.disconnect(); this.onDisconnect(message);
  }
}
