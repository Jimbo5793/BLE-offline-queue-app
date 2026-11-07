import 'dart:async';

/// Runs queue changes one at a time.
///
/// Database calls are async, so without this two claims could both read the
/// arrival counter before either saves it, and two people would get the same
/// number. Each job waits for the previous one to finish.
class ClaimSerializer {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  /// How many jobs are waiting or running. Used in tests.
  int get pending => _pending;

  Future<T> run<T>(Future<T> Function() job) {
    _pending++;
    final gate = Completer<void>();
    final previous = _tail;
    // This future must never fail, or one broken job would block all the
    // ones queued behind it.
    _tail = gate.future;

    return previous.then((_) => job()).whenComplete(() {
      _pending--;
      gate.complete();
    });
  }

  /// Completes when everything queued has finished.
  Future<void> get idle => _tail;
}
