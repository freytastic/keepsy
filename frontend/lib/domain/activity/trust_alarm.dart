import 'dart:convert';
import 'dart:typed_data';

import 'activity_event.dart';

// Persist before lighting the shelf dot; the album screen retains the alarm
// if this secondary record cannot be written
Future<void> recordTrustAlarm({
  required Future<void> Function(List<ActivityEvent> events) record,
  // Recompute from storage so a repeated alarm does not relight the dot
  required Future<void> Function() onRecorded,
  required String albumId,
  required String memberToken,
  required Uint8List newIkPub,
  required DateTime now,
}) async {
  try {
    await record([
      SafetyNumberChanged(
        // Keyed on the new key, so a later different key alarms again
        id: 'trust:$albumId:$memberToken:${base64Url.encode(newIkPub)}',
        albumId: albumId,
        at: now,
        peerToken: memberToken,
        presentedIk: newIkPub,
      ),
    ]);
  } catch (_) {
    return;
  }
  await onRecorded();
}
