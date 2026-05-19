import 'package:flutter/material.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/widgets/encrypted_image.dart';

// Full resolution view. Uses EncryptedImage so the route fetches
// ?asset=file (not the thumb) : confirms the full file pipeline e2e
class PhotoViewerScreen extends StatelessWidget {
  final MediaRecord record;
  final AlbumKeyStore aks;
  final MediaApi media;

  const PhotoViewerScreen({
    super.key,
    required this.record,
    required this.aks,
    required this.media,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: EncryptedImage(
          record: record,
          aks: aks,
          media: media,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
