import 'dart:async';

import 'package:flutter/material.dart';

import '../common/duration_picker.dart';
import '../common/time_format.dart' as fmt;
import '../logic/entry_timer.dart';

/// The running clock on a queue row.
///
/// Ticks itself rather than going through the screen's `setState`: the queue
/// tab rebuilds a `FutureBuilder` that re-queries the database on every
/// rebuild, so a countdown driven from up there would hit SQLite once a second.
class TimerReadout extends StatefulWidget {
  const TimerReadout({super.key, required this.timer});

  final EntryTimer timer;

  @override
  State<TimerReadout> createState() => _TimerReadoutState();
}

class _TimerReadoutState extends State<TimerReadout> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
        const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = widget.timer;
    final expired = t.hasExpired;
    final paused = t.state == TimerState.paused;

    final colour = expired
        ? scheme.error
        : paused
            ? scheme.onSurfaceVariant
            : scheme.primary;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          expired
              ? Icons.alarm_on
              : paused
                  ? Icons.pause_circle_outline
                  : t.direction == TimerDirection.countDown
                      ? Icons.hourglass_bottom
                      : Icons.timer_outlined,
          size: 15,
          color: colour,
        ),
        const SizedBox(width: 4),
        Text(
          expired ? 'time up' : fmt.elapsed(t.display),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: colour,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (paused) ...[
          const SizedBox(width: 4),
          Text('paused',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}

/// What the host picks before a timer starts.
class TimerSetup {
  const TimerSetup({
    required this.direction,
    this.total,
    this.warnings = const [],
  });

  final TimerDirection direction;
  final Duration? total;
  final List<TimerWarning> warnings;
}

/// Asks for direction, length and warning points.
Future<TimerSetup?> showTimerSetup(
  BuildContext context, {
  required String personName,
  Duration remembered = const Duration(minutes: 8),
}) {
  return showModalBottomSheet<TimerSetup>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _TimerSetupSheet(
      personName: personName,
      remembered: remembered,
    ),
  );
}

class _TimerSetupSheet extends StatefulWidget {
  const _TimerSetupSheet({required this.personName, required this.remembered});

  final String personName;
  final Duration remembered;

  @override
  State<_TimerSetupSheet> createState() => _TimerSetupSheetState();
}

class _TimerSetupSheetState extends State<_TimerSetupSheet> {
  late TimerDirection _direction = TimerDirection.countDown;
  late Duration _total = widget.remembered;
  late List<TimerWarning> _warnings =
      EntryTimer.defaultWarningsFor(widget.remembered);

  /// Shortcuts, not the whole range — "Custom" below takes any length, down to
  /// seconds, because a turn at a bench is not always a round number of
  /// minutes.
  static const _lengthPresets = [
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 8),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 20),
  ];

  /// The presets, plus whatever the host typed if it is not already one.
  List<Duration> get _lengths => [
        ..._lengthPresets,
        if (!_lengthPresets.contains(_total)) _total,
      ];

  Future<void> _pickCustomLength() async {
    final picked = await askForDuration(
      context,
      title: 'Timer length',
      initial: _total,
      withSeconds: true,
      min: const Duration(seconds: 10),
      max: const Duration(hours: 4),
    );
    if (picked == null || !mounted) return;
    _setTotal(picked);
  }

  void _setTotal(Duration d) => setState(() {
        _total = d;
        // Regenerate defaults so the warnings always make sense for the new
        // length; anything the host added by hand is deliberately replaced
        // rather than left pointing past the end.
        _warnings = EntryTimer.defaultWarningsFor(d);
      });

  Future<void> _addWarning() async {
    final ceiling = _direction == TimerDirection.countDown
        ? _total
        : const Duration(minutes: 60);
    var at = Duration(seconds: (ceiling.inSeconds * 0.5).round());

    final picked = await showDialog<Duration>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Warn at'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(fmt.elapsed(at),
                  style: Theme.of(ctx).textTheme.headlineMedium),
              Slider(
                value: at.inSeconds.toDouble(),
                max: ceiling.inSeconds.toDouble(),
                divisions: (ceiling.inSeconds ~/ 10).clamp(1, 360),
                onChanged: (v) =>
                    setDialog(() => at = Duration(seconds: v.round())),
              ),
              Text(
                _direction == TimerDirection.countDown
                    ? 'Measured from the start, so ${fmt.elapsed(at)} on an '
                        '${fmt.elapsed(_total)} timer leaves '
                        '${fmt.elapsed(_total - at)}.'
                    : 'Measured from the start.',
                style: Theme.of(ctx).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            // The slider moves in ten-second steps, which is fine for placing
            // a warning roughly but cannot hit an exact point. Typing can.
            TextButton(
              onPressed: () async {
                final typed = await askForDuration(
                  ctx,
                  title: 'Warn at',
                  initial: at,
                  withSeconds: true,
                  min: const Duration(seconds: 1),
                  max: ceiling,
                );
                if (typed != null && ctx.mounted) Navigator.pop(ctx, typed);
              },
              child: const Text('Type it'),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, at),
                child: const Text('Add')),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() {
      _warnings = [
        ..._warnings,
        TimerWarning(at: picked, pings: _warnings.isEmpty ? 1 : 2),
      ]..sort((a, b) => a.at.compareTo(b.at));
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final countingDown = _direction == TimerDirection.countDown;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Time ${widget.personName}',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              SegmentedButton<TimerDirection>(
                segments: const [
                  ButtonSegment(
                    value: TimerDirection.countDown,
                    icon: Icon(Icons.hourglass_bottom, size: 18),
                    label: Text('Count down'),
                  ),
                  ButtonSegment(
                    value: TimerDirection.countUp,
                    icon: Icon(Icons.timer_outlined, size: 18),
                    label: Text('Count up'),
                  ),
                ],
                selected: {_direction},
                onSelectionChanged: (s) =>
                    setState(() => _direction = s.first),
              ),
              const SizedBox(height: 6),
              Text(
                countingDown
                    ? 'Runs out after the length you set.'
                    : 'Measures how long they take. Never ends on its own.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (countingDown) ...[
                const SizedBox(height: 18),
                Text('Length', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final d in _lengths)
                      ChoiceChip(
                        label: Text(fmt.elapsed(d)),
                        selected: _total == d,
                        onSelected: (_) => _setTotal(d),
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Custom'),
                      onPressed: _pickCustomLength,
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text('Warnings',
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                  TextButton.icon(
                    onPressed: _addWarning,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add'),
                  ),
                ],
              ),
              if (_warnings.isEmpty)
                Text('No warnings — it will just end.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant))
              else
                for (final w in _warnings)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                        w.pings > 1
                            ? Icons.notifications_active
                            : Icons.notifications_none,
                        size: 20),
                    title: Text(
                      countingDown
                          ? '${fmt.elapsed(w.at)} — ${fmt.elapsed(_total - w.at)} left'
                          : 'at ${fmt.elapsed(w.at)}',
                    ),
                    subtitle:
                        Text(w.pings > 1 ? 'two pings' : 'one ping'),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () =>
                          setState(() => _warnings.remove(w)),
                    ),
                  ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => Navigator.pop(
                  context,
                  TimerSetup(
                    direction: _direction,
                    total: countingDown ? _total : null,
                    warnings: _warnings,
                  ),
                ),
                icon: const Icon(Icons.play_arrow),
                label: Text(countingDown
                    ? 'Start ${_total.inMinutes} min'
                    : 'Start stopwatch'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
