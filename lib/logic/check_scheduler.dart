import 'dart:math';

/// Decides when attendance checks happen.
///
/// The random number generator can be passed in, so tests can check that two
/// checks are never less than ten minutes apart.
class CheckScheduler {
  const CheckScheduler({
    this.minGap = const Duration(minutes: 10),
    this.leadIn = const Duration(minutes: 5),
    this.tailOff = const Duration(minutes: 5),
    this.fallbackMin = const Duration(minutes: 10),
    this.fallbackMax = const Duration(minutes: 25),
  });

  /// Minimum gap between two checks.
  final Duration minGap;

  /// Quiet time at the start, so a check can't happen before people have
  /// arrived and connected.
  final Duration leadIn;

  /// Quiet time at the end, so the last check isn't taken while everyone is
  /// packing up.
  final Duration tailOff;

  /// Range for the repeating gap when the host didn't set a length.
  final Duration fallbackMin;
  final Duration fallbackMax;

  static const CheckScheduler defaults = CheckScheduler();

  /// How many checks fit in [length] with the gaps respected.
  int maxChecksFor(Duration length) {
    final usable = length - leadIn - tailOff;
    if (usable.isNegative || usable == Duration.zero) return 0;
    return usable.inMilliseconds ~/ minGap.inMilliseconds + 1;
  }

  /// Random times measured from the start of the session, in order, at least
  /// [minGap] apart.
  ///
  /// Returns fewer than [count] if the session is too short, rather than
  /// squeezing them in.
  ///
  /// How it works: pick [count] random points in a shorter window, then push
  /// the i-th one out by i * minGap. This spreads them evenly. Just picking
  /// random points and rejecting bad sets would bunch them at the ends.
  List<Duration> plan({
    required Duration length,
    required int count,
    Random? rng,
  }) {
    if (count <= 0) return const [];
    final fit = min(count, maxChecksFor(length));
    if (fit <= 0) return const [];

    final r = rng ?? Random();
    final usableMs = (length - leadIn - tailOff).inMilliseconds;
    final freeMs = usableMs - (fit - 1) * minGap.inMilliseconds;

    final picks = [for (var i = 0; i < fit; i++) r.nextInt(freeMs + 1)]..sort();

    return [
      for (var i = 0; i < fit; i++)
        Duration(
          milliseconds: leadIn.inMilliseconds +
              picks[i] +
              i * minGap.inMilliseconds,
        ),
    ];
  }

  /// How long to wait for the next check when there's no session length.
  Duration nextGap([Random? rng]) {
    final r = rng ?? Random();
    final spread =
        fallbackMax.inMilliseconds - fallbackMin.inMilliseconds;
    return Duration(
      milliseconds: fallbackMin.inMilliseconds +
          (spread <= 0 ? 0 : r.nextInt(spread + 1)),
    );
  }
}
