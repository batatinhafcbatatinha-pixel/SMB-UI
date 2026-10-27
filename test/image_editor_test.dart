import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smb_media_viewer/image_editor.dart';

void main() {
  testWidgets('loads, crops and saves a decodable image', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('crop_test_'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.png');
    await tester.runAsync(
      () => source.writeAsBytes(
        img.encodePng(img.Image(width: 200, height: 100)),
      ),
    );
    String? output;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              output = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => ImageEditorScreen(path: source.path),
                ),
              );
            },
            child: const Text('Edit'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    await tester.pump();
    final saveFinder = find.widgetWithIcon(IconButton, Icons.check);
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      final save = tester.widget<IconButton>(saveFinder);
      if (save.onPressed != null) break;
    }
    expect(tester.widget<IconButton>(saveFinder).onPressed, isNotNull);
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.byIcon(Icons.check)));
    for (var i = 0; i < 100 && output == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(output, isNotNull);
    final result = File(output!);
    addTearDown(() async {
      if (await result.exists()) await result.delete();
    });
    final decoded = img.decodeImage(
      (await tester.runAsync(() => result.readAsBytes()))!,
    );
    expect(decoded, isNotNull);
    expect(decoded!.width, lessThan(200));
    expect(decoded.height, inInclusiveRange(1, 100));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
  });
}
