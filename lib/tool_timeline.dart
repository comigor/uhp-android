part of 'main.dart';

class ToolTimeline extends StatefulWidget {
  const ToolTimeline({super.key, required this.tools});

  final List<ToolCall> tools;

  @override
  State<ToolTimeline> createState() => _ToolTimelineState();
}

class _ToolTimelineState extends State<ToolTimeline> {
  bool _expanded = false;
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    if (widget.key != null) {
      _expanded =
          PageStorage.maybeOf(context)
              ?.readState(context, identifier: widget.key) ==
          true;
    }
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (widget.key != null) {
      PageStorage.maybeOf(context)
          ?.writeState(context, _expanded, identifier: widget.key);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tools.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ActionChip(
          avatar: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
          label: Text('Tools (${widget.tools.length})'),
          onPressed: _toggle,
        ),
        // Neither argument decoding nor argument widgets exist while collapsed.
        if (_expanded)
          ListView.builder(
            primary: false,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: widget.tools.length,
            itemBuilder: (context, index) =>
                _ToolTimelineEntry(tool: widget.tools[index]),
          ),
      ],
    );
  }
}

class _ToolTimelineEntry extends StatelessWidget {
  const _ToolTimelineEntry({required this.tool});

  final ToolCall tool;

  @override
  Widget build(BuildContext context) {
    Object? decoded;
    String arguments = tool.args;
    try {
      decoded = jsonDecode(tool.args);
      arguments = const JsonEncoder.withIndent('  ').convert(decoded);
    } on FormatException {
      // The endpoint promises a string, not valid JSON. Keep invalid data exact.
    }
    Object? summary = decoded;
    if (decoded is Map && decoded.isNotEmpty) {
      summary = switch (tool.name) {
        'read' || 'glob' => decoded['path'] ?? decoded['pattern'] ?? decoded,
        'grep' => decoded['pattern'] ?? decoded,
        'bash' => decoded.values.first,
        _ => decoded,
      };
    }
    final summaryText = _toolSummaryText(
      summary is String
          ? summary
          : summary == null
          ? tool.args
          : jsonEncode(summary),
    );
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(fontFamily: 'monospace');
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${tool.name} — $summaryText', style: style),
          const SizedBox(height: 4),
          SelectableText(arguments, style: style),
        ],
      ),
    );
  }
}

String _toolSummaryText(String text) {
  final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final runes = compact.runes.take(101).toList();
  return runes.length <= 100
      ? compact
      : '${String.fromCharCodes(runes.take(99))}…';
}
