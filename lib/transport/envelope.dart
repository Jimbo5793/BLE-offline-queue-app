
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../identity/signing.dart';

/// The kinds of message we send.
///
/// Each one is sent as a single byte, so only ever add new kinds at the END.
/// Reordering this list would make older versions misread every message.
enum MsgType {
  sessionInfo,
  joinRequest,
  joinAck,
  claimRequest,
  claimResult,
  snapshot,
  heartbeat,
  leaveRequest,
  error,
  roster,

  /// An attendee is leaving the session altogether, unlike [leaveRequest]
  /// which only gives up their queue place.
  ///
  /// Without this the host has no quick way to know. It could only notice
  /// check-ins had stopped, which takes three missed ones, and a check taken
  /// in between would count somebody who had already walked out.
  sessionLeave,

  /// Host to attendee, sent without being asked: something has changed about
  /// your place in this session.
  ///
  /// The body has a `reason`: `ended` if the host closed the session, or
  /// `removed` if the host took this person out. Both used to happen silently
  /// — the list just stopped including them, which looks exactly like a lost
  /// message.
  sessionNotice;

  static MsgType fromByte(int b) {
    if (b < 0 || b >= MsgType.values.length) {
      throw FormatException('unknown MsgType byte $b');
    }
    return MsgType.values[b];
  }
}

/// One message.
///
/// Right now everything goes straight from attendee to host, so [ttl] and
/// [hop] are always 1 and 0. They're here so that forwarding messages through
/// other phones could be added later without changing anything above the
/// transport: a forwarding phone would drop [ttl] by one, raise [hop] by one,
/// and ignore anything it had already seen.
class Envelope {
  Envelope({
    String? messageId,
    required this.senderId,
    required this.type,
    required this.payload,
    this.ttl = 1,
    this.hop = 0,
    Uint8List? signature,
  })  : messageId = messageId ?? const Uuid().v4(),
        signature = signature ?? Uint8List(0);

  /// Id for this request. Stays the same across retries, which is how the
  /// host knows not to act on the same thing twice.
  final String messageId;
  final String senderId;
  final MsgType type;
  final Uint8List payload;

  /// How many more times this may be forwarded. Zero means don't.
  final int ttl;

  /// How many times it has been forwarded already.
  final int hop;

  /// The signature. Empty if the message isn't signed.
  ///
  /// The host ignores anything unsigned or wrongly signed, which is what stops
  /// one attendee doing things as somebody else.
  final Uint8List signature;

  bool get isSigned => signature.isNotEmpty;

  factory Envelope.json({
    String? messageId,
    required String senderId,
    required MsgType type,
    required Map<String, Object?> body,
    int ttl = 1,
  }) =>
      Envelope(
        messageId: messageId,
        senderId: senderId,
        type: type,
        ttl: ttl,
        payload: Uint8List.fromList(utf8.encode(jsonEncode(body))),
      );

  Map<String, Object?> get json =>
      jsonDecode(utf8.decode(payload)) as Map<String, Object?>;

  Envelope forwarded() => Envelope(
        messageId: messageId,
        senderId: senderId,
        type: type,
        payload: payload,
        ttl: ttl - 1,
        hop: hop + 1,
        // The signature still works after forwarding, because it doesn't
        // cover ttl or hop.
        signature: signature,
      );

  /// Builds a signed message. [senderId] has to be the public key that goes
  /// with [keyPair], or the other end won't be able to verify it.
  static Future<Envelope> signed({
    required SimpleKeyPair keyPair,
    required String senderId,
    required MsgType type,
    required Uint8List payload,
    String? messageId,
    int ttl = 1,
    Signing? signing,
  }) async {
    final id = messageId ?? const Uuid().v4();
    final sig = await (signing ?? Signing()).sign(
      keyPair: keyPair,
      messageId: id,
      type: type.index,
      payload: payload,
    );
    return Envelope(
      messageId: id,
      senderId: senderId,
      type: type,
      payload: payload,
      ttl: ttl,
      signature: sig,
    );
  }

  static Future<Envelope> signedJson({
    required SimpleKeyPair keyPair,
    required String senderId,
    required MsgType type,
    required Map<String, Object?> body,
    String? messageId,
    int ttl = 1,
    Signing? signing,
  }) =>
      signed(
        keyPair: keyPair,
        senderId: senderId,
        type: type,
        payload: Uint8List.fromList(utf8.encode(jsonEncode(body))),
        messageId: messageId,
        ttl: ttl,
        signing: signing,
      );

  /// True if the signature matches the public key in [senderId]. False for
  /// anything unsigned, broken or faked.
  Future<bool> verify({Signing? signing}) async {
    if (!isSigned) return false;
    return (signing ?? Signing()).verify(
      senderId: senderId,
      messageId: messageId,
      type: type.index,
      payload: payload,
      signature: signature,
    );
  }

  /// Went to 2 when signatures were added. Version 1 messages are rejected
  /// rather than treated as unsigned, so signing can't be bypassed.
  static const int _version = 2;

  /// Wire format:
  ///   version(1) type(1) ttl(1) hop(1) idLen(1) senderLen(1) sigLen(1)
  ///   messageId(idLen) senderId(senderLen) signature(sigLen) payload(rest)
  Uint8List encode() {
    final id = utf8.encode(messageId);
    final sender = utf8.encode(senderId);
    if (id.length > 255 || sender.length > 255) {
      throw ArgumentError('messageId and senderId must each encode to <=255 bytes');
    }
    if (signature.length > 255) {
      throw ArgumentError('signature must be <=255 bytes');
    }
    final out = BytesBuilder(copy: false)
      ..addByte(_version)
      ..addByte(type.index)
      ..addByte(ttl.clamp(0, 255))
      ..addByte(hop.clamp(0, 255))
      ..addByte(id.length)
      ..addByte(sender.length)
      ..addByte(signature.length)
      ..add(id)
      ..add(sender)
      ..add(signature)
      ..add(payload);
    return out.toBytes();
  }

  static Envelope decode(Uint8List bytes) {
    if (bytes.length < 7) throw const FormatException('envelope too short');
    if (bytes[0] != _version) {
      throw FormatException('unsupported envelope version ${bytes[0]}');
    }
    final idLen = bytes[4];
    final senderLen = bytes[5];
    final sigLen = bytes[6];
    const head = 7;
    if (bytes.length < head + idLen + senderLen + sigLen) {
      throw const FormatException('envelope truncated');
    }
    final idEnd = head + idLen;
    final senderEnd = idEnd + senderLen;
    final sigEnd = senderEnd + sigLen;
    return Envelope(
      messageId: utf8.decode(bytes.sublist(head, idEnd)),
      senderId: utf8.decode(bytes.sublist(idEnd, senderEnd)),
      type: MsgType.fromByte(bytes[1]),
      ttl: bytes[2],
      hop: bytes[3],
      signature: Uint8List.sublistView(bytes, senderEnd, sigEnd),
      payload: Uint8List.sublistView(bytes, sigEnd),
    );
  }

  @override
  String toString() => 'Envelope(${type.name}, from=$senderId, '
      'id=${messageId.substring(0, 8)}, ${payload.length}B'
      '${isSigned ? ', signed' : ', UNSIGNED'})';
}

/// Remembers message ids we've seen recently, so a retry is only handled
/// once.
class DedupeCache {
  DedupeCache({this.capacity = 512});

  final int capacity;
  final _seen = <String>{};

  /// True if we hadn't seen this id before, meaning it should be handled.
  bool register(String messageId) {
    if (_seen.contains(messageId)) return false;
    _seen.add(messageId);
    if (_seen.length > capacity) _seen.remove(_seen.first);
    return true;
  }

  bool contains(String id) => _seen.contains(id);
  void clear() => _seen.clear();
  int get length => _seen.length;
}
