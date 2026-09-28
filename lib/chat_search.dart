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
  final _matchesByMessage = <int, List<_ChatMatch>>{};
  List<_ChatMatch> _matches = const [];
  int _active = 0;
  int? _anchorMessage;
  int _scrollRevision = 0;
  int _requestVersion = 0;
  late final ProviderSubscription<bool> _openSubscription;
  late final ProviderSubscription<ConversationThread?> _threadSubscription;

  @override
  void initState() {
    super.initState();
    _openSubscription = ref.listenManual(chatSearchOpenProvider, (_, open) {
      if (!open) setState(_clear);
    });
    _threadSubscription = ref.listenManual(threadProvider, (previous, next) {
      if (previous?.id != next?.id) {
        ref.read(chatSearchOpenProvider.notifier).state = false;
      }
    });
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
      _anchorMessage = null;
      _scrollRevision++;
    } else if (!identical(widget.messages, oldWidget.messages) ||
        widget.hasLiveTurn != oldWidget.hasLiveTurn) {
      if (_anchorMessage != null && _anchorMessage! >= widget.messages.length) {
        _anchorMessage = null;
        _scrollRevision++;
      }
      if (_query.text.isNotEmpty) _findMatches(preserveActive: true);
    }
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
    // Navigation follows the visible newest-first transcript order.
    for (var index = widget.messages.length - 1; index >= 0; index--) {
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
    final match = _matches[_active];
    _anchorMessage = match.messageIndex;
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
      final offset = _scroll.offset + top - viewportTop - 24;
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
    _openSubscription.close();
    _threadSubscription.close();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _row(BuildContext context, int visualIndex, bool searching) {
    if (widget.hasLiveTurn && visualIndex == 0) return const ActiveTurnCard();
    final index =
        widget.messages.length - 1 - visualIndex + (widget.hasLiveTurn ? 1 : 0);
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
    final anchor = _anchorMessage == null
        ? 0
        : widget.messages.length -
              1 -
              _anchorMessage! +
              (widget.hasLiveTurn ? 1 : 0);
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
            child: SizedBox.expand(
              key: _viewportKey,
              child: CustomScrollView(
                key: ValueKey((widget.threadId, _scrollRevision)),
                controller: _scroll,
                center: _anchorMessage == null ? null : centerKey,
                slivers: [
                  SliverToBoxAdapter(child: widget.composer),
                  if (count == 0)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text('No task history yet.')),
                    )
                  else ...[
                    if (_anchorMessage != null)
                      SliverList.builder(
                        itemCount: anchor,
                        itemBuilder: (context, index) =>
                            _row(context, anchor - 1 - index, searching),
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
