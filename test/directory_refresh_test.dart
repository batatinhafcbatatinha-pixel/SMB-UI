import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smb_media_viewer/main.dart';
import 'package:smb_media_viewer/utils/thumbnail_events.dart';

void main() {
  testWidgets(
    'refresh stays in folder and preserves thumbnails, filters and search',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'favorites:refresh:media': ['/inside/keep.txt'],
      });
      final paths = <String>[];
      Completer<List<dynamic>>? refresh;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('smb_channel');
      Map<String, dynamic> file(String name) => {
        'name': name,
        'path': '/inside/$name',
        'is_dir': false,
        'is_media': false,
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'listDirectory') return null;
        final path = (call.arguments as Map)['path'] as String;
        paths.add(path);
        if (path == '/') {
          return [
            {'name': 'Inside', 'path': '/inside/', 'is_dir': true},
          ];
        }
        if (refresh != null) return refresh.future;
        return [file('keep.txt'), file('removed.txt')];
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final locale = AppLocaleController();
      addTearDown(locale.dispose);
      await tester.pumpWidget(
        AppLocaleScope(
          notifier: locale,
          child: const MaterialApp(
            home: DirectoryScreen(
              ip: 'refresh',
              share: 'media',
              username: '',
              password: '',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inside'));
      await tester.pumpAndSettle();
      final sort = find.widgetWithText(ChoiceChip, 'Longest Duration');
      await tester.ensureVisible(sort);
      await tester.tap(sort);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(FilterChip));
      await tester.tap(find.byType(FilterChip));
      await tester.pumpAndSettle();
      emitThumbnailReady(
        '/inside/keep.txt',
        'existing-thumb.jpg',
        duration: 42,
      );
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.byTooltip('Search names'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('directory_search')),
        'keep',
      );
      await tester.pumpAndSettle();
      refresh = Completer<List<dynamic>>();
      final button = find.byKey(const ValueKey('refresh-folder'));
      await tester.tap(button);
      await tester.pump();
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      expect(find.text('keep.txt'), findsOneWidget);
      refresh.complete([file('keep.txt'), file('added.txt')]);
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(DirectoryScreen));
      expect(state.currentPath, '/inside/');
      expect(paths, ['/', '/inside/', '/inside/']);
      expect(state.sortType, 'duration');
      final entries = state.items as List;
      expect(
        entries.map((e) => e['name']),
        containsAll(['keep.txt', 'added.txt']),
      );
      expect(entries.map((e) => e['name']), isNot(contains('removed.txt')));
      expect(
        entries.firstWhere((e) => e['name'] == 'keep.txt')['thumb'],
        'existing-thumb.jpg',
      );
      expect(
        entries.firstWhere((e) => e['name'] == 'keep.txt')['duration'],
        42,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('directory_search')))
            .controller!
            .text,
        'keep',
      );
      expect(tester.widget<IconButton>(button).onPressed, isNotNull);
      expect(
        tester.widget<FilterChip>(find.byType(FilterChip)).selected,
        isTrue,
      );

      // Failed reconnects retain the last successful listing and allow retry.
      refresh = Completer<List<dynamic>>();
      await tester.tap(button);
      await tester.pump();
      refresh.completeError(PlatformException(code: 'OFFLINE'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      expect(state.currentPath, '/inside/');
      expect(state.items, same(entries));
      expect(state.sortType, 'duration');
      expect(
        tester.widget<FilterChip>(find.byType(FilterChip)).selected,
        isTrue,
      );
      expect(tester.widget<IconButton>(button).onPressed, isNotNull);
      expect(find.text('keep.txt'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
