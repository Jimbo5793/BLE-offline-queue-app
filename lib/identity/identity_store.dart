import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'identity.dart';
import 'name_policy.dart';
import 'signing.dart';

/// Creates the account once, then loads it every time after.
///
/// The private key goes into the platform's secure storage — the Keystore on
/// Android, the keychain on macOS. It's never regenerated: losing it loses the
/// identity, which is the whole point of it being unforgeable.
class IdentityStore {
  IdentityStore({
    FlutterSecureStorage? storage,
    Signing? signing,
    this.policy = NamePolicy.defaults,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _signing = signing ?? Signing();

  final FlutterSecureStorage _storage;
  final Signing _signing;
  final NamePolicy policy;

  static const _kPrivateKey = 'queue.identity.privateKey';
  static const _kPublicKey = 'queue.identity.publicKey';
  static const _kName = 'queue.identity.displayName';
  static const _kCreatedAt = 'queue.identity.accountCreatedAt';
  static const _kNameSetAt = 'queue.identity.nameSetAt';

  Future<bool> hasAccount() async =>
      await _storage.read(key: _kPrivateKey) != null;

  /// Loads the saved account, or null if there isn't one yet.
  Future<LocalIdentity?> load() async {
    final priv = await _storage.read(key: _kPrivateKey);
    final pub = await _storage.read(key: _kPublicKey);
    final name = await _storage.read(key: _kName);
    final created = await _storage.read(key: _kCreatedAt);
    final nameSet = await _storage.read(key: _kNameSetAt);
    if (priv == null || pub == null || name == null || created == null) {
      return null;
    }

    final publicKey =
        SimplePublicKey(base64Decode(pub), type: KeyPairType.ed25519);
    final keyPair = SimpleKeyPairData(
      base64Decode(priv),
      publicKey: publicKey,
      type: KeyPairType.ed25519,
    );

    return LocalIdentity(
      userId: Signing.encodeUserId(publicKey.bytes),
      displayName: name,
      accountCreatedAt: int.parse(created),
      nameSetAt: int.parse(nameSet ?? created),
      keyPair: keyPair,
    );
  }

  /// Makes a key pair and saves the account. Only call this when
  /// [hasAccount] is false, or it will overwrite the existing identity.
  Future<LocalIdentity> create({required String displayName, int? nowMs}) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final keyPair = await _signing.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    final name = NameValidator.normalise(displayName);

    await _storage.write(key: _kPrivateKey, value: base64Encode(privateBytes));
    await _storage.write(
        key: _kPublicKey, value: base64Encode(publicKey.bytes));
    await _storage.write(key: _kName, value: name);
    await _storage.write(key: _kCreatedAt, value: '$now');
    await _storage.write(key: _kNameSetAt, value: '$now');

    return LocalIdentity(
      userId: Signing.encodeUserId(publicKey.bytes),
      displayName: name,
      accountCreatedAt: now,
      nameSetAt: now,
      keyPair: keyPair,
    );
  }

  /// Renames if the rules allow it. Returns null when the name is locked, so
  /// the caller can show how long is left instead of doing nothing.
  Future<LocalIdentity?> rename(
    LocalIdentity identity,
    String newName, {
    int? nowMs,
  }) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (!identity.canRename(policy: policy, nowMs: now)) return null;

    final name = NameValidator.normalise(newName);
    await _storage.write(key: _kName, value: name);
    await _storage.write(key: _kNameSetAt, value: '$now');
    return identity.withName(name, nowMs: now);
  }

  /// Deletes the account for good. Only for a deliberate "start again" —
  /// never use this to recover from an error.
  Future<void> destroy() async {
    for (final k in [_kPrivateKey, _kPublicKey, _kName, _kCreatedAt, _kNameSetAt]) {
      await _storage.delete(key: k);
    }
  }
}
