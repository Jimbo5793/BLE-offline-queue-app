import '../domain/queue.dart';

enum ClaimFailure {
  queueClosed,
  sessionEnded,
  alreadyQueued,
  notQueued,
  slotTaken,
  slotOutOfRange,
  noSuchQueue,
}

/// The result of a queue change. Can be turned into JSON because we both
/// save it (to handle repeat requests) and send it back over Bluetooth.
class ClaimResult {
  const ClaimResult({
    required this.ok,
    this.failure,
    this.entry,
    this.position,
    this.isOverflow = false,
    this.replayed = false,
  });

  factory ClaimResult.success({
    required QueueEntry entry,
    required int position,
    required bool isOverflow,
  }) =>
      ClaimResult(
          ok: true, entry: entry, position: position, isOverflow: isOverflow);

  factory ClaimResult.failed(ClaimFailure failure) =>
      ClaimResult(ok: false, failure: failure);

  final bool ok;
  final ClaimFailure? failure;
  final QueueEntry? entry;

  /// Their position, starting at 1. Past the capacity means overflow.
  final int? position;
  final bool isOverflow;

  /// True if this is a saved answer to a request we'd already handled.
  final bool replayed;

  ClaimResult asReplay() => ClaimResult(
        ok: ok,
        failure: failure,
        entry: entry,
        position: position,
        isOverflow: isOverflow,
        replayed: true,
      );

  Map<String, Object?> toJson() => {
        'ok': ok,
        'failure': failure?.name,
        'entry': entry?.toMap(),
        'position': position,
        'isOverflow': isOverflow,
      };

  static ClaimResult fromJson(Map<String, Object?> j) => ClaimResult(
        ok: j['ok']! as bool,
        failure: j['failure'] == null
            ? null
            : ClaimFailure.values
                .firstWhere((e) => e.name == j['failure']! as String),
        entry: j['entry'] == null
            ? null
            : QueueEntry.fromMap((j['entry']! as Map).cast<String, Object?>()),
        position: j['position'] as int?,
        isOverflow: (j['isOverflow'] as bool?) ?? false,
      );

  @override
  String toString() => ok
      ? 'ClaimResult(ok, pos=$position, overflow=$isOverflow${replayed ? ', replayed' : ''})'
      : 'ClaimResult(failed: ${failure?.name})';
}
