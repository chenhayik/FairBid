import 'package:flutter/widgets.dart';

/// What:   StreamBuilder that creates its stream once, re-creating it only when [cacheKey] changes.
/// Input:  [create] builds the stream (use context.read); [cacheKey] is e.g. a uid (null if the inputs never change).
/// Output: [builder] gets each snapshot, with no resubscribe or spinner flash on rebuild.
/// Notes:  `.snapshots()` returns a new Stream per call, so an inline one resubscribes every rebuild.
class KeyedStreamBuilder<T> extends StatefulWidget {
  const KeyedStreamBuilder({
    super.key,
    required this.create,
    required this.builder,
    this.cacheKey,
  });

  /// Builds the stream: once, then again only when [cacheKey] changes.
  final Stream<T> Function() create;

  final AsyncWidgetBuilder<T> builder;

  /// Re-creates the stream when this changes (compared with `==`).
  final Object? cacheKey;

  @override
  State<KeyedStreamBuilder<T>> createState() => _KeyedStreamBuilderState<T>();
}

class _KeyedStreamBuilderState<T> extends State<KeyedStreamBuilder<T>> {
  // `late` so the first read happens in build, where context is valid.
  late Stream<T> _stream = widget.create();

  @override
  void didUpdateWidget(covariant KeyedStreamBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey) {
      _stream = widget.create();
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<T>(
      stream: _stream,
      builder: widget.builder,
    );
  }
}
