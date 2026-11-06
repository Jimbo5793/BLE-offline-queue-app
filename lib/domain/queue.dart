/// The queue model. Plain Dart, no Flutter or Bluetooth.
library;

/// The states a queue entry can be in.
enum QueueEntryStatus {
  /// Took the next free slot. Moves up as people ahead leave.
  floating,

  /// Picked a specific slot. Stays there even if slots ahead free up.
  pinned,

  /// Left, or was removed by the host.
  withdrawn,

  /// Done.
  finished;

  /// The two states that take up a place in the queue. Only these count
  /// towards the one-entry-per-person rule.
  bool get isActive =>
      this == QueueEntryStatus.floating || this == QueueEntryStatus.pinned;

  static QueueEntryStatus fromName(String v) =>
      QueueEntryStatus.values.firstWhere((e) => e.name == v);
}

class QueueEntry {
  const QueueEntry({
    required this.id,
    required this.queueId,
    required this.attendeeId,
    required this.seq,
    required this.status,
    required this.createdAt,
    this.pinnedSlot,
    this.manualOrder,
    this.clientRequestedAt,
    this.finishedAt,
    this.finalPosition,
    this.timerMs,
  });

  final String id;
  final String queueId;
  final String attendeeId;

  /// Arrival number, set by the host. This is how we decide who was first.
  final int seq;

  final QueueEntryStatus status;

  /// The slot they picked, if they pinned one. Starts at 1.
  final int? pinnedSlot;

  /// Position the host set by hand. Beats pins and arrival order.
  final int? manualOrder;

  /// The time the attendee's own device claimed. Stored for reference only —
  /// we never order by it, since phone clocks differ and can be faked.
  final int? clientRequestedAt;

  final int createdAt;
  final int? finishedAt;

  /// The slot they were in when they left or finished. Saved at that moment,
  /// because positions are worked out from people still waiting.
  final int? finalPosition;

  /// How long the host's timer ran, in milliseconds. Null if no timer.
  final int? timerMs;

  QueueEntry copyWith({
    QueueEntryStatus? status,
    int? pinnedSlot,
    int? manualOrder,
    int? finishedAt,
    bool clearPinnedSlot = false,
    bool clearManualOrder = false,
  }) =>
      QueueEntry(
        id: id,
        queueId: queueId,
        attendeeId: attendeeId,
        seq: seq,
        status: status ?? this.status,
        pinnedSlot: clearPinnedSlot ? null : (pinnedSlot ?? this.pinnedSlot),
        manualOrder: clearManualOrder ? null : (manualOrder ?? this.manualOrder),
        clientRequestedAt: clientRequestedAt,
        createdAt: createdAt,
        finishedAt: finishedAt ?? this.finishedAt,
        finalPosition: finalPosition,
        timerMs: timerMs,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'queue_id': queueId,
        'attendee_id': attendeeId,
        'seq': seq,
        'status': status.name,
        'pinned_slot': pinnedSlot,
        'manual_order': manualOrder,
        'client_requested_at': clientRequestedAt,
        'created_at': createdAt,
        'finished_at': finishedAt,
        'final_position': finalPosition,
        'timer_ms': timerMs,
      };

  static QueueEntry fromMap(Map<String, Object?> m) => QueueEntry(
        id: m['id']! as String,
        queueId: m['queue_id']! as String,
        attendeeId: m['attendee_id']! as String,
        seq: m['seq']! as int,
        status: QueueEntryStatus.fromName(m['status']! as String),
        pinnedSlot: m['pinned_slot'] as int?,
        manualOrder: m['manual_order'] as int?,
        clientRequestedAt: m['client_requested_at'] as int?,
        createdAt: m['created_at']! as int,
        finishedAt: m['finished_at'] as int?,
        finalPosition: m['final_position'] as int?,
        timerMs: m['timer_ms'] as int?,
      );
}

class Queue {
  const Queue({
    required this.id,
    required this.sessionId,
    required this.name,
    required this.capacity,
    required this.createdAt,
    this.closedAt,
  });

  final String id;
  final String sessionId;
  final String name;

  /// How many real slots there are. Anyone past this is in overflow.
  final int capacity;

  final int createdAt;
  final int? closedAt;

  bool get isOpen => closedAt == null;

  Queue copyWith({String? name, int? capacity, int? closedAt}) => Queue(
        id: id,
        sessionId: sessionId,
        name: name ?? this.name,
        capacity: capacity ?? this.capacity,
        createdAt: createdAt,
        closedAt: closedAt ?? this.closedAt,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'session_id': sessionId,
        'name': name,
        'capacity': capacity,
        'created_at': createdAt,
        'closed_at': closedAt,
      };

  static Queue fromMap(Map<String, Object?> m) => Queue(
        id: m['id']! as String,
        sessionId: m['session_id']! as String,
        name: m['name']! as String,
        capacity: m['capacity']! as int,
        createdAt: m['created_at']! as int,
        closedAt: m['closed_at'] as int?,
      );
}
