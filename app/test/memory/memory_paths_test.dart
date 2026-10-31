import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/ui/memory/memory_paths.dart';

void main() {
  group('memoryEntryPath', () {
    test('joins a normal manifest entry under a unix root', () {
      expect(
        memoryEntryPath('/sdcard/DSH-mesh/', 'memory/facts/a.md'),
        '/sdcard/DSH-mesh/memory/facts/a.md',
      );
    });

    test('joins under a windows root', () {
      expect(
        memoryEntryPath(r'C:\Users\me\DSH-mesh', r'AGENTS.shared.md'),
        'C:/Users/me/DSH-mesh/AGENTS.shared.md',
      );
    });

    test('rejects traversal and absolute entries', () {
      expect(memoryEntryPath('/sdcard/DSH-mesh', '../secret'), isNull);
      expect(memoryEntryPath('/sdcard/DSH-mesh', 'memory/../../secret'), isNull);
      expect(memoryEntryPath('/sdcard/DSH-mesh', '/etc/passwd'), isNull);
      expect(memoryEntryPath('/sdcard/DSH-mesh', r'C:\Windows\win.ini'), isNull);
      expect(memoryEntryPath('/sdcard/DSH-mesh', 'memory//x.md'), isNull);
      expect(memoryEntryPath('/sdcard/DSH-mesh', './x.md'), isNull);
      expect(memoryEntryPath('/sdcard/DSH-mesh', ''), isNull);
    });

    test('rejects roots that are relative or contain traversal', () {
      expect(memoryEntryPath('DSH-mesh', 'a.md'), isNull);
      expect(memoryEntryPath('/sdcard/../etc', 'passwd'), isNull);
      expect(memoryEntryPath('/', 'a.md'), isNull);
      expect(memoryEntryPath('', 'a.md'), isNull);
    });
  });
}
