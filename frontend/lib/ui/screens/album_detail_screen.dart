import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/media_api.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/data/models/member_model.dart';
import 'package:keepsy/e2ee/album_keys.dart';
import 'package:keepsy/e2ee/file_pipeline.dart';
import 'package:keepsy/e2ee/invite.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/screens/photo_viewer_screen.dart';
import 'package:keepsy/ui/theme/app_theme.dart';
import 'package:keepsy/ui/widgets/add_member_dialog.dart';
import 'package:keepsy/ui/widgets/encrypted_thumbnail.dart';

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

  @override
  void initState() {
    super.initState();
    _media = widget.mediaApi ?? MediaApi(ApiClient());
    _loadMembers();
    _loadMedia();
  }

  Future<void> _loadMembers() async {
    final members = await widget.albumService.listMembers(widget.album.id);
    if (mounted) {
      setState(() {
        _members = members;
        _loadingMembers = false;
      });
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
    // Capture providers up front so we never re read context across async gaps
    final aks = context.read<AlbumKeyStore>();
    final messenger = ScaffoldMessenger.of(context);

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    setState(() => _uploading = true);
    try {
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
      await _loadMedia();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  void dispose() {
    if (widget.mediaApi == null) _media.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final dark = state.isDark;
    final accent = state.accent;
    final syncing = state.isSyncing(widget.album.id);

    return Scaffold(
      backgroundColor: K.bg(dark),
      appBar: AppBar(
        backgroundColor: K.bg(dark),
        elevation: 0,
        // decode name_ct using AlbumKeyStore.useMk to
        // render the real album name. Rn the placeholder is the base64
        // ciphertext (set in AlbumModel.fromJson)
        title: Text(
          widget.album.name,
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
          IconButton(
            icon: Icon(Icons.settings_outlined, color: K.t2(dark)),
            onPressed: () {},
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: (syncing || _uploading) ? null : _pickAndUpload,
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
              accent: accent),
          const Divider(height: 1, thickness: 0.5),
          Expanded(
            child: syncing
                ? const _SyncingPlaceholder()
                : _MediaGrid(
                    items: _items,
                    loading: _loadingMedia,
                    dark: dark,
                    media: _media,
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
  final MediaApi media;

  const _MediaGrid({
    required this.items,
    required this.loading,
    required this.dark,
    required this.media,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return _MediaEmpty(dark: dark);
    }
    final aks = context.read<AlbumKeyStore>();
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
                aks: aks,
                media: media,
              ),
            ),
          ),
          child: EncryptedThumbnail(record: items[i], aks: aks, media: media),
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

  const _MemberChipsRow({
    required this.members,
    required this.loading,
    required this.dark,
    required this.accent,
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
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        itemCount: members.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => _MemberChip(member: members[i], dark: dark),
      ),
    );
  }
}

class _MemberChip extends StatelessWidget {
  final AlbumMember member;
  final bool dark;

  const _MemberChip({required this.member, required this.dark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: K.cardCol(dark),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: K.borderCol(dark)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 10,
            backgroundColor: K.defaultAccent.withValues(alpha: 0.3),
            child: Text(
              member.displayInitial,
              style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: Colors.white),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            // M7 : displayName falls back to a token slice until name_ct
            // decryption wires up in Phase 5
            member.displayName,
            style: TextStyle(
                color: K.t1(dark), fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 4),
          Text(
            member.role,
            style: TextStyle(color: K.t3(dark), fontSize: 10),
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
