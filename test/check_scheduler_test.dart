import 'dart:math';

import 'package:beaconq/logic/check_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const scheduler = CheckScheduler.defaults;
  const hour = Duration(minutes: 60);

  test('checks are in order, at least 10 minutes apart', () {
    for (var seed = 0; seed < 50; seed++) {
      final plan = scheduler.plan(length: hour, count: 4, rng: Random(seed));
      expect(plan.length, 4);
      for (var i = 1; i < plan.length; i++) {
        expect(plan[i] - plan[i - 1],
            greaterThanOrEqualTo(const Duration(minutes: 10)));
      }
    }
  });

  test('no check in the first or last 5 minutes', () {
    for (var seed = 0; seed < 50; seed++) {
      final plan = scheduler.plan(length: hour, count: 5, rng: Random(seed));
      expect(plan.first, greaterThanOrEqualTo(const Duration(minutes: 5)));
      expect(plan.last, lessThanOrEqualTo(const Duration(minutes: 55)));
    }
  });

  test('the same seed gives the same plan', () {
    final a = scheduler.plan(length: hour, count: 3, rng: Random(9));
    final b = scheduler.plan(length: hour, count: 3, rng: Random(9));
    expect(a, equals(b));
  });

  test('short sessions get fewer checks instead of squeezed ones', () {
    expect(scheduler.maxChecksFor(const Duration(minutes: 20)), 2);
    expect(
      scheduler.plan(length: const Duration(minutes: 20), count: 5).length,
      2,
    );
    expect(scheduler.plan(length: const Duration(minutes: 10), count: 3),
        isEmpty);
  });

  test('open-ended sessions wait 10 to 25 minutes between checks', () {
    final rng = Random(4);
    for (var i = 0; i < 100; i++) {
      final gap = scheduler.nextGap(rng);
      expect(gap, greaterThanOrEqualTo(const Duration(minutes: 10)));
      expect(gap, lessThanOrEqualTo(const Duration(minutes: 25)));
    }
  });
}
