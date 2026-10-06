import 'dart:typed_data';

// Pure classifier for whether an authenticated account may use the local vault

// Unavailable must remain distinct from an unpublished server identity
enum ServerIdentityState { published, unpublished, unavailable }

typedef ServerIdentity = ({
  ServerIdentityState state,
  Uint8List? ik,
  Uint8List? lk,
});

enum AccountGateOutcome {
  // Vault belongs to this usable account
  proceed,
  // Bound to another account; persist and reveal nothing
  blockedDifferentAccount,
  // Server identity exists but its local private keys are unavailable
  lostDevice,
  // No server identity exists, so bootstrap may publish
  newAccount,
  // Unbound keys exactly match this account's server identity
  adoptUnbound,
  // Unbound material cannot be attributed safely
  unclaimedVault,
  // Server state is required for a safe decision
  connectionRequired,
}

abstract class AccountGate {
  static AccountGateOutcome classify({
    required String? boundOwner,
    required String authenticatedUserId,
    required Uint8List? localIk,
    required Uint8List? localLk,
    // Album keys, sealed catalog entries, or partial-erase residue
    required bool hasResidualVault,
    required ServerIdentity server,
  }) {
    // A foreign owner overrides every other signal
    if (boundOwner != null && boundOwner != authenticatedUserId) {
      return AccountGateOutcome.blockedDifferentAccount;
    }

    final owned = boundOwner != null;
    final hasIdentity = localIk != null && localLk != null;
    // A partial identity is still attributable key material
    final hasMaterial = localIk != null || localLk != null || hasResidualVault;

    // Unowned incomplete material cannot be attributed safely
    if (!owned && !hasIdentity && hasMaterial) {
      return AccountGateOutcome.unclaimedVault;
    }

    if (!hasIdentity) {
      switch (server.state) {
        case ServerIdentityState.published:
          return AccountGateOutcome.lostDevice;
        case ServerIdentityState.unpublished:
          return AccountGateOutcome.newAccount;
        case ServerIdentityState.unavailable:
          // Do not mint keys while publication state is unknown
          return AccountGateOutcome.connectionRequired;
      }
    }

    switch (server.state) {
      case ServerIdentityState.unavailable:
        // The owner marker lets an attributed vault open offline
        return owned
            ? AccountGateOutcome.proceed
            : AccountGateOutcome.connectionRequired;

      case ServerIdentityState.unpublished:
        // Publication state cannot identify unbound local keys
        return owned
            ? AccountGateOutcome.newAccount
            : AccountGateOutcome.unclaimedVault;

      case ServerIdentityState.published:
        // Both halves must match to prevent a signer-only false match
        final matches =
            _sameBytes(localIk, server.ik) && _sameBytes(localLk, server.lk);
        if (!matches) return AccountGateOutcome.lostDevice;
        return owned
            ? AccountGateOutcome.proceed
            : AccountGateOutcome.adoptUnbound;
    }
  }

  // Every refusal stops before the shelf is loaded
  static bool admitsShelf(AccountGateOutcome outcome) => switch (outcome) {
        AccountGateOutcome.proceed => true,
        AccountGateOutcome.adoptUnbound => true,
        AccountGateOutcome.newAccount => true,
        AccountGateOutcome.lostDevice => false,
        AccountGateOutcome.blockedDifferentAccount => false,
        AccountGateOutcome.unclaimedVault => false,
        AccountGateOutcome.connectionRequired => false,
      };

  // Refusals discard credentials except when account deletion needs the session
  static bool retainsSession(AccountGateOutcome outcome) => switch (outcome) {
        AccountGateOutcome.proceed => true,
        AccountGateOutcome.adoptUnbound => true,
        AccountGateOutcome.newAccount => true,
        AccountGateOutcome.lostDevice => true,
        AccountGateOutcome.blockedDifferentAccount => false,
        AccountGateOutcome.unclaimedVault => false,
        AccountGateOutcome.connectionRequired => false,
      };

  // Pre-runApp shelf seeding requires matching owner and session IDs
  static bool maySeedShelf({
    required String? boundOwner,
    required String? storedUserId,
  }) =>
      boundOwner != null && storedUserId == boundOwner;

  static bool _sameBytes(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
