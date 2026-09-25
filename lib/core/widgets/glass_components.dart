import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/glass_depth.dart';

/// True when the active theme is the Glass theme.
/// Every glass-specific visual below is gated behind this so Dark / Light /
/// AMOLED always keep their exact existing appearance.
bool isGlassTheme(BuildContext context) => PyloGlass.isActive(context);

/// Text color for lower-priority labels, readable on dark glass surfaces.
Color glassSecondaryText(BuildContext context) =>
    isGlassTheme(context) ? GlassColors.textSecondary : Colors.grey.shade600;

/// Text color for most-muted metadata, readable on dark glass surfaces.
Color glassMutedText(BuildContext context) =>
    isGlassTheme(context) ? GlassColors.textMuted : Colors.grey.shade500;

/// Frosted-glass 3-surface wrapper shared by the whole Glass design system.
///
/// In Glass mode it renders a translucent surface at one of the three depth
/// levels (see [GlassDepth]) with a carefully controlled blur so surfaces
/// appear to float above the ambient background. In any other theme, the
/// child passes through untouched.
///
/// Performance rules baked in:
///  - [blur] defaults to the depth level's configured value and is only
///    applied when non-zero (BackdropFilter is expensive).
///  - The surface is a single [Container] (no nested blur layers).
///  - When the app is not in Glass mode there is zero decoration cost.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final GlassDepth depth;
  final double? blur;
  final Color? surfaceColor;
  final Color? borderColor;
  final List<BoxShadow>? shadows;
  final VoidCallback? onTap;

  const GlassSurface({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = 20,
    this.depth = GlassDepth.level2,
    this.blur,
    this.surfaceColor,
    this.borderColor,
    this.shadows,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (!isGlassTheme(context)) {
      Widget result = padding != null
          ? Padding(padding: padding!, child: child)
          : child;
      if (onTap != null) {
        result = InkWell(onTap: onTap, child: result);
      }
      return result;
    }

    final config = GlassDepthConfig.of(depth);
    final effectiveColor = surfaceColor ??
        _surfaceForDepth(context, depth, config.opacity);
    final effectiveBlur = blur ?? config.blur;
    final effectiveShadows = shadows ?? config.shadows;

    Widget surface = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: effectiveColor,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: borderColor ?? config.borderColor,
          width: 1,
        ),
        boxShadow: effectiveShadows,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );

    if (onTap != null) {
      surface = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(borderRadius),
          child: surface,
        ),
      );
    }

    if (effectiveBlur > 0) {
      surface = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: effectiveBlur * 0.5,
            sigmaY: effectiveBlur * 0.5,
          ),
          child: surface,
        ),
      );
    }

    return RepaintBoundary(child: surface);
  }

  Color _surfaceForDepth(
      BuildContext context, GlassDepth depth, double opacity) {
    return switch (depth) {
      GlassDepth.level1 => GlassColors.level1,
      GlassDepth.level2 => GlassColors.level2,
      GlassDepth.level3 => GlassColors.level3,
    };
  }
}

/// Glass-themed button with press feedback. In non-Glass themes it renders a
/// standard [FilledButton] with identical shape/behaviour.
class GlassButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final EdgeInsets? padding;
  final double radius;
  final bool outlined;

  const GlassButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.padding,
    this.radius = 14,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!isGlassTheme(context)) {
      return outlined
          ? OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(padding: padding),
              child: child,
            )
          : FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(padding: padding),
              child: child,
            );
    }

    final style = BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: outlined
          ? null
          : const LinearGradient(
              colors: [GlassColors.accent, GlassColors.accentStrong],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
      color: outlined ? GlassColors.level2 : null,
      border: Border.all(
        color: outlined
            ? GlassColors.borderStrong
            : Colors.transparent,
        width: 1,
      ),
      boxShadow: [
        BoxShadow(
          color: outlined
              ? const Color(0x28000000)
              : GlassColors.accentGlow,
          blurRadius: 14,
          offset: const Offset(0, 4),
        ),
      ],
    );

    return GestureDetector(
      onTap: onPressed,
      child: Container(
          padding: padding ?? const EdgeInsets.symmetric(
              horizontal: 20, vertical: 12),
          alignment: Alignment.center,
          decoration: style,
          child: DefaultTextStyle(
            style: TextStyle(
              color: outlined
                  ? GlassColors.textPrimary
                  : GlassColors.onAccent,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              fontFamily: 'Inter',
            ),
            child: child,
          ),
        ),
    );
  }
}

/// Glass-themed input field. Non-Glass renders a standard [TextField] with
/// the same decoration.
///
/// Password fields (obscured) get a PRESS-AND-HOLD visibility toggle in the
/// suffix: the text is readable only while the eye is held down and re-masks
/// the instant it is released — there is no persistent reveal state to leak
/// the password on screen. Set [obscureRevealEnabled] to false on a field
/// that must stay permanently masked.
class GlassInput extends StatefulWidget {
  final TextEditingController? controller;
  final String? labelText;
  final String? hintText;
  final String? errorText;
  final String? helperText;
  final IconData? prefixIcon;
  final IconData? suffixIcon;
  final bool obscureText;
  final int maxLines;
  final TextInputType? keyboardType;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onChanged;
  final bool obscureRevealEnabled;

  const GlassInput({
    super.key,
    this.controller,
    this.labelText,
    this.hintText,
    this.errorText,
    this.helperText,
    this.prefixIcon,
    this.suffixIcon,
    this.obscureText = false,
    this.maxLines = 1,
    this.keyboardType,
    this.validator,
    this.onChanged,
    this.obscureRevealEnabled = true,
  });

  @override
  State<GlassInput> createState() => _GlassInputState();
}

class _GlassInputState extends State<GlassInput> {
  /// True only while the eye suffix is physically held down.
  bool _revealing = false;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      obscureText: widget.obscureText && !_revealing,
      maxLines: widget.maxLines,
      keyboardType: widget.keyboardType,
      onChanged: widget.onChanged,
      validator: widget.validator,
      decoration: InputDecoration(
        labelText: widget.labelText,
        hintText: widget.hintText,
        errorText: widget.errorText,
        helperText: widget.helperText,
        prefixIcon: widget.prefixIcon != null ? Icon(widget.prefixIcon) : null,
        suffixIcon: widget.obscureText && widget.obscureRevealEnabled
            ? _obscureSuffix()
            : (widget.suffixIcon != null ? Icon(widget.suffixIcon) : null),
      ),
    );
  }

  /// Press-and-hold eye. Raw pointer handling (rather than a GestureDetector)
  /// so the field's own tap-to-focus recognizer can never steal or drop the
  /// press: pointer-down reveals, pointer-up/cancel re-masks immediately.
  Widget _obscureSuffix() {
    final icon = _revealing
        ? Icons.visibility_outlined
        : Icons.visibility_off_outlined;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => setState(() => _revealing = true),
      onPointerUp: (_) => setState(() => _revealing = false),
      onPointerCancel: (_) => setState(() => _revealing = false),
      child: SizedBox(
        width: 48,
        child: Icon(
          icon,
          size: 20,
          semanticLabel:
              _revealing ? 'Hide password' : 'Hold to show password',
        ),
      ),
    );
  }
}

/// Glass-themed dialog helper. Non-Glass uses the standard [showDialog].
Future<T?> showGlassDialog<T>(
  BuildContext context, {
  required String title,
  required Widget content,
  List<Widget> actions = const [],
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: content,
      actions: actions,
    ),
  );
}

/// Glass-themed bottom sheet helper. Non-Glass uses standard showModalBottomSheet.
Future<T?> showGlassBottomSheet<T>(
  BuildContext context, {
  required Widget child,
  bool isScrollControlled = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    backgroundColor: isGlassTheme(context)
        ? Colors.transparent
        : Theme.of(context).bottomSheetTheme.backgroundColor,
    builder: (context) {
      if (!isGlassTheme(context)) {
        return child;
      }
      return GlassSurface(
        borderRadius: 24,
        depth: GlassDepth.level3,
        padding: const EdgeInsets.only(bottom: 24),
        child: child,
      );
    },
  );
}