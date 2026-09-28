import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Paint-only tail: no Markdown mutation, layout shift, or blinking timer.
class StreamingCaret extends SingleChildRenderObjectWidget {
  const StreamingCaret({super.key, required this.style, required super.child});
  final TextStyle style;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderStreamingCaret(style, Directionality.of(context));

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderStreamingCaret).update(
        style,
        Directionality.of(context),
      );
}

class _RenderStreamingCaret extends RenderProxyBox {
  _RenderStreamingCaret(TextStyle style, TextDirection direction) {
    update(style, direction);
  }

  final _caret = TextPainter();
  RenderBox? _lastText;

  void update(TextStyle style, TextDirection direction) {
    _caret
      ..text = TextSpan(text: '▍', style: style)
      ..textDirection = direction
      ..layout();
    markNeedsPaint();
  }

  @override
  void performLayout() {
    super.performLayout();
    _lastText = null;
    void visit(RenderObject object) {
      if (object is RenderEditable &&
          object.text?.toPlainText().isNotEmpty == true) {
        _lastText = object;
      } else if (object is RenderParagraph &&
          object.text.toPlainText().isNotEmpty) {
        _lastText = object;
      }
      object.visitChildren(visit);
    }

    child?.visitChildren(visit);
    if (child is RenderEditable || child is RenderParagraph) visit(child!);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final target = _lastText;
    if (target == null) return;
    final Offset end;
    if (target is RenderEditable) {
      end = target
          .getLocalRectForCaret(
            TextPosition(offset: target.text!.toPlainText().length),
          )
          .topLeft;
    } else if (target is RenderParagraph) {
      end = target.getOffsetForCaret(
        TextPosition(offset: target.text.toPlainText().length),
        Rect.fromLTWH(0, 0, _caret.width, _caret.height),
      );
    } else {
      return;
    }
    _caret.paint(
      context.canvas,
      offset + target.localToGlobal(end, ancestor: this),
    );
  }

  @override
  void dispose() {
    _caret.dispose();
    super.dispose();
  }
}
