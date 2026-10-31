import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_overlay_bridge.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/pets/pet_stage.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show FakeChatController;
import 'support.dart';

class _NoCompaction extends PetCompactingController {
  _NoCompaction(super.sessionId);

  @override
  bool build() => false;
}

void main() {
  testWidgets('reports completion without another Flutter frame in the background', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final chat = FakeChatController('a', const ChatState(loading: false, running: true));
    await tester.pumpWidget(
      testApp(
        const PetStage(sessionId: 'a', child: SizedBox.expand()),
        overrides: [
          ...petOverrides(pack: deepy, clock: TestClock()),
          petOverlayBridgeProvider.overrideWith((ref) {}),
          chatProvider.overrideWith2((_) => chat),
          petCompactingProvider.overrideWith2(_NoCompaction.new),
        ],
      ),
    );
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(PetStage)));
    expect(container.read(petFocusProvider)?.running, isTrue);

    // Android stops drawing Flutter frames while another app is in front.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    chat.emit(const ChatState(loading: false));
    await tester.idle();
    await tester.idle();
    expect(container.read(petFocusProvider)?.activity, PetActivity.none);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
