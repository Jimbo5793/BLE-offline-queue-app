import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../common/time_format.dart' as fmt;
import '../data/csv_export.dart';
import '../data/database.dart';
import '../data/history_repository.dart';
import '../identity/identity.dart';

/// Past sessions, newest first.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.identity});

  final LocalIdentity identity;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  AppDatabase? _adb;
  List<SessionSummary> _sessions = const [];
  bool _loading = true;
  String? _error;

  List<SessionSummary> get _active =>
      _sessions.where((s) => !s.isFinished).toList();
  List<SessionSummary> get _past =>
      _sessions.where((s) => s.isFinished).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _adb?.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final adb = await AppDatabase.open(path: p.join(dir.path, 'queue.db'));
      final sessions =
          await HistoryRepository(adb.db).listSessions(hostId: widget.identity.userId);
      if (!mounted) return;
      setState(() {
        _adb = adb;
        _sessions = sessions;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _archive(SessionSummary session) async {
    await HistoryRepository(_adb!.db).archiveSession(session.id);
    await _reload();
  }

  Future<void> _delete(SessionSummary session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${session.title}"?'),
        content: Text(
          'This permanently removes the session and everything recorded '
          'during it — ${session.attendeeCount} '
          '${session.attendeeCount == 1 ? 'attendee' : 'attendees'}'
          '${session.checkCount == 0 ? '' : ' and ${session.checkCount} attendance ${session.checkCount == 1 ? 'check' : 'checks'}'}. '
          'This cannot be undone.\n\nExport it first if you still need the '
          'register. Archiving keeps everything and just files it away.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await HistoryRepository(_adb!.db).deleteSession(session.id);
    await _reload();
  }

  Future<void> _reload() async {
    final sessions = await HistoryRepository(_adb!.db)
        .listSessions(hostId: widget.identity.userId);
    if (mounted) setState(() => _sessions = sessions);
  }

  Widget _tile(SessionSummary s, {required bool active}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        color: active ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
        child: ListTile(
          title: Text(s.title),
          subtitle: Text([
            _dateLabel(s.started),
            if (s.duration != null)
              fmt.approxDuration(s.duration!)
            else
              'never ended',
            '${s.attendeeCount} attended',
            if (s.checkCount > 0) '${s.checkCount} checks',
          ].join(' · ')),
          trailing: PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'open') {
                await Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) =>
                      SessionReportScreen(db: _adb!, sessionId: s.id),
                ));
                await _reload();
              } else if (v == 'archive') {
                await _archive(s);
              } else if (v == 'delete') {
                await _delete(s);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'open',
                  child: ListTile(
                      leading: Icon(Icons.table_chart_outlined),
                      title: Text('View and export'))),
              if (active)
                const PopupMenuItem(
                    value: 'archive',
                    child: ListTile(
                        leading: Icon(Icons.inventory_2_outlined),
                        title: Text('Archive'),
                        subtitle: Text('Keeps everything'))),
              const PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Delete'),
                      subtitle: Text('Cannot be undone'))),
            ],
          ),
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => SessionReportScreen(db: _adb!, sessionId: s.id),
            ));
            await _reload();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Session history')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, textAlign: TextAlign.center),
                    ),
                  )
                : _sessions.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.history,
                                  size: 56, color: scheme.onSurfaceVariant),
                              const SizedBox(height: 16),
                              Text('No sessions yet',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 6),
                              Text(
                                'Sessions you host appear here, with their '
                                'attendance ready to export.',
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                        children: [
                          if (_active.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                              child: Row(
                                children: [
                                  Icon(Icons.play_circle_outline,
                                      size: 18, color: scheme.primary),
                                  const SizedBox(width: 8),
                                  Text('Still open',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(color: scheme.primary)),
                                ],
                              ),
                            ),
                            for (final s in _active) _tile(s, active: true),
                            const SizedBox(height: 18),
                          ],
                          if (_past.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                              child: Text('Finished',
                                  style:
                                      Theme.of(context).textTheme.titleSmall),
                            ),
                          for (final s in _past) _tile(s, active: false),
                        ],
                      ),
      ),
    );
  }

  static String _dateLabel(DateTime d) => fmt.dateAndTime(d);
}

/// The attendance grid for one session, plus the CSV export.
class SessionReportScreen extends StatefulWidget {
  const SessionReportScreen({
    super.key,
    required this.db,
    required this.sessionId,
  });

  final AppDatabase db;
  final String sessionId;

  @override
  State<SessionReportScreen> createState() => _SessionReportScreenState();
}

class _SessionReportScreenState extends State<SessionReportScreen> {
  SessionReport? _report;
  bool _loading = true;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final report =
        await HistoryRepository(widget.db.db).report(widget.sessionId);
    if (mounted) {
      setState(() {
        _report = report;
        _loading = false;
      });
    }
  }

  Future<void> _export() async {
    final report = _report;
    if (report == null) return;
    setState(() => _exporting = true);
    try {
      const csv = CsvExport();
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, csv.filename(report)));
      await file.writeAsString(csv.render(report));

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: '${report.summary.title} attendance',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final report = _report;

    return Scaffold(
      appBar: AppBar(
        title: Text(report?.summary.title ?? 'Session'),
        actions: [
          if (report != null)
            IconButton(
              tooltip: 'Export CSV',
              onPressed: _exporting ? null : _export,
              icon: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.ios_share),
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : report == null
                ? const Center(child: Text('That session is gone.'))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      Text(
                        '${report.presentCount} attended'
                        '${report.checks.isEmpty ? '' : ' · ${report.checks.length} checks'}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (report.patchy.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${report.patchy.length} missed at least one check',
                          style: TextStyle(color: scheme.error),
                        ),
                      ],
                      const SizedBox(height: 14),
                      AttendanceGrid(report: report),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _exporting ? null : _export,
                        icon: const Icon(Icons.ios_share),
                        label: const Text('Export as CSV'),
                      ),
                    ],
                  ),
      ),
    );
  }
}

/// Attendees down the side, checks across the top.
///
/// Scrolls horizontally, because a long session can have more checks than fit
/// on a phone and a squashed grid is worse than a scrolled one.
class AttendanceGrid extends StatelessWidget {
  const AttendanceGrid({super.key, required this.report});

  final SessionReport report;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (report.attendees.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Text('Nobody joined this session.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 44,
        dataRowMinHeight: 40,
        dataRowMaxHeight: 52,
        columnSpacing: 18,
        columns: [
          const DataColumn(label: Text('Name')),
          const DataColumn(label: Text('Joined')),
          for (final c in report.checks)
            DataColumn(
              label: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(c.label,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(_time(c.at),
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
        ],
        rows: [
          for (final a in report.attendees)
            DataRow(
              cells: [
                DataCell(Row(
                  children: [
                    Text(a.displayName,
                        style: TextStyle(
                          decoration:
                              a.wasRemoved ? TextDecoration.lineThrough : null,
                          color: a.wasRemoved ? scheme.onSurfaceVariant : null,
                        )),
                    if (a.wasRemoved) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.person_off_outlined,
                          size: 14, color: scheme.onSurfaceVariant),
                    ],
                  ],
                )),
                DataCell(Text(_time(a.firstJoined))),
                for (final c in report.checks)
                  DataCell(_OutcomeChip(outcome: a.outcomeFor(c))),
              ],
            ),
        ],
      ),
    );
  }

  static String _time(DateTime d) => fmt.clockTime(d);
}

class _OutcomeChip extends StatelessWidget {
  const _OutcomeChip({required this.outcome});

  final CheckOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (outcome) {
      CheckOutcome.pass =>
        Icon(Icons.check_circle, size: 20, color: scheme.primary),
      CheckOutcome.fail =>
        Icon(Icons.cancel_outlined, size: 20, color: scheme.error),
      CheckOutcome.notYetJoined => Text('–',
          style: TextStyle(color: scheme.onSurfaceVariant)),
      CheckOutcome.noDevice => Text('n/a',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
    };
  }
}
