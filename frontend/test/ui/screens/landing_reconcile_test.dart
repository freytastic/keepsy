import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/data/storage/account_owner.dart';
import 'package:keepsy/domain/account/account_gate.dart';
import 'package:keepsy/domain/account/sign_in_gate.dart';
import 'package:keepsy/ui/screens/landing_screen.dart';

import '../../secure_store/mock_secure_key_store.dart';

void main() {
  const userA = '11111111-1111-4111-8111-111111111111';
  final ikA = Uint8List.fromList(List.filled(32, 1));
  final lkA = Uint8List.fromList(List.filled(32, 2));

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
    bool residual = false,
    ServerIdentityState server = ServerIdentityState.unpublished,
    Uint8List? serverIk,
    Uint8List? serverLk,
    bool throws = false,
  }) =>
      SignInGate(
        owner: owner,
        readLocalIdentity: () async {
          if (throws) throw StateError('unreachable');
          return (ik: localIk, lk: localLk);
        },
        hasResidualVault: () async => residual,
        readServerIdentity: () async =>
            (state: server, ik: serverIk, lk: serverLk),
      );

  // Reconciliation must outlive Landing's replacement by MainShell
  test('a null user id refuses without consulting the gate', () async {
    var asked = false;
    final outcome = await reconcileAccount(
      gate: gate(throws: true),
      userId: null,
      discardSession: () async => asked = true,
    );

    expect(outcome, AccountGateOutcome.connectionRequired);
    expect(asked, isTrue, reason: 'a refusal must discard the session');
  });

  test('an unclaimable vault discards the session', () async {
    var discarded = false;
    final outcome = await reconcileAccount(
      gate: gate(residual: true),
      userId: userA,
      discardSession: () async => discarded = true,
    );

    expect(outcome, AccountGateOutcome.unclaimedVault);
    expect(discarded, isTrue);
  });

  // Deleting the stranded account needs the session that reached it
  test('a lost device keeps its session', () async {
    var discarded = false;
    final outcome = await reconcileAccount(
      gate: gate(
        server: ServerIdentityState.published,
        serverIk: ikA,
        serverLk: lkA,
      ),
      userId: userA,
      discardSession: () async => discarded = true,
    );

    expect(outcome, AccountGateOutcome.lostDevice);
    expect(discarded, isFalse);
  });

  test('an admitted vault keeps its session', () async {
    var discarded = false;
    await owner.bind(userA);
    final outcome = await reconcileAccount(
      gate: gate(
        localIk: ikA,
        localLk: lkA,
        server: ServerIdentityState.published,
        serverIk: ikA,
        serverLk: lkA,
      ),
      userId: userA,
      discardSession: () async => discarded = true,
    );

    expect(outcome, AccountGateOutcome.proceed);
    expect(discarded, isFalse);
  });

  test('a gate that throws refuses rather than admitting', () async {
    var discarded = false;
    final outcome = await reconcileAccount(
      gate: gate(throws: true),
      userId: userA,
      discardSession: () async => discarded = true,
    );

    expect(outcome, AccountGateOutcome.connectionRequired);
    expect(discarded, isTrue);
  });
}
