import 'dart:convert';
import 'dart:typed_data';

import 'package:beaconq/identity/signing.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final signing = Signing();
  final payload = Uint8List.fromList(utf8.encode('{"name":"Ana"}'));

  Future<String> userIdOf(SimpleKeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    return Signing.encodeUserId(publicKey.bytes);
  }

  group('user id is the public key', () {
    test('round-trips through encode and decode', () async {
      final keyPair = await signing.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final id = Signing.encodeUserId(publicKey.bytes);

      expect(id.length, 43);
      expect(id.contains('='), isFalse);
      expect(Signing.decodeUserId(id), equals(publicKey.bytes));
      expect(Signing.isDeviceIdentity(id), isTrue);
    });

    test('a host-made manual id is not a device identity', () {
      expect(Signing.decodeUserId('manual:3f2a9c'), isNull);
      expect(Signing.isDeviceIdentity('manual:3f2a9c'), isFalse);
      expect(Signing.isDeviceIdentity(''), isFalse);
    });

    test('two accounts never get the same id', () async {
      final a = await userIdOf(await signing.newKeyPair());
      final b = await userIdOf(await signing.newKeyPair());
      expect(a, isNot(equals(b)));
    });
  });

  group('signing', () {
    test('a genuine signature verifies', () async {
      final ana = await signing.newKeyPair();
      final signature = await signing.sign(
        keyPair: ana,
        messageId: 'm-1',
        type: 3,
        payload: payload,
      );

      expect(signature.length, Signing.signatureBytes);
      expect(
        await signing.verify(
          senderId: await userIdOf(ana),
          messageId: 'm-1',
          type: 3,
          payload: payload,
          signature: signature,
        ),
        isTrue,
      );
    });

    test('Bob cannot sign a message as Ana', () async {
      final ana = await signing.newKeyPair();
      final bob = await signing.newKeyPair();
      final signature = await signing.sign(
        keyPair: bob,
        messageId: 'm-1',
        type: 3,
        payload: payload,
      );

      expect(
        await signing.verify(
          senderId: await userIdOf(ana),
          messageId: 'm-1',
          type: 3,
          payload: payload,
          signature: signature,
        ),
        isFalse,
      );
    });

    test('a tampered payload fails', () async {
      final ana = await signing.newKeyPair();
      final signature = await signing.sign(
        keyPair: ana,
        messageId: 'm-1',
        type: 3,
        payload: payload,
      );
      final tampered = Uint8List.fromList(utf8.encode('{"name":"Bob"}'));

      expect(
        await signing.verify(
          senderId: await userIdOf(ana),
          messageId: 'm-1',
          type: 3,
          payload: tampered,
          signature: signature,
        ),
        isFalse,
      );
    });

    test('a signature cannot be reused under another message id or type',
        () async {
      final ana = await signing.newKeyPair();
      final id = await userIdOf(ana);
      final signature = await signing.sign(
        keyPair: ana,
        messageId: 'm-1',
        type: 3,
        payload: payload,
      );

      expect(
        await signing.verify(
          senderId: id,
          messageId: 'm-2',
          type: 3,
          payload: payload,
          signature: signature,
        ),
        isFalse,
      );
      expect(
        await signing.verify(
          senderId: id,
          messageId: 'm-1',
          type: 4,
          payload: payload,
          signature: signature,
        ),
        isFalse,
      );
    });

    test('malformed input returns false instead of throwing', () async {
      final ana = await signing.newKeyPair();
      final id = await userIdOf(ana);

      expect(
        await signing.verify(
          senderId: id,
          messageId: 'm-1',
          type: 3,
          payload: payload,
          signature: Uint8List(10),
        ),
        isFalse,
      );
      expect(
        await signing.verify(
          senderId: 'manual:not-a-key',
          messageId: 'm-1',
          type: 3,
          payload: payload,
          signature: Uint8List(Signing.signatureBytes),
        ),
        isFalse,
      );
    });
  });

  test('signed bytes start with the protocol prefix and exclude ttl and hop',
      () {
    final bytes = Signing.canonicalBytes(
      messageId: 'ab',
      type: 7,
      payload: Uint8List.fromList([1, 2]),
    );

    final expected = [...utf8.encode('qq1'), 7, 2, ...utf8.encode('ab'), 1, 2];
    expect(bytes, equals(expected));
  });
}
