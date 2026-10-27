import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smb_media_viewer/utils/image_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('image_test_'),
  );
  tearDown(() async => directory.delete(recursive: true));

  for (final dimensions in [(1200, 300), (300, 1200), (32, 16)]) {
    test(
      'viewer and thumbnail preserve ${dimensions.$1}x${dimensions.$2}',
      () async {
        final input = File('${directory.path}/source.png');
        await input.writeAsBytes(
          img.encodePng(img.Image(width: dimensions.$1, height: dimensions.$2)),
        );
        final codec = await decodeImageToFit(input.path, 400, 600);
        final frame = await codec.getNextFrame();
        expect(
          frame.image.width / frame.image.height,
          closeTo(dimensions.$1 / dimensions.$2, .01),
        );
        expect(frame.image.width, lessThanOrEqualTo(400));
        expect(frame.image.height, lessThanOrEqualTo(600));
        expect(frame.image.width, lessThanOrEqualTo(dimensions.$1));
        frame.image.dispose();
        codec.dispose();

        final output = '${directory.path}/thumb.png';
        expect(
          await generateImageThumbnailNative(input.path, output, 320),
          output,
        );
        final thumb = img.decodeImage(await File(output).readAsBytes())!;
        expect(thumb.width, lessThanOrEqualTo(320));
        expect(thumb.height, lessThanOrEqualTo(320));
        expect(
          thumb.width / thumb.height,
          closeTo(dimensions.$1 / dimensions.$2, .01),
        );
      },
    );
  }
  test('corrupt thumbnail input returns null', () async {
    final input = File('${directory.path}/bad.png');
    await input.writeAsString('not an image');
    expect(
      await generateImageThumbnailNative(
        input.path,
        '${directory.path}/thumb.png',
        320,
      ),
      isNull,
    );
  });
}
