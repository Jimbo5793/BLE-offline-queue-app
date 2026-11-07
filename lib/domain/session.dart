import 'proximity.dart';

/// A session the host runs. Attendees find it by scanning over Bluetooth;
/// there is no code or QR to enter, you just have to be in range. The host
/// can lock it to stop anyone else joining.
class Session {
  const Session({
    required this.id,
    required this.hostId,
    required this.title,
    required this.createdAt,
    this.endedAt,
    this.attendanceOpenUntil,
    this.lockedAt,
    this.plannedEndAt,
    this.checkMode = false,
    this.checkTarget,
  });

  final String id;
  final String hostId;
  final String title;

  final int createdAt;
  final int? endedAt;

  /// Time after which nobody new can join. Null means no cut-off.
  final int? attendanceOpenUntil;

  /// When the host locked it. A locked session keeps running, it just stops
  /// letting new people in.
  final int? lockedAt;

  /// When the host expects to finish. Only used to show a warning; we never
  /// end the session automatically, since a class that runs over shouldn't
  /// lose its queue.
  final int? plannedEndAt;

  /// Whether random attendance checks are on.
  final bool checkMode;

  /// How many checks were planned. Null if checks are off, or if there is no
  /// session length and they just repeat.
  final int? checkTarget;

  /// How long the host said the session would be.
  Duration? get plannedLength => plannedEndAt == null
      ? null
      : Duration(milliseconds: plannedEndAt! - createdAt);

  bool plannedEndPassedAt(int nowMs) =>
      plannedEndAt != null && nowMs >= plannedEndAt!;

  bool get isOpen => endedAt == null;
  bool get isLocked => lockedAt != null;

  /// Whether someone new can join right now.
  bool acceptsJoinsAt(int nowMs) =>
      isOpen &&
      !isLocked &&
      (attendanceOpenUntil == null || nowMs <= attendanceOpenUntil!);

  Session copyWith({
    String? title,
    int? endedAt,
    int? attendanceOpenUntil,
    int? lockedAt,
    int? plannedEndAt,
    bool? checkMode,
    int? checkTarget,
    bool clearLock = false,
    bool clearPlannedEnd = false,
  }) =>
      Session(
        id: id,
        hostId: hostId,
        title: title ?? this.title,
        createdAt: createdAt,
        endedAt: endedAt ?? this.endedAt,
        attendanceOpenUntil: attendanceOpenUntil ?? this.attendanceOpenUntil,
        lockedAt: clearLock ? null : (lockedAt ?? this.lockedAt),
        plannedEndAt:
            clearPlannedEnd ? null : (plannedEndAt ?? this.plannedEndAt),
        checkMode: checkMode ?? this.checkMode,
        checkTarget: checkTarget ?? this.checkTarget,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'host_id': hostId,
        'title': title,
        'created_at': createdAt,
        'ended_at': endedAt,
        'attendance_open_until': attendanceOpenUntil,
        'locked_at': lockedAt,
        'planned_end_at': plannedEndAt,
        'check_mode': checkMode ? 1 : 0,
        'check_target': checkTarget,
      };

  static Session fromMap(Map<String, Object?> m) => Session(
        id: m['id']! as String,
        hostId: m['host_id']! as String,
        title: m['title']! as String,
        createdAt: m['created_at']! as int,
        endedAt: m['ended_at'] as int?,
        attendanceOpenUntil: m['attendance_open_until'] as int?,
        lockedAt: m['locked_at'] as int?,
        plannedEndAt: m['planned_end_at'] as int?,
        checkMode: (m['check_mode'] as int?) == 1,
        checkTarget: m['check_target'] as int?,
      );
}

/// One person's attendance in one session, and how close they are.
class AttendanceEntry {
  const AttendanceEntry({
    required this.id,
    required this.sessionId,
    required this.attendeeId,
    required this.joinedAt,
    required this.lastSeenAt,
    this.proximity = ProximityState.inRange,
    this.rssiEma,
    this.present = true,
    this.hostLabel,
    this.removedAt,
    this.leftAt,
  });

  final String id;
  final String sessionId;
  final String attendeeId;
  final int joinedAt;

  /// When they last checked in. The host uses this to spot people who have
  /// gone quiet.
  final int lastSeenAt;

  final ProximityState proximity;

  /// The last signal strength they reported. Null until their first check-in.
  final double? rssiEma;

  /// The host can mark someone present or absent by hand.
  final bool present;

  /// A name the host typed to correct this person, for this session only.
  /// Shown instead of the name they chose themselves.
  final String? hostLabel;

  /// When the host removed them. They drop off the live list but stay in the
  /// history and the export, marked as removed.
  final int? removedAt;

  /// When they chose to leave. Kept separate from [removedAt] so the export
  /// can say whether they left or were removed.
  final int? leftAt;

  bool get wasRemoved => removedAt != null;
  bool get hasLeft => leftAt != null;

  /// True if they are off the live list either way.
  bool get isGone => wasRemoved || hasLeft;

  AttendanceEntry copyWith({
    int? lastSeenAt,
    ProximityState? proximity,
    double? rssiEma,
    bool? present,
    String? hostLabel,
    int? removedAt,
    int? leftAt,
  }) =>
      AttendanceEntry(
        id: id,
        sessionId: sessionId,
        attendeeId: attendeeId,
        joinedAt: joinedAt,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        proximity: proximity ?? this.proximity,
        rssiEma: rssiEma ?? this.rssiEma,
        present: present ?? this.present,
        hostLabel: hostLabel ?? this.hostLabel,
        removedAt: removedAt ?? this.removedAt,
        leftAt: leftAt ?? this.leftAt,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'session_id': sessionId,
        'attendee_id': attendeeId,
        'joined_at': joinedAt,
        'last_seen_at': lastSeenAt,
        'proximity': proximity.name,
        'rssi_ema': rssiEma,
        'present': present ? 1 : 0,
        'host_label': hostLabel,
        'removed_at': removedAt,
        'left_at': leftAt,
      };

  static AttendanceEntry fromMap(Map<String, Object?> m) => AttendanceEntry(
        id: m['id']! as String,
        sessionId: m['session_id']! as String,
        attendeeId: m['attendee_id']! as String,
        joinedAt: m['joined_at']! as int,
        lastSeenAt: m['last_seen_at']! as int,
        proximity: ProximityState.values
            .firstWhere((e) => e.name == m['proximity']! as String),
        rssiEma: (m['rssi_ema'] as num?)?.toDouble(),
        present: (m['present']! as int) == 1,
        hostLabel: m['host_label'] as String?,
        removedAt: m['removed_at'] as int?,
        leftAt: m['left_at'] as int?,
      );
}
