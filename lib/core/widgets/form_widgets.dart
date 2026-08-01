import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Text field with an external label above it (per the design mock), optional
/// show/hide toggle for secrets, and the standard FairBid styling.
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

  /// Optional widget on the right of the label row (e.g. a "Forgot?" link).
  final Widget? labelTrailing;
  final ValueChanged<String>? onSubmitted;

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
              Text(widget.label, style: theme.textTheme.labelLarge),
              const Spacer(),
              if (widget.labelTrailing != null) widget.labelTrailing!,
            ],
          ),
          const SizedBox(height: 6),
          TextFormField(
            controller: widget.controller,
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

/// Header shown above every onboarding step: "Stage X of 6", the section name
/// on the right in brand blue, and a thin progress bar underneath.
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

/// Dashed-border upload area: icon, "Click to upload" and a hint line.
/// Shows the picked file name with a green check once [pickedName] is set.
/// While [busy] (a pick/upload this box triggered is in flight), shows an
/// in-place spinner instead of the icon and disables the tap target — so
/// per-upload progress is obvious right where the user is looking, as
/// opposed to a screen-wide overlay.
class UploadBox extends StatelessWidget {
  const UploadBox({
    super.key,
    required this.onTap,
    required this.hint,
    this.icon = Icons.upload_file_outlined,
    this.pickedName,
    this.compact = false,
    this.busy = false,
  });

  final VoidCallback onTap;
  final String hint;
  final IconData icon;
  final String? pickedName;
  final bool compact;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final picked = pickedName != null;
    final accent =
        picked ? context.fairbid.success : context.fairbid.verified;

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
                    ? 'Uploading…'
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

/// Paints a rounded-rectangle dashed border (Flutter has no built-in one).
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

/// Green-check bullet line used in the "Tips for a successful verification"
/// card and the pending-review checklist.
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
              size: 18, color: context.fairbid.success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
