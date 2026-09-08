import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/diagnostics/trace.dart';
import 'package:keepsy/e2ee/file_decryptor.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/widgets/encrypted_image.dart';

import 'decrypted_image_preview.dart';

// Uses the encrypted full file only when no thumbnail exists

class EncryptedThumbnail extends StatefulWidget {
  final MediaRecord record;
  final MediaCacheManager cache;
  final BoxFit fit;
  final String? traceId;
  final VoidCallback? onFirstFrame;
  final ValueChanged<DecryptedImagePreview>? onReady;

  const EncryptedThumbnail({
    super.key,
    required this.record,
    required this.cache,
    this.fit = BoxFit.cover,
    this.traceId,
    this.onFirstFrame,
    this.onReady,
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
  DecryptedImagePreview? _preview;

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
      _preview = null;
      _resolvedTraceId = widget.traceId ?? Trace.newTraceId();
      if (widget.record.hasThumb) _decrypt();
    } else if (old.onReady != widget.onReady && _preview != null) {
      widget.onReady?.call(_preview!);
    }
  }

  Future<void> _decrypt() async {
    final requestedId = widget.record.id;
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
    if (!widget.record.hasThumb) {
      // Legacy rows and videos use the full encrypted file
      return EncryptedImage(
        record: widget.record,
        cache: widget.cache,
        fit: widget.fit,
        traceId: _resolvedTraceId,
        onFirstFrame: widget.onFirstFrame,
        onReady: widget.onReady,
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
