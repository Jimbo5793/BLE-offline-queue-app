import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'time_format.dart' as fmt;

/// Asks for a duration by typing it.
///
/// Every length in this app used to come from a fixed list of chips, which
/// cannot match a real timetable: a 45-minute tutorial, a 25-minute lab slot
/// or a 90-second turn had no way in at all. The chips are still there as
/// shortcuts for the common cases — this is the way out of them.
///
/// Returns null if the host cancels, so a caller can leave its current value
/// alone rather than having to guess a fallback.
Future<Duration?> askForDuration(
  BuildContext context, {
  required String title,
  Duration? initial,
  bool withSeconds = false,
  Duration min = const Duration(minutes: 1),
  Duration max = const Duration(hours: 24),
}) =>
    showDialog<Duration>(
      context: context,
      builder: (_) => DurationDialog(
        title: title,
        initial: initial,
        withSeconds: withSeconds,
        min: min,
        max: max,
      ),
    );

/// The dialog [askForDuration] shows. Public only so a widget test can pump it
/// directly instead of driving it through a host screen.
class DurationDialog extends StatefulWidget {
  const DurationDialog({
    super.key,
    required this.title,
    this.initial,
    this.withSeconds = false,
    this.min = const Duration(minutes: 1),
    this.max = const Duration(hours: 24),
  });

  final String title;
  final Duration? initial;

  /// Whether to offer a seconds field as well. A session length is whole
  /// minutes; a per-person timer often is not.
  final bool withSeconds;

  final Duration min;
  final Duration max;

  @override
  State<DurationDialog> createState() => _DurationDialogState();
}

class _DurationDialogState extends State<DurationDialog> {
  late final TextEditingController _minutes;
  late final TextEditingController _seconds;
  String? _error;

  @override
  void initState() {
    super.initState();
    final start = widget.initial;
    _minutes = TextEditingController(
        text: start == null ? '' : '${start.inMinutes}');
    _seconds = TextEditingController(
        text: start == null ? '' : '${start.inSeconds.remainder(60)}');
  }

  @override
  void dispose() {
    _minutes.dispose();
    _seconds.dispose();
    super.dispose();
  }

  String _describe(Duration d) =>
      widget.withSeconds ? fmt.elapsed(d) : fmt.approxDuration(d);

  /// Parses the fields, or sets [_error] and returns null.
  Duration? _read() {
    final minutesText = _minutes.text.trim();
    final secondsText = _seconds.text.trim();

    if (minutesText.isEmpty && secondsText.isEmpty) {
      _error = 'Enter how long.';
      return null;
    }

    final minutes = minutesText.isEmpty ? 0 : int.tryParse(minutesText);
    final seconds = secondsText.isEmpty ? 0 : int.tryParse(secondsText);
    if (minutes == null || seconds == null) {
      _error = 'Numbers only.';
      return null;
    }
    if (widget.withSeconds && seconds > 59) {
      _error = 'Seconds go up to 59 — add to the minutes instead.';
      return null;
    }

    final total = Duration(
        minutes: minutes, seconds: widget.withSeconds ? seconds : 0);

    if (total < widget.min) {
      _error = 'At least ${_describe(widget.min)}.';
      return null;
    }
    if (total > widget.max) {
      _error = 'At most ${_describe(widget.max)}.';
      return null;
    }

    _error = null;
    return total;
  }

  void _submit() {
    final value = _read();
    if (value == null) {
      setState(() {});
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _minutes,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  decoration: const InputDecoration(
                    labelText: 'Minutes',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              if (widget.withSeconds) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _seconds,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    decoration: const InputDecoration(
                      labelText: 'Seconds',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _error ??
                'Anything from ${_describe(widget.min)} to '
                    '${_describe(widget.max)}.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _error == null
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.error,
                ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Set')),
      ],
    );
  }
}
