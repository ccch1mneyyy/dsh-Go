import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('解析运行时工作目录并保留路径中的空格', () {
    const directory = '/data/test-private-runtime/home/my workspace';
    final status = RuntimeStatus.fromMap({'phase': 'running', 'workspaceDir': directory});
    expect(status.workspaceDir, directory);
  });

  test('旧运行时缺失字段仍未知，不猜测物理目录', () {
    expect(RuntimeStatus.fromMap({'phase': 'running'}).workspaceDir, isNull);
    expect(const RuntimeStatus(phase: RuntimePhase.running).workspaceDir, isNull);
  });

  test('空白及错误类型字段不作为有效工作目录', () {
    for (final value in [null, '', ' \t\n', 123, false, <String>[]]) {
      expect(RuntimeStatus.fromMap({'phase': 'running', 'workspaceDir': value}).workspaceDir, isNull);
    }
  });
}
