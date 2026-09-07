import 'dart:io';

import 'package:flutter/material.dart';
import 'package:keepsy/domain/upload/upload_item.dart';
import 'package:keepsy/domain/upload/upload_snapshot.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

// Renders a picked file until its cleaned preview is ready
class UploadTile extends StatelessWidget {
  final UploadItemView item;
  final UploadQueueModel model;
  final VoidCallback? onRetry;

  const UploadTile({
    super.key,
    required this.item,
    required this.model,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final failed = item.phase == UploadPhase.failed;
    // Undecodable bytes are not retryable
    final canRetry = failed && (item.failure?.retryable ?? false);
    return GestureDetector(
      onTap: canRetry ? onRetry : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Warm.wellEmpty),
          Opacity(opacity: failed ? 0.35 : 0.62, child: _image()),
          if (failed)
            Center(
              child: Icon(
                canRetry ? Icons.refresh_rounded : Icons.block_outlined,
                size: 22,
                color: Warm.ink,
              ),
            )
          else
            Positioned(
              right: 5,
              bottom: 5,
              child: _Ring(value: item.fraction),
            ),
        ],
      ),
    );
  }

  Widget _image() {
    final preview = model.preview(item.mediaId);
    if (preview != null) {
      return Image.memory(preview, fit: BoxFit.cover, gaplessPlayback: true);
    }
    final path = item.sourcePath;
    if (path != null) {
      return Image.file(File(path),
          fit: BoxFit.cover,
          cacheWidth: 640,
          errorBuilder: (_, __, ___) => const SizedBox.shrink());
    }
    return const SizedBox.shrink();
  }
}

class _Ring extends StatelessWidget {
  final double value;
  const _Ring({required this.value});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Warm.shadow(0.35), blurRadius: 2)],
        ),
        child: CircularProgressIndicator(
          value: value <= 0 ? null : value,
          strokeWidth: 2.4,
          backgroundColor: Colors.white24,
          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
        ),
      ),
    );
  }
}
