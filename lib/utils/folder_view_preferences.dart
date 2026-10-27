import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class FolderView {
  const FolderView({this.sort = 'name', this.favoritesOnly = false});
  final String sort;
  final bool favoritesOnly;
}

class FolderViewPreferences {
  FolderViewPreferences(
    this.preferences, {
    required this.server,
    required this.share,
  });
  final SharedPreferences preferences;
  final String server;
  final String share;
  static const sorts = {'name', 'recent', 'size', 'duration'};

  static String canonicalPath(String path) {
    final segments = path
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty);
    return '/${segments.join('/')}';
  }

  String _key(String path) =>
      'folderView:${jsonEncode([server, share, canonicalPath(path)])}';

  FolderView read(String path) {
    final saved = preferences.getString(_key(path));
    if (saved != null) {
      try {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        return FolderView(
          sort: sorts.contains(data['sort']) ? data['sort'] as String : 'name',
          favoritesOnly: data['favoritesOnly'] == true,
        );
      } catch (_) {
        // Fall back to a valid legacy value or the defaults.
      }
    }
    // Recover preferences written before trailing slashes were normalized.
    final prefix = 'sort_${server}_${share}_';
    final direct = preferences.getString('$prefix$path');
    if (sorts.contains(direct)) return FolderView(sort: direct!);
    for (final key in preferences.getKeys()) {
      if (key.startsWith(prefix) &&
          canonicalPath(key.substring(prefix.length)) == canonicalPath(path)) {
        final sort = preferences.getString(key);
        if (sorts.contains(sort)) return FolderView(sort: sort!);
      }
    }
    return const FolderView();
  }

  Future<bool> save(String path, FolderView view) => preferences.setString(
    _key(path),
    jsonEncode({'sort': view.sort, 'favoritesOnly': view.favoritesOnly}),
  );
}
