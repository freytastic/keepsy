import 'dart:typed_data';

import 'package:keepsy/data/storage/account_owner.dart';

import 'account_gate.dart';

typedef IdentityPair = ({Uint8List? ik, Uint8List? lk});
typedef LocalIdentityReader = Future<IdentityPair> Function();
typedef ServerIdentityReader = Future<ServerIdentity> Function();
// Detects vault material beyond the identity pair
typedef ResidualVaultProbe = Future<bool> Function();

// Refuses foreign owners before persistence, then resolves authenticated state
class SignInGate {
  final AccountOwnerStore _owner;
  final LocalIdentityReader _readLocalIdentity;
  final ServerIdentityReader _readServerIdentity;
  final ResidualVaultProbe _hasResidualVault;

  SignInGate({
    required AccountOwnerStore owner,
    required LocalIdentityReader readLocalIdentity,
    required ServerIdentityReader readServerIdentity,
    required ResidualVaultProbe hasResidualVault,
  })  : _owner = owner,
        _readLocalIdentity = readLocalIdentity,
        _readServerIdentity = readServerIdentity,
        _hasResidualVault = hasResidualVault;

  // False means this installation belongs to another account
  Future<bool> admits(String authenticatedUserId) async {
    final bound = await _owner.read();
    return bound == null || bound == authenticatedUserId;
  }

  Future<AccountGateOutcome> resolve(String authenticatedUserId) async {
    final bound = await _owner.read();
    final local = await _readLocalIdentity();
    final residual = await _hasResidualVault();
    final server = await _readServerIdentity();

    final outcome = AccountGate.classify(
      boundOwner: bound,
      authenticatedUserId: authenticatedUserId,
      localIk: local.ik,
      localLk: local.lk,
      hasResidualVault: residual,
      server: server,
    );

    // Bind only when the vault is provably attributable to this account
    switch (outcome) {
      case AccountGateOutcome.newAccount:
      case AccountGateOutcome.adoptUnbound:
        await _owner.bind(authenticatedUserId);
      case AccountGateOutcome.proceed:
      case AccountGateOutcome.lostDevice:
      case AccountGateOutcome.blockedDifferentAccount:
      case AccountGateOutcome.unclaimedVault:
      case AccountGateOutcome.connectionRequired:
        break;
    }
    return outcome;
  }
}
