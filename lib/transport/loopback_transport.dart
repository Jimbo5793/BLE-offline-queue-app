import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'envelope.dart';
import 'mesh_transport.dart';

/// A fake network that stands in for Bluetooth, all inside one app.
///
/// The tests run the real queue logic, real messages and real packet splitting
/// against this, so everything above the transport gets tested without needing
/// two phones. Delay and packet loss can be set so ordering can be tested
/// under bad conditions.
class LoopbackNetwork {
  LoopbackNetwork({
    this.minLatency = const Duration(milliseconds: 4),
    this.maxLatency = const Duration(milliseconds: 40),
    this.dropRate = 0.0,
    this.connectionLimit,
    this.connectCost = const Duration(milliseconds: 20),
    Random? random,
  }) : _random = random ?? Random(1337);

  /// How many devices can be connected at once, standing in for the limit of
  /// about eight on a real phone. Null means no limit.
  final int? connectionLimit;

  /// How long connecting and disconnecting takes, so competing for slots
  /// behaves like real Bluetooth instead of finishing instantly.
  final Duration connectCost;

  final _connected = <String>{};

  /// Which devices are connected right now.
  Set<String> get connected => Set.unmodifiable(_connected);

  /// The most that were ever connected at the same time. This is what the
  /// contention tests check.
  int peakConnections = 0;
  int refusedConnections = 0;

  /// Takes a connection slot, or returns false if they're all in use.
  bool acquire(String peerId) {
    if (_connected.contains(peerId)) return true;
    if (connectionLimit != null && _connected.length >= connectionLimit!) {
      refusedConnections++;
      return false;
    }
    _connected.add(peerId);
    peakConnections = max(peakConnections, _connected.length);
    return true;
  }

  void release(String peerId) => _connected.remove(peerId);

  final Duration minLatency;
  final Duration maxLatency;

  /// How often to drop a message, from 0 to 1. Retries plus the host
  /// ignoring repeat requests are what make this survivable.
  final double dropRate;

  final Random _random;
  final _nodes = <String, LoopbackTransport>{};

  /// Who can currently be reached. Removing someone from here is how tests
  /// simulate walking out of range.
  final _reachable = <String>{};

  int sentCount = 0;
  int droppedCount = 0;

  void register(LoopbackTransport node) {
    _nodes[node.localId] = node;
    _reachable.add(node.localId);
  }

  void unregister(String id) {
    _nodes.remove(id);
    _reachable.remove(id);
  }

  /// Simulates an attendee walking out of Bluetooth range.
  void setReachable(String id, bool reachable) {
    if (reachable) {
      _reachable.add(id);
    } else {
      _reachable.remove(id);
    }
  }

  bool isReachable(String id) => _reachable.contains(id);
  Iterable<String> get peers => _nodes.keys;

  Duration _latency() {
    final span = maxLatency.inMicroseconds - minLatency.inMicroseconds;
    return Duration(
        microseconds:
            minLatency.inMicroseconds + (span <= 0 ? 0 : _random.nextInt(span)));
  }

  Future<void> deliver({
    required String from,
    required String? to,
    required Envelope envelope,
  }) async {
    final targets = to == null
        ? _nodes.keys.where((k) => k != from).toList()
        : [if (_nodes.containsKey(to)) to];

    for (final target in targets) {
      sentCount++;
      // Either end being unreachable loses the packet, like a real radio.
      if (!_reachable.contains(target) || !_reachable.contains(from)) {
        droppedCount++;
        continue;
      }
      if (dropRate > 0 && _random.nextDouble() < dropRate) {
        droppedCount++;
        continue;
      }
      final node = _nodes[target];
      if (node == null) continue;
      // Re-encode so tests exercise the real codec rather than sharing objects.
      final bytes = envelope.encode();
      unawaited(Future.delayed(_latency(), () {
        node._receive(from: from, bytes: bytes);
      }));
    }
  }
}

class LoopbackTransport implements MeshTransport {
  LoopbackTransport({required this.localId, required this.network});

  @override
  final String localId;

  final LoopbackNetwork network;

  final _inbound = StreamController<InboundMessage>.broadcast();
  final _state = StreamController<TransportState>.broadcast();
  final _dedupe = DedupeCache();

  TransportState _current = TransportState.idle;

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  @override
  Stream<TransportState> get state => _state.stream;

  @override
  TransportState get currentState => _current;

  void _set(TransportState s) {
    _current = s;
    if (!_state.isClosed) _state.add(s);
  }

  @override
  Future<void> start() async {
    _set(TransportState.starting);
    network.register(this);
    _set(TransportState.ready);
  }

  @override
  Future<void> stop() async {
    network.unregister(localId);
    _set(TransportState.stopped);
    await _inbound.close();
    await _state.close();
  }

  @override
  Set<String> get peers => {
        for (final id in network.peers)
          if (id != localId && network.isReachable(id)) id,
      };

  @override
  int? get connectionLimit => network.connectionLimit;

  /// Connect, send, await the reply, disconnect — the same shape the BLE
  /// transport uses, so contention is exercised in tests rather than only on
  /// a phone.
  @override
  Future<Envelope?> request(
    Envelope command, {
    String? to,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final target = to ?? network.peers.firstWhere((p) => p != localId);
    if (!network.isReachable(target) || !network.isReachable(localId)) {
      return null;
    }
    if (!network.acquire(localId)) return null;

    try {
      await Future<void>.delayed(network.connectCost);

      final reply = Completer<Envelope>();
      late StreamSubscription<InboundMessage> sub;
      sub = inbound.listen((msg) {
        if (msg.envelope.json['req'] == command.messageId &&
            !reply.isCompleted) {
          reply.complete(msg.envelope);
        }
      });

      await network.deliver(from: localId, to: target, envelope: command);
      return await reply.future
          .timeout(timeout, onTimeout: () => throw TimeoutException('no reply'))
          .whenComplete(sub.cancel);
    } on TimeoutException {
      return null;
    } finally {
      await Future<void>.delayed(network.connectCost);
      network.release(localId);
    }
  }

  @override
  Future<void> send(Envelope envelope, {String? to}) =>
      network.deliver(from: localId, to: to, envelope: envelope);

  void _receive({required String from, required List<int> bytes}) {
    if (_inbound.isClosed) return;
    final envelope = Envelope.decode(
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    // Dedupe here rather than in the app: a retry, or the same message arriving
    // twice once relay exists, must surface once.
    if (!_dedupe.register(envelope.messageId)) return;
    _inbound.add(InboundMessage(envelope: envelope, peerId: from));
  }
}
