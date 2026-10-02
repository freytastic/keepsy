import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'trace.dart';

// Device comparison diagnostics. Runs only in tracing builds and adds nothing
// to the frame path otherwise
abstract class PerfProbe {
  static bool _started = false;

  static void start() {
    if (_started || !Trace.enabled) return;
    _started = true;
    Trace.event('app.main');
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
      Trace.event('app.firstFrame');
      _device();
      unawaited(_probeKeystore());
    }));
  }

  static void _device() {
    final display = PlatformDispatcher.instance.displays.firstOrNull;
    final view = PlatformDispatcher.instance.views.firstOrNull;
    Trace.event('device', fields: {
      'cores': Platform.numberOfProcessors,
      'hz': display?.refreshRate.toStringAsFixed(0),
      'dpr': view?.devicePixelRatio.toStringAsFixed(2),
      'px': view == null
          ? null
          : '${view.physicalSize.width.round()}x${view.physicalSize.height.round()}',
    });
  }

  // The wrap key exists only once onboarding has created it, so keep asking
  static Future<void> _probeKeystore() async {
    if (!Platform.isAndroid) return;
    const channel = MethodChannel('keepsy/keystore');
    for (var i = 0; i < 60; i++) {
      try {
        final r = await channel.invokeMethod<Map>('probe');
        if (r != null && r['initialized'] == true) {
          final loads = (r['loadMs'] as List).cast<num>();
          Trace.event('keystore.probe', fields: {
            'level': r['level'],
            'bytes': r['envelopeBytes'],
            'entries': r['entries'],
            'load_ms': loads.map((v) => v.toStringAsFixed(1)).join(','),
          });
          return;
        }
      } catch (e) {
        Trace.event('keystore.probe', fields: {'error': Trace.reasonOf(e)});
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 10));
    }
  }

  static void _onTimings(List<FrameTiming> timings) {
    if (timings.isEmpty) return;
    final hz =
        PlatformDispatcher.instance.displays.firstOrNull?.refreshRate ?? 60;
    final budgetUs = 1e6 / (hz <= 0 ? 60 : hz);
    final build = [for (final t in timings) t.buildDuration.inMicroseconds]
      ..sort();
    final raster = [for (final t in timings) t.rasterDuration.inMicroseconds]
      ..sort();
    final total = [for (final t in timings) t.totalSpan.inMicroseconds]..sort();
    Trace.event('frames', fields: {
      'n': timings.length,
      'late': total.where((us) => us > budgetUs).length,
      'budget': _ms(budgetUs.round()),
      'build50': _ms(_pct(build, .5)),
      'build90': _ms(_pct(build, .9)),
      'buildMax': _ms(build.last),
      'raster50': _ms(_pct(raster, .5)),
      'raster90': _ms(_pct(raster, .9)),
      'rasterMax': _ms(raster.last),
      'total90': _ms(_pct(total, .9)),
    });
  }

  static int _pct(List<int> sorted, double p) =>
      sorted[((sorted.length - 1) * p).round()];

  static String _ms(int us) => (us / 1000).toStringAsFixed(1);
}
