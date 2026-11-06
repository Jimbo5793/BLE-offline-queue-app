import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Signing and verifying messages with Ed25519.
///
/// A user's id is their public key. That means verifying a message needs no
/// lookup table: if the signature matches the key in the sender's id, then the
/// sender holds the matching private key. Nothing to get out of sync.
class Signing {
  Signing({Ed25519? algorithm}) : _algorithm = algorithm ?? Ed25519();

  final Ed25519 _algorithm;

  static const int publicKeyBytes = 32;
  static const int signatureBytes = 64;

  Future<SimpleKeyPair> newKeyPair() => _algorithm.newKeyPair();

  /// The user id: the public key as base64url text, 43 characters.
  static String encodeUserId(List<int> publicKey) =>
      base64Url.encode(publicKey).replaceAll('=', '');

  /// The opposite of [encodeUserId]. Returns null if the id isn't a key,
  /// which is how we spot people the host added by hand.
  static Uint8List? decodeUserId(String userId) {
    try {
      final padded = userId.padRight((userId.length + 3) & ~3, '=');
      final bytes = base64Url.decode(padded);
      return bytes.length == publicKeyBytes ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  static bool isDeviceIdentity(String userId) => decodeUserId(userId) != null;

  /// The exact bytes a signature covers.
  ///
  /// `ttl` and `hop` are left out on purpose. If we ever forward messages
  /// through another phone, those two change along the way, and including
  /// them would break the signature at the first hop. Everything that
  /// actually matters is covered.
  static Uint8List canonicalBytes({
    required String messageId,
    required int type,
    required Uint8List payload,
  }) {
    final id = utf8.encode(messageId);
    return (BytesBuilder(copy: false)
          ..add(utf8.encode('qq1'))
          ..addByte(type)
          ..addByte(id.length)
          ..add(id)
          ..add(payload))
        .toBytes();
  }

  Future<Uint8List> sign({
    required SimpleKeyPair keyPair,
    required String messageId,
    required int type,
    required Uint8List payload,
  }) async {
    final sig = await _algorithm.sign(
      canonicalBytes(messageId: messageId, type: type, payload: payload),
      keyPair: keyPair,
    );
    return Uint8List.fromList(sig.bytes);
  }

  /// Checks [signature] against the public key in [senderId].
  ///
  /// Returns false instead of throwing for every kind of failure, so one
  /// device sending rubbish can't crash the host.
  Future<bool> verify({
    required String senderId,
    required String messageId,
    required int type,
    required Uint8List payload,
    required Uint8List signature,
  }) async {
    if (signature.length != signatureBytes) return false;
    final publicKey = decodeUserId(senderId);
    if (publicKey == null) return false;
    try {
      return await _algorithm.verify(
        canonicalBytes(messageId: messageId, type: type, payload: payload),
        signature: Signature(
          signature,
          publicKey:
              SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
