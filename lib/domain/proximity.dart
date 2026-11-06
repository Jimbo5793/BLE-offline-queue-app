/// How we track whether someone is still in range.
///
/// The library we use for hosting cannot read signal strength at all, so the
/// host can't measure it. Instead each attendee reads their own signal and
/// sends it with their check-in. The host also watches for people who stop
/// checking in, so somebody who goes quiet is still noticed.
enum ProximityState {
  inRange,

  /// Weak signal, or late check-ins. Warn them and flag the row on the host.
  warning,

  /// Probably gone. We flag them, but never remove them automatically.
  lost,
}

class ProximityThresholds {
  const ProximityThresholds({
    this.warningDbm = -75,
    this.lostDbm = -88,
    this.consecutiveSamples = 3,
    this.recoverSamples = 1,
    this.sampleInterval = const Duration(seconds: 2),
    this.heartbeatInterval = const Duration(seconds: 30),
    this.heartbeatJitter = const Duration(seconds: 8),
    this.emaAlpha = 0.3,
    this.missedBeatsForWarning = 2,
    this.missedBeatsForLost = 3,
    this.linkGraceBeats = 1,
  });

  /// Signal at or below this means they're about to drop out.
  final int warningDbm;

  /// Signal at or below this counts as gone.
  final int lostDbm;

  /// How many bad readings in a row before we downgrade someone to warning
  /// or lost. Stops one bad reading from making the screen flicker, and means
  /// we're slow to call anyone absent. Going the other way uses
  /// [recoverSamples].
  final int consecutiveSamples;

  /// How many good readings it takes to count as back. Just one.
  ///
  /// This is on purpose different from [consecutiveSamples]. A check-in is
  /// signed and can only arrive if the phone is genuinely in Bluetooth range,
  /// so one is enough to prove someone is here. The gap between [warningDbm]
  /// and the recovery level already stops the state flickering.
  ///
  /// It used to need three, which was set when we read signal every two
  /// seconds. Check-ins are now every 30 seconds, so three meant three
  /// minutes before the host saw someone who had walked back in.
  final int recoverSamples;

  /// How often the host rechecks who is here. Cheap: it only reads memory.
  final Duration sampleInterval;

  /// How often an attendee checks in.
  ///
  /// Each check-in is a short connection, not traffic on a connection we hold
  /// open, so this can't be fast: thirty phones connecting every two seconds
  /// would swamp a host that can only handle about eight at once.
  ///
  /// Thirty seconds is what gives the two-minute worst case below. Rough
  /// maths: thirty people every thirty seconds is one connection a second,
  /// and each one takes about a second and a half, so around 1.5 of the 8
  /// slots are in use on average.
  final Duration heartbeatInterval;

  /// Random amount added or subtracted from [heartbeatInterval].
  ///
  /// Without it, phones that joined at the same time would check in at the
  /// same time forever and keep clashing.
  ///
  /// Kept to about a quarter of the interval. Any bigger and a phone that is
  /// simply a bit late would get flagged: 30s plus 8s is 38s at worst, well
  /// under the 60s warning limit.
  final Duration heartbeatJitter;

  /// Exponential moving average weight for the newest sample.
  final double emaAlpha;

  /// Counted in check-ins, not seconds, so changing the interval moves these
  /// with it.
  ///
  /// At 30 seconds per check-in:
  ///     1 min    warning   (2 missed)
  ///     1½ min   lost      (3 missed)
  ///     2 min    lost      (4 missed, worst case — see [linkGraceBeats])
  ///
  /// We keep a warning stage in the middle rather than jumping straight from
  /// present to gone, since that's what tells the host someone is about to
  /// drop out.
  final int missedBeatsForWarning;
  final int missedBeatsForLost;

  /// Extra time we allow someone who has stopped checking in but whose
  /// Bluetooth connection still looks open, counted in check-ins.
  ///
  /// It's small on purpose. On macOS there is no callback for a device
  /// disconnecting, so a phone that walks out of range or runs flat can look
  /// connected on the host forever. This used to skip the timeout completely,
  /// which meant those people stayed marked present and passed every
  /// attendance check.
  ///
  /// One extra check-in covers the real case — a phone whose timer the system
  /// briefly delayed. After that, no check-ins means gone.
  final int linkGraceBeats;

  /// Based on [heartbeatInterval], not how often we check: what matters is
  /// missed check-ins, not how often we look for them.
  Duration get warningTimeout => heartbeatInterval * missedBeatsForWarning;
  Duration get lostTimeout => heartbeatInterval * missedBeatsForLost;

  static const ProximityThresholds defaults = ProximityThresholds();
}
