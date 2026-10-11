import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../util/motion.dart';

/// What:   Full-width filled action button.
/// Input:  [label], [onPressed]; [busy] shows a spinner; optional [trailingIcon].
/// Output: Button that keeps its enabled colours but ignores taps while [busy].
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.busy = false,
    this.trailingIcon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    // A no-op (not null) keeps the enabled fill so the spinner stays visible;
    // AbsorbPointer blocks repeat taps.
    final button = SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: busy ? () {} : onPressed,
        child: busy
            ? Semantics(
                label: label,
                child: SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (trailingIcon != null) ...[
                    const SizedBox(width: 8),
                    Icon(trailingIcon, size: 18),
                  ],
                ],
              ),
      ),
    );
    return busy ? AbsorbPointer(child: button) : button;
  }
}

/// What:   Outlined secondary action button.
/// Input:  [label], [onPressed]; [busy] swaps the label for a spinner.
/// Output: Button that ignores taps while [busy].
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
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

/// What:   "Continue with Google" button with the G mark.
/// Input:  [onPressed]; [enabled] false disables it.
/// Output: Outlined white button.
class GoogleButton extends StatelessWidget {
  const GoogleButton({super.key, this.onPressed, this.enabled = true});

  final VoidCallback? onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: enabled ? onPressed : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        side: const BorderSide(color: Color(0xFFE2E8F0)),
        backgroundColor: Colors.white,
      ),
      icon: Image.asset(
        'assets/images/google_g.png',
        // Height only: Google's branding forbids distorting the mark.
        height: 18,
        excludeFromSemantics: true,
      ),
      label: const Text('Continue with Google'),
    );
  }
}

/// What:   Thin "OR" separator between the form and social sign-in.
/// Input:  None.
/// Output: A divider row with a centred "OR".
class OrDivider extends StatelessWidget {
  const OrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final color = context.fairbid.borderSubtle;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Row(
        children: [
          Expanded(child: Divider(color: color)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('OR',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    )),
          ),
          Expanded(child: Divider(color: color)),
        ],
      ),
    );
  }
}

/// What:   Red tinted banner for auth and form errors.
/// Input:  [message].
/// Output: Banner with an error icon and the message.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    final danger = context.fairbid.danger;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: danger, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(color: danger))),
        ],
      ),
    );
  }
}

/// What:   Tinted informational banner with an icon, bold title and body.
/// Input:  [icon], [title], [body]; optional [color], [background], [leftAccent], [trailing], [bottom].
/// Output: Banner; [bottom] is a full-width row under the text, [trailing] sits beside it.
class InfoBanner extends StatelessWidget {
  const InfoBanner({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.color,
    this.background,
    this.leftAccent = false,
    this.trailing,
    this.bottom,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color? color;
  final Color? background;
  final bool leftAccent;
  final Widget? trailing;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? context.fairbid.verified;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: background ?? context.fairbid.subtleBlue,
        borderRadius: BorderRadius.circular(8),
        border: leftAccent
            ? Border(left: BorderSide(color: accent, width: 4))
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: accent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(fontSize: 14)),
                const SizedBox(height: 4),
                Text(body,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        )),
                if (bottom != null) ...[
                  const SizedBox(height: 12),
                  bottom!,
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// What:   Pill-shaped status chip.
/// Input:  [label]; optional [icon] and [color].
/// Output: Tinted pill with a full-strength icon and label.
class PillBadge extends StatelessWidget {
  const PillBadge({
    super.key,
    required this.label,
    this.icon,
    this.color,
  });

  final String label;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? context.fairbid.verified;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: accent),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: accent, letterSpacing: 0.2)),
          ),
        ],
      ),
    );
  }
}

/// What:   White card with hairline border and 12px radius.
/// Input:  [child]; optional [padding], [color], [onTap].
/// Output: The card; tappable with a ripple when [onTap] is set.
/// Notes:  Use [onTap], not an outer InkWell - the opaque fill hides the ripple.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    final content = Padding(
      padding: padding ?? const EdgeInsets.all(20),
      child: child,
    );
    return Material(
      color: color ?? Theme.of(context).colorScheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: context.fairbid.borderSubtle),
      ),
      // So the splash is clipped to the rounded corners.
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: double.infinity,
        child: onTap == null
            ? content
            : InkWell(onTap: onTap, child: content),
      ),
    );
  }
}

/// What:   Tappable card that shows a selected state (role and provider-type cards).
/// Input:  [selected], [onTap], [child].
/// Output: Card with a 2px blue border on a subtle blue fill when selected.
class SelectableCard extends StatelessWidget {
  const SelectableCard({
    super.key,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final brand = context.fairbid.verified;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: motion(context, const Duration(milliseconds: 150)),
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? context.fairbid.subtleBlue : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? brand : context.fairbid.borderSubtle,
            width: selected ? 2 : 1,
          ),
        ),
        child: child,
      ),
    );
  }
}

/// What:   Dashboard metric tile.
/// Input:  [label], [value]; optional [icon].
/// Output: Subtle-blue tile with a big value under an uppercase caption.
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    this.icon,
  });

  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.fairbid.subtleBlue,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              if (icon != null)
                Icon(icon, size: 18, color: context.fairbid.verified),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// What:   Centred placeholder for screens and lists with no content.
/// Input:  [icon], [title], [message].
/// Output: Icon, title and message in a column.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// What:   Labelled progress bar for one Trust Score part.
/// Input:  [label], [percent] (0-100); optional [hint] and [onTap].
/// Output: Bar row; [hint] says how to raise it, [onTap] links to where to act.
class TrustScoreBar extends StatelessWidget {
  const TrustScoreBar({
    super.key,
    required this.label,
    required this.percent,
    this.hint,
    this.onTap,
  });

  final String label;
  final int percent;
  final String? hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bar = Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text(label, style: theme.textTheme.bodyMedium)),
              Text('$percent%',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              if (onTap != null)
                Icon(Icons.chevron_right,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (percent.clamp(0, 100)) / 100,
              minHeight: 6,
              backgroundColor: context.fairbid.borderSubtle,
              color: context.fairbid.verified,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
    if (onTap == null) return bar;
    return InkWell(
        onTap: onTap, borderRadius: BorderRadius.circular(8), child: bar);
  }
}

/// What:   A plain Cancel / confirm dialog.
/// Input:  [title], [body] and the confirm button's [actionLabel].
/// Output: true if confirmed, false if cancelled or dismissed.
/// Notes:  [danger] paints the confirm button red.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String actionLabel,
  String cancelLabel = 'Cancel',
  bool danger = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(cancelLabel)),
          FilledButton(
              style: danger
                  ? FilledButton.styleFrom(
                      backgroundColor: ctx.fairbid.danger)
                  : null,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(actionLabel)),
        ],
      ),
    ) ??
    false;
