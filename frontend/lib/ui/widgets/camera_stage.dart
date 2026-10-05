import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:keepsy/diagnostics/trace.dart';

const String _kFullAsset = 'lib/assets/onboarding/camera_stage.webp';
const String _kLiteAsset = 'lib/assets/onboarding/camera_stage_lite.webp';
const String _kStillAsset = 'lib/assets/onboarding/camera_stage_still.webp';
// Full-width probe from master frames 119-123
const String _kProbeAsset = 'lib/assets/onboarding/camera_stage_probe.webp';

// Keep native widths aligned with the asset encoders
const int _kMasterWidth = 1400;
const int _kLiteWidth = 720;

// Build override: full, lite or still
const String _kForcedTier = String.fromEnvironment('KEEPSY_STAGE_TIER');

// Measured late frames cost about 1.45x the average
// A 1.25x budget limit leaves average decode time near 0.85x the budget
const int _kProbeFrames = 4;
const double _kLateFitShare = 1.25;

// Bank cheap opening frames to cover the slower end of the lite clip
const int _kBufferBytes = 48 << 20;
const int _kMinDepth = 4;
const int _kMaxDepth = 40;
const int _kStartFrames = 4;
const Duration _kGiveUpLag = Duration(milliseconds: 700);

// Offsets center the camera within the wider photo fan
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

  static Widget positioned(
    BuildContext context, {
    VoidCallback? onComplete,
    bool shrink = false,
    double shrunkScale = _kStageShrunkScale,
  }) {
    final size = MediaQuery.sizeOf(context);
    final width = size.width * _kStageWidthFactor;
    // viewPadding is stable while the keyboard opens
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
        // Scale around the camera rather than the photo fan
        alignment: Alignment(2 * _kCameraXInImage - 1, -1),
        scale: shrink ? shrunkScale : 1,
        child: CameraStage(onComplete: onComplete),
      ),
    );
  }

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

  static void prewarm() {
    final view = ui.PlatformDispatcher.instance.implicitView;
    if (view == null) return;
    if (ui.PlatformDispatcher.instance.accessibilityFeatures.disableAnimations) {
      return;
    }
    _StagePrep.start(_paintWidth(view.physicalSize.width * _kStageWidthFactor));
  }

  @override
  State<CameraStage> createState() => _CameraStageState();
}

class _CameraStageState extends State<CameraStage>
    with SingleTickerProviderStateMixin {
  _Clip? _clip;
  Ticker? _ticker;
  int? _decodeWidth;

  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);

  int _decoded = -1;
  Duration _dueAt = Duration.zero;
  Duration _elapsed = Duration.zero;
  bool _done = false;
  bool _settling = false;

  int _shown = 0;
  int _skipped = 0;
  int _starved = 0;

  @override
  void dispose() {
    _ticker?.dispose();
    _frame.value?.dispose();
    _frame.dispose();
    _clip?.dispose();
    super.dispose();
  }

  Future<void> _load(int width) async {
    _decodeWidth = width;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _StagePrep.discard();
      await _settle();
      return;
    }
    final clip = await _StagePrep.take(width);
    if (!mounted) {
      clip?.dispose();
      return;
    }
    final first = clip?.takeFirst();
    if (clip == null || first == null) {
      clip?.dispose();
      await _settle();
      return;
    }
    _clip = clip;
    _decoded = 0;
    _shown = 1;
    _dueAt = _clampDuration(first.duration);
    _frame.value = first.image;
    unawaited(clip.fill(clip.depth));
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    final clip = _clip;
    if (_done || clip == null || elapsed < _dueAt) return;
    if (clip.ahead.isEmpty) {
      _starved++;
      if (elapsed - _dueAt > _kGiveUpLag) {
        unawaited(_settle());
      } else {
        unawaited(clip.fill(clip.depth));
      }
      return;
    }
    var advanced = 0;
    while (clip.ahead.isNotEmpty &&
        _dueAt <= elapsed &&
        _decoded < clip.frameCount - 1) {
      final next = clip.ahead.removeFirst();
      final previous = _frame.value;
      _frame.value = next.image;
      previous?.dispose();
      _decoded++;
      advanced++;
      if (_decoded >= clip.frameCount - 1) {
        _shown++;
        _skipped += advanced - 1;
        _finish(intended: _dueAt);
        return;
      }
      _dueAt += _clampDuration(next.duration);
    }
    if (advanced > 0) {
      _shown++;
      _skipped += advanced - 1;
    }
    unawaited(clip.fill(clip.depth));
  }

  // Keep the current frame while the still decodes
  Future<void> _settle() async {
    if (_settling || _done) return;
    _settling = true;
    _ticker?.stop();
    final still = await _decodeStill(_decodeWidth ?? _kMasterWidth);
    if (!mounted) {
      still?.dispose();
      return;
    }
    if (still != null) {
      final previous = _frame.value;
      _frame.value = still;
      previous?.dispose();
    }
    _finish(intended: _dueAt, settled: true);
  }

  static Duration _clampDuration(Duration d) =>
      d > Duration.zero ? d : const Duration(milliseconds: 16);

  void _finish({required Duration intended, bool settled = false}) {
    if (_done) return;
    _done = true;
    _ticker?.stop();
    final clip = _clip;
    if (clip != null) {
      final decode = [for (final us in clip.decodeUs) us ~/ 1000]..sort();
      int pct(double q) =>
          decode.isEmpty ? 0 : decode[((decode.length - 1) * q).round()];
      final wall = _elapsed.inMilliseconds;
      Trace.event('onboarding.clip', fields: {
        'tier': clip.tier.name,
        'w': clip.width,
        'frames': clip.frameCount,
        'intended_ms': intended.inMilliseconds,
        'wall_ms': wall,
        'speed': wall > 0
            ? (intended.inMilliseconds / wall).toStringAsFixed(2)
            : '-',
        'shown': _shown,
        'skipped': _skipped,
        'starved': _starved,
        'settled': settled,
        'depth': clip.depth,
        'decode50': pct(0.5),
        'decode90': pct(0.9),
        'decodeMax': decode.isEmpty ? 0 : decode.last,
      });
      clip.dispose();
      _clip = null;
    }
    widget.onComplete?.call();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_decodeWidth == null && constraints.maxWidth.isFinite) {
          final ratio = MediaQuery.devicePixelRatioOf(context);
          _load(_paintWidth(constraints.maxWidth * ratio));
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

int _paintWidth(double physicalWidth) =>
    physicalWidth.round().clamp(1, _kMasterWidth);

enum StageTier { full, lite }

// Use the fastest probe sample to limit interference from transient contention
@visibleForTesting
StageTier chooseStageTier(List<int> lateDecodeUs, Duration frameBudget) {
  if (lateDecodeUs.isEmpty) return StageTier.full;
  final late = lateDecodeUs.reduce((a, b) => a < b ? a : b);
  return late <= frameBudget.inMicroseconds * _kLateFitShare
      ? StageTier.full
      : StageTier.lite;
}

class _Clip {
  _Clip(this.tier, this.codec, this.width);

  final StageTier tier;
  final ui.Codec codec;
  final int width;
  final Queue<ui.FrameInfo> ahead = Queue<ui.FrameInfo>();
  final List<int> decodeUs = [];
  ui.FrameInfo? _first;
  int _pulled = 0;
  bool _filling = false;
  bool _disposed = false;
  int depth = _kMinDepth;

  int get frameCount => codec.frameCount;
  bool get exhausted => _pulled >= frameCount;

  ui.FrameInfo? takeFirst() {
    final first = _first;
    _first = null;
    return first;
  }

  Future<ui.FrameInfo> _pull() async {
    final watch = Stopwatch()..start();
    final frame = await codec.getNextFrame();
    decodeUs.add(watch.elapsedMicroseconds);
    _pulled++;
    return frame;
  }

  Future<void> start() async {
    final first = await _pull();
    if (_disposed) {
      first.image.dispose();
      return;
    }
    _first = first;
    final bytes = first.image.width * first.image.height * 4;
    depth = (_kBufferBytes ~/ bytes).clamp(_kMinDepth, _kMaxDepth);
  }

  // Only one fill loop may advance the codec
  Future<void> fill(int target) async {
    if (_filling) return;
    _filling = true;
    try {
      while (!_disposed && ahead.length < target && !exhausted) {
        final frame = await _pull();
        if (_disposed) {
          frame.image.dispose();
          return;
        }
        ahead.add(frame);
      }
    } catch (_) {
    } finally {
      _filling = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _first?.image.dispose();
    _first = null;
    for (final frame in ahead) {
      frame.image.dispose();
    }
    ahead.clear();
    codec.dispose();
  }
}

abstract class _StagePrep {
  static int? _width;
  static Future<_Clip?>? _pending;

  static void start(int width) {
    if (_pending != null && _width == width) return;
    discard();
    _width = width;
    _pending = _prepare(width);
  }

  static Future<_Clip?> take(int width) {
    start(width);
    final pending = _pending!;
    _pending = null;
    _width = null;
    return pending;
  }

  static void discard() {
    final pending = _pending;
    _pending = null;
    _width = null;
    pending?.then((clip) => clip?.dispose());
  }
}

Future<_Clip?> _prepare(int paintWidth) async {
  final span = Trace.start('onboarding.load', fields: {'w': paintWidth});
  _Clip? clip;
  try {
    final forced = _forcedTier();
    if (_kForcedTier == 'still') {
      span.end(fields: {'tier': 'still'});
      return null;
    }
    var tier = forced;
    if (tier == null) {
      final probe = await _probeLate(paintWidth);
      tier = chooseStageTier(probe.decodeUs, probe.budget);
      Trace.event('onboarding.tier', fields: {
        'tier': tier.name,
        'probe': probe.decodeUs
            .map((us) => (us / 1000).toStringAsFixed(1))
            .join(','),
        'budget': probe.budget.inMilliseconds,
      });
    }
    clip = await _openClip(tier, paintWidth);
    await clip.fill(_kStartFrames);
    span.end(fields: {
      'tier': clip.tier.name,
      'frames': clip.frameCount,
      'depth': clip.depth,
    });
    return clip;
  } catch (error) {
    clip?.dispose();
    span.fail(Trace.reasonOf(error));
    return null;
  }
}

// Skip the first probe frame to exclude initial decoder setup
Future<({List<int> decodeUs, Duration budget})> _probeLate(
    int paintWidth) async {
  final data = await rootBundle.load(_kProbeAsset);
  final codec = await ui.instantiateImageCodec(
    data.buffer.asUint8List(),
    targetWidth: paintWidth < _kMasterWidth ? paintWidth : null,
  );
  try {
    final first = await codec.getNextFrame();
    final d = first.duration;
    final budget = d > Duration.zero ? d : const Duration(milliseconds: 25);
    first.image.dispose();
    final decodeUs = <int>[];
    final limit = budget.inMicroseconds * _kLateFitShare;
    while (decodeUs.length < _kProbeFrames &&
        decodeUs.length < codec.frameCount - 1) {
      final watch = Stopwatch()..start();
      final frame = await codec.getNextFrame();
      decodeUs.add(watch.elapsedMicroseconds);
      frame.image.dispose();
      if (decodeUs.last > 2 * limit) break;
    }
    return (decodeUs: decodeUs, budget: budget);
  } finally {
    codec.dispose();
  }
}

StageTier? _forcedTier() => switch (_kForcedTier) {
      'full' => StageTier.full,
      'lite' => StageTier.lite,
      _ => null,
    };

Future<_Clip> _openClip(StageTier tier, int paintWidth) async {
  final lite = tier == StageTier.lite;
  final native = lite ? _kLiteWidth : _kMasterWidth;
  final data = await rootBundle.load(lite ? _kLiteAsset : _kFullAsset);
  final codec = await ui.instantiateImageCodec(
    data.buffer.asUint8List(),
    targetWidth: paintWidth < native ? paintWidth : null,
  );
  final clip = _Clip(tier, codec, paintWidth < native ? paintWidth : native);
  await clip.start();
  return clip;
}

Future<ui.Image?> _decodeStill(int paintWidth) async {
  try {
    final data = await rootBundle.load(_kStillAsset);
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
      targetWidth: paintWidth < _kMasterWidth ? paintWidth : null,
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  }
}
