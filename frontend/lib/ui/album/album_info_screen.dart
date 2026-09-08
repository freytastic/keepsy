import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

import 'album_copy.dart';
import 'album_stats.dart';
import 'member_avatars.dart';

// Returns null until the member name is decrypted
typedef MemberNameLookup = String? Function(String memberToken);

class AlbumInfoScreen extends StatelessWidget {
  final String albumName;
  final DateTime createdAt;
  final AlbumStats stats;
  final MemberNameLookup nameOf;

  const AlbumInfoScreen({
    super.key,
    required this.albumName,
    required this.createdAt,
    required this.stats,
    required this.nameOf,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Warm.ground,
      appBar: AppBar(
        backgroundColor: Warm.ground,
        elevation: 0,
        iconTheme: const IconThemeData(color: Warm.ink),
        title: const Text(AlbumCopy.infoTitle,
            style: TextStyle(
                color: Warm.ink, fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        children: [
          Text(albumName, style: _title),
          const SizedBox(height: 22),
          _Fact(label: AlbumCopy.infoCreated, value: _formatDate(createdAt)),
          _Fact(label: AlbumCopy.infoPhotos, value: '${stats.photoCount}'),
          _Fact(
              label: AlbumCopy.infoSize,
              value: AlbumStats.formatBytes(stats.totalBytes)),
          _Fact(label: AlbumCopy.infoPeople, value: '${stats.peopleCount}'),
          const SizedBox(height: 10),
          Text(AlbumCopy.infoExactBytes, style: _note),
          const SizedBox(height: 30),
          Text(AlbumCopy.infoStorage, style: _section),
          const SizedBox(height: 12),
          if (stats.perUploader.isEmpty)
            Text(AlbumCopy.infoStorageEmpty, style: _note)
          else
            for (final entry in stats.byWeight)
              _UploaderRow(
                token: entry.key,
                name: nameOf(entry.key),
                tally: entry.value,
                share: stats.totalBytes == 0
                    ? 0
                    : entry.value.bytes / stats.totalBytes,
              ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime d) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June', //
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  static const _title = TextStyle(
    fontSize: 25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.65,
    height: 1.14,
    color: Warm.ink,
  );

  static const _section = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
    color: Warm.ink,
  );

  static const _note =
      TextStyle(fontSize: 12.5, height: 1.45, color: Warm.inkSoft);
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;

  const _Fact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 14, color: Warm.inkSoft)),
          Text(value,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: Warm.ink)),
        ],
      ),
    );
  }
}

class _UploaderRow extends StatelessWidget {
  final String token;
  final String? name;
  final UploaderTally tally;
  final double share;

  const _UploaderRow({
    required this.token,
    required this.name,
    required this.tally,
    required this.share,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: MemberAvatars.hueFor(token),
                  shape: BoxShape.circle,
                ),
                child: Text(MemberAvatars.initialFor(name),
                    style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Warm.inkSoft,
                        height: 1)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  // Never show member tokens as names
                  name ?? AlbumCopy.unknownMember,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Warm.ink),
                ),
              ),
              Text(
                '${tally.photos} · ${AlbumStats.formatBytes(tally.bytes)}',
                style: const TextStyle(fontSize: 12.5, color: Warm.inkSoft),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: share.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: Warm.wellEmpty,
              valueColor:
                  AlwaysStoppedAnimation<Color>(MemberAvatars.hueFor(token)),
            ),
          ),
        ],
      ),
    );
  }
}
