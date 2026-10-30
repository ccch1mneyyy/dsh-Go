// 沿用本仓库 AGPL-3.0 许可。令牌和Cookie只在内存中传递，不写日志。
import { rcp } from '@kit.RemoteCommunicationKit';
import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Transport, HttpReply, SocketPort } from './ClientCore';

class HarmonySocket implements SocketPort {
  private socket: webSocket.WebSocket;
  private stopped: boolean = false;
  constructor(socket: webSocket.WebSocket) { this.socket = socket; }
  async send(text: string): Promise<void> {
    if (this.stopped) throw new Error('WebSocket 已关闭');
    try {
      const sent = await this.socket.send(text);
      if (!sent) throw new Error('发送失败');
    } catch (_error) { throw new Error('WebSocket 发送失败，请重新连接'); }
  }
  close(): void {
    if (this.stopped) return;
    this.stopped = true;
    this.socket.off('open'); this.socket.off('message'); this.socket.off('error'); this.socket.off('close');
    this.socket.close().catch((_error: BusinessError) => {});
  }
}

export class HarmonyTransport implements Transport {
  async request(url: string, method: string, body: string, cookie: string): Promise<HttpReply> {
    // RCP在API11起支持禁止自动跳转，登录需读取原始303的Set-Cookie。
    const session = rcp.createSession({ requestConfiguration: { transfer: {
      autoRedirect: false, timeout: { connectMs: 10000, transferMs: 30000 }
    } } });
    try {
      const headers: rcp.RequestHeaders = { 'content-type': 'application/json', 'cookie': cookie };
      const request = new rcp.Request(url, method === 'GET' ? 'GET' : 'POST', headers,
        method === 'GET' ? undefined : body);
      const response = await session.fetch(request);
      const setCookie = response.headers['set-cookie'];
      let cookies = '';
      if (typeof setCookie === 'string') cookies = setCookie;
      else if (setCookie) cookies = setCookie.join('\n');
      return { status: response.statusCode, body: response.toString() ?? '', cookies: cookies };
    } catch (error) {
      // 平台错误message可能包含完整登录URL，界面只传递错误码。
      const failure = error as BusinessError;
      throw new Error('网络请求失败，平台错误码 ' + String(failure.code ?? 0));
    } finally { session.close(); }
  }

  async open(url: string, cookie: string, onMessage: (text: string) => void,
    onLost: (message: string) => void): Promise<SocketPort> {
    const socket = webSocket.createWebSocket();
    const port = new HarmonySocket(socket);
    socket.on('message', (error: BusinessError, value: string | ArrayBuffer) => {
      if (error) { onLost('WebSocket 接收错误，平台错误码 ' + String(error.code)); return; }
      if (typeof value !== 'string') { onLost('DSH 返回不支持的二进制流'); return; }
      onMessage(value);
    });
    socket.on('error', (error: BusinessError) => { onLost('WebSocket 错误，平台错误码 ' + String(error.code)); });
    socket.on('close', (_error: BusinessError, value: webSocket.CloseResult) => {
      onLost('WebSocket 已断开，关闭码 ' + String(value.code));
    });
    let timer: number = -1;
    try {
      await new Promise<void>((resolve, reject) => {
        timer = setTimeout(() => { port.close(); reject(new Error('WebSocket 连接超时')); }, 15000);
        // connect返回仅表示请求已受理；必须等open事件后才能发送首帧。
        socket.on('open', (error: BusinessError) => {
          if (error && error.code) reject(new Error('WebSocket 握手失败，平台错误码 ' + String(error.code)));
          else resolve();
        });
        socket.connect(url, { header: { Cookie: cookie }, supportOriginPort: true }).then((connected: boolean) => {
          if (!connected) reject(new Error('WebSocket 连接被拒绝'));
        }).catch((error: BusinessError) => { reject(new Error('WebSocket 连接失败，平台错误码 ' + String(error.code))); });
      });
      return port;
    } catch (error) { port.close(); throw error as Error; }
    finally { clearTimeout(timer); }
  }
}
