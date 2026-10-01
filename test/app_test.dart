import 'package:flutter_test/flutter_test.dart';
import 'package:beaconq/main.dart';

void main() {
  testWidgets('app shell shows the BeaconQ placeholder', (tester) async {
    await tester.pumpWidget(const BeaconQApp());
    expect(find.text('BeaconQ'), findsOneWidget);
  });
}
