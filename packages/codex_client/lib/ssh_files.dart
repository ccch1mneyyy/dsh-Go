import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'host_files.dart';

class SshCodexFiles implements CodexHostFiles {
  SshCodexFiles(this.ssh);
  final SSHClient ssh;
  Future<SftpClient>? _sftp;
  Future<SftpClient> get sftp => _sftp ??= ssh.sftp();
  @override
  Future<Map<String, dynamic>> stat(String path) async {
    final s = await sftp;
    final real = await s.absolute(path);
    final a = await s.stat(real);
    if (!a.isFile) throw StateError('不是普通文件');
    return {
      'absolutePath': real,
      'bytes': a.size,
      'version': '$real:${a.modifyTime}:${a.size}',
    };
  }

  @override
  Future<Uint8List> read(String path, int offset, int length) async {
    if (offset < 0 || length < 0 || length > 2 * 1024 * 1024)
      throw ArgumentError('无效读取范围');
    final f = await (await sftp).open(path);
    try {
      return await f.readBytes(offset: offset, length: length);
    } finally {
      await f.close();
    }
  }

  @override
  Future<String> upload(String name, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 30 * 1024 * 1024)
      throw ArgumentError('附件大小超限');
    final s = await sftp;
    final home = await s.absolute('.');
    final root = '$home/.dsh-go-uploads';
    try {
      await s.mkdir(root, SftpFileAttrs(mode: SftpFileMode.value(448)));
    } on SftpStatusError {
      if (!(await s.stat(root)).isDirectory) rethrow;
    }
    final nonce = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final dir = '$root/$nonce';
    await s.mkdir(dir, SftpFileAttrs(mode: SftpFileMode.value(448)));
    final safe = name.replaceAll(RegExp(r'[\x00-\x1f/\\<>\[\]]'), '_');
    final path =
        '$dir/${safe.isEmpty || safe == '.' || safe == '..' ? 'file' : safe}';
    final f = await s.open(
      path,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.exclusive,
    );
    try {
      await s.setStat(path, SftpFileAttrs(mode: SftpFileMode.value(384)));
      await f.writeBytes(bytes);
    } catch (_) {
      await f.close();
      await s.remove(path);
      rethrow;
    }
    await f.close();
    return path;
  }

  @override
  Future<Map<String, dynamic>> inspect(Map<String, dynamic> request) async {
    final quoted = "'${rolloutInspector.replaceAll("'", "'\\''")}'";
    final channel = await ssh.execute('python3 -c $quoted');
    final err = channel.stderr.listen((_) {});
    final bytes = BytesBuilder(copy: false);
    try {
      channel.stdin.add(Uint8List.fromList(utf8.encode(jsonEncode(request))));
      await channel.stdin.close();
      await (() async {
        await for (final chunk in channel.stdout) {
          if (bytes.length + chunk.length > 2 * 1024 * 1024)
            throw StateError('搜索结果过大');
          bytes.add(chunk);
        }
      })().timeout(const Duration(seconds: 12));
      await channel.done;
      if (channel.exitCode != 0) throw StateError('无法读取历史，请确认服务器有 Python 3');
      return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(bytes.takeBytes())) as Map,
      );
    } finally {
      channel.close();
      await err.cancel();
    }
  }
}
