import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../util/motion.dart';

/// Full-width filled action button that shows a spinner while [busy].
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
    // While busy the button must keep its *enabled* colours. Passing null to
    // onPressed would render it disabled, fading the fill to 35%-alpha brand
    // blue, against which the white spinner sits at 1.78:1 and is effectively
    // invisible - so every commitment action in the app looked unresponsive
    // exactly while it was working. A no-op keeps the fill, and AbsorbPointer
    // below blocks the repeat tap that null was there to prevent.
    // Full width by itself (not via the shared theme - see filledButtonTheme
    // in app_theme.dart) so a bare FilledButton (dialog actions) can size to
    // its content instead of stretching edge-to-edge.
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
                  // Flexible so a long label wraps/ellipses at larger text
                  // scales instead of overflowing the button.
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

/// Full-width outlined secondary action button.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(onPressed: onPressed, child: Text(label));
  }
}

/// "Continue with Google" button with the G mark, per the design mock.
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
        // Height only: the mark is 200x204, and Google's branding guidelines
        // forbid distorting it, so let the width follow the aspect ratio.
        height: 18,
        excludeFromSemantics: true,
      ),
      label: const Text('Continue with Google'),
    );
  }
}

/// Thin "OR" separator between the form and social sign-in.
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

/// Red tinted banner for auth / form errors.
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

/// Tinted informational banner with an icon, a bold title and body text.
/// Used for "Unlock badge", "Bank-Level Security", "Trust Boosters" etc.
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
  final Color? color; // icon + accent colour, defaults to brand blue
  final Color? background; // defaults to subtle blue
  final bool leftAccent; // 4px solid left border, per DESIGN.md banners
  final Widget? trailing;

  /// Optional full-width widget under the title/body - e.g. an action button
  /// that needs its own row rather than squeezing beside the text like
  /// [trailing] does.
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

/// Pill-shaped status chip: tinted background, full-strength icon + label.
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
          // Flexible so long labels shrink instead of overflowing the pill.
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

/// White card with the standard hairline border and 12px radius (L1 surface).
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

  /// Makes the whole card tappable, *with* a ripple.
  ///
  /// Always prefer this over wrapping an [AppCard] in an [InkWell]. Ink
  /// features are painted into the nearest [Material] before its descendants
  /// are drawn, so the card's own opaque fill covered the splash completely:
  /// every job card, conversation row and queue row in the app registered as a
  /// dead tap. Rendering the fill *as* the Material puts the ink above it.
  final VoidCallback? onTap;

  /// Card fill, defaulting to white. Exists so the handful of tinted cards
  /// (an unread notification, say) can reuse this instead of hand-rolling the
  /// same decoration.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    final content = Padding(
      padding: padding ?? const EdgeInsets.all(20),
      child: child,
    );
    return Material(
      // Falls back to the theme's white card surface (not the scaffold
      // background's `surface`, which is the same tint and hides the card).
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

/// Card that can be tapped to select it - role cards, provider-type cards.
/// Selected: blue 2px border on a subtle blue fill, per the mock.
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

/// Dashboard metric tile: subtle-blue fill, no border, a big value and a small
/// uppercase caption (DESIGN.md §6.4). Optional icon in the top-right.
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.valueColor,
  });

  final String label;
  final String value;
  final IconData? icon;
  final Color? valueColor;

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
              color: valueColor ?? theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// Centred placeholder for screens/lists that have no content yet.
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

/// A labelled progress bar used for the Trust Score breakdown
/// (Reviews / Track Record / Verification / Profile). An optional [hint]
/// tells the user how to raise the sub-score; [onTap] makes the row a
/// shortcut to the place they can act on it (e.g. Edit Profile).
class TrustScoreBar extends StatelessWidget {
  const TrustScoreBar({
    super.key,
    required this.label,
    required this.percent,
    this.hint,
    this.onTap,
  });

  final String label;
  final int percent; // 0–100
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
