import 'dart:convert';

import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/api_error.dart';

enum DeletionOutcome { leave, deleteAlbum, deleteShared }

class DeletionAlbum {
  final String albumId;
  final int activeMemberCount;
  final int ownMediaCount;
  final DeletionOutcome outcome;

  const DeletionAlbum({
    required this.albumId,
    required this.activeMemberCount,
    required this.ownMediaCount,
    required this.outcome,
  });

  static DeletionAlbum? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['album_id'];
    final outcome = switch (json['outcome']) {
      'leave' => DeletionOutcome.leave,
      'delete_album' => DeletionOutcome.deleteAlbum,
      'delete_shared' => DeletionOutcome.deleteShared,
      _ => null,
    };
    if (id is! String || outcome == null) return null;
    return DeletionAlbum(
      albumId: id,
      activeMemberCount: (json['active_member_count'] as num?)?.toInt() ?? 0,
      ownMediaCount: (json['own_media_count'] as num?)?.toInt() ?? 0,
      outcome: outcome,
    );
  }
}

abstract class AccountDeletionApi {
  Future<List<DeletionAlbum>> preflight();

  Future<void> request(List<String> sharedAlbumIds, String receipt);

  // Receipt checks remain available after acceptance removes every session
  Future<bool> receiptAccepted(String receipt);

  // Returns true when acceptance won the race
  Future<bool> abandon(String receipt);
}

class HttpAccountDeletionApi implements AccountDeletionApi {
  final ApiClient _client;
  HttpAccountDeletionApi(this._client);

  @override
  Future<List<DeletionAlbum>> preflight() async {
    final resp = await _client.get('/users/me/deletion');
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final albums = body['albums'];
    if (albums is! List) throw const FormatException('albums missing');
    // An unreadable row would hide an album from the plan, so refuse it
    return [
      for (final a in albums)
        DeletionAlbum.tryParse(a) ??
            (throw const FormatException('unreadable deletion row')),
    ];
  }

  @override
  Future<void> request(List<String> sharedAlbumIds, String receipt) async {
    await _client.post('/users/me/deletion', body: {
      'delete_shared_album_ids': sharedAlbumIds,
      'receipt': receipt,
    });
  }

  @override
  Future<bool> abandon(String receipt) async {
    try {
      await _client.post('/account-deletions/$receipt/abandon');
      return false;
    } on ApiError catch (e) {
      if (e.code == 'E_DELETION_ACCEPTED') return true;
      rethrow;
    }
  }

  @override
  Future<bool> receiptAccepted(String receipt) async {
    try {
      await _client.get('/account-deletions/$receipt');
      return true;
    } on ApiError catch (e) {
      if (e.code == 'E_NOT_FOUND') return false;
      rethrow;
    }
  }
}
