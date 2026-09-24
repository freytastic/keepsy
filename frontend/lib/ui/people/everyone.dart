import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:keepsy/crypto/uuid_bytes.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/identity_trust.dart';
import 'package:keepsy/e2ee/invite.dart';
import 'package:keepsy/ui/album/add_people_sheet.dart';
import 'package:keepsy/ui/album/album_copy.dart';
import 'package:keepsy/ui/album/member_avatars.dart';
import 'package:keepsy/ui/people/people_screen.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/member_face.dart';
import 'package:keepsy/ui/widgets/safety_number_sheet.dart';

// One person across albums, grouped by key on this phone only
class _Person {
  final Uint8List ik;
  final List<({String albumId, String token})> seen = [];
  TrustState trust = TrustState.verified;
  String? name;

  _Person(this.ik);
}

const _worse = {
  TrustState.verified: 0,
  TrustState.unverified: 1,
  TrustState.changed: 2,
};

// Loads rosters and runs the same reconcile an album runs on open, so a
// changed key alarms here too
class _Roster {
  final AppState state;
  final IdentityTrust trust;
  final IdentityService identity;
  final AlbumService svc;
  final List<AlbumModel> Function() albums;
  // Single album view also lists invites, which have no key yet
  final bool withInvites;

  final Map<String, _Person> people = {};
  final List<AvatarMember> avatars = [];

  _Roster(
    BuildContext context, {
    required this.albums,
    required this.withInvites,
    AlbumService? service,
  })  : state = context.read<AppState>(),
        trust = context.read<IdentityTrust>(),
        identity = context.read<IdentityService>(),
        svc = service ?? AlbumService();

  Future<List<PersonEntry>> load() async {
    people.clear();
    avatars.clear();
    final invites = <PersonEntry>[];
    final mine = base64.encode(await identity.currentIkPub());
    for (final a in albums()) {
      final albumBytes = uuidToBytes(a.id);
      if (albumBytes == null) continue;
      final roster = <PeerIdentity>[];
      final Map<String, TrustState> states;
      try {
        for (final m in await svc.listMembers(a.id)) {
          if (m.revoked) continue;
          final self = m.memberToken == a.memberToken;
          final pending = m.profile.nameCt == null && !self;
          avatars.add(AvatarMember(
            token: m.memberToken,
            name: state.memberDisplayName(a.id, m.memberToken),
            pending: pending,
            self: self,
          ));
          if (self) continue;
          if (pending && withInvites) {
            invites.add(PersonEntry(
              id: 'invite-${m.memberToken}',
              name: AlbumCopy.invitedShort,
              face: const SizedBox(),
              invited: true,
              detail: "Hasn't opened it yet",
            ));
            continue;
          }
          final ik = m.profile.ikPub;
          if (ik == null || ik.isEmpty) continue;
          final bytes = base64.decode(base64.normalize(ik));
          if (bytes.length != 32) continue;
          roster.add(PeerIdentity(memberToken: m.memberToken, ikPub: bytes));
        }
        if (roster.isEmpty) continue;
        states = await trust.reconcile(albumBytes, roster,
            myMemberToken: a.memberToken);
      } catch (_) {
        if (withInvites) rethrow;
        continue;
      }
      for (final peer in roster) {
        final s = states[peer.memberToken] ?? TrustState.unverified;
        // A stranger's row carrying our key only matters as an alarm
        if (base64.encode(peer.ikPub) == mine && s != TrustState.changed) {
          continue;
        }
        final p = people.putIfAbsent(
            base64.encode(peer.ikPub), () => _Person(peer.ikPub));
        p.seen.add((albumId: a.id, token: peer.memberToken));
        p.name ??= state.memberDisplayName(a.id, peer.memberToken);
        if (_worse[s]! > _worse[p.trust]!) p.trust = s;
      }
    }
    return [
      for (final e in people.entries)
        PersonEntry(
          id: e.key,
          name: e.value.name ?? AlbumCopy.unknownMember,
          face: _face(e.value, 40),
          trust: e.value.trust,
          detail: withInvites
              ? null
              : '${e.value.seen.length} '
                  'album${e.value.seen.length == 1 ? '' : 's'}',
        ),
      ...invites,
    ];
  }

  Future<void> open(BuildContext context, PersonEntry entry) async {
    final p = people[entry.id];
    if (p == null) return;
    // Numbers are per album, so both phones must compare the same one
    final first = p.seen.first;
    final albumBytes = uuidToBytes(first.albumId);
    if (albumBytes == null) return;
    final digits =
        await trust.safetyNumber(albumId: albumBytes, peerIkPub: p.ik);
    if (!context.mounted) return;
    final title = state.albumDisplayName(first.albumId) ?? 'an album';
    Future<void>? verifying;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Warm.ground,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => SafetyNumberSheet(
        displayName: entry.name,
        digits: digits,
        state: entry.trust,
        subtitle: withInvites ? title : 'Number for $title',
        face: _face(p, 46),
        onVerify: () {
          verifying = () async {
            try {
              await trust.markVerified(
                  albumId: albumBytes,
                  memberToken: first.token,
                  peerIkPub: p.ik);
            } on VerificationNotSaved {
              // Session trust survives, but a restart restores the alarm
            }
          }();
        },
      ),
    );
    await verifying?.catchError((_) {});
  }
}

Future<void> openEveryone(BuildContext context, {AlbumService? service}) {
  final state = context.read<AppState>();
  final roster = _Roster(context,
      albums: () => state.albums, withInvites: false, service: service);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => PeopleScreen(
      title: 'Safety numbers',
      subtitle: 'Everyone you share an album with',
      load: roster.load,
      onOpen: (e) => roster.open(context, e),
    ),
  ));
}

// The album's roster without opening the album, as the shelf menu offers it
Future<void> openAlbumPeople(BuildContext context, AlbumModel album,
    {AlbumService? service}) async {
  final state = context.read<AppState>();
  final roster = _Roster(context,
      albums: () => [album], withInvites: true, service: service);
  final title = state.albumDisplayName(album.id) ?? 'This album';

  Future<void> add() async {
    final albumBytes = uuidToBytes(album.id);
    if (albumBytes == null) return;
    final initiator = context.read<InviteInitiator>();
    await AddPeopleSheet.show(
      context,
      albumId: album.id,
      albumTitle: title,
      members: [
        for (final a in roster.avatars)
          if (!a.pending) a
      ],
      myKeepsyId: state.keepsyId,
      onInvite: (keepsyId) =>
          initiator.inviteExistingUser(keepsyId: keepsyId, albumId: albumBytes),
    );
  }

  final admin = state.isAdminOf(album.id);
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => PeopleScreen(
      title: AlbumCopy.people,
      subtitle: title,
      load: roster.load,
      onOpen: (e) => roster.open(context, e),
      onAdd: admin ? add : null,
      note:
          admin ? null : 'Only the person who made this album can add people.',
    ),
  ));
}

Widget _face(_Person p, double size) => MemberFace(
      albumId: p.seen.first.albumId,
      token: p.seen.first.token,
      name: p.name,
      size: size,
      style: Warm.acFace.copyWith(fontSize: size * 0.36),
    );
