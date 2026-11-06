import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../domain/queue.dart';
import 'claim_result.dart';
import 'claim_serializer.dart';
import 'position_resolver.dart';

/// Every change to the queue. Only ever runs on the host.
///
/// Each change goes through [_serializer] and commits in one database
/// transaction, so arrival numbers never clash and the order always comes out
/// the same. Attendees don't change anything themselves — they ask, and then
/// use whatever the host sends back.
class QueueLogic {
  QueueLogic(this.db, {ClaimSerializer? serializer, Uuid? uuid})
      : _serializer = serializer ?? ClaimSerializer(),
        _uuid = uuid ?? const Uuid();

  final Database db;
  final ClaimSerializer _serializer;
  final Uuid _uuid;
  static const _resolver = PositionResolver();

  int get pendingClaims => _serializer.pending;
  Future<void> get idle => _serializer.idle;

  /// Runs [job] in the same queue as every other change.
  ///
  /// Anything that touches the database from a timer has to go through here.
  /// Reading while a transaction is open blocks until it times out — ten
  /// seconds with the host frozen — so this keeps that work in order with
  /// everything else.
  Future<T> serialized<T>(Future<T> Function() job) => _serializer.run(job);

  // ---------------------------------------------------------------- queries

  Future<Queue?> queue(String queueId) async {
    final rows =
        await db.query('queues', where: 'id = ?', whereArgs: [queueId]);
    return rows.isEmpty ? null : Queue.fromMap(rows.first);
  }

  Future<List<QueueEntry>> entries(String queueId) async {
    final rows = await db.query('queue_entries',
        where: 'queue_id = ?', whereArgs: [queueId], orderBy: 'seq ASC');
    return rows.map(QueueEntry.fromMap).toList();
  }

  /// Who is in which position right now, and who is in overflow.
  Future<QueueResolution> resolution(String queueId) async {
    final q = await queue(queueId);
    if (q == null) {
      return const QueueResolution(capacity: 1, slots: {}, overflow: []);
    }
    return _resolver.resolve(entries: await entries(queueId), capacity: q.capacity);
  }

  Future<Queue> createQueue({
    required String sessionId,
    required String name,
    required int capacity,
  }) async {
    final q = Queue(
      id: _uuid.v4(),
      sessionId: sessionId,
      name: name,
      capacity: capacity,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await db.insert('queues', q.toMap());
    return q;
  }

  // ----------------------------------------------------------- attendee ops

  /// Take the next free slot, or go into overflow if the queue is full.
  Future<ClaimResult> claimNextAvailable({
    required String queueId,
    required String attendeeId,
    required String messageId,
    int? clientRequestedAt,
  }) =>
      _claim(
        queueId: queueId,
        attendeeId: attendeeId,
        messageId: messageId,
        clientRequestedAt: clientRequestedAt,
        desiredSlot: null,
      );

  /// Take a specific slot. Fails if someone already has it.
  Future<ClaimResult> claimSpecificSlot({
    required String queueId,
    required String attendeeId,
    required int slot,
    required String messageId,
    int? clientRequestedAt,
  }) =>
      _claim(
        queueId: queueId,
        attendeeId: attendeeId,
        messageId: messageId,
        clientRequestedAt: clientRequestedAt,
        desiredSlot: slot,
      );

  /// Fix them in the position they're in now, so it stops moving up as
  /// people ahead of them leave.
  Future<ClaimResult> pinCurrentSlot({
    required String queueId,
    required String attendeeId,
  }) =>
      _serializer.run(() => db.transaction((txn) async {
            final q = await _queueIn(txn, queueId);
            if (q == null) return ClaimResult.failed(ClaimFailure.noSuchQueue);
            if (!q.isOpen) return ClaimResult.failed(ClaimFailure.queueClosed);

            final all = await _entriesIn(txn, queueId);
            final mine = all.firstWhereOrNull(
                (e) => e.attendeeId == attendeeId && e.status.isActive);
            if (mine == null) return ClaimResult.failed(ClaimFailure.notQueued);

            final before =
                _resolver.resolve(entries: all, capacity: q.capacity);
            final pos = before.positionOf(attendeeId)!;
            if (pos > q.capacity) {
              // They're in overflow, so there's no slot to pin.
              return ClaimResult.failed(ClaimFailure.slotOutOfRange);
            }

            await txn.update(
              'queue_entries',
              {'status': QueueEntryStatus.pinned.name, 'pinned_slot': pos},
              where: 'id = ?',
              whereArgs: [mine.id],
            );

            final after = _resolver.resolve(
                entries: await _entriesIn(txn, queueId), capacity: q.capacity);
            final r = after.forAttendee(attendeeId)!;
            return ClaimResult.success(
                entry: r.entry, position: r.position, isOverflow: r.isOverflow);
          }));

  /// Leave the queue. We keep the row so the history is still there.
  Future<ClaimResult> withdraw({
    required String queueId,
    required String attendeeId,
  }) =>
      _serializer.run(() => db.transaction((txn) async {
            final q = await _queueIn(txn, queueId);
            if (q == null) return ClaimResult.failed(ClaimFailure.noSuchQueue);

            final all = await _entriesIn(txn, queueId);
            final mine = all.firstWhereOrNull(
                (e) => e.attendeeId == attendeeId && e.status.isActive);
            if (mine == null) return ClaimResult.failed(ClaimFailure.notQueued);

            final position =
                await _currentPosition(txn, queueId, attendeeId);

            await txn.update(
              'queue_entries',
              {
                'status': QueueEntryStatus.withdrawn.name,
                'pinned_slot': null,
                'manual_order': null,
                'finished_at': DateTime.now().millisecondsSinceEpoch,
                'final_position': position,
              },
              where: 'id = ?',
              whereArgs: [mine.id],
            );
            return ClaimResult.success(
              entry: mine.copyWith(status: QueueEntryStatus.withdrawn),
              position: 0,
              isOverflow: false,
            );
          }));

  // --------------------------------------------------------------- host ops

  /// Marks someone as served and frees their slot.
  ///
  /// Everyone floating behind them moves up and the first person in overflow
  /// comes in. If they had pinned a slot, that slot is released.
  ///
  /// Runs in a transaction and checks the entry exists first, so an unknown
  /// id reports a failure instead of silently doing nothing.
  Future<ClaimResult> finish(String entryId, {int? timerMs}) =>
      _serializer.run(() => db.transaction((txn) async {
            final rows = await txn.query('queue_entries',
                where: 'id = ?', whereArgs: [entryId], limit: 1);
            if (rows.isEmpty) return ClaimResult.failed(ClaimFailure.notQueued);

            final entry = QueueEntry.fromMap(rows.first);
            if (!entry.status.isActive) {
              return ClaimResult.failed(ClaimFailure.notQueued);
            }

            final position = await _currentPosition(
                txn, entry.queueId, entry.attendeeId);

            await txn.update(
              'queue_entries',
              {
                'status': QueueEntryStatus.finished.name,
                'pinned_slot': null,
                'manual_order': null,
                'finished_at': DateTime.now().millisecondsSinceEpoch,
                'final_position': position,
                'timer_ms': ?timerMs,
              },
              where: 'id = ?',
              whereArgs: [entryId],
            );
            return ClaimResult.success(
              entry: entry.copyWith(status: QueueEntryStatus.finished),
              position: 0,
              isOverflow: false,
            );
          }));

  /// The host takes someone out of the queue.
  ///
  /// In a transaction so we can record which slot they were in before their
  /// status changes, same as the other ways of leaving.
  Future<void> hostRemove(String entryId) =>
      _serializer.run(() => db.transaction((txn) async {
            final rows = await txn.query('queue_entries',
                where: 'id = ?', whereArgs: [entryId], limit: 1);
            if (rows.isEmpty) return;
            final entry = QueueEntry.fromMap(rows.first);

            final position = entry.status.isActive
                ? await _currentPosition(txn, entry.queueId, entry.attendeeId)
                : entry.finalPosition;

            await txn.update(
              'queue_entries',
              {
                'status': QueueEntryStatus.withdrawn.name,
                'pinned_slot': null,
                'manual_order': null,
                'finished_at': DateTime.now().millisecondsSinceEpoch,
                'final_position': position,
              },
              where: 'id = ?',
              whereArgs: [entryId],
            );
          }));

  /// The host drags the queue into a specific order. [orderedEntryIds] is
  /// top to bottom, and this beats slots people pinned themselves.
  Future<void> hostReorder({
    required String queueId,
    required List<String> orderedEntryIds,
  }) =>
      _serializer.run(() => db.transaction((txn) async {
            final batch = txn.batch();
            for (var i = 0; i < orderedEntryIds.length; i++) {
              batch.update('queue_entries', {'manual_order': i + 1},
                  where: 'id = ?', whereArgs: [orderedEntryIds[i]]);
            }
            await batch.commit(noResult: true);
          }));

  /// The host moves one person to a specific slot, e.g. out of overflow.
  Future<void> hostPromote({
    required String entryId,
    required int toSlot,
  }) =>
      _serializer.run(() => db.update('queue_entries',
          {'manual_order': toSlot}, where: 'id = ?', whereArgs: [entryId]));

  /// Remove a host override so they go back to normal ordering.
  Future<void> clearOverride(String entryId) =>
      _serializer.run(() => db.update('queue_entries', {'manual_order': null},
          where: 'id = ?', whereArgs: [entryId]));

  /// Change the queue size. Making it smaller pushes the people at the back
  /// into overflow, and pinned slots that no longer exist become floating.
  Future<void> editCapacity({
    required String queueId,
    required int capacity,
  }) =>
      _serializer.run(() => db.update('queues', {'capacity': capacity},
          where: 'id = ?', whereArgs: [queueId]));

  Future<void> closeQueue(String queueId) => _serializer.run(() => db.update(
      'queues', {'closed_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?', whereArgs: [queueId]));

  // ------------------------------------------------------------- internals

  Future<ClaimResult> _claim({
    required String queueId,
    required String attendeeId,
    required String messageId,
    required int? desiredSlot,
    int? clientRequestedAt,
  }) =>
      _serializer.run(() => db.transaction((txn) async {
            // If the same request arrives twice — a Bluetooth retry after a
            // timeout — don't add them to the queue again.
            final prior = await txn.query('processed_requests',
                where: 'message_id = ?', whereArgs: [messageId], limit: 1);
            if (prior.isNotEmpty) {
              final json = jsonDecode(prior.first['result_json']! as String)
                  as Map<String, Object?>;
              return ClaimResult.fromJson(json).asReplay();
            }

            final result = await _runAtomicClaim(
              txn: txn,
              queueId: queueId,
              attendeeId: attendeeId,
              desiredSlot: desiredSlot,
              clientRequestedAt: clientRequestedAt,
            );

            await txn.insert('processed_requests', {
              'message_id': messageId,
              'queue_id': queueId,
              'result_json': jsonEncode(result.toJson()),
              'processed_at': DateTime.now().millisecondsSinceEpoch,
            });
            return result;
          }));

  Future<ClaimResult> _runAtomicClaim({
    required DatabaseExecutor txn,
    required String queueId,
    required String attendeeId,
    required int? desiredSlot,
    int? clientRequestedAt,
  }) async {
    final q = await _queueIn(txn, queueId);
    if (q == null) return ClaimResult.failed(ClaimFailure.noSuchQueue);
    if (!q.isOpen) return ClaimResult.failed(ClaimFailure.queueClosed);

    final existing = await _entriesIn(txn, queueId);

    // The database blocks this as well. Checking here just turns it into a
    // proper error message instead of a database exception.
    if (existing.any((e) => e.attendeeId == attendeeId && e.status.isActive)) {
      return ClaimResult.failed(ClaimFailure.alreadyQueued);
    }

    if (desiredSlot != null) {
      if (desiredSlot < 1 || desiredSlot > q.capacity) {
        return ClaimResult.failed(ClaimFailure.slotOutOfRange);
      }
      final taken = _resolver.resolve(entries: existing, capacity: q.capacity);
      if (taken.slots.containsKey(desiredSlot)) {
        return ClaimResult.failed(ClaimFailure.slotTaken);
      }
    }

    // Read and bump the arrival number inside this transaction, so two
    // people claiming at once can't get the same one.
    final seq = await _nextSeq(txn, queueId);

    final entry = QueueEntry(
      id: _uuid.v4(),
      queueId: queueId,
      attendeeId: attendeeId,
      seq: seq,
      status: desiredSlot == null
          ? QueueEntryStatus.floating
          : QueueEntryStatus.pinned,
      pinnedSlot: desiredSlot,
      clientRequestedAt: clientRequestedAt,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await txn.insert('queue_entries', entry.toMap());

    final after = _resolver
        .resolve(entries: [...existing, entry], capacity: q.capacity);
    final placed = after.forAttendee(attendeeId)!;
    return ClaimResult.success(
      entry: entry,
      position: placed.position,
      isOverflow: placed.isOverflow,
    );
  }

  /// Which slot this person is in right now.
  ///
  /// Has to be called BEFORE their status changes. Positions are worked out
  /// from people still waiting, so once someone has left there's no way to
  /// work out where they were.
  Future<int?> _currentPosition(
    DatabaseExecutor txn,
    String queueId,
    String attendeeId,
  ) async {
    final q = await _queueIn(txn, queueId);
    if (q == null) return null;
    final resolution = _resolver.resolve(
        entries: await _entriesIn(txn, queueId), capacity: q.capacity);
    return resolution.positionOf(attendeeId);
  }

  Future<int> _nextSeq(DatabaseExecutor txn, String queueId) async {
    final name = 'seq:$queueId';
    final rows = await txn
        .query('counters', where: 'name = ?', whereArgs: [name], limit: 1);
    final next = rows.isEmpty ? 1 : (rows.first['value']! as int) + 1;
    if (rows.isEmpty) {
      await txn.insert('counters', {'name': name, 'value': next});
    } else {
      await txn.update('counters', {'value': next},
          where: 'name = ?', whereArgs: [name]);
    }
    return next;
  }

  Future<Queue?> _queueIn(DatabaseExecutor txn, String queueId) async {
    final rows =
        await txn.query('queues', where: 'id = ?', whereArgs: [queueId]);
    return rows.isEmpty ? null : Queue.fromMap(rows.first);
  }

  Future<List<QueueEntry>> _entriesIn(
      DatabaseExecutor txn, String queueId) async {
    final rows = await txn.query('queue_entries',
        where: 'queue_id = ?', whereArgs: [queueId], orderBy: 'seq ASC');
    return rows.map(QueueEntry.fromMap).toList();
  }
}

extension<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
