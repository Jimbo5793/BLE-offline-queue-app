import '../domain/queue.dart';

/// One entry placed at a concrete position.
class ResolvedEntry {
  const ResolvedEntry({
    required this.entry,
    required this.position,
    required this.isOverflow,
    this.pinHonoured = false,
    this.demotedFromPin = false,
  });

  final QueueEntry entry;

  /// Starts at 1. Overflow entries carry on past the capacity.
  final int position;

  final bool isOverflow;

  /// True if this person got the exact slot they asked for.
  final bool pinHonoured;

  /// Asked for a slot but someone earlier had it, so they're floating.
  final bool demotedFromPin;

  String get attendeeId => entry.attendeeId;
}

/// The full picture of a queue at one instant.
class QueueResolution {
  const QueueResolution({
    required this.capacity,
    required this.slots,
    required this.overflow,
  });

  final int capacity;

  /// Position to entry, for positions inside the capacity. Can have gaps: if
  /// someone pins slot 3 and nobody is in 1 or 2, those stay empty.
  final Map<int, ResolvedEntry> slots;

  /// Everyone past the capacity, in order.
  final List<ResolvedEntry> overflow;

  List<ResolvedEntry> get all => [
        ...(slots.keys.toList()..sort()).map((k) => slots[k]!),
        ...overflow,
      ];

  int get filledSlots => slots.length;
  int get freeSlots => capacity - slots.length;

  /// Slots inside the capacity that nobody is on.
  List<int> get emptySlots =>
      [for (var i = 1; i <= capacity; i++) if (!slots.containsKey(i)) i];

  ResolvedEntry? forAttendee(String attendeeId) {
    for (final r in all) {
      if (r.attendeeId == attendeeId) return r;
    }
    return null;
  }

  int? positionOf(String attendeeId) => forAttendee(attendeeId)?.position;
}

/// Works out who is in which queue position.
///
/// Plain Dart with no database or Bluetooth, so the ordering rules can be
/// tested on their own.
///
/// Order of priority:
///   1. slots the host set by hand
///   2. slots an attendee pinned
///   3. everyone else, by arrival order, filling the lowest free slot
///
/// If two people want the same slot, whoever arrived first gets it and the
/// other one becomes floating.
class PositionResolver {
  const PositionResolver();

  QueueResolution resolve({
    required Iterable<QueueEntry> entries,
    required int capacity,
  }) {
    assert(capacity > 0, 'capacity must be positive');

    final active = entries.where((e) => e.status.isActive).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));

    final slots = <int, ResolvedEntry>{};
    final floating = <QueueEntry>[];
    final demoted = <String>{};

    // Step 1: slots the host set. Earlier arrival wins a clash.
    final overrides = active.where((e) => e.manualOrder != null).toList()
      ..sort((a, b) {
        final c = a.manualOrder!.compareTo(b.manualOrder!);
        return c != 0 ? c : a.seq.compareTo(b.seq);
      });
    for (final e in overrides) {
      final want = e.manualOrder!;
      if (want >= 1 && want <= capacity && !slots.containsKey(want)) {
        slots[want] = ResolvedEntry(
          entry: e,
          position: want,
          isOverflow: false,
          pinHonoured: e.status == QueueEntryStatus.pinned,
        );
      } else {
        floating.add(e);
      }
    }

    // Step 2: slots people pinned themselves.
    final pinned = active
        .where((e) =>
            e.manualOrder == null &&
            e.status == QueueEntryStatus.pinned &&
            e.pinnedSlot != null)
        .toList()
      ..sort((a, b) {
        final c = a.pinnedSlot!.compareTo(b.pinnedSlot!);
        return c != 0 ? c : a.seq.compareTo(b.seq);
      });
    for (final e in pinned) {
      final want = e.pinnedSlot!;
      if (want >= 1 && want <= capacity && !slots.containsKey(want)) {
        slots[want] =
            ResolvedEntry(entry: e, position: want, isOverflow: false, pinHonoured: true);
      } else {
        // Slot already taken, or the host shrank the queue below it.
        // Treat them as floating instead.
        floating.add(e);
        demoted.add(e.id);
      }
    }

    // Step 3: everyone else, in arrival order.
    floating.addAll(active.where((e) =>
        e.manualOrder == null &&
        !(e.status == QueueEntryStatus.pinned && e.pinnedSlot != null)));
    floating.sort((a, b) => a.seq.compareTo(b.seq));

    final overflow = <ResolvedEntry>[];
    var cursor = 1;
    var overflowPos = capacity;
    for (final e in floating) {
      while (cursor <= capacity && slots.containsKey(cursor)) {
        cursor++;
      }
      if (cursor <= capacity) {
        slots[cursor] = ResolvedEntry(
          entry: e,
          position: cursor,
          isOverflow: false,
          demotedFromPin: demoted.contains(e.id),
        );
        cursor++;
      } else {
        overflowPos++;
        overflow.add(ResolvedEntry(
          entry: e,
          position: overflowPos,
          isOverflow: true,
          demotedFromPin: demoted.contains(e.id),
        ));
      }
    }

    return QueueResolution(capacity: capacity, slots: slots, overflow: overflow);
  }
}
