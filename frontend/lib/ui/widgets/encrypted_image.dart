import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/diagnostics/trace.dart';
import 'package:keepsy/e2ee/file_decryptor.dart';
import 'package:keepsy/e2ee/media_record.dart';

import 'decrypted_image_preview.dart';

// Decrypts fully before rendering so tampered files never reach the screen

class EncryptedImage extends StatefulWidget {
  final MediaRecord record;
  final MediaCacheManager cache;
  final BoxFit fit;
  final String? traceId;
  final VoidCallback? onFirstFrame;
  final int? cacheWidth;
  final int? cacheHeight;
  final ValueChanged<DecryptedImagePreview>? onReady;

  const EncryptedImage({
    super.key,
    required this.record,
    required this.cache,
    this.fit = BoxFit.cover,
    this.traceId,
    this.onFirstFrame,
    this.cacheWidth,
    this.cacheHeight,
    this.onReady,
  });

  @override
  State<EncryptedImage> createState() => _EncryptedImageState();
}

class _EncryptedImageState extends State<EncryptedImage> {
  Uint8List? _bytes;
  String? _error;
  bool _loading = true;
  TraceSpan? _toFrameSpan;
  bool _frameReported = false;
  late String _resolvedTraceId;
  DecryptedImagePreview? _preview;

  @override
  void initState() {
    super.initState();
    _resolvedTraceId = widget.traceId ?? Trace.newTraceId();
    _decrypt();
  }

  @override
  void didUpdateWidget(covariant EncryptedImage old) {
    super.didUpdateWidget(old);
    if (old.record.id != widget.record.id || old.traceId != widget.traceId) {
      _toFrameSpan?.fail('record_changed_before_frame');
      _toFrameSpan = null;
      _bytes = null;
      _error = null;
      _loading = true;
      _frameReported = false;
      _preview = null;
      _resolvedTraceId = widget.traceId ?? Trace.newTraceId();
      _decrypt();
    } else if (old.onReady != widget.onReady && _preview != null) {
      widget.onReady?.call(_preview!);
    }
  }

  Future<void> _decrypt() async {
    final requestedId = widget.record.id;
    _toFrameSpan = Trace.start('media.fullImageToFrame',
        traceId: _resolvedTraceId,
        fields: {
          'album': Trace.id(widget.record.albumId),
          'media': Trace.id(widget.record.id),
          'asset': 'file',
        });
    try {
      final pt = await Trace.withId(_resolvedTraceId,
          () => widget.cache.getDecrypted(widget.record, thumb: false));
      DecryptedImagePreview? preview;
      try {
        preview = await DecryptedImagePreview.inspect(pt);
      } catch (_) {}
      if (!mounted || widget.record.id != requestedId) return;
      setState(() {
        _bytes = pt;
        _loading = false;
      });
      if (preview != null) {
        _preview = preview;
        widget.onReady?.call(preview);
      }
    } on FileDecryptError catch (e) {
      // A tile rebound to another record owns _toFrameSpan now
      if (widget.record.id != requestedId) return;
      _toFrameSpan?.fail(e.reason);
      _toFrameSpan = null;
      if (!mounted) return;
      setState(() {
        _error = e.reason;
        _loading = false;
      });
    } catch (_) {
      if (widget.record.id != requestedId) return;
      _toFrameSpan?.fail('unexpected');
      _toFrameSpan = null;
      if (!mounted) return;
      setState(() {
        _error = 'unexpected';
        _loading = false;
      });
    }
  }

  void _reportFirstFrame(bool synchronouslyLoaded) {
    if (_frameReported) return;
    _frameReported = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _toFrameSpan?.end(fields: {'sync': synchronouslyLoaded});
      _toFrameSpan = null;
      widget.onFirstFrame?.call();
    });
  }

  @override
  void dispose() {
    _toFrameSpan?.fail('disposed_before_frame');
    _toFrameSpan = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Container(
        color: Colors.black12,
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_outlined, size: 28),
              const SizedBox(height: 4),
              Text(_error!,
                  style: const TextStyle(fontSize: 10),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    return Image.memory(
      _bytes!,
      fit: widget.fit,
      gaplessPlayback: true,
      cacheWidth: widget.cacheWidth,
      cacheHeight: widget.cacheHeight,
      frameBuilder: (context, child, frame, synchronouslyLoaded) {
        if (frame != null) _reportFirstFrame(synchronouslyLoaded);
        return child;
      },
    );
  }
}
