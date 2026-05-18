import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:luban_imager/main.dart';

void main() {
  testWidgets('uses English app name by default', (tester) async {
    await tester.pumpWidget(const LubanImagerApp());

    expect(find.text(AppName.english), findsOneWidget);
    expect(find.text('选择文件'), findsWidgets);
    expect(find.text('从相册选择'), findsOneWidget);
  });

  testWidgets('uses Chinese app name for Chinese locale', (tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [
      Locale('zh', 'CN'),
    ];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

    await tester.pumpWidget(const LubanImagerApp());

    expect(find.text(AppName.chinese), findsOneWidget);
    expect(find.text(AppName.english), findsNothing);
    expect(find.text('选择文件'), findsWidgets);
    expect(find.text('从相册选择'), findsOneWidget);
  });
}
