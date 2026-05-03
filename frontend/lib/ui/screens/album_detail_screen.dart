import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/api/album_api.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/member_model.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/theme/app_theme.dart';

class AlbumDetailScreen extends StatefulWidget {
  final AlbumModel album;
  final AlbumService albumService;

  AlbumDetailScreen(
      {super.key, required this.album, AlbumService? albumService})
      : albumService = albumService ?? AlbumService();

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  List<AlbumMember> _members = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    final members = await widget.albumService.listMembers(widget.album.id);
    if (mounted)
      setState(() {
        _members = members;
        _loading = false;
      });
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
        // todo (p1): decode name_ct with AES-GCM to get the real album name
        title: Text(
          widget.album.name,
          style: TextStyle(
            color: K.t1(dark),
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        iconTheme: IconThemeData(color: K.t1(dark)),
        actions: [
          IconButton(
            icon: Icon(Icons.person_add_outlined, color: K.t2(dark)),
            onPressed: () {},
          ),
          IconButton(
            icon: Icon(Icons.settings_outlined, color: K.t2(dark)),
            onPressed: () {},
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MemberChipsRow(
              members: _members, loading: _loading, dark: dark, accent: accent),
          const Divider(height: 1, thickness: 0.5),
          Expanded(child: _MediaPlaceholder(dark: dark)),
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
            member.profile.name ?? member.memberToken.substring(0, 8),
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

class _MediaPlaceholder extends StatelessWidget {
  final bool dark;

  const _MediaPlaceholder({required this.dark});

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
          Text('Encrypted photos will appear here',
              style: TextStyle(color: K.t3(dark), fontSize: 13)),
        ],
      ),
    );
  }
}
