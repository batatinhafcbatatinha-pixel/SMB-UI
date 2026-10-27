import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smb_media_viewer/widgets/video_gestures.dart';

void main() {
  testWidgets(
    'only double side taps seek; single and center taps show controls',
    (tester) async {
      final seeks = <Duration>[];
      var shown = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 300,
              height: 200,
              child: VideoGestures(
                onSeek: seeks.add,
                onShowControls: () => shown++,
                child: const SizedBox(width: 50, height: 200),
              ),
            ),
          ),
        ),
      );
      final origin = tester.getTopLeft(find.byType(VideoGestures));
      await tester.tapAt(origin + const Offset(20, 100));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(origin + const Offset(150, 100));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(origin + const Offset(280, 100));
      await tester.pump(const Duration(milliseconds: 400));
      expect(seeks, isEmpty);
      expect(shown, 3);
      for (final x in [20.0, 150.0, 280.0]) {
        await tester.tapAt(origin + Offset(x, 100));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(origin + Offset(x, 100));
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(seeks, [
        const Duration(seconds: -10),
        const Duration(seconds: 10),
      ]);
      expect(shown, 6);
    },
  );
  test('seek never exceeds beginning or end', () {
    expect(
      videoSeekTarget(
        const Duration(seconds: 4),
        const Duration(seconds: -10),
        const Duration(minutes: 1),
      ),
      Duration.zero,
    );
    expect(
      videoSeekTarget(
        const Duration(seconds: 58),
        const Duration(seconds: 10),
        const Duration(minutes: 1),
      ),
      const Duration(minutes: 1),
    );
    expect(
      videoSeekTarget(
        Duration.zero,
        const Duration(seconds: 10),
        Duration.zero,
      ),
      Duration.zero,
    );
  });
}
