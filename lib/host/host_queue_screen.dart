import 'package:flutter/material.dart';

import '../common/live_session.dart';
import '../common/theme.dart';
import '../common/time_format.dart' as fmt;
import '../data/history_repository.dart';
import '../domain/proximity.dart';
import '../identity/identity.dart';
import '../logic/entry_timer.dart';
import '../logic/position_resolver.dart';
import '../transport/ble_host_transport.dart';
import '../transport/protocol.dart';
import 'host_session_service.dart';
import 'timer_controls.dart';

/// The host's live view: who is here, and the queue if one is running.
class HostQueueScreen extends StatefulWidget {
  const HostQueueScreen({super.key, required this.service, this.transport});

  final HostSessionService service;

  /// Present on a real device; null in the simulator.
  final BleHostTransport? transport;

  @override
  State<HostQueueScreen> createState() => _HostQueueScreenState();
}

class _HostQueueScreenState extends State<HostQueueScreen> {
  int _tab = 0;
  RosterSnapshot? _roster;
  List<CheckRun> _checks = const [];
  bool _checking = false;

  HostSessionService get s => widget.service;

  @override
  void initState() {
    super.initState();
    // Seed from what the service already knows. Reopening this screen used to
    // start with an empty roster and stay empty until something changed, so
    // backing out and resuming looked like every attendee had vanished.
    _roster = s.lastRoster;
    _checks = s.checks;

    // Republished whenever state changes and periodically thereafter, so a
    // scanning client sees the current version even if it missed the change.
    s.onAdvertise = (r) => widget.transport?.publish(
          title: r.title,
          hostName: s.identity.displayName,
          locked: r.locked,
          attendeeCount: r.hereCount,
          stateVersion: r.revision,
        );

    s.rosters.listen((r) {
      if (!mounted) return;
      setState(() => _roster = r);
      // Keep the advertisement honest: nearby attendees read the headcount
      // and lock state straight from the scan response.
      widget.transport?.publish(
        title: r.title,
        hostName: s.identity.displayName,
        locked: r.locked,
        attendeeCount: r.hereCount,
        // Every roster carries a fresh revision, so republishing here is what
        // tells scanning clients there is something new to read.
        stateVersion: r.revision,
      );
    });
    s.snapshots.listen((_) {
      if (mounted) setState(() {});
    });
    s.checkRuns.listen((runs) {
      if (mounted) setState(() => _checks = runs);
    });
    // State changes only — starting, pausing, expiring. The ticking display
    // drives itself so a running countdown never re-queries the database.
    s.timers.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _runCheck() async {
    setState(() => _checking = true);
    final run = await s.runCheckNow();
    if (!mounted) return;
    setState(() => _checking = false);
    if (run != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${run.label} recorded')),
      );
    }
  }

  Future<void> _end() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End this session?'),
        content: const Text(
            'Attendees will be disconnected and the queue will close.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('End session')),
        ],
      ),
    );
    if (ok != true) return;
    await LiveSession.instance.stopHosting();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final session = s.session;
    final fading = _roster?.fadingCount ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(session?.title ?? 'Session'),
        actions: [
          IconButton(
            tooltip: s.isLocked ? 'Unlock session' : 'Lock session',
            onPressed: () async {
              await s.setLocked(!s.isLocked);
              if (mounted) setState(() {});
            },
            icon: Icon(s.isLocked ? Icons.lock : Icons.lock_open),
          ),
          IconButton(
            tooltip: 'End session',
            onPressed: _end,
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        ],
        bottom: _banner(context),
      ),
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: [
            _RoomTab(
              service: s,
              roster: _roster,
              checks: _checks,
              checking: _checking,
              onRunCheck: _runCheck,
              onChanged: _refresh,
            ),
            _QueueTab(service: s, roster: _roster, onChanged: _refresh),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: fading > 0,
              label: Text('$fading'),
              backgroundColor: const Color(0xFFE08600),
              child: const Icon(Icons.people_outline),
            ),
            label: 'Room',
          ),
          const NavigationDestination(
            icon: Icon(Icons.format_list_numbered),
            label: 'Queue',
          ),
        ],
      ),
    );
  }

  /// The lock and end-of-time notices share one strip; the time warning wins
  /// because it is the newer piece of news.
  PreferredSizeWidget? _banner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (text, bg, fg) = s.plannedEndPassed
        ? (
            'Time is up — end the session when you are ready',
            scheme.errorContainer,
            scheme.onErrorContainer
          )
        : s.isLocked
            ? (
                'Locked — no new attendees can join',
                scheme.tertiaryContainer,
                scheme.onTertiaryContainer
              )
            : (null, null, null);
    if (text == null) return null;

    return PreferredSize(
      preferredSize: const Size.fromHeight(26),
      child: Container(
        width: double.infinity,
        color: bg,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: fg)),
      ),
    );
  }

  void _refresh() {
    if (mounted) setState(() {});
  }
}

// -------------------------------------------------------------------- room

class _RoomTab extends StatelessWidget {
  const _RoomTab({
    required this.service,
    required this.roster,
    required this.checks,
    required this.checking,
    required this.onRunCheck,
    required this.onChanged,
  });

  final HostSessionService service;
  final RosterSnapshot? roster;
  final List<CheckRun> checks;
  final bool checking;
  final VoidCallback onRunCheck;
  final VoidCallback onChanged;

  Future<void> _addManual(BuildContext context) async {
    final name = await _promptForName(context,
        title: 'Add someone without the app',
        hint: 'Their name',
        helper: 'They will appear in the room and can be put in the queue.');
    if (name == null) return;
    await service.addManualAttendee(name);
    onChanged();
  }

  Future<void> _relabel(BuildContext context, RosterRow row) async {
    final name = await _promptForName(
      context,
      title: 'Correct this name',
      hint: 'Name',
      helper: row.kind == UserKind.manual
          ? 'You added this person, so you can rename them freely.'
          : 'Applies to this session only. Their account is unchanged.',
      initial: row.displayName,
    );
    if (name == null) return;
    if (row.kind == UserKind.manual) {
      await service.renameManualAttendee(row.userId, name);
    } else {
      await service.setHostLabel(row.userId, name);
    }
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = roster?.rows ?? const <RosterRow>[];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  rows.isEmpty ? 'Nobody here yet' : _headcount(roster),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton.icon(
                onPressed: () => _addManual(context),
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('Add by hand'),
              ),
            ],
          ),
        ),
        _ChecksStrip(
          checks: checks,
          checking: checking,
          onRunCheck: onRunCheck,
        ),
        if (rows.isEmpty)
          Expanded(
            child: _Empty(
              icon: Icons.wifi_tethering,
              title: 'Waiting for attendees',
              subtitle:
                  'Anyone nearby with the app will see this session and can '
                  'join without a code.',
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final row = rows[i];
                final style = ProximityStyle.of(row.proximity, scheme);
                final manual = row.kind == UserKind.manual;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    child: ListTile(
                      leading: Icon(
                        manual ? Icons.person_outline : style.icon,
                        color: manual ? scheme.onSurfaceVariant : style.color,
                      ),
                      title: Row(
                        children: [
                          Flexible(
                              child: Text(row.displayName,
                                  overflow: TextOverflow.ellipsis)),
                          if (row.hostLabelled) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.edit_note,
                                size: 15, color: scheme.primary),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        manual
                            ? 'Added by you · no device'
                            : row.inQueue
                                ? '${style.label} · in queue at ${row.position}'
                                : style.label,
                        style: TextStyle(
                            color: !manual && row.proximity != ProximityState.inRange
                                ? style.color
                                : scheme.onSurfaceVariant),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Visible, not buried in the overflow menu. This was
                          // a menu item before and was effectively invisible —
                          // the feature existed and nobody could find it.
                          if (service.hasQueue && !row.inQueue)
                            IconButton(
                              tooltip: 'Add to queue',
                              onPressed: () async {
                                final r =
                                    await service.hostAddToQueue(row.userId);
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(r.ok
                                        ? '${row.displayName} added at ${r.position}'
                                        : 'Could not add ${row.displayName}'),
                                  ),
                                );
                                onChanged();
                              },
                              icon: const Icon(Icons.playlist_add),
                            ),
                          PopupMenuButton<String>(
                            onSelected: (v) async {
                              switch (v) {
                                case 'rename':
                                  await _relabel(context, row);
                                case 'remove':
                                  await service.removeAttendee(row.userId);
                                  onChanged();
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                  value: 'rename',
                                  child: ListTile(
                                      leading:
                                          Icon(Icons.drive_file_rename_outline),
                                      title: Text('Correct name'))),
                              const PopupMenuItem(
                                  value: 'remove',
                                  child: ListTile(
                                      leading:
                                          Icon(Icons.person_remove_outlined),
                                      title: Text('Remove'))),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------- queue

/// Test 1..N as they land, with a button to take one now.
/// Reads out the room honestly.
///
/// Somebody out of range is listed but NOT counted as here — lumping them in
/// as "present · about to drop" is how a host reads a room as fuller than it
/// is, which is exactly the mistake an attendance app must not make.
String _headcount(RosterSnapshot? roster) {
  if (roster == null) return '';
  final parts = <String>[
    '${roster.hereCount} here',
    if (roster.weakCount > 0) '${roster.weakCount} weak signal',
    if (roster.goneCount > 0) '${roster.goneCount} out of range',
  ];
  return parts.join(' · ');
}

class _ChecksStrip extends StatelessWidget {
  const _ChecksStrip({
    required this.checks,
    required this.checking,
    required this.onRunCheck,
  });

  final List<CheckRun> checks;
  final bool checking;
  final VoidCallback onRunCheck;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: checks.isEmpty
                ? Text('No checks taken yet',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant))
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final c in checks)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Chip(
                              visualDensity: VisualDensity.compact,
                              avatar: Icon(
                                  c.manual
                                      ? Icons.touch_app_outlined
                                      : Icons.shuffle,
                                  size: 14),
                              label: Text(
                                  '${c.label} · ${_time(c.at)}',
                                  style: const TextStyle(fontSize: 12)),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          TextButton.icon(
            onPressed: checking ? null : onRunCheck,
            icon: checking
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.fact_check_outlined, size: 18),
            label: const Text('Check now'),
          ),
        ],
      ),
    );
  }

  static String _time(DateTime d) => fmt.clockTime(d);
}

class _QueueTab extends StatelessWidget {
  const _QueueTab({
    required this.service,
    required this.roster,
    required this.onChanged,
  });

  final HostSessionService service;
  final RosterSnapshot? roster;
  final VoidCallback onChanged;

  Future<void> _createQueue(BuildContext context) async {
    var capacity = 10;
    final name = TextEditingController(text: 'Main queue');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Open a queue'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Queue name'),
              ),
              const SizedBox(height: 20),
              Text('$capacity slots',
                  style: Theme.of(ctx).textTheme.headlineSmall),
              Slider(
                value: capacity.toDouble(),
                min: 1,
                max: 50,
                divisions: 49,
                onChanged: (v) => setDialog(() => capacity = v.round()),
              ),
              Text(
                'Anyone joining beyond this waits in overflow and is promoted '
                'automatically as slots free up.',
                style: Theme.of(ctx).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Open queue')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await service.createQueue(
        name: name.text.trim().isEmpty ? 'Queue' : name.text.trim(),
        capacity: capacity);
    onChanged();
  }

  Future<void> _editCapacity(BuildContext context) async {
    var value = service.queue?.capacity ?? 10;
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Queue capacity'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$value slots',
                  style: Theme.of(ctx).textTheme.headlineMedium),
              Slider(
                value: value.toDouble(),
                min: 1,
                max: 50,
                divisions: 49,
                onChanged: (v) => setDialog(() => value = v.round()),
              ),
              Text(
                'Shrinking moves the tail of the queue into overflow. Nobody '
                'loses their place.',
                style: Theme.of(ctx).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, value),
                child: const Text('Apply')),
          ],
        ),
      ),
    );
    if (result != null) {
      await service.editCapacity(result);
      onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (!service.hasQueue) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.format_list_numbered,
                  size: 56, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text('No queue running',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                'The session works fine without one. Open a queue when you '
                'need to take people in order.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: () => _createQueue(context),
                icon: const Icon(Icons.add),
                label: const Text('Open a queue'),
              ),
            ],
          ),
        ),
      );
    }

    return FutureBuilder<QueueResolution>(
      future: service.logic.resolution(service.queue!.id),
      builder: (context, snap) {
        final res = snap.data;
        if (res == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = res.all;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(service.queue?.name ?? 'Queue',
                            style: Theme.of(context).textTheme.titleMedium),
                        Text(
                          '${res.filledSlots} of ${res.capacity} slots'
                          '${res.overflow.isEmpty ? '' : ' · ${res.overflow.length} in overflow'}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _editCapacity(context),
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('Capacity'),
                  ),
                ],
              ),
            ),
            if (rows.isEmpty)
              Expanded(
                child: _Empty(
                  icon: Icons.hourglass_empty,
                  title: 'Queue is empty',
                  subtitle: 'Attendees can join it themselves, or you can add '
                      'someone from the Room tab.',
                ),
              )
            else
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  itemCount: rows.length,
                  onReorderItem: (from, to) async {
                    // Dragging writes an explicit host override, which
                    // outranks both arrival order and attendee pins.
                    final ids = rows.map((r) => r.entry.id).toList();
                    ids.insert(to, ids.removeAt(from));
                    await service.hostReorder(ids);
                    onChanged();
                  },
                  itemBuilder: (context, i) => _EntryTile(
                    key: ValueKey(rows[i].entry.id),
                    resolved: rows[i],
                    name: service.nameOf(rows[i].attendeeId),
                    proximity: service.proximityOf(rows[i].attendeeId),
                    timer: service.timerFor(rows[i].entry.id),
                    index: i,
                    onStartTimer: () async {
                      final setup = await showTimerSetup(
                        context,
                        personName: service.nameOf(rows[i].attendeeId),
                      );
                      if (setup == null) return;
                      service.startTimer(
                        entryId: rows[i].entry.id,
                        direction: setup.direction,
                        total: setup.total,
                        warnings: setup.warnings,
                      );
                      onChanged();
                    },
                    onPauseTimer: () {
                      final t = service.timerFor(rows[i].entry.id);
                      if (t == null) return;
                      t.isRunning
                          ? service.pauseTimer(rows[i].entry.id)
                          : service.resumeTimer(rows[i].entry.id);
                      onChanged();
                    },
                    onStopTimer: () async {
                      await service.stopTimer(rows[i].entry.id);
                      onChanged();
                    },
                    onFinish: () async {
                      await service.finish(rows[i].entry.id);
                      onChanged();
                    },
                    onRemove: () async {
                      await service.hostRemove(rows[i].entry.id);
                      onChanged();
                    },
                    onPromote: () async {
                      await service.hostPromote(rows[i].entry.id, 1);
                      onChanged();
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    super.key,
    required this.resolved,
    required this.name,
    required this.proximity,
    required this.index,
    required this.onFinish,
    required this.onRemove,
    required this.onPromote,
    required this.onStartTimer,
    required this.onPauseTimer,
    required this.onStopTimer,
    this.timer,
  });

  final ResolvedEntry resolved;
  final String name;
  final ProximityState proximity;
  final EntryTimer? timer;
  final int index;
  final VoidCallback onStartTimer;
  final VoidCallback onPauseTimer;
  final VoidCallback onStopTimer;
  final VoidCallback onFinish;
  final VoidCallback onRemove;
  final VoidCallback onPromote;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = ProximityStyle.of(proximity, scheme);
    final fading = proximity != ProximityState.inRange;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        color: resolved.isOverflow
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.25)
            : null,
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
          leading: CircleAvatar(
            backgroundColor: resolved.isOverflow
                ? scheme.surfaceContainerHighest
                : scheme.primaryContainer,
            child: Text(
              '${resolved.position}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: resolved.isOverflow
                    ? scheme.onSurfaceVariant
                    : scheme.onPrimaryContainer,
              ),
            ),
          ),
          title: Row(
            children: [
              Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
              if (resolved.pinHonoured) ...[
                const SizedBox(width: 6),
                Icon(Icons.push_pin, size: 14, color: scheme.primary),
              ],
            ],
          ),
          onTap: timer == null ? onStartTimer : null,
          subtitle: Row(
            children: [
              if (timer != null) ...[
                TimerReadout(timer: timer!),
                Text(' · ', style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
              if (resolved.isOverflow)
                Text('Overflow · ',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              Icon(style.icon,
                  size: 13,
                  color: fading ? style.color : scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                fading ? '${style.label} — may drop' : style.label,
                style: TextStyle(
                  color: fading ? style.color : scheme.onSurfaceVariant,
                  fontWeight: fading ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (timer == null)
                IconButton(
                  tooltip: 'Start a timer',
                  onPressed: onStartTimer,
                  icon: const Icon(Icons.timer_outlined),
                )
              else ...[
                IconButton(
                  tooltip: timer!.isRunning ? 'Pause' : 'Resume',
                  onPressed: onPauseTimer,
                  icon: Icon(timer!.isRunning
                      ? Icons.pause_circle_outline
                      : Icons.play_circle_outline),
                ),
                IconButton(
                  tooltip: 'Stop the timer',
                  onPressed: onStopTimer,
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
              ],
              PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'finish' => onFinish(),
                  'remove' => onRemove(),
                  'promote' => onPromote(),
                  _ => null,
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'finish',
                      child: ListTile(
                          leading: Icon(Icons.check_circle_outline),
                          title: Text('Mark as served'))),
                  if (resolved.isOverflow)
                    const PopupMenuItem(
                        value: 'promote',
                        child: ListTile(
                            leading: Icon(Icons.vertical_align_top),
                            title: Text('Promote to front'))),
                  const PopupMenuItem(
                      value: 'remove',
                      child: ListTile(
                          leading: Icon(Icons.playlist_remove),
                          title: Text('Remove from queue'))),
                ],
              ),
              ReorderableDragStartListener(
                index: index,
                child: Icon(Icons.drag_handle, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String?> _promptForName(
  BuildContext context, {
  required String title,
  required String hint,
  required String helper,
  String? initial,
}) async {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(labelText: hint, helperText: helper),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save')),
      ],
    ),
  ).then((v) => (v == null || v.isEmpty) ? null : v);
}

class _Empty extends StatelessWidget {
  const _Empty(
      {required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
