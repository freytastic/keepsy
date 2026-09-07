import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/crypto/uuid_bytes.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/storage/identity_pin_store.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/display_name.dart';
import 'package:keepsy/e2ee/epoch_rotator.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/invite.dart';
import 'package:keepsy/e2ee/sealed_name.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/warm_button.dart';

import 'album_name_print.dart';
import 'glass_sheet.dart';
import 'create_copy.dart';
import 'invite_dispatcher.dart';
import 'invite_id_field.dart';

// Creates the album before finishing encryption and invites in background

class CreateAlbumScreen extends StatefulWidget {
  const CreateAlbumScreen({super.key});

  @override
  State<CreateAlbumScreen> createState() => _CreateAlbumScreenState();
}

class _CreateAlbumScreenState extends State<CreateAlbumScreen> {
  final _nameCtrl = TextEditingController();
  final _printKey = GlobalKey<AlbumNamePrintState>();
  List<String> _inviteIds = const [];
  bool _busy = false;
  bool _leaving = false;
  String? _error;

  bool get _ready => _nameCtrl.text.trim().isNotEmpty;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = CreateCopy.nameRequired);
      return;
    }
    // Capture dependencies before the route closes
    final rotator = context.read<EpochRotator>();
    final identity = context.read<IdentityService>();
    final appState = context.read<AppState>();
    final albumKeys = context.read<AlbumKeyStore>();
    final namePublisher = context.read<DisplayNamePublisher>();
    final pinStore = context.read<IdentityPinStore>();
    final inviter = context.read<InviteInitiator>();
    final userId = appState.userId;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    if (userId == null) {
      setState(() => _error = 'Not signed in');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // Let the busy state paint before starting network work
    await WidgetsBinding.instance.endOfFrame;

    try {
      final album = await AlbumService().createAlbum();
      if (album == null) throw Exception('Album creation failed');
      final tokenB64 = album.memberToken;
      if (tokenB64 == null) {
        throw Exception('Server did not return member_token');
      }
      final albumIdBytes = uuidToBytes(album.id);
      if (albumIdBytes == null) {
        throw Exception('Invalid album id from server');
      }
      // Register self before the signer gate sees the epoch 0 wrap
      appState.registerSelfToken(album.id, tokenB64);
      // Persist sole signer authority until epoch 0 installs
      await pinStore.markCreating(album.id);
      // Keep album reads and uploads disabled during setup
      appState.markSyncing([album.id]);
      unawaited(_runRotateInBackground(
        rotator: rotator,
        identity: identity,
        appState: appState,
        albumKeys: albumKeys,
        namePublisher: namePublisher,
        pinStore: pinStore,
        inviter: inviter,
        messenger: messenger,
        albumId: album.id,
        albumIdBytes: albumIdBytes,
        creatorMemberToken: base64Decode(tokenB64),
        creatorUserId: userId,
        albumName: name,
        creatorDisplayName: appState.profileName,
        inviteIds: _inviteIds,
      ));
      // Finish the exit motion before revealing the shelf
      setState(() => _leaving = true);
      await _printKey.currentState?.flyOut();
      navigator.pop(album);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  // Always clears syncing so failed setup cannot strand the album
  Future<void> _runRotateInBackground({
    required EpochRotator rotator,
    required IdentityService identity,
    required AppState appState,
    required AlbumKeyStore albumKeys,
    required DisplayNamePublisher namePublisher,
    required IdentityPinStore pinStore,
    required InviteInitiator inviter,
    required ScaffoldMessengerState messenger,
    required String albumId,
    required Uint8List albumIdBytes,
    required Uint8List creatorMemberToken,
    required String creatorUserId,
    required String albumName,
    required String creatorDisplayName,
    required List<String> inviteIds,
  }) async {
    try {
      await identity.cryptoReady;
      await rotator.bootstrap(
        albumIdBytes: albumIdBytes,
        creatorMemberToken: creatorMemberToken,
        creatorUserId: creatorUserId,
      );
      // Close the temporary sole signer window
      await pinStore.clearCreating(albumId);
      // Seal the title after epoch 0 installs
      final nameCt =
          await SealedName.sealAlbumName(albumKeys, albumIdBytes, 0, albumName);
      if (await AlbumService().updateAlbumNameCt(albumId, nameCt)) {
        // Keep a stale shell refresh from restoring the placeholder
        appState.applyAlbumNameCt(albumId, nameCt, albumName);
      }
      await namePublisher.publishToAlbum(
        albumId: albumId,
        memberToken: creatorMemberToken,
        name: creatorDisplayName,
      );
      // Invites require epoch 0 keys
      final failed = await InviteDispatcher((keepsyId) => inviter
              .inviteExistingUser(keepsyId: keepsyId, albumId: albumIdBytes))
          .sendAll(inviteIds);
      if (failed > 0) {
        messenger.showSnackBar(SnackBar(
          content: Text(CreateCopy.invitesFailed(failed)),
          duration: const Duration(seconds: 4),
        ));
      }
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
        content: Text(CreateCopy.keySetupFailed),
        duration: Duration(seconds: 4),
      ));
    } finally {
      appState.clearSyncing(albumId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Warm.glassInk),
        title: const Text(CreateCopy.title,
            style: TextStyle(
                color: Warm.glassInk,
                fontSize: 18,
                fontWeight: FontWeight.w700)),
      ),
      body: GlassSheet(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: SizedBox(
                        width: 236,
                        child: AlbumNamePrint(
                          key: _printKey,
                          controller: _nameCtrl,
                          enabled: !_busy,
                          onChanged: (_) => setState(() => _error = null),
                          onSubmitted: () {
                            if (_ready && !_busy) _create();
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    AnimatedOpacity(
                      opacity: _leaving ? 0 : 1,
                      duration: Warm.quick,
                      child: InviteIdField(
                        ids: _inviteIds,
                        enabled: !_busy,
                        onChanged: (ids) => setState(() => _inviteIds = ids),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(_error!,
                          style:
                              const TextStyle(color: Warm.warn, fontSize: 13)),
                    ],
                    const SizedBox(height: 28),
                    AnimatedOpacity(
                      opacity: _leaving ? 0 : 1,
                      duration: Warm.quick,
                      child: WarmButton(
                        label: CreateCopy.createAndInvite(_inviteIds.length),
                        busy: _busy,
                        onTap: _ready && !_busy ? _create : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
