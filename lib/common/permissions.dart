import 'dart:io';

import 'package:flutter/services.dart';

import 'package:permission_handler/permission_handler.dart';

/// Asks for Bluetooth permission, where the platform needs it.
///
/// The permissions package supports Android, iOS, web and Windows — but not
/// macOS, where calling it throws rather than returning a refusal.
///
/// macOS doesn't need it anyway: it shows its own prompt the first time the
/// app touches Bluetooth. So on a Mac we do nothing and let the system ask.
class BlePermissions {
  const BlePermissions._();

  /// Asks for what's needed to host a session.
  static Future<PermissionOutcome> forHosting() => _request(const [
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
      ]);

  /// Asks for what's needed to find and join a session.
  static Future<PermissionOutcome> forJoining() => _request(const [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ]);

  /// Asked for at the same time as Bluetooth, since it's only ever needed at
  /// the same moment.
  static const _optional = [Permission.notification];

  static Future<PermissionOutcome> _request(List<Permission> wanted) async {
    if (!_pluginSupportsThisPlatform) {
      return const PermissionOutcome.notRequired();
    }
    try {
      final results = await [...wanted, ..._optional].request();
      final denied = [
        for (final e in results.entries)
          // Refusing the notification must not stop a session. What keeps
          // check-ins running with the screen locked is the background
          // service; the notification is just how Android shows it, and the
          // service runs either way.
          if (!e.value.isGranted && !_optional.contains(e.key)) _label(e.key),
      ];
      return denied.isEmpty
          ? const PermissionOutcome.granted()
          : PermissionOutcome.denied(denied);
    } on MissingPluginException {
      // A platform the package doesn't support. Better to let the system ask
      // than to block on a permission we can't even request.
      return const PermissionOutcome.notRequired();
    }
  }

  static bool get _pluginSupportsThisPlatform => Platform.isAndroid || Platform.isIOS;

  static String _label(Permission p) =>
      p.toString().replaceFirst('Permission.', '');
}

class PermissionOutcome {
  const PermissionOutcome.granted()
      : denied = const [],
        required_ = true;
  const PermissionOutcome.notRequired()
      : denied = const [],
        required_ = false;
  const PermissionOutcome.denied(this.denied) : required_ = true;

  final List<String> denied;

  /// False when the platform asks for Bluetooth permission itself.
  final bool required_;

  bool get ok => denied.isEmpty;

  String get message => 'Bluetooth permission denied: ${denied.join(', ')}';
}
