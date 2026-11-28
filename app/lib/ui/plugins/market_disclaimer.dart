import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/l10n.dart';
import '../common/app_dialog.dart';

const marketDisclaimerAcceptedKey = 'plugin_market_disclaimer_accepted_v1';

final marketDisclaimerProvider = AsyncNotifierProvider<MarketDisclaimer, bool>(MarketDisclaimer.new);

class MarketDisclaimer extends AsyncNotifier<bool> {
  Future<bool>? _pending;
  SharedPreferences? _prefs;

  @override
  Future<bool> build() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      return _prefs?.getBool(marketDisclaimerAcceptedKey) == true;
    } on Exception {
      debugPrint('Could not load the plugin market disclaimer preference.');
      return false;
    }
  }

  Future<bool> confirm(BuildContext context) => _pending ??= _confirm(context).whenComplete(() => _pending = null);

  Future<bool> _confirm(BuildContext context) async {
    final alreadyAccepted = await future;
    if (!context.mounted) return false;
    if (alreadyAccepted) return true;

    final accepted = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) {
        final l10n = dialog.l10n;
        return AlertDialog(
          scrollable: true,
          title: Text(l10n.marketDisclaimerTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.marketDisclaimerBody),
              const SizedBox(height: 16),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: 8,
                children: [
                  TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.marketDisclaimerLeave)),
                  FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.marketDisclaimerAccept)),
                ],
              ),
            ],
          ),
        );
      },
    );
    if (accepted != true) return false;
    // A storage failure may require acknowledgement again, but does not invalidate this one.
    final prefs = _prefs;
    try {
      if (prefs != null && !await prefs.setBool(marketDisclaimerAcceptedKey, true)) {
        debugPrint('Could not save the plugin market disclaimer acknowledgement.');
      }
    } on Exception {
      debugPrint('Could not save the plugin market disclaimer acknowledgement.');
    }
    if (ref.mounted) state = const AsyncData(true);
    return true;
  }
}
