import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/e2ee/file_decryptor.dart';
import 'package:keepsy/e2ee/media_record.dart';

// EncryptedImage : renders an encrypted photo through MediaCacheManager
// L1 (RAM) -> L2 (disk ciphertext) -> L3 (S3). The full decrypt completes
// before any pixel hits the screen , so a tamper surfaces as
// a clean error tile, never a half decrypted JPEG

class EncryptedImage extends StatefulWidget {
  final MediaRecord record;
  final MediaCacheManager cache;
  final BoxFit fit;

  const EncryptedImage({
    super.key,
    required this.record,
    required this.cache,
    this.fit = BoxFit.cover,
  });

  @override
  State<EncryptedImage> createState() => _EncryptedImageState();
}

class _EncryptedImageState extends State<EncryptedImage> {
  Uint8List? _bytes;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _decrypt();
  }

  @override
  void didUpdateWidget(covariant EncryptedImage old) {
    super.didUpdateWidget(old);
    if (old.record.id != widget.record.id) {
      _bytes = null;
      _error = null;
      _loading = true;
      _decrypt();
    }
  }

  Future<void> _decrypt() async {
    try {
      final pt = await widget.cache.getDecrypted(widget.record, thumb: false);
      if (!mounted) return;
      setState(() {
        _bytes = pt;
        _loading = false;
      });
    } on FileDecryptError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.reason;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'unexpected';
        _loading = false;
      });
    }
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
    return Image.memory(_bytes!, fit: widget.fit, gaplessPlayback: true);
  }
}
