import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/domain/account/account_gate.dart';

void main() {
  const userA = '11111111-1111-4111-8111-111111111111';
  const userB = '22222222-2222-4222-8222-222222222222';

  final ikA = Uint8List.fromList(List.filled(32, 1));
  final lkA = Uint8List.fromList(List.filled(32, 2));
  final ikOther = Uint8List.fromList(List.filled(32, 9));
  final lkOther = Uint8List.fromList(List.filled(32, 8));

  AccountGateOutcome classify({
    String? owner,
    String authenticated = userA,
    Uint8List? localIk,
    Uint8List? localLk,
    bool residualVault = false,
    ServerIdentityState server = ServerIdentityState.unpublished,
    Uint8List? serverIk,
    Uint8List? serverLk,
  }) =>
      AccountGate.classify(
        boundOwner: owner,
        authenticatedUserId: authenticated,
        localIk: localIk,
        localLk: localLk,
        hasResidualVault: residualVault,
        server: (state: server, ik: serverIk, lk: serverLk),
      );

  group('a vault bound to someone else', () {
    test('is refused whatever its key state', () {
      expect(
        classify(owner: userA, authenticated: userB),
        AccountGateOutcome.blockedDifferentAccount,
      );
      expect(
        classify(
          owner: userA,
          authenticated: userB,
          localIk: ikA,
          localLk: lkA,
          server: ServerIdentityState.published,
          serverIk: ikA,
          serverLk: lkA,
        ),
        AccountGateOutcome.blockedDifferentAccount,
      );
    });

    test('is refused even when the server cannot be reached', () {
      expect(
        classify(
          owner: userA,
          authenticated: userB,
          server: ServerIdentityState.unavailable,
        ),
        AccountGateOutcome.blockedDifferentAccount,
      );
    });
  });

  group('an unbound vault that still holds keys', () {
    // Publication state cannot attribute unbound keys from another account
    test('is unclaimed when the account has published no identity', () {
      expect(
        classify(localIk: ikA, localLk: lkA),
        AccountGateOutcome.unclaimedVault,
      );
    });

    test('adopts the keys only on an exact match with the published identity',
        () {
      expect(
        classify(
          localIk: ikA,
          localLk: lkA,
          server: ServerIdentityState.published,
          serverIk: ikA,
          serverLk: lkA,
        ),
        AccountGateOutcome.adoptUnbound,
      );
    });

    test('refuses to adopt when only the signing key matches', () {
      expect(
        classify(
          localIk: ikA,
          localLk: lkOther,
          server: ServerIdentityState.published,
          serverIk: ikA,
          serverLk: lkA,
        ),
        AccountGateOutcome.lostDevice,
      );
    });

    test('refuses to adopt keys belonging to some other account', () {
      expect(
        classify(
          localIk: ikOther,
          localLk: lkOther,
          server: ServerIdentityState.published,
          serverIk: ikA,
          serverLk: lkA,
        ),
        AccountGateOutcome.lostDevice,
      );
    });

    // An unreachable server cannot prove who owns unbound keys
    test('waits for the server rather than guessing', () {
      expect(
        classify(
          localIk: ikA,
          localLk: lkA,
          server: ServerIdentityState.unavailable,
        ),
        AccountGateOutcome.connectionRequired,
      );
    });
  });

  group('an unbound vault holding only part of an identity', () {
    // A partial identity must not be classified as an empty installation
    test('a lone signing key is not an empty installation', () {
      expect(classify(localIk: ikA), AccountGateOutcome.unclaimedVault);
    });

    test('a lone agreement key is not an empty installation', () {
      expect(classify(localLk: lkA), AccountGateOutcome.unclaimedVault);
    });

    test('album keys without an identity are not an empty installation', () {
      expect(
        classify(residualVault: true),
        AccountGateOutcome.unclaimedVault,
      );
    });

    // A published identity cannot vouch for incomplete local material
    test('residue is refused even when the account has an identity', () {
      expect(
        classify(
          localIk: ikA,
          residualVault: true,
          server: ServerIdentityState.published,
          serverIk: ikA,
          serverLk: lkA,
        ),
        AccountGateOutcome.unclaimedVault,
      );
    });

    // The owner marker is the one thing that can vouch for residue
    test('the owner may still resume over its own residue', () {
      expect(
        classify(owner: userA, localIk: ikA, residualVault: true),
        AccountGateOutcome.newAccount,
      );
    });
  });

  group('an unbound vault with no keys', () {
    test('is a new account when the server has no identity either', () {
      expect(classify(), AccountGateOutcome.newAccount);
    });

    test('is a lost device when the server already holds an identity', () {
      expect(
        classify(
          server: ServerIdentityState.published,
          serverIk: ikA,
          serverLk: lkA,
        ),
        AccountGateOutcome.lostDevice,
      );
    });

    test('waits rather than generating an identity it may have to throw away',
        () {
      expect(
        classify(server: ServerIdentityState.unavailable),
        AccountGateOutcome.connectionRequired,
      );
    });
  });

  group('a vault bound to the account signing in', () {
    test('proceeds when the local keys are the published identity', () {
      expect(
        classify(
          owner: userA,
          localIk: ikA,
          localLk: lkA,
          server: ServerIdentityState.published,
          serverIk: ikA,
          serverLk: lkA,
        ),
        AccountGateOutcome.proceed,
      );
    });

    // The owner marker lets an attributed vault open offline
    test('proceeds offline without consulting the server', () {
      expect(
        classify(
          owner: userA,
          localIk: ikA,
          localLk: lkA,
          server: ServerIdentityState.unavailable,
        ),
        AccountGateOutcome.proceed,
      );
    });

    test('resumes publishing keys an interrupted bootstrap left behind', () {
      expect(
        classify(owner: userA, localIk: ikA, localLk: lkA),
        AccountGateOutcome.newAccount,
      );
    });

    test('reports a lost device when the local keys are not the account keys',
        () {
      expect(
        classify(
          owner: userA,
          localIk: ikOther,
          localLk: lkOther,
          server: ServerIdentityState.published,
          serverIk: ikA,
          serverLk: lkA,
        ),
        AccountGateOutcome.lostDevice,
      );
    });

    test('reports a lost device when its keys are gone', () {
      expect(
        classify(
          owner: userA,
          server: ServerIdentityState.published,
          serverIk: ikA,
          serverLk: lkA,
        ),
        AccountGateOutcome.lostDevice,
      );
    });
  });

  group('which outcomes may continue into the app', () {
    // No refusal may fall through to shelf loading
    test('only the three settled outcomes continue', () {
      expect(AccountGate.admitsShelf(AccountGateOutcome.proceed), isTrue);
      expect(AccountGate.admitsShelf(AccountGateOutcome.adoptUnbound), isTrue);
      expect(AccountGate.admitsShelf(AccountGateOutcome.newAccount), isTrue);
    });

    test('every refusal stops the flow', () {
      expect(AccountGate.admitsShelf(AccountGateOutcome.lostDevice), isFalse);
      expect(
          AccountGate.admitsShelf(AccountGateOutcome.blockedDifferentAccount),
          isFalse);
      expect(
          AccountGate.admitsShelf(AccountGateOutcome.unclaimedVault), isFalse);
      expect(AccountGate.admitsShelf(AccountGateOutcome.connectionRequired),
          isFalse);
    });
  });

  group('which outcomes may keep the session', () {
    // Refused credentials must not reopen the vault offline
    test('a refused vault does not keep credentials', () {
      expect(
          AccountGate.retainsSession(
              AccountGateOutcome.blockedDifferentAccount),
          isFalse);
      expect(AccountGate.retainsSession(AccountGateOutcome.unclaimedVault),
          isFalse);
      expect(AccountGate.retainsSession(AccountGateOutcome.connectionRequired),
          isFalse);
    });

    // The lost-device remedy is deleting the account, which needs the session
    test('a lost device keeps its session so deletion can run', () {
      expect(AccountGate.retainsSession(AccountGateOutcome.lostDevice), isTrue);
    });

    test('every settled outcome keeps its session', () {
      expect(AccountGate.retainsSession(AccountGateOutcome.proceed), isTrue);
      expect(
          AccountGate.retainsSession(AccountGateOutcome.adoptUnbound), isTrue);
      expect(AccountGate.retainsSession(AccountGateOutcome.newAccount), isTrue);
    });
  });

  group('seeding the durable shelf at launch', () {
    test('seeds for the account that owns the vault', () {
      expect(AccountGate.maySeedShelf(boundOwner: userA, storedUserId: userA),
          isTrue);
    });

    test('refuses to seed for anyone else', () {
      expect(AccountGate.maySeedShelf(boundOwner: userA, storedUserId: userB),
          isFalse);
    });

    test('refuses to seed when nobody is signed in', () {
      expect(AccountGate.maySeedShelf(boundOwner: userA, storedUserId: null),
          isFalse);
    });

    // An unreconciled vault has no authenticated shelf owner
    test('refuses to seed an unbound vault before reconciliation', () {
      expect(AccountGate.maySeedShelf(boundOwner: null, storedUserId: userA),
          isFalse);
    });
  });
}
