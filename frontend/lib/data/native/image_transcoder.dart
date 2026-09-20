import 'package:flutter/services.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';

const MethodChannel _channel = MethodChannel('keepsy/image');

// Only an explicit unavailable result may use the Dart fallback
const String _kUnavailable = 'E_UNAVAILABLE';

// Convert channel failures into typed photo outcomes
Future<TranscodeOutcome> transcodeToJpeg(Uint8List bytes) async {
  final Map<Object?, Object?>? out;
  try {
    out = await _channel.invokeMethod<Map<Object?, Object?>>(
        'transcodeToJpeg', bytes);
  } on MissingPluginException {
    return const TranscodeUnavailable();
  } on PlatformException catch (e) {
    if (e.code == _kUnavailable) return const TranscodeUnavailable();
    return TranscodeRejected(e.code);
  }
  if (out == null) return const TranscodeUnavailable();
  final jpeg = out['file'];
  final thumb = out['thumb'];
  final width = out['width'];
  final height = out['height'];
  if (jpeg is! Uint8List ||
      thumb is! Uint8List ||
      width is! int ||
      height is! int) {
    return const TranscodeRejected('malformed_result');
  }
  return TranscodeDone(TranscodedPhoto(
    jpeg: jpeg,
    thumb: thumb,
    width: width,
    height: height,
  ));
}

const ImageTranscoder platformImageTranscoder = transcodeToJpeg;
