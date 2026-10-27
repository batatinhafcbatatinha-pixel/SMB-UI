import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smb_media_viewer/utils/folder_view_preferences.dart';

void main() {
  test(
    'folder preferences survive a new storage instance and normalize paths',
    () async {
      SharedPreferences.setMockInitialValues({});
      var prefs = await SharedPreferences.getInstance();
      var store = FolderViewPreferences(
        prefs,
        server: 'server',
        share: 'media',
      );
      expect(
        await store.save(
          '/A/',
          const FolderView(sort: 'size', favoritesOnly: true),
        ),
        isTrue,
      );
      await store.save('/B', const FolderView(sort: 'recent'));
      final persisted = {
        for (final key in prefs.getKeys()) key: prefs.get(key)!,
      };
      SharedPreferences.setMockInitialValues(persisted);
      prefs = await SharedPreferences.getInstance();
      store = FolderViewPreferences(prefs, server: 'server', share: 'media');
      expect(store.read(r'\A\').sort, 'size');
      expect(store.read('/A').favoritesOnly, isTrue);
      expect(store.read('/B/').sort, 'recent');
      expect(store.read('/B/').favoritesOnly, isFalse);
      expect(store.read('/new').sort, 'name');
      expect(store.read('/new').favoritesOnly, isFalse);
      expect(
        FolderViewPreferences(
          prefs,
          server: 'other',
          share: 'media',
        ).read('/A').sort,
        'name',
      );
    },
  );

  test(
    'legacy sort keys are restored with and without trailing slash',
    () async {
      SharedPreferences.setMockInitialValues({
        'sort_server_media_/A/': 'duration',
      });
      final store = FolderViewPreferences(
        await SharedPreferences.getInstance(),
        server: 'server',
        share: 'media',
      );
      expect(store.read('/A').sort, 'duration');
      expect(store.read(r'\A').sort, 'duration');
    },
  );
}
