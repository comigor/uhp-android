part of 'main.dart';

final chatSearchOpenProvider = StateProvider<bool>((ref) => false);

@immutable
class _ChatMatch {
  const _ChatMatch(this.messageIndex, this.start, this.end);
  final int messageIndex;
  final int start;
  final int end;
}

class _ChatHighlights {
  const _ChatHighlights(this.matches, this.active, this.paragraphKey);
  final List<_ChatMatch> matches;
  final _ChatMatch? active;
  final GlobalKey? paragraphKey;
}

/// An index anchor, rather than an estimated pixel offset, makes distant rows
/// reachable without laying out every intervening variable-height message.
class _ChatSearchView extends ConsumerStatefulWidget {
  const _ChatSearchView({
    required this.threadId,
    required this.messages,
    required this.hasLiveTurn,
    required this.composer,
    required this.messageBuilder,
  });

  final String? threadId;
  final List<ThreadMessage> messages;
  final bool hasLiveTurn;
  final Widget composer;
  final Widget Function(BuildContext, int, _ChatHighlights?) messageBuilder;

  @override
  ConsumerState<_ChatSearchView> createState() => _ChatSearchViewState();
}

class _ChatSearchViewState extends ConsumerState<_ChatSearchView> {
  final _query = TextEditingController();
  final _scroll = ScrollController(keepScrollOffset: false);
  final _paragraphKey = GlobalKey();
  final _viewportKey = GlobalKey();
  final _liveTailKey = GlobalKey();
  final _showFollow = ValueNotifier(false);
  bool _following = true;
  bool _followScheduled = false;
  int _followVersion = 0;
  (double, double, double)? _scrollDimensions;
  final _matchesByMessage = <int, List<_ChatMatch>>{};
  List<_ChatMatch> _matches = const [];
  int _active = 0;
  int _anchorIndex = 0;
  int _scrollRevision = 0;
  int _requestVersion = 0;
  late final ProviderSubscription<bool> _openSubscription;
  late final ProviderSubscription<ConversationThread?> _threadSubscription;
  late final ProviderSubscription<LiveTurn?> _liveSubscription;

  @override
  void initState() {
    super.initState();
    _anchorIndex = _lastIndex;
    _openSubscription = ref.listenManual(chatSearchOpenProvider, (_, open) {
      if (!open) setState(_clear);
    });
    _threadSubscription = ref.listenManual(threadProvider, (previous, next) {
      if (previous?.id != next?.id) {
        _resetFollow();
        ref.read(chatSearchOpenProvider.notifier).state = false;
      }
    });
    _liveSubscription = ref.listenManual(liveTurnProvider, (previous, next) {
      if (next != null && previous == null) {
        _resetFollow();
        _requestVersion++;
      }
      _showFollow.value = next != null && !_following;
      _scheduleFollow();
    });
    _scheduleFollow();
  }

  int get _lastIndex {
    final count = widget.messages.length + (widget.hasLiveTurn ? 1 : 0);
    return count == 0 ? 0 : count - 1;
  }

  void _resetFollow() {
    _followVersion++;
    _followScheduled = false;
    _following = true;
    _showFollow.value = false;
  }

  void _detach() {
    if (!_following) return;
    _following = false;
    _followVersion++;
    _followScheduled = false;
    _showFollow.value = widget.hasLiveTurn;
  }

  void _resumeFollow() {
    _requestVersion++; // A queued search reveal must not compete with the tap.
    _resetFollow();
    _scheduleFollow();
  }

  void _scheduleFollow() {
    if (!_following || _followScheduled || !mounted) return;
    _followScheduled = true;
    final version = _followVersion;
    final threadId = widget.threadId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          version != _followVersion ||
          threadId != widget.threadId) {
        return;
      }
      _followScheduled = false;
      if (!_following || !_scroll.hasClients) return;
      if (_anchorIndex != _lastIndex) {
        // Rebase at the latest row without laying out distant history. Keep the
        // index stable while detached so append-only updates cannot shift it.
        setState(() {
          _anchorIndex = _lastIndex;
          _scrollRevision++;
        });
        _scheduleFollow();
        return;
      }
      final bottom = _scroll.position.maxScrollExtent;
      if ((bottom - _scroll.offset).abs() > 0.5) _scroll.jumpTo(bottom);
    });
    // Metrics can arrive between frames; a distant lazy row may also have no
    // mounted consumer requesting one. A callback alone does not start a frame.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is UserScrollNotification &&
        notification.direction == ScrollDirection.forward) {
      _detach();
    } else if (notification is ScrollEndNotification &&
        notification.metrics.extentAfter <= 1 &&
        !_following &&
        _query.text.isEmpty) {
      _resetFollow();
    }
    return false;
  }

  bool _onMetrics(ScrollMetricsNotification notification) {
    if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
      final metrics = notification.metrics;
      final dimensions = (
        metrics.minScrollExtent,
        metrics.maxScrollExtent,
        metrics.viewportDimension,
      );
      // Selection can scroll text into view without resizing the transcript.
      // Do not snap it back and dismiss the native selection toolbar.
      if (_scrollDimensions != dimensions) {
        _scrollDimensions = dimensions;
        _scheduleFollow();
      }
    }
    return false;
  }

  void _clear() {
    _requestVersion++;
    _query.clear();
    _matches = const [];
    _matchesByMessage.clear();
    _active = 0;
  }

  @override
  void didUpdateWidget(covariant _ChatSearchView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.threadId != oldWidget.threadId) {
      _clear();
      _anchorIndex = _lastIndex;
      _scrollRevision++;
      _resetFollow();
    } else if (!identical(widget.messages, oldWidget.messages) ||
        widget.hasLiveTurn != oldWidget.hasLiveTurn) {
      if (_anchorIndex > _lastIndex) {
        _anchorIndex = _lastIndex;
        _scrollRevision++;
      }
      if (_query.text.isNotEmpty) _findMatches(preserveActive: true);
    }
    _showFollow.value = widget.hasLiveTurn && !_following;
    _scheduleFollow();
  }

  void _findMatches({bool preserveActive = false}) {
    final previous = preserveActive && _matches.isNotEmpty
        ? _matches[_active]
        : null;
    _requestVersion++;
    _matches = [];
    _matchesByMessage.clear();
    _active = 0;
    if (_query.text.isEmpty) return;
    final pattern = RegExp(RegExp.escape(_query.text), caseSensitive: false);
    for (var index = 0; index < widget.messages.length; index++) {
      for (final match in pattern.allMatches(widget.messages[index].text)) {
        final occurrence = _ChatMatch(index, match.start, match.end);
        _matches.add(occurrence);
        (_matchesByMessage[index] ??= []).add(occurrence);
        if (previous?.messageIndex == index && previous?.start == match.start) {
          _active = _matches.length - 1;
        }
      }
    }
    if (_matches.isNotEmpty) _revealActive();
  }

  void _navigate(int direction) {
    if (_matches.isEmpty) return;
    setState(() {
      _active = (_active + direction) % _matches.length;
      _revealActive();
    });
  }

  void _revealActive() {
    _detach();
    final match = _matches[_active];
    _anchorIndex = match.messageIndex;
    _scrollRevision++;
    final request = ++_requestVersion;
    final threadId = widget.threadId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          request != _requestVersion ||
          widget.threadId != threadId ||
          !ref.read(chatSearchOpenProvider) ||
          !_scroll.hasClients) {
        return;
      }
      final paragraph = _paragraphKey.currentContext?.findRenderObject();
      final viewport = _viewportKey.currentContext?.findRenderObject();
      if (paragraph is! RenderParagraph || viewport is! RenderBox) return;
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: match.start, extentOffset: match.end),
      );
      if (boxes.isEmpty) return;
      final top = paragraph.localToGlobal(Offset(0, boxes.first.top)).dy;
      final viewportTop = viewport.localToGlobal(Offset.zero).dy;
      final offset =
          _scroll.offset +
          top -
          viewportTop +
          (boxes.first.bottom - boxes.first.top) / 2 -
          viewport.size.height / 2;
      final position = _scroll.position;
      _scroll.jumpTo(
        offset
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble(),
      );
    });
  }

  void _close() => ref.read(chatSearchOpenProvider.notifier).state = false;

  @override
  void dispose() {
    _requestVersion++;
    _followVersion++;
    _liveSubscription.close();
    _showFollow.dispose();
    _openSubscription.close();
    _threadSubscription.close();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _row(BuildContext context, int index, bool searching) {
    if (widget.hasLiveTurn && index == widget.messages.length) {
      return ActiveTurnCard(tailKey: _liveTailKey);
    }
    final active = _matches.isEmpty ? null : _matches[_active];
    return KeyedSubtree(
      key: ValueKey((widget.threadId, index)),
      child: widget.messageBuilder(
        context,
        index,
        searching
            ? _ChatHighlights(
                _matchesByMessage[index] ?? const [],
                active?.messageIndex == index ? active : null,
                active?.messageIndex == index ? _paragraphKey : null,
              )
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final open = ref.watch(chatSearchOpenProvider);
    final searching = open && _query.text.isNotEmpty;
    final count = widget.messages.length + (widget.hasLiveTurn ? 1 : 0);
    final anchor = _anchorIndex;
    const centerKey = ValueKey('chat-message-anchor');
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Column(
        children: [
          if (open)
            Material(
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('chat-search-query'),
                        controller: _query,
                        autofocus: true,
                        decoration: const InputDecoration(
                          hintText: 'Search in chat',
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                        ),
                        onChanged: (_) => setState(_findMatches),
                        onSubmitted: (_) => _navigate(1),
                      ),
                    ),
                    Text(
                      '${_matches.isEmpty ? 0 : _active + 1}/${_matches.length}',
                      key: const ValueKey('chat-search-count'),
                    ),
                    IconButton(
                      tooltip: 'Previous match',
                      onPressed: _matches.isEmpty ? null : () => _navigate(-1),
                      icon: const Icon(Icons.keyboard_arrow_up),
                    ),
                    IconButton(
                      tooltip: 'Next match',
                      onPressed: _matches.isEmpty ? null : () => _navigate(1),
                      icon: const Icon(Icons.keyboard_arrow_down),
                    ),
                    IconButton(
                      tooltip: 'Close chat search',
                      onPressed: _close,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                NotificationListener<ScrollMetricsNotification>(
                  onNotification: _onMetrics,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    child: SizedBox.expand(
                      key: _viewportKey,
                      child: CustomScrollView(
                        key: ValueKey((widget.threadId, _scrollRevision)),
                        controller: _scroll,
                        center: count > 0 ? centerKey : null,
                        anchor: count > 0 ? 1 : 0,
                        slivers: [
                          if (count == 0)
                            const SliverFillRemaining(
                              hasScrollBody: false,
                              child: Center(
                                child: Text('No task history yet.'),
                              ),
                            )
                          else ...[
                            if (anchor > 0)
                              SliverList.builder(
                                itemCount: anchor,
                                itemBuilder: (context, index) => _row(
                                  context,
                                  anchor - 1 - index,
                                  searching,
                                ),
                              ),
                            SliverList.builder(
                              key: centerKey,
                              itemCount: count - anchor,
                              itemBuilder: (context, index) =>
                                  _row(context, anchor + index, searching),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 12,
                  left: 0,
                  right: 0,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _showFollow,
                    builder: (context, visible, _) => visible
                        ? Center(
                            child: Material(
                              color: Theme.of(context)
                                  .colorScheme
                                  .secondaryContainer,
                              elevation: 2,
                              borderRadius: BorderRadius.circular(24),
                              child: IconButton(
                                key: const ValueKey('chat-follow-live'),
                                tooltip: 'Follow live response',
                                onPressed: _resumeFollow,
                                icon: const Icon(Icons.arrow_downward),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
          widget.composer,
        ],
      ),
    );
  }
}

class _ChatSearchText extends StatelessWidget {
  const _ChatSearchText({required this.text, required this.highlights});
  final String text;
  final _ChatHighlights highlights;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final match in highlights.matches) {
      if (match.start > offset) {
        spans.add(TextSpan(text: text.substring(offset, match.start)));
      }
      final active = identical(match, highlights.active);
      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: TextStyle(
            backgroundColor: active
                ? colors.primary
                : colors.secondaryContainer,
            color: active ? colors.onPrimary : colors.onSecondaryContainer,
            fontWeight: active ? FontWeight.bold : null,
          ),
        ),
      );
      offset = match.end;
    }
    if (offset < text.length) spans.add(TextSpan(text: text.substring(offset)));
    return SelectionArea(
      contextMenuBuilder: MessageActions.regionMenu,
      child: Builder(
        builder: (context) => RichText(
          key: highlights.paragraphKey,
          text: TextSpan(
            style: DefaultTextStyle.of(context).style,
            children: spans,
          ),
          textScaler: MediaQuery.textScalerOf(context),
          selectionRegistrar: SelectionContainer.maybeOf(context),
          selectionColor: colors.primary.withValues(alpha: 0.3),
        ),
      ),
    );
  }
}
