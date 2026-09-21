import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/storage/account_owner.dart';

import '../../secure_store/mock_secure_key_store.dart';

void main() {
  late MockSecureKeyStore store;
  late AccountOwnerStore owner;

  const userA = '11111111-1111-4111-8111-111111111111';
  const userB = '22222222-2222-4222-8222-222222222222';

  setUp(() async {
    store = MockSecureKeyStore();
    await store.initialize();
    owner = AccountOwnerStore(store);
  });

  test('read returns null before any account is bound', () async {
    expect(await owner.read(), isNull);
  });

  test('bind then read returns the bound account', () async {
    await owner.bind(userA);
    expect(await owner.read(), userA);
  });

  test('binding the same account twice is idempotent', () async {
    await owner.bind(userA);
    await owner.bind(userA);
    expect(await owner.read(), userA);
    expect(await store.list(labelPrefix: kAccountOwnerLabel), hasLength(1));
  });

  // Rebinding would hand a second account the first account's keys
  test('binding a different account throws instead of overwriting', () async {
    await owner.bind(userA);
    await expectLater(
      owner.bind(userB),
      throwsA(isA<AccountOwnerConflict>()),
    );
    expect(await owner.read(), userA);
  });

  test('clear releases the binding so a new account can bind', () async {
    await owner.bind(userA);
    await owner.clear();
    expect(await owner.read(), isNull);
    await owner.bind(userB);
    expect(await owner.read(), userB);
  });
}
