import 'package:flutter/material.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/widgets/encrypted_image.dart';

// Full resolution view. Uses EncryptedImage so the route fetches the file
// asset (not the thumb) and confirms the full file pipeline e2e
class PhotoViewerScreen extends StatelessWidget {
  final MediaRecord record;
  final MediaCacheManager cache;

  const PhotoViewerScreen({
    super.key,
    required this.record,
    required this.cache,
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
          cache: cache,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
