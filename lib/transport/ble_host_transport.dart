import 'dart:async';
import 'dart:typed_data';

import 'package:ble_peripheral_plus/ble_peripheral_plus.dart';

import 'dart:convert';

import 'chunking.dart';
import 'envelope.dart';
import 'mesh_transport.dart';
import 'protocol.dart';

/// The host's Bluetooth code. Runs a server that attendees connect to.
///
/// The library uses static callbacks, so this class owns the only copy of them
/// and turns them into streams.
class BleHostTransport implements MeshTransport {
  BleHostTransport({required this.localId});

  @override
  final String localId;

  String _title = '';
  String _hostName = '';
  bool _locked = false;
  int _attendeeCount = 0;
  int _stateVersion = 0;

  final _inbound = StreamController<InboundMessage>.broadcast();
  final _state = StreamController<TransportState>.broadcast();
  final _dedupe = DedupeCache();
  final _reassemblers = <String, Reassembler>{};

  /// The packet size for each connected device. Only the attendee can ask for
  /// a bigger one, so we just record whatever we're told.
  ///
  /// On Apple the number we get is already the usable size, so our maths is
  /// three bytes conservative there. Harmless — smaller packets always fit.
  final _mtu = <String, int>{};

  /// What an attendee gets when it reads the current state.
  ///
  /// Stored ready-to-send because the read callback has to answer straight
  /// away — it can't wait for a database query.
  Uint8List _snapshotBytes = Uint8List(0);

  /// The devices signed up for updates. This is who we actually send to.
  ///
  /// We use this rather than the connect/disconnect callback because that
  /// callback only exists on Android. A Mac host would otherwise never know
  /// anyone had arrived and would broadcast to nobody.
  final _subscribed = <String>{};

  TransportState _current = TransportState.idle;

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  @override
  Stream<TransportState> get state => _state.stream;

  @override
  TransportState get currentState => _current;

  /// Who a broadcast reaches. The operating system keeps this up to date, so
  /// it stays right even while an attendee's phone is locked.
  @override
  Set<String> get peers => Set.unmodifiable(_subscribed);

  void _set(TransportState s) {
    _current = s;
    if (!_state.isClosed) _state.add(s);
  }

  /// Re-advertises so nearby phones can see the current title, lock state and
  /// headcount without connecting.
  ///
  /// The main advert only has about 10 spare bytes, so the title goes in a
  /// second packet which gets its own 31.
  Future<void> publish({
    required String title,
    required bool locked,
    required int attendeeCount,
    String hostName = '',
    int stateVersion = 0,
  }) async {
    _title = title;
    _hostName = hostName;
    _locked = locked;
    _attendeeCount = attendeeCount;
    _stateVersion = stateVersion;
    if (_current != TransportState.ready) return;
    await BlePeripheral.stopAdvertising();
    await _startAdvertising();
  }

  /// Layout: version, locked, headcount, title length, title, host name.
  ///
  /// The title's length comes first so the host name can follow it without
  /// needing a separator character that a name might contain.
  Uint8List _manufacturerPayload() {
    final title = _clip(_title, BleIds.maxAdvertisedTitleBytes);
    final host = _clip(_hostName, BleIds.maxAdvertisedHostBytes);
    return (BytesBuilder(copy: false)
          ..addByte(BleIds.advertPayloadVersion)
          ..addByte(_locked ? 1 : 0)
          ..addByte(_attendeeCount.clamp(0, 255))
          ..addByte(title.length)
          ..add(title)
          ..add(host))
        .toBytes();
  }

  /// Cuts the text short without splitting a character in half, which would
  /// show up as a broken symbol on the other end.
  static List<int> _clip(String value, int maxBytes) {
    var bytes = utf8.encode(value);
    if (bytes.length <= maxBytes) return bytes;
    var end = maxBytes;
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return bytes.sublist(0, end);
  }

  /// Apple ignores the extra advertising data completely, so a Mac or iPhone
  /// host only advertises its service id and short name. The attendee's list
  /// shows a placeholder, and the real title arrives when they join.
  Future<void> _startAdvertising() => BlePeripheral.startAdvertising(
        services: [BleIds.serviceUuid],
        // Capped at 8 characters: the package rejects anything longer on
        // Android when service UUIDs are advertised too, and the radio itself
        // answers ADVERTISE_FAILED_DATA_TOO_LARGE.
        // Carries the state version, which is how a client knows to re-read
        // without connecting. Apple ignores manufacturer data, so this is the
        // only field that reaches every platform.
        localName: BleIds.advertisedName(_stateVersion),
        manufacturerData: ManufacturerData(
          manufacturerId: BleIds.manufacturerId,
          data: _manufacturerPayload(),
        ),
        addManufacturerDataInScanResponse: true,
      );

  /// Waits for Bluetooth to report itself ready.
  ///
  /// On Apple, Bluetooth starts in an unknown state and only becomes ready a
  /// moment later, so setting up the server immediately after starting it
  /// times out. Android doesn't have this problem, which is why the bug only
  /// showed up once the app ran on a Mac.
  ///
  /// The callback is registered BEFORE starting Bluetooth on purpose: it only
  /// fires when the state changes, so registering afterwards can miss the one
  /// change there will ever be and then wait forever. There's no way to just
  /// ask what the state is.
  Completer<bool>? _radioReady;

  void _watchRadio() {
    _radioReady = Completer<bool>();
    BlePeripheral.setBleStateChangeCallback((on) {
      if (on && !(_radioReady?.isCompleted ?? true)) {
        _radioReady!.complete(true);
      }
    });
  }

  Future<bool> _awaitRadio({
    Duration timeout = const Duration(seconds: 8),
  }) =>
      (_radioReady?.future ?? Future.value(false))
          .timeout(timeout, onTimeout: () => false);

  @override
  Future<void> start() async {
    _set(TransportState.starting);
    try {
      _watchRadio();
      await BlePeripheral.initialize();
      if (!await BlePeripheral.isSupported()) {
        throw StateError('BLE peripheral mode is not supported on this device');
      }
      if (!await _awaitRadio()) {
        throw StateError(
            'Bluetooth never reported ready. Check it is switched on, and '
            'that this app has been granted Bluetooth permission — on macOS '
            'that prompt only appears for a normally launched app, not a '
            'test harness.');
      }

      BlePeripheral.setWriteRequestCallback(_onWrite);
      BlePeripheral.setReadRequestCallback(_onRead);
      BlePeripheral.setCharacteristicSubscriptionChangeCallback(
          _onSubscriptionChanged);
      // Android only; on Apple the subscription callback above carries the
      // load. Registering it anyway is harmless and gives faster cleanup where
      // it does fire.
      BlePeripheral.setConnectionStateChangeCallback(_onConnectionChanged);
      BlePeripheral.setMtuChangeCallback((deviceId, mtu) => _mtu[deviceId] = mtu);

      await BlePeripheral.addService(
        BleService(
          uuid: BleIds.serviceUuid,
          primary: true,
          characteristics: [
            _characteristic(BleIds.claimRxChar, write: true),
            _characteristic(BleIds.heartbeatRxChar, write: true),
            // Readable as well as push-based, so an attendee that connects
            // for a moment can just fetch the current state instead of
            // waiting for an update that might not arrive in time.
            _characteristic(BleIds.snapshotTxChar, read: true, notify: true),
          ],
        ),
      );

      _set(TransportState.ready);
      await _startAdvertising();
    } catch (e) {
      _set(TransportState.failed);
      rethrow;
    }
  }

  BleCharacteristic _characteristic(
    String uuid, {
    bool read = false,
    bool write = false,
    bool notify = false,
  }) =>
      BleCharacteristic(
        uuid: uuid,
        // These cross into the native code as plain numbers, not enums.
        properties: [
          if (read) CharacteristicProperties.read.index,
          if (write) CharacteristicProperties.write.index,
          if (write) CharacteristicProperties.writeWithoutResponse.index,
          if (notify) CharacteristicProperties.notify.index,
        ],
        permissions: [
          if (read || notify) AttributePermissions.readable.index,
          if (write) AttributePermissions.writeable.index,
        ],
        value: null,
      );

  @override
  Future<void> stop() async {
    try {
      await BlePeripheral.stopAdvertising();
      await BlePeripheral.clearServices();
    } catch (_) {
      // Already shut down, nothing to do.
    }
    _set(TransportState.stopped);
    await _inbound.close();
    await _state.close();
  }

  /// The host only answers requests, it never sends them.
  @override
  Future<Envelope?> request(
    Envelope command, {
    String? to,
    Duration timeout = const Duration(seconds: 10),
  }) =>
      throw UnsupportedError('the host responds to commands, it does not send');

  /// Roughly how many connections a phone can manage. This is just for
  /// display — the Bluetooth hardware enforces the real limit.
  @override
  int? get connectionLimit => 8;

  @override
  Future<void> send(Envelope envelope, {String? to}) async {
    final bytes = envelope.encode();
    final targets = to == null ? _subscribed.toList() : [to];

    for (final deviceId in targets) {
      // Packet size is agreed per device, so split to suit this one.
      final chunks = Chunker.split(
        messageId: envelope.messageId,
        bytes: bytes,
        maxChunkSize: Chunker.payloadForMtu(_mtu[deviceId] ?? 23),
      );
      for (final chunk in chunks) {
        await BlePeripheral.updateCharacteristic(
          characteristicId: BleIds.snapshotTxChar,
          value: chunk,
          deviceId: deviceId,
        );
      }
    }
  }

  /// Updates the state that a connecting attendee will read.
  ///
  /// Called every time the host rebuilds its state, so what's waiting is never
  /// out of date.
  void publishSnapshot(Uint8List bytes) => _snapshotBytes = bytes;

  /// Answers a read straight from memory. This callback has to return
  /// immediately, which is why we keep the bytes ready.
  ///
  /// [offset] handles a long read: state too big for one packet gets fetched
  /// in pieces.
  ReadRequestResult? _onRead(
    String deviceId,
    String characteristicId,
    int offset,
    Uint8List? value,
  ) {
    if (characteristicId.toLowerCase() !=
        BleIds.snapshotTxChar.toLowerCase()) {
      return null;
    }
    if (offset >= _snapshotBytes.length) {
      return ReadRequestResult(value: Uint8List(0));
    }
    return ReadRequestResult(value: _snapshotBytes.sublist(offset));
  }

  // Has to return straight away, since what we return is the Bluetooth
  // reply. So we queue the real work and acknowledge immediately.
  WriteRequestResult? _onWrite(
    String deviceId,
    String characteristicId,
    int offset,
    Uint8List? value,
  ) {
    if (value == null) return null;
    final reassembler =
        _reassemblers.putIfAbsent(deviceId, Reassembler.new);
    try {
      final complete = reassembler.accept(value);
      if (complete == null) return null; // still waiting for more pieces

      final envelope = Envelope.decode(complete);
      if (_dedupe.register(envelope.messageId) && !_inbound.isClosed) {
        _inbound.add(InboundMessage(envelope: envelope, peerId: deviceId));
      }
    } on FormatException {
      // One device sending a broken packet must not break the session.
      reassembler.clear();
    }
    return null;
  }

  /// A device signing up for updates is what makes it reachable. This fires
  /// on every platform, unlike the connect/disconnect callback.
  void _onSubscriptionChanged(
    String deviceId,
    String characteristicId,
    bool isSubscribed,
    String? name,
  ) {
    if (characteristicId.toLowerCase() !=
        BleIds.snapshotTxChar.toLowerCase()) {
      return;
    }
    if (isSubscribed) {
      _subscribed.add(deviceId);
    } else {
      _subscribed.remove(deviceId);
    }
  }

  /// Android only. Tidies up as soon as a device disconnects, instead of
  /// waiting for it to unsubscribe, which might never happen.
  void _onConnectionChanged(String deviceId, bool connected) {
    if (connected) return;
    _subscribed.remove(deviceId);
    _mtu.remove(deviceId);
    _reassemblers.remove(deviceId);
  }
}
