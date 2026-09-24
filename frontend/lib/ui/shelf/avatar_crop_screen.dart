import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:keepsy/e2ee/avatar_image.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/warm_button.dart';

const double _maxZoom = 5;
// Enough for a sharp preview at the largest zoom without holding the full photo
const int _previewDecode = 2048;

class AvatarCropScreen extends StatefulWidget {
  final Uint8List source;
  final Future<Uint8List> Function(Uint8List source, AvatarCrop crop) render;

  const AvatarCropScreen({
    super.key,
    required this.source,
    this.render = AvatarImage.render,
  });

  static Future<Uint8List?> show(BuildContext context, Uint8List source) =>
      Navigator.of(context).push<Uint8List>(
          MaterialPageRoute(builder: (_) => AvatarCropScreen(source: source)));

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  Size? _natural;
  double _zoom = 1;
  // Image top left relative to the viewport, in viewport pixels
  Offset _offset = Offset.zero;
  double _viewport = 0;
  bool _busy = false;

  double _startZoom = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(widget.source);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size =
        Size(descriptor.width.toDouble(), descriptor.height.toDouble());
    descriptor.dispose();
    buffer.dispose();
    if (mounted) setState(() => _natural = size);
  }

  double _scaleFor(double zoom) {
    final n = _natural!;
    return math.max(_viewport / n.width, _viewport / n.height) * zoom;
  }

  // The photo must always cover the circle's square
  Offset _clamp(Offset o, double zoom) {
    final s = _scaleFor(zoom);
    final n = _natural!;
    return Offset(
      o.dx.clamp(_viewport - n.width * s, 0.0),
      o.dy.clamp(_viewport - n.height * s, 0.0),
    );
  }

  void _layout(double viewport) {
    if (viewport == _viewport) return;
    final first = _viewport == 0;
    _viewport = viewport;
    if (first) {
      final n = _natural!;
      final s = _scaleFor(_zoom);
      _offset =
          Offset((viewport - n.width * s) / 2, (viewport - n.height * s) / 2);
    }
    _offset = _clamp(_offset, _zoom);
  }

  void _onStart(ScaleStartDetails d) {
    _startZoom = _zoom;
    _startOffset = _offset;
    _startFocal = d.localFocalPoint;
  }

  // Keeps the photo point under the fingers fixed while zooming
  void _onUpdate(ScaleUpdateDetails d) {
    final zoom = (_startZoom * d.scale).clamp(1.0, _maxZoom);
    final picked = (_startFocal - _startOffset) / _scaleFor(_startZoom);
    final next = d.localFocalPoint - picked * _scaleFor(zoom);
    setState(() {
      _zoom = zoom;
      _offset = _clamp(next, zoom);
    });
  }

  AvatarCrop _crop() {
    final s = _scaleFor(_zoom);
    return AvatarCrop(
      x: (-_offset.dx / s).round(),
      y: (-_offset.dy / s).round(),
      side: (_viewport / s).round(),
    );
  }

  Future<void> _use() async {
    setState(() => _busy = true);
    try {
      final jpeg = await widget.render(widget.source, _crop());
      if (mounted) Navigator.of(context).pop(jpeg);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("This photo couldn't be used. Try another one.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Warm.ground,
      body: SafeArea(
        child: Padding(
          padding:
              const EdgeInsets.fromLTRB(Warm.pagePad, 26, Warm.pagePad, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Back(),
              const SizedBox(height: 27),
              Text('Position your photo', style: Warm.h1),
              const SizedBox(height: 8),
              Text('People in your albums see what is inside the circle.',
                  style: Warm.sub),
              const SizedBox(height: 32),
              Expanded(
                child: Center(
                  child: _natural == null
                      ? const CircularProgressIndicator(
                          strokeWidth: 2, color: Warm.inkFaint)
                      : LayoutBuilder(builder: (context, box) {
                          _layout(math.min(box.maxWidth, box.maxHeight));
                          return _stage();
                        }),
                ),
              ),
              const SizedBox(height: 32),
              WarmButton(
                key: const ValueKey('avatar-use'),
                label: 'Use photo',
                busy: _busy,
                onTap: _natural == null ? null : _use,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stage() {
    final n = _natural!;
    final s = _scaleFor(_zoom);
    return GestureDetector(
      key: const ValueKey('avatar-stage'),
      onScaleStart: _onStart,
      onScaleUpdate: _onUpdate,
      child: SizedBox.square(
        dimension: _viewport,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            children: [
              Positioned(
                left: _offset.dx,
                top: _offset.dy,
                width: n.width * s,
                height: n.height * s,
                child: Image(
                  image: ResizeImage(
                    MemoryImage(widget.source),
                    width: _previewDecode,
                    height: _previewDecode,
                    policy: ResizeImagePolicy.fit,
                  ),
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              const Positioned.fill(
                child: IgnorePointer(child: CustomPaint(painter: _Mask())),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Dims everything outside the circle members will see
class _Mask extends CustomPainter {
  const _Mask();

  @override
  void paint(Canvas canvas, Size size) {
    final circle = Rect.fromCircle(
        center: size.center(Offset.zero), radius: size.shortestSide / 2 - 1);
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(circle);
    canvas.drawPath(
        outside, Paint()..color = Warm.ground.withValues(alpha: 0.72));
    canvas.drawOval(
      circle,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xCCFFFFFF),
    );
  }

  @override
  bool shouldRepaint(_Mask old) => false;
}

class _Back extends StatelessWidget {
  const _Back();

  @override
  Widget build(BuildContext context) =>
      const WarmBack(key: ValueKey('avatar-back'));
}
