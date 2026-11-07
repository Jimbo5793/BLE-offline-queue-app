import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// The noises a timer makes.
///
/// One ping for a first warning, two for a second, with a vibration alongside
/// so it still lands when the phone is silenced or face down on a desk — which
/// is exactly where a host's phone tends to be.
class Alerts {
  Alerts._();

  static final Alerts instance = Alerts._();

  final _player = AudioPlayer();

  /// Lets the host silence the pings without abandoning the timer.
  bool muted = false;

  static const _gapBetweenPings = Duration(milliseconds: 260);

  /// Plays [count] pings in sequence.
  ///
  /// Failures are swallowed deliberately: a missing audio route or a device
  /// that refuses to play must not take down a running timer, and the
  /// vibration still gets through.
  Future<void> ping({int count = 1}) async {
    await _vibrate(count);
    if (muted) return;

    for (var i = 0; i < count; i++) {
      if (i > 0) await Future<void>.delayed(_gapBetweenPings);
      try {
        await _player.stop();
        await _player.play(AssetSource('sounds/ping.wav'));
      } catch (_) {
        // No audio route, or the platform declined. Nothing to do about it.
      }
    }
  }

  Future<void> _vibrate(int count) async {
    try {
      for (var i = 0; i < count; i++) {
        if (i > 0) await Future<void>.delayed(_gapBetweenPings);
        await HapticFeedback.mediumImpact();
      }
    } catch (_) {
      // Desktops have no vibration motor; that is not an error.
    }
  }

  /// A softer tick for the end of a countdown, distinct from a warning.
  Future<void> finished() => ping(count: 2);

  Future<void> dispose() => _player.dispose();
}
