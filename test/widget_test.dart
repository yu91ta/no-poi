import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ppp_hackthon/main.dart';

void main() {
  testWidgets('NoPoi opens choice screen', (WidgetTester tester) async {
    await tester.pumpWidget(const NoPoiApp());

    expect(find.text('NoPoi'), findsOneWidget);
    expect(find.text('タスク管理'), findsOneWidget);
    expect(find.text('支出管理'), findsOneWidget);
    expect(find.text('メイン画面'), findsOneWidget);
  });

  testWidgets('main screen opens from choice screen on phone layout', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const NoPoiApp());

    await tester.tap(find.byIcon(Icons.home_outlined));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Task'), findsOneWidget);
  });
}
