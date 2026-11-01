import util from '@ohos.util';
import nativeBroker from 'libdsh_broker.so';
import { ParentBroker, Codec, TaskDriver, SpawnSpec } from './broker/parent-broker.js';

class HarmonyBrokerCodec implements Codec {
  encodeText(text: string): Uint8Array { return new util.TextEncoder().encodeInto(text); }
  decodeText(data: Uint8Array): string { return new util.TextDecoder('utf-8', { fatal: true }).decodeToString(data); }
  base64(data: Uint8Array): string { return new util.Base64Helper().encodeToStringSync(data); }
  unbase64(text: string): Uint8Array {
    const data = new util.Base64Helper().decodeSync(text);
    if (this.base64(data) !== text) throw new Error('BROKER_BASE64_INVALID');
    return data;
  }
}

// 主引擎拥有连接和代号；仅在子端完成传递后由宿主显式 start。
export class HarmonyBrokerHost {
  private handle: number;
  private core: ParentBroker;
  private timer: number = -1;
  private stopping: boolean = false;
  private closing: Promise<void> | undefined = undefined;
  constructor(handle: number, generation: string, driver: TaskDriver, allowSpec: (spec: SpawnSpec) => boolean) {
    this.handle = handle;
    this.core = new ParentBroker(generation, driver, (data: Uint8Array): number => {
      // 原生单次发送上限64KiB；核心保留剩余帧并按短写继续。
      return nativeBroker.write(this.handle, data.slice(0, 65536));
    }, allowSpec, new HarmonyBrokerCodec());
  }
  start(): void {
    if (this.timer >= 0 || this.stopping) throw new Error('BROKER_ALREADY_STARTED');
    this.timer = setInterval(() => this.tick(), 10);
  }
  private tick(): void {
    if (this.stopping) return;
    try {
      // 每轮有界读取，避免连续输入独占ArkTS主线程。
      for (let count = 0; count < 4; count++) {
        const read = nativeBroker.read(this.handle);
        if (read.error !== 0) throw new Error('BROKER_READ_FAILED');
        if (read.bytes.length > 0) this.core.accept(read.bytes);
        if (read.eof === 1) { this.beginShutdown('BROKER_PEER_CLOSED'); return; }
        if (read.bytes.length === 0 || this.core.failure !== null) break;
      }
      this.core.pump();
      if (this.core.failure !== null) this.beginShutdown('BROKER_CORE_FAILED');
    } catch (_) { this.beginShutdown('BROKER_TRANSPORT_FAILED'); }
  }
  private beginShutdown(code: string): void {
    // 保留失败Promise供宿主await，不因后台定时器造成未处理拒绝。
    this.shutdown(code).catch(() => {});
  }
  shutdown(code: string = 'BROKER_HOST_STOPPED'): Promise<void> {
    if (this.closing !== undefined) return this.closing;
    this.stopping = true;
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    this.core.disconnect(code);
    this.closing = this.finishShutdown();
    return this.closing;
  }
  private async finishShutdown(): Promise<void> {
    // 任意原生任务尚未确认回收时拒绝，宿主必须保留该对象处理失败。
    await this.core.settled();
    if (nativeBroker.close(this.handle) !== 0) throw new Error('BROKER_CLOSE_FAILED');
  }
}
