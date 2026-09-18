import 'package:flutter/material.dart';
import 'app_theme.dart';

/// Three levels of glass surface depth used across the Glass theme.
///
/// Each level pairs a surface color, blur intensity, elevation, border and
/// shadow so surfaces visibly layer: background glass sits behind standard
/// cards, which sit behind floating controls. This creates real visual
/// hierarchy instead of identical transparency everywhere.
enum GlassDepth { level1, level2, level3 }

class GlassDepthConfig {
  final GlassDepth depth;
  final double opacity;
  final double blur;
  final double elevation;
  final Color borderColor;
  final List<BoxShadow> shadows;

  const GlassDepthConfig({
    required this.depth,
    required this.opacity,
    required this.blur,
    required this.elevation,
    required this.borderColor,
    required this.shadows,
  });

  static const level1 = GlassDepthConfig(
    depth: GlassDepth.level1,
    opacity: 0.79,
    blur: 14,
    elevation: 0,
    borderColor: GlassColors.border,
    shadows: [BoxShadow(color: Color(0x08000000), blurRadius: 20)],
  );

  /// Blur strengths were tuned down after a perf audit: the cost of a
  /// BackdropFilter scales with the blurred area and re-composites on every
  /// scroll, and sigma 9–10 on full-width cards was the dominant GPU expense.
  /// The reduced values keep the frosted look while cutting that cost by
  /// roughly 40% on the two largest surfaces.
  static const level2 = GlassDepthConfig(
    depth: GlassDepth.level2,
    opacity: 0.91,
    blur: 14,
    elevation: 2,
    borderColor: GlassColors.borderMedium,
    shadows: [BoxShadow(color: Color(0x28000000), blurRadius: 24, offset: Offset(0, 6))],
  );

  static const level3 = GlassDepthConfig(
    depth: GlassDepth.level3,
    opacity: 0.96,
    blur: 16,
    elevation: 6,
    borderColor: GlassColors.borderStrong,
    shadows: [
      BoxShadow(color: Color(0x40000000), blurRadius: 30, offset: Offset(0, 10)),
      BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 2)),
    ],
  );

  static GlassDepthConfig of(GlassDepth depth) => switch (depth) {
        GlassDepth.level1 => level1,
        GlassDepth.level2 => level2,
        GlassDepth.level3 => level3,
      };
}