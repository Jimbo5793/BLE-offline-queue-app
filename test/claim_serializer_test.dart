import 'package:beaconq/logic/claim_serializer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('jobs run one at a time, in the order they were queued', () async {
    final serializer = ClaimSerializer();
    final log = <String>[];

    Future<int> job(int n) async {
      log.add('start $n');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      log.add('end $n');
      return n;
    }

    final results = await Future.wait([
      serializer.run(() => job(1)),
      serializer.run(() => job(2)),
      serializer.run(() => job(3)),
    ]);

    expect(results, [1, 2, 3]);
    expect(log, [
      'start 1',
      'end 1',
      'start 2',
      'end 2',
      'start 3',
      'end 3',
    ]);
    expect(serializer.pending, 0);
  });

  test('a failing job does not block the jobs behind it', () async {
    final serializer = ClaimSerializer();

    final failing = serializer.run<int>(() async => throw StateError('boom'));
    final next = serializer.run(() async => 42);

    await expectLater(failing, throwsStateError);
    expect(await next, 42);
  });

  test('concurrent counters never hand out the same number', () async {
    final serializer = ClaimSerializer();
    var counter = 0;

    Future<int> nextNumber() async {
      final read = counter;
      await Future<void>.delayed(Duration.zero);
      counter = read + 1;
      return counter;
    }

    final numbers = await Future.wait(
      List.generate(30, (_) => serializer.run(nextNumber)),
    );

    expect(numbers.toSet().length, 30);
    expect(numbers, List.generate(30, (i) => i + 1));
  });
}
