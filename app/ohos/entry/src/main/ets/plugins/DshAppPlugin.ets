import { i18n } from '@kit.LocalizationKit';
import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';

// 原调度页面读取系统 IANA 时区；其他应用操作保留未实现状态。
export default class DshAppPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;

  getUniqueClassName(): string {
    return 'DshAppPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/app');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'getTimeZoneId') {
      result.notImplemented();
      return;
    }
    try {
      result.success(i18n.getTimeZone().getID());
    } catch (_) {
      result.error('UNAVAILABLE', '无法读取系统时区', null);
    }
  }
}
