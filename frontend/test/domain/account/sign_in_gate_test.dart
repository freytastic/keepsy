import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/storage/account_owner.dart';
import 'package:keepsy/domain/account/account_gate.dart';
import 'package:keepsy/domain/account/sign_in_gate.dart';

import '../../secure_store/mock_secure_key_store.dart';

void main() {
  const userA = '11111111-1111-4111-8111-111111111111';
  const userB = '22222222-2222-4222-8222-222222222222';

  final ikA = Uint8List.fromList(List.filled(32, 1));
  final lkA = Uint8List.fromList(List.filled(32, 2));
  final ikOther = Uint8List.fromList(List.filled(32, 9));

  late MockSecureKeyStore store;
  late AccountOwnerStore owner;

  setUp(() async {
    store = MockSecureKeyStore();
    await store.initialize();
    owner = AccountOwnerStore(store);
  });

  SignInGate gate({
    Uint8List? localIk,
    Uint8List? localLk,
    bool residualVault = false,
    ServerIdentityState server = ServerIdentityState.unpublished,
    Uint8List? serverIk,
    Uint8List? serverLk,
  }) =>
      SignInGate(
        owner: owner,
        readLocalIdentity: () async => (ik: localIk, lk: localLk),
        hasResidualVault: () async => residualVault,
        readServerIdentity: () async =>
            (state: server, ik: serverIk, lk: serverLk),
      );

  group('admits, before any credential is written', () {
    test('lets any account onto an unbound device', () async {
      expect(await gate().admits(userA), isTrue);
    });

    test('lets the owner back in', () async {
      await owner.bind(userA);
      expect(await gate().admits(userA), isTrue);
    });

    test('refuses a different account', () async {
      await owner.bind(userA);
      expect(await gate().admits(userB), isFalse);
    });
  });

  group('resolve, after the session is committed', () {
    test('binds the owner for a brand new account', () async {
      final outcome = await gate().resolve(userA);
      expect(outcome, AccountGateOutcome.newAccount);
      expect(await owner.read(), userA);
    });

    test('binds the owner when adopting keys that match the server', () async {
      final outcome = await gate(
        localIk: ikA,
        localLk: lkA,
        server: ServerIdentityState.published,
        serverIk: ikA,
        serverLk: lkA,
      ).resolve(userA);

      expect(outcome, AccountGateOutcome.adoptUnbound);
      expect(await owner.read(), userA);
    });

    // Mismatched keys cannot open this account's album wraps
    test('leaves the device unbound on a lost device', () async {
      final outcome = await gate(
        localIk: ikOther,
        localLk: lkA,
        server: ServerIdentityState.published,
        serverIk: ikA,
        serverLk: lkA,
      ).resolve(userA);

      expect(outcome, AccountGateOutcome.lostDevice);
      expect(await owner.read(), isNull);
    });

    // Unattributable keys must never acquire an owner
    test('never binds a vault it cannot attribute', () async {
      final outcome = await gate(localIk: ikA, localLk: lkA).resolve(userA);
      expect(outcome, AccountGateOutcome.unclaimedVault);
      expect(await owner.read(), isNull);
    });

    test('never binds a vault holding only album keys', () async {
      final outcome = await gate(residualVault: true).resolve(userA);
      expect(outcome, AccountGateOutcome.unclaimedVault);
      expect(await owner.read(), isNull);
    });

    test('never binds while the server is unreachable', () async {
      final outcome = await gate(
        localIk: ikA,
        localLk: lkA,
        server: ServerIdentityState.unavailable,
      ).resolve(userA);
      expect(outcome, AccountGateOutcome.connectionRequired);
      expect(await owner.read(), isNull);
    });

    test('proceeds for the owner without rebinding', () async {
      await owner.bind(userA);
      final outcome = await gate(
        localIk: ikA,
        localLk: lkA,
        server: ServerIdentityState.published,
        serverIk: ikA,
        serverLk: lkA,
      ).resolve(userA);

      expect(outcome, AccountGateOutcome.proceed);
      expect(await owner.read(), userA);
    });
  });
}
