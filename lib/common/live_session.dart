import 'package:flutter/foundation.dart';

import '../attendee/attendee_session_service.dart';
import '../data/database.dart';
import '../host/host_session_service.dart';
import '../transport/ble_host_transport.dart';
import 'session_service_controller.dart';

/// Keeps track of what's running, so the home screen can offer to go back to
/// it.
///
/// Screens used to stack on top of each other, so backing out of a live
/// session landed on the form that created it. Now the live screen replaces
/// the form, and this holds the running session so home can show a Resume
/// button instead of the session becoming unreachable.
class LiveSession extends ChangeNotifier {
  LiveSession._();

  static final LiveSession instance = LiveSession._();

  HostSessionService? _host;
  BleHostTransport? _hostTransport;
  AppDatabase? _hostDb;
  AttendeeSessionService? _attendee;

  HostSessionService? get host => _host;
  BleHostTransport? get hostTransport => _hostTransport;
  AttendeeSessionService? get attendee => _attendee;

  bool get isHosting => _host?.session?.isOpen ?? false;
  bool get isAttending => _attendee?.joinState == JoinState.joined;
  bool get anyLive => isHosting || isAttending;

  String? get hostSessionTitle => _host?.session?.title;
  String? get attendeeSessionTitle => _attendee?.sessionTitle;

  void startHosting({
    required HostSessionService service,
    required BleHostTransport transport,
    required AppDatabase db,
  }) {
    _host = service;
    _hostTransport = transport;
    _hostDb = db;
    SessionForegroundService.hold('hosting', service.session?.title ?? 'Session');
    notifyListeners();
  }

  /// Ends the session and closes the Bluetooth connection and database.
  Future<void> stopHosting({bool endSession = true}) async {
    final service = _host;
    if (service == null) return;
    if (endSession) await service.endSession();
    await service.stop();
    await _hostDb?.close();
    _host = null;
    _hostTransport = null;
    _hostDb = null;
    await SessionForegroundService.release('hosting');
    notifyListeners();
  }

  void startAttending(AttendeeSessionService service) {
    _attendee = service;
    SessionForegroundService.hold('in a session', service.sessionTitle ?? 'Session');
    notifyListeners();
  }

  /// Leaves the session and says whether the host was actually told.
  ///
  /// The screen needs to know. If the message didn't get through, the person
  /// has still left, but the host will keep showing them for a couple of
  /// minutes until their check-ins time out — better to say so than let them
  /// assume the host knows.
  Future<bool> leaveAttending() async {
    final told = await _attendee?.leaveSession() ?? false;
    await stopAttending(notifyHost: false);
    return told;
  }

  /// Leaves the session, telling the host first.
  ///
  /// [notifyHost] is only false when there's nobody left to tell. Skipping it
  /// means the host waits for three missed check-ins before noticing, and an
  /// attendance check in the meantime would still count them as present.
  Future<void> stopAttending({bool notifyHost = true}) async {
    final service = _attendee;
    if (service == null) return;
    if (notifyHost) await service.leaveSession();
    await service.stop();
    _attendee = null;
    await SessionForegroundService.release('in a session');
    notifyListeners();
  }
}
