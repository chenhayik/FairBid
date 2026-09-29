import 'package:flutter/material.dart';

/// Full-width outlined action button that shows a spinner while [busy].
/// [PrimaryButton] (see `app_widgets.dart`) is reserved for the one
/// recommended action per screen; every other Award/Check-price action on
/// the bundle detail screen uses this instead, so only one button competes
/// for the eye at a time.
class OutlinedBusyButton extends StatelessWidget {
  const OutlinedBusyButton({
    super.key,
    required this.label,
    this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton(
      onPressed: busy ? () {} : onPressed,
      child: busy
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
    return busy ? AbsorbPointer(child: button) : button;
  }
}
