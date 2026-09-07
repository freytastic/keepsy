import 'dart:typed_data';

import 'package:keepsy/domain/upload/upload_coordinator.dart';
import 'package:keepsy/domain/upload/upload_item.dart';
import 'package:keepsy/domain/upload/upload_ports.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';
import 'package:keepsy/ui/providers/upload_queue_model.dart';

// Idle queue for widget tests that only require the provider
class _NoSources implements PickedSourceStore {
  @override
  Future<Uint8List> read(String path) async => Uint8List(0);
  @override
  Future<void> discard(String path) async {}
}

class _NoPreparer implements MediaPreparer {
  @override
  Future<int> latestEpoch(String albumId) async => 0;
  @override
  Future<UploadEnvelope> prepare({
    required String albumId,
    required MediaId mediaId,
    required Uint8List plaintext,
    required String mimeType,
  }) =>
      throw UnimplementedError();
}

class _NoUploader implements StagedUploader {
  @override
  Future<Reservation> reserve(String a, UploadEnvelope e) =>
      throw UnimplementedError();
  @override
  Future<void> putFile(String a, Reservation r, UploadEnvelope e,
          {required ProgressSink onBytes, required CancelToken cancel}) =>
      throw UnimplementedError();
  @override
  Future<void> putThumb(String a, Reservation r, UploadEnvelope e,
          {required ProgressSink onBytes, required CancelToken cancel}) =>
      throw UnimplementedError();
  @override
  Future<int> confirm(String a, MediaId m) => throw UnimplementedError();
  @override
  Future<bool> abort(String a, MediaId m) async => true;
}

class _NoSink implements UploadSink {
  @override
  void onPrepared(String a, MediaId m, Uint8List? t) {}
  @override
  Future<void> seed(String a, UploadEnvelope e) async {}
  @override
  Future<void> onBatchSettled(String a) async {}
}

UploadQueueModel idleUploadQueue() => UploadQueueModel(UploadCoordinator(
      sources: _NoSources(),
      preparer: _NoPreparer(),
      uploader: _NoUploader(),
      sink: _NoSink(),
    ));
