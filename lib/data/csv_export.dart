import '../common/time_format.dart' as fmt;
import 'history_repository.dart';

/// Turns a [SessionReport] into a CSV file for a spreadsheet.
///
/// Written by hand rather than using a package. The only tricky part is
/// escaping, which is about twenty lines, and doing it ourselves means the
/// guard against spreadsheet formulas is right there to see.
class CsvExport {
  const CsvExport();

  /// Columns: name, when they joined, whether they left or were removed, then
  /// one column per check with the time it ran.
  String render(SessionReport report) {
    final rows = <List<String>>[
      [
        'Name',
        'First joined',
        'Left or removed',
        for (final c in report.checks) '${c.label} (${fmt.clockTime(c.at)})',
        'Passed',
        'Missed',
      ],
      for (final a in report.attendees)
        [
          a.displayName,
          fmt.clockTime(a.firstJoined),
          _departure(a),
          for (final c in report.checks) a.outcomeFor(c).csv,
          '${a.passes}',
          '${a.fails}',
        ],
    ];

    final lines = rows.map((r) => r.map(_field).join(',')).toList();

    // The queue table goes below the attendance table with a blank line
    // between. A CSV can't have separate sheets, so this is the closest we
    // can get in one file.
    for (final queue in report.queues) {
      if (queue.entries.isEmpty) continue;
      lines
        ..add('')
        ..add(_field('QUEUE: ${queue.name}'))
        ..add(['Name', 'Position', 'Time', 'Outcome'].map(_field).join(','));
      for (final e in queue.entries) {
        lines.add([
          e.displayName,
          e.position?.toString() ?? '',
          e.took == null ? '' : fmt.elapsed(e.took!),
          e.outcome,
        ].map(_field).join(','));
      }
    }

    return lines.join('\r\n');
  }

  /// Names the file after the session, so you can tell what it is without
  /// opening it.
  ///
  /// Only strips characters a filesystem actually rejects. An earlier version
  /// removed everything outside A-Z, which wiped out non-English titles.
  String filename(SessionReport report) {
    final safe = report.summary.title
        .replaceAll(RegExp(r'[/\\:*?"<>|]'), '')
        .replaceAll(RegExp(r'[\x00-\x1f]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // Windows won't allow these as filenames, whatever the extension.
    const reserved = {
      'CON', 'PRN', 'AUX', 'NUL',
      'COM1', 'COM2', 'COM3', 'COM4', 'LPT1', 'LPT2', 'LPT3',
    };

    final usable = safe.isEmpty || reserved.contains(safe.toUpperCase())
        ? 'session'
        : (safe.length > 80 ? safe.substring(0, 80).trim() : safe);
    return '$usable.csv';
  }


  /// Why somebody is no longer here, and when.
  ///
  /// If both happened, we report the removal, since that's the host's
  /// decision and more useful to know.
  static String _departure(AttendeeReport a) {
    if (a.wasRemoved) {
      return 'removed '
          '${fmt.clockTime(DateTime.fromMillisecondsSinceEpoch(a.removedAt!))}';
    }
    if (a.hasLeft) {
      return 'left '
          '${fmt.clockTime(DateTime.fromMillisecondsSinceEpoch(a.leftAt!))}';
    }
    return '';
  }

  /// Wraps anything with a comma, quote or line break in quotes, doubling any
  /// quotes inside it.
  ///
  /// Also puts an apostrophe in front of a leading `=`, `+`, `-` or `@`.
  /// Spreadsheets treat those as the start of a formula, so without this
  /// someone could pick a name that runs when the host opens the file.
  static String _field(String raw) {
    var value = raw;
    if (value.isNotEmpty && '=+-@'.contains(value[0])) {
      value = "'$value";
    }
    if (value.contains(RegExp('[",\r\n]'))) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
