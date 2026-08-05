import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/storage/identity_pin_store.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/display_name.dart';
import 'package:keepsy/e2ee/epoch_rotator.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/sealed_name.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/theme/app_theme.dart';

// Album creation first obtains the album id and local member token, then starts
// epoch 0 bootstrap in the background. AppState marks the album as syncing so
// uploads remain disabled while bootstrap and encrypted name publication run

class CreateAlbumScreen extends StatefulWidget {
  const CreateAlbumScreen({super.key});

  @override
  State<CreateAlbumScreen> createState() => _CreateAlbumScreenState();
}

class _CreateAlbumScreenState extends State<CreateAlbumScreen> {
  final _nameCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Album name is required');
      return;
    }
    // Capture providers up front : context isnt valid across the awaits +
    // we navigator.pop before the deferred rotate runs, so the original
    // context is gone by then
    final rotator = context.read<EpochRotator>();
    final identity = context.read<IdentityService>();
    final appState = context.read<AppState>();
    final albumKeys = context.read<AlbumKeyStore>();
    final namePublisher = context.read<DisplayNamePublisher>();
    final pinStore = context.read<IdentityPinStore>();
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
    // Let the spinner paint before the network call
    await WidgetsBinding.instance.endOfFrame;

    try {
      final album = await AlbumService().createAlbum();
      if (album == null) throw Exception('Album creation failed');
      final tokenB64 = album.memberToken;
      if (tokenB64 == null) {
        throw Exception('Server did not return member_token');
      }
      final albumIdBytes = _uuidStringToBytes(album.id);
      if (albumIdBytes == null) {
        throw Exception('Invalid album id from server');
      }
      // Register our token before epoch 0 fanout can race the album list refresh
      // Otherwise the signer gate would treat our own wrap as peer signed
      appState.registerSelfToken(album.id, tokenB64);
      // Until epoch 0 lands, only this device can legitimately sign. Flush the
      // marker now so it can survive a crash before bootstrap completes
      await pinStore.markCreating(album.id);
      // Mark syncing : album_detail's _SyncingPlaceholder + FAB disable
      // already key off appState.isSyncing(albumId), so navigating into the
      // album before rotate completes is safe + visually consistent
      appState.markSyncing([album.id]);
      // Run AndroidKeyStore work after navigation while the syncing indicator
      // keeps the album read only
      unawaited(_runRotateInBackground(
        rotator: rotator,
        identity: identity,
        appState: appState,
        albumKeys: albumKeys,
        namePublisher: namePublisher,
        pinStore: pinStore,
        messenger: messenger,
        albumId: album.id,
        albumIdBytes: albumIdBytes,
        creatorMemberToken: base64Decode(tokenB64),
        creatorUserId: userId,
        albumName: name,
        creatorDisplayName: appState.profileName,
      ));
      navigator.pop(album);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  // Cleared in finally so a failed rotate doesnt leave the album stuck in
  // the syncing state forever : a snackbar tells the user what happened
  // cryptoReady is awaited HERE (not before pop) so a fast user that beats
  // signup bootstrap doesnt block on the create screen
  Future<void> _runRotateInBackground({
    required EpochRotator rotator,
    required IdentityService identity,
    required AppState appState,
    required AlbumKeyStore albumKeys,
    required DisplayNamePublisher namePublisher,
    required IdentityPinStore pinStore,
    required ScaffoldMessengerState messenger,
    required String albumId,
    required Uint8List albumIdBytes,
    required Uint8List creatorMemberToken,
    required String creatorUserId,
    required String albumName,
    required String creatorDisplayName,
  }) async {
    try {
      await identity.cryptoReady;
      await rotator.bootstrap(
        albumIdBytes: albumIdBytes,
        creatorMemberToken: creatorMemberToken,
        creatorUserId: creatorUserId,
      );
      // Local epoch 0 now exists, so the creator only signing window can close
      await pinStore.clearCreating(albumId);
      // epoch 0 MK now exists : seal the real title and PATCH it in, then
      // show it immediately (we hold the plaintext, no decrypt needed)
      final nameCt =
          await SealedName.sealAlbumName(albumKeys, albumIdBytes, 0, albumName);
      if (await AlbumService().updateAlbumNameCt(albumId, nameCt)) {
        // Update the stored nameCt too : if MainShell's post create album
        // refresh raced ahead with the placeholder, a later refreshAlbumNames
        // would otherwise clobber this title back to "Untitled Album"
        appState.applyAlbumNameCt(albumId, nameCt, albumName);
      }
      // Publish the creator's global display name into this album
      await namePublisher.publishToAlbum(
        albumId: albumId,
        memberToken: creatorMemberToken,
        name: creatorDisplayName,
      );
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Encryption setup failed for the new album'),
        duration: Duration(seconds: 4),
      ));
    } finally {
      appState.clearSyncing(albumId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final dark = state.isDark;
    final accent = state.accent;

    return Scaffold(
      backgroundColor: K.bg(dark),
      appBar: AppBar(
        backgroundColor: K.bg(dark),
        elevation: 0,
        iconTheme: IconThemeData(color: K.t1(dark)),
        title: Text('New Album',
            style: TextStyle(
                color: K.t1(dark), fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Album name',
                labelStyle: TextStyle(color: K.t3(dark)),
                filled: true,
                fillColor: K.cardCol(dark),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
              style: TextStyle(color: K.t1(dark), fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _busy ? null : _create,
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Create',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              Text('Generating encryption keys for the album…',
                  style: TextStyle(color: K.t3(dark), fontSize: 13),
                  textAlign: TextAlign.center),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  style:
                      const TextStyle(color: Colors.redAccent, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }
}

// 8-4-4-4-12 hex string -> 16 raw bytes. Returns null on malformed input
// Inlined here matching the existing pattern (main.dart, landing_screen,
// album_detail) : consolidating into one helper is a separate cleanup
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
