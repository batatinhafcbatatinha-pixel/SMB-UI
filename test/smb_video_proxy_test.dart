import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smb_media_viewer/utils/smb_video_proxy_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('smb_channel');
  final payload = Uint8List.fromList(List.generate(128, (i) => i));
  late HttpClient client;
  late Uri uri;

  setUp(() async {
    HttpOverrides.global = null;
    client = HttpClient();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'readSmbFileChunk') {
            final args = call.arguments as Map;
            final offset = args['offset'] as int;
            final length = args['length'] as int;
            return {'bytes': payload.sublist(offset, offset + length)};
          }
          throw PlatformException(code: 'unexpected', message: call.method);
        });
    uri = await smbVideoProxyServer.registerSource(
      ip: 'server',
      share: 'media',
      path: '/video.mp4',
      username: '',
      password: '',
      fileSizeOverride: payload.length,
    );
  });

  tearDown(() async {
    client.close(force: true);
    await smbVideoProxyServer.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<HttpClientResponse> request({
    String method = 'GET',
    String? range,
  }) async {
    final request = await client.openUrl(method, uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close();
  }

  test('full response contains exact bytes and no Content-Range', () async {
    final response = await request();
    expect(response.statusCode, 200);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), isNull);
    expect(await response.expand((bytes) => bytes).toList(), payload);
  });

  for (final range in ['bytes=10-19', 'bytes=118-', 'bytes=-10']) {
    test('serves $range exactly', () async {
      final response = await request(range: range);
      expect(response.statusCode, 206);
      final start = range == 'bytes=10-19' ? 10 : 118;
      expect(response.contentLength, 10);
      expect(
        await response.expand((bytes) => bytes).toList(),
        payload.sublist(start, start + 10),
      );
    });
  }

  for (final range in [
    'bytes=128-',
    'bytes=20-10',
    'bytes=abc-20',
    'bytes=-0',
  ]) {
    test('rejects invalid range $range', () async {
      final response = await request(range: range);
      expect(response.statusCode, 416);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes */128',
      );
      await response.drain<void>();
    });
  }

  test('HEAD sends headers without a body', () async {
    final response = await request(method: 'HEAD');
    expect(response.statusCode, 200);
    expect(response.contentLength, payload.length);
    expect(await response.expand((bytes) => bytes).toList(), isEmpty);
  });

  test('rejects unsupported methods', () async {
    final response = await request(method: 'POST');
    expect(response.statusCode, 405);
    await response.drain<void>();
  });

  test('unregistered source is inaccessible', () async {
    smbVideoProxyServer.unregisterSource(uri.queryParameters['token']);
    final response = await request();
    expect(response.statusCode, 404);
    await response.drain<void>();
  });

  test('concurrent registrations reuse the listening server', () async {
    await smbVideoProxyServer.dispose();
    final uris = await Future.wait(
      List.generate(
        4,
        (i) => smbVideoProxyServer.registerSource(
          ip: 'server',
          share: 'media',
          path: '/$i.mp4',
          username: '',
          password: '',
          fileSizeOverride: 128,
        ),
      ),
    );
    expect(uris.map((u) => u.port).toSet(), hasLength(1));
  });
}
