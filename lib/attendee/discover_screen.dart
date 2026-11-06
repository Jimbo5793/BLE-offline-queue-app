import 'package:flutter/material.dart';

import '../common/live_session.dart';
import '../common/permissions.dart';
import '../common/theme.dart';
import '../domain/proximity.dart';
import '../identity/identity.dart';
import '../transport/ble_attendee_transport.dart';
import '../transport/protocol.dart';
import 'attendee_queue_screen.dart';
import 'attendee_session_service.dart';

/// Find a session by scanning. No code, no QR — nearest first.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key, required this.identity});

  final LocalIdentity identity;

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  List<DiscoveredSession> _found = const [];
  bool _scanning = false;
  bool _joining = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final permission = await BlePermissions.forJoining();
      if (!permission.ok) throw Exception(permission.message);
      final sessions = await BleAttendeeTransport.discoverSessions();
      if (mounted) setState(() => _found = sessions);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _join(DiscoveredSession session) async {
    setState(() {
      _joining = true;
      _error = null;
    });

    AttendeeSessionService? service;
    try {
      final device = BleAttendeeTransport.deviceFor(session.deviceId);
      if (device == null) {
        throw Exception('That session is no longer in range. Scan again.');
      }

      final transport = BleAttendeeTransport(
        localId: widget.identity.userId,
        device: device,
      );
      service = AttendeeSessionService(
        transport: transport,
        identity: widget.identity,
        rssiSource: transport.readRssi,
      );
      await service.start();

      final ok = await service.join();
      if (!ok) {
        throw Exception(switch (service.rejectReason) {
          'sessionLocked' => 'That session is locked and is not taking anyone '
              'new right now.',
          'sessionClosed' => 'That session has ended.',
          // Trying again is what an attendee naturally does, so say plainly
          // that it will not work. This used to be silently accepted: the join
          // succeeded and the host's roster went on excluding them.
          'removedByHost' => 'The host removed you from that session. They '
              'have to put you back before you can rejoin.',
          _ => 'The host did not answer. Move closer and try again.',
        });
      }

      LiveSession.instance.startAttending(service);

      if (!mounted) return;
      // Replace, so backing out returns home rather than to the scan list.
      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => AttendeeQueueScreen(service: service!),
      ));
    } catch (e) {
      await service?.stop();
      if (mounted) {
        setState(() =>
            _error = '$e'.replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby sessions'),
        actions: [
          IconButton(
            tooltip: 'Scan again',
            onPressed: _scanning || _joining ? null : _scan,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_scanning) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Card(
                  color: scheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline,
                            color: scheme.onErrorContainer),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(_error!,
                              style:
                                  TextStyle(color: scheme.onErrorContainer)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _found.isEmpty
                  ? _empty(context)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                      itemCount: _found.length,
                      itemBuilder: (context, i) => _SessionTile(
                        session: _found[i],
                        nearest: i == 0,
                        busy: _joining,
                        onTap: () => _join(_found[i]),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Text(
                'Joining as ${widget.identity.displayName}',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_scanning ? Icons.bluetooth_searching : Icons.search_off,
                size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(_scanning ? 'Looking for sessions…' : 'No sessions nearby',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              _scanning
                  ? 'This takes a few seconds.'
                  : 'You need to be in the same room as the host. Move closer '
                      'and scan again.',
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

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.nearest,
    required this.busy,
    required this.onTap,
  });

  final DiscoveredSession session;
  final bool nearest;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = ProximityStyle.of(session.nearness, scheme);
    final enabled = !busy && !session.locked;

    // Laid out by hand rather than with ListTile: a ListTile gives its
    // trailing widget as much width as it asks for, and a button that asks
    // for all of it squeezes the title to one character per line.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        color: nearest ? scheme.primaryContainer.withValues(alpha: 0.45) : null,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: [
                Icon(
                  session.locked ? Icons.lock : Icons.wifi_tethering,
                  color:
                      session.locked ? scheme.onSurfaceVariant : style.color,
                ),
                const SizedBox(width: 14),
                // Expanded is what guarantees the text gets the leftover
                // width instead of being crushed by the button.
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight:
                              nearest ? FontWeight.w700 : FontWeight.w600,
                          fontStyle: session.detailsKnown
                              ? FontStyle.normal
                              : FontStyle.italic,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _subtitle(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: TextStyle(
                            fontSize: 12.5, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (session.locked)
                  Text('Locked',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant))
                else
                  FilledButton(
                    onPressed: busy ? null : onTap,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(72, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    child: const Text('Join'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle() {
    final parts = <String>[
      if (session.hostName.isNotEmpty)
        'Hosted by ${session.hostName}'
      else if (!session.detailsKnown)
        'Name shown once you join',
      _nearness(),
      if (session.attendeeCount > 0)
        '${session.attendeeCount} here'
      else if (session.detailsKnown)
        'nobody yet',
    ];
    return parts.join(' · ');
  }

  String _nearness() => switch (session.nearness) {
        ProximityState.inRange => 'very close',
        ProximityState.warning => 'nearby',
        ProximityState.lost => 'far away',
      };
}
