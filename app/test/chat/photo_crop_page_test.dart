import 'dart:typed_data';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/ui/chat/photo_crop_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/harness.dart';

void main() {
  testWidgets('按 ✕ 回来什么都不留', (tester) async {
    usePhoneView(tester);
    final photo = DraftAttachment.sniff(
      'shot.png',
      Uint8List.fromList(img.encodePng(img.Image(width: 16, height: 8))),
    );
    DraftAttachment? result;
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showPhotoCropPage(context, photo: photo, retake: () async => null),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    // 照片在后台解码,这里不等它:取消不需要画面。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(AppIcons.close));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(result, isNull);
    expect(find.byType(PhotoCropPage), findsNothing);
  });
}
