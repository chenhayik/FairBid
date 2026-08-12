import 'package:flutter/widgets.dart';

/// Resolves an animation duration against the viewer's reduced-motion setting.
///
/// Returns [duration] normally, or [Duration.zero] when the platform reports
/// "remove animations" (Android's Accessibility > Remove animations, iOS's
/// Reduce Motion). Route every animation duration in the app through this
/// rather than hardcoding one, so the setting is honoured by construction
/// instead of being remembered case by case.
///
/// ```dart
/// AnimatedSize(duration: motion(context, const Duration(milliseconds: 200)))
/// ```
Duration motion(BuildContext context, Duration duration) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;
