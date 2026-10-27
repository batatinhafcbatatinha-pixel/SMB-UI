import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smb_media_viewer/app_theme.dart';
import 'package:smb_media_viewer/main.dart';

void main() {
  testWidgets(
    'each folder restores sort and favorites after navigation and app recreation',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'favorites:test:media': ['/a/', '/b/'],
      });
      const channel = MethodChannel('smb_channel');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'listDirectory') return null;
        final path = (call.arguments as Map)['path'];
        if (path != '/' && path != '') return [];
        return [
          for (final name in ['a', 'b'])
            {
              'name': name.toUpperCase(),
              'path': '/$name/',
              'is_dir': true,
              'is_media': false,
            },
        ];
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final locale = AppLocaleController();
      addTearDown(locale.dispose);

      Future<void> launch() async {
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
      }

      Future<void> chooseSort(String label) async {
        final chip = find.widgetWithText(ChoiceChip, label);
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
      }

      Future<void> toggleFavorites() async {
        await tester.ensureVisible(find.byType(FilterChip));
        await tester.tap(find.byType(FilterChip));
        await tester.pumpAndSettle();
      }

      void expectFilters(String label, bool favorites) {
        expect(
          tester
              .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label))
              .selected,
          isTrue,
        );
        expect(
          tester.widget<FilterChip>(find.byType(FilterChip)).selected,
          favorites,
        );
      }

      Future<void> back() async {
        tester
            .widget<PopScope<dynamic>>(find.byType(PopScope<dynamic>).first)
            .onPopInvokedWithResult!(false, null);
        await tester.pumpAndSettle();
      }

      Future<void> open(String name) async {
        await tester.tap(find.text(name));
        await tester.pumpAndSettle();
      }

      await launch();
      await chooseSort('Largest Size');
      await toggleFavorites();
      await open('A');
      expectFilters('Name', false);
      await chooseSort('Most Recent');
      await chooseSort('Longest Duration');
      await toggleFavorites();
      await back();
      expectFilters('Largest Size', true);
      await open('B');
      expectFilters('Name', false);
      await back();
      await open('A');
      expectFilters('Longest Duration', true);

      // Destroy all screen state and reload only values written to preferences.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      final persisted = {
        for (final key in prefs.getKeys()) key: prefs.get(key)!,
      };
      SharedPreferences.setMockInitialValues(persisted);
      await launch();
      expectFilters('Largest Size', true);
      await open('A');
      expectFilters('Longest Duration', true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
