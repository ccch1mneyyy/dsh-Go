import 'package:dsh_attachment_picker_ohos/dsh_attachment_picker_ohos.dart';
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh.attachments');
  final calls = <MethodCall>[];
  final data = Uint8List.fromList(List.generate(70000, (index) => index % 251));
  var cancelled = false;
  String? failure;

  setUp(() {
    DshAttachmentPickerOhos.registerWith();
    calls.clear();
    cancelled = false;
    failure = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (failure != null) throw PlatformException(code: failure!);
      final args = (call.arguments as Map?) ?? {};
      switch (call.method) {
        case 'pickFiles':
          return cancelled ? [] : [{'id': 'f1', 'name': '虚构夹具.txt', 'size': 1}];
        case 'pickImages':
          return cancelled ? [] : ['/仅虚构路径/fixture.jpg'];
        case 'readFile':
          final offset = args['offset'] as int;
          final count = args['count'] as int;
          return Uint8List.sublistView(data, offset.clamp(0, data.length), (offset + count).clamp(0, data.length));
        case 'fileSize': return data.length;
        case 'clearFiles': return null;
      }
      throw MissingPluginException();
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('注册现代平台接口且不替换原业务页面', () {
    expect(FilePickerPlatform.instance, isA<DshFilePickerOhos>());
    expect(ImagePickerPlatform.instance, isA<DshImagePickerOhos>());
  });

  test('原版多图参数完整传到原生，不读取虚构路径', () async {
    final result = await ImagePickerPlatform.instance.getMultiImageWithOptions(options: const MultiImagePickerOptions(
      imageOptions: ImageOptions(maxWidth: 2560, maxHeight: 2560, imageQuality: 88, requestFullMetadata: false), limit: 9,
    ));
    expect(result.single.path, '/仅虚构路径/fixture.jpg');
    expect(calls.single.arguments, {
      'camera': false, 'front': false, 'limit': 9, 'maxWidth': 2560.0, 'maxHeight': 2560.0,
      'quality': 88, 'fullMetadata': false,
    });
  });

  test('相机与论坛单图参数保留来源和压缩设置', () async {
    await ImagePickerPlatform.instance.getImageFromSource(source: ImageSource.camera,
      options: const ImagePickerOptions(maxWidth: 2048, maxHeight: 2048, imageQuality: 85,
        requestFullMetadata: false, preferredCameraDevice: CameraDevice.front));
    expect((calls.single.arguments as Map)['camera'], true);
    expect((calls.single.arguments as Map)['front'], true);
    expect((calls.single.arguments as Map)['quality'], 85);
  });

  test('用户取消映射为空列表或null，原生错误继续抛出', () async {
    cancelled = true;
    expect(await FilePickerPlatform.instance.pickFiles(), isEmpty);
    expect(await FilePickerPlatform.instance.pickFile(), isNull);
    expect(await ImagePickerPlatform.instance.getImageFromSource(source: ImageSource.gallery,
      options: const ImagePickerOptions(requestFullMetadata: false)), isNull);
    failure = 'PICKER_ERROR';
    await expectLater(FilePickerPlatform.instance.pickFiles(), throwsA(isA<PlatformException>()));
  });

  test('分段读不信任过时长度，保持字节且不提前截断', () async {
    final file = (await FilePickerPlatform.instance.pickFiles()).single;
    expect(file.name, '虚构夹具.txt');
    expect(file.lengthSync(), 1);
    expect(await file.length(), 70000);
    expect(await file.readAsBytes(), orderedEquals(data));
    final reads = calls.where((call) => call.method == 'readFile').toList();
    expect(reads.length, 3);
    expect((reads[1].arguments as Map)['offset'], 65536);
    expect(reads.every((call) => (call.arguments as Map)['count'] == 65536), true);
  });

  test('取消字节流后不再请求后续块，原业务大小预算可生效', () async {
    final file = (await FilePickerPlatform.instance.pickFile())!;
    expect((await file.readAsByteStream().first).length, 65536);
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((call) => call.method == 'readFile').length, 1);
  });

  test('XFile适配支持有限范围和内容读取，不将URI当沙箱文件路径', () async {
    final file = (await FilePickerPlatform.instance.pickFile())!;
    expect(file.path, isNull);
    expect(file.xFile.name, '虚构夹具.txt');
    expect(await file.xFile.openRead(10, 20).first, orderedEquals(data.sublist(10, 20)));
    expect(await file.xFile.length(), data.length);
  });

  test('未知高级文件选项显式失败，不冒充已支持', () async {
    expect(() => FilePickerPlatform.instance.pickFiles(initialDirectory: '/虚构路径'), throwsUnsupportedError);
    expect(calls, isEmpty);
  });
}
