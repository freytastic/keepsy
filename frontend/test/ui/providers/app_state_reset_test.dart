import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/ui/providers/app_state.dart';

AlbumModel _album(String id) => AlbumModel(
      id: id,
      nameCt: 'REAL',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

Future<String> _resolver(String albumId, String? nameCt) async => 'Real Name';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('reset clears all account scoped session state', () async {
    final s = AppState();
    s.attachAlbumNameResolver(_resolver);
    s.setAlbums([_album('a'), _album('b')]);
    s.markSyncing(['a']);
    s.setUnreadNotifications(true);
    await Future<void>.delayed(Duration.zero);

    // state is populated before reset
    expect(s.albums, isNotEmpty);
    expect(s.isSyncing('a'), isTrue);
    expect(s.albumDisplayName('a'), 'Real Name');
    expect(s.hasUnreadNotifications, isTrue);

    s.reset();

    expect(s.albums, isEmpty);
    expect(s.isSyncing('a'), isFalse);
    expect(s.albumDisplayName('a'), isNull);
    expect(s.hasUnreadNotifications, isFalse);
    expect(s.lastRemovedAlbumId, isNull);
  });

  test('reset clears identity, profile and realtime signal fields', () async {
    final s = AppState();
    s.setUserData({'id': 'u1', 'keepsy_id': 'kid-1'});
    s.setEmail('me@example.com');
    s.setProfileName('Alice');
    s.setProfileAvatar('avatar-key');
    s.notifyMediaAdded('alb', 'med');
    s.notifyMemberChanged('alb');

    expect(s.userId, 'u1');
    expect(s.profileName, 'Alice');
    expect(s.memberChangeTick, greaterThan(0));

    s.reset();

    // identity + profile must not survive into the next account's session
    expect(s.userId, isNull);
    expect(s.email, isNull);
    expect(s.keepsyId, isNull);
    expect(s.avatarKey, isNull);
    expect(s.profileName, 'User'); // back to the default placeholder
    // realtime one shot signals
    expect(s.lastMediaAddedAlbumId, isNull);
    expect(s.lastMediaAddedMediaId, isNull);
    expect(s.lastMemberChangedAlbumId, isNull);
    expect(s.memberChangeTick, 0);
  });
}
