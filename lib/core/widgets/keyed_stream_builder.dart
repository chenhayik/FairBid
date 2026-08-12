import 'package:flutter/widgets.dart';

/// A [StreamBuilder] that creates its stream **once** and re-creates it only
/// when [cacheKey] changes.
///
/// Firestore's `.snapshots()` returns a *new* `Stream` object on every call, so
/// `StreamBuilder(stream: repo.watchThing(), ...)` written inline in `build()`
/// hands `StreamBuilder` a different stream each rebuild. `didUpdateWidget`
/// then unsubscribes, resubscribes, and resets the snapshot to
/// `ConnectionState.waiting` while *keeping* the old data. Builders that check
/// `waiting` before reading `snapshot.data` therefore throw away perfectly good
/// results and flash a spinner.
///
/// The visible symptom was that typing in the job feed search blanked the list
/// between keystrokes, and tapping a status filter blanked the list *and* the
/// filter row. The fix already existed by hand in a few screens (see
/// `job_detail_screen`, `milestone_section`, `app_shell`); this widget makes it
/// available without converting every list screen to a `StatefulWidget`.
///
/// Pass a [cacheKey] whenever [create] closes over a value that can change -
/// typically a uid or an id list. Leave it null for a stream whose inputs are
/// fixed for the lifetime of the widget.
///
/// ```dart
/// KeyedStreamBuilder<List<Job>>(
///   cacheKey: uid,
///   create: () => context.read<JobRepository>().watchMyJobs(uid),
///   builder: (context, snapshot) => ...,
/// )
/// ```
class KeyedStreamBuilder<T> extends StatefulWidget {
  const KeyedStreamBuilder({
    super.key,
    required this.create,
    required this.builder,
    this.cacheKey,
    this.initialData,
  });

  /// Builds the stream. Called once on first build, then again only when
  /// [cacheKey] changes. Use `context.read`, never `context.watch`.
  final Stream<T> Function() create;

  final AsyncWidgetBuilder<T> builder;

  /// Re-creates the stream when this changes. Compared with `==`, so a list
  /// must be wrapped in something with value equality (or joined to a string).
  final Object? cacheKey;

  final T? initialData;

  @override
  State<KeyedStreamBuilder<T>> createState() => _KeyedStreamBuilderState<T>();
}

class _KeyedStreamBuilderState<T> extends State<KeyedStreamBuilder<T>> {
  // `late` so the first read happens during build, where the closure's context
  // is valid.
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
      initialData: widget.initialData,
      builder: widget.builder,
    );
  }
}
