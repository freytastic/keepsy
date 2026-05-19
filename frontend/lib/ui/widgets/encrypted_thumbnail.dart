import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_decryptor.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/widgets/encrypted_image.dart';

// EncryptedThumbnail : renders the thumb cipher. Falls through to the
// full EncryptedImage when the row predates or is a video (no
// thumb minted at upload time). 20 KB AES-GCM blob, single MethodChannel
// trip for MK, then full decrypt before any pixel hits screen (same P5
// rule as EncryptedImage)

class EncryptedThumbnail extends StatefulWidget {
  final MediaRecord record;
  final AlbumKeyStore aks;
  final MediaApi media;
  final BoxFit fit;

  const EncryptedThumbnail({
    super.key,
    required this.record,
    required this.aks,
    required this.media,
    this.fit = BoxFit.cover,
  });

  @override
  State<EncryptedThumbnail> createState() => _EncryptedThumbnailState();
}

class _EncryptedThumbnailState extends State<EncryptedThumbnail> {
  Uint8List? _bytes;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.record.hasThumb) {
      _decrypt();
    } else {
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(covariant EncryptedThumbnail old) {
    super.didUpdateWidget(old);
    if (old.record.id != widget.record.id) {
      _bytes = null;
      _error = null;
      _loading = widget.record.hasThumb;
      if (widget.record.hasThumb) _decrypt();
    }
  }

  Future<void> _decrypt() async {
    try {
      final url = await widget.media.requestDownloadURL(
          widget.record.albumId, widget.record.id,
          asset: 'thumb');
      final pt = await FileDecryptor.downloadAndDecryptThumb(
        aks: widget.aks,
        record: widget.record,
        presignedUrl: url,
        download: widget.media.downloadCiphertext,
      );
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
    if (!widget.record.hasThumb) {
      // row or video : fall back to the full file render. Slower i know
      // but functionally identical so the grid never shows a blank tile
      return EncryptedImage(
        record: widget.record,
        aks: widget.aks,
        media: widget.media,
        fit: widget.fit,
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
    return Image.memory(_bytes!, fit: widget.fit, gaplessPlayback: true);
  }
}
