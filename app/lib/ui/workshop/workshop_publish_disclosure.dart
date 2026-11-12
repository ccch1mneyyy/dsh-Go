// 首次凭据说明: what leaves the phone when the person submits, shown before
// anything is sent (docs/design/workshop-app.md「投稿与凭据」).
//
// The workshop checks who is submitting by receiving the forum sign-in
// credential (a Discourse User API Key) and asking the forum whose it is. The
// two addresses on screen are the ones in the offer the state layer made; the
// very same offer object goes back with 「同意并继续」, so a consent can never
// land on an address the person did not see.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/workshop_auth_state.dart';
import '../common/list_page_row.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'workshop_publish_text.dart';
import 'workshop_widgets.dart';

class WorkshopPublishDisclosure extends StatelessWidget {
  const WorkshopPublishDisclosure({
    super.key,
    required this.offer,
    required this.onAccept,
    required this.onDecline,
    this.stale = false,
  });

  /// The offer on screen. [onAccept] gets this object back, not a copy.
  final WorkshopDisclosure offer;
  final ValueChanged<WorkshopDisclosure> onAccept;
  final VoidCallback onDecline;

  /// The last 「同意」 was for an offer that had been replaced: say so, and
  /// show the current one.
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final body = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: 48,
                child: GlassSurface(
                  tier: GlassTier.card,
                  circle: true,
                  child: Center(child: Icon(AppIcons.apiKey, size: 22, color: theme.colorScheme.onSurfaceVariant)),
                ),
              ),
              const SizedBox(height: 16),
              Semantics(
                header: true,
                child: Text(l10n.workshopPublishDisclosureTitle, style: theme.textTheme.titleLarge),
              ),
              const SizedBox(height: 8),
              Text(l10n.workshopPublishDisclosureLead, style: body),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (stale)
          WorkshopNote(l10n.workshopPublishDisclosureStale, tone: WorkshopNoteTone.warning),
        ListPageCard(
          children: [
            _Party(label: l10n.workshopPublishDisclosureWorker, host: workshopHostText(offer.worker)),
            _Party(label: l10n.workshopPublishDisclosureForum, host: workshopHostText(offer.forum)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.workshopPublishDisclosureUse, style: body),
              const SizedBox(height: 8),
              Text(
                l10n.workshopPublishDisclosureKept,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.5),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () => onAccept(offer),
                child: Text(l10n.workshopPublishDisclosureAccept),
              ),
              const SizedBox(height: 4),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                onPressed: onDecline,
                child: Text(l10n.workshopPublishDisclosureDecline),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One side of the hand-over: what it does, and its address in full under
/// it (an address is never cut to fit a row's end).
class _Party extends StatelessWidget {
  const _Party({required this.label, required this.host});

  final String label;
  final String host;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 10, ListPageRow.horizontal, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary)),
          const SizedBox(height: 2),
          Text(host, style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.4)),
        ],
      ),
    );
  }
}
