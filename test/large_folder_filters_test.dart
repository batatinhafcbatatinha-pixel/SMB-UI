import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smb_media_viewer/main.dart';
import 'package:smb_media_viewer/utils/parallel_thumbnail_loader.dart';
import 'package:smb_media_viewer/utils/thumbnail_cache.dart';
import 'package:smb_media_viewer/utils/thumbnail_events.dart';

void main() {
  testWidgets(
    '29,223 files: sorts, favorites, cached duration and final update',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'favorites:large:media': ['/large/00000.mp4'],
      });
      final loader = ParallelThumbnailLoader()..pause();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('smb_channel');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'listDirectory') return null;
        return List.generate(
          29223,
          (i) => {
            'name': '${i.toString().padLeft(5, '0')}.mp4',
            'path': '/large/${i.toString().padLeft(5, '0')}.mp4',
            'is_dir': false,
            'is_media': true,
            'size': i,
            'modified': i,
          },
        );
      });
      await thumbCache.putDuration('/large/29221.mp4', 120);
      final locale = AppLocaleController();
      addTearDown(locale.dispose);
      await tester.pumpWidget(
        AppLocaleScope(
          notifier: locale,
          child: const MaterialApp(
            home: DirectoryScreen(
              ip: 'large',
              share: 'media',
              username: '',
              password: '',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('00000.mp4'), findsWidgets);
      Future<void> sort(String label) async {
        final chip = find.widgetWithText(ChoiceChip, label);
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
      }

      await sort('Largest Size');
      expect(find.text('29222.mp4'), findsWidgets);
      await sort('Most Recent');
      expect(find.text('29222.mp4'), findsWidgets);
      await sort('Longest Duration');
      expect(find.text('29221.mp4'), findsWidgets);
      emitThumbnailReady('/large/00000.mp4', null, duration: 121);
      await tester.pump(const Duration(milliseconds: 40));
      emitThumbnailReady('/large/00001.mp4', null, duration: 130);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();
      expect(find.text('00001.mp4'), findsWidgets);
      await tester.ensureVisible(find.byType(FilterChip));
      await tester.tap(find.byType(FilterChip));
      await tester.pumpAndSettle();
      expect(find.text('00000.mp4'), findsWidgets);
      expect(find.text('00001.mp4'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      loader.cancelAll();
      loader.resume();
      await tester.pump(const Duration(seconds: 2));
      messenger.setMockMethodCallHandler(channel, null);
    },
  );
}
