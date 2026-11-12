// 「已安装」: placeholder until the tab is written.

import 'package:flutter/material.dart';

class WorkshopInstalledSliver extends StatelessWidget {
  const WorkshopInstalledSliver({super.key, this.onBrowse});

  final VoidCallback? onBrowse;

  @override
  Widget build(BuildContext context) => const SliverToBoxAdapter(child: SizedBox.shrink());
}
