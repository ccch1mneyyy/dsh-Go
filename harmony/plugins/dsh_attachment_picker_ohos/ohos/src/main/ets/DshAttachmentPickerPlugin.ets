import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { picker, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { cameraPicker, camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import {
  AbilityAware, AbilityPluginBinding, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';

class PickerFailure extends Error {
  code: string;
  constructor(code: string) {
    super(code);
    this.code = code;
  }
}

export default class DshAttachmentPickerPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | undefined;
  private context: common.UIAbilityContext | undefined;
  private files: Map<string, string> = new Map();
  private nextId: number = 0;
  private busy: boolean = false;

  getUniqueClassName(): string { return 'DshAttachmentPickerPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh.attachments');
    this.channel.setMethodCallHandler(this);
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.context = binding.getAbility().context;
  }

  onDetachedFromAbility(): void { this.context = undefined; }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = undefined;
    this.context = undefined;
    this.files.clear();
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.execute(call, result).catch((error: Error): void => {
      // 不记录 URI、文件名、图片内容或原始异常消息。
      const code = (error as BusinessError).code;
      result.error(error instanceof PickerFailure ? error.code : 'PICKER_ERROR',
        '附件选择或读取失败', typeof code === 'number' ? code : null);
    });
  }

  private number(call: MethodCall, key: string, fallback: number, integer: boolean = false): number {
    const value: number | string | boolean | Object | null | undefined = call.argument(key);
    if (value === null || value === undefined) return fallback;
    if (typeof value !== 'number' || !Number.isFinite(value) || (integer && !Number.isInteger(value))) {
      throw new PickerFailure('INVALID_ARGUMENT');
    }
    return value;
  }

  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    if (call.method === 'clearFiles') {
      this.files.clear();
      result.success(null);
      return;
    }
    if (call.method === 'readFile' || call.method === 'fileSize') {
      const id: Object | null | undefined = call.argument('id');
      if (typeof id !== 'string' || !this.files.has(id)) throw new PickerFailure('INVALID_HANDLE');
      const uri = this.files.get(id) as string;
      if (call.method === 'fileSize') {
        result.success((await fs.stat(uri)).size);
        return;
      }
      const offset = this.number(call, 'offset', 0, true);
      const count = this.number(call, 'count', 65536, true);
      if (offset < 0 || count < 1 || count > 65536) throw new PickerFailure('INVALID_RANGE');
      const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
      try {
        const buffer = new ArrayBuffer(count);
        const length = await fs.read(file.fd, buffer, { offset: offset, length: count });
        result.success(new Uint8Array(buffer, 0, length));
      } finally {
        await fs.close(file);
      }
      return;
    }
    if (call.method !== 'pickFiles' && call.method !== 'pickImages') {
      result.notImplemented();
      return;
    }
    if (this.context === undefined) throw new PickerFailure('NO_FOREGROUND_ABILITY');
    if (this.busy) throw new PickerFailure('ALREADY_ACTIVE');
    const context = this.context;
    this.busy = true;
    try {
      if (call.method === 'pickFiles') result.success(await this.pickFiles(context, call));
      else result.success(await this.pickImages(context, call));
    } finally {
      this.busy = false;
    }
  }

  private async pickFiles(context: common.UIAbilityContext, call: MethodCall): Promise<Map<string, Object | null>[]> {
    const multiple: Object | null | undefined = call.argument('multiple');
    const type: Object | null | undefined = call.argument('type');
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = multiple === true ? 500 : 1;
    if (type !== 'any') {
      if (type !== 'custom') throw new PickerFailure('UNSUPPORTED_FILE_FILTER');
      const extensions = call.argument('extensions') as string[];
      if (!Array.isArray(extensions) || extensions.length === 0 ||
        !extensions.every((extension: string): boolean => typeof extension === 'string' && /^[a-zA-Z0-9]+$/.test(extension))) {
        throw new PickerFailure('INVALID_FILE_FILTER');
      }
      options.fileSuffixFilters = extensions.map((extension: string): string => '.' + extension);
    }
    const selected = await new picker.DocumentViewPicker(context).select(options);
    const result: Map<string, Object | null>[] = [];
    for (const uri of selected) {
      const id = 'f' + (++this.nextId).toString();
      const record = new Map<string, Object | null>();
      this.files.set(id, uri);
      record.set('id', id);
      record.set('name', new fileUri.FileUri(uri).name);
      // 元数据读不到时仍允许业务用实际字节流判断大小，不伪报为零字节。
      let size: number | null = null;
      try { size = (await fs.stat(uri)).size; } catch (_) {}
      record.set('size', size);
      result.push(record);
    }
    return result;
  }

  private async pickImages(context: common.UIAbilityContext, call: MethodCall): Promise<string[]> {
    const limit = this.number(call, 'limit', 1, true);
    const maxWidth = this.number(call, 'maxWidth', Number.MAX_SAFE_INTEGER);
    const maxHeight = this.number(call, 'maxHeight', Number.MAX_SAFE_INTEGER);
    const quality = this.number(call, 'quality', 100, true);
    if (limit < 1 || limit > 500 || maxWidth <= 0 || maxHeight <= 0 || quality < 0 || quality > 100) {
      throw new PickerFailure('INVALID_IMAGE_OPTIONS');
    }
    if (call.argument('fullMetadata') !== false) {
      throw new PickerFailure('FULL_METADATA_UNSUPPORTED');
    }
    const uris: string[] = [];
    if (call.argument('camera') === true) {
      const rawPath = context.cacheDir + '/dsh_camera_' + Date.now().toString() + '_' + (++this.nextId).toString() + '.jpg';
      const raw = await fs.open(rawPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      await fs.close(raw);
      try {
        const captured = await cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], {
          cameraPosition: call.argument('front') === true ? camera.CameraPosition.CAMERA_POSITION_FRONT :
            camera.CameraPosition.CAMERA_POSITION_BACK,
          saveUri: fileUri.getUriFromPath(rawPath)
        });
        if (captured.resultCode === -1 && captured.resultUri.length === 0) return [];
        if (captured.resultCode !== 0 || captured.resultUri.length === 0) throw new PickerFailure('CAMERA_FAILED');
        // 相机输出先写入自己的沙箱，不要求将照片保存至用户图库。
        return [await this.resize(context, captured.resultUri, maxWidth, maxHeight, quality)];
      } finally {
        await fs.unlink(rawPath);
      }
    } else {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = limit;
      const selected = await new photoAccessHelper.PhotoViewPicker().select(options);
      uris.push(...selected.photoUris);
    }
    const output: string[] = [];
    try {
      for (const uri of uris) output.push(await this.resize(context, uri, maxWidth, maxHeight, quality));
      return output;
    } catch (error) {
      for (const path of output) await fs.unlink(path);
      throw error as Error;
    }
  }

  private async resize(context: common.UIAbilityContext, uri: string, maxWidth: number,
    maxHeight: number, quality: number): Promise<string> {
    const input = await fs.open(uri, fs.OpenMode.READ_ONLY);
    let source: image.ImageSource | undefined;
    let pixels: image.PixelMap | undefined;
    let packer: image.ImagePacker | undefined;
    let output: fs.File | undefined;
    let outputPath: string | undefined;
    let succeeded = false;
    try {
      source = image.createImageSource(input.fd);
      const info = await source.getImageInfo();
      let orientation = 1;
      try { orientation = Number.parseInt(await source.getImageProperty(image.PropertyKey.ORIENTATION), 10) || 1; } catch (_) {}
      const turned = orientation >= 5 && orientation <= 8;
      const width = turned ? info.size.height : info.size.width;
      const height = turned ? info.size.width : info.size.height;
      const scale = Math.min(1, maxWidth / width, maxHeight / height);
      pixels = await source.createPixelMap({ desiredSize: {
        width: Math.max(1, Math.floor(info.size.width * scale)),
        height: Math.max(1, Math.floor(info.size.height * scale))
      } });
      if (orientation === 3) await pixels.rotate(180);
      if (orientation >= 5 && orientation <= 7) await pixels.rotate(90);
      if (orientation === 8) await pixels.rotate(270);
      if (orientation === 2 || orientation === 5) await pixels.flip(true, false);
      if (orientation === 4 || orientation === 7) await pixels.flip(false, true);
      const png = info.mimeType === 'image/png';
      outputPath = context.cacheDir + '/dsh_image_' + Date.now().toString() + '_' + (++this.nextId).toString() + (png ? '.png' : '.jpg');
      output = await fs.open(outputPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      packer = image.createImagePacker();
      // 从像素重新打包且不复制 EXIF，避免把位置元数据带入附件。
      await packer.packToFile(pixels, output.fd, { format: png ? 'image/png' : 'image/jpeg', quality: quality,
        needsPackProperties: false });
      succeeded = true;
      return outputPath;
    } finally {
      if (output !== undefined) await fs.close(output);
      if (packer !== undefined) await packer.release();
      if (pixels !== undefined) await pixels.release();
      if (source !== undefined) await source.release();
      await fs.close(input);
      if (!succeeded && outputPath !== undefined) await fs.unlink(outputPath);
    }
  }
}
