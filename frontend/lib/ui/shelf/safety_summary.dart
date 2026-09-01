import 'dart:convert';
import 'dart:typed_data';

import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/identity_trust.dart';

// Counts distinct verified peer keys locally to avoid cross album identity linking
Future<String?> safetyNumberSummary({
  required List<AlbumModel> albums,
  required IdentityTrust trust,
  required IdentityService identity,
  AlbumService? service,
}) async {
  if (albums.isEmpty) return null;
  final svc = service ?? AlbumService();

  Uint8List? mine;
  try {
    mine = await identity.currentIkPub();
  } catch (_) {
    mine = null;
  }
  final mineB64 = mine == null ? null : base64.encode(mine);

  final peers = <String>{};
  for (final a in albums) {
    try {
      for (final m in await svc.listMembers(a.id)) {
        if (m.revoked) continue;
        final ik = m.profile.ikPub;
        if (ik == null || ik.isEmpty) continue;
        final norm = base64.encode(base64.decode(base64.normalize(ik)));
        if (norm == mineB64) continue;
        peers.add(norm);
      }
    } catch (_) {}
  }
  if (peers.isEmpty) return null;

  var verified = 0;
  for (final ik in peers) {
    try {
      if (await trust.verifiedAt(base64.decode(ik)) != null) verified++;
    } catch (_) {}
  }
  return '$verified of ${peers.length} verified';
}
