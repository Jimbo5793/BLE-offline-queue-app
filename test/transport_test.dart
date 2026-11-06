import 'dart:convert';
import 'dart:typed_data';

import 'package:beaconq/identity/signing.dart';
import 'package:beaconq/transport/chunking.dart';
import 'package:beaconq/transport/envelope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('envelope', () {
    test('survives encode and decode with every field', () {
      final original = Envelope.json(
        messageId: 'm-1',
        senderId: 'sender',
        type: MsgType.heartbeat,
        body: {'rssi': -60},
      );
      final copy = Envelope.decode(original.encode());

      expect(copy.messageId, 'm-1');
      expect(copy.senderId, 'sender');
      expect(copy.type, MsgType.heartbeat);
      expect(copy.ttl, 1);
      expect(copy.hop, 0);
      expect(copy.json['rssi'], -60);
    });

    test('rejects a version 1 frame', () {
      final bytes = Envelope.json(
        senderId: 'sender',
        type: MsgType.joinRequest,
        body: {'name': 'Ana'},
      ).encode();
      bytes[0] = 1;
      expect(() => Envelope.decode(bytes), throwsFormatException);
    });

    test('a signed envelope verifies, and still verifies once forwarded',
        () async {
      final signing = Signing();
      final keyPair = await signing.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final envelope = await Envelope.signed(
        keyPair: keyPair,
        senderId: Signing.encodeUserId(publicKey.bytes),
        type: MsgType.claimRequest,
        payload: Uint8List.fromList(utf8.encode('{"kind":"pin"}')),
      );

      final received = Envelope.decode(envelope.encode());
      expect(await received.verify(), isTrue);
      expect(await received.forwarded().verify(), isTrue);
    });

    test('an unsigned envelope never verifies', () async {
      final envelope = Envelope.json(
        senderId: 'sender',
        type: MsgType.joinRequest,
        body: {'name': 'Ana'},
      );
      expect(await envelope.verify(), isFalse);
    });

    test('message type numbers never move', () {
      expect(MsgType.joinRequest.index, 1);
      expect(MsgType.heartbeat.index, 6);
      expect(MsgType.roster.index, 9);
      expect(MsgType.sessionNotice.index, 11);
      expect(() => MsgType.fromByte(200), throwsFormatException);
    });
  });

  group('chunking', () {
    test('a message split into pieces reassembles in any order', () {
      final bytes =
          Uint8List.fromList(List.generate(500, (i) => i % 256));
      final pieces = Chunker.split(
        messageId: 'm-7',
        bytes: bytes,
        maxChunkSize: 23,
      );
      expect(pieces.length, greaterThan(1));

      final reassembler = Reassembler();
      Uint8List? result;
      for (final piece in pieces.reversed) {
        result = reassembler.accept(piece);
      }
      expect(result, equals(bytes));
      expect(reassembler.pending, 0);
    });

    test('a nonsense piece throws instead of crashing', () {
      expect(
        () => Reassembler().accept(Uint8List.fromList([1, 5, 2, 65])),
        throwsFormatException,
      );
    });

    test('payload size follows the MTU within 20 to 512 bytes', () {
      expect(Chunker.payloadForMtu(23), 20);
      expect(Chunker.payloadForMtu(185), 182);
      expect(Chunker.payloadForMtu(1000), 512);
    });
  });

  group('dedupe cache', () {
    test('accepts each message id once', () {
      final cache = DedupeCache();
      expect(cache.register('a'), isTrue);
      expect(cache.register('a'), isFalse);
    });

    test('forgets the oldest id when full', () {
      final cache = DedupeCache(capacity: 2);
      cache.register('a');
      cache.register('b');
      cache.register('c');
      expect(cache.contains('a'), isFalse);
      expect(cache.contains('c'), isTrue);
    });
  });
}
