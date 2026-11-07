import 'dart:async';
import 'dart:math';

import '../domain/proximity.dart';
import '../identity/identity.dart';
import '../identity/signing.dart';
import '../logic/claim_result.dart';
import '../logic/proximity_monitor.dart';
import '../transport/backoff.dart';
import '../transport/envelope.dart';
import '../transport/mesh_transport.dart';
import '../transport/protocol.dart';

enum JoinState { idle, joining, joined, rejected }

/// Why someone is no longer in a session they joined.
///
/// Both of these are final — there's nothing left to wait for, so the session
/// gets closed. Losing contact with the host is not in here on purpose,
/// because that can come back. See [AttendeeSessionService.hostUnreachable].
enum SessionEnd {
  /// The host closed the session.
  endedByHost,

  /// The host removed this person.
  removedByHost,
}

/// The attendee's side of a session.
///
/// No database and no decisions: it asks the host for things and shows
/// whatever comes back. Only the host decides positions, so the attendee never
/// changes its own place in the queue.
class AttendeeSessionService {
  AttendeeSessionService({
    required this.transport,
    required this.identity,
    ProximityThresholds? thresholds,
    Signing? signing,
    this.rssiSource,
    this.backoff = Backoff.defaults,
    this.verifyHostMessages = true,
  })  : thresholds = thresholds ?? ProximityThresholds.defaults,
        _signing = signing ?? Signing(),
        _proximity = ProximityMonitor(
            thresholds: thresholds ?? ProximityThresholds.defaults);

  final MeshTransport transport;

  /// This device's account. Every message we send is signed with its key, and
  /// the public key is the identity the host acts on.
  final LocalIdentity identity;

  /// Checks the host's messages are properly signed, so another device can't
  /// send us fake updates.
  final bool verifyHostMessages;

  final Signing _signing;

  /// How long to wait before retrying. Being turned away is normal when the
  /// host can only handle about eight connections.
  final Backoff backoff;

  /// The version the host was advertising last time we checked. Only worth
  /// reconnecting when this has changed.
  int _seenVersion = 0;
  bool _refreshing = false;

  String get attendeeId => identity.userId;
  String get displayName => identity.displayName;

  /// How often we read our signal and check in, and how quickly a weak
  /// signal turns into a warning.
  final ProximityThresholds thresholds;
  final ProximityMonitor _proximity;

  /// Reads the current signal strength. On a real phone this comes from
  /// Bluetooth; tests pass in a fixed value. Null means we can't measure it,
  /// and only missed check-ins will show this person leaving.
  final Future<int> Function()? rssiSource;

  StreamSubscription<InboundMessage>? _sub;
  Timer? _beat;

  /// Set when [stop] starts, so a timer or a message still in flight can't
  /// use streams that have been closed.
  bool _stopped = false;

  JoinState _joinState = JoinState.idle;
  String? _hostPeerId;
  String? _hostId;
  String? _sessionId;
  String? _sessionTitle;
  String? _hostName;
  String? _queueId;
  String? _queueName;
  String? _rejectReason;

  PresenceSample _presence = const PresenceSample(attendeeId: '');
  QueueSnapshot? _snapshot;
  RosterSnapshot? _roster;

  final _snapshots = StreamController<QueueSnapshot>.broadcast();
  final _rosters = StreamController<RosterSnapshot>.broadcast();
  final _results = StreamController<ClaimResult>.broadcast();
  final _presenceCtl = StreamController<PresenceSample>.broadcast();
  final _pending = <String, Completer<ClaimResult>>{};
  final _endings = StreamController<SessionEnd>.broadcast();

  /// Fires once when we're no longer in the session. The screen listens so it
  /// can say so and close, instead of showing a list that will never update
  /// again.
  Stream<SessionEnd> get endings => _endings.stream;

  SessionEnd? _ended;

  /// Set once the session has ended or we were removed. Null while everything
  /// is fine.
  SessionEnd? get ended => _ended;

  /// How many check-ins in a row got no reply.
  ///
  /// One failure is normal — a busy host turns us away, which is what the
  /// retry delay is for. Several in a row means nobody is answering.
  int _silentCheckIns = 0;

  /// How many unanswered check-ins before we say we've lost the host. Three
  /// at 30 seconds is a minute and a half, which is about when the host stops
  /// counting us, so both sides agree.
  static const _silentCheckInsBeforeSayingSo = 3;

  final _contact = StreamController<bool>.broadcast();

  /// Sends false when we lose contact with the host, true when it comes
  /// back.
  Stream<bool> get contact => _contact.stream;

  /// True when several check-ins in a row have had no reply.
  ///
  /// This can recover, and check-ins keep running the whole time. An earlier
  /// version treated it as the end of the session and stopped the timer, which
  /// meant anyone who stepped out of range for ninety seconds had left for
  /// good — the opposite of what walking back in should do.
  bool get hostUnreachable =>
      _silentCheckIns >= _silentCheckInsBeforeSayingSo;

  void _finish(SessionEnd how) {
    if (_ended != null) return; // first reason wins; it is the true one
    _ended = how;
    _beat?.cancel();
    if (!_endings.isClosed) _endings.add(how);
  }

  Stream<QueueSnapshot> get snapshots => _snapshots.stream;
  Stream<RosterSnapshot> get rosters => _rosters.stream;
  Stream<ClaimResult> get results => _results.stream;
  Stream<PresenceSample> get presenceUpdates => _presenceCtl.stream;

  JoinState get joinState => _joinState;
  QueueSnapshot? get snapshot => _snapshot;

  /// Everyone in the session, queued or not. Null until the first update.
  RosterSnapshot? get roster => _roster;

  String? get queueId => _queueId;
  String? get queueName => _queueName;
  String? get sessionId => _sessionId;
  String? get sessionTitle => _sessionTitle;

  /// Who's hosting, once we know. Not available before joining, because a
  /// Mac host can't advertise it.
  String? get hostName => _hostName;
  String? get rejectReason => _rejectReason;

  /// The host may have replaced the name we chose.
  String get nameInSession =>
      _roster?.rowFor(attendeeId)?.displayName ?? displayName;

  bool get hasQueue => _queueId != null && (_roster?.hasQueue ?? true);
  bool get sessionLocked => _roster?.locked ?? false;
  PresenceSample get presence => _presence;

  bool get isRefreshing => _refreshing;

  /// True if the host has changed something since we last checked.
  bool staleAgainst(int advertisedVersion) => advertisedVersion > _seenVersion;

  /// Fetches the current state from the host.
  ///
  /// Uses the same retry logic as everything else, since a busy host will turn
  /// us away. That's normal, and the random wait stops a dozen phones from
  /// clashing over and over.
  Future<bool> refresh() async {
    if (_refreshing || _stopped) return false;
    _refreshing = true;
    try {
      final reply = await backoff.run<Envelope>((_) async {
        final command = await Envelope.signedJson(
          keyPair: identity.keyPair,
          senderId: attendeeId,
          type: MsgType.joinRequest,
          body: {'refresh': true, 'name': displayName},
          signing: _signing,
        );
        return transport.request(command, to: _hostPeerId);
      });

      if (reply == null) return false;

      // A refusal is still a reply, and worth applying because it carries
      // the reason. But reporting success would tell somebody who'd been
      // removed that they were back in.
      _apply(InboundMessage(envelope: reply, peerId: _hostPeerId ?? 'host'));
      return reply.type != MsgType.error;
    } finally {
      _refreshing = false;
    }
  }

  /// Tells the host we're leaving, before we shut down Bluetooth.
  ///
  /// This is the only quick way the host finds out. Otherwise it can only tell
  /// that check-ins stopped, which takes three missed ones, and an attendance
  /// check in the meantime would count somebody who has already left as
  /// present.
  ///
  /// Only two attempts, because the user is waiting on a dialog and a host
  /// that's out of range won't come back by waiting longer. False means "you
  /// have left, but the host hasn't been told yet", not "you're still in".
  Future<bool> leaveSession() async {
    if (_stopped || _joinState != JoinState.joined) return false;

    final envelope = await Envelope.signedJson(
      keyPair: identity.keyPair,
      senderId: attendeeId,
      type: MsgType.sessionLeave,
      body: {'sessionId': ?_sessionId},
      signing: _signing,
    );

    final reply = await const Backoff(maxAttempts: 2).run<Envelope>(
      (_) => transport.request(
        envelope,
        to: _hostPeerId,
        timeout: const Duration(seconds: 3),
      ),
    );
    return reply != null;
  }

  /// Where we are in the queue, taken straight from the host's update.
  SnapshotRow? get myRow => _snapshot?.rowFor(attendeeId);
  int? get myPosition => myRow?.position;
  bool get amInOverflow => myRow?.isOverflow ?? false;
  bool get amQueued => myRow != null;

  /// True when we should warn the user they're about to drop out.
  bool get isLeavingRange => _presence.state != ProximityState.inRange;

  Future<void> start() async {
    _presence = PresenceSample(attendeeId: identity.userId);
    await transport.start();
    _sub = transport.inbound.listen(_onInbound);
  }

  Future<void> stop() async {
    _stopped = true;
    _beat?.cancel();
    await _sub?.cancel();
    await transport.stop();
    await _snapshots.close();
    await _rosters.close();
    await _results.close();
    await _presenceCtl.close();
    await _endings.close();
    await _contact.close();
  }

  // ------------------------------------------------------------------ join

  /// Asks to join the session and waits for the host to accept.
  ///
  /// No code and no QR — the attendee already picked this session from the
  /// list, and being in range is the only requirement. The host identifies
  /// them by the public key that signs this request.
  Future<bool> join({
    String? hostPeerId,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _joinState = JoinState.joining;
    _rejectReason = null;
    _hostPeerId = hostPeerId;

    final accepted = Completer<bool>();
    late StreamSubscription<InboundMessage> once;
    once = transport.inbound.listen((msg) {
      if (msg.type == MsgType.joinAck && !accepted.isCompleted) {
        accepted.complete(true);
      } else if (msg.type == MsgType.error && !accepted.isCompleted) {
        _rejectReason = msg.envelope.json['reason'] as String?;
        accepted.complete(false);
      }
    });

    await _send(MsgType.joinRequest, {'name': displayName});

    final ok = await accepted.future
        .timeout(timeout, onTimeout: () => false)
        .whenComplete(once.cancel);
    _joinState = ok ? JoinState.joined : JoinState.rejected;
    if (ok) _startHeartbeat();
    return ok;
  }

  /// Signs and sends. Everything we send is signed, so the host acts on a
  /// verified identity rather than whatever id we claim.
  Future<Envelope> _send(MsgType type, Map<String, Object?> body) async {
    final envelope = await Envelope.signedJson(
      keyPair: identity.keyPair,
      senderId: attendeeId,
      type: type,
      body: body,
      signing: _signing,
    );
    await transport.send(envelope, to: _hostPeerId);
    return envelope;
  }

  // ---------------------------------------------------------------- claims

  Future<ClaimResult> claimNextAvailable() =>
      _sendClaim(ClaimKind.nextAvailable);

  Future<ClaimResult> claimSlot(int slot) =>
      _sendClaim(ClaimKind.specificSlot, slot: slot);

  Future<ClaimResult> pinCurrentSlot() => _sendClaim(ClaimKind.pin);

  Future<ClaimResult> leaveQueue() => _sendClaim(ClaimKind.leave);

  Future<ClaimResult> _sendClaim(
    ClaimKind kind, {
    int? slot,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final qid = _queueId;
    if (qid == null) return ClaimResult.failed(ClaimFailure.noSuchQueue);

    final envelope = await Envelope.signedJson(
      keyPair: identity.keyPair,
      senderId: attendeeId,
      type: MsgType.claimRequest,
      signing: _signing,
      body: ClaimRequest(
        queueId: qid,
        attendeeId: attendeeId,
        kind: kind,
        slot: slot,
        // The host stores this for reference but never orders by it, since
        // phone clocks differ and can be faked.
        clientRequestedAt: DateTime.now().millisecondsSinceEpoch,
      ).toJson(),
    );

    final completer = Completer<ClaimResult>();
    _pending[envelope.messageId] = completer;
    await transport.send(envelope, to: _hostPeerId);

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(envelope.messageId);
        // The request may have arrived and only the reply got lost. Sending
        // the same id again is safe — the host repeats its answer rather
        // than adding us to the queue twice.
        return ClaimResult.failed(ClaimFailure.noSuchQueue);
      },
    );
  }

  // ------------------------------------------------------------- heartbeat

  final _rng = Random();

  /// Adds a random amount either side of the interval, so a room full of
  /// phones that joined together doesn't keep checking in at the same moment.
  Duration get _nextBeatGap {
    final jitter = thresholds.heartbeatJitter.inMilliseconds;
    return thresholds.heartbeatInterval +
        Duration(milliseconds: jitter == 0 ? 0 : _rng.nextInt(jitter * 2) - jitter);
  }

  /// Each check-in schedules the next one itself, so every gap gets a fresh
  /// random amount rather than settling into a fixed rhythm.
  void _startHeartbeat() {
    _beat?.cancel();
    _beat = Timer(_nextBeatGap, () async {
      await _sendHeartbeat();
      if (!_stopped) _startHeartbeat();
    });
  }

  /// Checks in with the host.
  ///
  /// A short connection rather than one we hold open. The reply includes the
  /// current list of people, so one connection does both the check-in and the
  /// refresh instead of needing two.
  Future<void> _sendHeartbeat() async {
    if (_stopped) return;
    final read = rssiSource;

    var rssi = -60;
    if (read != null) {
      try {
        rssi = await read();
      } catch (_) {
        // Nothing connected to measure. Still worth checking in — the
        // attempt itself is what tells the host we're here.
      }
    }

    if (_stopped) return;
    final e = _proximity.onHeartbeat(
      previous: _presence,
      rssi: rssi,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    _presence = e.sample;
    if (!_presenceCtl.isClosed) _presenceCtl.add(_presence);

    final envelope = await Envelope.signedJson(
      keyPair: identity.keyPair,
      senderId: attendeeId,
      type: MsgType.heartbeat,
      signing: _signing,
      body: Heartbeat(
        attendeeId: attendeeId,
        rssi: rssi,
        rssiEma: _presence.rssiEma ?? rssi.toDouble(),
        proximity: _presence.state,
        sentAt: DateTime.now().millisecondsSinceEpoch,
      ).toJson(),
    );

    final reply = await backoff.run<Envelope>(
        (_) => transport.request(envelope, to: _hostPeerId));

    if (reply == null) {
      // One refusal is normal, since the host can only take about eight
      // connections at a time. Several in a row is different: nobody is
      // answering and the host has stopped counting us, so say so rather than
      // showing a list frozen from whenever contact was lost.
      //
      // Note the check-in timer keeps running. We expect to recover from
      // this.
      final wasReachable = !hostUnreachable;
      _silentCheckIns++;
      if (wasReachable && hostUnreachable && !_contact.isClosed) {
        _contact.add(false);
      }
      return;
    }

    final wasUnreachable = hostUnreachable;
    _silentCheckIns = 0;
    if (wasUnreachable && !_contact.isClosed) _contact.add(true);

    if (!_stopped) {
      _apply(InboundMessage(envelope: reply, peerId: _hostPeerId ?? 'host'));
    }
  }

  // --------------------------------------------------------------- ingress

  void _onInbound(InboundMessage msg) {
    if (_stopped) return;
    if (verifyHostMessages) {
      unawaited(_verifyThenApply(msg));
    } else {
      _apply(msg);
    }
  }

  Future<void> _verifyThenApply(InboundMessage msg) async {
    final ok = await msg.envelope.verify(signing: _signing);
    if (ok && !_stopped) _apply(msg);
  }

  void _apply(InboundMessage msg) {
    _hostPeerId ??= msg.peerId;
    switch (msg.type) {
      case MsgType.joinAck:
        final b = msg.envelope.json;
        _hostId = msg.envelope.senderId;
        _sessionId = b['sessionId'] as String?;
        _sessionTitle = b['title'] as String?;
        _hostName = b['hostName'] as String?;
        _queueId = b['queueId'] as String?;
        _queueName = b['queueName'] as String?;
        _joinState = JoinState.joined;
        _hostPeerId = msg.peerId;

      case MsgType.roster:
        final r = RosterSnapshot.fromJson(msg.envelope.json);
        if (_roster != null && r.revision <= _roster!.revision) return;
        _seenVersion = r.revision;
        _roster = r;
        _sessionTitle = r.title;
        // The host can open or close a queue at any time, so track it from
        // these updates rather than only from the join reply.
        if (!r.hasQueue) _queueId = null;
        if (!_rosters.isClosed) _rosters.add(r);

      case MsgType.snapshot:
        final snap = QueueSnapshot.fromJson(msg.envelope.json);
        if (_snapshot != null && snap.revision <= _snapshot!.revision) return;
        _snapshot = snap;
        if (snap.revision > _seenVersion) _seenVersion = snap.revision;
        _queueId ??= snap.queueId;
        _queueName ??= snap.queueName;
        if (!_snapshots.isClosed) _snapshots.add(snap);

      case MsgType.claimResult:
        final resp = ClaimResponse.fromJson(msg.envelope.json);
        _pending.remove(resp.requestId)?.complete(resp.result);
        if (!_results.isClosed) _results.add(resp.result);

      case MsgType.sessionNotice:
        // The host telling us something changed without being asked. Both of
        // these used to happen silently, leaving the attendee looking at a
        // list that would never update again.
        switch (msg.envelope.json['reason'] as String?) {
          case 'removed':
            _rejectReason = 'removedByHost';
            _finish(SessionEnd.removedByHost);
          case 'ended':
            _finish(SessionEnd.endedByHost);
          default:
            break;
        }

      case MsgType.error:
        final reason = msg.envelope.json['reason'] as String?;
        _rejectReason = reason;
        if (_joinState == JoinState.joining) {
          _joinState = JoinState.rejected;
        }
        // Turned away mid-session rather than when joining. This is how
        // somebody who wasn't connected when the host removed them finds
        // out — their next check-in gets refused.
        switch (reason) {
          case 'removedByHost':
            _finish(SessionEnd.removedByHost);
          case 'sessionClosed':
            if (_joinState == JoinState.joined) {
              _finish(SessionEnd.endedByHost);
            }
          default:
            break;
        }

      default:
        break;
    }
  }

  String? get hostId => _hostId;
}
