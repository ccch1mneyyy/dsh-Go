import 'dart:typed_data';

import 'package:codex_client/host_files.dart';

class FakeFiles implements CodexHostFiles {
  final data = <String, Uint8List>{};
  final reads = <({String path, int offset, int length})>[];
  Map<String, dynamic> result = {};
  Map<String, dynamic>? inspection;
  @override
  Future<Map<String, dynamic>> stat(String path) async => {
    'absolutePath': path,
    'version': '1',
    'bytes': data[path]!.length,
  };
  @override
  Future<Uint8List> read(String path, int offset, int length) async {
    reads.add((path: path, offset: offset, length: length));
    final bytes = data[path]!;
    return Uint8List.sublistView(
      bytes,
      offset,
      (offset + length).clamp(0, bytes.length),
    );
  }

  @override
  Future<String> upload(String name, Uint8List bytes) async {
    final path = '/home/me/.dsh-go-uploads/${data.length}/$name';
    data[path] = bytes;
    return path;
  }

  @override
  Future<Map<String, dynamic>> inspect(Map<String, dynamic> request) async {
    inspection = request;
    return result;
  }
}
