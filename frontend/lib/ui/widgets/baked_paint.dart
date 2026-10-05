import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

typedef BakedPainter = void Function(Canvas canvas, Size size);

// Cache static blur effects to avoid repainting the blur each frame
class BakedPaint extends StatefulWidget {
  // Include paint changes in the ID; size is added to the cache key
  final String id;
  final EdgeInsets overflow;
  final double maxScale;
  final BakedPainter painter;

  const BakedPaint({
    super.key,
    required this.id,
    required this.painter,
    this.overflow = EdgeInsets.zero,
    this.maxScale = 3,
  });

  @override
  State<BakedPaint> createState() => _BakedPaintState();
}

class _BakedPaintState extends State<BakedPaint> {
  static final LinkedHashMap<String, ui.Image> _cache = LinkedHashMap();
  static final Map<String, Future<ui.Image>> _pending = {};
  static const int _maxEntries = 24;
  static const Duration _settle = Duration(milliseconds: 120);

  ui.Image? _image;
  String? _imageKey;
  String? _wanted;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  static String _keyFor(String id, Size size, double scale) =>
      '$id|${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}@$scale';

  void _use(String key, ui.Image shared) {
    if (_imageKey == key) return;
    _image?.dispose();
    _image = shared.clone();
    _imageKey = key;
  }

  void _want(String key, Size size, double scale) {
    if (_wanted == key) return;
    _wanted = key;
    _timer?.cancel();
    // Wait for resizing to stop before allocating a cached image
    _timer = Timer(_settle, () async {
      if (!mounted || _wanted != key) return;
      try {
        // Do not return the removed future or it would await itself
        final image = await (_pending[key] ??=
            _bake(size, scale).whenComplete(() {
          _pending.remove(key);
        }));
        _store(key, image);
        if (mounted && _wanted == key) setState(() {});
      } catch (_) {
      }
    });
  }

  Future<ui.Image> _bake(Size size, double scale) {
    final o = widget.overflow;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(scale)
      ..translate(o.left, o.top);
    widget.painter(canvas, size);
    final picture = recorder.endRecording();
    return picture
        .toImage(((size.width + o.horizontal) * scale).ceil(),
            ((size.height + o.vertical) * scale).ceil())
        .whenComplete(picture.dispose);
  }

  static void _store(String key, ui.Image image) {
    if (_cache.containsKey(key)) {
      if (!identical(_cache[key], image)) image.dispose();
      return;
    }
    _cache[key] = image;
    while (_cache.length > _maxEntries) {
      // Widget clones remain valid after cache eviction
      _cache.remove(_cache.keys.first)?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      if (!size.isFinite || size.isEmpty) return const SizedBox.shrink();
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final scale = dpr < widget.maxScale ? dpr : widget.maxScale;
      final key = _keyFor(widget.id, size, scale);
      final cached = _cache[key];
      if (cached != null) {
        _use(key, cached);
      } else {
        _want(key, size, scale);
      }
      final image = _imageKey == key ? _image : null;
      return CustomPaint(
        size: size,
        painter: image != null
            ? _ImagePainter(image, widget.overflow)
            : _LivePainter(widget.painter, widget.id),
      );
    });
  }
}

class _ImagePainter extends CustomPainter {
  final ui.Image image;
  final EdgeInsets overflow;

  _ImagePainter(this.image, this.overflow);

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(
        0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromLTWH(-overflow.left, -overflow.top,
        size.width + overflow.horizontal, size.height + overflow.vertical);
    canvas.drawImageRect(
        image, src, dst, Paint()..filterQuality = FilterQuality.low);
  }

  @override
  bool shouldRepaint(_ImagePainter old) =>
      !identical(old.image, image) || old.overflow != overflow;
}

class _LivePainter extends CustomPainter {
  final BakedPainter painter;
  final String id;

  _LivePainter(this.painter, this.id);

  @override
  void paint(Canvas canvas, Size size) => painter(canvas, size);

  @override
  bool shouldRepaint(_LivePainter old) => old.id != id;
}
