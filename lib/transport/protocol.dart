import '../domain/proximity.dart';
import '../identity/identity.dart';
import '../logic/claim_result.dart';
import '../logic/position_resolver.dart';

/// The Bluetooth ids we use. The host advertises [serviceUuid] and attendees
/// scan for it.
class BleIds {
  // Randomly generated, as custom Bluetooth services have to be. They also
  // have to be valid hex — Android parses them strictly, so a "readable"
  // UUID with letters like q or u in it crashes on startup.
  static const String serviceUuid = '8af39807-dab8-49da-815c-081153d5895e';
  static const String sessionInfoChar = 'dab963c7-3500-4d83-ad7e-6ed1e7665f42';
  static const String claimRxChar = '27c2ff8b-54b0-4b2d-b7eb-5fb0032170ae';
  static const String snapshotTxChar = '7f577651-3489-4d0a-8c18-e3d285fbc79a';
  static const String heartbeatRxChar = 'd94af91a-41f3-45da-8ea6-a65d53a70b43';

  /// The id we put on the extra advertising data that carries the session
  /// title. Apple hosts can't send this at all.
  static const int manufacturerId = 0xFFFF;

  /// A Bluetooth advert is only 31 bytes, and the flags plus our service id
  /// use up all but about 10 of them. That's why the advertised name is
  /// capped at 8 characters, and why the session title travels in a second
  /// packet (the scan response) which gets its own 31 bytes. The title and
  /// host name share what's left there, so both are cut short — the full
  /// versions arrive once you connect.
  static const int advertPayloadVersion = 2;

  /// The advertised name includes a version number, so an attendee can tell
  /// whether anything has changed without connecting.
  ///
  /// It goes in the name rather than the extra data because Apple throws the
  /// extra data away, and a Mac host would then advertise no version at all.
  /// Android only allows 8 characters here, so the number is written in
  /// base 36 — 6 characters covers over two billion changes.
  static String advertisedName(int stateVersion) =>
      '$advertisedNamePrefix${stateVersion.toRadixString(36)}';

  /// Reads the version back out of the name, or null if it isn't one of
  /// ours.
  static int? stateVersionFrom(String? advertisedName) {
    if (advertisedName == null ||
        !advertisedName.startsWith(advertisedNamePrefix)) {
      return null;
    }
    return int.tryParse(
        advertisedName.substring(advertisedNamePrefix.length),
        radix: 36);
  }
  static const int maxAdvertisedTitleBytes = 14;
  static const int maxAdvertisedHostBytes = 9;
  static const String advertisedNamePrefix = 'QQ';

  /// Android refuses a longer name when a service id is advertised as well,
  /// and advertising just fails.
  static const int maxAdvertisedNameChars = 8;
}

/// The things an attendee can ask to do.
enum ClaimKind { nextAvailable, specificSlot, pin, leave }

class ClaimRequest {
  const ClaimRequest({
    required this.queueId,
    required this.attendeeId,
    required this.kind,
    this.slot,
    this.clientRequestedAt,
  });

  final String queueId;
  final String attendeeId;
  final ClaimKind kind;

  /// Only used when asking for a specific slot.
  final int? slot;

  /// The time on the attendee's phone. Stored for reference only — phone
  /// clocks differ and can be faked, so we never order the queue by it.
  final int? clientRequestedAt;

  Map<String, Object?> toJson() => {
        'queueId': queueId,
        'attendeeId': attendeeId,
        'kind': kind.name,
        'slot': slot,
        'clientRequestedAt': clientRequestedAt,
      };

  static ClaimRequest fromJson(Map<String, Object?> j) => ClaimRequest(
        queueId: j['queueId']! as String,
        attendeeId: j['attendeeId']! as String,
        kind: ClaimKind.values.firstWhere((e) => e.name == j['kind']! as String),
        slot: j['slot'] as int?,
        clientRequestedAt: j['clientRequestedAt'] as int?,
      );
}

/// An attendee's check-in, with the signal strength they measured.
class Heartbeat {
  const Heartbeat({
    required this.attendeeId,
    required this.rssi,
    required this.rssiEma,
    required this.proximity,
    required this.sentAt,
  });

  final String attendeeId;
  final int rssi;
  final double rssiEma;
  final ProximityState proximity;
  final int sentAt;

  Map<String, Object?> toJson() => {
        'attendeeId': attendeeId,
        'rssi': rssi,
        'rssiEma': rssiEma,
        'proximity': proximity.name,
        'sentAt': sentAt,
      };

  static Heartbeat fromJson(Map<String, Object?> j) => Heartbeat(
        attendeeId: j['attendeeId']! as String,
        rssi: j['rssi']! as int,
        rssiEma: (j['rssiEma']! as num).toDouble(),
        proximity: ProximityState.values
            .firstWhere((e) => e.name == j['proximity']! as String),
        sentAt: j['sentAt']! as int,
      );
}

/// One row of the queue as sent to attendees.
class SnapshotRow {
  const SnapshotRow({
    required this.attendeeId,
    required this.displayName,
    required this.position,
    required this.isOverflow,
    required this.pinned,
    required this.proximity,
  });

  final String attendeeId;
  final String displayName;
  final int position;
  final bool isOverflow;
  final bool pinned;
  final ProximityState proximity;

  /// Short key names on purpose: this goes over Bluetooth, and a 20-person
  /// queue with long names would need noticeably more packets.
  Map<String, Object?> toJson() => {
        'a': attendeeId,
        'n': displayName,
        'p': position,
        'o': isOverflow ? 1 : 0,
        'k': pinned ? 1 : 0,
        'x': proximity.index,
      };

  static SnapshotRow fromJson(Map<String, Object?> j) => SnapshotRow(
        attendeeId: j['a']! as String,
        displayName: j['n']! as String,
        position: j['p']! as int,
        isOverflow: (j['o']! as int) == 1,
        pinned: (j['k']! as int) == 1,
        proximity: ProximityState.values[j['x']! as int],
      );
}

/// The state of the queue, as the host sends it out after every change.
class QueueSnapshot {
  const QueueSnapshot({
    required this.queueId,
    required this.queueName,
    required this.capacity,
    required this.rows,
    required this.revision,
    required this.isOpen,
  });

  final String queueId;
  final String queueName;
  final int capacity;
  final List<SnapshotRow> rows;

  /// Goes up on every change, so an attendee can ignore an update that
  /// arrived out of order.
  final int revision;
  final bool isOpen;

  int get activeCount => rows.where((r) => !r.isOverflow).length;
  int get overflowCount => rows.where((r) => r.isOverflow).length;

  SnapshotRow? rowFor(String attendeeId) {
    for (final r in rows) {
      if (r.attendeeId == attendeeId) return r;
    }
    return null;
  }

  static QueueSnapshot fromResolution({
    required String queueId,
    required String queueName,
    required int revision,
    required bool isOpen,
    required QueueResolution resolution,
    required Map<String, String> names,
    Map<String, ProximityState> proximity = const {},
  }) =>
      QueueSnapshot(
        queueId: queueId,
        queueName: queueName,
        capacity: resolution.capacity,
        revision: revision,
        isOpen: isOpen,
        rows: [
          for (final r in resolution.all)
            SnapshotRow(
              attendeeId: r.attendeeId,
              displayName: names[r.attendeeId] ?? r.attendeeId,
              position: r.position,
              isOverflow: r.isOverflow,
              pinned: r.pinHonoured,
              proximity:
                  proximity[r.attendeeId] ?? ProximityState.inRange,
            ),
        ],
      );

  Map<String, Object?> toJson() => {
        'q': queueId,
        'nm': queueName,
        'c': capacity,
        'r': revision,
        'op': isOpen ? 1 : 0,
        'rows': [for (final r in rows) r.toJson()],
      };

  static QueueSnapshot fromJson(Map<String, Object?> j) => QueueSnapshot(
        queueId: j['q']! as String,
        queueName: j['nm']! as String,
        capacity: j['c']! as int,
        revision: j['r']! as int,
        isOpen: (j['op']! as int) == 1,
        rows: [
          for (final r in (j['rows']! as List))
            SnapshotRow.fromJson((r as Map).cast<String, Object?>()),
        ],
      );
}

/// One person in the session, whether or not they're in the queue.
class RosterRow {
  const RosterRow({
    required this.userId,
    required this.displayName,
    required this.kind,
    required this.proximity,
    required this.inQueue,
    this.hostLabelled = false,
    this.position,
  });

  final String userId;

  /// The host's correction is already applied, so every device shows the
  /// same name.
  final String displayName;

  final UserKind kind;
  final ProximityState proximity;
  final bool inQueue;

  /// True if the host typed a correction for this name.
  final bool hostLabelled;

  /// Their queue position, if they're in the queue.
  final int? position;

  Map<String, Object?> toJson() => {
        'u': userId,
        'n': displayName,
        'k': kind.index,
        'x': proximity.index,
        'q': inQueue ? 1 : 0,
        'h': hostLabelled ? 1 : 0,
        if (position != null) 'p': position,
      };

  static RosterRow fromJson(Map<String, Object?> j) => RosterRow(
        userId: j['u']! as String,
        displayName: j['n']! as String,
        kind: UserKind.values[j['k']! as int],
        proximity: ProximityState.values[j['x']! as int],
        inQueue: (j['q']! as int) == 1,
        hostLabelled: (j['h']! as int) == 1,
        position: j['p'] as int?,
      );
}

/// Everyone in the session, sent to the host's own screen and to attendees.
///
/// Kept separate from [QueueSnapshot] because a session doesn't have to have
/// a queue. Without this, a session with no queue would send attendees
/// nothing at all after they joined.
class RosterSnapshot {
  const RosterSnapshot({
    required this.sessionId,
    required this.title,
    required this.revision,
    required this.locked,
    required this.rows,
    this.hasQueue = false,
  });

  final String sessionId;
  final String title;

  /// Goes up on every change, so updates that arrive out of order get
  /// ignored.
  final int revision;

  final bool locked;
  final List<RosterRow> rows;

  /// Whether the host has opened a queue.
  final bool hasQueue;

  /// Everyone on the list, whether we can still reach them or not.
  int get presentCount => rows.length;

  int get queuedCount => rows.where((r) => r.inQueue).length;

  /// Still reachable: in range or weak signal, but not gone.
  ///
  /// This is the number that answers "how many people are actually here". It
  /// isn't [presentCount] on purpose — someone out of range stays on the list,
  /// because removing them is the host's call, but counting them as present
  /// would make an empty room look full.
  int get hereCount =>
      rows.where((r) => r.proximity != ProximityState.lost).length;

  /// Weak signal: still here, but might drop out.
  int get weakCount =>
      rows.where((r) => r.proximity == ProximityState.warning).length;

  /// Out of range. Still on the list, but not counted as here.
  int get goneCount =>
      rows.where((r) => r.proximity == ProximityState.lost).length;

  int get fadingCount =>
      rows.where((r) => r.proximity != ProximityState.inRange).length;

  RosterRow? rowFor(String userId) {
    for (final r in rows) {
      if (r.userId == userId) return r;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        's': sessionId,
        't': title,
        'r': revision,
        'l': locked ? 1 : 0,
        'hq': hasQueue ? 1 : 0,
        'rows': [for (final r in rows) r.toJson()],
      };

  static RosterSnapshot fromJson(Map<String, Object?> j) => RosterSnapshot(
        sessionId: j['s']! as String,
        title: j['t']! as String,
        revision: j['r']! as int,
        locked: (j['l']! as int) == 1,
        hasQueue: (j['hq'] as int?) == 1,
        rows: [
          for (final r in (j['rows']! as List))
            RosterRow.fromJson((r as Map).cast<String, Object?>()),
        ],
      );
}

/// A session we found while scanning, before connecting.
class DiscoveredSession {
  const DiscoveredSession({
    required this.deviceId,
    required this.title,
    required this.rssi,
    required this.locked,
    required this.attendeeCount,
    this.stateVersion = 0,
    this.hostName = '',
    this.detailsKnown = true,
  });

  final String deviceId;

  /// Cut short to fit in the advert. The full title arrives when you join.
  final String title;

  /// Who's hosting, also cut short. Empty if the host couldn't advertise it,
  /// which is always the case on a Mac or iPhone.
  final String hostName;

  /// False if all we got was the service id, so the screen can say the
  /// details come on connecting rather than making up a name.
  final bool detailsKnown;

  final int rssi;
  final bool locked;
  final int attendeeCount;

  /// The version number from the advertised name. Attendees only reconnect
  /// when it changes, so a session where nothing is happening costs nothing.
  final int stateVersion;

  /// A rough idea of how close it is, for the list. Signal strength is noisy,
  /// so we show three bands rather than a number pretending to be metres.
  ProximityState get nearness => rssi >= -70
      ? ProximityState.inRange
      : rssi >= -85
          ? ProximityState.warning
          : ProximityState.lost;
}

/// The host's answer to a queue request.
class ClaimResponse {
  const ClaimResponse({required this.requestId, required this.result});

  final String requestId;
  final ClaimResult result;

  Map<String, Object?> toJson() =>
      {'req': requestId, 'res': result.toJson()};

  static ClaimResponse fromJson(Map<String, Object?> j) => ClaimResponse(
        requestId: j['req']! as String,
        result:
            ClaimResult.fromJson((j['res']! as Map).cast<String, Object?>()),
      );
}
