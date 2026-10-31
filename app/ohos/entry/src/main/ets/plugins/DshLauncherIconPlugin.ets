import bundleManager from '@ohos.bundle.bundleManager';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';

// 通过API26真实查询和切换备用图标，不把界面预览当作桌面已更新。
export default class DshLauncherIconPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;

  getUniqueClassName(): string {
    return 'DshLauncherIconPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/launcher_icon');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.execute(call, result).catch((error: BusinessError) => {
      result.error('failed', null, typeof error.code === 'number' ? error.code : null);
    });
  }

  private async current(): Promise<string> {
    const icons = await bundleManager.getAlternateIcons();
    const enabled = icons.filter((icon: bundleManager.AlternateIconInfo) => icon.enabled);
    if (enabled.length === 0) return 'mist';
    if (enabled.length !== 1 || !['night', 'frost', 'ink'].includes(enabled[0].iconName)) {
      throw new Error('备用图标状态与应用配置不符。');
    }
    return enabled[0].iconName;
  }

  private state(current: string): Map<string, Object | null> {
    const state = new Map<string, Object | null>();
    state.set('current', current);
    // 桌面遮罩形状没有在此接口提供，保持原Dart契约的未知状态。
    state.set('mask', null);
    return state;
  }

  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    if (call.method === 'state') {
      result.success(this.state(await this.current()));
      return;
    }
    if (call.method !== 'set') {
      result.notImplemented();
      return;
    }
    const id: string | number | boolean | Object | null | undefined = call.argument('id');
    if (typeof id !== 'string' || !['mist', 'night', 'frost', 'ink'].includes(id)) {
      result.error('unknown', null, null);
      return;
    }
    if (await this.current() !== id) {
      // 空名称撤销备用图标；已是默认时不重复调用，避免17700309。
      await bundleManager.setAlternateIcon(id === 'mist' ? '' : id);
    }
    const current = await this.current();
    if (current !== id) {
      result.error('failed', null, null);
      return;
    }
    result.success(this.state(current));
  }
}
