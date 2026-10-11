import 'package:flutter/widgets.dart';

/// What:   Animation duration that honours the platform's reduced-motion setting.
/// Input:  [context] and the normal [duration]; route every animation through this.
/// Output: [duration], or [Duration.zero] when the platform removes animations.
Duration motion(BuildContext context, Duration duration) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;
