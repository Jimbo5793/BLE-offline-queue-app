import 'package:beaconq/domain/queue.dart';
import 'package:beaconq/logic/position_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

QueueEntry entry(
  String who,
  int seq, {
  QueueEntryStatus status = QueueEntryStatus.floating,
  int? pin,
  int? manual,
}) =>
    QueueEntry(
      id: 'e$seq',
      queueId: 'q1',
      attendeeId: who,
      seq: seq,
      status: status,
      createdAt: seq,
      pinnedSlot: pin,
      manualOrder: manual,
    );

void main() {
  const resolver = PositionResolver();

  test('floating entries fill slots in arrival order', () {
    final r = resolver.resolve(
      entries: [entry('c', 3), entry('a', 1), entry('b', 2)],
      capacity: 5,
    );
    expect(r.positionOf('a'), 1);
    expect(r.positionOf('b'), 2);
    expect(r.positionOf('c'), 3);
    expect(r.emptySlots, [4, 5]);
  });

  test('a pinned entry keeps its slot and others flow around it', () {
    final r = resolver.resolve(
      entries: [
        entry('a', 1),
        entry('b', 2, status: QueueEntryStatus.pinned, pin: 2),
        entry('c', 3),
      ],
      capacity: 5,
    );
    expect(r.positionOf('a'), 1);
    expect(r.positionOf('b'), 2);
    expect(r.forAttendee('b')!.pinHonoured, isTrue);
    expect(r.positionOf('c'), 3);
  });

  test('when two people pin the same slot the earlier arrival wins', () {
    final r = resolver.resolve(
      entries: [
        entry('a', 1, status: QueueEntryStatus.pinned, pin: 2),
        entry('b', 2, status: QueueEntryStatus.pinned, pin: 2),
      ],
      capacity: 5,
    );
    expect(r.positionOf('a'), 2);
    expect(r.positionOf('b'), 1);
    expect(r.forAttendee('b')!.demotedFromPin, isTrue);
  });

  test('a host override beats an attendee pin', () {
    final r = resolver.resolve(
      entries: [
        entry('a', 1, status: QueueEntryStatus.pinned, pin: 1),
        entry('b', 2, manual: 1),
      ],
      capacity: 5,
    );
    expect(r.positionOf('b'), 1);
    expect(r.positionOf('a'), 2);
  });

  test('people beyond capacity go to overflow', () {
    final r = resolver.resolve(
      entries: [entry('a', 1), entry('b', 2), entry('c', 3)],
      capacity: 2,
    );
    expect(r.filledSlots, 2);
    expect(r.freeSlots, 0);
    expect(r.overflow.length, 1);
    expect(r.positionOf('c'), 3);
    expect(r.forAttendee('c')!.isOverflow, isTrue);
  });

  test('withdrawn and finished entries take no place', () {
    final r = resolver.resolve(
      entries: [
        entry('a', 1, status: QueueEntryStatus.withdrawn),
        entry('b', 2, status: QueueEntryStatus.finished),
        entry('c', 3),
      ],
      capacity: 5,
    );
    expect(r.positionOf('a'), isNull);
    expect(r.positionOf('b'), isNull);
    expect(r.positionOf('c'), 1);
  });
}
