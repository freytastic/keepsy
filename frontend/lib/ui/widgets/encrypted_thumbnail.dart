import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/diagnostics/trace.dart';
import 'package:keepsy/e2ee/file_decryptor.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/widgets/encrypted_image.dart';

// EncryptedThumbnail : routes through MediaCacheManager for the thumb cipher
// Falls through to the full EncryptedImage when the row has no thumb (legacy
// rows or videos). Same rule : full decrypt before any pixel
// hits screen

class EncryptedThumbnail extends StatefulWidget {
  final MediaRecord record;
  final MediaCacheManager cache;
  final BoxFit fit;
  final String? traceId;
  final VoidCallback? onFirstFrame;

  const EncryptedThumbnail({
    super.key,
    required this.record,
    required this.cache,
    this.fit = BoxFit.cover,
    this.traceId,
    this.onFirstFrame,
  });

  @override
  State<EncryptedThumbnail> createState() => _EncryptedThumbnailState();
}

class _EncryptedThumbnailState extends State<EncryptedThumbnail> {
  Uint8List? _bytes;
  String? _error;
  bool _loading = true;
  TraceSpan? _toFrameSpan;
  bool _frameReported = false;
  late String _resolvedTraceId;

  @override
  void initState() {
    super.initState();
    _resolvedTraceId = widget.traceId ?? Trace.newTraceId();
    if (widget.record.hasThumb) {
      _decrypt();
    } else {
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(covariant EncryptedThumbnail old) {
    super.didUpdateWidget(old);
    if (old.record.id != widget.record.id || old.traceId != widget.traceId) {
      _toFrameSpan?.fail('record_changed_before_frame');
      _toFrameSpan = null;
      _bytes = null;
      _error = null;
      _loading = widget.record.hasThumb;
      _frameReported = false;
      _resolvedTraceId = widget.traceId ?? Trace.newTraceId();
      if (widget.record.hasThumb) _decrypt();
    }
  }

  Future<void> _decrypt() async {
    _toFrameSpan = Trace.start('media.thumbnailToFrame',
        traceId: _resolvedTraceId,
        fields: {
          'album': Trace.id(widget.record.albumId),
          'media': Trace.id(widget.record.id),
          'asset': 'thumb',
        });
    try {
      final pt = await Trace.withId(_resolvedTraceId,
          () => widget.cache.getDecrypted(widget.record, thumb: true));
      if (!mounted) return;
      setState(() {
        _bytes = pt;
        _loading = false;
      });
    } on FileDecryptError catch (e) {
      _toFrameSpan?.fail(e.reason);
      _toFrameSpan = null;
      if (!mounted) return;
      setState(() {
        _error = e.reason;
        _loading = false;
      });
    } catch (_) {
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
    if (!widget.record.hasThumb) {
      // row or video : fall back to full file render (cache path is identical)
      return EncryptedImage(
        record: widget.record,
        cache: widget.cache,
        fit: widget.fit,
        traceId: _resolvedTraceId,
        onFirstFrame: widget.onFirstFrame,
      );
    }
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Container(
        color: Colors.black12,
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image_outlined, size: 20),
      );
    }
    return Image.memory(
      _bytes!,
      fit: widget.fit,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, synchronouslyLoaded) {
        if (frame != null) _reportFirstFrame(synchronouslyLoaded);
        return child;
      },
    );
  }
}
