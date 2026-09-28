import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Adds actions without changing the message's rendering or selection gestures.
class MessageActions extends StatelessWidget {
  const MessageActions({
    super.key,
    required this.text,
    required this.onShare,
    required this.child,
  });

  final String text;
  final Future<void> Function(String) onShare;
  final Widget child;

  static Widget editableMenu(BuildContext context, EditableTextState state) {
    final actions = state.context
        .dependOnInheritedWidgetOfExactType<_MessageActionScope>();
    final selection = AdaptiveTextSelectionToolbar.editableText(
      editableTextState: state,
    );
    if (actions == null) return selection;
    return _MessageActionToolbar(
      actions: actions,
      anchors: state.contextMenuAnchors,
      selection: selection,
      hide: state.hideToolbar,
    );
  }

  static Widget regionMenu(BuildContext context, SelectableRegionState state) {
    final actions = state.context
        .dependOnInheritedWidgetOfExactType<_MessageActionScope>();
    final selection = AdaptiveTextSelectionToolbar.selectableRegion(
      selectableRegionState: state,
    );
    if (actions == null) return selection;
    return _MessageActionToolbar(
      actions: actions,
      anchors: state.contextMenuAnchors,
      selection: selection,
      hide: state.hideToolbar,
    );
  }

  @override
  Widget build(BuildContext context) {
    final actions = _MessageActionScope(
      text: text,
      onShare: onShare,
      child: child,
    );
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      // Selectable children win their own gesture arena and use the toolbar.
      // The card's non-text area offers the same actions via a standard sheet.
      onLongPress: () async {
        final action = await showModalBottomSheet<String>(
          context: context,
          useSafeArea: true,
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final label in const [
                  'Copy full text',
                  'Share',
                  'Select text',
                ])
                  ListTile(
                    title: Text(label),
                    onTap: () => Navigator.pop(context, label),
                  ),
              ],
            ),
          ),
        );
        if (!context.mounted || action == null) return;
        if (action == 'Select text') {
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Select text'),
              content: SingleChildScrollView(child: SelectableText(text)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          );
        } else {
          await actions.perform(context, share: action == 'Share');
        }
      },
      child: actions,
    );
  }
}

class _MessageActionScope extends InheritedWidget {
  const _MessageActionScope({
    required this.text,
    required this.onShare,
    required super.child,
  });
  final String text;
  final Future<void> Function(String) onShare;

  Future<void> perform(BuildContext context, {required bool share}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (share) {
        await onShare(text);
      } else {
        await Clipboard.setData(ClipboardData(text: text));
      }
    } catch (error) {
      if (messenger?.mounted ?? false) {
        messenger!.showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  bool updateShouldNotify(_MessageActionScope oldWidget) =>
      oldWidget.text != text || oldWidget.onShare != onShare;
}

class _MessageActionToolbar extends StatefulWidget {
  const _MessageActionToolbar({
    required this.actions,
    required this.anchors,
    required this.selection,
    required this.hide,
  });
  final _MessageActionScope actions;
  final TextSelectionToolbarAnchors anchors;
  final Widget selection;
  final VoidCallback hide;

  @override
  State<_MessageActionToolbar> createState() => _MessageActionToolbarState();
}

class _MessageActionToolbarState extends State<_MessageActionToolbar> {
  bool _selecting = false;

  @override
  Widget build(BuildContext context) => _selecting
      ? widget.selection
      : AdaptiveTextSelectionToolbar.buttonItems(
          anchors: widget.anchors,
          buttonItems: [
            ContextMenuButtonItem(
              label: 'Copy full text',
              onPressed: () {
                widget.actions.perform(context, share: false);
                widget.hide();
              },
            ),
            ContextMenuButtonItem(
              label: 'Share',
              onPressed: () {
                widget.actions.perform(context, share: true);
                widget.hide();
              },
            ),
            ContextMenuButtonItem(
              label: 'Select text',
              onPressed: () => setState(() => _selecting = true),
            ),
          ],
        );
}
