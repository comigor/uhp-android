import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// Renders assistant output without interpreting prompts or loading resources.
class MessageContent extends StatelessWidget {
  const MessageContent({super.key, required this.role, required this.text});

  final String role;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (role != 'assistant') {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(text),
      );
    }
    final codeBuilder = _CodeBlockBuilder();
    return MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        code: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
        codeblockPadding: EdgeInsets.zero,
        codeblockDecoration: const BoxDecoration(),
      ),
      builders: {'pre': codeBuilder, 'code': codeBuilder},
      onTapLink: (_, href, _) {
        if (href != null) _showLink(context, href);
      },
      // Untrusted transcripts must never initiate image/file requests.
      imageBuilder: (uri, title, alt) => SelectableText(
        '[Image${alt == null || alt.isEmpty ? '' : ': $alt'}] $uri',
      ),
    );
  }
}

Future<void> _showLink(BuildContext context, String url) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Link'),
    content: SelectableText(url),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
      TextButton.icon(
        icon: const Icon(Icons.copy),
        label: const Text('Copy link'),
        onPressed: () => Clipboard.setData(ClipboardData(text: url)),
      ),
    ],
  ),
);

class _CodeBlockBuilder extends MarkdownElementBuilder {
  String? _language;

  @override
  void visitElementBefore(element) {
    if (element.tag == 'pre') {
      _language = null;
    } else if (element.tag == 'code') {
      final String? codeClass = element.attributes['class'];
      if (codeClass != null && codeClass.startsWith('language-')) {
        _language = codeClass.substring('language-'.length);
      }
    }
  }

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // Register for code only to read its language; inline code retains the
    // package's normal styling. The parser owns fence boundaries, even mid-stream.
    if (element.tag != 'pre') return null;
    final String code = element.textContent;
    return _CodeBlock(code: code, language: _language);
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code, required this.language});

  final String code;
  final String? language;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (language != null && language!.isNotEmpty)
                Flexible(
                  child: Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(language!),
                  ),
                ),
              const Spacer(),
              IconButton(
                tooltip: 'Copy code',
                icon: const Icon(Icons.copy),
                onPressed: () => Clipboard.setData(ClipboardData(text: code)),
              ),
            ],
          ),
          SelectionArea(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                code,
                softWrap: false,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
