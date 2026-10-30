// 原生鸿蒙适配入口，协议/状态实现可独立在Node上测试。
import { ClientCore } from './ClientCore';
import { HarmonyTransport } from './HarmonyTransport';

export class DshClient extends ClientCore {
  constructor() { super(new HarmonyTransport()); }
}
