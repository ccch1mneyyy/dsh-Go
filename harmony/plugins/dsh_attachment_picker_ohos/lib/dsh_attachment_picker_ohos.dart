import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

const _channel = MethodChannel('dsh.attachments');

/// 注册后原版 FilePicker 和 ImagePicker 调用无需更改页面。
class DshAttachmentPickerOhos {
  static void registerWith() {
    FilePickerPlatform.instance = DshFilePickerOhos();
    ImagePickerPlatform.instance = DshImagePickerOhos();
  }
}

class DshFilePickerOhos extends FilePickerPlatform {
  Future<List<PlatformFile>> _pick(bool multiple, FileType type, List<String>? extensions) async {
    final items = await _channel.invokeListMethod<Object?>('pickFiles', {
      'multiple': multiple,
      'type': type.name,
      'extensions': extensions ?? <String>[],
    });
    return [
      for (final item in items ?? const [])
        DshPickedFile.fromMap(Map<Object?, Object?>.from(item! as Map)),
    ];
  }

  void _check(String? title, String? directory, int compressionQuality) {
    if (title != null || directory != null || compressionQuality != 0) {
      throw UnsupportedError('鸿蒙附件选择器暂不支持自定义标题、初始目录或文件压缩');
    }
  }

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle, String? initialDirectory, FileType type = FileType.any,
    List<String>? allowedExtensions, Function(FilePickerStatus)? onFileLoading, int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(), DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(), LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) {
    _check(dialogTitle, initialDirectory, compressionQuality);
    return _pick(true, type, allowedExtensions);
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle, String? initialDirectory, FileType type = FileType.any,
    List<String>? allowedExtensions, Function(FilePickerStatus)? onFileLoading, int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(), DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(), LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    _check(dialogTitle, initialDirectory, compressionQuality);
    final files = await _pick(false, type, allowedExtensions);
    return files.isEmpty ? null : files.single;
  }

  @override
  Future<void> clearTemporaryFiles() => _channel.invokeMethod<void>('clearFiles');
}

/// 文件只凭系统选择产生的句柄分段读取，不把私钥等内容预复制到缓存。
final class DshPickedFile extends PlatformFile {
  DshPickedFile(this.id, this.name, this._size);
  factory DshPickedFile.fromMap(Map<Object?, Object?> map) =>
      DshPickedFile(map['id']! as String, map['name']! as String, (map['size'] as num?)?.toInt());
  final String id;
  @override
  final String name;
  final int? _size;
  @override
  Uri get uri => Uri(scheme: 'dsh-picked', host: id);
  @override
  XFile get xFile => _PickedXFile(this);
  @override
  int? lengthSync() => _size;
  @override
  Future<int?> length() => _channel.invokeMethod<int>('fileSize', {'id': id});
  @override
  Future<Uint8List> readAsBytes() async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in readAsByteStream()) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
  @override
  Stream<Uint8List> readAsByteStream() => _stream();

  Stream<Uint8List> _stream([int start = 0, int? end]) async* {
    if (start < 0 || (end != null && end < start)) throw RangeError('无效读取范围');
    var offset = start;
    // 不用选择时的长度终止读取，原业务仍可识别过时或缺失的元数据。
    while (end == null || offset < end) {
      final count = end == null ? 65536 : (end - offset).clamp(0, 65536);
      final chunk = await _channel.invokeMethod<Uint8List>('readFile', {'id': id, 'offset': offset, 'count': count});
      if (chunk == null) throw const FormatException('文件通道缺少读取结果');
      if (chunk.isEmpty) return;
      if (chunk.length > count) throw const FormatException('文件通道读取长度无效');
      offset += chunk.length;
      yield chunk;
    }
  }
}

class _PickedXFile extends XFile {
  _PickedXFile(this.file) : super(file.uri.toString());
  final DshPickedFile file;
  @override
  String get name => file.name;
  @override
  Future<int> length() async => await file.length() ?? (await file.readAsBytes()).length;
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> openRead([int? start, int? end]) => file._stream(start ?? 0, end);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) async => encoding.decode(await readAsBytes());
  @override
  Future<void> saveTo(String path) async {
    final target = File(path).openWrite();
    try {
      await target.addStream(file.readAsByteStream());
    } finally {
      await target.close();
    }
  }
}

class DshImagePickerOhos extends ImagePickerPlatform {
  Future<List<XFile>> _pick(ImageSource source, ImageOptions options, int limit, CameraDevice camera) async {
    final paths = await _channel.invokeListMethod<String>('pickImages', {
      'camera': source == ImageSource.camera,
      'front': camera == CameraDevice.front,
      'limit': limit,
      'maxWidth': options.maxWidth,
      'maxHeight': options.maxHeight,
      'quality': options.imageQuality ?? 100,
      'fullMetadata': options.requestFullMetadata,
    });
    return [for (final path in paths ?? <String>[]) XFile(path)];
  }

  @override
  Future<XFile?> getImageFromSource({required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async {
    final files = await _pick(source, options, 1, options.preferredCameraDevice);
    return files.isEmpty ? null : files.single;
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({MultiImagePickerOptions options = const MultiImagePickerOptions()}) =>
      _pick(ImageSource.gallery, options.imageOptions, options.limit ?? 500, CameraDevice.rear);
}
