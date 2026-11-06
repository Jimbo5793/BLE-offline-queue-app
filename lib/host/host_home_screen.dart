import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../common/duration_picker.dart';
import '../common/live_session.dart';
import '../common/permissions.dart';
import '../common/time_format.dart' as fmt;
import '../data/database.dart';
import '../identity/identity.dart';
import '../logic/check_scheduler.dart';
import '../transport/ble_host_transport.dart';
import 'host_queue_screen.dart';
import 'host_session_service.dart';

/// Host setup. Names the session and goes live — the queue is a separate,
/// optional decision made afterwards from the dashboard.
class HostHomeScreen extends StatefulWidget {
  const HostHomeScreen({super.key, required this.identity});

  final LocalIdentity identity;

  @override
  State<HostHomeScreen> createState() => _HostHomeScreenState();
}

class _HostHomeScreenState extends State<HostHomeScreen> {
  final _title = TextEditingController(text: 'Office hours');
  bool _starting = false;
  String? _error;

  Duration? _length;
  int _checkCount = 0;

  /// Shortcuts, not the whole range. A real timetable has 45-minute tutorials
  /// and 25-minute lab slots in it, so "Custom" below is the way out of this
  /// list rather than an afterthought.
  static const _lengthPresets = <Duration?>[
    null,
    Duration(minutes: 30),
    Duration(minutes: 60),
    Duration(minutes: 90),
    Duration(minutes: 120),
    Duration(minutes: 180),
  ];

  /// The presets, plus whatever the host typed if it is not already one.
  List<Duration?> get _lengthOptions => [
        ..._lengthPresets,
        if (_length != null && !_lengthPresets.contains(_length)) _length,
      ];

  Future<void> _pickCustomLength() async {
    final picked = await askForDuration(
      context,
      title: 'Session length',
      initial: _length,
      min: const Duration(minutes: 1),
      max: const Duration(hours: 24),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _length = picked;
      // A shorter session may no longer fit the checks already asked for.
      if (_checkCount > _maxChecks) _checkCount = _maxChecks;
    });
  }

  /// How many checks fit, so the stepper cannot promise more than the
  /// scheduler can honour with a ten-minute minimum gap.
  int get _maxChecks => _length == null
      ? 8
      : CheckScheduler.defaults.maxChecksFor(_length!).clamp(0, 8);

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });

    try {
      // Android 12+ gates advertising and connecting behind runtime
      // permissions; without them the GATT server silently never appears.
      // macOS has no such API and prompts on first radio use instead.
      final permission = await BlePermissions.forHosting();
      if (!permission.ok) throw Exception(permission.message);

      final dir = await getApplicationDocumentsDirectory();
      final adb = await AppDatabase.open(path: p.join(dir.path, 'queue.db'));

      final transport = BleHostTransport(localId: widget.identity.userId);
      final service = HostSessionService(
        db: adb.db,
        transport: transport,
        identity: widget.identity,
      );
      final session = await service.createSession(
        title: _title.text.trim().isEmpty ? 'Session' : _title.text.trim(),
        length: _length,
        checkCount: _checkCount,
      );
      // The transport serves this to clients that connect briefly and read,
      // rather than relying on a push they may not be connected for.
      service.onSnapshotBytes = transport.publishSnapshot;
      await service.start();
      // Put the title on the air so nearby attendees can read it from the
      // scan response without connecting.
      await transport.publish(
        title: session.title,
        hostName: widget.identity.displayName,
        locked: false,
        attendeeCount: 0,
      );

      LiveSession.instance
          .startHosting(service: service, transport: transport, db: adb);

      if (!mounted) return;
      // Replace, not push: backing out of a live dashboard should return to
      // the home screen, not to the form that created the session.
      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => HostQueueScreen(service: service, transport: transport),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Host a session')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Session name',
                helperText: 'Shown to attendees when they scan for sessions',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.wifi_tethering, color: scheme.primary),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Anyone nearby can join',
                              style:
                                  Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 4),
                          Text(
                            'There is no code. Attendees in Bluetooth range '
                            'see your session and tap to join. You can lock '
                            'the session or remove people at any time.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.format_list_numbered,
                        color: scheme.onSurfaceVariant),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('A queue is optional',
                              style:
                                  Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 4),
                          Text(
                            'Start the session first. Open a queue later from '
                            'the dashboard if you need one.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.schedule, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text('How long?',
                              style: Theme.of(context).textTheme.titleSmall),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Only used to warn you when the time is up. The session '
                      'never ends itself.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final option in _lengthOptions)
                          ChoiceChip(
                            label: Text(option == null
                                ? 'Open ended'
                                : fmt.approxDuration(option)),
                            selected: _length == option,
                            onSelected: (_) => setState(() {
                              _length = option;
                              if (_checkCount > _maxChecks) {
                                _checkCount = _maxChecks;
                              }
                            }),
                          ),
                        ActionChip(
                          avatar: const Icon(Icons.edit_outlined, size: 16),
                          label: const Text('Custom'),
                          onPressed: _pickCustomLength,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.fact_check_outlined,
                            color: _checkCount > 0
                                ? scheme.primary
                                : scheme.onSurfaceVariant),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text('Random attendance checks',
                              style: Theme.of(context).textTheme.titleSmall),
                        ),
                        Switch(
                          value: _checkCount > 0,
                          onChanged: _maxChecks == 0
                              ? null
                              : (on) => setState(
                                  () => _checkCount = on ? 1.clamp(0, _maxChecks) : 0),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _checkCount == 0
                          ? 'Off. Nobody is checked after they join.'
                          : _length == null
                              ? 'Checks repeat at random, 10–25 minutes apart, '
                                  'for as long as the session runs.'
                              : '$_checkCount check${_checkCount == 1 ? '' : 's'} '
                                  'at random times, at least 10 minutes apart. '
                                  'Shown as Test 1, Test 2…',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    if (_checkCount > 0 && _length != null) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              value: _checkCount.toDouble(),
                              min: 1,
                              max: _maxChecks.toDouble().clamp(1, 8),
                              divisions: (_maxChecks - 1).clamp(1, 7),
                              label: '$_checkCount',
                              onChanged: (v) =>
                                  setState(() => _checkCount = v.round()),
                            ),
                          ),
                          SizedBox(
                            width: 28,
                            child: Text('$_checkCount',
                                textAlign: TextAlign.end,
                                style:
                                    Theme.of(context).textTheme.titleMedium),
                          ),
                        ],
                      ),
                    ],
                    Text(
                      'Checks are silent — nobody is interrupted. They record '
                      'who is still in range, so somebody who connects on the '
                      'way past and leaves shows up as missing.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Card(
                color: scheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline, color: scheme.onErrorContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(_error!,
                            style: TextStyle(color: scheme.onErrorContainer)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _starting ? null : _start,
              icon: _starting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow),
              label: Text(_starting ? 'Starting…' : 'Go live'),
            ),
            const SizedBox(height: 12),
            Text(
              'Your phone becomes the Bluetooth host. Keep this screen open '
              'and stay near your attendees.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
