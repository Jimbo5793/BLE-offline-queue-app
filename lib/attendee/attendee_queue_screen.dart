import 'package:flutter/material.dart';

import 'dart:async';
import 'dart:math';

import '../common/live_session.dart';
import '../common/theme.dart';
import '../domain/proximity.dart';
import '../identity/identity.dart';
import '../logic/claim_result.dart';
import '../transport/protocol.dart';
import 'attendee_session_service.dart';

/// What the attendee sees once they are in a session: where they stand, and
/// the four things they can do about it.
class AttendeeQueueScreen extends StatefulWidget {
  const AttendeeQueueScreen({super.key, required this.service});

  final AttendeeSessionService service;

  @override
  State<AttendeeQueueScreen> createState() => _AttendeeQueueScreenState();
}

class _AttendeeQueueScreenState extends State<AttendeeQueueScreen> {
  AttendeeSessionService get s => widget.service;
  bool _busy = false;

  int _tab = 0;
  Timer? _autoRefresh;
  final _rng = Random();

  /// Jittered so a dozen attendees do not all wake at the same instant and
  /// collide over the host's handful of connection slots.
  Duration get _nextRefreshGap =>
      Duration(seconds: 20 + _rng.nextInt(21));

  void _scheduleRefresh() {
    _autoRefresh?.cancel();
    _autoRefresh = Timer(_nextRefreshGap, () async {
      if (!mounted) return;
      await s.refresh();
      if (mounted) {
        setState(() {});
        _scheduleRefresh();
      }
    });
  }

  Future<void> _refreshNow() async {
    setState(() {});
    final ok = await s.refresh();
    if (!mounted) return;
    setState(() {});
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not reach the host. Move closer and try again.'),
        ),
      );
    }
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scheduleRefresh();
    s.snapshots.listen((_) {
      if (mounted) setState(() {});
    });
    s.rosters.listen((_) {
      if (mounted) setState(() {});
    });
    s.presenceUpdates.listen((_) {
      if (mounted) setState(() {});
    });
    s.endings.listen(_onSessionEnded);
    // Contact comes and goes. It gets a banner, not a dialog, because it is
    // recoverable and often means nothing more than stepping into a corridor.
    s.contact.listen((_) {
      if (mounted) setState(() {});
    });
  }

  /// The session has stopped being ours to be in, for good.
  ///
  /// Both cases were previously silent: the roster simply stopped changing,
  /// which is indistinguishable from a quiet room, so the attendee sat on a
  /// dead screen believing they were still counted. Losing contact with the
  /// host does not come through here — that is recoverable and gets a banner.
  Future<void> _onSessionEnded(SessionEnd how) async {
    if (!mounted) return;
    _autoRefresh?.cancel();

    final (title, body) = switch (how) {
      SessionEnd.endedByHost => (
          'Session ended',
          'The host has ended ${s.sessionTitle ?? 'this session'}. Your '
              'attendance is already recorded on their device.',
        ),
      SessionEnd.removedByHost => (
          'Removed from the session',
          'The host has taken you out of ${s.sessionTitle ?? 'this session'}. '
              'You cannot rejoin unless they put you back — speak to them if '
              'this looks wrong.',
        ),
    };

    // Tear the session down before showing anything: whatever the reason, the
    // radio work is over and there is nothing left to keep alive.
    await LiveSession.instance.stopAttending(notifyHost: false);
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// Leaves the whole session, not just the queue.
  ///
  /// Distinct from "leave the queue": an attendee may want to stay in the room
  /// without holding a place, and previously the only way out of the session
  /// was to kill the app.
  Future<void> _leaveSession() async {
    // Captured before any await: the messenger has to outlive this screen,
    // because the message below is worth showing after we have popped home.
    final messenger = ScaffoldMessenger.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave this session?'),
        content: Text(
          s.amQueued
              ? 'You will lose your place in the queue and disconnect from '
                  '${s.sessionTitle ?? 'the session'}.'
              : 'You will disconnect from ${s.sessionTitle ?? 'the session'}. '
                  'You can rejoin while you are still in range.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Stay')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Leave')),
        ],
      ),
    );
    if (ok != true) return;

    // No separate leaveQueue call — the host withdraws us as part of handling
    // the departure, and each round trip costs a connection slot.
    final told = await LiveSession.instance.leaveAttending();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);

    if (!told) {
      messenger.showSnackBar(const SnackBar(
        content: Text('You have left, but the host could not be reached — '
            'they will see you drop off in a couple of minutes.'),
      ));
    }
  }

  Future<void> _act(Future<ClaimResult> Function() action) async {
    setState(() => _busy = true);
    final result = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_explain(result.failure))),
      );
    }
  }

  String _explain(ClaimFailure? f) => switch (f) {
        ClaimFailure.alreadyQueued => "You're already in this queue.",
        ClaimFailure.slotTaken => 'Somebody took that slot first.',
        ClaimFailure.slotOutOfRange => "That slot isn't available.",
        ClaimFailure.queueClosed => 'The host closed this queue.',
        ClaimFailure.sessionEnded => 'The session has ended.',
        ClaimFailure.notQueued => "You're not in the queue.",
        ClaimFailure.noSuchQueue => "Couldn't reach the host. Try again.",
        null => 'Something went wrong.',
      };

  Future<void> _pickSlot() async {
    final snap = s.snapshot;
    if (snap == null) return;
    final taken = snap.rows.map((r) => r.position).toSet();
    final free = [
      for (var i = 1; i <= snap.capacity; i++)
        if (!taken.contains(i)) i
    ];
    if (free.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Every slot is taken right now.')),
      );
      return;
    }

    final chosen = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Pick a slot',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            Flexible(
              child: GridView.count(
                shrinkWrap: true,
                crossAxisCount: 5,
                padding: const EdgeInsets.all(16),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                children: [
                  for (final slot in free)
                    OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, slot),
                      style: OutlinedButton.styleFrom(
                          minimumSize: Size.zero,
                          padding: EdgeInsets.zero),
                      child: Text('$slot'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen != null) await _act(() => s.claimSlot(chosen));
  }

  @override
  Widget build(BuildContext context) {
    final roster = s.roster;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.sessionTitle ?? 'Session'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: s.isRefreshing ? null : _refreshNow,
            icon: s.isRefreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Leave session',
            onPressed: _leaveSession,
            icon: const Icon(Icons.logout),
          ),
        ],
        bottom: s.sessionLocked
            ? PreferredSize(
                preferredSize: const Size.fromHeight(26),
                child: Container(
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('Host locked this session',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onTertiaryContainer)),
                ),
              )
            : null,
      ),
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: [_queueTab(context), _roomTab(context)],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.format_list_numbered),
            label: 'Queue',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: (roster?.hereCount ?? 0) > 0,
              label: Text('${roster?.hereCount ?? 0}'),
              child: const Icon(Icons.people_outline),
            ),
            label: 'Room',
          ),
        ],
      ),
    );
  }

  Widget _queueTab(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final snap = s.snapshot;
    final row = s.myRow;

    if (!s.hasQueue) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (s.hostUnreachable) const _LostContactBanner(),
          if (s.isLeavingRange) _RangeWarning(state: s.presence.state),
          const SizedBox(height: 40),
          Icon(Icons.hourglass_empty,
              size: 56, color: scheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text('No queue yet',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            "You're in the session. If the host opens a queue it will appear "
            'here.',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        if (s.hostUnreachable) const _LostContactBanner(),
        if (s.isLeavingRange) _RangeWarning(state: s.presence.state),
        _PositionCard(row: row, capacity: snap?.capacity ?? 0),
        const SizedBox(height: 16),
        if (row == null) ...[
          FilledButton.icon(
            onPressed: _busy ? null : () => _act(s.claimNextAvailable),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Join the queue'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickSlot,
            icon: const Icon(Icons.grid_view),
            label: const Text('Pick a specific slot'),
          ),
        ] else ...[
          if (!row.pinned)
            FilledButton.tonalIcon(
              onPressed:
                  _busy || row.isOverflow ? null : () => _act(s.pinCurrentSlot),
              icon: const Icon(Icons.push_pin_outlined),
              label: Text(row.isOverflow
                  ? 'Pin (available once you have a slot)'
                  : 'Pin me to slot ${row.position}'),
            ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _act(s.leaveQueue),
            icon: const Icon(Icons.logout),
            label: const Text('Leave the queue'),
          ),
        ],
        const SizedBox(height: 28),
        if (snap != null) ...[
          Row(
            children: [
              Text('The queue',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text(
                '${snap.activeCount}/${snap.capacity}'
                '${snap.overflowCount == 0 ? '' : ' · ${snap.overflowCount} waiting'}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final r in snap.rows)
            _QueueRow(row: r, isMe: r.attendeeId == s.attendeeId),
        ],
      ],
    );
  }

  Widget _roomTab(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final roster = s.roster;
    final rows = roster?.rows ?? const <RosterRow>[];

    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.people_outline,
                  size: 56, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text("You're the first one here",
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text('${rows.length} in the room',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        for (final r in rows)
          Builder(builder: (context) {
            final isMe = r.userId == s.attendeeId;
            final manual = r.kind == UserKind.manual;
            final style = ProximityStyle.of(r.proximity, scheme);
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              color: isMe
                  ? scheme.primaryContainer.withValues(alpha: 0.4)
                  : null,
              child: ListTile(
                leading: Icon(
                  manual ? Icons.person_outline : style.icon,
                  color: manual ? scheme.onSurfaceVariant : style.color,
                ),
                title: Text(isMe ? '${r.displayName} (you)' : r.displayName,
                    style: TextStyle(
                        fontWeight: isMe ? FontWeight.w600 : null)),
                subtitle: Text(
                  [
                    if (manual) 'Added by the host' else style.label,
                    if (r.inQueue) 'in queue at ${r.position}',
                  ].join(' · '),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            );
          }),
      ],
    );
  }
}

class _PositionCard extends StatelessWidget {
  const _PositionCard({required this.row, required this.capacity});

  final SnapshotRow? row;
  final int capacity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (row == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(Icons.event_available,
                  size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text("You're not in the queue",
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('Join to take the next free slot.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }

    final r = row!;
    return Card(
      color: r.isOverflow
          ? scheme.surfaceContainerHighest
          : scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
        child: Column(
          children: [
            Text(
              r.isOverflow ? 'Waiting in overflow' : 'Your slot',
              style: TextStyle(
                color: r.isOverflow
                    ? scheme.onSurfaceVariant
                    : scheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${r.position}',
              style: TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.w700,
                height: 1,
                color: r.isOverflow
                    ? scheme.onSurfaceVariant
                    : scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              r.isOverflow
                  ? "You'll move into a slot automatically as people leave."
                  : r.pinned
                      // The honest phrasing: a pin holds your index, it does
                      // not stop others passing you if the line shortens.
                      ? 'Reserved. Others may move ahead if the line shortens.'
                      : 'of $capacity slots',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: r.isOverflow
                    ? scheme.onSurfaceVariant
                    : scheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown while the host has stopped answering.
///
/// Distinct from the range warning above it, which is about OUR signal. This
/// one says nothing is coming back at all, which reads the same to the host as
/// having left — so it needs to be visible rather than inferred from a roster
/// that has quietly stopped changing.
///
/// A banner and not a dialog: it clears itself the moment a check-in is
/// answered, and stepping into a corridor should not end anybody's session.
class _LostContactBanner extends StatelessWidget {
  const _LostContactBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              Icon(Icons.cloud_off, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('The host is not answering',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: scheme.onErrorContainer)),
                    const SizedBox(height: 2),
                    Text(
                      'You are not being counted as here. Move closer — this '
                      'clears on its own once contact comes back.',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onErrorContainer),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RangeWarning extends StatelessWidget {
  const _RangeWarning({required this.state});
  final ProximityState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = ProximityStyle.of(state, scheme);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: style.color.withValues(alpha: 0.14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: style.color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("You're drifting out of range",
                        style: TextStyle(
                            fontWeight: FontWeight.w600, color: style.color)),
                    const SizedBox(height: 2),
                    const Text(
                        'Move closer to the host or you may lose your place.'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({required this.row, required this.isMe});

  final SnapshotRow row;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isMe ? scheme.primaryContainer.withValues(alpha: 0.5) : null,
        border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text('${row.position}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: row.isOverflow ? scheme.onSurfaceVariant : null,
                )),
          ),
          Expanded(
            child: Text(isMe ? '${row.displayName} (you)' : row.displayName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: isMe ? FontWeight.w600 : null)),
          ),
          if (row.pinned)
            Icon(Icons.push_pin, size: 14, color: scheme.primary),
          if (row.isOverflow) ...[
            const SizedBox(width: 6),
            Text('overflow',
                style: TextStyle(
                    fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}
