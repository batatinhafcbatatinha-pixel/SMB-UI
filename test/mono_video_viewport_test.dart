import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smb_media_viewer/widgets/mono_video_viewport.dart';

void main() {
  testWidgets('Kandao SBS shows one eye; drag, FOV and reset preserve player', (
    tester,
  ) async {
    var interactions = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MonoVideoViewport(
            enabled: true,
            sourceAspectRatio: 7680 / 2160,
            showControls: true,
            onInteraction: () => interactions++,
            child: const ColoredBox(
              key: ValueKey('player'),
              color: Colors.blue,
            ),
          ),
        ),
      ),
    );
    final crop = find.byKey(const ValueKey('mono-eye-crop'));
    final player = find.byKey(const ValueKey('player'));
    final element = tester.element(player);
    expect(
      tester.getSize(player).width,
      closeTo(tester.getSize(crop).width * 2, .01),
    );
    final before = tester.getTopLeft(crop);
    await tester.dragFrom(const Offset(400, 350), const Offset(90, 30));
    await tester.pump();
    expect(tester.getTopLeft(crop), isNot(before));
    expect(interactions, greaterThan(0));
    tester.widget<Slider>(find.byKey(const ValueKey('mono-fov'))).onChanged!(
      35,
    );
    await tester.pump();
    expect(find.text('FOV 35°'), findsOneWidget);
    expect(tester.element(player), same(element));
    await tester.tap(find.byTooltip('Centralizar visão'));
    await tester.pump();
    expect(find.text('FOV 75°'), findsOneWidget);
    expect(tester.getTopLeft(crop), before);
  });
  testWidgets(
    'normal mode keeps entire frame and switching keeps player mounted',
    (tester) async {
      Widget viewer(bool enabled) => MaterialApp(
        home: Scaffold(
          body: MonoVideoViewport(
            enabled: enabled,
            sourceAspectRatio: 7680 / 2160,
            showControls: true,
            onInteraction: () {},
            child: const ColoredBox(
              key: ValueKey('player'),
              color: Colors.blue,
            ),
          ),
        ),
      );
      await tester.pumpWidget(viewer(false));
      final player = find.byKey(const ValueKey('player'));
      final element = tester.element(player);
      expect(
        tester.getSize(player),
        tester.getSize(find.byKey(const ValueKey('mono-eye-crop'))),
      );
      expect(find.byType(Slider), findsNothing);
      await tester.pumpWidget(viewer(true));
      expect(tester.element(player), same(element));
      expect(find.byType(Slider), findsOneWidget);
    },
  );
}
