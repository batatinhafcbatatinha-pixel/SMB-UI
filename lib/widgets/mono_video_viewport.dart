import 'dart:math' as math;
import 'package:flutter/material.dart';

enum EyeLayout { auto, sideBySide, overUnder, mono }

/// A rectilinear single-eye camera for stereo videos such as the Kandao demo.
/// This deliberately does not label flat stereo footage as a spherical panorama.
class MonoVideoViewport extends StatefulWidget {
  const MonoVideoViewport({
    super.key,
    required this.child,
    required this.enabled,
    required this.sourceAspectRatio,
    required this.showControls,
    required this.onInteraction,
  });
  final Widget child;
  final bool enabled;
  final double sourceAspectRatio;
  final bool showControls;
  final VoidCallback onInteraction;

  @override
  State<MonoVideoViewport> createState() => _MonoVideoViewportState();
}

class _MonoVideoViewportState extends State<MonoVideoViewport> {
  EyeLayout _layout = EyeLayout.auto;
  double _fov = 75;
  double _startZoom = 1;
  Offset _pan = Offset.zero;
  Offset _lastFocus = Offset.zero;
  static const _baseFov = 100.0;
  double get _zoom =>
      math.tan(_baseFov * math.pi / 360) / math.tan(_fov * math.pi / 360);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final sourceAspect = widget.sourceAspectRatio;
      final layout = _layout == EyeLayout.auto
          ? (sourceAspect >= 3 ? EyeLayout.sideBySide : EyeLayout.mono)
          : _layout;
      final columns = widget.enabled && layout == EyeLayout.sideBySide
          ? 2.0
          : 1.0;
      final rows = widget.enabled && layout == EyeLayout.overUnder ? 2.0 : 1.0;
      final eyeAspect = sourceAspect * rows / columns;
      final baseHeight = widget.enabled
          ? math.max(bounds.maxHeight, bounds.maxWidth / eyeAspect)
          : math.min(bounds.maxHeight, bounds.maxWidth / eyeAspect);
      final height = baseHeight * (widget.enabled ? _zoom : 1);
      final width = height * eyeAspect;
      final maxX = math.max(0.0, (width - bounds.maxWidth) / 2);
      final maxY = math.max(0.0, (height - bounds.maxHeight) / 2);
      _pan = widget.enabled
          ? Offset(_pan.dx.clamp(-maxX, maxX), _pan.dy.clamp(-maxY, maxY))
          : Offset.zero;
      return Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            key: const ValueKey('mono-drag-surface'),
            behavior: HitTestBehavior.opaque,
            onScaleStart: !widget.enabled
                ? null
                : (details) {
                    _startZoom = _zoom;
                    _lastFocus = details.localFocalPoint;
                    widget.onInteraction();
                  },
            onScaleUpdate: !widget.enabled
                ? null
                : (details) {
                    setState(() {
                      final zoom = _startZoom * details.scale;
                      _fov =
                          (math.atan(
                                    math.tan(_baseFov * math.pi / 360) / zoom,
                                  ) *
                                  360 /
                                  math.pi)
                              .clamp(35.0, _baseFov);
                      _pan += details.localFocalPoint - _lastFocus;
                      _lastFocus = details.localFocalPoint;
                    });
                    widget.onInteraction();
                  },
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned(
                    left: (bounds.maxWidth - width) / 2 + _pan.dx,
                    top: (bounds.maxHeight - height) / 2 + _pan.dy,
                    width: width,
                    height: height,
                    child: ClipRect(
                      key: const ValueKey('mono-eye-crop'),
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: width * columns,
                        maxWidth: width * columns,
                        minHeight: height * rows,
                        maxHeight: height * rows,
                        child: widget.child,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.enabled && widget.showControls)
            Positioned(
              left: 16,
              right: 16,
              top: MediaQuery.paddingOf(context).top + 64,
              child: Material(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 12),
                        const Text(
                          'Uma lente',
                          style: TextStyle(color: Colors.white),
                        ),
                        const Spacer(),
                        DropdownButton<EyeLayout>(
                          key: const ValueKey('mono-layout'),
                          value: _layout,
                          dropdownColor: Colors.black87,
                          style: const TextStyle(color: Colors.white),
                          items: const [
                            DropdownMenuItem(
                              value: EyeLayout.auto,
                              child: Text('Automático'),
                            ),
                            DropdownMenuItem(
                              value: EyeLayout.sideBySide,
                              child: Text('Lado a lado'),
                            ),
                            DropdownMenuItem(
                              value: EyeLayout.overUnder,
                              child: Text('Acima / abaixo'),
                            ),
                            DropdownMenuItem(
                              value: EyeLayout.mono,
                              child: Text('Imagem única'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() {
                              _layout = value;
                              _pan = Offset.zero;
                            });
                            widget.onInteraction();
                          },
                        ),
                        IconButton(
                          tooltip: 'Centralizar visão',
                          icon: const Icon(
                            Icons.center_focus_strong,
                            color: Colors.white,
                          ),
                          onPressed: () {
                            setState(() {
                              _pan = Offset.zero;
                              _fov = 75;
                            });
                            widget.onInteraction();
                          },
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 12),
                        Text(
                          'FOV ${_fov.round()}°',
                          style: const TextStyle(color: Colors.white),
                        ),
                        Expanded(
                          child: Slider(
                            key: const ValueKey('mono-fov'),
                            value: _fov,
                            min: 35,
                            max: _baseFov,
                            onChanged: (value) {
                              setState(() => _fov = value);
                              widget.onInteraction();
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}
