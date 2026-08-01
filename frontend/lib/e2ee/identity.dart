import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/wire_format.dart';
import 'package:keepsy/secure_store/key_handle.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

import 'identity_label_map.dart';
import 'prekey_api.dart';

// Manages device identity keys, signed prekeys, and one time prekeys. Bootstrap
// publishes five OPKs; steadystate replenishment raises the pool to 20
// Local keys are persisted before publication so bootstrap can resume safely

typedef Now = DateTime Function();

// Selects the current, unsettled, previous, or most recently archived SPK
enum SpkSlot { current, pending, previous, archived }

// Bootstrap stays small for signup latency; background work fills the target
const int kBootstrapOpkPool = 5;
const int kTargetOpkPool = 20;
const int kReplenishTrigger = 5;
const int kSpkRotationSeconds = 30 * 24 * 3600;
// Leaves a margin inside the server's 5 minute spk_ts skew window
const int kSpkRecoverySkewLimitSeconds = 4 * 60;

// Domain prefix for replenish_sig (§6.5): "opk-batch-v1" || u32_be(N) || SHA256(concat pubs)
final Uint8List _kSaltOpkBatch = Uint8List.fromList('opk-batch-v1'.codeUnits);

// Thrown when bootstrap detects an unrecoverable mismatch between local key
// state and the server's stored identity. The UI should surface this clearly
// rather than retry, since regenerating keys would only reproduce the conflict
class BootstrapAccountConflictException implements Exception {
  final String message;
  const BootstrapAccountConflictException([
    this.message =
        'Server already has an E2EE identity for this account, but this device '
            'does not have the matching private keys.',
  ]);
  @override
  String toString() => 'BootstrapAccountConflictException: $message';
}

// The server advertises an SPK matching neither current nor pending
class SpkReconciliationConflict implements Exception {
  const SpkReconciliationConflict();
  @override
  String toString() =>
      'SpkReconciliationConflict: server spk_pub matches neither the pending '
      'nor the current SPK; pending archived, recovery rotation pending';
}

// The server identity differs from the immutable keys held by this device
class IdentityDivergenceException implements Exception {
  const IdentityDivergenceException();
  @override
  String toString() =>
      'IdentityDivergenceException: server ik_pub/lk_pub do not match this '
      'device';
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length || a.isEmpty) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class IdentityService {
  final SecureKeyStore _store;
  final IdentityLabelMap _labels;
  final PrekeyApi _api;
  final Now _now;

  // Mutex: WS opk_low + cold start replenish collapse to one in-flight call
  Completer<void>? _inflightReplenish;

  // cryptoReady : resolves the first time bootstrap() completes successfully
  // (or immediately if isBootstrapped() was already true). UI surfaces that
  // need IK/LK/SPK (album create, invite, etc) 'await identity.cryptoReady'
  // before calling into the rotator/x3dh so a non-blocking landing flow
  // doesnt race the crypto hygiene running in the background
  Completer<void> _bootstrapDone = Completer<void>();
  Future<void> get cryptoReady => _bootstrapDone.future;

  IdentityService({
    required SecureKeyStore store,
    required IdentityLabelMap labels,
    required PrekeyApi api,
    Now? now,
  })  : _store = store,
        _labels = labels,
        _api = api,
        _now = now ?? DateTime.now;

  // True when keys are generated locally AND both the identity bundle and the
  // initial OPK batch have been accepted server-side. A "false" here is the
  // signal to call bootstrap()
  Future<bool> isBootstrapped() async {
    if (_labels.handleId(kLabelIK) == null) return false;
    if (!await _labels.isIdentityPublished()) return false;
    if (!await _labels.areInitialOpksPublished()) return false;
    return true;
  }

  // Resumable bootstrap: persist keys, publish identity, then publish five OPKs
  // E_IDENTITY_ALREADY_SET is reserved for genuine key divergence
  Future<void> bootstrap() async {
    if (await isBootstrapped()) {
      if (!_bootstrapDone.isCompleted) _bootstrapDone.complete();
      return;
    }
    // Resume path : a prior bootstrap completed with-error left the completer
    // closed. Recreate so callers awaiting cryptoReady get the new outcome
    if (_bootstrapDone.isCompleted) {
      _bootstrapDone = Completer<void>();
    }

    try {
      await _store.initialize();
      final keys = await _ensureKeysGenerated();
      if (!await _labels.isIdentityPublished()) {
        await _publishIdentity(keys);
      }
      if (!await _labels.areInitialOpksPublished()) {
        await _publishInitialOpks(keys);
      }
      _bootstrapDone.complete();
    } catch (e, s) {
      _bootstrapDone.completeError(e, s);
      // If nothing happened to be awaiting cryptoReady, .ignore() prevents
      // the framework from flagging an "unhandled async error" : the
      // rethrow below still surfaces the failure to bootstrap()'s caller
      _bootstrapDone.future.ignore();
      rethrow;
    }
  }

  Future<_BootstrapKeys> _ensureKeysGenerated() async {
    final ikId = _labels.handleId(kLabelIK);
    final lkId = _labels.handleId(kLabelLK);
    final spkId = _labels.handleId(kLabelSpkCurrent);
    // Resume from the fixed bootstrap range, ignoring replenished indices
    final bootstrapOpkLabels = [
      for (var i = 0; i < kBootstrapOpkPool; i++) '$kLabelOpkPrefix$i',
    ];
    final allPresent = ikId != null &&
        lkId != null &&
        spkId != null &&
        bootstrapOpkLabels.every((l) => _labels.handleId(l) != null);

    if (allPresent) {
      return _readKeysFromStore(
        ikId: ikId,
        lkId: lkId,
        spkId: spkId,
        opkLabels: bootstrapOpkLabels,
      );
    }

    // Partial state. Identity must NOT have been marked published, otherwise
    // we'd be in an unrecoverable conflict (server has matching ik_pub but
    // we've lost some of the matching privs)
    if (await _labels.isIdentityPublished()) {
      throw const BootstrapAccountConflictException(
        'Server has an identity for this account but local key state is incomplete.',
      );
    }

    // Fresh slate: drop any leftover label sidecars (ts, half set flags) and
    // generate. Orphaned handles in the secure store (if any) are
    // unaddressable without labels and cost <2KB : user wipeAll cleans them
    await _labels.clearAll();
    return _generateAndPersistKeys();
  }

  Future<_BootstrapKeys> _generateAndPersistKeys() async {
    // Generate every key first, then persist the whole set in one putMany.
    // 23 separate native puts (each re-encrypting + rewriting the entire
    // envelope) was the bootstrap bottleneck
    final entries = <({String label, Uint8List plaintext})>[];
    final seeds = <Uint8List>[];

    // IK = Ed25519 seed (32B)
    final ikSeed = Csprng.bytes(32);
    final ikKp = await KeyHandleAdapter.toEd25519(ikSeed);
    final ikPub = ikKp.publicKey;
    seeds.add(ikSeed);
    entries.add((label: kLabelIK, plaintext: ikSeed));

    // LK = X25519 (32B scalar)
    final lkPriv = Csprng.bytes(32);
    final lkKp = await KeyHandleAdapter.toX25519(lkPriv);
    final lkPub = lkKp.publicKey;
    seeds.add(lkPriv);
    entries.add((label: kLabelLK, plaintext: lkPriv));

    // SPK = X25519
    final spkPriv = Csprng.bytes(32);
    final spkKp = await KeyHandleAdapter.toX25519(spkPriv);
    final spkPub = spkKp.publicKey;
    seeds.add(spkPriv);
    entries.add((label: kLabelSpkCurrent, plaintext: spkPriv));

    // OPKs[0..kBootstrapOpkPool-1] : background replenish raises to target
    final opks = <PrekeyOpk>[];
    for (var i = 0; i < kBootstrapOpkPool; i++) {
      final priv = Csprng.bytes(32);
      final kp = await KeyHandleAdapter.toX25519(priv);
      seeds.add(priv);
      entries.add((label: '$kLabelOpkPrefix$i', plaintext: priv));
      opks.add(PrekeyOpk(idx: i, keyPub: kp.publicKey));
    }

    // Single batched persist. Seeds are zeroed once the bytes have been
    // handed to the store, whether putMany succeeds or throws
    final List<KeyHandle> handles;
    try {
      handles = await _store.putMany(entries);
    } finally {
      for (final s in seeds) {
        s.fillRange(0, s.length, 0);
      }
    }

    // handles[i] aligns with entries[i] : same order in, same order out
    for (var i = 0; i < handles.length; i++) {
      await _labels.set(entries[i].label, handles[i].id);
    }

    return _BootstrapKeys(
      ikHandle: handles[0],
      ikPub: ikPub,
      lkPub: lkPub,
      spkPub: spkPub,
      initialOpks: opks,
    );
  }

  // Reads keys back from the store on a resume path (labels exist, publish
  // didn't finish). Pubs are derived from privs inside use<T> so no plaintext
  // bytes escape the §2.1 zeroing finally
  Future<_BootstrapKeys> _readKeysFromStore({
    required String ikId,
    required String lkId,
    required String spkId,
    required List<String> opkLabels,
  }) async {
    final ikHandle = KeyHandle(id: ikId, label: kLabelIK);
    final ikPub = await _store.use<Uint8List>(ikHandle, (seed) async {
      final kp = await KeyHandleAdapter.toEd25519(seed);
      return kp.publicKey;
    });

    final lkHandle = KeyHandle(id: lkId, label: kLabelLK);
    final lkPub = await _store.use<Uint8List>(lkHandle, (priv) async {
      final kp = await KeyHandleAdapter.toX25519(priv);
      return kp.publicKey;
    });

    final spkHandle = KeyHandle(id: spkId, label: kLabelSpkCurrent);
    final spkPub = await _store.use<Uint8List>(spkHandle, (priv) async {
      final kp = await KeyHandleAdapter.toX25519(priv);
      return kp.publicKey;
    });

    final sortedLabels = List<String>.from(opkLabels)
      ..sort((a, b) {
        final ia = int.parse(a.substring(kLabelOpkPrefix.length));
        final ib = int.parse(b.substring(kLabelOpkPrefix.length));
        return ia.compareTo(ib);
      });

    final initialOpks = <PrekeyOpk>[];
    for (final label in sortedLabels) {
      final idx = int.parse(label.substring(kLabelOpkPrefix.length));
      final hid = _labels.handleId(label)!;
      final h = KeyHandle(id: hid, label: label);
      final pub = await _store.use<Uint8List>(h, (priv) async {
        final kp = await KeyHandleAdapter.toX25519(priv);
        return kp.publicKey;
      });
      initialOpks.add(PrekeyOpk(idx: idx, keyPub: pub));
    }

    return _BootstrapKeys(
      ikHandle: ikHandle,
      ikPub: ikPub,
      lkPub: lkPub,
      spkPub: spkPub,
      initialOpks: initialOpks,
    );
  }

  Future<void> _publishIdentity(_BootstrapKeys keys) async {
    // Fresh ts every publish attempt: a long pause between generation and
    // (resumed) upload would otherwise blow the server's 5 min skew window
    final spkTs = _now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final spkSig = await _signWithIk(
      _spkSigMsg(keys.spkPub, spkTs),
      keys.ikHandle,
    );
    try {
      await _api.upsertIdentity(
        ikPub: keys.ikPub,
        lkPub: keys.lkPub,
        spkPub: keys.spkPub,
        spkSig: spkSig,
        spkTs: spkTs,
      );
    } on PrekeyApiException catch (e) {
      if (e.code == 'E_IDENTITY_ALREADY_SET') {
        // Server's stored ik_pub differs from the one we just signed under
        // The keys in our local store can never be used for this account
        throw const BootstrapAccountConflictException();
      }
      rethrow;
    }
    await _labels.setSpkTs(spkTs);
    await _labels.markIdentityPublished();
  }

  Future<void> _publishInitialOpks(_BootstrapKeys keys) async {
    final replenishSig = await _signWithIk(
      await _replenishMsg(keys.initialOpks),
      keys.ikHandle,
    );
    await _api.replenishOpks(
      opks: keys.initialOpks,
      replenishSig: replenishSig,
    );
    await _labels.markInitialOpksPublished();
  }

  // Serialize reconciliation and rotation across every entry point. Callers
  // queue so each transition re reads the state produced by its predecessor
  Completer<void>? _spkLock;

  Future<void> _withSpkLock(Future<void> Function() fn) async {
    while (_spkLock != null) {
      try {
        await _spkLock!.future;
      } catch (_) {}
    }
    final held = Completer<void>();
    _spkLock = held;
    try {
      await fn();
    } finally {
      _spkLock = null;
      held.complete();
    }
  }

  Future<void> settleSpkState() => _withSpkLock(_settleSpkState);

  Future<void> _settleSpkState() async {
    try {
      await _reconcilePendingSpk();
    } on IdentityDivergenceException {
      developer.log('spk: identity divergence, rotation blocked',
          name: 'keepsy.identity');
      return;
    } on SpkReconciliationConflict {
      developer.log('spk: conflict, recovering with a fresh rotation',
          name: 'keepsy.identity');
    } catch (_) {
      // The responder can use pending while reconciliation is offline
    }

    try {
      await _ensureSpkRotated();
    } catch (_) {
      // Settle an ambiguous result immediately, with at most one recovery retry
      try {
        await _reconcilePendingSpk();
      } on IdentityDivergenceException {
        developer.log('spk: identity divergence, rotation blocked',
            name: 'keepsy.identity');
      } on SpkReconciliationConflict {
        developer.log('spk: conflict after rotation, retrying once',
            name: 'keepsy.identity');
        try {
          await _ensureSpkRotated();
        } catch (_) {}
      } catch (_) {}
    }
  }

  // Rotate after 30 days; all public callers share the SPK transition lock
  Future<void> ensureSpkRotated() => _withSpkLock(_ensureSpkRotated);

  Future<void> _ensureSpkRotated() async {
    final ts = await _labels.getSpkTs();
    if (ts == null) return;
    final nowSec = _now().toUtc().millisecondsSinceEpoch ~/ 1000;
    if (nowSec - ts < kSpkRotationSeconds) return;

    // Never replace a pending key that the server may already advertise
    if (_labels.handleId(kLabelSpkPending) != null) return;

    final ikHandleId = _labels.handleId(kLabelIK);
    if (ikHandleId == null) return;
    final ikHandle = KeyHandle(id: ikHandleId, label: kLabelIK);

    // A recovery timestamp must beat the server's unknown rotation
    final conflictTs = await _labels.getSpkConflictTs();
    var newTs = nowSec;
    if (conflictTs != null && conflictTs + 1 > newTs) {
      newTs = conflictTs + 1;
    }
    // Defer until a monotonic timestamp also fits the server's skew window
    if (newTs - nowSec > kSpkRecoverySkewLimitSeconds) return;

    final newPriv = Csprng.bytes(32);
    final newKp = await KeyHandleAdapter.toX25519(newPriv);
    final newPub = newKp.publicKey;
    // Persist pending before publication; promote only after confirmation
    final newHandle = await _store.put(kLabelSpkPending, newPriv);
    newPriv.fillRange(0, newPriv.length, 0);
    await _labels.set(kLabelSpkPending, newHandle.id);

    final spkSig = await _signWithIk(_spkSigMsg(newPub, newTs), ikHandle);
    final rotationSig = await _signWithIk(
      _rotationSigMsg(newPub, newTs),
      ikHandle,
    );

    await _api.rotateSpk(
      spkPub: newPub,
      spkSig: spkSig,
      spkTs: newTs,
      rotationSig: rotationSig,
    );

    await _promotePendingSpk(newHandle.id, newTs);
  }

  // Promotion is idempotent when an interrupted attempt already moved current
  Future<void> _promotePendingSpk(String pendingId, int ts) async {
    final curId = _labels.handleId(kLabelSpkCurrent);
    if (curId != pendingId) {
      // Demote only : the 30d TTL sweep on .previous is owned by §2.3, not
      // here (locked: spk-prev-ttl-30d)
      if (curId != null) {
        await _labels.set(kLabelSpkPrevious, curId);
      }
      await _labels.set(kLabelSpkCurrent, pendingId);
    }
    await _labels.setSpkTs(ts);
    await _labels.remove(kLabelSpkPending);
    // Clear conflict state only after confirmed promotion.
    await _labels.clearSpkConflict();
  }

  // Resolve a pending rotation from server state: promote on a pending match,
  // discard on a current match, or archive on an unknown SPK. No network call
  // is made when no pending label exists
  Future<void> reconcilePendingSpk() => _withSpkLock(_reconcilePendingSpk);

  Future<void> _reconcilePendingSpk() async {
    final pendingId = _labels.handleId(kLabelSpkPending);
    if (pendingId == null) return;

    final own = await _api.fetchOwnKeys();

    // Verify immutable identity keys before mutating SPK state
    final myIk = await currentIkPub();
    final myLk = await useLk<Uint8List>(
        (priv) async => (await KeyHandleAdapter.toX25519(priv)).publicKey);
    if (!_bytesEqual(own.ikPub, myIk) || !_bytesEqual(own.lkPub, myLk)) {
      await _labels.setSpkConflictTs(own.spkTs ?? _nowSec());
      throw const IdentityDivergenceException();
    }

    final pendingPub = await _store.use<Uint8List>(
      KeyHandle(id: pendingId, label: kLabelSpkPending),
      (priv) async => (await KeyHandleAdapter.toX25519(priv)).publicKey,
    );

    if (_bytesEqual(own.spkPub, pendingPub)) {
      await _promotePendingSpk(pendingId, own.spkTs ?? _nowSec());
      return;
    }

    final curId = _labels.handleId(kLabelSpkCurrent);
    if (curId != null) {
      final curPub = await _store.use<Uint8List>(
        KeyHandle(id: curId, label: kLabelSpkCurrent),
        (priv) async => (await KeyHandleAdapter.toX25519(priv)).publicKey,
      );
      if (_bytesEqual(own.spkPub, curPub)) {
        // Remove the durable reference before deleting the key
        await _labels.remove(kLabelSpkPending);
        try {
          await _store
              .delete(KeyHandle(id: pendingId, label: kLabelSpkPending));
        } catch (_) {}
        return;
      }
    }

    // Keep the latest unacknowledged key for delayed wraps. The unknown server
    // key remains unrecoverable; the replacement restores future delivery
    final oldArchiveId = _labels.handleId(kLabelSpkArchived);
    // Persist the recovery timestamp and label transition before deleting the
    // previous archive. The equality guard prevents deleting an aliased key
    await _labels.setSpkConflictTs(own.spkTs ?? _nowSec());
    await _labels.mutate((m) {
      m[kLabelSpkArchived] = pendingId;
      m.remove(kLabelSpkPending);
    });
    if (oldArchiveId != null && oldArchiveId != pendingId) {
      // Cleanup after the durable transition
      try {
        await _store
            .delete(KeyHandle(id: oldArchiveId, label: kLabelSpkArchived));
      } catch (_) {}
    }
    throw const SpkReconciliationConflict();
  }

  // Diagnostics only marker for an unresolved SPK conflict
  Future<int?> spkConflictTs() => _labels.getSpkConflictTs();

  int _nowSec() => _now().toUtc().millisecondsSinceEpoch ~/ 1000;

  // Shared by cold start and realtime OPK replenishment
  Future<void> replenishOpks({
    int target = kTargetOpkPool,
    int trigger = kReplenishTrigger,
  }) async {
    // Do not add steady state indices until bootstrap is acknowledged
    if (!await isBootstrapped()) return;
    return _replenishMutexed(target, trigger);
  }

  Future<void> _replenishMutexed(int target, int trigger) {
    final inflight = _inflightReplenish;
    if (inflight != null) return inflight.future;
    final c = Completer<void>();
    _inflightReplenish = c;
    _doReplenish(target, trigger)
        .then(
      (_) => c.complete(),
      onError: (Object e, StackTrace s) => c.completeError(e, s),
    )
        .whenComplete(() {
      _inflightReplenish = null;
    });
    return c.future;
  }

  Future<void> _doReplenish(int target, int trigger) async {
    final count = await _api.opkCount();
    if (count >= trigger) return;

    final ikHandleId = _labels.handleId(kLabelIK);
    if (ikHandleId == null) return;
    final ikHandle = KeyHandle(id: ikHandleId, label: kLabelIK);

    // Pick a fresh idx range above any existing keepsy.opk.* label
    final existing = _labels.labelsWithPrefix(kLabelOpkPrefix);
    var maxIdx = -1;
    for (final l in existing) {
      final n = int.tryParse(l.substring(kLabelOpkPrefix.length));
      if (n != null && n > maxIdx) maxIdx = n;
    }

    final needed = target - count;
    final opks = <PrekeyOpk>[];
    for (var k = 0; k < needed; k++) {
      final idx = maxIdx + 1 + k;
      final priv = Csprng.bytes(32);
      final kp = await KeyHandleAdapter.toX25519(priv);
      final h = await _store.put('$kLabelOpkPrefix$idx', priv);
      priv.fillRange(0, priv.length, 0);
      // Label before publication so accepted keys remain addressable. A retry
      // then advances to fresh indices instead of reminting possible conflicts
      await _labels.set('$kLabelOpkPrefix$idx', h.id);
      opks.add(PrekeyOpk(idx: idx, keyPub: kp.publicKey));
    }

    final replenishSig = await _signWithIk(await _replenishMsg(opks), ikHandle);
    await _api.replenishOpks(opks: opks, replenishSig: replenishSig);
  }

  // Signs 'msg' under the IK seed inside a use<T> callback so the seed never
  // escapes lib/secure_store/'s zeroing finally
  Future<Uint8List> _signWithIk(Uint8List msg, KeyHandle ikHandle) {
    return _store.use<Uint8List>(ikHandle, (seed) async {
      final kp = await KeyHandleAdapter.toEd25519(seed);
      return Sign.sign(kp, msg);
    });
  }

  // Pass through to SecureKeyStore.use<T> for the IK / LK / SPK.current handles
  // so callers (X3dhSession et al) dont need SecureKeyStore + IdentityLabelMap
  // refs. Throws StateError when the label isnt set : caller is using a
  // non bootstrapped identity, which is a bug not an expected path
  Future<T> useIk<T>(Future<T> Function(Uint8List seed) fn) {
    final id = _labels.handleId(kLabelIK);
    if (id == null) {
      throw StateError(
        'IK not bootstrapped : IdentityService.bootstrap() first',
      );
    }
    return _store.use<T>(KeyHandle(id: id, label: kLabelIK), fn);
  }

  // Our own Ed25519 IK public key, derived from the seed we hold. safety
  // numbers MUST use this and never the server's copy of our ik_pub : a server
  // that supplied both sides of the comparison could make any number match
  // Public + immutable, so it is cached : the keystore read is an IPC round trip
  Uint8List? _ikPubCache;
  Future<Uint8List> currentIkPub() async {
    final cached = _ikPubCache;
    if (cached != null) return cached;
    final pub = await useIk<Uint8List>((seed) async {
      final kp = await KeyHandleAdapter.toEd25519(seed);
      return kp.publicKey;
    });
    return _ikPubCache = pub;
  }

  Future<T> useLk<T>(Future<T> Function(Uint8List priv) fn) {
    final id = _labels.handleId(kLabelLK);
    if (id == null) {
      throw StateError(
        'LK not bootstrapped : IdentityService.bootstrap() first',
      );
    }
    return _store.use<T>(KeyHandle(id: id, label: kLabelLK), fn);
  }

  // Optional responder fallbacks, checked in order by EpochProcessor
  bool get hasPreviousSpk => _labels.handleId(kLabelSpkPrevious) != null;

  bool get hasPendingSpk => _labels.handleId(kLabelSpkPending) != null;

  bool get hasArchivedSpk => _labels.handleId(kLabelSpkArchived) != null;

  Future<T> useSpk<T>(Future<T> Function(Uint8List priv) fn,
      {SpkSlot slot = SpkSlot.current}) {
    final label = switch (slot) {
      SpkSlot.current => kLabelSpkCurrent,
      SpkSlot.pending => kLabelSpkPending,
      SpkSlot.previous => kLabelSpkPrevious,
      SpkSlot.archived => kLabelSpkArchived,
    };
    final id = _labels.handleId(label);
    if (id == null) {
      throw StateError(switch (slot) {
        SpkSlot.current =>
          'SPK.current not bootstrapped : IdentityService.bootstrap() first',
        SpkSlot.pending => 'SPK.pending not present : no rotation is in flight',
        SpkSlot.previous =>
          'SPK.previous not present : no rotation has happened yet',
        SpkSlot.archived => 'SPK.archived not present : no conflict recorded',
      });
    }
    return _store.use<T>(KeyHandle(id: id, label: label), fn);
  }

  // Responder side OPK access. Returns null (not StateError) when the label
  // is missing : caller decides between OpkNotFoundException and 3-DH (D5)
  Future<T>? tryUseOpk<T>(int idx, Future<T> Function(Uint8List priv) fn) {
    final label = '$kLabelOpkPrefix$idx';
    final id = _labels.handleId(label);
    if (id == null) return null;
    return _store.use<T>(KeyHandle(id: id, label: label), fn);
  }
}

// Internal struct shared across the bootstrap stages
class _BootstrapKeys {
  final KeyHandle ikHandle;
  final Uint8List ikPub;
  final Uint8List lkPub;
  final Uint8List spkPub;
  final List<PrekeyOpk> initialOpks;
  const _BootstrapKeys({
    required this.ikHandle,
    required this.ikPub,
    required this.lkPub,
    required this.spkPub,
    required this.initialOpks,
  });
}

// spk_pub (32) || u64_be(spk_ts) , 40 bytes total
Uint8List _spkSigMsg(Uint8List spkPub, int spkTs) {
  final out = Uint8List(40);
  out.setRange(0, 32, spkPub);
  ByteData.sublistView(out, 32).setUint64(0, spkTs, Endian.big);
  return out;
}

// "rotate-spk-v1" (13) || spk_pub (32) || u64_be(spk_ts) , 53 bytes total
Uint8List _rotationSigMsg(Uint8List spkPub, int spkTs) {
  final salt = kSaltSpkRotate;
  final out = Uint8List(salt.length + 32 + 8);
  out.setRange(0, salt.length, salt);
  out.setRange(salt.length, salt.length + 32, spkPub);
  ByteData.sublistView(out, salt.length + 32).setUint64(0, spkTs, Endian.big);
  return out;
}

// "opk-batch-v1" (12) || u32_be(N) || SHA256(concat raw 32B pubs in order)
Future<Uint8List> _replenishMsg(List<PrekeyOpk> opks) async {
  // Concat raw pubs (not base64)
  final concat = Uint8List(32 * opks.length);
  for (var i = 0; i < opks.length; i++) {
    concat.setRange(i * 32, (i + 1) * 32, opks[i].keyPub);
  }
  final digest = await cg.Sha256().hash(concat);
  final hash = Uint8List.fromList(digest.bytes);
  final salt = _kSaltOpkBatch;
  final out = Uint8List(salt.length + 4 + hash.length);
  out.setRange(0, salt.length, salt);
  ByteData.sublistView(
    out,
    salt.length,
    salt.length + 4,
  ).setUint32(0, opks.length, Endian.big);
  out.setRange(salt.length + 4, out.length, hash);
  return out;
}
