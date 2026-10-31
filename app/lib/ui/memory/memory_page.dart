import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/render/markdown_body.dart';
import '../../state/connection_state.dart';
import '../../ui_config/ui_config_source.dart';

/// A read-only native view of the shared dsh-mesh memory directory.
///
/// The host writes a small manifest to `$DSH_HOME/dsh-go/dsh-mesh.json`;
/// this page reads that manifest and individual Markdown files through
/// `workspaceFiles/read`, so it works for local and DSH Remote hosts without
/// the dsh-go bridge.
class MemoryPage extends ConsumerStatefulWidget {
  const MemoryPage({super.key, this.sessionId});

  final String? sessionId;

  @override
  ConsumerState<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryFile {
  const _MemoryFile({required this.path, required this.title, required this.kind, required this.size});

  final String path;
  final String title;
  final String kind;
  final int size;

  factory _MemoryFile.fromJson(Map<String, dynamic> json) => _MemoryFile(
    path: '${json['path'] ?? ''}',
    title: '${json['title'] ?? json['path'] ?? ''}',
    kind: '${json['kind'] ?? ''}',
    size: (json['size'] as num?)?.toInt() ?? 0,
  );
}

class _MemoryManifest {
  const _MemoryManifest({required this.root, required this.device, required this.files});

  final String root;
  final String device;
  final List<_MemoryFile> files;
}

class _MemoryPageState extends ConsumerState<MemoryPage> {
  bool _loading = true;
  String? _error;
  _MemoryManifest? _manifest;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final conn = ref.read(activeConnectionProvider).value;
      final client = conn?.client;
      if (client == null) throw StateError('没有连接到主机');
      final host = DshUiRemoteHost(client);
      if (!host.supports('workspaceFiles/read')) {
        throw StateError('当前主机不支持 workspaceFiles/read');
      }
      final session = widget.sessionId ?? await host.recentSessionId();
      if (session == null) throw StateError('没有可用于读取记忆的会话');
      var home = host.userHome;
      if (home == null || home.isEmpty) {
        final skill = await host.skillFile(session);
        home = dshHomeFromSkillPath(skill ?? '');
      }
      if (home == null || home.isEmpty) throw StateError('无法确定主机 DSH_HOME');
      final path = '${home.replaceFirst(RegExp(r'/+$'), '')}/.dsh/dsh-go/dsh-mesh.json';
      final res = await host.read(session, path);
      final map = jsonDecode(res.text) as Map<String, dynamic>;
      final files = [
        for (final item in (map['files'] as List? ?? const []))
          if (item is Map<String, dynamic>) _MemoryFile.fromJson(item),
      ];
      if (!mounted) return;
      setState(() {
        _manifest = _MemoryManifest(root: '${map['root'] ?? ''}', device: '${map['device'] ?? ''}', files: files);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _open(_MemoryFile file) async {
    final conn = ref.read(activeConnectionProvider).value;
    final client = conn?.client;
    final manifest = _manifest;
    if (client == null || manifest == null) return;
    final host = DshUiRemoteHost(client);
    final session = widget.sessionId ?? await host.recentSessionId();
    if (session == null) return;
    try {
      final path = '${manifest.root.replaceFirst(RegExp(r'/+$'), '')}/${file.path}';
      var page = await host.read(session, path);
      final text = StringBuffer(page.text);
      var pages = 1;
      while (!page.eof && pages < 32) {
        page = await host.read(session, path, offset: page.offset + page.lines);
        text
          ..write('\n')
          ..write(page.text);
        pages++;
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _MemoryFilePage(file: file, text: text.toString()),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('读取失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('记忆'),
        actions: [IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh), tooltip: '刷新')],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('还读不到共享记忆', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final manifest = _manifest;
    if (manifest == null || manifest.files.isEmpty) {
      return const Center(child: Text('共享记忆目录还是空的。'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: manifest.files.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final file = manifest.files[index];
          return ListTile(
            dense: true,
            leading: Icon(_iconFor(file.kind)),
            title: Text(file.title),
            subtitle: Text(file.path, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(file),
          );
        },
      ),
    );
  }

  IconData _iconFor(String kind) {
    switch (kind) {
      case 'AGENTS.shared.md':
      case 'memory':
      case 'sessions':
      case 'skills':
        return Icons.folder_outlined;
      default:
        return Icons.description_outlined;
    }
  }
}

class _MemoryFilePage extends StatelessWidget {
  const _MemoryFilePage({required this.file, required this.text});

  final _MemoryFile file;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(file.title, overflow: TextOverflow.ellipsis)),
      body: SelectionArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(file.path, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              MarkdownBody(text: text),
            ],
          ),
        ),
      ),
    );
  }
}
