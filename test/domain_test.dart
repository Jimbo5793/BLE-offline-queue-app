import 'package:beaconq/domain/proximity.dart';
import 'package:beaconq/domain/queue.dart';
import 'package:beaconq/domain/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('session', () {
    const session = Session(
      id: 's1',
      hostId: 'host',
      title: 'Lab 3',
      createdAt: 1000,
      attendanceOpenUntil: 5000,
      plannedEndAt: 9000,
      checkMode: true,
      checkTarget: 2,
    );

    test('survives a round trip through a database map', () {
      final copy = Session.fromMap(session.toMap());
      expect(copy.id, 's1');
      expect(copy.hostId, 'host');
      expect(copy.title, 'Lab 3');
      expect(copy.attendanceOpenUntil, 5000);
      expect(copy.plannedEndAt, 9000);
      expect(copy.checkMode, isTrue);
      expect(copy.checkTarget, 2);
    });

    test('accepts joins only while open, unlocked and before the cutoff', () {
      expect(session.acceptsJoinsAt(4000), isTrue);
      expect(session.acceptsJoinsAt(6000), isFalse);
      expect(session.copyWith(lockedAt: 2000).acceptsJoinsAt(3000), isFalse);
      expect(session.copyWith(endedAt: 2000).acceptsJoinsAt(3000), isFalse);
    });
  });

  group('attendance entry', () {
    test('keeps removal and leaving apart', () {
      const entry = AttendanceEntry(
        id: 'a1',
        sessionId: 's1',
        attendeeId: 'u1',
        joinedAt: 1,
        lastSeenAt: 2,
        proximity: ProximityState.warning,
        leftAt: 3,
      );
      final copy = AttendanceEntry.fromMap(entry.toMap());

      expect(copy.proximity, ProximityState.warning);
      expect(copy.hasLeft, isTrue);
      expect(copy.wasRemoved, isFalse);
      expect(copy.isGone, isTrue);
    });
  });

  group('queue', () {
    test('only floating and pinned entries are active', () {
      expect(QueueEntryStatus.floating.isActive, isTrue);
      expect(QueueEntryStatus.pinned.isActive, isTrue);
      expect(QueueEntryStatus.withdrawn.isActive, isFalse);
      expect(QueueEntryStatus.finished.isActive, isFalse);
    });

    test('an entry survives a round trip through a database map', () {
      const entry = QueueEntry(
        id: 'e1',
        queueId: 'q1',
        attendeeId: 'u1',
        seq: 7,
        status: QueueEntryStatus.pinned,
        createdAt: 100,
        pinnedSlot: 3,
      );
      final copy = QueueEntry.fromMap(entry.toMap());

      expect(copy.seq, 7);
      expect(copy.status, QueueEntryStatus.pinned);
      expect(copy.pinnedSlot, 3);
      expect(copy.manualOrder, isNull);
    });

    test('a queue is open until it is closed', () {
      const queue = Queue(
        id: 'q1',
        sessionId: 's1',
        name: 'Questions',
        capacity: 5,
        createdAt: 1,
      );
      expect(queue.isOpen, isTrue);
      expect(Queue.fromMap(queue.toMap()).capacity, 5);
      expect(queue.copyWith(closedAt: 2).isOpen, isFalse);
    });
  });
}
