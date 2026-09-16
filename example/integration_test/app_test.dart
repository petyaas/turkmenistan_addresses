import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:turkmenistan_addresses_example/main.dart';

/// A run through the app on a device: type a query, open a street, open a
/// house. The pauses give each screen time to reach a screenshot taken
/// from outside with `xcrun simctl io booted screenshot`.
const _pause = Duration(seconds: 3);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('search, street, house', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pumpAndSettle();

    // The database is read from disk — wait for the spinner to go.
    for (var i = 0; i < 40; i++) {
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('settlements'), findsOneWidget);
    await tester.pump(_pause);

    // 1. Type the query the way a person would.
    await tester.enterText(find.byType(SearchBar), 'par 2/4 1');
    await tester.pumpAndSettle();
    expect(find.text('Parahat 2/4, 1'), findsWidgets);
    await tester.pump(_pause);

    // 2. Find the street and open the houses on it.
    //
    // «Parahat 2/4» is three things at once: a neighbourhood, a street and
    // fifteen houses on it, so the tile is picked by its subtitle rather
    // than its name — by name the neighbourhood comes first.
    await tester.enterText(find.byType(SearchBar), 'parahat 2/4');
    await tester.pumpAndSettle();
    final street = find.ancestor(
      of: find.textContaining('street · Aşgabat'),
      matching: find.byType(ListTile),
    );
    expect(street, findsOneWidget);
    await tester.pump(_pause);

    await tester.tap(street);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Parahat 2/4'), findsOneWidget);
    expect(find.textContaining('15 houses'), findsOneWidget);
    await tester.pump(_pause);

    // 3. Open the house card.
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(find.text('Street'), findsOneWidget);
    expect(find.textContaining('Within 150 m'), findsOneWidget);
    await tester.pump(_pause);
  });
}
