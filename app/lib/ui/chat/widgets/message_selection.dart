// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

import '../../../l10n/l10n.dart';
import '../../speech/speech_ui.dart';
import '../../theme/theme.dart';
import '../secret_mask.dart';
import 'message_menu.dart';

/// A message's text, selectable where it is: a long-press selects the word
/// under the finger, the handles drag the range. The toolbar over the
/// selection offers copy, quote ([onQuote]), share, read aloud, more ([onMore],
/// the message menu), and select all. Editable prompts put [onEdit] first.
///
/// It copies and shares what is drawn (a masked credential stays
/// masked; the eye shows it, the menu's 「复制」 takes the original); 朗读
/// leaves credentials out ([speakableSelection]).
class MessageSelection extends StatefulWidget {
  const MessageSelection({
    super.key,
    required this.text,
    required this.child,
    this.onQuote,
    this.onEdit,
    this.onMore,
    this.live = false,
  });

  /// The whole message: 朗读 finds its credentials here, where a selected
  /// piece of one would no longer look like one.
  final String text;

  final Widget child;
  final ValueChanged<String>? onQuote;
  final VoidCallback? onEdit;
  final VoidCallback? onMore;

  /// Still being written. Selecting works as on a finished message, but the
  /// text is handed to the selection only once a finger comes down on it or
  /// the writing stops ([_HeldSelectables]), not with every delta.
  final bool live;

  @override
  State<MessageSelection> createState() => _MessageSelectionState();
}

class _MessageSelectionState extends State<MessageSelection> with AutomaticKeepAliveClientMixin {
  late final _edgeSelection = _MessageEdgeSelection();

  /// What is selected right now (plain text).
  String _selected = '';

  @override
  bool get wantKeepAlive => _selected.isNotEmpty;

  void _onSelectionChanged(SelectedContent? content) {
    final had = _selected.isNotEmpty;
    _selected = content?.plainText ?? '';
    final has = _selected.isNotEmpty;
    // 选词的那一下给个轻触觉:手柄弹出来的动画对不上手指,震动对得上。
    if (!had && has) HapticFeedback.selectionClick();
    if (had != has) updateKeepAlive();
  }

  @override
  void dispose() {
    _edgeSelection.dispose();
    super.dispose();
  }

  Widget _toolbar(BuildContext context, SelectableRegionState region) {
    final system = region.contextMenuButtonItems;
    ContextMenuButtonItem? item(ContextMenuButtonType type) => system.where((i) => i.type == type).firstOrNull;
    const ours = {ContextMenuButtonType.copy, ContextMenuButtonType.share, ContextMenuButtonType.selectAll};
    final selected = _selected;
    final some = selected.trim().isNotEmpty;
    final onQuote = widget.onQuote;
    final onEdit = widget.onEdit;
    final onMore = widget.onMore;
    final more = onMore == null
        ? null
        : ContextMenuButtonItem(
            label: context.l10n.commonMore,
            onPressed: () {
              region.clearSelection();
              onMore();
            },
          );
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: region.contextMenuAnchors,
      buttonItems: [
        if (onEdit != null)
          ContextMenuButtonItem(
            label: MessageAction.edit.label,
            onPressed: () {
              region.hideToolbar();
              region.clearSelection();
              onEdit();
            },
          ),
        ?item(ContextMenuButtonType.copy),
        if (some && onQuote != null)
          ContextMenuButtonItem(
            label: MessageAction.quote.label,
            onPressed: () {
              region.clearSelection();
              onQuote(selected);
            },
          ),
        // Keep the full menu visible when edit takes a slot on a narrow screen.
        if (onEdit != null) ?more,
        ?item(ContextMenuButtonType.share),
        if (some)
          ContextMenuButtonItem(
            label: MessageAction.readAloud.label,
            onPressed: () {
              region.hideToolbar();
              // Its own id: another passage starts over, the same one stops.
              readAloudReply(this.context, 'selection:$selected', speakableSelection(selected, widget.text));
            },
          ),
        if (onEdit == null) ?more,
        ?item(ContextMenuButtonType.selectAll),
        ...system.where((i) => !ours.contains(i.type)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scrollable = Scrollable.maybeOf(context, axis: Axis.vertical);
    final content = _HeldSelectables(live: widget.live, child: widget.child);
    return SelectionArea(
      selectionControls: glassSelectionControls,
      onSelectionChanged: _onSelectionChanged,
      contextMenuBuilder: _toolbar,
      child: scrollable == null
          ? content
          : Builder(
              builder: (context) {
                _edgeSelection
                  ..scrollable = scrollable
                  ..status = SelectableRegionSelectionStatusScope.maybeOf(context)!;
                return SelectionContainer(delegate: _edgeSelection, child: content);
              },
            ),
    );
  }
}

/// Inline messages have the inverse of Flutter's usual selection/scroll
/// nesting: the list owns the scroll position, each message its own selection.
class _MessageEdgeSelection extends StaticSelectionContainerDelegate {
  late ScrollableState scrollable;
  late ValueListenable<SelectableRegionSelectionStatus> status;
  bool _stepping = false;

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final result = super.dispatchSelectionEvent(event);
    if (event is! SelectionEdgeUpdateEvent || result == SelectionResult.pending) return result;

    final viewport = scrollable.context.findRenderObject()! as RenderBox;
    final y = viewport.globalToLocal(event.globalPosition).dy;
    final height = viewport.size.height;
    final band = math.min(64.0, height / 3);
    final over = y < band ? y - band : math.max(0.0, y - (height - band));
    if (over == 0) return result;

    // Stop at the selected message's edge, not at the end of the conversation.
    final bounds = MatrixUtils.transformRect(getTransformTo(viewport), Offset.zero & containerSize);
    final room = over < 0 ? -bounds.top : bounds.bottom - height;
    final step = math.min(room, over.abs().clamp(4.0, 24.0));
    if (step < 1) return result;
    final position = scrollable.position;
    final direction = scrollable.axisDirection == AxisDirection.up ? -over.sign : over.sign;
    final target = (position.pixels + direction * step)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if (target == position.pixels) return result;

    // The region retries a pending edge on the next frame while a handle is
    // moving. Its first update sets the status after dispatch, so request a
    // frame but don't scroll yet: a simple tap never enters the retry loop.
    if (status.value == SelectableRegionSelectionStatus.finalized) {
      SchedulerBinding.instance.ensureVisualUpdate();
    } else if (!_stepping) {
      _stepping = true;
      unawaited(
        position.animateTo(target, duration: const Duration(milliseconds: 32), curve: Curves.linear).whenComplete(() {
          _stepping = false;
        }),
      );
    }
    return SelectionResult.pending;
  }
}

/// Holds back the text that registers for selection below it while [live].
///
/// Each delta of a reply being written changes its last paragraph's text, and
/// a paragraph whose text changes registers its pieces again: the region then
/// sorts them in among the whole reply's after the frame, walking each one's
/// transform up to the root. Nobody is selecting most of the time, so that is
/// held back here instead.
///
/// A pointer down on the message, the region taking focus (the keyboard), or
/// the end of [live], hands everything held to the region and lets later
/// registrations straight through. The
/// region takes them in at the end of the next frame, well before a
/// long-press fires or a double tap's second tap comes down, so selecting
/// works as on a finished message.
class _HeldSelectables extends StatefulWidget {
  const _HeldSelectables({required this.live, required this.child});

  final bool live;
  final Widget child;

  @override
  State<_HeldSelectables> createState() => _HeldSelectablesState();
}

class _HeldSelectablesState extends State<_HeldSelectables> {
  /// Open from the start on a finished message.
  late final _gate = _SelectableGate(!widget.live);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gate.region = SelectionContainer.maybeOf(context);
    // The region's own focus, reached by the keyboard (Tab) with no pointer:
    // its select-all and copy shortcuts work on what it holds.
    if (Focus.maybeOf(context)?.hasFocus ?? false) _gate.open();
  }

  @override
  void didUpdateWidget(_HeldSelectables oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.live) _gate.open();
  }

  @override
  Widget build(BuildContext context) => Listener(
    // The region's own gesture detector is translucent over the same box.
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => _gate.open(),
    child: SelectionRegistrarScope(registrar: _gate, child: widget.child),
  );
}

/// What registers below [_HeldSelectables]: kept, and passed on to [region]
/// once open.
class _SelectableGate implements SelectionRegistrar {
  _SelectableGate(this._open);

  final _held = <Selectable>{};
  bool _open;

  SelectionRegistrar? get region => _region;
  SelectionRegistrar? _region;
  set region(SelectionRegistrar? value) {
    if (identical(value, _region)) return;
    if (_open) {
      for (final selectable in _held) {
        _region?.remove(selectable);
        value?.add(selectable);
      }
    }
    _region = value;
  }

  void open() {
    if (_open) return;
    _open = true;
    final region = _region;
    if (region == null || _held.isEmpty) return;
    for (final selectable in _held) {
      region.add(selectable);
    }
    // The region sorts them in after a frame: make sure there is one.
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void add(Selectable selectable) {
    _held.add(selectable);
    if (_open) _region?.add(selectable);
  }

  @override
  void remove(Selectable selectable) {
    if (!_held.remove(selectable)) return;
    if (_open) _region?.remove(selectable);
  }
}

/// [selected] without any part of a credential in [message]: a whole one, one
/// cut at either end of the selection, or a selection inside one (nothing is
/// left). Neither a voice service nor the speaker gets it, as with a whole
/// reply. Text only, without positions: a cut counts from [_least] characters,
/// so an ordinary word that merely shares a letter with a key stays.
@visibleForTesting
String speakableSelection(String selected, String message) {
  final cut = List.filled(selected.length, false);
  for (final secret in findSecrets(message)) {
    final value = message.substring(secret.start, secret.end);
    final words = selected.trim();
    if (words.length >= _least && value.contains(words)) return '';
    for (var at = selected.indexOf(value); at >= 0; at = selected.indexOf(value, at + 1)) {
      cut.fillRange(at, at + value.length, true);
    }
    for (var n = math.min(value.length, selected.length); n >= _least; n--) {
      if (selected.startsWith(value.substring(value.length - n))) {
        cut.fillRange(0, n, true);
        break;
      }
    }
    for (var n = math.min(value.length, selected.length); n >= _least; n--) {
      if (selected.endsWith(value.substring(0, n))) {
        cut.fillRange(selected.length - n, selected.length, true);
        break;
      }
    }
  }
  return String.fromCharCodes([
    for (var i = 0; i < selected.length; i++)
      if (!cut[i]) selected.codeUnitAt(i),
  ]);
}

const _least = 4;
