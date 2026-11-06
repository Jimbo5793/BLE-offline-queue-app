import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the app running in the background while a session is open.
///
/// Presence depends on the attendee's phone sending a check-in on a timer, and
/// a backgrounded Android app can't reliably do that. Android's battery saving
/// delays timers by minutes at a time, and without a background service it can
/// kill the app outright. Check-ins stop, the host marks them absent after a
/// couple of minutes, and an attendance check would fail a room full of phones
/// sitting in pockets.
///
/// A foreground service is the only proper fix for this. Android only — macOS
/// doesn't suspend apps, so everything here does nothing on other platforms.
class SessionForegroundService {
  const SessionForegroundService._();

  /// What's currently keeping the service running. You can host and attend at
  /// the same time, so the service only stops when the last one is done.
  static final Map<String, String> _held = {};

  static bool _initialised = false;

  static bool get _supported => Platform.isAndroid;

  /// Starts the service, or updates its notification if it's already going.
  ///
  /// [role] is the caller's own name — pass the same one to [release].
  /// [detail] is the session name, so the notification says something useful.
  static Future<void> hold(String role, String detail) async {
    _held[role] = detail;
    if (!_supported) return;
    _init();
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: _title,
          notificationText: _text,
        );
      } else {
        await FlutterForegroundTask.startService(
          serviceTypes: const [ForegroundServiceTypes.connectedDevice],
          notificationTitle: _title,
          notificationText: _text,
        );
      }
    } on MissingPluginException {
      // A platform this package doesn't support. The session still works.
    } on PlatformException {
      // Same idea: without this the app just sleeps sooner, which is worse
      // but not broken, so it must not stop the session starting.
    }
  }

  /// Releases [role]. Stops the service once nothing else needs it.
  static Future<void> release(String role) async {
    _held.remove(role);
    if (!_supported) return;
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      if (_held.isEmpty) {
        await FlutterForegroundTask.stopService();
      } else {
        await FlutterForegroundTask.updateService(
          notificationTitle: _title,
          notificationText: _text,
        );
      }
    } on MissingPluginException {
      // Nothing to stop.
    } on PlatformException {
      // Nothing to stop.
    }
  }

  static String get _title =>
      _held.length > 1 ? 'Queue is running' : 'Queue — ${_held.keys.first}';

  static String get _text => _held.values.join(' · ');

  /// Starting the service fails if this hasn't run. It's cheap and safe to
  /// call twice, so we do it on first use rather than in `main`.
  static void _init() {
    if (_initialised) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'queue_session',
        channelName: 'Running session',
        channelDescription:
            'Shown while a session is open so check-ins keep working with the '
            'screen locked.',
        // Android requires a notification for this kind of service, but it
        // isn't a message for the user, so it must never make a sound or
        // vibrate during a lecture.
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // We don't run any code in the service itself. The timers we care
        // about already run in the app, and running a second copy would mean
        // two versions of the session state that could disagree. All we need
        // is for the app to stay alive and awake.
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        // Swiping the app away closes the session, so the service should
        // stop too rather than restart with nothing to do.
        stopWithTask: true,
        allowAutoRestart: false,
      ),
    );
    _initialised = true;
  }
}
