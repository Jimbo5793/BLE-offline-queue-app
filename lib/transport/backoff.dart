import 'dart:math';

/// How long to wait before retrying when the host is busy.
///
/// The host can only handle about eight connections at once, so being refused
/// is normal. The random element matters: without it, two phones that clash
/// once would keep clashing on every retry.
///
/// The random number generator can be passed in so the timings can be
/// tested.
class Backoff {
  const Backoff({
    this.min = const Duration(milliseconds: 200),
    this.max = const Duration(milliseconds: 1500),
    this.maxAttempts = 5,
  });

  final Duration min;
  final Duration max;

  /// Counts the first try, so 5 means one attempt and four retries.
  final int maxAttempts;

  static const Backoff defaults = Backoff();

  /// How long to wait before attempt number [attempt].
  ///
  /// Roughly doubles each time up to [max], then stays there. The wait is
  /// picked randomly from the whole range rather than being a fixed delay with
  /// a bit of noise added, which spreads a crowd out much better.
  Duration delayFor(int attempt, [Random? rng]) {
    if (attempt <= 1) return Duration.zero;
    final r = rng ?? Random();

    final ceiling = min.inMilliseconds * (1 << (attempt - 2));
    final capped = ceiling.clamp(min.inMilliseconds, max.inMilliseconds);
    final span = capped - min.inMilliseconds;

    return Duration(
      milliseconds:
          min.inMilliseconds + (span <= 0 ? 0 : r.nextInt(span + 1)),
    );
  }

  bool shouldRetry(int attempt) => attempt < maxAttempts;

  /// Runs [action], retrying if it fails or returns null.
  ///
  /// Gives up and returns null after the last attempt, so the caller can
  /// report a failure instead of waiting forever.
  Future<T?> run<T>(
    Future<T?> Function(int attempt) action, {
    Random? rng,
    Future<void> Function(Duration)? sleep,
  }) async {
    final wait = sleep ?? (d) => Future<void>.delayed(d);
    Object? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) await wait(delayFor(attempt, rng));
      try {
        final result = await action(attempt);
        if (result != null) return result;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) {
      // Kept so the caller can say what actually went wrong, instead of
      // reporting a timeout for what was really a refusal.
      lastFailure = lastError;
    }
    return null;
  }

  static Object? lastFailure;
}
