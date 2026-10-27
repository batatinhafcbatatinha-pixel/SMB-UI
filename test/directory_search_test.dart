import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smb_media_viewer/app_theme.dart';
import 'package:smb_media_viewer/main.dart';
import 'package:smb_media_viewer/utils/name_search.dart';

void main() {
  test('name search ignores case, accents and surrounding spaces', () {
    expect(
      normalizeSearchName('  FÉRIAS São João.MP4  '),
      'ferias sao joao.mp4',
    );
    expect(normalizeSearchName('ação'), 'acao');
  });

  testWidgets(
    'search filters folders and files, clears and resets on navigation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('smb_channel');
      var requests = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'listDirectory') return null;
        requests++;
        if ((call.arguments as Map)['path'].toString().contains('ferias')) {
          return [];
        }
        return [
          {
            'name': 'Férias',
            'path': '/ferias/',
            'is_dir': true,
            'is_media': false,
          },
          {
            'name': 'Projetos',
            'path': '/projetos/',
            'is_dir': true,
            'is_media': false,
          },
          {
            'name': 'Roteiro férias.txt',
            'path': '/roteiro.txt',
            'is_dir': false,
            'is_media': false,
          },
        ];
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final locale = AppLocaleController();
      addTearDown(locale.dispose);
      await tester.pumpWidget(
        AppLocaleScope(
          notifier: locale,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const DirectoryScreen(
              ip: 'test',
              share: 'media',
              username: '',
              password: '',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Roteiro férias.txt'), findsOneWidget);
      await tester.tap(find.byTooltip('Search names'));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('directory_search'));
      await tester.enterText(search, 'FERIAS');
      await tester.pumpAndSettle();
      expect(find.text('Férias'), findsOneWidget);
      expect(find.text('Roteiro férias.txt'), findsOneWidget);
      expect(find.text('Projetos'), findsNothing);
      expect(
        tester
            .widget<GridView>(find.byType(GridView))
            .childrenDelegate
            .estimatedChildCount,
        2,
      );
      expect(requests, 1, reason: 'typing must not issue network requests');
      await tester.enterText(search, 'missing');
      await tester.pumpAndSettle();
      expect(find.text('No matching names'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Projetos'), findsOneWidget);
      await tester.enterText(search, 'ferias');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Férias'));
      await tester.pumpAndSettle();
      expect(find.text('media/ferias/'), findsOneWidget);
      expect(search, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('home fits a narrow phone with larger text', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final locale = AppLocaleController();
    addTearDown(locale.dispose);
    await tester.pumpWidget(
      AppLocaleScope(
        notifier: locale,
        child: MaterialApp(
          theme: buildAppTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: const MainScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.radar_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
