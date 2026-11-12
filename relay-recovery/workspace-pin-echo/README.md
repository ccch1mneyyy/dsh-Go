# NOT TESTED / NOT READY — workspace pin echo recovery

This is an internal recovery branch after the execution environment became unavailable. Do not open or merge it as a completed product PR. The original hard cutoff remains 2026-11-12T03:03:00Z.

Base: ec32775a412ffb126594fcfabd160df158f199d6 (tree 484f5a21fe3e71f388ff35a95e44be00ba8cc65b). ADDENDUM 47 was read again before this recovery commit. Local uncommitted branch had been codex/relay2-workspace-pin-echo in wt-workspace-pins.

## What is actually proven

- The old product ran all four new tests: 1 pass / 3 fail, exit 1 at 02:20:17 UTC. A late unpin erased a newer pushed set; reversed pin replies and a late reply after full replace overwrote newer sets. Unrelated workspace/archive frames retained valid unary behavior.
- These are public-provider tests using the real DshClient through a controlled FakeWorkspaceHost carrier. They are not real HTTP/WebSocket or real Host executions.
- The final test text was recovered from retained conversation/tool text. Its SHA256 is exactly the SHA recorded by the completed old run: 4694a13e67627ee5722f77729d4c0234d82fa20cecd566095f125332e389681f.
- The original product was fetched from the exact base above; SHA256 40bc5329d000001c188d28a1f85a4d6bdace03908225b7003212f7477cff1974 matches the old run. The five successful patch replacements were reapplied in memory to recover the candidate, SHA256 dacfa878cc00d8dc510f27efe36779762e669d4260f24269737a47f61c91cdb4.
- old.log and old-results.json here transcribe the complete outputs already read before loss. Their original filesystem copies cannot be re-read or uploaded now; do not claim an independently checked original-log file hash.

## Unfinished

The candidate adds one pin request sequence, increments it at new pin/unpin calls and full/pinned frames, and only applies a still-current unary response while the captured Ref is mounted. Ordinary workspace/archive handling and callers are unchanged. No manual ordering/persistence feature for issue #904 was implemented; #904 remains open.

The candidate three-file matrix started at 2026-11-12T02:20:28.785169+00:00 in session 66978. The last successful poll still reported running with no new output. No completed candidate test count, analyze result or format result was retrieved. No final source review, own CI, PR, or merge exists for this candidate. A reviewer read the four tests/Host contract and agreed the fixture model; that is not final implementation approval.

The real environment error was:
```
exec_command failed: CreateProcess { message: "Rejected(\"Failed to create unified exec process: exec-server transport disconnected; failed to resume exec-server session: recovery timed out after 45s\")" }
```
The user's environment then explicitly reported unavailable. Necessary Drive uploads of the existing test file and old.log each failed once:
```
no primary turn environment is available
```
No further shell execution or test restart was attempted after this confirmation.

## Contract and next actions

Locked official source commit 66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db:
- packages/workspace/workspace/src/index.ts: serialized pin/unpin writes await durable setState.
- packages/api/workspace-controller/src/commands.ts: returns a copied complete pin set after commit; feed.ts independently publishes committed pinned sets.
- packages/api/workspace-controller/src/client/model.ts and tests/model.client.spec.ts: a newer pin intent, pinned set, or baseline retires an older unary echo; unrelated updates do not.
- DshHttpCarrier in packages/dsh_client/lib/src/carrier.dart uses separate unary HTTP and mux WebSocket paths. This is source evidence explaining the reachable delivery order.

Recover only the two source/test paths onto a fresh isolated branch from then-current main, preserving others' progress; recovery documents are not product files. Check unchanged test hash, then run from app:
```sh
flutter pub get --offline --enforce-lockfile
flutter test --no-pub --concurrency=1 --reporter=expanded test/workspace/workspace_pin_echo_test.dart test/workspace/workspaces_state_test.dart test/drawer/drawer_pin_owner_test.dart
flutter analyze --no-pub lib/state/workspaces_state.dart test/workspace/workspace_pin_echo_test.dart
dart format --output=none --set-exit-if-changed lib/state/workspaces_state.dart test/workspace/workspace_pin_echo_test.dart
```
The original wrapper set CI=true, FLUTTER_SUPPRESS_ANALYTICS=true, TZ=Asia/Shanghai and the installed Noto font paths; SDK was Flutter 3.47.7 / Dart 3.13.5. Lock hash above must remain unchanged. Obtain independent final review and new exact-head CI before any product merge. Do not infer success from the interrupted session.
