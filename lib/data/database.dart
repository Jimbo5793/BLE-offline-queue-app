import 'package:sqflite/sqflite.dart';

/// The host's database.
///
/// Only the host opens this, and it holds everything: sessions, attendance and
/// queues. Attendees just keep the last update the host sent them in memory.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const int schemaVersion = 6;

  /// Opens the database. [factory] is passed in so tests can run the real
  /// schema without a device.
  static Future<AppDatabase> open({
    required String path,
    DatabaseFactory? factory,
  }) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        onCreate: (d, _) async {
          for (final stmt in _ddl) {
            await d.execute(stmt);
          }
        },
        // Upgrades run in order and only ever add things. An earlier version
        // dropped all the tables and rebuilt them, which would now wipe the
        // session history.
        onUpgrade: (d, from, to) async {
          for (var v = from + 1; v <= to; v++) {
            for (final stmt in _migrations[v] ?? const <String>[]) {
              await d.execute(stmt);
            }
          }
        },
      ),
    );
    return AppDatabase._(db);
  }

  static Future<AppDatabase> openInMemory({DatabaseFactory? factory}) =>
      open(path: inMemoryDatabasePath, factory: factory);

  Future<void> close() => db.close();

  static const List<String> _ddl = [
    // A user's id is their public key, so we can check a signature without
    // looking anything up. People the host typed in by hand have no key and
    // get an id like 'manual:<uuid>'.
    '''
    CREATE TABLE users(
      id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      kind TEXT NOT NULL,
      public_key TEXT,
      first_seen_at INTEGER NOT NULL,
      name_set_at INTEGER NOT NULL
    )''',
    '''
    CREATE TABLE sessions(
      id TEXT PRIMARY KEY,
      host_id TEXT NOT NULL REFERENCES users(id),
      title TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      ended_at INTEGER,
      attendance_open_until INTEGER,
      locked_at INTEGER,
      -- How long the host said it would be. Only used for a warning; we
      -- never end the session automatically.
      planned_end_at INTEGER,
      check_mode INTEGER NOT NULL DEFAULT 0,
      check_target INTEGER
    )''',
    '''
    CREATE TABLE attendance_entries(
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      attendee_id TEXT NOT NULL REFERENCES users(id),
      joined_at INTEGER NOT NULL,
      last_seen_at INTEGER NOT NULL,
      proximity TEXT NOT NULL DEFAULT 'inRange',
      rssi_ema REAL,
      present INTEGER NOT NULL DEFAULT 1,
      -- A name the host typed to correct this person, for this session only.
      -- Shown instead of the name they chose, without changing their account.
      host_label TEXT,
      -- Removing someone takes them off the live list but keeps them in the
      -- history and the export, so a mistaken tap can be undone.
      removed_at INTEGER,
      -- When they chose to leave. Kept separate from removed_at so the export
      -- can say whether they left or were removed. Either way they keep their
      -- attendance and check results up to that point.
      left_at INTEGER,
      UNIQUE(session_id, attendee_id)
    )''',
    '''
    CREATE TABLE queues(
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      capacity INTEGER NOT NULL CHECK(capacity > 0),
      created_at INTEGER NOT NULL,
      closed_at INTEGER
    )''',
    '''
    CREATE TABLE queue_entries(
      id TEXT PRIMARY KEY,
      queue_id TEXT NOT NULL REFERENCES queues(id) ON DELETE CASCADE,
      attendee_id TEXT NOT NULL REFERENCES users(id),
      seq INTEGER NOT NULL,
      status TEXT NOT NULL,
      pinned_slot INTEGER,
      manual_order INTEGER,
      client_requested_at INTEGER,
      created_at INTEGER NOT NULL,
      finished_at INTEGER,
      -- The slot they were actually in, saved when they leave. Positions are
      -- worked out from people still waiting, so this is the only way the
      -- export can say where somebody was.
      final_position INTEGER,
      -- How long the host's timer ran, in milliseconds.
      timer_ms INTEGER
    )''',
    // One person can only have one active entry per queue. The database
    // enforces this, not our code.
    //
    // Written with OR instead of IN on purpose: Android 7.0 ships SQLite
    // 3.9.2, which rejects an IN list here. Tests use a newer SQLite and
    // wouldn't catch it.
    '''
    CREATE UNIQUE INDEX idx_queue_active_attendee
      ON queue_entries(queue_id, attendee_id)
      WHERE status = 'floating' OR status = 'pinned' ''',
    // Arrival numbers are unique within a queue. This is what lets us answer
    // "who was first".
    '''
    CREATE UNIQUE INDEX idx_queue_seq ON queue_entries(queue_id, seq)''',
    // Two people must never hold the same pinned slot. Our code checks first,
    // but a check can race and an index can't, so this is the real guarantee.
    // Floating positions don't need one: they're calculated, and the resolver
    // gives each a different slot anyway.
    '''
    CREATE UNIQUE INDEX idx_queue_pinned_slot
      ON queue_entries(queue_id, pinned_slot)
      WHERE status = 'pinned' ''',
    '''
    CREATE INDEX idx_queue_entries_queue ON queue_entries(queue_id, status)''',
    // Speeds up the query we run most: everyone active in a queue, in
    // arrival order.
    '''
    CREATE INDEX idx_queue_active_order ON queue_entries(queue_id, seq)
      WHERE status = 'floating' OR status = 'pinned' ''',
    // Records requests we've already handled, so a retry after a Bluetooth
    // timeout gets the same answer instead of joining the queue twice.
    '''
    CREATE TABLE processed_requests(
      message_id TEXT PRIMARY KEY,
      queue_id TEXT,
      result_json TEXT NOT NULL,
      processed_at INTEGER NOT NULL
    )''',
    // The arrival counter for each queue. Bumped inside the claim
    // transaction so the numbers never clash.
    '''
    CREATE TABLE counters(
      name TEXT PRIMARY KEY,
      value INTEGER NOT NULL
    )''',
    ..._v3Tables,
  ];

  /// One attendance check. Number 1 is shown as "Test 1" everywhere.
  static const List<String> _v3Tables = [
    '''
    CREATE TABLE attendance_checks(
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      ordinal INTEGER NOT NULL,
      ran_at INTEGER NOT NULL,
      manual INTEGER NOT NULL DEFAULT 0
    )''',
    '''
    CREATE UNIQUE INDEX idx_check_ordinal
      ON attendance_checks(session_id, ordinal)''',
    // One row per person per check. We keep the signal state as well as the
    // pass/fail so the host can see why somebody failed.
    '''
    CREATE TABLE attendance_check_results(
      check_id TEXT NOT NULL REFERENCES attendance_checks(id) ON DELETE CASCADE,
      attendee_id TEXT NOT NULL REFERENCES users(id),
      passed INTEGER NOT NULL,
      proximity TEXT NOT NULL,
      PRIMARY KEY (check_id, attendee_id)
    )''',
    '''
    CREATE INDEX idx_check_results_attendee
      ON attendance_check_results(attendee_id)''',
  ];

  /// Upgrades, keyed by the version they produce.
  ///
  /// The oldest SQLite we support can add columns but not drop them, so
  /// nothing here removes anything.
  static const Map<int, List<String>> _migrations = {
    6: [
      'ALTER TABLE attendance_entries ADD COLUMN left_at INTEGER',
    ],
    5: [
      '''
      CREATE UNIQUE INDEX idx_queue_pinned_slot
        ON queue_entries(queue_id, pinned_slot)
        WHERE status = 'pinned' ''',
    ],
    4: [
      'ALTER TABLE queue_entries ADD COLUMN final_position INTEGER',
      'ALTER TABLE queue_entries ADD COLUMN timer_ms INTEGER',
    ],
    3: [
      'ALTER TABLE sessions ADD COLUMN planned_end_at INTEGER',
      'ALTER TABLE sessions ADD COLUMN check_mode INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE sessions ADD COLUMN check_target INTEGER',
      'ALTER TABLE attendance_entries ADD COLUMN removed_at INTEGER',
      ..._v3Tables,
    ],
  };

}
