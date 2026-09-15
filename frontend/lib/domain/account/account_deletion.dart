import 'dart:convert';
import 'dart:typed_data';

import 'package:keepsy/data/api/account_api.dart';
import 'package:keepsy/data/api/api_error.dart';

class DeletionPlan {
  final List<DeletionAlbum> albums;
  const DeletionPlan(this.albums);

  List<DeletionAlbum> get shared => [
        for (final a in albums)
          if (a.outcome == DeletionOutcome.deleteShared) a
      ];

  List<DeletionAlbum> get solo => [
        for (final a in albums)
          if (a.outcome == DeletionOutcome.deleteAlbum) a
      ];

  List<DeletionAlbum> get left => [
        for (final a in albums)
          if (a.outcome == DeletionOutcome.leave) a
      ];
}

class PendingDeletion {
  final String receipt;
  final List<String> sharedAlbumIds;
  final bool accepted;

  const PendingDeletion({
    required this.receipt,
    required this.sharedAlbumIds,
    required this.accepted,
  });

  PendingDeletion markAccepted() => PendingDeletion(
      receipt: receipt, sharedAlbumIds: sharedAlbumIds, accepted: true);

  Map<String, dynamic> toJson() => {
        'receipt': receipt,
        'shared_album_ids': sharedAlbumIds,
        'accepted': accepted,
      };

  static PendingDeletion? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final receipt = json['receipt'];
    final shared = json['shared_album_ids'];
    final accepted = json['accepted'];
    if (receipt is! String || shared is! List || accepted is! bool) return null;
    return PendingDeletion(
      receipt: receipt,
      sharedAlbumIds: shared.whereType<String>().toList(),
      accepted: accepted,
    );
  }
}

// The marker must survive restarts and the wipe until verification succeeds
abstract class DeletionMarkerStore {
  Future<PendingDeletion?> read();
  Future<void> write(PendingDeletion pending);
  Future<void> clear();
}

enum DeletionResult {
  deleted,
  planChanged,
  notAccepted,
  // The server has no record of it yet, which never proves it will not accept
  // a request still in flight. Only the user decides from here
  unconfirmed,
}

typedef WipeStep = ({String name, Future<void> Function() run});

class WipeIncomplete implements Exception {
  final List<String> failures;
  const WipeIncomplete(this.failures);

  @override
  String toString() => 'WipeIncomplete(${failures.join(', ')})';
}

// Runs every idempotent step before checking what remains
class TerminalWipe {
  final List<WipeStep> steps;
  final Future<List<String>> Function() leftovers;
  final int attempts;
  final Future<void> Function(Duration) sleep;

  TerminalWipe({
    required this.steps,
    required this.leftovers,
    this.attempts = 3,
    Future<void> Function(Duration)? sleep,
  }) : sleep = sleep ?? Future<void>.delayed;

  Future<void> run() async {
    for (var attempt = 1;; attempt++) {
      final problems = <String>[];
      for (final step in steps) {
        try {
          await step.run();
        } catch (_) {
          problems.add(step.name);
        }
      }
      try {
        problems.addAll(await leftovers());
      } catch (_) {
        problems.add('verification');
      }
      if (problems.isEmpty) return;
      if (attempt >= attempts) throw WipeIncomplete(problems);
      await sleep(Duration(seconds: attempt));
    }
  }
}

class AccountDeletion {
  final AccountDeletionApi _api;
  final DeletionMarkerStore _marker;
  final Future<void> Function() _wipe;
  final Uint8List Function(int) _random;

  AccountDeletion({
    required AccountDeletionApi api,
    required DeletionMarkerStore marker,
    required Future<void> Function() wipe,
    required Uint8List Function(int) random,
  })  : _api = api,
        _marker = marker,
        _wipe = wipe,
        _random = random;

  Future<DeletionPlan> plan() async => DeletionPlan(await _api.preflight());

  Future<PendingDeletion?> pending() => _marker.read();

  Future<DeletionResult> confirm(DeletionPlan plan) async {
    final pending = PendingDeletion(
      receipt: base64Url.encode(_random(32)).replaceAll('=', ''),
      sharedAlbumIds: [for (final a in plan.shared) a.albumId],
      accepted: false,
    );
    // No request leaves without a marker, or a lost response strands the data
    await _marker.write(pending);
    try {
      await _api.request(pending.sharedAlbumIds, pending.receipt);
      return _finish(pending);
    } on ApiError catch (e) {
      if (e.code == 'E_DELETION_PLAN_STALE') {
        return _giveUp(pending, DeletionResult.planChanged);
      }
    } catch (_) {}
    // This retry is still part of the original confirmation
    if (await _api.receiptAccepted(pending.receipt)) return _finish(pending);
    return _send(pending);
  }

  // Never resends and never concludes failure from silence
  Future<DeletionResult?> resume() async {
    final pending = await _marker.read();
    if (pending == null) return null;
    if (pending.accepted || await _api.receiptAccepted(pending.receipt)) {
      return _finish(pending);
    }
    return DeletionResult.unconfirmed;
  }

  // Reusing the receipt makes a repeated request harmless
  Future<DeletionResult> continueDeleting() async {
    final pending = await _marker.read();
    if (pending == null) return DeletionResult.notAccepted;
    if (pending.accepted || await _api.receiptAccepted(pending.receipt)) {
      return _finish(pending);
    }
    return _send(pending);
  }

  // Keeps the account only once the server has barred the receipt, so no
  // request still in flight can delete it afterwards
  Future<DeletionResult> keepAccount() async {
    final pending = await _marker.read();
    if (pending == null) return DeletionResult.notAccepted;
    if (pending.accepted) return _finish(pending);
    return _giveUp(pending, DeletionResult.notAccepted);
  }

  Future<DeletionResult> _send(PendingDeletion pending) async {
    try {
      await _api.request(pending.sharedAlbumIds, pending.receipt);
      return _finish(pending);
    } on ApiError catch (e) {
      if (e.code == 'E_DELETION_PLAN_STALE') {
        return _giveUp(pending, DeletionResult.planChanged);
      }
      // A refused retry may still be explained by the first request landing
      if (await _api.receiptAccepted(pending.receipt)) return _finish(pending);
      return DeletionResult.unconfirmed;
    }
  }

  Future<DeletionResult> _giveUp(
      PendingDeletion pending, DeletionResult result) async {
    if (await _api.abandon(pending.receipt)) return _finish(pending);
    await _marker.clear();
    return result;
  }

  Future<DeletionResult> _finish(PendingDeletion pending) async {
    if (!pending.accepted) await _marker.write(pending.markAccepted());
    await _wipe();
    await _marker.clear();
    return DeletionResult.deleted;
  }
}
