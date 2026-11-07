/// A timer the host runs on one person in the queue.
///
/// No Flutter, no sound and no timer of its own. It just says which warnings
/// are due and lets the caller make the noise, so it can be tested without a
/// device.
library;

enum TimerDirection {
  /// Measure how long someone takes.
  countUp,

  /// Count down from a fixed length.
  countDown,
}

/// A point to warn at, and how loudly.
class TimerWarning {
  const TimerWarning({required this.at, this.pings = 1});

  /// Time since the start, so it means the same counting up or down. On an
  /// eight-minute countdown, 7:00 is one minute before the end.
  final Duration at;

  /// Number of beeps: one as a nudge, two for "time to wrap up".
  final int pings;

  @override
  bool operator ==(Object other) =>
      other is TimerWarning && other.at == at && other.pings == pings;

  @override
  int get hashCode => Object.hash(at, pings);
}

enum TimerState { ready, running, paused, finished }

/// One person's timer.
///
/// Uses [Stopwatch] rather than doing maths on the clock. Pause and resume
/// then work properly, and it won't drift if the system clock changes.
class EntryTimer {
  EntryTimer({
    required this.entryId,
    required this.direction,
    this.total,
    List<TimerWarning>? warnings,
  })  : assert(direction == TimerDirection.countUp || total != null,
            'a countdown needs a length'),
        warnings = [...?warnings]..sort((a, b) => a.at.compareTo(b.at));

  /// The queue entry this timer is for.
  final String entryId;

  final TimerDirection direction;

  /// How long the countdown is. Null when counting up.
  final Duration? total;

  /// Sorted by time so they go off in order.
  final List<TimerWarning> warnings;

  final _stopwatch = Stopwatch();
  final _fired = <TimerWarning>{};
  bool _stopped = false;

  /// Default warnings for a countdown: one a minute before the end, one just
  /// before. Short timers only get one, so they aren't on top of each other.
  static List<TimerWarning> defaultWarningsFor(Duration total) {
    if (total < const Duration(minutes: 1)) {
      return [
        TimerWarning(at: total - const Duration(seconds: 10), pings: 2),
      ].where((w) => w.at > Duration.zero).toList();
    }
    return [
      TimerWarning(at: total - const Duration(minutes: 1)),
      TimerWarning(at: total - const Duration(seconds: 10), pings: 2),
    ].where((w) => w.at > Duration.zero).toList();
  }

  Duration get elapsed => _stopwatch.elapsed;

  /// Time left on a countdown, never below zero. Null when counting up.
  Duration? get remaining => total == null
      ? null
      : (total! - elapsed).isNegative
          ? Duration.zero
          : total! - elapsed;

  /// What the host sees: time taken when counting up, time left when counting
  /// down.
  Duration get display =>
      direction == TimerDirection.countUp ? elapsed : remaining!;

  bool get isRunning => _stopwatch.isRunning;
  bool get hasStarted => elapsed > Duration.zero || _stopwatch.isRunning;

  /// True when a countdown has run out. Counting up never ends by itself.
  bool get hasExpired =>
      direction == TimerDirection.countDown && elapsed >= total!;

  TimerState get state {
    if (_stopped || hasExpired) return TimerState.finished;
    if (_stopwatch.isRunning) return TimerState.running;
    return hasStarted ? TimerState.paused : TimerState.ready;
  }

  /// How far through, for a progress bar. Null when counting up, since there
  /// is no total.
  double? get progress => total == null
      ? null
      : (elapsed.inMilliseconds / total!.inMilliseconds).clamp(0.0, 1.0);

  void start() {
    if (_stopped) return;
    _stopwatch.start();
  }

  void pause() => _stopwatch.stop();

  void resume() {
    if (!_stopped && !hasExpired) _stopwatch.start();
  }

  /// Stops for good but keeps [elapsed], so it can go in the export.
  void stop() {
    _stopwatch.stop();
    _stopped = true;
  }

  /// Warnings that have become due since the last call.
  ///
  /// Each one is only returned once. The caller checks this on a timer, so
  /// returning the same warning twice would beep twice for one moment.
  List<TimerWarning> takeDueWarnings() {
    if (_stopped) return const [];
    final now = elapsed;
    final due = <TimerWarning>[];
    for (final w in warnings) {
      if (w.at <= now && !_fired.contains(w)) {
        _fired.add(w);
        due.add(w);
      }
    }
    return due;
  }

  /// Warnings still to come, so the host can see what's ahead.
  List<TimerWarning> get pending =>
      warnings.where((w) => !_fired.contains(w)).toList();

  bool hasFired(TimerWarning w) => _fired.contains(w);

  /// The time to save against the queue entry when they're done.
  int get resultMs => elapsed.inMilliseconds;
}
