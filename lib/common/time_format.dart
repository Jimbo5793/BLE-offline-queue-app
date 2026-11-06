/// Time and duration formatting, in one place.
///
/// The same `HH:MM` helper had been copied privately into four files. The
/// timer needs `m:ss` as well, so rather than add a fifth copy they all point
/// here.
library;

String two(int n) => n.toString().padLeft(2, '0');

/// Clock time, `14:23`.
String clockTime(DateTime d) => '${two(d.hour)}:${two(d.minute)}';

/// Date and time, `28/9/2026 14:23`.
String dateAndTime(DateTime d) =>
    '${d.day}/${d.month}/${d.year} ${clockTime(d)}';

/// Elapsed time as `m:ss`, or `h:mm:ss` once it passes an hour.
///
/// Used for the running timer and for the exported result, so what the host
/// watched counting down is exactly what lands in the spreadsheet.
String elapsed(Duration d) {
  final total = d.isNegative ? Duration.zero : d;
  final hours = total.inHours;
  final minutes = total.inMinutes.remainder(60);
  final seconds = total.inSeconds.remainder(60);
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '$minutes:${two(seconds)}';
}

/// A rough duration for a summary line, `90 min` or `1 h 30 min`.
String approxDuration(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  return minutes == 0 ? '$hours h' : '$hours h $minutes min';
}
