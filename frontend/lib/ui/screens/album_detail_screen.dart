import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/data/storage/name_cache.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/data/models/member_model.dart';
import 'package:keepsy/crypto/uuid_bytes.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/epoch_processor.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';
import 'package:keepsy/e2ee/identity_trust.dart';
import 'package:keepsy/e2ee/invite.dart';
import 'package:keepsy/e2ee/member_removal.dart';
import 'package:keepsy/e2ee/sealed_name.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/screens/photo_viewer_screen.dart';
import 'package:keepsy/ui/theme/app_theme.dart';
import 'package:keepsy/ui/widgets/add_member_dialog.dart';
import 'package:keepsy/ui/widgets/encrypted_thumbnail.dart';
import 'package:keepsy/ui/widgets/safety_number_sheet.dart';

class AlbumDetailScreen extends StatefulWidget {
  final AlbumModel album;
  final AlbumService albumService;
  final MediaApi? mediaApi;

  AlbumDetailScreen({
    super.key,
    required this.album,
    AlbumService? albumService,
    this.mediaApi,
  }) : albumService = albumService ?? AlbumService();

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  late final MediaApi _media;
  List<AlbumMember> _members = [];
  List<MediaRecord> _items = [];
  bool _loadingMembers = true;
  bool _loadingMedia = true;
  bool _uploading = false;

  //  track the last (album,media) tuple we acted on so a
  // single AppState.notifyListeners broadcast doesnt drive _loadMedia twice
  // _appState is captured in didChangeDependencies for symmetric add/remove
  String? _lastSeenMediaAddedId;
  int _lastSeenMemberTick = 0;
  // set once this screen has begun exiting (kicked, or a voluntary leave) so
  // the AppState listener never double pops
  bool _accessLost = false;
  AppState? _appState;

  @override
  void initState() {
    super.initState();
    _media = widget.mediaApi ?? MediaApi(ApiClient());
    _loadMembers();
    _loadMedia();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<AppState>();
    if (!identical(_appState, next)) {
      _appState?.removeListener(_onAppStateChange);
      _appState = next;
      _appState!.addListener(_onAppStateChange);
    }
  }

  void _onAppStateChange() {
    final s = _appState;
    if (s == null) return;

    // This album was removed for me (kicked while viewing, or a missed WS event
    // recovered via the 403 fallback) : exit the screen instead of showing
    // stale content. Guarded so a voluntary leave (which sets _accessLost
    // first) doesnt get the "you were removed" treatment or a double pop
    if (!_accessLost && s.lastRemovedAlbumId == widget.album.id) {
      _accessLost = true;
      final nav = Navigator.of(context);
      final messenger = ScaffoldMessenger.of(context);
      if (nav.canPop()) nav.pop();
      messenger.showSnackBar(
          const SnackBar(content: Text('You were removed from this album')));
      return;
    }

    // a member joined or was revoked in this album : refresh the roster so a
    // kicked user disappears (and a new one appears) without re entering
    if (s.lastMemberChangedAlbumId == widget.album.id &&
        s.memberChangeTick != _lastSeenMemberTick) {
      _lastSeenMemberTick = s.memberChangeTick;
      _loadMembers();
    }

    // new media in this album
    if (s.lastMediaAddedAlbumId == widget.album.id) {
      final mid = s.lastMediaAddedMediaId;
      if (mid != null && mid != _lastSeenMediaAddedId) {
        _lastSeenMediaAddedId = mid;
        _loadMedia();
      }
    }
  }

  // memberToken -> (decrypted name, the name_ct it came from). The name_ct is
  // kept so a rename (new name_ct) invalidates the stale cached name instead of
  // showing it : a member whose ct no longer matches falls back to "Member"
  // until the new name decrypts
  final Map<String, ({String name, String ct})> _memberNames = {};

  // Never surface the raw token slice : and never a stale name after a rename
  String _memberName(AlbumMember m) {
    final e = _memberNames[m.memberToken];
    if (e != null && e.ct == m.profile.nameCt) return e.name;
    return 'Member';
  }

  Future<void> _loadMembers() async {
    final members = await widget.albumService.listMembers(widget.album.id);
    if (mounted) {
      setState(() {
        _members = members;
        _loadingMembers = false;
      });
      unawaited(_resolveMemberNames(members));
      unawaited(_reconcileTrust(members));
      // As an admin, finish any rotation left pending by a crashed kick or a
      // member who left while no admin was online
      unawaited(_maybeRecoverPending());
    }
  }

  // memberToken -> roster trust shown by chips and the key change banner
  // Epoch signing authority and install blocks are tracked separately
  Map<String, TrustState> _trust = {};

  IdentityTrust? _trustSvc() {
    try {
      return context.read<IdentityTrust>();
    } catch (_) {
      return null; // widget tests that dont install the provider
    }
  }

  Uint8List? _peerIk(AlbumMember m) {
    final b64 = m.profile.ikPub;
    if (b64 == null || b64.isEmpty) return null;
    try {
      final ik = base64.decode(base64.normalize(b64));
      return ik.length == 32 ? ik : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _reconcileTrust(List<AlbumMember> members) async {
    final trust = _trustSvc();
    final albumIdBytes = uuidToBytes(widget.album.id);
    if (trust == null || albumIdBytes == null) return;

    final peers = <PeerIdentity>[];
    for (final m in members) {
      if (m.revoked) continue;
      final ik = _peerIk(m);
      if (ik == null) continue;
      peers.add(PeerIdentity(memberToken: m.memberToken, ikPub: ik));
    }
    if (peers.isEmpty) return;

    try {
      final states = await trust.reconcile(albumIdBytes, peers,
          myMemberToken: widget.album.memberToken);
      if (mounted && !_accessLost) setState(() => _trust = states);
    } catch (_) {
      // trust display : never break the album on it
    }
  }

  Future<void> _openSafetyNumber(AlbumMember m) async {
    final trust = _trustSvc();
    final albumIdBytes = uuidToBytes(widget.album.id);
    final ik = _peerIk(m);
    if (trust == null || albumIdBytes == null || ik == null) return;

    final state = _trust[m.memberToken] ?? TrustState.unverified;
    final digits =
        await trust.safetyNumber(albumId: albumIdBytes, peerIkPub: ik);
    if (!mounted) return;

    final app = context.read<AppState>();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: K.bg(app.isDark),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafetyNumberSheet(
        displayName: _memberName(m),
        digits: digits,
        state: state,
        dark: app.isDark,
        accent: app.accent,
        // verifies the key the user was ACTUALLY SHOWN, not whatever the
        // roster happens to say by the time they tap
        onVerify: () async {
          await trust.markVerified(
              albumId: albumIdBytes, memberToken: m.memberToken, peerIkPub: ik);
          await _reconcileTrust(_members);
        },
      ),
    );
  }

  // Manually re run contiguous catch up. Reconnects may retry it too: any
  // unresolved failure simply emits a fresh block
  Future<void> _retryKeySync() async {
    final albumIdBytes = uuidToBytes(widget.album.id);
    if (albumIdBytes == null) return;
    EpochProcessor proc;
    try {
      proc = context.read<EpochProcessor>();
    } catch (_) {
      return; // widget tests that dont install the provider
    }
    await proc.catchUpAll([albumIdBytes]);
  }

  // Shows the digits for the key EXACTLY as it was presented during the failed
  // install. Re reading it from the roster would let a server sign with one key
  // and show an honest one here, so the human would be comparing the wrong thing
  Future<void> _verifyBlockingSigner(EpochBlocked block) async {
    final trust = _trustSvc();
    final albumIdBytes = uuidToBytes(widget.album.id);
    final ik = block.presentedIk;
    final token = block.senderToken;
    if (trust == null || albumIdBytes == null || ik == null || token == null) {
      return;
    }
    final tokenB64 = base64.encode(token);
    final name = _members
        .where((m) => m.memberToken == tokenB64)
        .map(_memberName)
        .firstOrNull;
    final digits =
        await trust.safetyNumber(albumId: albumIdBytes, peerIkPub: ik);
    if (!mounted) return;

    final app = context.read<AppState>();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: K.bg(app.isDark),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafetyNumberSheet(
        displayName: name ?? 'this member',
        digits: digits,
        state: TrustState.changed,
        dark: app.isDark,
        accent: app.accent,
        onVerify: () async {
          await trust.markVerified(
              albumId: albumIdBytes, memberToken: tokenB64, peerIkPub: ik);
          // Verifying only AUTHORIZES the retry : the block lifts when the
          // install actually succeeds
          await _retryKeySync();
        },
      ),
    );
  }

  Future<void> _resolveMemberNames(List<AlbumMember> members) async {
    if (!mounted) return;
    final withCt =
        members.where((m) => (m.profile.nameCt ?? '').isNotEmpty).toList();
    // Nothing published yet : skip (also avoids needing providers in tests
    // whose members carry no name_ct)
    if (withCt.isEmpty) return;
    final nameCache = context.read<NameCache>();
    final albumId = widget.album.id;

    // Serve cache hits instantly (CPU) : batch the misses into one MK
    // unwrap per epoch instead of a keystore round trip per member
    final fromCache = <String, ({String name, String ct})>{};
    final misses = <({String token, Uint8List tokenBytes, String nameCt})>[];
    for (final m in withCt) {
      final ct = m.profile.nameCt!;
      final cached =
          nameCache.get(NameCache.memberKey(albumId, m.memberToken), ct);
      if (cached != null) {
        fromCache[m.memberToken] = (name: cached, ct: ct);
        continue;
      }
      final Uint8List tokenBytes;
      try {
        tokenBytes = base64.decode(base64.normalize(m.memberToken));
      } catch (_) {
        continue;
      }
      misses.add((token: m.memberToken, tokenBytes: tokenBytes, nameCt: ct));
    }
    if (fromCache.isNotEmpty && mounted) {
      setState(() => _memberNames.addAll(fromCache));
    }
    if (misses.isEmpty) return;

    final albumIdBytes = uuidToBytes(albumId);
    if (albumIdBytes == null) return;
    final ks = context.read<AlbumKeyStore>();
    final resolved = await SealedName.openMemberNames(ks, albumIdBytes, misses);
    // If we were removed from the album while this decrypt was in flight, the
    // wipe (clearAlbum) already ran : don't repopulate NameCache with names for
    // an album we no longer belong to
    if (!mounted || _accessLost) return;
    if (resolved.isEmpty) return;
    final ctByToken = {for (final m in misses) m.token: m.nameCt};
    final applied = <String, ({String name, String ct})>{};
    resolved.forEach((token, name) {
      final ct = ctByToken[token];
      if (ct == null) return;
      nameCache.put(NameCache.memberKey(albumId, token), name, ct);
      applied[token] = (name: name, ct: ct);
    });
    if (mounted && applied.isNotEmpty) {
      setState(() => _memberNames.addAll(applied));
    }
  }

  // Surfaced as a banner so a substituted key is noticed without tapping a chip
  List<AlbumMember> get _changedKeyMembers => _members
      .where((m) => !m.revoked && _trust[m.memberToken] == TrustState.changed)
      .toList();

  // The viewer's own member row for this album, resolved by matching their held
  // member_token. null until members load (or if not present)
  AlbumMember? get _me {
    final myToken = widget.album.memberToken;
    if (myToken == null) return null;
    for (final m in _members) {
      if (m.memberToken == myToken) return m;
    }
    return null;
  }

  bool get _viewerIsAdmin {
    final r = _me?.role;
    return r == 'admin' || r == 'co-admin';
  }

  // Mirrors the server's last admin guard: only role=='admin' counts (a
  // co admin can't rotate a keyless album), revoked rows dont
  int get _activeAdminCount =>
      _members.where((m) => !m.revoked && m.role == 'admin').length;

  bool get _hasOtherActiveMembers => _members
      .any((m) => !m.revoked && m.memberToken != widget.album.memberToken);

  Future<void> _maybeRecoverPending() async {
    if (!_viewerIsAdmin) return;
    final albumIdBytes = _uuidStringToBytes(widget.album.id);
    if (albumIdBytes == null) return;
    try {
      final did = await context
          .read<MemberRemovalCoordinator>()
          .recoverIfPending(albumIdBytes);
      if (did && mounted) await _loadMembers();
    } catch (_) {
      // the upload freeze still protects content until it heals
    }
  }

  Future<void> _kick(AlbumMember m) async {
    final albumIdBytes = _uuidStringToBytes(widget.album.id);
    if (albumIdBytes == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final coord = context.read<MemberRemovalCoordinator>();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove member'),
        content: Text(
            'Remove ${_memberName(m)}? They lose access to photos added after now.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirm != true) return;
    final token = base64.decode(base64.normalize(m.memberToken));
    try {
      await coord.kick(albumIdBytes, token);
      if (mounted) {
        await _loadMembers();
        messenger.showSnackBar(const SnackBar(content: Text('Member removed')));
      }
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not remove member')));
    }
  }

  Future<void> _leave() async {
    final albumIdBytes = _uuidStringToBytes(widget.album.id);
    final myToken = widget.album.memberToken;
    if (albumIdBytes == null || myToken == null) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final coord = context.read<MemberRemovalCoordinator>();

    // The sole admin cant just leave (an admin less album cant rotate)
    // with other members present, block and explain, alone, offer
    // to delete the album instead
    final soleAdmin = _me?.role == 'admin' && _activeAdminCount <= 1;
    if (soleAdmin && _hasOtherActiveMembers) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("You're the only admin"),
          content: const Text(
              'Remove the other members first, or keep the album : an album '
              'needs at least one admin.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    if (soleAdmin && !_hasOtherActiveMembers) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete album'),
          content: const Text(
              "You're the only member. Leaving deletes this album and its "
              'photos for good.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete')),
          ],
        ),
      );
      if (confirm != true) return;
      final ok = await widget.albumService.deleteAlbum(widget.album.id);
      if (!ok) {
        messenger.showSnackBar(
            const SnackBar(content: Text('Could not delete album')));
        return;
      }
      _accessLost = true; // suppress the removal listener : we pop ourselves
      await coord.onSelfRemoved(albumIdBytes); // wipe local keys + cache + tile
      if (mounted) navigator.pop();
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave album'),
        content: const Text(
            'Leave this album? You lose access to it on this device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Leave')),
        ],
      ),
    );
    if (confirm != true) return;
    final token = base64.decode(base64.normalize(myToken));
    _accessLost = true; // suppress the removal listener : we pop ourselves
    try {
      await coord.leave(albumIdBytes, token);
      if (mounted) navigator.pop(); // album already dropped from the home grid
    } catch (_) {
      _accessLost =
          false; // leave failed : stay, and let a real removal exit us
      messenger
          .showSnackBar(const SnackBar(content: Text('Could not leave album')));
    }
  }

  // §6.1 : invite an existing keepsy user by their keepsy_id. The server gates
  // the actual add to admin/co-admin : a non-admin caller surfaces the generic
  // error in the dialog (i think i might need to come back on this later)
  Future<void> _openAddMember() async {
    final albumIdBytes = _uuidStringToBytes(widget.album.id);
    if (albumIdBytes == null) return;
    final initiator = context.read<InviteInitiator>();
    final messenger = ScaffoldMessenger.of(context);
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => AddMemberDialog(
        onInvite: (keepsyId) async {
          await initiator.inviteExistingUser(
              keepsyId: keepsyId, albumId: albumIdBytes);
        },
      ),
    );
    if (added == true && mounted) {
      await _loadMembers();
      messenger.showSnackBar(const SnackBar(content: Text('Invite sent')));
    }
  }

  Future<void> _loadMedia() async {
    try {
      final items = await _media.listMedia(widget.album.id);
      if (mounted) {
        setState(() {
          _items = items;
          _loadingMedia = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMedia = false);
    }
  }

  Future<void> _pickAndUpload() async {
    if (_uploading) return;
    // Flip the guard BEFORE pickImage so a fast double tap on the FAB cant
    // race past the if return and open the picker twice (PlatformException
    // already_active). reset in finally so a cancelled pick doesnt sticky lock
    setState(() => _uploading = true);
    final aks = context.read<AlbumKeyStore>();
    final cache = context.read<MediaCacheManager>();
    final messenger = ScaffoldMessenger.of(context);

    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final albumIdBytes = _uuidStringToBytes(widget.album.id);
      if (albumIdBytes == null) throw Exception('bad album id');
      final epoch = await aks.latestEpoch(albumIdBytes);
      if (epoch < 0) {
        throw Exception('no MK installed for this album yet');
      }

      final env = await FilePipeline.prepareUpload(
        aks: aks,
        albumIdBytes: albumIdBytes,
        currentEpoch: epoch,
        plaintext: bytes,
        mediaType: 'photo',
        mimeType: picked.mimeType ?? 'image/jpeg',
      );
      await _media.upload(albumId: widget.album.id, envelope: env);
      // Seed before _loadMedia : the grid rebuild that fires when setState
      // swaps _items will hit L1 instead of going to S3
      await cache.seedFromUpload(albumId: widget.album.id, env: env);
      await _loadMedia();
    } on UnprocessableImageException {
      messenger.showSnackBar(const SnackBar(
          content:
              Text("This photo's format isn't supported yet , try a JPEG.")));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChange);
    if (widget.mediaApi == null) _media.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final dark = state.isDark;
    final accent = state.accent;
    final syncing = state.isSyncing(widget.album.id);
    // A block survives failed sync attempts and disables uploads until a
    // successful catch up reaches the refused epoch
    final keyBlock = state.keyBlockFor(widget.album.id);

    // Only surface a resolved name whose fingerprint still matches the member's
    // current name_ct : a renamed member falls back to "Member" until re resolved
    final memberDisplayNames = <String, String>{};
    for (final m in _members) {
      final e = _memberNames[m.memberToken];
      if (e != null && e.ct == m.profile.nameCt) {
        memberDisplayNames[m.memberToken] = e.name;
      }
    }

    return Scaffold(
      backgroundColor: K.bg(dark),
      appBar: AppBar(
        backgroundColor: K.bg(dark),
        elevation: 0,
        title: Text(
          state.albumDisplayName(widget.album.id) ?? 'Album',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: K.t1(dark), fontSize: 18, fontWeight: FontWeight.w700),
        ),
        iconTheme: IconThemeData(color: K.t1(dark)),
        actions: [
          IconButton(
            icon: Icon(Icons.person_add_outlined, color: K.t2(dark)),
            onPressed: _openAddMember,
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: K.t2(dark)),
            onSelected: (v) {
              if (v == 'leave') _leave();
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'leave',
                child: Text('Leave album'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed:
            (syncing || _uploading || keyBlock != null) ? null : _pickAndUpload,
        backgroundColor: accent,
        child: _uploading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.add_a_photo_outlined, color: Colors.white),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MemberChipsRow(
              members: _members,
              loading: _loadingMembers,
              dark: dark,
              accent: accent,
              resolvedNames: memberDisplayNames,
              trust: _trust,
              onTapMember: _openSafetyNumber,
              // admins can long press another (non-revoked) member to remove
              onRemove: _viewerIsAdmin ? _kick : null,
              myToken: widget.album.memberToken),
          if (keyBlock != null)
            _KeyBlockBanner(
              dark: dark,
              block: keyBlock,
              onVerify: () => _verifyBlockingSigner(keyBlock),
              onRetry: _retryKeySync,
            ),
          if (_changedKeyMembers.isNotEmpty)
            _KeyChangeBanner(
              dark: dark,
              members: _changedKeyMembers,
              nameOf: _memberName,
              onTap: _openSafetyNumber,
            ),
          const Divider(height: 1, thickness: 0.5),
          Expanded(
            child: syncing
                ? const _SyncingPlaceholder()
                : _MediaGrid(
                    items: _items,
                    loading: _loadingMedia,
                    dark: dark,
                  ),
          ),
        ],
      ),
    );
  }
}

class _SyncingPlaceholder extends StatelessWidget {
  const _SyncingPlaceholder();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 2),
          const SizedBox(height: 12),
          Text('Syncing encryption keys…',
              style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _MediaGrid extends StatelessWidget {
  final List<MediaRecord> items;
  final bool loading;
  final bool dark;

  const _MediaGrid({
    required this.items,
    required this.loading,
    required this.dark,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return _MediaEmpty(dark: dark);
    }
    final cache = context.read<MediaCacheManager>();
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => ClipRRect(
        borderRadius: BorderRadius.circular(6),
        //  grid uses thumb cipher (~20 KB) so scroll stays smooth
        // Pre §5.3 rows + videos fall through to EncryptedImage inside
        // the widget
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PhotoViewerScreen(
                record: items[i],
                cache: cache,
              ),
            ),
          ),
          child: EncryptedThumbnail(record: items[i], cache: cache),
        ),
      ),
    );
  }
}

class _MediaEmpty extends StatelessWidget {
  final bool dark;
  const _MediaEmpty({required this.dark});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_library_outlined, size: 48, color: K.t3(dark)),
          const SizedBox(height: 12),
          Text('No media yet',
              style: TextStyle(
                  color: K.t2(dark),
                  fontSize: 16,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text('Tap + to upload an encrypted photo',
              style: TextStyle(color: K.t3(dark), fontSize: 13)),
        ],
      ),
    );
  }
}

class _MemberChipsRow extends StatelessWidget {
  final List<AlbumMember> members;
  final bool loading;
  final bool dark;
  final Color accent;
  // Non null only for an admin viewer : long pressing a removable chip calls it
  final void Function(AlbumMember)? onRemove;
  // The viewer's own token, so their chip never shows a remove button
  final String? myToken;
  // memberToken -> decrypted display name (missing entries fall back to a slice)
  final Map<String, String> resolvedNames;
  // memberToken -> TOFU state. Absent = not computed yet (no badge)
  final Map<String, TrustState> trust;
  final void Function(AlbumMember) onTapMember;

  const _MemberChipsRow({
    required this.members,
    required this.loading,
    required this.dark,
    required this.accent,
    required this.resolvedNames,
    required this.trust,
    required this.onTapMember,
    this.onRemove,
    this.myToken,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: SizedBox(
          height: 32,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: accent),
            ),
          ),
        ),
      );
    }
    // Revoked members are no longer part of the album : hide them so a kicked
    // user disappears from everyone's roster
    final visible = members.where((m) => !m.revoked).toList();
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        itemCount: visible.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final m = visible[i];
          final removable = onRemove != null && m.memberToken != myToken;
          final isMe = m.memberToken == myToken;
          return _MemberChip(
            member: m,
            dark: dark,
            accent: accent,
            displayName: resolvedNames[m.memberToken] ?? 'Member',
            // no safety number with yourself
            trust: isMe ? null : trust[m.memberToken],
            onTap: isMe ? null : () => onTapMember(m),
            onRemove: removable ? () => onRemove!(m) : null,
          );
        },
      ),
    );
  }
}

class _MemberChip extends StatelessWidget {
  final AlbumMember member;
  final bool dark;
  final Color accent;
  final String displayName;
  // null for our own chip, or before the roster has been reconciled
  final TrustState? trust;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  const _MemberChip(
      {required this.member,
      required this.dark,
      required this.accent,
      required this.displayName,
      this.trust,
      this.onTap,
      this.onRemove});

  @override
  Widget build(BuildContext context) {
    final changed = trust == TrustState.changed;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: EdgeInsets.only(
            left: 10, right: onRemove != null ? 2 : 10, top: 4, bottom: 4),
        decoration: BoxDecoration(
          color: K.cardCol(dark),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: changed ? const Color(0xFFF87171) : K.borderCol(dark)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 10,
              backgroundColor: K.defaultAccent.withValues(alpha: 0.3),
              child: Text(
                displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: Colors.white),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              // resolved global name : "Member" for anyone who hasnt published
              // a name_ct yet (never the raw token)
              displayName,
              style: TextStyle(
                  color: K.t1(dark), fontSize: 12, fontWeight: FontWeight.w500),
            ),
            // verified gets a mark, a changed key gets a loud one. An
            // unverified peer gets NOTHING : an icon there would read as a
            // safety claim we cannot make about a key nobody has compared
            if (trust == TrustState.verified) ...[
              const SizedBox(width: 3),
              Icon(Icons.verified_user, size: 11, color: accent),
            ] else if (changed) ...[
              const SizedBox(width: 3),
              const Icon(Icons.error, size: 11, color: Color(0xFFF87171)),
            ],
            const SizedBox(width: 4),
            Text(
              member.role,
              style: TextStyle(color: K.t3(dark), fontSize: 10),
            ),
            // Visible remove affordance for admins : a tappable × on each
            // removable member (replaces the old undiscoverable long-press)
            if (onRemove != null) ...[
              const SizedBox(width: 2),
              InkResponse(
                onTap: onRemove,
                radius: 16,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 14, color: K.t3(dark)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Album level "someone's key changed" strip. A chip badge alone is too easy to
// miss, and this is the one state that warrants interrupting the user
class _KeyChangeBanner extends StatelessWidget {
  final bool dark;
  final List<AlbumMember> members;
  final String Function(AlbumMember) nameOf;
  final void Function(AlbumMember) onTap;

  const _KeyChangeBanner({
    required this.dark,
    required this.members,
    required this.nameOf,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFF87171);
    final names = members.map(nameOf).toList();
    final who = names.length == 1
        ? "${names.first}'s security key changed"
        : '${names.length} members’ security keys changed';
    return InkWell(
      onTap: () => onTap(members.first),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: red.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: red.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 16, color: red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$who. Verify with them directly if that was unexpected.',
                style: TextStyle(color: K.t1(dark), fontSize: 12, height: 1.35),
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: K.t3(dark)),
          ],
        ),
      ),
    );
  }
}

// Persistent key sync failure. It remains visible until a background or manual
// catch up reaches the blocked epoch
class _KeyBlockBanner extends StatelessWidget {
  final bool dark;
  final EpochBlocked block;
  final VoidCallback onVerify;
  final VoidCallback onRetry;

  const _KeyBlockBanner({
    required this.dark,
    required this.block,
    required this.onVerify,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFF87171);
    // Only a PEER's key can be settled by a human comparison. Our own key needs
    // no confirming, and the rest have nothing to compare against
    final verifiable = block.reason == EpochBlockReason.signerMismatch ||
        block.reason == EpochBlockReason.unknownSigner;
    final text = switch (block.reason) {
      EpochBlockReason.signerMismatch =>
        'New photos are paused. The key that signed this album’s latest '
            'encryption update is not the one we trust for that member.',
      EpochBlockReason.unknownSigner =>
        'New photos are paused. This album’s latest encryption update was '
            'signed by someone this device has no identity for.',
      EpochBlockReason.selfSignerMismatch =>
        'New photos are paused. The server described this device’s own '
            'identity key incorrectly.',
      EpochBlockReason.wrapUnavailable =>
        'New photos are paused. An encryption update for this album could not '
            'be downloaded, and later ones cannot be applied without it.',
      EpochBlockReason.verificationFailed =>
        'New photos are paused. An encryption update for this album failed its '
            'integrity check.',
      EpochBlockReason.localKeyMissing =>
        'New photos are paused. A one time key this album’s encryption update '
            'was addressed to is no longer on this device.',
      EpochBlockReason.replayRejected =>
        'New photos are paused. An encryption update for this album was '
            'refused as a replay of one already installed.',
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: red.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.gpp_maybe_outlined, size: 16, color: red),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style:
                      TextStyle(color: K.t1(dark), fontSize: 12, height: 1.35),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: verifiable
                ? TextButton(
                    onPressed: onVerify,
                    child: const Text('Verify safety number',
                        style: TextStyle(fontSize: 12)),
                  )
                : TextButton(
                    onPressed: onRetry,
                    child: const Text('Retry encryption sync',
                        style: TextStyle(fontSize: 12)),
                  ),
          ),
        ],
      ),
    );
  }
}

// 8-4-4-4-12 hex string -> 16 raw bytes. Returns null on malformed input
// Inlined here to match the existing pattern in main.dart + landing_screen.dart :
// future cleanup could pull into a shared helper if a 4th copy appears
Uint8List? _uuidStringToBytes(String s) {
  final hex = s.replaceAll('-', '');
  if (hex.length != 32) return null;
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    final v = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (v == null) return null;
    out[i] = v;
  }
  return out;
}
