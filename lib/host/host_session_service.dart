import 'dart:async';
import 'dart:math';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'dart:convert';
import 'dart:typed_data';

import '../common/alerts.dart';
import '../data/history_repository.dart';
import '../logic/check_scheduler.dart';
import '../logic/entry_timer.dart';

import '../domain/proximity.dart';
import '../domain/queue.dart';
import '../domain/session.dart';
import '../identity/identity.dart';
import '../identity/name_policy.dart';
import '../identity/signing.dart';
import '../logic/claim_result.dart';
import '../logic/proximity_monitor.dart';
import '../logic/queue_logic.dart';
import '../transport/envelope.dart';
import '../transport/mesh_transport.dart';
import '../transport/protocol.dart';

/// The host's side of a live session.
///
/// Owns the database, answers queue requests, tracks who's here, and sends out
/// updates. Everything an attendee sees comes from here.
class HostSessionService {
  HostSessionService({
    required this.db,
    required this.transport,
    required this.identity,
    QueueLogic? logic,
    ProximityThresholds? thresholds,
    NamePolicy? namePolicy,
    Signing? signing,
    this.keepAliveInterval = const Duration(seconds: 5),
    Uuid? uuid,
    CheckScheduler? checkScheduler,
    Random? random,
    this.verifySignatures = true,
  })  : logic = logic ?? QueueLogic(db),
        history = HistoryRepository(db),
        checkScheduler = checkScheduler ?? CheckScheduler.defaults,
        _random = random ?? Random(),
        thresholds = thresholds ?? ProximityThresholds.defaults,
        namePolicy = namePolicy ?? NamePolicy.defaults,
        _signing = signing ?? Signing(),
        _proximity =
            ProximityMonitor(thresholds: thresholds ?? ProximityThresholds.defaults),
        _uuid = uuid ?? const Uuid();

  final Database db;
  final MeshTransport transport;

  /// The host's own account. Messages we send are signed with its key.
  final LocalIdentity identity;

  /// Only turned off in some older tests. The real app always verifies.
  final bool verifySignatures;

  /// Called with the latest state whenever it changes, so Bluetooth can hand
  /// it straight to an attendee that connects for a moment and reads.
  void Function(Uint8List)? onSnapshotBytes;

  /// How often we re-advertise, so an attendee that missed a change still
  /// notices within this time.
  final Duration keepAliveInterval;

  /// Called when the advert needs updating. The host screen connects this to
  /// Bluetooth.
  void Function(RosterSnapshot)? onAdvertise;

  final NamePolicy namePolicy;
  final Signing _signing;

  /// Reads past sessions and checks, and records new ones.
  final HistoryRepository history;

  /// Decides when checks happen. Passed in so tests can control it.
  final CheckScheduler checkScheduler;
  final Random _random;

  String get hostId => identity.userId;
  final QueueLogic logic;

  /// Controls both how often we check and the presence rules, so tests can
  /// run the real logic on a much faster clock.
  final ProximityThresholds thresholds;
  final ProximityMonitor _proximity;
  final Uuid _uuid;

  Session? _session;
  Queue? _queue;

  /// Set as soon as [stop] begins. Messages already on their way can still
  /// arrive after Bluetooth closes, and a late check-in must be dropped rather
  /// than written to a database that's closing.
  bool _stopped = false;

  /// Work currently in progress. [stop] waits for all of it before returning,
  /// so the database is never closed while something is still writing.
  /// Checking a flag isn't enough, because the close could happen between the
  /// check and the write.
  final _inFlight = <Future<void>>{};
  StreamSubscription<InboundMessage>? _sub;
  Timer? _sweep;
  final _stopwatch = Stopwatch()..start();

  /// Counts arrivals. Increased immediately, before any waiting, so it
  /// records the order Bluetooth actually handed us the messages.
  int _arrivalCounter = 0;

  int _revision = 0;

  /// Everyone in this session, whether they have a phone or were typed in,
  /// in the order they joined. People typed in by hand have no key and never
  /// appear in [_presence].
  final _known = <String, KnownUser>{};
  final _hostLabels = <String, String>{};

  /// People the host removed. Off the live list and the headcount, but still
  /// in the history and the export.
  final _removed = <String>{};

  /// People who told us they were leaving. Off the live list and out of any
  /// later checks, but we keep their attendance and the checks that ran while
  /// they were here, since they were present for those.
  ///
  /// Kept apart from [_removed] so the export can say whether somebody left or
  /// was removed.
  final _departed = <String>{};
  final _presence = <String, PresenceSample>{};
  final _peerToUser = <String, String>{};
  final _lastBeatElapsed = <String, int>{};

  final _snapshots = StreamController<QueueSnapshot>.broadcast();
  final _rosters = StreamController<RosterSnapshot>.broadcast();
  final _checkRuns = StreamController<List<CheckRun>>.broadcast();
  final _timerStream = StreamController<Map<String, EntryTimer>>.broadcast();

  final _checks = <CheckRun>[];

  /// The last update we sent. Kept so reopening the screen mid-session shows
  /// the room straight away. The dashboard used to hold this only in the
  /// widget, so backing out and going back in showed an empty room until
  /// somebody did something.
  RosterSnapshot? lastRoster;
  QueueSnapshot? lastSnapshot;

  /// Re-advertises every so often, so a phone that's scanning sees the current
  /// version even if it missed the change.
  ///
  /// This doesn't send state to anyone. Attendees fetch it themselves when the
  /// version changes, since the host can't hold enough connections to push to
  /// a whole room.
  Timer? _advertRefresh;

  /// Timers that are running, by queue entry. In practice the host times one
  /// person at a time, but nothing stops them running several.
  final _timers = <String, EntryTimer>{};
  Timer? _timerTick;
  final _checkTimers = <Timer>[];
  Timer? _endWarning;
  bool _plannedEndPassed = false;

  Stream<QueueSnapshot> get snapshots => _snapshots.stream;
  Stream<RosterSnapshot> get rosters => _rosters.stream;

  /// Every check that has run, in order. Test 1 is first.
  Stream<List<CheckRun>> get checkRuns => _checkRuns.stream;

  /// Fires when a timer starts, pauses, runs out or ends — not on every tick.
  /// The countdown on screen updates itself, so a running timer doesn't hit
  /// the database every second.
  Stream<Map<String, EntryTimer>> get timers => _timerStream.stream;

  EntryTimer? timerFor(String entryId) => _timers[entryId];
  Map<String, EntryTimer> get runningTimers => Map.unmodifiable(_timers);
  List<CheckRun> get checks => List.unmodifiable(_checks);

  /// True once the length the host set has passed. The session keeps going,
  /// since a class that runs over shouldn't lose its queue, but the dashboard
  /// shows a notice.
  bool get plannedEndPassed => _plannedEndPassed;

  Session? get session => _session;
  Queue? get queue => _queue;
  bool get hasQueue => _queue != null;

  List<PresenceSample> get attendees => _presence.values.toList();
  List<KnownUser> get knownUsers => _known.values.toList();

  /// Use the host's correction first, then their own name, then the raw id.
  String nameOf(String userId) =>
      _hostLabels[userId] ?? _known[userId]?.displayName ?? userId;

  bool isHostLabelled(String userId) => _hostLabels.containsKey(userId);

  ProximityState proximityOf(String userId) =>
      _presence[userId]?.state ??
      // Somebody typed in by hand has no phone, so there's no signal to
      // lose and "in range" is the only sensible answer.
      ProximityState.inRange;

  // ------------------------------------------------------------- lifecycle

  /// Creates the session. It doesn't create a queue — the session is what
  /// attendees join, and the host decides later whether to run a queue.
  Future<Session> createSession({
    required String title,
    Duration? length,
    int checkCount = 0,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _rememberUser(
      KnownUser(
        id: hostId,
        displayName: identity.displayName,
        kind: UserKind.device,
        firstSeenAt: now,
        nameSetAt: now,
        publicKey: hostId,
      ),
    );

    final created = Session(
      id: _uuid.v4(),
      hostId: hostId,
      title: title,
      createdAt: now,
      plannedEndAt: length == null ? null : now + length.inMilliseconds,
      checkMode: checkCount > 0,
      checkTarget: checkCount > 0 ? checkCount : null,
    );
    await db.insert('sessions', created.toMap());
    _session = created;
    return created;
  }

  // ---------------------------------------------------------------- checks

  /// Sets up the check schedule and the end-of-session warning.
  ///
  /// If the host set a length, checks happen at random points across it, at
  /// least ten minutes apart. If not, they repeat every ten to twenty-five
  /// minutes for as long as the session runs.
  void _armTimers() {
    final s = _session;
    if (s == null) return;

    if (s.plannedEndAt != null) {
      final remaining = s.plannedEndAt! - DateTime.now().millisecondsSinceEpoch;
      if (remaining > 0) {
        _endWarning = Timer(Duration(milliseconds: remaining), () {
          _plannedEndPassed = true;
          _track(logic.serialized(_broadcast));
        });
      } else {
        _plannedEndPassed = true;
      }
    }

    if (!s.checkMode) return;

    final length = s.plannedLength;
    if (length != null) {
      final offsets = checkScheduler.plan(
        length: length,
        count: s.checkTarget ?? 0,
        rng: _random,
      );
      for (final offset in offsets) {
        _checkTimers.add(Timer(offset, () => _track(runCheck())));
      }
    } else {
      _armRepeatingCheck();
    }
  }

  void _armRepeatingCheck() {
    _checkTimers.add(Timer(checkScheduler.nextGap(_random), () {
      _track(runCheck());
      if (!_stopped) _armRepeatingCheck();
    }));
  }

  // ----------------------------------------------------------------- timers

  /// Starts timing someone in the queue.
  ///
  /// Replaces any timer already on that person, so starting again restarts
  /// rather than running two at once.
  EntryTimer startTimer({
    required String entryId,
    required TimerDirection direction,
    Duration? total,
    List<TimerWarning>? warnings,
  }) {
    final timer = EntryTimer(
      entryId: entryId,
      direction: direction,
      total: total,
      warnings: warnings ??
          (direction == TimerDirection.countDown && total != null
              ? EntryTimer.defaultWarningsFor(total)
              : const []),
    )..start();

    _timers[entryId] = timer;
    _ensureTicking();
    _emitTimers();
    return timer;
  }

  void pauseTimer(String entryId) {
    _timers[entryId]?.pause();
    _emitTimers();
  }

  void resumeTimer(String entryId) {
    _timers[entryId]?.resume();
    _ensureTicking();
    _emitTimers();
  }

  /// Stops the timer and saves the time against the queue entry, so it still
  /// appears in the export even if the person is never marked finished.
  Future<void> stopTimer(String entryId) async {
    final timer = _timers.remove(entryId);
    if (timer == null) return;
    timer.stop();
    await _recordTimer(entryId, timer.resultMs);
    _emitTimers();
  }

  Future<void> _recordTimer(String entryId, int ms) async {
    if (_stopped) return;
    await logic.serialized(() => db.update('queue_entries', {'timer_ms': ms},
        where: 'id = ?', whereArgs: [entryId]));
  }

  /// One shared tick for all running timers rather than one each.
  ///
  /// It only checks whether a warning is due. The countdown on screen updates
  /// itself, so this can stay slow enough to cost nothing.
  void _ensureTicking() {
    _timerTick ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_stopped) return;
      var changed = false;
      for (final timer in _timers.values.toList()) {
        for (final warning in timer.takeDueWarnings()) {
          unawaited(Alerts.instance.ping(count: warning.pings));
        }
        if (timer.hasExpired && timer.state == TimerState.finished) {
          changed = true;
        }
      }
      if (_timers.values.every((t) => !t.isRunning)) {
        _timerTick?.cancel();
        _timerTick = null;
      }
      if (changed) _emitTimers();
    });
  }

  void _emitTimers() {
    if (!_timerStream.isClosed) _timerStream.add(runningTimers);
  }

  /// Takes an attendance check right now. The host can do this any time, and
  /// it gets the next Test number just like a scheduled one.
  ///
  /// Nobody is prompted, on purpose — so nothing can be forgotten or tapped by
  /// a friend on your behalf. It just records who was reachable at that
  /// moment.
  Future<CheckRun?> runCheck({bool manual = false}) async {
    final s = _session;
    if (s == null || _stopped) return null;

    final run = await logic.serialized(() => history.recordCheck(
      checkId: _uuid.v4(),
      sessionId: s.id,
      ranAt: DateTime.now().millisecondsSinceEpoch,
      manual: manual,
      presence: {
        for (final u in _known.values)
          if (u.id != hostId &&
              !_removed.contains(u.id) &&
              !_departed.contains(u.id))
            u.id: proximityOf(u.id),
      },
      manualAttendees: {
        for (final u in _known.values)
          if (u.isManual) u.id,
      },
    ));

    _checks.add(run);
    if (!_checkRuns.isClosed) _checkRuns.add(checks);
    await _broadcast();
    return run;
  }

  Future<CheckRun?> runCheckNow() => runCheck(manual: true);

  /// Changes or removes the session length while it's running.
  Future<void> setSessionLength(Duration? length) async {
    final s = _session;
    if (s == null) return;
    final endAt = length == null
        ? null
        : s.createdAt + length.inMilliseconds;

    await db.update('sessions', {'planned_end_at': endAt},
        where: 'id = ?', whereArgs: [s.id]);
    _session = s.copyWith(
        plannedEndAt: endAt, clearPlannedEnd: endAt == null);

    _endWarning?.cancel();
    _plannedEndPassed = false;
    if (endAt != null) {
      final remaining = endAt - DateTime.now().millisecondsSinceEpoch;
      if (remaining > 0) {
        _endWarning = Timer(Duration(milliseconds: remaining), () {
          _plannedEndPassed = true;
          _track(logic.serialized(_broadcast));
        });
      } else {
        _plannedEndPassed = true;
      }
    }
    await _broadcast();
  }

  /// Opens a queue. Optional, and you can only open another once the last
  /// one is closed.
  Future<Queue> createQueue({
    required String name,
    required int capacity,
  }) async {
    final s = _session;
    if (s == null) throw StateError('create the session first');
    _queue = await logic.createQueue(
        sessionId: s.id, name: name, capacity: capacity);
    await _broadcast();
    return _queue!;
  }

  Future<void> closeQueue() async {
    final q = _queue;
    if (q == null) return;
    await logic.closeQueue(q.id);
    _queue = null;
    await _broadcast();
  }

  /// Stops new people joining. Everyone already here stays.
  Future<void> setLocked(bool locked) async {
    final s = _session;
    if (s == null) return;
    final at = locked ? DateTime.now().millisecondsSinceEpoch : null;
    await db.update('sessions', {'locked_at': at},
        where: 'id = ?', whereArgs: [s.id]);
    _session = locked
        ? s.copyWith(lockedAt: at)
        : s.copyWith(clearLock: true);
    await _broadcast();
  }

  bool get isLocked => _session?.isLocked ?? false;

  Future<void> start() async {
    await transport.start();
    _sub = transport.inbound.listen(_onInbound);
    _sweep = Timer.periodic(thresholds.sampleInterval, (_) => _sweepPresence());
    _advertRefresh = Timer.periodic(keepAliveInterval, (_) {
      if (_stopped || logic.pendingClaims > 0) return;
      // Only re-sends what we already have. It doesn't read the database, so
      // it can't clash with a transaction.
      final roster = lastRoster;
      if (roster != null) onAdvertise?.call(roster);
    });
    _armTimers();
  }

  Future<void> stop() async {
    _stopped = true;
    _sweep?.cancel();
    _advertRefresh?.cancel();
    _endWarning?.cancel();
    _timerTick?.cancel();
    _timerTick = null;
    for (final t in _timers.values) {
      t.stop();
    }
    _timers.clear();
    for (final t in _checkTimers) {
      t.cancel();
    }
    _checkTimers.clear();
    await _sub?.cancel();
    await transport.stop();
    // Wait for anything still running before the caller closes the database.
    // Errors are already reported by the handlers themselves.
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList()).catchError((_) => <void>[]);
    }
    await _snapshots.close();
    await _rosters.close();
    await _checkRuns.close();
    await _timerStream.close();
  }

  Future<void> endSession() async {
    final s = _session;
    if (s == null) return;
    await db.update('sessions',
        {'ended_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [s.id]);
    _session = s.copyWith(endedAt: DateTime.now().millisecondsSinceEpoch);

    // Tell everyone before Bluetooth shuts down. This has to happen here and
    // not in [stop], because stop closes the connection and nothing can be
    // sent after that.
    //
    // It only reaches attendees who happen to be connected, which is usually
    // a few of them. The rest find out by noticing the host has stopped
    // answering, so this is a nice extra rather than the only route.
    await _notify(reason: 'ended');
  }

  /// Sends a notice without being asked, to one device or to everyone.
  Future<void> _notify({required String reason, String? to}) async {
    if (_stopped) return;
    try {
      await _send(to: to, type: MsgType.sessionNotice, body: {'reason': reason});
    } catch (_) {
      // This might not get through — they could be out of range or just not
      // connected. Failing to tell somebody must not stop the host ending its
      // own session.
    }
  }

  // --------------------------------------------------------------- ingress

  /// Nothing waits before the arrival number is taken and the job is handed
  /// over, so the order can't get shuffled by the scheduler.
  ///
  /// Signatures are checked here, before the arrival number is given out, so
  /// an unsigned or faked message never takes a queue place. Since the sender
  /// id is the public key, a device can only act as the identity it holds the
  /// key for.
  void _onInbound(InboundMessage msg) {
    if (_stopped) return;
    if (verifySignatures) {
      _track(_verifyThenDispatch(msg));
      return;
    }
    _dispatch(msg, ++_arrivalCounter);
  }

  void _track(Future<void> work) {
    _inFlight.add(work);
    work.whenComplete(() => _inFlight.remove(work));
  }

  Future<void> _verifyThenDispatch(InboundMessage msg) async {
    final ok = await msg.envelope.verify(signing: _signing);
    // Checking the signature takes a moment, so check again — the session
    // may have ended in the meantime.
    if (_stopped) return;
    if (!ok) {
      rejectedMessages++;
      return;
    }
    _dispatch(msg, ++_arrivalCounter);
  }

  /// How many messages we rejected for a bad or missing signature. Shown on
  /// the host screen so a misbehaving device is visible.
  int rejectedMessages = 0;

  void _dispatch(InboundMessage msg, int arrival) {
    if (_stopped) return;
    switch (msg.type) {
      case MsgType.joinRequest:
        _track(_handleJoin(msg));
      case MsgType.claimRequest:
        _track(_handleClaim(msg, arrival));
      case MsgType.heartbeat:
        _track(_handleHeartbeat(msg));
      case MsgType.leaveRequest:
        _track(_handleLeave(msg));
      case MsgType.sessionLeave:
        _track(_handleSessionLeave(msg));
      default:
        break;
    }
  }

  Future<void> _handleJoin(InboundMessage msg) async {
    final s = _session;
    if (s == null || _stopped) return;

    // The signature has already been checked and the sender id is their
    // public key, so this really is them. There's no code to enter — being in
    // range is the only requirement.
    final userId = msg.envelope.senderId;
    final claimedName =
        NameValidator.normalise((msg.envelope.json['name'] as String?) ?? '');
    final now = DateTime.now().millisecondsSinceEpoch;

    // A refresh is a join from somebody already here. Same reply, but a
    // locked session must not turn them away: locking stops new people
    // arriving, not people already here seeing the queue.
    // If the host removed you, trying again doesn't help.
    //
    // This check used to be missing, and a removed attendee slipped straight
    // through: they weren't counted as already here, so a fresh join only had
    // to get past the "is the session open" test, which it did. They got an
    // acceptance and thought they were in, while every update left them out —
    // so the host's list never showed them and neither side could explain it.
    // Only the host restoring them undoes a removal.
    if (_removed.contains(userId)) {
      await _send(
        to: msg.peerId,
        type: MsgType.error,
        body: {'reason': 'removedByHost', 'req': msg.envelope.messageId},
      );
      return;
    }

    final isRefresh = (msg.envelope.json['refresh'] as bool?) ?? false;
    // Somebody who left isn't "already here", so coming back counts as a new
    // arrival and a locked session can refuse it, same as anyone else turning
    // up late. (Removals are handled above.)
    final known =
        _known.containsKey(userId) && !_departed.contains(userId);

    if (!(isRefresh && known) && !s.acceptsJoinsAt(now)) {
      await _send(
        to: msg.peerId,
        type: MsgType.error,
        body: {
          'reason': s.isLocked ? 'sessionLocked' : 'sessionClosed',
          'req': msg.envelope.messageId,
        },
      );
      return;
    }

    final name = await _resolveName(userId, claimedName, now);

    _peerToUser[msg.peerId] = userId;
    _presence.putIfAbsent(userId, () => PresenceSample(attendeeId: userId));
    _lastBeatElapsed[userId] = _stopwatch.elapsedMilliseconds;

    await db.insert(
      'attendance_entries',
      AttendanceEntry(
        id: _uuid.v4(),
        sessionId: s.id,
        attendeeId: userId,
        joinedAt: now,
        lastSeenAt: now,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    // Back after leaving. The insert above does nothing because their row
    // already exists, so we have to clear the "left" time ourselves —
    // otherwise they'd stay off the list despite just rejoining. Their
    // original join time is kept, which is what the export wants.
    if (_departed.remove(userId)) {
      await db.update('attendance_entries', {'left_at': null},
          where: 'session_id = ? AND attendee_id = ?',
          whereArgs: [s.id, userId]);
    }

    await _send(
      to: msg.peerId,
      type: MsgType.joinAck,
      body: {
        'req': msg.envelope.messageId,
        'sessionId': s.id,
        'title': s.title,
        'hostName': identity.displayName,
        'name': name,
        if (_queue != null) 'queueId': _queue!.id,
        if (_queue != null) 'queueName': _queue!.name,
        if (_queue != null) 'capacity': _queue!.capacity,
      },
    );
    await _broadcast();
  }

  /// Applies the name rules using the host's own clock and the first time it
  /// saw this key. We never trust a time sent by a phone, same as with queue
  /// ordering.
  ///
  /// Returns the name the host will actually use.
  Future<String> _resolveName(String userId, String claimed, int nowMs) async {
    final existing = _known[userId] ?? await _loadUser(userId);

    if (existing == null) {
      final user = KnownUser(
        id: userId,
        displayName: claimed.isEmpty ? 'Attendee' : claimed,
        kind: UserKind.device,
        firstSeenAt: nowMs,
        nameSetAt: nowMs,
        publicKey: userId,
      );
      await _rememberUser(user);
      return user.displayName;
    }

    if (claimed.isEmpty || claimed == existing.displayName) {
      return existing.displayName;
    }

    if (!existing.hostMayAcceptNewName(policy: namePolicy, nowMs: nowMs)) {
      // Locked, so keep the name already registered. The attendee's own app
      // blocks this too, so getting here means a modified app.
      return existing.displayName;
    }

    final updated = KnownUser(
      id: existing.id,
      displayName: claimed,
      kind: existing.kind,
      firstSeenAt: existing.firstSeenAt,
      nameSetAt: nowMs,
      publicKey: existing.publicKey,
    );
    await _rememberUser(updated);
    return claimed;
  }

  Future<void> _handleClaim(InboundMessage msg, int arrivalOrdinal) async {
    if (_stopped) return;
    final q = _queue;
    final req = ClaimRequest.fromJson(msg.envelope.json);
    final messageId = msg.envelope.messageId;

    if (q == null) {
      // Say so rather than ignoring it and leaving them to time out ten
      // seconds later with a confusing error.
      await _send(
        to: msg.peerId,
        type: MsgType.error,
        body: {'reason': 'noQueue', 'req': messageId},
      );
      return;
    }

    // The signature already proved who sent this, so we use that key and
    // ignore whatever id the message body claims. This is what stops one
    // attendee removing another.
    final actor = msg.envelope.senderId;

    final result = switch (req.kind) {
      ClaimKind.nextAvailable => await logic.claimNextAvailable(
          queueId: q.id,
          attendeeId: actor,
          messageId: messageId,
          clientRequestedAt: req.clientRequestedAt,
        ),
      ClaimKind.specificSlot => await logic.claimSpecificSlot(
          queueId: q.id,
          attendeeId: actor,
          slot: req.slot ?? 0,
          messageId: messageId,
          clientRequestedAt: req.clientRequestedAt,
        ),
      ClaimKind.pin =>
        await logic.pinCurrentSlot(queueId: q.id, attendeeId: actor),
      ClaimKind.leave =>
        await logic.withdraw(queueId: q.id, attendeeId: actor),
    };

    await _send(
      to: msg.peerId,
      type: MsgType.claimResult,
      body: ClaimResponse(requestId: messageId, result: result).toJson()
        ..['arrival'] = arrivalOrdinal,
    );
    await _broadcast();
  }

  Future<void> _handleHeartbeat(InboundMessage msg) async {
    if (_stopped) return;
    final beat = Heartbeat.fromJson(msg.envelope.json);
    final userId = msg.envelope.senderId;

    // Refuse check-ins from somebody the host removed. Handling one would put
    // them straight back into the presence list that removeAttendee just
    // cleared, and reply as if nothing had happened. This is also how
    // somebody who wasn't connected when they were removed finds out.
    if (_removed.contains(userId)) {
      await _send(
        to: msg.peerId,
        type: MsgType.error,
        body: {'reason': 'removedByHost', 'req': msg.envelope.messageId},
      );
      return;
    }

    final prev = _presence[userId] ?? PresenceSample(attendeeId: userId);

    _lastBeatElapsed[userId] = _stopwatch.elapsedMilliseconds;
    final e = _proximity.onHeartbeat(
      previous: prev,
      rssi: beat.rssi,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    _presence[userId] = e.sample;

    final s = _session;
    if (s != null && !_stopped) {
      await db.update(
        'attendance_entries',
        {
          'last_seen_at': DateTime.now().millisecondsSinceEpoch,
          'proximity': e.sample.state.name,
          'rssi_ema': e.sample.rssiEma,
        },
        where: 'session_id = ? AND attendee_id = ?',
        whereArgs: [s.id, userId],
      );
    }

    // Reply with the current state, so one connection covers both the
    // check-in and the refresh. Without a reply their request times out and
    // the retry delay eats seconds before the next check-in, which stops
    // presence working at all.
    final roster = lastRoster;
    if (roster != null && !_stopped) {
      await _send(
        to: msg.peerId,
        type: MsgType.roster,
        body: roster.toJson()..['req'] = msg.envelope.messageId,
      );
    }

    // Only tell everyone when something actually changed, or every check-in
    // from every attendee would send the whole list to the whole room.
    if (e.changed) await _broadcast();
  }

  Future<void> _handleLeave(InboundMessage msg) async {
    final q = _queue;
    if (q == null || _stopped) return;
    await logic.withdraw(queueId: q.id, attendeeId: msg.envelope.senderId);
    await _broadcast();
  }

  /// An attendee has left the session, not just the queue.
  ///
  /// We keep everything — their attendance and their result in every check
  /// that ran while they were here — but they come off the live list at once
  /// and are left out of any later check. Waiting for the check-in timeout
  /// instead would count them as present for a couple of minutes, long enough
  /// for a check to pass somebody already down the corridor.
  Future<void> _handleSessionLeave(InboundMessage msg) async {
    final s = _session;
    if (s == null || _stopped) return;

    // Use the verified key, never an id from the message body, so one
    // attendee can't sign somebody else out of the session.
    final userId = msg.envelope.senderId;

    final q = _queue;
    if (q != null) {
      // Record which slot they were in before their status changes, same as
      // the other ways of leaving.
      await logic.withdraw(queueId: q.id, attendeeId: userId);
    }

    _departed.add(userId);
    _presence.remove(userId);
    _lastBeatElapsed.remove(userId);
    _peerToUser.removeWhere((_, v) => v == userId);

    await db.update(
      'attendance_entries',
      {'left_at': DateTime.now().millisecondsSinceEpoch},
      where: 'session_id = ? AND attendee_id = ?',
      whereArgs: [s.id, userId],
    );

    await _broadcast();

    // Reply, so the attendee can tell the user whether the host actually
    // knows they've gone.
    final roster = lastRoster;
    if (roster != null && !_stopped) {
      await _send(
        to: msg.peerId,
        type: MsgType.roster,
        body: roster.toJson()..['req'] = msg.envelope.messageId,
      );
    }
  }

  // -------------------------------------------------------------- presence

  void _sweepPresence() {
    if (_stopped) return;
    final now = _stopwatch.elapsedMilliseconds;
    var changed = false;

    // Who Bluetooth says is still connected. The operating system keeps this
    // up to date even while an app is asleep, so it stays true when a phone
    // locks — unlike check-ins, which stop.
    final linked = {
      for (final peer in transport.peers)
        if (_peerToUser[peer] != null) _peerToUser[peer]!,
    };

    final beatMs = thresholds.heartbeatInterval.inMilliseconds;

    for (final id in _presence.keys.toList()) {
      final previous = _presence[id]!;
      final elapsed = now - (_lastBeatElapsed[id] ?? now);
      final missed = beatMs <= 0 ? 0 : elapsed ~/ beatMs;

      // A connection only counts as evidence while messages are still
      // arriving on it, so it buys a little extra time rather than skipping
      // the timeout entirely.
      //
      // It used to skip the timeout completely, which was wrong in the one
      // direction an attendance app must never get wrong. On a Mac there's no
      // callback for a device disconnecting, so somebody who connected and
      // then walked off could look connected forever, never be marked absent,
      // and pass every check.
      final credible = linked.contains(id) &&
          missed < thresholds.missedBeatsForLost + thresholds.linkGraceBeats;

      if (credible) {
        // Bluetooth still thinks they're connected, but we haven't heard from
        // them recently enough to call them in range. Warning at best, and we
        // never overrule a real signal measurement.
        final held = missed >= thresholds.missedBeatsForWarning &&
                previous.state == ProximityState.inRange
            ? previous.copyWith(
                state: ProximityState.warning, missedBeats: missed)
            : previous.copyWith(missedBeats: missed);
        changed = changed || held.state != previous.state;
        _presence[id] = held;
        continue;
      }

      final e = _proximity.onSweep(
        previous: previous,
        elapsedSinceLastBeatMs: elapsed,
      );
      _presence[id] = e.sample;
      changed = changed || e.changed;
    }
    if (changed && logic.pendingClaims == 0) _track(_broadcast());
  }

  // ------------------------------------------------------------- broadcast

  Future<void> _send({
    String? to,
    required MsgType type,
    required Map<String, Object?> body,
  }) async {
    final envelope = await Envelope.signedJson(
      keyPair: identity.keyPair,
      senderId: hostId,
      type: type,
      body: body,
      signing: _signing,
    );
    await transport.send(envelope, to: to);
  }

  /// Sends the list of people to everyone, plus the queue if there is one.
  /// The list always goes out — without it, a session with no queue would tell
  /// its attendees nothing after they joined.
  Future<void> _broadcast() async {
    final s = _session;
    if (s == null || _stopped) return;

    final q = _queue == null ? null : await logic.queue(_queue!.id) ?? _queue;
    _queue = q;
    final resolution = q == null ? null : await logic.resolution(q.id);
    _revision++;

    final positions = <String, int>{};
    if (resolution != null) {
      for (final r in resolution.all) {
        positions[r.attendeeId] = r.position;
      }
    }

    final roster = RosterSnapshot(
      sessionId: s.id,
      title: s.title,
      revision: _revision,
      locked: s.isLocked,
      hasQueue: q != null,
      rows: [
        for (final u in _known.values)
          if (u.id != hostId &&
              !_removed.contains(u.id) &&
              !_departed.contains(u.id))
            RosterRow(
              userId: u.id,
              displayName: nameOf(u.id),
              kind: u.kind,
              proximity: proximityOf(u.id),
              inQueue: positions.containsKey(u.id),
              hostLabelled: isHostLabelled(u.id),
              position: positions[u.id],
            ),
      ],
    );
    lastRoster = roster;
    if (!_rosters.isClosed) _rosters.add(roster);
    onAdvertise?.call(roster);

    // Still sent to anyone who happens to be connected, since it's free and
    // instant for them. Nothing depends on it: an attendee that isn't
    // connected gets it on their next check-in or when they refresh.
    await _send(type: MsgType.roster, body: roster.toJson());

    if (q != null && resolution != null) {
      final snapshot = QueueSnapshot.fromResolution(
        queueId: q.id,
        queueName: q.name,
        revision: _revision,
        isOpen: q.isOpen,
        resolution: resolution,
        names: {for (final u in _known.values) u.id: nameOf(u.id)},
        proximity: {for (final u in _known.values) u.id: proximityOf(u.id)},
      );
      lastSnapshot = snapshot;
      // Keep the readable copy up to date, so an attendee that connects
      // briefly can just fetch it.
      onSnapshotBytes?.call(
          Uint8List.fromList(utf8.encode(jsonEncode(snapshot.toJson()))));
      if (!_snapshots.isClosed) _snapshots.add(snapshot);
      await _send(type: MsgType.snapshot, body: snapshot.toJson());
    }
  }

  Future<void> refresh() => _broadcast();

  // --------------------------------------------------------------- roster

  Future<void> _rememberUser(KnownUser user) async {
    _known[user.id] = user;
    await db.insert('users', user.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<KnownUser?> _loadUser(String id) async {
    final rows = await db.query('users', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final user = KnownUser.fromMap(rows.first);
    _known[user.id] = user;
    return user;
  }

  /// Corrects somebody's name for this session only. Their account isn't
  /// changed — this is for fixing a typo or a joke name so the register
  /// matches.
  Future<void> setHostLabel(String userId, String? label) async {
    final s = _session;
    if (s == null) return;
    final clean = label == null ? null : NameValidator.normalise(label);

    if (clean == null || clean.isEmpty) {
      _hostLabels.remove(userId);
    } else {
      _hostLabels[userId] = clean;
    }
    await db.update('attendance_entries', {'host_label': _hostLabels[userId]},
        where: 'session_id = ? AND attendee_id = ?',
        whereArgs: [s.id, userId]);
    await _broadcast();
  }

  /// Adds someone with no phone. They have no key and no signal, but the host
  /// can put them in the queue like anyone else.
  Future<KnownUser> addManualAttendee(String name) async {
    final s = _session;
    if (s == null) throw StateError('create the session first');
    final now = DateTime.now().millisecondsSinceEpoch;

    final user = KnownUser(
      id: 'manual:${_uuid.v4()}',
      displayName: NameValidator.normalise(name),
      kind: UserKind.manual,
      firstSeenAt: now,
      nameSetAt: now,
    );
    await _rememberUser(user);
    await db.insert(
      'attendance_entries',
      AttendanceEntry(
        id: _uuid.v4(),
        sessionId: s.id,
        attendeeId: user.id,
        joinedAt: now,
        lastSeenAt: now,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await _broadcast();
    return user;
  }

  /// Renames someone the host typed in. Always allowed, since there's no key
  /// involved and nothing to impersonate — locking it would only stop the host
  /// fixing their own typos.
  Future<void> renameManualAttendee(String userId, String name) async {
    final user = _known[userId];
    if (user == null || !user.isManual) return;
    await _rememberUser(KnownUser(
      id: user.id,
      displayName: NameValidator.normalise(name),
      kind: user.kind,
      firstSeenAt: user.firstSeenAt,
      nameSetAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await _broadcast();
  }

  /// Removes somebody from the session.
  ///
  /// Their record is marked rather than deleted, so a mistaken tap can be
  /// undone and the export can still show that somebody connected and was
  /// removed. They come off the list and the headcount straight away.
  Future<void> removeAttendee(String userId) async {
    final s = _session;
    if (s == null) return;
    final q = _queue;
    if (q != null) {
      await logic.withdraw(queueId: q.id, attendeeId: userId);
    }

    // Grabbed before we clear the mapping, so we still know where to send
    // the notice.
    final peers = [
      for (final e in _peerToUser.entries)
        if (e.value == userId) e.key,
    ];

    _removed.add(userId);
    _presence.remove(userId);
    _lastBeatElapsed.remove(userId);
    _peerToUser.removeWhere((_, v) => v == userId);

    await db.update(
      'attendance_entries',
      {'removed_at': DateTime.now().millisecondsSinceEpoch},
      where: 'session_id = ? AND attendee_id = ?',
      whereArgs: [s.id, userId],
    );
    await _broadcast();

    // Removal used to be silent: the list just stopped including them, which
    // from their side looks exactly like a lost message. If they're connected
    // they find out now; otherwise their next check-in tells them.
    for (final peer in peers) {
      await _notify(reason: 'removed', to: peer);
    }
  }

  /// Puts a removed attendee back on the list. The history still records that
  /// they were removed.
  Future<void> restoreAttendee(String userId) async {
    final s = _session;
    if (s == null || !_removed.remove(userId)) return;
    await db.update('attendance_entries', {'removed_at': null},
        where: 'session_id = ? AND attendee_id = ?',
        whereArgs: [s.id, userId]);
    await _broadcast();
  }

  Set<String> get removedAttendees => Set.unmodifiable(_removed);

  /// People who told us they were leaving.
  Set<String> get departedAttendees => Set.unmodifiable(_departed);

  // --------------------------------------------------------------- queue ops

  Future<void> hostReorder(List<String> orderedEntryIds) async {
    final q = _queue;
    if (q == null) return;
    await logic.hostReorder(queueId: q.id, orderedEntryIds: orderedEntryIds);
    await _broadcast();
  }

  Future<void> hostPromote(String entryId, int toSlot) async {
    await logic.hostPromote(entryId: entryId, toSlot: toSlot);
    await _broadcast();
  }

  Future<void> hostRemove(String entryId) async {
    await logic.hostRemove(entryId);
    await _broadcast();
  }

  /// Marks somebody as served. Stops their timer if one is running and saves
  /// the time, which is what the export shows.
  Future<void> finish(String entryId) async {
    final timer = _timers.remove(entryId);
    timer?.stop();
    if (timer != null) {
      _timerTick?.cancel();
      _timerTick = null;
      _emitTimers();
    }
    await logic.finish(entryId, timerMs: timer?.resultMs);
    await _broadcast();
  }

  Future<void> editCapacity(int capacity) async {
    final q = _queue;
    if (q == null) return;
    await logic.editCapacity(queueId: q.id, capacity: capacity);
    await _broadcast();
  }

  /// The host puts somebody in the queue directly. This is the only way in
  /// for someone typed in by hand, since they have no phone to ask with.
  Future<ClaimResult> hostAddToQueue(String userId) async {
    final q = _queue;
    if (q == null) return ClaimResult.failed(ClaimFailure.noSuchQueue);
    final result = await logic.claimNextAvailable(
      queueId: q.id,
      attendeeId: userId,
      messageId: 'host:${_uuid.v4()}',
    );
    await _broadcast();
    return result;
  }

  Future<List<QueueEntry>> currentEntries() =>
      _queue == null ? Future.value(const []) : logic.entries(_queue!.id);
}
