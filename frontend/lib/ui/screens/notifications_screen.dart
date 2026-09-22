import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:keepsy/crypto/uuid_bytes.dart';
import 'package:keepsy/data/storage/activity_store.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/domain/activity/activity_event.dart';
import 'package:keepsy/domain/activity/activity_sync.dart';
import 'package:keepsy/e2ee/identity_trust.dart';
import 'package:keepsy/ui/activity/activity_copy.dart';
import 'package:keepsy/ui/activity/activity_screen.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/encrypted_thumbnail.dart';
import 'package:keepsy/ui/widgets/safety_number_sheet.dart';

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final store = context.read<ActivityFeed>();
    final trust = context.read<IdentityTrust>();
    final sync = context.read<ActivitySync>();
    final names = ActivityNames(
      memberName: (albumId, token) =>
          state.memberDisplayName(albumId, token) ?? 'Someone',
      albumTitle: (id) => state.albumDisplayName(id) ?? 'an album',
    );

    return ActivityScreen(
      store: store,
      refresh: () async {
        await sync.flush();
        await _settleVerified(store, trust);
      },
      thumb: (record) => EncryptedThumbnail(
        record: record,
        cache: context.read<MediaCacheManager>(),
      ),
      names: names,
      onOpenAlbum: (albumId) => Navigator.of(context).pop(albumId),
      onCompare: (e) => _compare(context, e, names, store, trust),
      onUnreadChanged: state.setUnreadNotifications,
    );
  }

  // Compare the alarm key, never a later roster key
  static Future<void> _compare(
    BuildContext context,
    SafetyNumberChanged e,
    ActivityNames names,
    ActivityFeed store,
    IdentityTrust trust,
  ) async {
    final ik = e.presentedIk;
    final album = uuidToBytes(e.albumId);
    // Rows recorded before the key was kept can only point at the album
    if (ik == null || album == null) {
      Navigator.of(context).pop(e.albumId);
      return;
    }
    final digits = await trust.safetyNumber(albumId: album, peerIkPub: ik);
    if (!context.mounted) return;

    Future<void>? verifying;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Warm.ground,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafetyNumberSheet(
        displayName: names.memberName(e.albumId, e.peerToken),
        digits: digits,
        state: TrustState.changed,
        onVerify: () {
          verifying = () async {
            try {
              await trust.markVerified(
                  albumId: album, memberToken: e.peerToken, peerIkPub: ik);
            } on VerificationNotSaved {
              // The album alarms again after a restart, so no "it matched"
              return;
            }
            await store.resolveVerified(e);
          }();
        },
      ),
    );
    // The sheet closes before its verification writes finish
    await verifying?.catchError((_) {});
  }

  // Settle only when this album's pin agrees with the verified key
  static Future<void> _settleVerified(
      ActivityFeed store, IdentityTrust trust) async {
    for (final r in await store.read(lane: ActivityLane.security)) {
      final e = r.event;
      if (e is! SafetyNumberChanged || e.verified) continue;
      final Uint8List? ik = e.presentedIk;
      final album = uuidToBytes(e.albumId);
      if (ik == null || album == null) continue;
      if (await trust.isResolved(
          albumId: album, memberToken: e.peerToken, peerIkPub: ik)) {
        await store.resolveVerified(e);
      }
    }
  }
}
