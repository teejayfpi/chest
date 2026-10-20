import 'package:flutter/material.dart';

import '../theme/chest_theme.dart';

/// The Chest mark, drawn from the same geometry as the launcher icon.
///
/// Rendered in code rather than loaded from a PNG so it stays sharp at any size
/// and adds nothing to the bundle. The geometry mirrors
/// `tool/generate_brand_assets.py`.
class ChestMark extends StatelessWidget {
  const ChestMark({super.key, this.size = 72, this.showBackground = true});

  /// Width and height of the mark.
  final double size;

  /// Whether to paint the dark obsidian plate behind the hexagon.
  final bool showBackground;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.22),
          gradient: showBackground
              ? const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF182233), ChestTheme.obsidian],
                )
              : null,
        ),
        child: CustomPaint(painter: _MarkPainter()),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final outerRadius = size.width * 0.40;

    List<Offset> hexagon(double radius) => List.generate(6, (i) {
          final angle = (90 + 60 * i) * 3.14159265358979 / 180;
          return centre +
              Offset(radius * _cos(angle), radius * _sin(angle));
        });

    final body = Path()..addPolygon(hexagon(outerRadius), true);
    canvas.drawPath(body, Paint()..color = const Color(0xFF36466A));

    final rim = Paint()
      ..color = ChestTheme.gold
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.024
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(body, rim);

    // Lid seam.
    final seamY = centre.dy - outerRadius * 0.18;
    canvas.drawLine(
      Offset(centre.dx - outerRadius * 0.82, seamY),
      Offset(centre.dx + outerRadius * 0.82, seamY),
      Paint()
        ..color = ChestTheme.gold
        ..strokeWidth = size.width * 0.022
        ..strokeCap = StrokeCap.round,
    );

    // Keyhole.
    final keyholeCentre = Offset(centre.dx, centre.dy + outerRadius * 0.16);
    canvas.drawCircle(
      keyholeCentre,
      size.width * 0.072,
      Paint()..color = ChestTheme.gold,
    );
    canvas.drawPath(
      Path()
        ..moveTo(keyholeCentre.dx - size.width * 0.028, keyholeCentre.dy)
        ..lineTo(keyholeCentre.dx + size.width * 0.028, keyholeCentre.dy)
        ..lineTo(keyholeCentre.dx + size.width * 0.018,
            keyholeCentre.dy + outerRadius * 0.32)
        ..lineTo(keyholeCentre.dx - size.width * 0.018,
            keyholeCentre.dy + outerRadius * 0.32)
        ..close(),
      Paint()..color = ChestTheme.gold,
    );
  }

  double _cos(double radians) => _sin(radians + 1.5707963267948966);
  double _sin(double radians) {
    // Small local sine to avoid a dart:math import for two call sites.
    var x = radians % 6.283185307179586;
    if (x < 0) x += 6.283185307179586;
    var sign = 1.0;
    if (x > 3.141592653589793) {
      x -= 3.141592653589793;
      sign = -1.0;
    }
    final x2 = x * x;
    return sign *
        (x -
            x * x2 / 6 +
            x * x2 * x2 / 120 -
            x * x2 * x2 * x2 / 5040 +
            x * x2 * x2 * x2 * x2 / 362880);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// A bordered panel used for grouped content.
class ChestPanel extends StatelessWidget {
  const ChestPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.accent,
  });

  /// Panel contents.
  final Widget child;

  /// Inner padding.
  final EdgeInsetsGeometry padding;

  /// Optional accent colour for the leading edge, used to flag a state.
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    // A rounded rectangle cannot be drawn from a border whose sides have
    // different colours, so the accent is a separate bar rather than a
    // coloured left edge on the border.
    return Container(
      decoration: BoxDecoration(
        color: ChestTheme.slate,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ChestTheme.hairline),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            if (accent != null)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 3,
                child: ColoredBox(color: accent!),
              ),
            Padding(
              padding: accent == null
                  ? padding
                  : padding.add(const EdgeInsets.only(left: 3)),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}

/// Section heading with an optional trailing widget.
class ChestSectionHeader extends StatelessWidget {
  const ChestSectionHeader({super.key, required this.title, this.trailing});

  /// Section label, rendered in small caps.
  final String title;

  /// Optional trailing content, such as a count or action.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1.4,
                fontWeight: FontWeight.w700,
                color: ChestTheme.muted,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A labelled row of technical detail.
class ChestKeyValue extends StatelessWidget {
  const ChestKeyValue({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.mono = false,
  });

  /// Row label.
  final String label;

  /// Row value.
  final String value;

  /// Optional override for the value colour.
  final Color? valueColor;

  /// Whether to render the value in the monospace style.
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(label, style: const TextStyle(color: ChestTheme.muted, fontSize: 13)),
          ),
          Expanded(
            child: Text(
              value,
              style: mono
                  ? ChestTheme.mono.copyWith(color: valueColor ?? ChestTheme.parchment)
                  : TextStyle(
                      color: valueColor ?? ChestTheme.parchment,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small pill used for status chips.
class ChestChip extends StatelessWidget {
  const ChestChip({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  /// Chip text.
  final String label;

  /// Chip accent colour.
  final Color color;

  /// Optional leading icon.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-width inline error banner.
class ChestErrorBanner extends StatelessWidget {
  const ChestErrorBanner({super.key, required this.message, this.onDismiss});

  /// The message to show.
  final String message;

  /// Called when the user dismisses the banner.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return ChestPanel(
      accent: ChestTheme.ember,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: ChestTheme.ember, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: const TextStyle(color: ChestTheme.parchment, fontSize: 13)),
          ),
          if (onDismiss != null)
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 18, color: ChestTheme.muted),
              tooltip: 'Dismiss',
            ),
        ],
      ),
    );
  }
}

/// A strength meter for a passphrase.
class PassphraseStrengthBar extends StatelessWidget {
  const PassphraseStrengthBar({super.key, required this.passphrase});

  /// The passphrase to assess.
  final String passphrase;

  /// Rough entropy estimate in bits.
  ///
  /// This is a deliberately conservative heuristic, not a real estimator: it
  /// scores the character-class diversity times length and penalises the obvious
  /// patterns. Its job is to steer the user toward longer passphrases, which is
  /// what actually raises the cost of an offline attack against the Argon2id
  /// output.
  static int estimateBits(String value) {
    if (value.isEmpty) return 0;
    var pool = 0;
    if (RegExp(r'[a-z]').hasMatch(value)) pool += 26;
    if (RegExp(r'[A-Z]').hasMatch(value)) pool += 26;
    if (RegExp(r'[0-9]').hasMatch(value)) pool += 10;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(value)) pool += 33;
    if (pool == 0) return 0;

    final distinct = value.split('').toSet().length;
    // Repetition makes the naive length estimate optimistic, so scale by the
    // share of distinct characters.
    final diversity = (distinct / value.length).clamp(0.25, 1.0);
    final bits = (value.length * (pool > 0 ? _log2(pool) : 0) * diversity);
    return bits.round();
  }

  static double _log2(int value) {
    var result = 0.0;
    var remaining = value.toDouble();
    while (remaining >= 2) {
      remaining /= 2;
      result += 1;
    }
    return result;
  }

  /// Maps entropy to a 0..1 score.
  static double score(String value) => (estimateBits(value) / 90).clamp(0.0, 1.0);

  /// Human-readable label for the current score.
  static String label(String value) {
    final bits = estimateBits(value);
    if (bits == 0) return 'Empty';
    if (bits < 40) return 'Weak';
    if (bits < 60) return 'Fair';
    if (bits < 80) return 'Strong';
    return 'Very strong';
  }

  @override
  Widget build(BuildContext context) {
    final value = score(passphrase);
    final colour = value < 0.35
        ? ChestTheme.ember
        : value < 0.6
            ? ChestTheme.gold
            : ChestTheme.moss;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 5,
            backgroundColor: ChestTheme.hairline,
            valueColor: AlwaysStoppedAnimation<Color>(colour),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              label(passphrase),
              style: TextStyle(color: colour, fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            Text(
              '~${estimateBits(passphrase)} bits',
              style: const TextStyle(color: ChestTheme.muted, fontSize: 11.5),
            ),
          ],
        ),
      ],
    );
  }
}
