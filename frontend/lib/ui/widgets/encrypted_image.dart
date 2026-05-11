import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_decryptor.dart';

// EncryptedImage : renders a §5.1 encrypted photo. The full decrypt happens
// before any pixel hits the screen (P5 / §5.2 DoD) : on tamper the user
// sees a clean error tile, never a half decrypted JPEG. Plaintext bytes are
// held in this widget's State only : not cached to disk in §5.2 (the §2.13
// at rest plaintext cache is a §5.x follow up)

class EncryptedImage extends StatefulWidget {
  final MediaRecord record;
  final AlbumKeyStore aks;
  final MediaApi media;
  final BoxFit fit;

  const EncryptedImage({
    super.key,
    required this.record,
    required this.aks,
    required this.media,
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
      final url = await widget.media
          .requestDownloadURL(widget.record.albumId, widget.record.id);
      final pt = await FileDecryptor.downloadAndDecrypt(
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
    } catch (e) {
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
