import 'package:sqflite/sqflite.dart';

import '../domain/proximity.dart';
import '../identity/identity.dart';

/// One past session, as the history list shows it.
class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.title,
    required this.startedAt,
    required this.attendeeCount,
    required this.checkCount,
    this.endedAt,
    this.plannedEndAt,
  });

  final String id;
  final String title;
  final int startedAt;
  final int? endedAt;
  final int? plannedEndAt;

  /// Excludes attendees the host removed.
  final int attendeeCount;
  final int checkCount;

  DateTime get started => DateTime.fromMillisecondsSinceEpoch(startedAt);

  /// Null while a session is still running, or if the app was killed without
  /// the host ending it properly.
  Duration? get duration =>
      endedAt == null ? null : Duration(milliseconds: endedAt! - startedAt);

  bool get isFinished => endedAt != null;
}

/// One spot-check within a session. [ordinal] 1 renders as "Test 1".
class CheckRun {
  const CheckRun({
    required this.id,
    required this.ordinal,
    required this.ranAt,
    required this.manual,
  });

  final String id;
  final int ordinal;
  final int ranAt;
  final bool manual;

  String get label => 'Test $ordinal';
  DateTime get at => DateTime.fromMillisecondsSinceEpoch(ranAt);
}

/// How one attendee fared in one check.
enum CheckOutcome {
  pass,
  fail,

  /// They had not joined yet when this check ran. Deliberately distinct from
  /// a fail: absent-before-arriving is not the same as absent-while-enrolled.
  notYetJoined,

  /// A host-added walk-in with no device. Nothing to measure, so nothing is
  /// claimed either way.
  noDevice;

  String get csv => switch (this) {
        CheckOutcome.pass => 'pass',
        CheckOutcome.fail => 'fail',
        CheckOutcome.notYetJoined => '',
        CheckOutcome.noDevice => 'n/a',
      };
}

/// One row of the attendance grid.
class AttendeeReport {
  const AttendeeReport({
    required this.userId,
    required this.displayName,
    required this.firstJoinedAt,
    required this.kind,
    required this.outcomes,
    this.removedAt,
    this.leftAt,
  });

  final String userId;

  /// Host correction applied if there was one.
  final String displayName;

  final int firstJoinedAt;
  final UserKind kind;
  final int? removedAt;

  /// Epoch ms they left of their own accord. Kept apart from [removedAt]
  /// because the host throwing somebody out and somebody walking out are
  /// different facts, and a register should say which.
  final int? leftAt;

  /// Keyed by check id.
  final Map<String, CheckOutcome> outcomes;

  bool get wasRemoved => removedAt != null;
  bool get hasLeft => leftAt != null;

  DateTime get firstJoined =>
      DateTime.fromMillisecondsSinceEpoch(firstJoinedAt);

  int get passes =>
      outcomes.values.where((o) => o == CheckOutcome.pass).length;
  int get fails => outcomes.values.where((o) => o == CheckOutcome.fail).length;

  CheckOutcome outcomeFor(CheckRun run) =>
      outcomes[run.id] ?? CheckOutcome.notYetJoined;
}

/// One person's time in a queue, as the export reports it.
class QueueEntryReport {
  const QueueEntryReport({
    required this.displayName,
    required this.outcome,
    this.position,
    this.timerMs,
  });

  final String displayName;

  /// The slot they held when their entry ended, recorded at that moment
  /// because it cannot be recovered afterwards. Null for anyone still waiting.
  final int? position;

  /// What the host's timer measured, if one was run.
  final int? timerMs;

  /// `served`, `left`, or `waiting` — `finished_at` alone cannot tell these
  /// apart, so this comes from the status.
  final String outcome;

  Duration? get took =>
      timerMs == null ? null : Duration(milliseconds: timerMs!);
}

/// One queue and everyone who passed through it.
class QueueReport {
  const QueueReport({
    required this.id,
    required this.name,
    required this.capacity,
    required this.entries,
  });

  final String id;
  final String name;
  final int capacity;

  /// In arrival order, so the export reads as the queue happened.
  final List<QueueEntryReport> entries;
}

/// A whole session: the attendee list crossed with the checks.
///
/// One shape feeds the dashboard, the history detail screen and the CSV, so
/// those three cannot disagree with each other.
class SessionReport {
  const SessionReport({
    required this.summary,
    required this.checks,
    required this.attendees,
    this.queues = const [],
  });

  final SessionSummary summary;

  /// Every queue the session ran. A session can hold more than one over its
  /// life, so this is a list rather than a single queue.
  final List<QueueReport> queues;

  /// Ascending by ordinal.
  final List<CheckRun> checks;
  final List<AttendeeReport> attendees;

  Iterable<AttendeeReport> get active => attendees.where((a) => !a.wasRemoved);
  int get presentCount => active.length;

  /// Attendees who passed every check that ran while they were present.
  Iterable<AttendeeReport> get perfect => active.where((a) => a.fails == 0);

  /// The ones worth the host's attention: they missed at least one check.
  Iterable<AttendeeReport> get patchy => active.where((a) => a.fails > 0);
}

/// Reads sessions back out.
///
/// Before this, `sessions` and `attendance_entries` were written to and never
/// queried — the data had been accumulating on disk with nothing able to show
/// it.
class HistoryRepository {
  const HistoryRepository(this.db);

  final Database db;

  /// Newest first. Optionally only the sessions this host ran.
  Future<List<SessionSummary>> listSessions({String? hostId}) async {
    final rows = await db.rawQuery('''
      SELECT s.id, s.title, s.created_at, s.ended_at, s.planned_end_at,
             (SELECT COUNT(*) FROM attendance_entries a
               WHERE a.session_id = s.id AND a.removed_at IS NULL)
               AS attendee_count,
             (SELECT COUNT(*) FROM attendance_checks c
               WHERE c.session_id = s.id) AS check_count
      FROM sessions s
      ${hostId == null ? '' : 'WHERE s.host_id = ?'}
      ORDER BY s.created_at DESC
    ''', [?hostId]);

    return [
      for (final r in rows)
        SessionSummary(
          id: r['id']! as String,
          title: r['title']! as String,
          startedAt: r['created_at']! as int,
          endedAt: r['ended_at'] as int?,
          plannedEndAt: r['planned_end_at'] as int?,
          attendeeCount: r['attendee_count']! as int,
          checkCount: r['check_count']! as int,
        ),
    ];
  }

  Future<SessionSummary?> summary(String sessionId) async {
    final all = await listSessions();
    for (final s in all) {
      if (s.id == sessionId) return s;
    }
    return null;
  }

  /// The full grid for one session.
  Future<SessionReport?> report(String sessionId) async {
    final head = await summary(sessionId);
    if (head == null) return null;

    final checkRows = await db.query('attendance_checks',
        where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'ordinal ASC');
    final checks = [
      for (final c in checkRows)
        CheckRun(
          id: c['id']! as String,
          ordinal: c['ordinal']! as int,
          ranAt: c['ran_at']! as int,
          manual: (c['manual'] as int? ?? 0) == 1,
        ),
    ];

    // Host label wins over the stored name, matching the live roster.
    final attendeeRows = await db.rawQuery('''
      SELECT a.attendee_id, a.joined_at, a.removed_at, a.left_at, a.host_label,
             u.display_name, u.kind
      FROM attendance_entries a
      JOIN users u ON u.id = a.attendee_id
      WHERE a.session_id = ?
      ORDER BY a.joined_at ASC
    ''', [sessionId]);

    final resultRows = await db.rawQuery('''
      SELECT r.check_id, r.attendee_id, r.passed
      FROM attendance_check_results r
      JOIN attendance_checks c ON c.id = r.check_id
      WHERE c.session_id = ?
    ''', [sessionId]);

    final byAttendee = <String, Map<String, CheckOutcome>>{};
    for (final r in resultRows) {
      final attendee = r['attendee_id']! as String;
      byAttendee.putIfAbsent(attendee, () => {})[r['check_id']! as String] =
          (r['passed']! as int) == 1 ? CheckOutcome.pass : CheckOutcome.fail;
    }

    return SessionReport(
      summary: head,
      checks: checks,
      queues: await _queues(sessionId),
      attendees: [
        for (final a in attendeeRows)
          () {
            final id = a['attendee_id']! as String;
            final kind = UserKind.fromName(a['kind']! as String);
            final outcomes = byAttendee[id] ?? <String, CheckOutcome>{};
            return AttendeeReport(
              userId: id,
              displayName:
                  (a['host_label'] as String?) ?? a['display_name']! as String,
              firstJoinedAt: a['joined_at']! as int,
              kind: kind,
              removedAt: a['removed_at'] as int?,
              leftAt: a['left_at'] as int?,
              outcomes: {
                for (final c in checks)
                  c.id: outcomes[c.id] ??
                      // No stored result: either they had not arrived, or they
                      // have no device to measure.
                      (kind == UserKind.manual
                          ? CheckOutcome.noDevice
                          : CheckOutcome.notYetJoined),
              },
            );
          }(),
      ],
    );
  }

  /// Every queue in the session, each with everyone who passed through it.
  ///
  /// Names prefer the host's session-scoped label exactly as the attendance
  /// table does, so the two sections of the export cannot disagree about who
  /// somebody is.
  Future<List<QueueReport>> _queues(String sessionId) async {
    final queueRows = await db.query('queues',
        where: 'session_id = ?',
        whereArgs: [sessionId],
        orderBy: 'created_at ASC');

    final reports = <QueueReport>[];
    for (final q in queueRows) {
      final queueId = q['id']! as String;
      final entryRows = await db.rawQuery('''
        SELECT e.status, e.final_position, e.timer_ms, e.seq,
               u.display_name, a.host_label
        FROM queue_entries e
        JOIN users u ON u.id = e.attendee_id
        LEFT JOIN attendance_entries a
          ON a.attendee_id = e.attendee_id AND a.session_id = ?
        WHERE e.queue_id = ?
        ORDER BY e.seq ASC
      ''', [sessionId, queueId]);

      reports.add(QueueReport(
        id: queueId,
        name: q['name']! as String,
        capacity: q['capacity']! as int,
        entries: [
          for (final e in entryRows)
            QueueEntryReport(
              displayName: (e['host_label'] as String?) ??
                  e['display_name']! as String,
              position: e['final_position'] as int?,
              timerMs: e['timer_ms'] as int?,
              outcome: switch (e['status']! as String) {
                'finished' => 'served',
                'withdrawn' => 'left',
                _ => 'waiting',
              },
            ),
        ],
      ));
    }
    return reports;
  }

  /// Marks a session archived: it stays in history and stays exportable, it
  /// just stops appearing as active. The safe counterpart to [deleteSession].
  Future<void> archiveSession(String sessionId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update('sessions', {'ended_at': now},
        where: 'id = ? AND ended_at IS NULL', whereArgs: [sessionId]);
  }

  /// Permanently removes a session and everything recorded during it.
  ///
  /// Attendance, queues, entries and checks all carry ON DELETE CASCADE with
  /// foreign keys enabled, so one delete takes the lot. There is no undo,
  /// which is why the caller warns first.
  Future<void> deleteSession(String sessionId) async {
    await db.delete('sessions', where: 'id = ?', whereArgs: [sessionId]);
  }

  /// True when nothing was ever recorded, so the UI can offer a quieter
  /// confirmation for a session with nothing in it.
  Future<bool> isSessionEmpty(String sessionId) async {
    final report = await this.report(sessionId);
    return report == null ||
        (report.attendees.isEmpty && report.checks.isEmpty);
  }

  /// Records a spot-check and its per-attendee verdicts in one transaction, so
  /// a check never exists with half its results.
  Future<CheckRun> recordCheck({
    required String checkId,
    required String sessionId,
    required int ranAt,
    required bool manual,
    required Map<String, ProximityState> presence,
    required Set<String> manualAttendees,
  }) async {
    return db.transaction((txn) async {
      final existing = await txn.rawQuery(
          'SELECT MAX(ordinal) AS n FROM attendance_checks WHERE session_id = ?',
          [sessionId]);
      final ordinal = ((existing.first['n'] as int?) ?? 0) + 1;

      await txn.insert('attendance_checks', {
        'id': checkId,
        'session_id': sessionId,
        'ordinal': ordinal,
        'ran_at': ranAt,
        'manual': manual ? 1 : 0,
      });

      final batch = txn.batch();
      for (final MapEntry(key: userId, value: state) in presence.entries) {
        // A host-typed walk-in has no phone, so a pass would be meaningless.
        if (manualAttendees.contains(userId)) continue;
        batch.insert('attendance_check_results', {
          'check_id': checkId,
          'attendee_id': userId,
          // Lenient by design: only a fully lost link counts as absent.
          'passed': state == ProximityState.lost ? 0 : 1,
          'proximity': state.name,
        });
      }
      await batch.commit(noResult: true);

      return CheckRun(
          id: checkId, ordinal: ordinal, ranAt: ranAt, manual: manual);
    });
  }
}
