import 'dart:math';

import 'package:beaconq/transport/backoff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const backoff = Backoff.defaults;
  Future<void> noWait(Duration d) async {}

  test('the first attempt never waits', () {
    expect(backoff.delayFor(1), Duration.zero);
  });

  test('every retry waits between 200 and 1500 ms', () {
    final rng = Random(7);
    for (var attempt = 2; attempt <= 10; attempt++) {
      for (var i = 0; i < 50; i++) {
        final ms = backoff.delayFor(attempt, rng).inMilliseconds;
        expect(ms, inInclusiveRange(200, 1500));
      }
    }
  });

  test('jitter spreads two clients apart', () {
    final a = Random(1);
    final b = Random(2);
    final delaysA = [for (var i = 0; i < 20; i++) backoff.delayFor(4, a)];
    final delaysB = [for (var i = 0; i < 20; i++) backoff.delayFor(4, b)];
    expect(delaysA, isNot(equals(delaysB)));
  });

  test('retries after null or an error, then returns the result', () async {
    var calls = 0;
    final result = await backoff.run<String>((attempt) async {
      calls++;
      if (attempt == 1) return null;
      if (attempt == 2) throw StateError('busy');
      return 'ok';
    }, sleep: noWait);

    expect(result, 'ok');
    expect(calls, 3);
  });

  test('gives up with null after the fifth attempt', () async {
    var calls = 0;
    final result = await backoff.run<String>((attempt) async {
      calls++;
      return null;
    }, sleep: noWait);

    expect(result, isNull);
    expect(calls, 5);
  });
}
