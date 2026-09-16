import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:turkmenistan_addresses_example/main.dart';

/// Прогон по приложению на устройстве: набрать запрос, открыть улицу,
/// открыть дом. Паузы нужны, чтобы экраны успевали попасть в скриншот,
/// который снимается снаружи через `xcrun simctl io booted screenshot`.
const _pause = Duration(seconds: 3);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('поиск, улица, дом', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pumpAndSettle();

    // База грузится с диска — дожидаемся, пока пропадёт индикатор.
    for (var i = 0; i < 40; i++) {
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('населённых пунктов'), findsOneWidget);
    await tester.pump(_pause);

    // 1. Набираем запрос так, как его набирал бы человек.
    await tester.enterText(find.byType(SearchBar), 'par 2/4 1');
    await tester.pumpAndSettle();
    expect(find.text('Parahat 2/4, 1'), findsWidgets);
    await tester.pump(_pause);

    // 2. Ищем улицу и открываем список домов на ней.
    //
    // «Parahat 2/4» — это сразу и микрорайон, и улица, и пятнадцать домов
    // на ней, поэтому плитку выбираем по подписи, а не по названию:
    // по названию первым идёт микрорайон.
    await tester.enterText(find.byType(SearchBar), 'parahat 2/4');
    await tester.pumpAndSettle();
    final street = find.ancestor(
      of: find.textContaining('улица · Aşgabat'),
      matching: find.byType(ListTile),
    );
    expect(street, findsOneWidget);
    await tester.pump(_pause);

    await tester.tap(street);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Parahat 2/4'), findsOneWidget);
    expect(find.textContaining('15 домов'), findsOneWidget);
    await tester.pump(_pause);

    // 3. Открываем карточку дома.
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(find.text('Улица'), findsOneWidget);
    expect(find.textContaining('Рядом'), findsOneWidget);
    await tester.pump(_pause);
  });
}
