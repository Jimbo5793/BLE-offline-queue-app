import 'package:flutter/material.dart';

import 'account/account_screen.dart';
import 'attendee/attendee_queue_screen.dart';
import 'attendee/discover_screen.dart';
import 'common/live_session.dart';
import 'common/theme.dart';
import 'host/history_screen.dart';
import 'host/host_home_screen.dart';
import 'host/host_queue_screen.dart';
import 'identity/identity.dart';
import 'identity/identity_store.dart';

void main() => runApp(const BeaconQApp());

class BeaconQApp extends StatelessWidget {
  const BeaconQApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'BeaconQ',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const AccountGate(),
      );
}

/// Loads the account, or creates one on first launch.
///
/// Nothing else can run first: the keypair made here is what signs every
/// message, and without it the host has no way to tell one device from another.
class AccountGate extends StatefulWidget {
  const AccountGate({super.key});

  @override
  State<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends State<AccountGate> {
  final _store = IdentityStore();
  LocalIdentity? _identity;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final identity = await _store.load();
      if (mounted) {
        setState(() {
          _identity = identity;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not open your account:\n$_error',
                textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final identity = _identity;
    if (identity == null) {
      return CreateAccountScreen(
        store: _store,
        onCreated: (created) => setState(() => _identity = created),
      );
    }
    return RolePickerScreen(
      store: _store,
      identity: identity,
      onIdentityChanged: (updated) => setState(() => _identity = updated),
    );
  }
}

/// One app, two roles. The host runs the database and the BLE GATT server;
/// attendees find it by scanning.
class RolePickerScreen extends StatefulWidget {
  const RolePickerScreen({
    super.key,
    required this.store,
    required this.identity,
    required this.onIdentityChanged,
  });

  final IdentityStore store;
  final LocalIdentity identity;
  final ValueChanged<LocalIdentity> onIdentityChanged;

  @override
  State<RolePickerScreen> createState() => _RolePickerScreenState();
}

class _RolePickerScreenState extends State<RolePickerScreen> {
  final _live = LiveSession.instance;

  @override
  void initState() {
    super.initState();
    _live.addListener(_onLiveChanged);
  }

  @override
  void dispose() {
    _live.removeListener(_onLiveChanged);
    super.dispose();
  }

  void _onLiveChanged() {
    if (mounted) setState(() {});
  }

  IdentityStore get store => widget.store;
  LocalIdentity get identity => widget.identity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('BeaconQ'),
        actions: [
          IconButton(
            tooltip: 'Your account',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AccountDetailsScreen(
                  store: store,
                  identity: identity,
                  onChanged: widget.onIdentityChanged,
                ),
              ),
            ),
            icon: const Icon(Icons.account_circle_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.groups_2_outlined,
                      size: 64, color: scheme.primary),
                  const SizedBox(height: 16),
                  Text('Hello, ${identity.displayName}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(
                    'Run a session over Bluetooth. No internet, no server — '
                    'the host device holds everything.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  if (_live.isHosting)
                    _ResumeCard(
                      icon: Icons.record_voice_over_outlined,
                      label: 'Hosting now',
                      title: _live.hostSessionTitle ?? 'Session',
                      onResume: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => HostQueueScreen(
                              service: _live.host!,
                              transport: _live.hostTransport,
                            ),
                          ),
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                  if (_live.isAttending)
                    _ResumeCard(
                      icon: Icons.groups_2_outlined,
                      label: 'In a session',
                      title: _live.attendeeSessionTitle ?? 'Session',
                      onResume: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                AttendeeQueueScreen(service: _live.attendee!),
                          ),
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                  if (_live.anyLive) const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _live.isHosting
                        ? null
                        : () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                  builder: (_) =>
                                      HostHomeScreen(identity: identity)),
                            ),
                    icon: const Icon(Icons.record_voice_over_outlined),
                    label: Text(_live.isHosting
                        ? 'Already hosting'
                        : "I'm hosting"),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _live.isAttending
                        ? null
                        : () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                  builder: (_) =>
                                      DiscoverScreen(identity: identity)),
                            ),
                    icon: const Icon(Icons.bluetooth_searching),
                    label: Text(_live.isAttending
                        ? 'Already in a session'
                        : 'Find a session'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => HistoryScreen(identity: identity)),
                    ),
                    icon: const Icon(Icons.history),
                    label: const Text('Past sessions'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A live session on the home screen, so backing out of a dashboard never
/// leaves the session stranded and unreachable.
class _ResumeCard extends StatelessWidget {
  const _ResumeCard({
    required this.icon,
    required this.label,
    required this.title,
    required this.onResume,
  });

  final IconData icon;
  final String label;
  final String title;
  final Future<void> Function() onResume;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        color: scheme.primaryContainer,
        child: InkWell(
          onTap: onResume,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: [
                Icon(icon, color: scheme.onPrimaryContainer),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label,
                          style: TextStyle(
                              fontSize: 12,
                              color: scheme.onPrimaryContainer
                                  .withValues(alpha: 0.8))),
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: scheme.onPrimaryContainer)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: onResume,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(80, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: const Text('Resume'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
