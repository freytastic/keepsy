import 'dart:async';

import 'package:flutter/material.dart';
import 'package:keepsy/domain/upload/upload_item.dart';
import 'package:keepsy/domain/upload/upload_snapshot.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:provider/provider.dart';

import 'upload_copy.dart';
import 'warm_button.dart';

// Closing the sheet does not cancel its app scoped queue
class UploadSheet extends StatefulWidget {
  final String batchId;
  final VoidCallback? onPickMore;
  // Lets the screen refresh before overlays are dismissed
  final Future<void> Function(String batchId)? onDismiss;

  const UploadSheet({
    super.key,
    required this.batchId,
    this.onPickMore,
    this.onDismiss,
  });

  static Future<void> show(
    BuildContext context, {
    required String batchId,
    VoidCallback? onPickMore,
    Future<void> Function(String batchId)? onDismiss,
  }) {
    // Claim before pushing so settlement cannot sweep the batch first
    final model = context.read<UploadQueueModel>();
    model.beginPresenting(batchId);
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Warm.paper,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => UploadSheet(
          batchId: batchId, onPickMore: onPickMore, onDismiss: onDismiss),
    ).whenComplete(() => model.endPresenting(batchId));
  }

  @override
  State<UploadSheet> createState() => _UploadSheetState();
}

class _UploadSheetState extends State<UploadSheet> {
  UploadQueueModel? _model;
  bool _busy = false;
  bool _closing = false;
  bool _closeArmed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<UploadQueueModel>();
    if (identical(_model, next)) return;
    _model?.endPresenting(widget.batchId);
    _model = next;
    next.beginPresenting(widget.batchId);
  }

  @override
  void dispose() {
    _model?.endPresenting(widget.batchId);
    super.dispose();
  }

  // Close only this sheet after it becomes the current route
  void _close() {
    if (_closing) return;
    final route = ModalRoute.of(context);
    if (route == null) return;
    if (!route.isCurrent) {
      _armClose();
      return;
    }
    _closing = true;
    Navigator.of(context).pop();
  }

  // Re-arm on a future frame without scheduling a loop
  void _armClose() {
    if (_closing || _closeArmed) return;
    _closeArmed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _closeArmed = false;
      if (mounted) _close();
    });
  }

  Future<void> _guarded(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<UploadQueueModel>();
    final batchId = widget.batchId;
    final onPickMore = widget.onPickMore;
    final batch = model.state.batch(batchId);
    // Close when the batch was removed elsewhere
    if (batch == null) {
      _armClose();
      return const SizedBox.shrink();
    }
    final albumName = context.watch<AppState>().albumDisplayName(batch.albumId);

    final unprocessable = batch.unprocessableCount;
    final retryable = batch.retryableCount;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Warm.inkGhost,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(sheetTitle(batch, albumName),
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Warm.ink)),
            const SizedBox(height: 18),
            _Readout(batch: batch),
            const SizedBox(height: 16),
            _Track(value: batch.fraction),
            if (pauseNote(batch) != null) ...[
              const SizedBox(height: 12),
              Text(pauseNote(batch)!,
                  style: const TextStyle(fontSize: 12.5, color: Warm.inkSoft)),
            ],
            if (unprocessable > 0) ...[
              const SizedBox(height: 16),
              _Notice(
                headline: unprocessableHeadline(unprocessable),
                body: unprocessableBody(unprocessable),
                actionLabel:
                    onPickMore == null ? null : 'Pick different photos',
                onAction: () {
                  _close();
                  onPickMore?.call();
                },
              ),
            ],
            if (retryable > 0) ...[
              const SizedBox(height: 12),
              _Notice(
                headline: failureHeadline(retryable),
                body: failureBody(retryable),
                actionLabel: 'Try again',
                onAction: _busy ? null : () => model.retryFailed(batchId),
                // Removing the final item closes through the build guard
                secondaryLabel: 'Remove them',
                onSecondary: _busy
                    ? null
                    : () => _guarded(() => model.removeFailed(batchId)),
              ),
            ],
            // Done would discard sources still needed for retry
            if (batch.settled && retryable == 0) ...[
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: WarmButton(
                  label: 'Done',
                  // Keep overlays until the album listing replaces them
                  onTap: () {
                    model.requestDismiss(batchId);
                    final refresh = widget.onDismiss;
                    if (refresh != null) unawaited(refresh(batchId));
                    _close();
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Track extends StatelessWidget {
  final double value;
  const _Track({required this.value});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: value,
        minHeight: 5,
        backgroundColor: Warm.wellEmpty,
        valueColor: const AlwaysStoppedAnimation<Color>(Warm.ctaTop),
      ),
    );
  }
}

class _Readout extends StatelessWidget {
  final UploadBatchSnapshot batch;
  const _Readout({required this.batch});

  @override
  Widget build(BuildContext context) {
    final active = batch.items.firstWhere(
      (i) => i.phase != UploadPhase.done && i.phase != UploadPhase.failed,
      orElse: () => batch.items.last,
    );
    final rate = formatRate(batch.bytesPerSecond);
    final eta = formatEta(batch.eta);
    final sent = '${formatBytes(batch.logicalBytesSent)} sent';

    // Show the phase while no bytes are moving
    final lead = batch.settled
        ? sent
        : rate.isEmpty
            ? phaseLabel(active.phase)
            : rate;
    final trail = batch.settled
        ? null
        : eta.isEmpty
            ? sent
            : '$eta  ·  $sent';

    return Row(
      children: [
        _CountRing(
          value: batch.fraction,
          done: batch.doneCount,
          total: batch.totalCount,
          settled: batch.settled,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                lead,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: Warm.ink),
              ),
              if (trail != null) ...[
                const SizedBox(height: 3),
                Text(
                  trail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: Warm.inkSoft),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CountRing extends StatelessWidget {
  final double value;
  final int done;
  final int total;
  final bool settled;

  const _CountRing({
    required this.value,
    required this.done,
    required this.total,
    required this.settled,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      height: 46,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: value <= 0 && !settled ? null : value,
              strokeWidth: 3,
              backgroundColor: Warm.wellEmpty,
              valueColor: const AlwaysStoppedAnimation<Color>(Warm.ctaTop),
            ),
          ),
          Text(
            '$done/$total',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Warm.ink,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final String headline;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  const _Notice({
    required this.headline,
    required this.body,
    required this.actionLabel,
    required this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: Warm.warn.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(headline,
              style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: Warm.ink)),
          const SizedBox(height: 4),
          Text(body,
              style: const TextStyle(fontSize: 12.5, color: Warm.inkSoft)),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (secondaryLabel != null)
                TextButton(
                  onPressed: onSecondary,
                  child: Text(secondaryLabel!,
                      style: const TextStyle(color: Warm.inkSoft)),
                ),
              if (actionLabel != null)
                TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ),
        ],
      ),
    );
  }
}
