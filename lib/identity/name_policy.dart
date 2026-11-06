/// When someone is allowed to change their display name.
///
/// No clock and no storage in here — the time is passed in. Both the
/// attendee's screen and the host's checks use this same code, so they can't
/// disagree.
///
/// Note the lock isn't what stops impersonation; the key pair does that, since
/// pretending to be someone else needs their private key. The lock only stops
/// a name changing after the fact, so a short window is enough.
library;

class NamePolicy {
  const NamePolicy({
    this.grace = const Duration(minutes: 15),
    this.lock = const Duration(days: 7),
  });

  /// Just after making an account the name can still be changed, so a typo
  /// spotted straight away isn't stuck.
  final Duration grace;

  /// Once the grace period is over, the name is fixed for this long.
  final Duration lock;

  static const NamePolicy defaults = NamePolicy();

  /// [anchorMs] is when the identity started: account creation on the
  /// attendee's phone, or the first time the host saw that key. It's not the
  /// last rename on purpose — otherwise you could rename every 14 minutes
  /// forever.
  bool canRename({
    required int anchorMs,
    required int nameSetAtMs,
    required int nowMs,
  }) =>
      nowMs < anchorMs + grace.inMilliseconds ||
      nowMs >= nameSetAtMs + lock.inMilliseconds;

  bool inGrace({required int anchorMs, required int nowMs}) =>
      nowMs < anchorMs + grace.inMilliseconds;

  /// When the name unlocks, or null if it can be changed now.
  DateTime? unlocksAt({
    required int anchorMs,
    required int nameSetAtMs,
    required int nowMs,
  }) =>
      canRename(anchorMs: anchorMs, nameSetAtMs: nameSetAtMs, nowMs: nowMs)
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              nameSetAtMs + lock.inMilliseconds);

  /// Time left in the grace period, or null once it's over.
  Duration? graceRemaining({required int anchorMs, required int nowMs}) {
    final endsAt = anchorMs + grace.inMilliseconds;
    return nowMs < endsAt
        ? Duration(milliseconds: endsAt - nowMs)
        : null;
  }
}

/// Rejects names that would be no use to a host trying to identify someone.
class NameValidator {
  static const int minLength = 2;
  static const int maxLength = 40;

  /// Returns null if the name is fine, otherwise the reason it isn't.
  static String? validate(String raw) {
    final name = raw.trim();
    if (name.length < minLength) return 'Enter at least $minLength characters.';
    if (name.length > maxLength) return 'Keep it under $maxLength characters.';
    if (!RegExp(r'[A-Za-z]').hasMatch(name)) {
      return 'Your name needs at least one letter.';
    }
    return null;
  }

  /// Squashes repeated spaces, so "Ana   Smith" and "Ana Smith" match.
  static String normalise(String raw) =>
      raw.trim().replaceAll(RegExp(r'\s+'), ' ');
}
