import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

// Streams the transparent camera animation without decoding it all at once

const String _kAsset = 'lib/assets/onboarding/camera_stage.webp';

// The crop includes the photo fan, so these values centre the camera body
const double _kStageWidthFactor = 1.256;
const double _kStageLeftFactor = 0.054;
const double _kStageTopFactor = 0.084;
const double _kStageAspect = 1400 / 1014;

const double _kCameraXInImage = 0.3566;

const double _kStageTopFactorShrunk = 0.01;
const double _kStageShrunkScale = 0.5;
const Duration _kShrinkDuration = Duration(milliseconds: 280);
const Curve _kShrinkCurve = Curves.easeOutCubic;

class CameraStage extends StatefulWidget {
  const CameraStage({super.key, this.onComplete});

  final VoidCallback? onComplete;

  // Positions the crop around the camera body inside a full-screen Stack
  static Widget positioned(
    BuildContext context, {
    VoidCallback? onComplete,
    bool shrink = false,
    double shrunkScale = _kStageShrunkScale,
  }) {
    final size = MediaQuery.sizeOf(context);
    final width = size.width * _kStageWidthFactor;
    // viewPadding stays stable while the keyboard opens
    final topInset = MediaQuery.viewPaddingOf(context).top;
    return AnimatedPositioned(
      duration: _kShrinkDuration,
      curve: _kShrinkCurve,
      left: size.width * _kStageLeftFactor,
      top: topInset +
          size.height * (shrink ? _kStageTopFactorShrunk : _kStageTopFactor),
      width: width,
      height: width / _kStageAspect,
      child: AnimatedScale(
        duration: _kShrinkDuration,
        curve: _kShrinkCurve,
        // Scale around the camera, not the wider photo-fan crop
        alignment: Alignment(2 * _kCameraXInImage - 1, -1),
        scale: shrink ? shrunkScale : 1,
        child: CameraStage(onComplete: onComplete),
      ),
    );
  }

  // Reduces the keyboard-open scale when vertical space is tight
  static double shrunkScaleToFit(
    BuildContext context, {
    required double maxVisualBottom,
  }) {
    final size = MediaQuery.sizeOf(context);
    final top = MediaQuery.viewPaddingOf(context).top +
        size.height * _kStageTopFactorShrunk;
    final unscaledHeight = size.width * _kStageWidthFactor / _kStageAspect;
    if (unscaledHeight <= 0) return _kStageShrunkScale;
    return ((maxVisualBottom - top) / unscaledHeight)
        .clamp(0.0, _kStageShrunkScale)
        .toDouble();
  }

  static double shrunkVisualBottom(
    BuildContext context, {
    required double scale,
  }) {
    final size = MediaQuery.sizeOf(context);
    final top = MediaQuery.viewPaddingOf(context).top +
        size.height * _kStageTopFactorShrunk;
    final unscaledHeight = size.width * _kStageWidthFactor / _kStageAspect;
    return top + unscaledHeight * scale;
  }

  @override
  State<CameraStage> createState() => _CameraStageState();
}

class _CameraStageState extends State<CameraStage>
    with SingleTickerProviderStateMixin {
  ui.Codec? _codec;
  Ticker? _ticker;

  // Repaint only the image on each tick
  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);

  // Eight prefetched frames cover about 200 ms without excessive memory use
  static const int _kPrefetch = 8;
  final Queue<ui.FrameInfo> _ahead = Queue<ui.FrameInfo>();
  bool _decoding = false;
  int _pulled = 0;

  // Follow encoded durations and skip late frames instead of slowing playback
  int _decoded = -1;
  Duration _dueAt = Duration.zero;
  int _frameCount = 0;
  bool _done = false;

  int? _decodeWidth;

  @override
  void dispose() {
    _ticker?.dispose();
    _frame.value?.dispose();
    _frame.dispose();
    for (final frame in _ahead) {
      frame.image.dispose();
    }
    _codec?.dispose();
    super.dispose();
  }

  // Decode at paint size to keep memory proportional to the device
  Future<void> _load(int decodeWidth) async {
    _decodeWidth = decodeWidth;
    final data = await rootBundle.load(_kAsset);
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
      targetWidth: decodeWidth,
    );
    if (!mounted) {
      codec.dispose();
      return;
    }
    _codec = codec;
    _frameCount = codec.frameCount;

    // Paint once before starting the clock
    final first = await codec.getNextFrame();
    if (!mounted) {
      first.image.dispose();
      return;
    }
    _decoded = 0;
    _pulled = 0;
    _dueAt = _clampDuration(first.duration);
    _frame.value = first.image;
    unawaited(_decodeAhead());

    if (!mounted) return;
    // Reduced motion shows only the settled composition
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      await _advanceUntil(const Duration(days: 1));
      _finish();
      return;
    }
    _ticker = createTicker(_onTick)..start();
  }

  // The codec is sequential and cannot decode concurrently
  Future<void> _decodeAhead() async {
    final codec = _codec;
    if (codec == null || _decoding) return;
    _decoding = true;
    try {
      while (_ahead.length < _kPrefetch && _pulled < _frameCount - 1) {
        final next = await codec.getNextFrame();
        if (!mounted) {
          next.image.dispose();
          return;
        }
        _pulled++;
        _ahead.add(next);
      }
    } finally {
      _decoding = false;
    }
  }

  void _onTick(Duration elapsed) {
    if (_done || elapsed < _dueAt) return;
    _advance(elapsed);
  }

  // Drop ready frames when playback falls behind
  void _advance(Duration elapsed) {
    while (
        _ahead.isNotEmpty && _dueAt <= elapsed && _decoded < _frameCount - 1) {
      final next = _ahead.removeFirst();
      final previous = _frame.value;
      _frame.value = next.image;
      previous?.dispose();
      _decoded++;
      _dueAt += _clampDuration(next.duration);
      if (_decoded >= _frameCount - 1) {
        _finish();
        return;
      }
    }
    unawaited(_decodeAhead());
  }

  Future<void> _advanceUntil(Duration elapsed) async {
    final codec = _codec;
    if (codec == null) return;
    while (_decoded < _frameCount - 1) {
      final next =
          _ahead.isNotEmpty ? _ahead.removeFirst() : await codec.getNextFrame();
      if (!mounted) {
        next.image.dispose();
        return;
      }
      final previous = _frame.value;
      _frame.value = next.image;
      previous?.dispose();
      _decoded++;
    }
  }

  // Prevent malformed frame durations from stalling playback
  static Duration _clampDuration(Duration d) =>
      d > Duration.zero ? d : const Duration(milliseconds: 16);

  void _finish() {
    if (_done) return;
    _done = true;
    _ticker?.stop();
    widget.onComplete?.call();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_decodeWidth == null && constraints.maxWidth.isFinite) {
          final ratio = MediaQuery.devicePixelRatioOf(context);
          final width = (constraints.maxWidth * ratio).round();
          // Never decode above the asset's native width.
          _load(width.clamp(1, _kMasterWidth));
        }
        return RepaintBoundary(
          child: SizedBox.expand(
            child: ValueListenableBuilder<ui.Image?>(
              valueListenable: _frame,
              builder: (context, frame, _) => frame == null
                  ? const SizedBox.shrink()
                  : RawImage(
                      image: frame,
                      fit: BoxFit.contain,
                      // The frame is already decoded at paint size
                      filterQuality: FilterQuality.low,
                      isAntiAlias: true,
                    ),
            ),
          ),
        );
      },
    );
  }
}

// Keep in sync with tools/encode_camera_stage.py
const int _kMasterWidth = 1400;
