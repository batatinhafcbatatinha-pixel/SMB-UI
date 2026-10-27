import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smb_media_viewer/main.dart';

void main() {
  testWidgets('late folder response cannot overwrite parent after back', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final slowFolder = Completer<List<dynamic>>();
    const channel = MethodChannel('smb_channel');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'listDirectory') {
            if ((call.arguments as Map)['path'].toString().contains('slow')) {
              return slowFolder.future;
            }
            return [
              {
                'name': 'slow',
                'path': '/slow/',
                'is_dir': true,
                'is_media': false,
              },
            ];
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final locale = AppLocaleController();
    addTearDown(locale.dispose);
    await tester.pumpWidget(
      AppLocaleScope(
        notifier: locale,
        child: const MaterialApp(
          home: DirectoryScreen(
            ip: 'test',
            share: 'media',
            username: '',
            password: '',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('slow'));
    await tester.pumpAndSettle();
    expect(find.text('media/slow/'), findsOneWidget);
    final scope = tester.widget<PopScope<dynamic>>(
      find.byType(PopScope<dynamic>).first,
    );
    scope.onPopInvokedWithResult!(false, null);
    await tester.pumpAndSettle();
    slowFolder.complete([
      {
        'name': 'stale',
        'path': '/slow/stale',
        'is_dir': true,
        'is_media': false,
      },
    ]);
    await tester.pumpAndSettle();
    expect(find.text('media/'), findsOneWidget);
    expect(find.text('stale'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
