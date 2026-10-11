import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// What:   Text field with an external label, optional show/hide toggle for secrets, and FairBid styling.
/// Input:  [controller], [label], validators and the display options below.
/// Output: A labelled TextFormField.
class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.prefixIcon,
    this.prefixText,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.validator,
    this.helperText,
    this.maxLines = 1,
    this.maxLength,
    this.labelTrailing,
    this.onSubmitted,
    this.enabled = true,
    this.fieldKey,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final IconData? prefixIcon;
  final String? prefixText;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final String? Function(String?)? validator;
  final String? helperText;
  final int maxLines;
  final int? maxLength;

  /// False greys the field out and blocks input.
  final bool enabled;

  /// Widget on the right of the label row (e.g. "Forgot?").
  final Widget? labelTrailing;
  final ValueChanged<String>? onSubmitted;

  /// Key on the inner TextFormField, to reach its FormFieldState.
  final GlobalKey<FormFieldState<String>>? fieldKey;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late bool _hidden = widget.obscure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Expanded: the label takes all the free width (wrapping
              // rather than overflowing a narrow screen), pushing any
              // trailing widget flush to the row's right edge.
              Expanded(
                child: Text(widget.label, style: theme.textTheme.labelLarge),
              ),
              if (widget.labelTrailing != null) widget.labelTrailing!,
            ],
          ),
          const SizedBox(height: 6),
          TextFormField(
            key: widget.fieldKey,
            controller: widget.controller,
            enabled: widget.enabled,
            keyboardType: widget.keyboardType,
            obscureText: _hidden,
            maxLines: widget.obscure ? 1 : widget.maxLines,
            maxLength: widget.maxLength,
            textInputAction: widget.textInputAction,
            validator: widget.validator,
            onFieldSubmitted: widget.onSubmitted,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            decoration: InputDecoration(
              hintText: widget.hint,
              helperText: widget.helperText,
              helperMaxLines: 3,
              // Long validation messages (e.g. the bundle-price cap) used to
              // be clipped to one line, cutting the amount off mid-word.
              errorMaxLines: 3,
              prefixText: widget.prefixText,
              prefixIcon:
                  widget.prefixIcon == null ? null : Icon(widget.prefixIcon),
              suffixIcon: widget.obscure
                  ? IconButton(
                      icon: Icon(_hidden
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined),
                      onPressed: () => setState(() => _hidden = !_hidden),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// What:   Header above every onboarding step.
/// Input:  [stage] of [totalStages] (the last step number) and the [sectionLabel].
/// Output: "Stage X of N", the section name in brand blue and a progress bar.
class StageHeader extends StatelessWidget {
  const StageHeader({
    super.key,
    required this.stage,
    required this.totalStages,
    required this.sectionLabel,
  });

  final int stage;
  final int totalStages;
  final String sectionLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Stage $stage of $totalStages',
                style: theme.textTheme.bodyMedium),
            const SizedBox(width: 12),
            // Flexible so long section names shrink on narrow screens.
            Expanded(
              child: Text(sectionLabel,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: context.fairbid.verified)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: stage / totalStages,
            minHeight: 6,
            backgroundColor: context.fairbid.borderSubtle,
            color: context.fairbid.verified,
          ),
        ),
      ],
    );
  }
}

/// What:   Dashed-border upload area.
/// Input:  [icon], [hint], [onTap]; [pickedName] once a file is chosen; [busy] while uploading.
/// Output: Icon with "Click to upload" and the hint; the file name with a green check when picked; an in-place spinner and disabled tap while [busy].
class UploadBox extends StatelessWidget {
  const UploadBox({
    super.key,
    required this.onTap,
    required this.hint,
    this.icon = Icons.upload_file_outlined,
    this.pickedName,
    this.compact = false,
    this.busy = false,
    this.busyLabel = 'Uploading…',
  });

  final VoidCallback onTap;
  final String hint;
  final IconData icon;
  final String? pickedName;
  final bool compact;
  final bool busy;
  final String busyLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final picked = pickedName != null;
    // successText: `accent` colours text and glyph, which must clear AA on white.
    final accent =
        picked ? context.fairbid.successText : context.fairbid.verified;

    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: CustomPaint(
        painter: _DashedRRectPainter(
          color: picked ? accent : const Color(0xFFC3C5D9),
        ),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(vertical: compact ? 16 : 28),
          child: Column(
            children: [
              if (busy)
                SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: accent),
                )
              else
                Icon(picked ? Icons.check_circle_outline : icon,
                    color: accent, size: 28),
              const SizedBox(height: 8),
              Text(
                busy
                    ? busyLabel
                    : (picked ? pickedName! : 'Click to upload'),
                style: theme.textTheme.labelLarge?.copyWith(color: accent),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                busy ? 'Please wait' : (picked ? 'Tap to change' : hint),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints a dashed rounded-rectangle border (Flutter has none built in).
class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const dash = 6.0, gap = 4.0, radius = 12.0;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(radius),
      ));

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(
          metric.extractPath(distance, distance + dash),
          paint,
        );
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// What:   Green-check bullet line for tips and checklists.
/// Input:  [text].
/// Output: A row with a green check and the text.
class CheckBullet extends StatelessWidget {
  const CheckBullet(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle_outline,
              size: 18, color: context.fairbid.successText),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

/// What:   A dialog asking for a required free-text reason.
/// Input:  [title], [message], [hint] and the confirm button's [confirmLabel] / [confirmColor].
/// Output: Pops the trimmed text on confirm, null on cancel.
/// Notes:  Confirm stays disabled until something is typed.
class ReasonDialog extends StatefulWidget {
  const ReasonDialog({
    super.key,
    required this.title,
    required this.message,
    required this.hint,
    required this.confirmLabel,
    this.confirmColor,
  });

  final String title, message, hint, confirmLabel;
  final Color? confirmColor;

  @override
  State<ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<ReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _controller.text.trim();
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLines: 3,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(hintText: widget.hint),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: widget.confirmColor == null
              ? null
              : FilledButton.styleFrom(backgroundColor: widget.confirmColor),
          onPressed: text.isEmpty ? null : () => Navigator.of(context).pop(text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
