import '../domain/proximity.dart';

/// What the host knows about one attendee's presence.
class PresenceSample {
  const PresenceSample({
    required this.attendeeId,
    this.state = ProximityState.inRange,
    this.rssiEma,
    this.lastRssi,
    this.missedBeats = 0,
    this.goodStreak = 0,
    this.badStreak = 0,
    this.lastHeartbeatMs,
    this.linkConnected = true,
  });

  final String attendeeId;
  final ProximityState state;
  final double? rssiEma;
  final int? lastRssi;
  final int missedBeats;

  /// How many good readings in a row.
  final int goodStreak;

  /// How many bad readings in a row.
  final int badStreak;

  final int? lastHeartbeatMs;
  final bool linkConnected;

  PresenceSample copyWith({
    ProximityState? state,
    double? rssiEma,
    int? lastRssi,
    int? missedBeats,
    int? goodStreak,
    int? badStreak,
    int? lastHeartbeatMs,
    bool? linkConnected,
  }) =>
      PresenceSample(
        attendeeId: attendeeId,
        state: state ?? this.state,
        rssiEma: rssiEma ?? this.rssiEma,
        lastRssi: lastRssi ?? this.lastRssi,
        missedBeats: missedBeats ?? this.missedBeats,
        goodStreak: goodStreak ?? this.goodStreak,
        badStreak: badStreak ?? this.badStreak,
        lastHeartbeatMs: lastHeartbeatMs ?? this.lastHeartbeatMs,
        linkConnected: linkConnected ?? this.linkConnected,
      );

  bool get isFading => state != ProximityState.inRange;
}

/// What came out of processing one reading.
class ProximityEvaluation {
  const ProximityEvaluation({
    required this.sample,
    required this.changed,
    required this.trigger,
    this.previous,
  });

  final PresenceSample sample;

  /// True if the state actually changed. Only then do we bother telling
  /// anyone.
  final bool changed;

  final String trigger;
  final ProximityState? previous;
}

/// Decides when someone is dropping out of range.
///
/// No Bluetooth code in here and the time is passed in, so it can be tested
/// on its own. Two things feed it, because neither is enough by itself:
///
///  * the signal strength attendees report, since the host can't measure it
///  * missed check-ins, because someone who just walks off stops sending
///    anything at all
///
/// Going down and coming back up use different signal levels. Without that
/// gap, a phone sitting right on the edge would flip back and forth every
/// few seconds.
class ProximityMonitor {
  ProximityMonitor({
    ProximityThresholds? thresholds,
    this.recoverDbm = -69,
  }) : thresholds = thresholds ?? ProximityThresholds.defaults;

  final ProximityThresholds thresholds;

  /// Needs to be well above [ProximityThresholds.warningDbm]. The gap
  /// between them is what stops the state flickering.
  final int recoverDbm;

  /// A check-in arrived with a new signal reading.
  ProximityEvaluation onHeartbeat({
    required PresenceSample previous,
    required int rssi,
    required int nowMs,
  }) {
    // If they were marked lost we weren't measuring them, so the old average
    // describes a connection that no longer exists. Averaging the first new
    // reading against it would keep them out of range for no reason, so start
    // fresh instead.
    final ema = previous.rssiEma == null ||
            previous.state == ProximityState.lost
        ? rssi.toDouble()
        : previous.rssiEma! * (1 - thresholds.emaAlpha) +
            rssi * thresholds.emaAlpha;

    final bad = ema <= thresholds.warningDbm;
    final good = ema >= recoverDbm;
    final badStreak = bad ? previous.badStreak + 1 : 0;
    final goodStreak = good ? previous.goodStreak + 1 : 0;

    var next = previous.state;
    var trigger = 'heartbeat';

    if (ema <= thresholds.lostDbm &&
        badStreak >= thresholds.consecutiveSamples) {
      next = ProximityState.lost;
      trigger = 'rssiLost';
    } else if (bad && badStreak >= thresholds.consecutiveSamples) {
      next = ProximityState.warning;
      trigger = 'rssiLow';
    } else if (good && goodStreak >= thresholds.recoverSamples) {
      // Straight back to in range, even from lost.
      //
      // This used to go via warning first, which made sense when we read the
      // signal every two seconds. With check-ins every 30 seconds it meant
      // three minutes before the host saw someone walk back in. We already
      // have the proof: the check-in is signed and can only arrive from
      // inside Bluetooth range.
      next = ProximityState.inRange;
      trigger = 'rssiRecovered';
    }

    return _evaluate(
      previous,
      previous.copyWith(
        state: next,
        rssiEma: ema,
        lastRssi: rssi,
        missedBeats: 0,
        goodStreak: goodStreak,
        badStreak: badStreak,
        lastHeartbeatMs: nowMs,
      ),
      trigger,
    );
  }

  /// The host's regular check: has this person gone quiet?
  ///
  /// The elapsed time must come from a stopwatch, not the clock. If the system
  /// clock jumped, using it would mark everyone lost at once.
  ProximityEvaluation onSweep({
    required PresenceSample previous,
    required int elapsedSinceLastBeatMs,
  }) {
    // Measured against how often they should check in, not how often we
    // look.
    final missed = elapsedSinceLastBeatMs ~/
        thresholds.heartbeatInterval.inMilliseconds;

    var next = previous.state;
    var trigger = 'quiet';
    if (missed >= thresholds.missedBeatsForLost) {
      next = ProximityState.lost;
      trigger = 'heartbeatTimeout';
    } else if (missed >= thresholds.missedBeatsForWarning) {
      next = ProximityState.warning;
      trigger = 'heartbeatLate';
    }

    return _evaluate(
      previous,
      previous.copyWith(state: next, missedBeats: missed),
      trigger,
    );
  }

  /// The Bluetooth connection dropped or came back. This is the most reliable
  /// signal we have, so it beats anything based on signal strength.
  ProximityEvaluation onLinkChanged({
    required PresenceSample previous,
    required bool connected,
    required int nowMs,
  }) =>
      _evaluate(
        previous,
        previous.copyWith(
          state: connected ? ProximityState.warning : ProximityState.lost,
          linkConnected: connected,
          goodStreak: 0,
          badStreak: 0,
          lastHeartbeatMs: connected ? nowMs : previous.lastHeartbeatMs,
        ),
        connected ? 'reconnect' : 'disconnect',
      );

  ProximityEvaluation _evaluate(
    PresenceSample before,
    PresenceSample after,
    String trigger,
  ) =>
      ProximityEvaluation(
        sample: after,
        changed: before.state != after.state,
        previous: before.state,
        trigger: trigger,
      );
}
