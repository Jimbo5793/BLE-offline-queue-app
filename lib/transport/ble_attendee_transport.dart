import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'chunking.dart';
import 'envelope.dart';
import 'mesh_transport.dart';
import 'protocol.dart';

/// The attendee's Bluetooth code. Finds the host and talks to it.
class BleAttendeeTransport implements MeshTransport {
  BleAttendeeTransport({required this.localId, required this.device});

  @override
  final String localId;

  /// Picked from [discoverSessions]. There's no code to type — the attendee
  /// chose this session from the list of nearby ones.
  final BluetoothDevice device;

  /// Scans for the whole [window] and returns every session found, closest
  /// first.
  ///
  /// It waits for the full time rather than returning the first result,
  /// because you can't say which is closest until you've seen them all — the
  /// first one to answer isn't necessarily the nearest.
  static Future<List<DiscoveredSession>> discoverSessions({
    Duration window = const Duration(seconds: 6),
  }) async {
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      throw StateError('Bluetooth is off');
    }

    final best = <String, DiscoveredSession>{};
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final found = _parse(r);
        if (found == null) continue;
        // Keep the strongest reading for each device. Signal strength
        // jumps around, and the best reading is the more useful one.
        final prev = best[found.deviceId];
        if (prev == null || found.rssi > prev.rssi) best[found.deviceId] = found;
      }
    });

    await FlutterBluePlus.startScan(
      withServices: [Guid(BleIds.serviceUuid)],
      timeout: window,
    );
    await Future<void>.delayed(window + const Duration(milliseconds: 250));
    await sub.cancel();
    await FlutterBluePlus.stopScan();

    return best.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  static DiscoveredSession? _parse(ScanResult r) {
    final raw = r.advertisementData.manufacturerData[BleIds.manufacturerId];
    var title = '';
    var hostName = '';
    var locked = false;
    var count = 0;
    var known = false;

    if (raw != null &&
        raw.length >= 4 &&
        raw[0] == BleIds.advertPayloadVersion) {
      locked = raw[1] == 1;
      count = raw[2];
      final titleLen = raw[3];
      final titleEnd = (4 + titleLen).clamp(4, raw.length);
      title = utf8.decode(raw.sublist(4, titleEnd), allowMalformed: true).trim();
      hostName =
          utf8.decode(raw.sublist(titleEnd), allowMalformed: true).trim();
      known = true;
    }

    return DiscoveredSession(
      deviceId: r.device.remoteId.str,
      stateVersion:
          BleIds.stateVersionFrom(r.advertisementData.advName) ?? 0,
      // Apple hosts can't advertise this at all, so it's often empty.
      // Better to say so than invent a name the host never picked.
      title: title.isEmpty ? 'Nearby session' : title,
      hostName: hostName,
      detailsKnown: known && title.isNotEmpty,
      rssi: r.rssi,
      locked: locked,
      attendeeCount: count,
    );
  }

  /// Looks up a device from the last scan, so the list can hand back
  /// something we can connect to.
  static BluetoothDevice? deviceFor(String remoteId) {
    for (final r in FlutterBluePlus.lastScanResults) {
      if (r.device.remoteId.str == remoteId) return r.device;
    }
    return null;
  }

  final _inbound = StreamController<InboundMessage>.broadcast();
  final _state = StreamController<TransportState>.broadcast();
  final _dedupe = DedupeCache();
  final _reassembler = Reassembler();

  BluetoothDevice? _host;
  BluetoothCharacteristic? _claimRx;
  BluetoothCharacteristic? _heartbeatRx;
  BluetoothCharacteristic? _snapshotTx;
  StreamSubscription<List<int>>? _notifications;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  TransportState _current = TransportState.idle;

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  @override
  Stream<TransportState> get state => _state.stream;

  @override
  TransportState get currentState => _current;

  String get hostPeerId => _host?.remoteId.str ?? 'host';

  @override
  Set<String> get peers =>
      _host == null || _current != TransportState.ready
          ? const {}
          : {hostPeerId};

  void _set(TransportState s) {
    _current = s;
    if (!_state.isClosed) _state.add(s);
  }

  @override
  Future<void> start() async {
    _set(TransportState.starting);
    try {
      if (await FlutterBluePlus.adapterState.first !=
          BluetoothAdapterState.on) {
        throw StateError('Bluetooth is off');
      }

      await device.connect(
        // The Bluetooth library needs a licence stated here. `nonprofit`
        // covers personal and educational use; selling this would need a
        // paid licence.
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
        // Ask for a bigger packet size so updates need fewer pieces. If the
        // phone refuses, our splitting code handles the smallest case.
        mtu: 512,
      );
      _host = device;

      // Services have to be looked up again after every connect.
      //
      // Compared as Guid objects rather than strings. Some UUIDs print in a
      // short form and some in a long one, so comparing text would work or
      // fail depending on which kind of UUID you happened to use.
      final wantService = Guid(BleIds.serviceUuid);
      final services = await device.discoverServices();
      final match =
          services.where((s) => s.uuid == wantService).toList();

      for (final service in match) {
        for (final c in service.characteristics) {
          if (c.uuid == Guid(BleIds.claimRxChar)) _claimRx = c;
          if (c.uuid == Guid(BleIds.heartbeatRxChar)) _heartbeatRx = c;
          if (c.uuid == Guid(BleIds.snapshotTxChar)) _snapshotTx = c;
        }
      }

      if (_claimRx == null || _snapshotTx == null) {
        // List what we actually found. "Service not found" on its own tells
        // you nothing, and this runs on a phone where debugging is awkward.
        final found = StringBuffer()
          ..write('Connected, but the queue service was incomplete. ');
        if (match.isEmpty) {
          found.write(
              'No service with our UUID was offered. Services seen: '
              '${services.map((s) => s.uuid.str128).join(', ')}');
        } else {
          final chars = match
              .expand((s) => s.characteristics)
              .map((c) => c.uuid.str128)
              .join(', ');
          found
            ..write('Service found but missing ')
            ..write([
              if (_claimRx == null) 'claim',
              if (_snapshotTx == null) 'snapshot',
            ].join(' and '))
            ..write('. Characteristics offered: ')
            ..write(chars.isEmpty ? '(none)' : chars);
        }
        throw StateError(found.toString());
      }

      await _snapshotTx!.setNotifyValue(true);
      _notifications = _snapshotTx!.onValueReceived.listen(_onChunk);
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _set(TransportState.failed);
        }
      });

      _set(TransportState.ready);
    } catch (e) {
      _set(TransportState.failed);
      rethrow;
    }
  }

  /// Signal strength to the host.
  ///
  /// The host's Bluetooth library can't measure this, so the attendee reads it
  /// here and sends it with each check-in.
  Future<int> readRssi() async {
    final device = _host;
    if (device == null) throw StateError('not connected');
    return device.readRssi();
  }

  @override
  Future<void> stop() async {
    await _notifications?.cancel();
    await _connSub?.cancel();
    try {
      await _host?.disconnect();
    } catch (_) {
      // Already disconnected.
    }
    _set(TransportState.stopped);
    await _inbound.close();
    await _state.close();
  }

  @override
  int? get connectionLimit => 1;

  /// Connect, send, wait for the reply, disconnect.
  ///
  /// We don't stay connected between requests: a host can only handle about
  /// eight connections and a session might have thirty people. Being turned
  /// away is normal, so the caller retries after a random short wait rather
  /// than treating it as an error.
  @override
  Future<Envelope?> request(
    Envelope command, {
    String? to,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final connected = await _connect();
    if (!connected) return null;

    try {
      final reply = Completer<Envelope>();
      late StreamSubscription<InboundMessage> sub;
      sub = inbound.listen((msg) {
        if (msg.envelope.json['req'] == command.messageId &&
            !reply.isCompleted) {
          reply.complete(msg.envelope);
        }
      });

      await send(command);
      return await reply.future
          .timeout(timeout, onTimeout: () => throw TimeoutException('no reply'))
          .whenComplete(sub.cancel);
    } on TimeoutException {
      return null;
    } finally {
      await _disconnect();
    }
  }

  /// Connects for one request. Returns false if the host is full or out of
  /// range, both of which are worth retrying.
  Future<bool> _connect() async {
    if (_currentlyConnected) return true;
    try {
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 8),
        mtu: 512,
      );
      _host = device;
      await _discoverCharacteristics();
      await _snapshotTx?.setNotifyValue(true);
      _notifications ??= _snapshotTx?.onValueReceived.listen(_onChunk);
      _set(TransportState.ready);
      return true;
    } catch (_) {
      // Refused, out of range, or the host is full. Normal, not an error.
      return false;
    }
  }

  Future<void> _disconnect() async {
    await _notifications?.cancel();
    _notifications = null;
    try {
      await _host?.disconnect();
    } catch (_) {
      // Already gone.
    }
    _host = null;
    _reassembler.clear();
  }

  bool get _currentlyConnected => _host != null;

  Future<void> _discoverCharacteristics() async {
    final wantService = Guid(BleIds.serviceUuid);
    for (final service in await device.discoverServices()) {
      if (service.uuid != wantService) continue;
      for (final c in service.characteristics) {
        if (c.uuid == Guid(BleIds.claimRxChar)) _claimRx = c;
        if (c.uuid == Guid(BleIds.heartbeatRxChar)) _heartbeatRx = c;
        if (c.uuid == Guid(BleIds.snapshotTxChar)) _snapshotTx = c;
      }
    }
  }

  @override
  Future<void> send(Envelope envelope, {String? to}) async {
    final target = envelope.type == MsgType.heartbeat
        ? (_heartbeatRx ?? _claimRx)
        : _claimRx;
    if (target == null) throw StateError('not connected to a host');

    final chunks = Chunker.split(
      messageId: envelope.messageId,
      bytes: envelope.encode(),
      maxChunkSize: Chunker.payloadForMtu(_host?.mtuNow ?? 23),
    );
    for (final chunk in chunks) {
      // Wait for confirmation on each piece, so a full buffer slows us down
      // instead of silently losing part of the message.
      await target.write(chunk);
    }
  }

  void _onChunk(List<int> data) {
    try {
      final complete = _reassembler.accept(
          data is Uint8List ? data : Uint8List.fromList(data));
      if (complete == null) return;
      final envelope = Envelope.decode(complete);
      if (_dedupe.register(envelope.messageId) && !_inbound.isClosed) {
        _inbound
            .add(InboundMessage(envelope: envelope, peerId: hostPeerId));
      }
    } on FormatException {
      _reassembler.clear();
    }
  }
}
