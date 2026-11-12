// 「我的投稿」: placeholder until the tab is written.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reads the person's submissions again (pull to refresh on the 我的投稿 tab).
Future<void> refreshWorkshopMine(WidgetRef ref) async {}

class WorkshopMineSliver extends StatelessWidget {
  const WorkshopMineSliver({super.key});

  @override
  Widget build(BuildContext context) => const SliverToBoxAdapter(child: SizedBox.shrink());
}
