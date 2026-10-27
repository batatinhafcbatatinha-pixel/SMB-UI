import 'package:flutter_test/flutter_test.dart';
import 'package:smb_media_viewer/utils/memory_cache.dart';

void main() {
  test('evicts least recently used entry and accounts for replacements', () {
    final cache = MemoryCache<String>(maxEntries: 2, maxMemoryBytes: 10);
    addTearDown(cache.dispose);
    cache.put('a', 'a', sizeBytes: 4);
    cache.put('b', 'b', sizeBytes: 4);
    expect(cache.get('a'), 'a');
    cache.put('c', 'c', sizeBytes: 4);
    expect(cache.get('b'), isNull);
    expect(cache.memoryBytes, 8);
    cache.put('a', 'small', sizeBytes: 1);
    expect(cache.memoryBytes, 5);
  });

  test('rejects negative sizes without corrupting accounting', () {
    final cache = MemoryCache<String>();
    addTearDown(cache.dispose);
    cache.put('a', 'a', sizeBytes: 4);
    expect(() => cache.put('a', 'b', sizeBytes: -1), throwsArgumentError);
    expect(cache.get('a'), 'a');
    expect(cache.memoryBytes, 4);
    expect(() => MemoryCache(maxEntries: -1), throwsArgumentError);
  });
}
