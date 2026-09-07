import 'package:flutter/material.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';
import 'package:provider/provider.dart';

import 'upload_copy.dart';
import 'upload_sheet.dart';

// Keeps app scoped uploads reachable outside the album screen
class UploadPill extends StatelessWidget {
  const UploadPill({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.watch<UploadQueueModel>();
    // Failed batches stay reachable for retry or removal
    final live = model.state.batches
        .where((b) => !b.settled || b.failedCount > 0)
        .toList();
    if (live.isEmpty) return const SizedBox.shrink();
    final batch = live.last;
    final failed = batch.settled;

    return PressableScale(
      onTap: () => UploadSheet.show(context, batchId: batch.batchId),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
        decoration: BoxDecoration(
          color: Warm.paper,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Warm.shadow(0.10), blurRadius: 12)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failed)
              const Icon(Icons.error_outline, size: 16, color: Warm.warn)
            else
              SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                  value: batch.fraction <= 0 ? null : batch.fraction,
                  strokeWidth: 2,
                  backgroundColor: Warm.wellEmpty,
                  valueColor: const AlwaysStoppedAnimation<Color>(Warm.ctaTop),
                ),
              ),
            const SizedBox(width: 9),
            Text(
              failed
                  ? '${batch.failedCount} didn’t send'
                  : 'Adding ${batch.doneCount + batch.failedCount + 1}'
                      ' of ${batch.totalCount}',
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600, color: Warm.ink),
            ),
            if (!failed && formatRate(batch.bytesPerSecond).isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(formatRate(batch.bytesPerSecond),
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Warm.inkSoft)),
            ],
          ],
        ),
      ),
    );
  }
}
