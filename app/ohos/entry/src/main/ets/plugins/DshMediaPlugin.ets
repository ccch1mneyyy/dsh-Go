import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';

// 沿用原保存图片入口；仅通过系统单次保存弹窗取得目标图库URI。
export default class DshMediaPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private saving: boolean = false;

  getUniqueClassName(): string { return 'DshMediaPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/media');
    this.channel.setMethodCallHandler(this);
  }
  onDetachedFromEngine(_binding: FlutterPluginBinding): void { this.channel?.setMethodCallHandler(null); this.channel = null; }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.execute(call, result).catch(() => result.error('failed', '图片未保存到图库', null));
  }

  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    if (!['saveImage', 'openSettings'].includes(call.method)) { result.notImplemented(); return; }
    const context = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
    if (!context) throw new Error('应用界面不可用');
    if (call.method === 'openSettings') {
      await context.startAbility({ bundleName: 'com.huawei.hmos.settings', abilityName: 'com.huawei.hmos.settings.MainAbility',
        parameters: { 'settingsParam': 'application_info', 'bundleName': context.abilityInfo.bundleName } });
      result.success(true); return;
    }
    const bytes: Object | null | undefined = call.argument('bytes');
    const mime: string | number | boolean | Object | null | undefined = call.argument('mime');
    const name: string | number | boolean | Object | null | undefined = call.argument('name');
    if (!(bytes instanceof Uint8Array) || bytes.length === 0 || typeof mime !== 'string' ||
      !['image/png', 'image/jpeg', 'image/gif', 'image/webp'].includes(mime)) {
      result.error('invalid', '没有可保存的图片', null); return;
    }
    if (this.saving) { result.error('busy', '请先完成当前保存操作', null); return; }
    this.saving = true;
    const extension = mime === 'image/jpeg' ? 'jpg' : mime.substring(6);
    const base = typeof name === 'string' ? name.replace(/\.[^.]*$/, '').replace(/[\x00-\x1f\\/:*?"'`<>|{}\[\]]/g, '_').substring(0, 80).trim() : '';
    const title = base && !base.startsWith('.') ? base : 'DSH_' + Date.now();
    let directory: string | null = null;
    let source: string | null = null;
    let helper: photoAccessHelper.PhotoAccessHelper | null = null;
    let saved: string | null = null;
    try {
      directory = await fs.mkdtemp(context.cacheDir + '/dsh-gallery-');
      source = directory + '/image.' + extension;
      const temporary = await fs.open(source, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      try {
        const written = await fs.write(temporary.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
        if (written !== bytes.length) throw new Error('图片临时写入不完整');
      } finally { await fs.close(temporary.fd); }
      helper = photoAccessHelper.getPhotoAccessHelper(context);
      const targets = await helper.showAssetsCreationDialog([fileUri.getUriFromPath(source)],
        [{ title, fileNameExtension: extension, photoType: photoAccessHelper.PhotoType.IMAGE }]);
      if (targets.length > 0) {
        if (targets.length !== 1 || !targets[0].startsWith('file://media/')) throw new Error('图库没有返回可写目标');
        const input = await fs.open(source, fs.OpenMode.READ_ONLY);
        try {
          const output = await fs.open(targets[0], fs.OpenMode.WRITE_ONLY);
          try {
            await fs.copyFile(input.fd, output.fd);
            if (fs.statSync(output.fd).size !== bytes.length) throw new Error('图库图片写入不完整');
          } finally { await fs.close(output.fd); }
        } finally { await fs.close(input.fd); }
        saved = targets[0];
      }
    } finally {
      try { if (source !== null && fs.accessSync(source)) fs.unlinkSync(source); } catch (_) {}
      try { if (directory !== null) fs.rmdirSync(directory); } catch (_) {}
      try { if (helper) await helper.release(); } catch (_) {}
      this.saving = false;
    }
    if (saved === null) result.error('permission', '你取消了图库保存授权', null); else result.success(saved);
  }
}
