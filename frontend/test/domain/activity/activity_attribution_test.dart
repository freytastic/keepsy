import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/domain/activity/activity_attribution.dart';
import 'package:keepsy/domain/activity/activity_event.dart';
import 'package:keepsy/e2ee/media_record.dart';

void main() {
  final at = DateTime.utc(2026, 9, 20, 10);

  MediaRecord shot(String id, String uploader, int? seq, {DateTime? when}) =>
      MediaRecord(
        id: id,
        albumId: 'a',
        uploaderToken: uploader,
        wrapNonce: Uint8List(12),
        wrapTagCT: Uint8List(48),
        epochTag: 1,
        blobSize: 10,
        blobSha256: Uint8List(32),
        mediaType: 'photo',
        mimeType: 'image/jpeg',
        createdAt: when ?? at,
        albumSeq: seq,
      );

  PhotosAdded bundle(int count) => PhotosAdded(
        id: 'added:a:7',
        albumId: 'a',
        at: at,
        count: count,
      );

  List<PhotosAdded> attribute(
    List<MediaRecord> media, {
    required int after,
    required int through,
    String? self,
  }) =>
      attributeUploads(
        bundle: bundle(through - after),
        media: media,
        selfToken: self,
        afterSeq: after,
        throughSeq: through,
      );

  test('only uploads confirmed since the last look are counted', () {
    final out = attribute([
      shot('new', 'sam', 6),
      shot('old', 'noor', 5),
      shot('older', 'noor', 4),
    ], after: 5, through: 6);

    expect(out.single.uploaderToken, 'sam');
    expect(out.single.count, 1);
  });

  // A missing new row must not transfer credit to an older survivor
  test('a new photo deleted before the look never borrows an older one', () {
    final out = attribute([
      shot('s7', 'sam', 7),
      // seq 6 was deleted
      shot('n5', 'noor', 5),
    ], after: 5, through: 7);

    // The deleted upload remains as an unnamed count
    final sam = out.firstWhere((e) => e.uploaderToken == 'sam');
    expect(sam.count, 1);
    final unnamed = out.where((e) => e.uploaderToken == null).single;
    expect(unnamed.count, 1);
    expect(out.map((e) => e.uploaderToken), isNot(contains('noor')));
    expect(out.map((e) => e.id).toSet(), hasLength(out.length));
  });

  test('two uploaders become a row each, largest first', () {
    final out = attribute([
      shot('m4', 'sam', 4),
      shot('m3', 'noor', 3),
      shot('m2', 'noor', 2),
      shot('m1', 'noor', 1),
    ], after: 0, through: 4);

    expect(out.map((e) => e.uploaderToken), ['noor', 'sam']);
    expect(out.map((e) => e.count), [3, 1]);
  });

  // Exact attribution is impossible without a sequence, so say photos
  // arrived and name nobody rather than guess
  test('rows without a sequence fall back to the unattributed row', () {
    final out = attribute([
      shot('m2', 'sam', null),
      shot('m1', 'noor', null),
    ], after: 0, through: 2);

    expect(out.single.uploaderToken, isNull);
    expect(out.single.count, 2);
  });

  test('every new photo already deleted falls back to unattributed', () {
    final out = attribute([shot('old', 'noor', 3)], after: 3, through: 5);

    expect(out.single.uploaderToken, isNull);
  });

  test('your own uploads are not reported back to you', () {
    final out = attribute([
      shot('m3', 'me', 3),
      shot('m2', 'me', 2),
      shot('m1', 'noor', 1),
    ], after: 0, through: 3, self: 'me');

    expect(out.single.uploaderToken, 'noor');
  });

  test('an album of only your own uploads reports nothing', () {
    final out = attribute([shot('m2', 'me', 2), shot('m1', 'me', 1)],
        after: 0, through: 2, self: 'me');

    expect(out, isEmpty);
  });

  // A fetch that failed must leave the unattributed row intact rather than
  // silently dropping the fact that photos arrived
  test('no media at all keeps the original unattributed row', () {
    final out = attribute(const [], after: 0, through: 5);

    expect(out.single.uploaderToken, isNull);
    expect(out.single.count, 5);
  });

  test('ids stay stable and distinct per uploader', () {
    List<String> run() =>
        attribute([shot('m2', 'sam', 2), shot('m1', 'noor', 1)],
                after: 0, through: 2)
            .map((e) => e.id)
            .toList();

    expect(run(), run());
    expect(run().toSet(), hasLength(2));
  });

  test('each row carries its uploader\'s newest three photos', () {
    final out = attribute([
      shot('n5', 'noor', 6),
      shot('s1', 'sam', 5),
      shot('n4', 'noor', 4),
      shot('n3', 'noor', 3),
      shot('n2', 'noor', 2),
      shot('n1', 'noor', 1),
    ], after: 0, through: 6);

    final noor = out.firstWhere((e) => e.uploaderToken == 'noor');
    expect(noor.previews.map((r) => r.id), ['n5', 'n4', 'n3']);
    expect(out.firstWhere((e) => e.uploaderToken == 'sam').previews.single.id,
        's1');
  });

  // One shared "latest" put yesterday's upload under Today whenever someone
  // else had uploaded today
  test('each uploader row carries its own newest time', () {
    final today = DateTime.utc(2026, 9, 22, 9);
    final yesterday = DateTime.utc(2026, 9, 21, 9);
    final out = attribute([
      shot('s2', 'sam', 2, when: today),
      shot('n1', 'noor', 1, when: yesterday),
    ], after: 0, through: 2);

    expect(out.firstWhere((e) => e.uploaderToken == 'sam').at, today);
    expect(out.firstWhere((e) => e.uploaderToken == 'noor').at, yesterday);
  });

  test('your own deleted-before-the-look uploads still count as unnamed', () {
    final out =
        attribute([shot('m2', 'me', 2)], after: 0, through: 3, self: 'me');

    expect(out.single.uploaderToken, isNull);
    expect(out.single.count, 2);
  });
}
