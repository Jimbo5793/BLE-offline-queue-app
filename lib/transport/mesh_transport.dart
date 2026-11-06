import 'dart:async';

import 'envelope.dart';

enum TransportState { idle, starting, ready, failed, stopped }

/// The interface the queue logic and screens talk to. Nothing above this
/// knows whether messages go over Bluetooth or just stay in memory.
///
/// There are three versions: the host's, the attendee's, and a fake one used
/// by the tests. If we ever forward messages between phones, it would only
/// change in here.
abstract class MeshTransport {
  /// Messages for us, with duplicates already filtered out.
  Stream<InboundMessage> get inbound;

  Stream<TransportState> get state;
  TransportState get currentState;

  /// Our own address.
  String get localId;

  /// Who we can currently reach.
  ///
  /// This comes from the operating system, which keeps track of Bluetooth
  /// connections even while the app is asleep. That makes it better evidence
  /// that someone is still here than our own check-ins, which stop as soon as
  /// a phone locks.
  Set<String> get peers => const {};

  Future<void> start();
  Future<void> stop();

  /// Sends to [to], or to everyone if [to] is null.
  Future<void> send(Envelope envelope, {String? to});

  /// Sends something and waits for the reply.
  ///
  /// Over Bluetooth this means connect, send, wait, disconnect. We don't hold
  /// connections open, because a phone can only manage about eight at once and
  /// a session might have thirty people in it.
  ///
  /// Returns null if we couldn't get through at all. That means "try again in
  /// a bit", not "refused" — with only eight slots, being turned away is
  /// normal.
  Future<Envelope?> request(
    Envelope command, {
    String? to,
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      throw UnsupportedError('$runtimeType does not support request/response');

  /// How many devices can be connected at once. Null means no limit.
  int? get connectionLimit => null;
}

/// A message plus which device it arrived from.
class InboundMessage {
  const InboundMessage({required this.envelope, required this.peerId});

  final Envelope envelope;

  /// The device that handed it to us — a Bluetooth device id, or a fake one
  /// in tests. Not the same as `envelope.senderId`, which is who wrote it.
  final String peerId;

  MsgType get type => envelope.type;
}
