// Optimized SMB Media Viewer - Import optimized modules
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'widgets/mono_video_viewport.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:video_thumbnail/video_thumbnail.dart';
// image package retained for rare operations; prefer native codec where possible

// Memory optimization imports
import 'utils/file_cache_manager.dart';
import 'utils/smb_connection_manager.dart';
import 'utils/smb_client.dart';
// import 'utils/performance_monitor.dart'; // unused here
import 'utils/parallel_thumbnail_loader.dart';
import 'utils/smb_video_proxy_server.dart';
import 'image_editor.dart';
import 'video_trimmer_screen.dart';
import 'utils/thumbnail_cache.dart';
import 'utils/thumbnail_events.dart';
import 'utils/image_utils.dart';
import 'app_theme.dart';
import 'utils/name_search.dart';
import 'utils/folder_view_preferences.dart';
import 'widgets/video_gestures.dart';

// Delete a cached file if it looks like a temporary downloaded cache entry.
// Conservative heuristics: filename starts with "temp_" or path contains a cache folder.
Future<void> deleteCachedFileIfNeeded(String? path) async {
  if (path == null || path.isEmpty) return;
  try {
    final pLower = path.toLowerCase();
    final file = File(path);
    final name = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : '';
    final nameLower = name.toLowerCase();

    if (!await file.exists()) return;

    final bool looksTemp =
        nameLower.startsWith('temp_') ||
        pLower.contains('/cache/') ||
        pLower.contains('\\cache\\');
    if (!looksTemp) return;

    try {
      await file.delete();
      debugPrint('Deleted cached file: $path');
    } catch (e) {
      debugPrint('Failed deleting cached file $path: $e');
    }
  } catch (e) {
    debugPrint('Error in deleteCachedFileIfNeeded for $path: $e');
  }
}

// Case-insensitive name order, falling back to the raw name for a stable order.
int _compareNames(Map a, Map b) {
  final an = a['name'] as String? ?? '';
  final bn = b['name'] as String? ?? '';
  final c = an.toLowerCase().compareTo(bn.toLowerCase());
  return c != 0 ? c : an.compareTo(bn);
}

// Downloads left behind by a previous run (viewer files, partial thumbnail
// reads). Nothing uses them at startup, and they used to pile up past 1 GB.
Future<void> _purgeOrphanDownloads(
  Directory cacheDir, {
  List<String> prefixes = const [
    'temp_',
    'thumb_temp_',
    'partial_',
    'partialimg_',
    'trim_', // trimmed videos awaiting upload
    'edited_', // cropped images awaiting upload
  ],
}) async {
  if (!await cacheDir.exists()) return;
  final startedAt = DateTime.now();
  var freed = 0;
  try {
    await for (final entity in cacheDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!prefixes.any(name.startsWith)) continue;
      try {
        final stat = await entity.stat();
        if (stat.modified.isAfter(startedAt)) continue;
        freed += stat.size;
        await entity.delete();
      } catch (_) {}
    }
  } catch (e) {
    debugPrint('Orphan download cleanup failed: $e');
  }
  if (freed > 0) {
    debugPrint('Removed ${freed ~/ (1024 * 1024)} MB of orphan downloads');
  }
}

Future<void> _registerFetchedFile(String path) async {
  try {
    if (path.isEmpty) return;
    final f = File(path);
    final stat = await f.stat();
    if (stat.type != FileSystemEntityType.file) return;
    final size = stat.size;
    // Register in the global file cache manager so it can evict later.
    try {
      fileCacheManager.registerFile(path, size);
    } catch (e) {
      debugPrint('fileCacheManager.registerFile error: $e');
    }
    debugPrint('Registered fetched file: $path ($size bytes)');
  } catch (e) {
    debugPrint('Error in _registerFetchedFile: $e');
  }
}

// Minimal localized strings used by the app. Expand as needed.
final Map<String, Map<String, String>> _localizedStrings = {
  'en': {
    'appTitle': 'SMB Media Viewer',
    'searchNetwork': 'Search network',
    'searchNames': 'Search names',
    'searchHint': 'Files and folders in this folder',
    'noMatches': 'No matching names',
    'emptyFolder': 'Nothing here yet',
    'clearSearch': 'Clear search',
    'closeSearch': 'Close search',
    'results': '{count} items',
    'selectServerToBegin': 'Select a server to begin',
    'searchingServers': 'Searching servers...',
    'foundServers': '{count} servers found',
    'noServersFound': 'No servers found: {error}',
    'error': 'Error: {error}',
    'selectShare': 'Select share',
    'noSharesFound': 'No shares or access denied: {error}',
    'language': 'Language',
    'useSystemLanguage': 'System default',
    'portugueseBrazil': 'Portuguese (Brazil)',
    'english': 'English',
    'name': 'Name',
    'mostRecent': 'Most Recent',
    'largestSize': 'Largest Size',
    'longestDuration': 'Longest Duration',
    'favorites': 'Favorites',
    'activeFilters': 'Active filters',
    'allMedia': 'All Media',
    'favoritesOnly': 'Favorites Only',
    'refreshFolder': 'Reconnect and refresh folder',
    'refreshFailed': 'Could not refresh. Your current view was kept.',
    'addServer': 'Add server',
    'serverAddress': 'Server IP or hostname',
    'cancel': 'Cancel',
    'add': 'Add',
    'removeServer': 'Remove server',
  },
  'pt': {
    'appTitle': 'SMB Media Viewer',
    'searchNetwork': 'Buscar na rede',
    'searchNames': 'Pesquisar nomes',
    'searchHint': 'Arquivos e pastas nesta pasta',
    'noMatches': 'Nenhum nome encontrado',
    'emptyFolder': 'Nada por aqui ainda',
    'clearSearch': 'Limpar pesquisa',
    'closeSearch': 'Fechar pesquisa',
    'results': '{count} itens',
    'selectServerToBegin': 'Selecione um servidor para comecar',
    'searchingServers': 'Buscando servidores...',
    'foundServers': '{count} servidores encontrados',
    'noServersFound': 'Nenhum servidor encontrado: {error}',
    'error': 'Erro: {error}',
    'selectShare': 'Selecionar compartilhamento',
    'noSharesFound': 'Sem compartilhamentos ou acesso negado: {error}',
    'language': 'Idioma',
    'useSystemLanguage': 'Padrao do sistema',
    'portugueseBrazil': 'Portugues (Brasil)',
    'english': 'Ingles',
    'name': 'Nome',
    'mostRecent': 'Mais recente',
    'largestSize': 'Maior tamanho',
    'longestDuration': 'Maior duracao',
    'favorites': 'Favoritos',
    'activeFilters': 'Filtros ativos',
    'allMedia': 'Toda midia',
    'favoritesOnly': 'Somente favoritos',
    'refreshFolder': 'Reconectar e atualizar pasta',
    'refreshFailed':
        'Não foi possível atualizar. A visualização atual foi mantida.',
    'addServer': 'Adicionar servidor',
    'serverAddress': 'IP ou nome do servidor',
    'cancel': 'Cancelar',
    'add': 'Adicionar',
    'removeServer': 'Remover servidor',
  },
};

String t(BuildContext context, String key, {Map<String, String>? params}) {
  final scope = context.dependOnInheritedWidgetOfExactType<AppLocaleScope>();
  final forcedLocale = scope?.notifier?.locale;
  final effectiveLocale =
      forcedLocale ??
      Localizations.maybeLocaleOf(context) ??
      const Locale('en');
  final lang = effectiveLocale.languageCode.toLowerCase().startsWith('pt')
      ? 'pt'
      : 'en';
  var value =
      _localizedStrings[lang]?[key] ?? _localizedStrings['en']?[key] ?? key;
  if (params != null) {
    params.forEach((k, v) {
      value = value.replaceAll('{$k}', v);
    });
  }
  return value;
}

// Locale/controller implementation — persists mode and optional forced locale.
enum AppLocaleMode { system, ptBr, en }

class AppLocaleController extends ChangeNotifier {
  static const _prefsModeKey = 'app_locale_mode';
  static const _prefsLocaleKey = 'app_locale_locale';

  Locale? _locale; // forced locale when mode != system
  AppLocaleMode mode = AppLocaleMode.system;

  Locale? get locale => _locale;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeStr = prefs.getString(_prefsModeKey) ?? 'system';
      switch (modeStr) {
        case 'ptBr':
          mode = AppLocaleMode.ptBr;
          _locale = const Locale('pt', 'BR');
          break;
        case 'en':
          mode = AppLocaleMode.en;
          _locale = const Locale('en');
          break;
        default:
          mode = AppLocaleMode.system;
          _locale = null;
      }

      // Backwards-compatible: allow explicit locale string override
      final localeStr = prefs.getString(_prefsLocaleKey);
      if (localeStr != null && localeStr.isNotEmpty) {
        final parts = localeStr.split('_');
        if (parts.isNotEmpty) {
          _locale = parts.length > 1
              ? Locale(parts[0], parts[1])
              : Locale(parts[0]);
        }
      }
    } catch (e) {
      // ignore errors reading prefs; fall back to system
      mode = AppLocaleMode.system;
      _locale = null;
    }
    notifyListeners();
  }

  Future<void> setMode(AppLocaleMode m) async {
    mode = m;
    switch (m) {
      case AppLocaleMode.ptBr:
        _locale = const Locale('pt', 'BR');
        break;
      case AppLocaleMode.en:
        _locale = const Locale('en');
        break;
      case AppLocaleMode.system:
        _locale = null;
        break;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsModeKey,
        m == AppLocaleMode.system
            ? 'system'
            : (m == AppLocaleMode.ptBr ? 'ptBr' : 'en'),
      );
      if (_locale != null) {
        final s =
            _locale!.countryCode != null && _locale!.countryCode!.isNotEmpty
            ? '${_locale!.languageCode}_${_locale!.countryCode}'
            : _locale!.languageCode;
        await prefs.setString(_prefsLocaleKey, s);
      } else {
        await prefs.remove(_prefsLocaleKey);
      }
    } catch (_) {}
    notifyListeners();
  }

  /// Force a specific `Locale` value and persist it.
  Future<void> setLocale(Locale? l) async {
    _locale = l;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (l != null) {
        final s = l.countryCode != null && l.countryCode!.isNotEmpty
            ? '${l.languageCode}_${l.countryCode}'
            : l.languageCode;
        await prefs.setString(_prefsLocaleKey, s);
      } else {
        await prefs.remove(_prefsLocaleKey);
      }
    } catch (_) {}
    notifyListeners();
  }
}

class AppLocaleScope extends InheritedNotifier<AppLocaleController> {
  const AppLocaleScope({
    required AppLocaleController notifier,
    required Widget child,
    Key? key,
  }) : super(key: key, notifier: notifier, child: child);

  static AppLocaleController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppLocaleScope>();
    if (scope == null) {
      throw FlutterError(
        'AppLocaleScope.of() called with no AppLocaleScope present in the widget tree.',
      );
    }
    return scope.notifier!;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Configure structured error logging
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint(
      '\n=== [FLUTTER ERROR] ===\n${details.exceptionAsString()}\n=======================\n',
    );
  };

  try {
    await fileCacheManager.initialize();
  } catch (e) {
    debugPrint('fileCacheManager initialization failed: $e');
  }
  try {
    smbConnectionManager.initialize();
  } catch (e) {
    debugPrint('smbConnectionManager initialization failed: $e');
  }
  try {
    final cacheDir = await getTemporaryDirectory();
    await thumbCache.initialize(cacheDir);
    unawaited(_purgeOrphanDownloads(cacheDir));
    // video_trimmer writes into <documents>/Trimmer and never cleans it.
    unawaited(
      getApplicationDocumentsDirectory().then(
        (docs) => _purgeOrphanDownloads(
          Directory('${docs.path}/Trimmer'),
          prefixes: const ['temp_'],
        ),
      ),
    );
  } catch (e) {
    debugPrint('thumbCache initialization failed: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final AppLocaleController _localeController = AppLocaleController();

  @override
  void initState() {
    super.initState();
    _localeController.load();
    // Adjust image cache size heuristically (can be overridden in prefs)
    adjustImageCacheSizeFromPrefs();
  }

  @override
  void dispose() {
    _localeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppLocaleScope(
      notifier: _localeController,
      child: AnimatedBuilder(
        animation: _localeController,
        builder: (context, _) => MaterialApp(
          title: 'SMB Media Viewer',
          theme: buildAppTheme(),
          debugShowCheckedModeBanner: false,
          locale: _localeController.locale,
          supportedLocales: const [Locale('en'), Locale('pt', 'BR')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const MainScreen(),
        ),
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool _searching = false;
  String _status = 'Select a server to begin';
  bool _statusInitialized = false;
  List<Map<dynamic, dynamic>> _servers = [];
  final String _username = '';
  final String _password = '';

  // Servers typed in by the user, persisted so they show up on next launch.
  static const _savedServersKey = 'saved_servers';
  List<String> _savedServers = [];

  @override
  void initState() {
    super.initState();
    _loadSavedServers();
  }

  Future<void> _loadSavedServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_savedServersKey) ?? [];
      if (!mounted) return;
      setState(() {
        _savedServers = saved;
        _mergeServers(const []);
      });
    } catch (e) {
      debugPrint('Failed loading saved servers: $e');
    }
  }

  // Saved servers first, then discovered ones not already listed.
  void _mergeServers(List<Map<dynamic, dynamic>> discovered) {
    final seen = <String>{};
    _servers = [
      for (final ip in _savedServers)
        if (seen.add(ip)) {'name': ip, 'ip': ip, 'saved': true},
      for (final s in [..._servers, ...discovered])
        if (s['saved'] != true && seen.add('${s['ip']}')) s,
    ];
  }

  Future<void> _persistSavedServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_savedServersKey, _savedServers);
    } catch (e) {
      debugPrint('Failed saving servers: $e');
    }
  }

  Future<void> _addServerDialog() async {
    final controller = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t(context, 'addServer')),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(hintText: t(context, 'serverAddress')),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(t(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text),
            child: Text(t(context, 'add')),
          ),
        ],
      ),
    );
    controller.dispose();
    final value = ip?.trim() ?? '';
    if (value.isEmpty || !mounted) return;
    setState(() {
      _savedServers = [value, ..._savedServers.where((s) => s != value)];
      _mergeServers(const []);
    });
    await _persistSavedServers();
  }

  Future<void> _removeSavedServer(String ip) async {
    setState(() {
      _savedServers = _savedServers.where((s) => s != ip).toList();
      _servers = _servers.where((s) => s['ip'] != ip).toList();
    });
    await _persistSavedServers();
  }

  Future<void> _confirmRemoveServer(String ip) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t(context, 'removeServer')),
        content: Text(ip),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(t(context, 'removeServer')),
          ),
        ],
      ),
    );
    if (remove == true) await _removeSavedServer(ip);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_statusInitialized) {
      _statusInitialized = true;
      _status = t(context, 'selectServerToBegin');
    }
  }

  Future<void> _searchNetwork() async {
    setState(() {
      _searching = true;
      _status = t(context, 'searchingServers');
      _servers = [];
      _mergeServers(const []);
    });

    try {
      final result = await SMBClient.discoverNetwork();

      if (!mounted) return;
      if (result.success && result.data != null) {
        setState(() {
          _mergeServers(
            result.data!.map((e) => Map<dynamic, dynamic>.from(e)).toList(),
          );
          _status = t(
            context,
            'foundServers',
            params: {'count': _servers.length.toString()},
          );
          if (result.retryCount > 0) {
            _status += ' (retry: ${result.retryCount}x)';
          }
        });
      } else {
        setState(() {
          _status = t(
            context,
            'noServersFound',
            params: {'error': result.error ?? 'Unknown error'},
          );
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = t(context, 'error', params: {'error': '$e'});
      });
    } finally {
      if (mounted) {
        setState(() {
          _searching = false;
        });
      }
    }
  }

  Future<void> _openShares(Map server) async {
    try {
      final result = await SMBClient.listShares(
        server['ip'] as String,
        username: _username,
        password: _password,
      );

      if (!mounted) return;
      if (result.success && result.data != null && result.data!.isNotEmpty) {
        final chosen = await showDialog<String?>(
          context: context,
          builder: (c) => SimpleDialog(
            title: Text(t(context, 'selectShare')),
            children: result.data!
                .map<Widget>(
                  (s) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, s.toString()),
                    child: Text(s.toString()),
                  ),
                )
                .toList(),
          ),
        );

        if (chosen != null) {
          if (!mounted) return;
          // Register connection for keepalive tracking
          smbConnectionManager.registerConnection(
            '${server['ip']}:$chosen',
            server['ip'] as String,
            chosen,
            username: _username,
            password: _password,
          );

          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => DirectoryScreen(
                ip: server['ip'] as String,
                share: chosen,
                username: _username,
                password: _password,
              ),
            ),
          );
        }
      } else {
        setState(() {
          _status = t(
            context,
            'noSharesFound',
            params: {'error': '${result.error}'},
          );
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = t(context, 'error', params: {'error': '$e'});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final localeController = AppLocaleScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t(context, 'appTitle')),
        actions: [
          IconButton(
            key: const ValueKey('add-server'),
            tooltip: t(context, 'addServer'),
            onPressed: _addServerDialog,
            icon: const Icon(Icons.add_rounded),
          ),
          PopupMenuButton<AppLocaleMode>(
            tooltip: t(context, 'language'),
            icon: const Icon(Icons.language),
            initialValue: localeController.mode,
            onSelected: (mode) => localeController.setMode(mode),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: AppLocaleMode.system,
                child: Row(
                  children: [
                    if (localeController.mode == AppLocaleMode.system)
                      const Padding(
                        padding: EdgeInsets.only(right: 8.0),
                        child: Icon(Icons.check, size: 16),
                      ),
                    Text(t(context, 'useSystemLanguage')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: AppLocaleMode.ptBr,
                child: Row(
                  children: [
                    if (localeController.mode == AppLocaleMode.ptBr)
                      const Padding(
                        padding: EdgeInsets.only(right: 8.0),
                        child: Icon(Icons.check, size: 16),
                      ),
                    Text(t(context, 'portugueseBrazil')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: AppLocaleMode.en,
                child: Row(
                  children: [
                    if (localeController.mode == AppLocaleMode.en)
                      const Padding(
                        padding: EdgeInsets.only(right: 8.0),
                        child: Icon(Icons.check, size: 16),
                      ),
                    Text(t(context, 'english')),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _searching ? null : _searchNetwork,
                  icon: const Icon(Icons.radar_rounded),
                  label: Text(t(context, 'searchNetwork')),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(_status, textAlign: TextAlign.right)),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _servers.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(28),
                            ),
                            child: Icon(
                              Icons.dns_outlined,
                              size: 48,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            t(
                              context,
                              _searching
                                  ? 'searchingServers'
                                  : 'selectServerToBegin',
                            ),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (_searching)
                            const Padding(
                              padding: EdgeInsets.only(top: 20),
                              child: SizedBox(
                                width: 160,
                                child: LinearProgressIndicator(),
                              ),
                            ),
                        ],
                      ),
                    )
                  : GridView.extent(
                      maxCrossAxisExtent: 260,
                      childAspectRatio: 1.25,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      children: _servers.map((s) {
                        final name = s['name'] ?? s['ip'];
                        final ip = s['ip'];
                        return GestureDetector(
                          onTap: () => _openShares(s),
                          onLongPress: s['saved'] == true
                              ? () => _confirmRemoveServer('$ip')
                              : null,
                          child: Card(
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.dns_rounded,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      '$name',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if ('$name' != '$ip') ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        '$ip',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class DirectoryScreen extends StatefulWidget {
  final String ip;
  final String share;
  final String username;
  final String password;
  const DirectoryScreen({
    required this.ip,
    required this.share,
    required this.username,
    required this.password,
    super.key,
  });

  @override
  State<DirectoryScreen> createState() => _DirectoryScreenState();
}

class _DirectoryScreenState extends State<DirectoryScreen> {
  final _searchController = TextEditingController();
  final _gridScroll = ScrollController();
  bool _showSearch = false;
  String _searchQuery = '';

  bool _matchesFilters(Map<dynamic, dynamic> item) =>
      (_filter != 'favorites' || _isFavorite(item)) &&
      (_searchQuery.isEmpty ||
          (item['_search'] ??= normalizeSearchName(
            item['name'] as String? ?? '',
          )).contains(_searchQuery));

  // A new order or filter should start from the top of the list.
  void _scrollToTop() {
    if (_gridScroll.hasClients) _gridScroll.jumpTo(0);
  }

  void _closeSearch() {
    _searchController.clear();
    setState(() {
      _showSearch = false;
      _searchQuery = '';
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  List<Map<dynamic, dynamic>> items = [];
  List<Map<dynamic, dynamic>> mediaItems = [];
  // Same map instances as in [items], keyed by normalized path, so thumbnail
  // events update a single entry instead of scanning the whole folder.
  Map<String, Map<dynamic, dynamic>> _itemsByPath = {};
  Timer? _durationSortTimer;
  String status = '';
  String currentPath = '/';
  String? sortType;

  // Favorites (per-folder)
  late SharedPreferences _prefs;
  final Set<String> _favorites = {}; // stores item['path'] values
  String _filter = 'all'; // 'all' or 'favorites'

  // Thumbnail loading cancellation
  bool _thumbnailLoadingCancelled = false;
  Timer? _scrollDebounceTimer;

  // Thumbnail events subscription
  StreamSubscription<ThumbnailReadyEvent>? _thumbnailEventSub;
  final Map<String, ThumbnailReadyEvent> _pendingThumbUpdates = {};
  Timer? _thumbUpdateTimer;

  // Adaptive concurrency for background preloading.
  int _adaptiveParallelism = 4;

  // Viewport-first thumbnail scheduler (lightweight and cancelable).
  final Set<String> _viewportQueuedPaths = <String>{};
  int _preloadGeneration = 0;

  FolderViewPreferences? _folderViews;
  final Set<String> _selectedPaths = <String>{};
  bool get _isSelectionMode => _selectedPaths.isNotEmpty;

  Future<void> _saveFolderView() async {
    final store = _folderViews;
    if (store == null) return;
    final path = currentPath;
    final view = FolderView(
      sort: sortType ?? 'name',
      favoritesOnly: _filter == 'favorites',
    );
    try {
      if (!await store.save(path, view)) {
        throw StateError('Preferences write failed');
      }
    } catch (e) {
      debugPrint('Failed saving folder preferences: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não foi possível salvar os filtros.')),
        );
      }
    }
  }

  void _toggleFavoritesFilter() {
    if (_folderViews == null) return;
    setState(() {
      _filter = _filter == 'favorites' ? 'all' : 'favorites';
      _selectedPaths.clear();
    });
    _scrollToTop();
    unawaited(_saveFolderView());
    _restartBackgroundPreload();
  }

  String _normalizePath(String path) {
    if (path.isEmpty) return '/';
    // Hot path: listing paths are normalized once on load.
    if (path.startsWith('/') && !path.contains('\\') && !path.contains('//')) {
      return path;
    }
    var p = path.replaceAll('\\', '/');
    p = p.replaceAll(RegExp('/+'), '/');
    if (!p.startsWith('/')) p = '/$p';
    // Preserve a trailing slash only if the original path ended with a slash or backslash.
    if (path.endsWith('/') || path.endsWith('\\')) {
      if (!p.endsWith('/')) p = '$p/';
    }
    return p;
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
    // Subscribe to thumbnail-ready events and update UI in a controlled way
    _thumbnailEventSub = thumbnailReadyBus.stream.listen((ev) {
      try {
        _onThumbnailReady(ev);
      } catch (e) {
        debugPrint('Error handling thumbnail event: $e');
      }
    });
  }

  Future<void> _bootstrap() async {
    await _initPrefs();
    if (!mounted) return;
    await _loadDirectory('/');
  }

  @override
  void dispose() {
    _searchController.dispose();
    _gridScroll.dispose();
    _progressTimer?.cancel();
    _scrollDebounceTimer?.cancel();
    _thumbnailLoadingCancelled = true;
    _thumbnailEventSub?.cancel();
    _durationSortTimer?.cancel();
    _durationSortTimer = null;
    _thumbUpdateTimer?.cancel();
    // Garante que o índice foi gravado antes de sair
    thumbCache.flush();
    super.dispose();
  }

  // Apply thumbnail/duration updates on the main thread in a single setState.
  void _onThumbnailReady(ThumbnailReadyEvent ev) {
    if (!mounted) return;
    final normalized = _normalizePath(ev.smbPath);
    final previous = _pendingThumbUpdates[normalized];
    _pendingThumbUpdates[normalized] = ThumbnailReadyEvent(
      smbPath: normalized,
      thumbPath: ev.thumbPath ?? previous?.thumbPath,
      duration: ev.duration ?? previous?.duration,
    );
    _thumbUpdateTimer ??= Timer(
      const Duration(milliseconds: 32),
      _applyThumbnailUpdates,
    );
  }

  void _applyThumbnailUpdates() {
    _thumbUpdateTimer = null;
    if (!mounted) return;
    final updates = Map<String, ThumbnailReadyEvent>.of(_pendingThumbUpdates);
    _pendingThumbUpdates.clear();
    var updatedAny = false;
    var durationChanged = false;
    for (final entry in updates.entries) {
      final item = _itemsByPath[entry.key];
      if (item == null) continue;
      final ev = entry.value;
      if (ev.thumbPath?.isNotEmpty == true) {
        item['thumb'] = ev.thumbPath;
        _viewportQueuedPaths.remove(entry.key);
      }
      if (ev.duration != null) {
        item['duration'] = ev.duration;
        durationChanged = true;
      }
      updatedAny = true;
    }
    if (updatedAny) setState(() {});
    if (updatedAny && durationChanged && sortType == 'duration') {
      _durationSortTimer ??= Timer(const Duration(milliseconds: 800), () {
        _durationSortTimer = null;
        if (!mounted || sortType != 'duration') return;
        _sortMedia('duration', restartBackgroundLoading: false, persist: false);
      });
    }
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    _folderViews = FolderViewPreferences(
      _prefs,
      server: widget.ip,
      share: widget.share,
    );
    final key = 'favorites:${widget.ip}:${widget.share}';
    final list = _prefs.getStringList(key) ?? [];
    _favorites.addAll(list);
  }

  Future<void> _loadSavedSortForFolder(String path) async {
    final view = _folderViews!.read(path);
    sortType = view.sort;
    _filter = view.favoritesOnly ? 'favorites' : 'all';
  }

  int _directoryGeneration = 0;
  bool _refreshing = false;

  Future<void> _refreshDirectory() async {
    if (_refreshing || _folderViews == null) return;
    final path = currentPath;
    final generation = ++_directoryGeneration;
    // Preserve completed thumbnail events before cancelling pending work.
    _thumbUpdateTimer?.cancel();
    _applyThumbnailUpdates();
    ParallelThumbnailLoader().cancelAll();
    _cancelThumbnailLoading();
    _progressTimer?.cancel();
    setState(() => _refreshing = true);
    try {
      // Android listDirectory opens and authenticates a fresh SMB connection.
      // Keep the current list visible until that fresh listing succeeds.
      final ok = await _tryLoadDirectoryWithRetries(
        path,
        generation: generation,
        attempts: 1,
        preserveExisting: true,
      );
      if (!mounted || generation != _directoryGeneration) return;
      if (!ok) {
        setState(() => status = t(context, 'refreshFailed'));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t(context, 'refreshFailed'))));
        _restartBackgroundPreload();
      }
    } finally {
      if (mounted && generation == _directoryGeneration) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _loadDirectory(String path) async {
    final generation = ++_directoryGeneration;
    _refreshing = false;
    _searchController.clear();
    _searchQuery = '';
    _showSearch = false;
    ParallelThumbnailLoader().cancelAll();
    _cancelThumbnailLoading();

    // Limpar thumbnails da pasta anterior
    await _clearThumbnailsFromPreviousFolder();
    if (!mounted || generation != _directoryGeneration) return;

    // Load saved sort for this folder
    await _loadSavedSortForFolder(path);
    if (!mounted || generation != _directoryGeneration) return;

    setState(() {
      status = 'Loading...';
      currentPath = path;
      items = [];
      mediaItems = [];
      _itemsByPath = {};
      _selectedPaths.clear();
    });

    final ok = await _tryLoadDirectoryWithRetries(
      path,
      generation: generation,
      attempts: 3,
    );
    if (!mounted || generation != _directoryGeneration) return;
    if (!ok) {
      setState(
        () => status = 'Error loading directory (server rejected the request).',
      );
    }
  }

  /// Cancela o carregamento da pasta anterior.
  /// NÃO deleta thumbs do disco — eles são persistentes e indexados no cache.
  Future<void> _clearThumbnailsFromPreviousFolder() async {
    // Apenas garante que o índice foi gravado antes de trocar de pasta.
    await thumbCache.flush();
    // Cancela carregamento em progresso (sinaliza para loops pararem).
    _cancelThumbnailLoading();
    debugPrint('Folder change: flushed thumb cache, cancelled pending loads');
  }

  void _cancelThumbnailLoading() {
    _durationSortTimer?.cancel();
    _durationSortTimer = null;
    _thumbUpdateTimer?.cancel();
    _thumbUpdateTimer = null;
    _pendingThumbUpdates.clear();
    _preloadGeneration++;
    _thumbnailLoadingCancelled = true;
    _viewportQueuedPaths.clear();
  }

  void _enqueueViewportThumbnail(
    Map<dynamic, dynamic> item, {
    LoadPriority priority = LoadPriority.high,
  }) {
    final isMedia = item['is_media'] == true;
    if (!isMedia) return;

    final path = item['path'] as String?;
    if (path == null || path.isEmpty) return;
    final key = _normalizePath(path);

    final needsDuration =
        sortType == 'duration' &&
        _isVideoFile(item['name'] as String?) &&
        item['duration'] == null &&
        thumbCache.getDuration(key) == null;
    if (_viewportQueuedPaths.contains(key) && !needsDuration) {
      if (priority != LoadPriority.low) {
        ParallelThumbnailLoader().promotePath(key, priority);
      }
      return;
    }

    final name = (item['name'] as String?)?.toLowerCase() ?? '';
    final hasThumb = (item['thumb'] as String?)?.isNotEmpty == true;
    final hasDuration = (item['duration'] as num?) != null;

    final workItems = <ThumbnailWorkItem>[];

    if (!hasThumb) {
      workItems.add(
        ThumbnailWorkItem(
          id: '${key}_thumb',
          ip: widget.ip,
          share: widget.share,
          path: key,
          name: item['name'] as String? ?? '',
          username: widget.username,
          password: widget.password,
          type: WorkType.thumbnail,
          item: item,
          initialPriority: priority,
          onError: (_) {
            _viewportQueuedPaths.remove(key);
          },
        ),
      );
    }

    if (_isVideoFile(name) &&
        sortType == 'duration' &&
        !hasDuration &&
        thumbCache.getDuration(key) == null) {
      workItems.add(
        ThumbnailWorkItem(
          id: '${key}_meta',
          ip: widget.ip,
          share: widget.share,
          path: key,
          name: item['name'] as String? ?? '',
          username: widget.username,
          password: widget.password,
          type: WorkType.metadata,
          item: item,
          initialPriority: priority,
          onError: (_) {
            _viewportQueuedPaths.remove(key);
          },
        ),
      );
    }

    if (workItems.isEmpty) return;

    _viewportQueuedPaths.add(key);
    try {
      ParallelThumbnailLoader().addItems(workItems);
    } catch (_) {
      _viewportQueuedPaths.remove(key);
    }
  }

  void _restartBackgroundPreload() {
    _thumbnailLoadingCancelled = false;
    final generation = ++_preloadGeneration;
    unawaited(_preloadFolder(generation));
  }

  Future<void> _preloadFolder(int generation) async {
    final snapshot = List<Map<dynamic, dynamic>>.of(mediaItems);
    for (var i = 0; i < snapshot.length; i++) {
      if (!mounted ||
          _thumbnailLoadingCancelled ||
          generation != _preloadGeneration) {
        return;
      }
      _enqueueViewportThumbnail(snapshot[i], priority: LoadPriority.low);
      if (i % 32 == 31) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }
  }

  void _applyAdaptiveLoaderConfig() {
    ParallelThumbnailLoader().configure();
    // Keep SMB concurrency aligned with UI preloader parallelism.
    SMBClient.configureParallelism(_adaptiveParallelism);
  }

  Future<bool> _tryLoadDirectoryWithRetries(
    String path, {
    required int generation,
    int attempts = 3,
    bool preserveExisting = false,
  }) async {
    // SMB over network is unstable under burst concurrency. Keep this low to avoid
    // the timeouts and connection drops seen when thumbnails/videos are opened.
    // SMB over network is unstable under burst concurrency, and parallel reads
    // on the shared session measured slower than two at a time.
    _adaptiveParallelism = 2;
    _applyAdaptiveLoaderConfig();

    for (var i = 0; i < attempts; i++) {
      if (!mounted || generation != _directoryGeneration) return false;
      try {
        setState(() => status = 'Loading $path (attempt ${i + 1}/$attempts)');

        final result = await SMBClient.listDirectory(
          widget.ip,
          widget.share,
          path,
          username: widget.username,
          password: widget.password,
        );

        if (!mounted || generation != _directoryGeneration) return false;

        if (result.success && result.data != null) {
          final allItems = result.data!
              .map((e) => Map<dynamic, dynamic>.from(e))
              .toList();

          if (preserveExisting) {
            final previous = {
              for (final item in items)
                _normalizePath(item['path'] as String? ?? ''): item,
            };
            for (final item in allItems) {
              final old =
                  previous[_normalizePath(item['path'] as String? ?? '')];
              if (old == null) continue;
              for (final field in ['thumb', 'duration', 'width', 'height']) {
                if (old[field] != null) item[field] = old[field];
              }
            }
          }

          final folders = allItems
              .where((item) => item['is_dir'] == true)
              .toList();
          final media = allItems
              .where((item) => item['is_media'] == true)
              .toList();

          final otherFiles = allItems
              .where(
                (item) => item['is_dir'] != true && item['is_media'] != true,
              )
              .toList();

          // Normalize paths for all items to ensure thumbnail event matching works
          for (final item in folders) {
            final p = item['path'] as String? ?? '';
            item['path'] = _normalizePath(p);
          }
          for (final item in [...media, ...otherFiles]) {
            final p = item['path'] as String? ?? '';
            item['path'] = _normalizePath(p);
            // Restore before the first sort, including off-screen videos.
            // A cached duration also suppresses another metadata request.
            final cached = thumbCache.peek(item['path'] as String);
            if (cached != null) {
              item['duration'] ??= cached.duration;
              if (cached.thumbPath.isNotEmpty) {
                item['thumb'] ??= cached.thumbPath;
              }
            }
          }

          folders.sort((a, b) => _compareNames(a, b));

          setState(() {
            items = [...folders, ...media, ...otherFiles];
            mediaItems = media;
            _itemsByPath = {
              for (final item in items) item['path'] as String: item,
            };
            if (preserveExisting) {
              final remaining = items.map((item) => item['path']).toSet();
              _selectedPaths.retainWhere(remaining.contains);
            }
            status =
                'Loaded ${items.length} items (${folders.length} folders, ${media.length} media)';
            if (result.retryCount > 0) {
              status += ' [retry: ${result.retryCount}x]';
            }
          });

          if (sortType != null) {
            _sortMedia(
              sortType!,
              restartBackgroundLoading: false,
              persist: false,
            );
            // Pre-queue runs from within _sortMedia after sort completes
          } else {
            // No sort applied, but still pre-queue media items for thumbnail loading
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _thumbnailLoadingCancelled) return;
              // Cap initial pre-queue to avoid SMB burst that causes Read timed out.
              final preQueueLimit = mediaItems.length.clamp(0, 8);
              int preQueued = 0;
              for (int i = 0; i < preQueueLimit; i++) {
                _enqueueViewportThumbnail(mediaItems[i]);
                preQueued++;
              }
              if (preQueued > 0) {
                debugPrint(
                  'Pre-queued $preQueued media items for initial load (no sort)',
                );
              }
            });
          }

          // â”€â”€ Restaura thumbs e metadata do cache persistente â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          debugPrint(
            'Directory loaded. Viewport-first thumbnail loading enabled.',
          );

          // Stop any previous viewport queue and let the visible cells enqueue new work.
          _cancelThumbnailLoading();
          _thumbnailLoadingCancelled = false;
          _restartBackgroundPreload();

          return true;
        } else {
          debugPrint('listDirectory failed: ${result.error}');
          // Exponential backoff: 500ms, 1s, 2s, 4s, 8s
          if (i < attempts - 1) {
            final delayMs = 500 * (1 << i); // 500, 1000, 2000, 4000, 8000
            await Future.delayed(Duration(milliseconds: delayMs));
          }
        }
      } catch (e) {
        debugPrint('listDirectory unexpected error: $e');
        if (i < attempts - 1) {
          final delayMs = 500 * (1 << i);
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }
    }

    return false;
  }

  /// Atualiza o status periodicamente com progresso do loader
  Timer? _progressTimer;

  void _startProgressUpdates() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final stats = ParallelThumbnailLoader().stats;
      if (stats.totalItems > 0) {
        setState(() {
          if (stats.isFinished) {
            if (stats.failedItems == 0) {
              status =
                  'Thumbnails verified: ${stats.completedItems}/${stats.totalItems} ready';
            } else {
              final failedPreview = stats.failedPaths
                  .take(3)
                  .map((path) => path.split('/').last)
                  .join(', ');
              final extra = failedPreview.isEmpty
                  ? ''
                  : ' ($failedPreview${stats.failedPaths.length > 3 ? ', ...' : ''})';
              status =
                  'Completed with ${stats.failedItems} failure(s): ${stats.completedItems}/${stats.totalItems} ready$extra';
            }
          } else {
            status =
                'Loading thumbnails: ${stats.completedItems}/${stats.totalItems}';
          }
        });
      }
    });
  }

  void _sortMedia(
    String type, {
    bool restartBackgroundLoading = true,
    bool persist = true,
  }) {
    if (_folderViews == null) return;
    setState(() {
      sortType = type;
      ParallelThumbnailLoader().currentSortType = type;
      final folders = items.where((item) => item['is_dir'] == true).toList();
      final media = List<Map<dynamic, dynamic>>.from(mediaItems);
      final otherFiles =
          items
              .where(
                (item) => item['is_dir'] != true && item['is_media'] != true,
              )
              .toList()
            ..sort((a, b) => _compareNames(a, b));

      // Sort folders by the selected type
      switch (type) {
        case 'recent':
          folders.sort((a, b) {
            final aMod = (a['modified'] as num?)?.toDouble() ?? 0.0;
            final bMod = (b['modified'] as num?)?.toDouble() ?? 0.0;
            return bMod.compareTo(aMod);
          });
          media.sort((a, b) {
            final aMod = (a['modified'] as num?)?.toDouble() ?? 0.0;
            final bMod = (b['modified'] as num?)?.toDouble() ?? 0.0;
            return bMod.compareTo(aMod);
          });
          break;
        case 'size':
          int compareBySizeWithTieBreak(Map a, Map b) {
            final aSize = (a['size'] as num?)?.toInt() ?? 0;
            final bSize = (b['size'] as num?)?.toInt() ?? 0;
            // Primary: file size
            final sizeComp = bSize.compareTo(aSize);
            if (sizeComp != 0) return sizeComp;

            // Tie-breaker 1: estimated bitrate when duration is available
            final aDur = (a['duration'] as num?)?.toDouble() ?? 0.0;
            final bDur = (b['duration'] as num?)?.toDouble() ?? 0.0;
            if (aDur > 0 && bDur > 0) {
              final aBit = (aSize * 8) / aDur; // bits per second
              final bBit = (bSize * 8) / bDur;
              final bitComp = bBit.compareTo(aBit);
              if (bitComp != 0) return bitComp;
            } else if (aDur > 0 && bDur == 0) {
              // prefer item that has duration metadata (likely video)
              return -1; // put b (no duration) after a
            } else if (bDur > 0 && aDur == 0) {
              return 1;
            }

            // Tie-breaker 2: longer duration (prefer more content)
            if (aDur != bDur) return bDur.compareTo(aDur);

            // Tie-breaker 3: attempt to prefer larger image resolution if metadata exists
            final aW = (a['width'] as num?)?.toInt();
            final aH = (a['height'] as num?)?.toInt();
            final bW = (b['width'] as num?)?.toInt();
            final bH = (b['height'] as num?)?.toInt();
            if (aW != null && aH != null && bW != null && bH != null) {
              final aPx = aW * aH;
              final bPx = bW * bH;
              final pxComp = bPx.compareTo(aPx);
              if (pxComp != 0) return pxComp;
            }

            // Final fallback: modified date (more recent first), then name
            final aMod = (a['modified'] as num?)?.toDouble() ?? 0.0;
            final bMod = (b['modified'] as num?)?.toDouble() ?? 0.0;
            final modComp = bMod.compareTo(aMod);
            if (modComp != 0) return modComp;

            return _compareNames(a, b);
          }

          folders.sort((a, b) {
            final aSize = (a['size'] as num?)?.toInt() ?? 0;
            final bSize = (b['size'] as num?)?.toInt() ?? 0;
            return bSize.compareTo(aSize);
          });
          media.sort((a, b) => compareBySizeWithTieBreak(a, b));
          break;
        case 'duration':
          media.sort((a, b) {
            final aDur = (a['duration'] as num?)?.toDouble() ?? 0.0;
            final bDur = (b['duration'] as num?)?.toDouble() ?? 0.0;
            return bDur.compareTo(aDur);
          });
          break;
        case 'name':
          folders.sort((a, b) => _compareNames(a, b));
          media.sort((a, b) => _compareNames(a, b));
          break;
      }

      items = [...folders, ...media, ...otherFiles];
      mediaItems = media;
    });

    // After sort completes and frame is built, pre-queue media items for thumbnail loading
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _thumbnailLoadingCancelled) return;
      // Cap initial pre-queue to avoid SMB burst that causes Read timed out.
      final preQueueLimit = mediaItems.length.clamp(0, 8);
      int preQueued = 0;
      for (int i = 0; i < preQueueLimit; i++) {
        _enqueueViewportThumbnail(mediaItems[i]);
        preQueued++;
      }
      if (preQueued > 0) {
        debugPrint(
          'Pre-queued $preQueued media items for initial load after sort',
        );
      }
    });

    // Save sort preference for current folder
    if (persist) {
      _scrollToTop();
      unawaited(_saveFolderView());
    }

    if (restartBackgroundLoading) {
      _restartBackgroundPreload();
    }
  }

  // Check if item is a video
  bool _isVideoFile(String? name) {
    if (name == null) return false;
    final n = name.toLowerCase();
    return n.endsWith('.mp4') ||
        n.endsWith('.avi') ||
        n.endsWith('.mkv') ||
        n.endsWith('.mov') ||
        n.endsWith('.3gp') ||
        n.endsWith('.webm') ||
        n.endsWith('.flv') ||
        n.endsWith('.wmv') ||
        n.endsWith('.m4v');
  }

  // Check if item is an image or GIF
  bool _isImageLike(String? name) {
    if (name == null) return false;
    final n = name.toLowerCase();
    return n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.png') ||
        n.endsWith('.gif') ||
        n.endsWith('.bmp') ||
        n.endsWith('.webp') ||
        n.endsWith('.svg') ||
        n.endsWith('.ico');
  }

  // Legacy batch thumbnail generation removed.

  void _navigateToFolder(Map item) {
    // Cancela todos os trabalhos quando muda de pasta
    // Cancela preload de thumbs e timers ao navegar
    ParallelThumbnailLoader().cancelAll();
    _cancelThumbnailLoading();
    _progressTimer?.cancel();
    thumbCache.flush();

    final raw = item['path'] as String? ?? item['name'] as String? ?? '';
    final newPath = _normalizePath(raw);
    _loadDirectory(newPath);
  }

  bool _isFavorite(Map item) {
    final path = item['path'] as String? ?? '';
    return _favorites.contains(path);
  }

  Future<void> _toggleFavorite(Map item) async {
    final path = item['path'] as String? ?? '';
    final key = 'favorites:${widget.ip}:${widget.share}';
    if (_favorites.contains(path)) {
      _favorites.remove(path);
    } else {
      _favorites.add(path);
    }
    await _prefs.setStringList(key, _favorites.toList());
    if (mounted) setState(() {});
  }

  void _toggleSelection(Map item) {
    final path = item['path'] as String?;
    if (path == null || path.isEmpty) return;

    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
      } else {
        _selectedPaths.add(path);
      }
    });
  }

  void _clearSelection() {
    if (_selectedPaths.isEmpty) return;
    setState(() {
      _selectedPaths.clear();
    });
  }

  bool _isSelected(Map item) {
    final path = item['path'] as String?;
    if (path == null || path.isEmpty) return false;
    return _selectedPaths.contains(path);
  }

  /// Shows a folder picker within the same SMB share and copies/moves selected items there.
  Future<void> _copyOrMoveSelected({required bool move}) async {
    ParallelThumbnailLoader().cancelAll();
    _cancelThumbnailLoading();
    if (_selectedPaths.isEmpty) return;

    final selectedItems = items.where((item) {
      final path = item['path'] as String?;
      return path != null && _selectedPaths.contains(path);
    }).toList();

    // Let user pick a destination folder by browsing the share
    final destPath = await Navigator.of(context).push<String?>(
      MaterialPageRoute(
        builder: (_) => _FolderPickerScreen(
          ip: widget.ip,
          share: widget.share,
          username: widget.username,
          password: widget.password,
          title: move ? 'Mover para...' : 'Copiar para...',
          excludePaths: _selectedPaths,
        ),
      ),
    );

    if (destPath == null || !mounted) return;

    // Normalise destination: ensure trailing slash
    final dest = destPath.endsWith('/') ? destPath : '$destPath/';

    final total = selectedItems.length;
    final progress = ValueNotifier<(int, int)>((0, 0)); // (done, failed)
    var cancelled = false;
    var dialogOpen = true;
    BuildContext? dialogContext;

    // Not awaited: the copy loop below runs while the dialog is visible.
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          dialogContext = ctx;
          return AlertDialog(
            title: Text(move ? 'Movendo...' : 'Copiando...'),
            content: ValueListenableBuilder<(int, int)>(
              valueListenable: progress,
              builder: (_, value, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: total > 0 ? value.$1 / total : null,
                  ),
                  const SizedBox(height: 8),
                  Text('${value.$1} / $total'),
                  if (value.$2 > 0)
                    Text(
                      '${value.$2} falha(s)',
                      style: const TextStyle(color: Colors.red),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancelled = true;
                  Navigator.of(ctx).pop();
                },
                child: const Text('Cancelar'),
              ),
            ],
          );
        },
      ).whenComplete(() => dialogOpen = false),
    );

    var done = 0;
    var failed = 0;
    for (final item in selectedItems) {
      if (cancelled || !mounted) break;
      final srcPath = item['path'] as String? ?? '';
      final name = srcPath
          .split('/')
          .where((part) => part.isNotEmpty)
          .lastOrNull;
      if (name == null) {
        failed++;
        done++;
        progress.value = (done, failed);
        continue;
      }
      final dstPath = '$dest$name';

      try {
        final res = move
            ? await SMBClient.moveFile(
                widget.ip,
                widget.share,
                srcPath,
                dstPath,
                username: widget.username,
                password: widget.password,
              )
            : await SMBClient.copyFile(
                widget.ip,
                widget.share,
                srcPath,
                dstPath,
                username: widget.username,
                password: widget.password,
              );

        if (res.success) {
          if (move) {
            items.removeWhere((i) => i['path'] == srcPath);
            mediaItems.removeWhere((i) => i['path'] == srcPath);
            _selectedPaths.remove(srcPath);
            _favorites.remove(srcPath);
            await thumbCache.remove(srcPath);
          }
        } else {
          failed++;
        }
      } catch (_) {
        failed++;
      }
      done++;
      progress.value = (done, failed);
      if (mounted) setState(() {});
    }

    if (dialogOpen && dialogContext != null && dialogContext!.mounted) {
      Navigator.of(dialogContext!).pop();
    }
    progress.dispose();
    if (!mounted) return;
    setState(() {
      if (move) _selectedPaths.clear();
    });
    final action = move ? 'Movido' : 'Copiado';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$action: ${done - failed}/$total${failed > 0 ? ', $failed falha(s)' : ''}',
        ),
      ),
    );
    if (move) {
      final favKey = 'favorites:${widget.ip}:${widget.share}';
      await _prefs.setStringList(favKey, _favorites.toList());
    }
  }

  Future<void> _deleteSelectedItems() async {
    if (_selectedPaths.isEmpty) return;

    final selectedItems = items.where((item) {
      final path = item['path'] as String?;
      return path != null && _selectedPaths.contains(path);
    }).toList();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete selected items'),
        content: Text('Delete ${selectedItems.length} selected items?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (!mounted || confirm != true) return;

    int successCount = 0;
    int failCount = 0;

    for (final item in selectedItems) {
      final path = item['path'] as String? ?? '';
      if (path.isEmpty) {
        failCount++;
        continue;
      }

      try {
        final result = await SMBClient.deleteFile(
          widget.ip,
          widget.share,
          path,
          username: widget.username,
          password: widget.password,
        );

        if (result.success) {
          successCount++;

          _favorites.remove(path);

          if (item['is_media'] == true) {
            await thumbCache.remove(path);
          }

          items.removeWhere((i) => i['path'] == path);
          mediaItems.removeWhere((i) => i['path'] == path);
          _selectedPaths.remove(path);
        } else {
          failCount++;
        }
      } catch (_) {
        failCount++;
      }
    }

    final favKey = 'favorites:${widget.ip}:${widget.share}';
    await _prefs.setStringList(favKey, _favorites.toList());

    if (!mounted) return;
    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted: $successCount, failed: $failCount')),
    );
  }

  // Intercept back button to go to parent folder instead of popping to home
  Future<bool> _onWillPop() async {
    if (_showSearch) {
      _closeSearch();
      return false;
    }
    if (_isSelectionMode) {
      _clearSelection();
      return false;
    }

    // Cancel thumbnail loading when navigating back
    _thumbnailLoadingCancelled = true;
    debugPrint('Navigating back, cancelled thumbnail loading');
    final p = currentPath.replaceAll('\\', '/');
    if (p != '/' && p.trim().isNotEmpty) {
      var q = p;
      if (q.endsWith('/')) {
        q = q.substring(0, q.length - 1);
      }
      final idx = q.lastIndexOf('/');
      String parent = idx <= 0 ? '/' : q.substring(0, idx + 1);

      await _loadDirectory(parent);

      return false; // successfully loaded parent, stay on the same screen
    }
    return true;
  }

  Future<void> _openMedia(Map item, int index) async {
    debugPrint('Opening media and pausing folder preload');
    _cancelThumbnailLoading();
    _progressTimer?.cancel();
    ParallelThumbnailLoader().cancelAll();

    // Filter media list by type - separate videos and images
    final mediaName = (item['name'] as String?)?.toLowerCase() ?? '';
    final isVideo = _isVideoFile(mediaName);

    final filteredList = mediaItems.where((m) {
      if (!_matchesFilters(m)) return false;
      final mName = (m['name'] as String?)?.toLowerCase() ?? '';
      if (isVideo) {
        return _isVideoFile(mName); // Only videos
      } else {
        return _isImageLike(mName); // Only images
      }
    }).toList();

    // Find the index in filtered list by comparing paths
    final itemPath = item['path'] as String?;
    final filteredIndex = filteredList.indexWhere((m) => m['path'] == itemPath);

    debugPrint(
      'Opening media: name=${item['name']}, path=$itemPath, filteredIndex=$filteredIndex, filteredListLength=$filteredList.length',
    );

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MediaViewerScreen(
          key: ValueKey(
            'media_${item['path']}',
          ), // Force new instance for each media
          ip: widget.ip,
          share: widget.share,
          username: widget.username,
          password: widget.password,
          initialItem: item,
          initialIndex: filteredIndex >= 0 ? filteredIndex : 0,
          mediaList: filteredList,
        ),
      ),
    );

    if (!mounted) return;
    _restartBackgroundPreload();
    _startProgressUpdates();
  }

  String get _currentFolderName =>
      currentPath.split('/').where((part) => part.isNotEmpty).lastOrNull ??
      widget.share;

  String _formatDurationSeconds(double s) {
    final total = s.round();
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final localeController = AppLocaleScope.of(context);
    final visibleItems = items.where(_matchesFilters).toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearSelection,
              )
            : null,
        title: _isSelectionMode
            ? Text('${_selectedPaths.length} selected')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _currentFolderName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${widget.share}$currentPath',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
        actions: [
          if (_isSelectionMode) ...[
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copiar para...',
              onPressed: () => _copyOrMoveSelected(move: false),
            ),
            IconButton(
              icon: const Icon(Icons.drive_file_move),
              tooltip: 'Mover para...',
              onPressed: () => _copyOrMoveSelected(move: true),
            ),
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _deleteSelectedItems,
            ),
          ] else ...[
            IconButton(
              key: const ValueKey('refresh-folder'),
              tooltip: t(context, 'refreshFolder'),
              onPressed: _refreshing ? null : _refreshDirectory,
              icon: _refreshing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
            IconButton(
              tooltip: t(context, _showSearch ? 'closeSearch' : 'searchNames'),
              icon: Icon(
                _showSearch ? Icons.search_off_rounded : Icons.search_rounded,
              ),
              onPressed: () {
                if (_showSearch) {
                  _closeSearch();
                } else {
                  setState(() => _showSearch = true);
                }
              },
            ),
            PopupMenuButton<AppLocaleMode>(
              tooltip: t(context, 'language'),
              icon: const Icon(Icons.language),
              initialValue: localeController.mode,
              onSelected: (mode) => localeController.setMode(mode),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: AppLocaleMode.system,
                  child: Text(t(context, 'useSystemLanguage')),
                ),
                PopupMenuItem(
                  value: AppLocaleMode.ptBr,
                  child: Text(t(context, 'portugueseBrazil')),
                ),
                PopupMenuItem(
                  value: AppLocaleMode.en,
                  child: Text(t(context, 'english')),
                ),
              ],
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'favorites') {
                  _toggleFavoritesFilter();
                } else {
                  _sortMedia(value);
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'name',
                  child: Row(
                    children: [
                      if (sortType == 'name') const Icon(Icons.check, size: 16),
                      if (sortType == 'name') const SizedBox(width: 8),
                      Text(t(context, 'name')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'recent',
                  child: Row(
                    children: [
                      if (sortType == 'recent')
                        const Icon(Icons.check, size: 16),
                      if (sortType == 'recent') const SizedBox(width: 8),
                      Text(t(context, 'mostRecent')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'size',
                  child: Row(
                    children: [
                      if (sortType == 'size') const Icon(Icons.check, size: 16),
                      if (sortType == 'size') const SizedBox(width: 8),
                      Text(t(context, 'largestSize')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'duration',
                  child: Row(
                    children: [
                      if (sortType == 'duration')
                        const Icon(Icons.check, size: 16),
                      if (sortType == 'duration') const SizedBox(width: 8),
                      Text(t(context, 'longestDuration')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'favorites',
                  child: Row(
                    children: [
                      if (_filter == 'favorites')
                        const Icon(Icons.check, size: 16),
                      if (_filter == 'favorites') const SizedBox(width: 8),
                      Text(t(context, 'favorites')),
                    ],
                  ),
                ),
              ],
              icon: const Icon(Icons.sort),
            ),
          ],
        ],
      ),
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (bool didPop, dynamic result) async {
          if (didPop) return;
          final navigator = Navigator.of(context);
          final allow = await _onWillPop();
          if (!mounted) return;
          if (allow) {
            // allow system to pop the route (e.g., back to server list)
            navigator.pop();
          }
        },
        child: Column(
          children: [
            if (_showSearch)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  key: const ValueKey('directory_search'),
                  controller: _searchController,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: t(context, 'searchHint'),
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searchQuery.isEmpty
                        ? null
                        : IconButton(
                            tooltip: t(context, 'clearSearch'),
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          ),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = normalizeSearchName(value);
                      _selectedPaths.clear();
                    });
                    _scrollToTop();
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_open_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    t(
                      context,
                      'results',
                      params: {'count': '${visibleItems.length}'},
                    ),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Text('${t(context, 'activeFilters')}: '),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: Text(t(context, 'name')),
                      selected: sortType == 'name' || sortType == null,
                      onSelected: (_) => _sortMedia('name'),
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: Text(t(context, 'mostRecent')),
                      selected: sortType == 'recent',
                      onSelected: (_) => _sortMedia('recent'),
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: Text(t(context, 'largestSize')),
                      selected: sortType == 'size',
                      onSelected: (_) => _sortMedia('size'),
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: Text(t(context, 'longestDuration')),
                      selected: sortType == 'duration',
                      onSelected: (_) => _sortMedia('duration'),
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: Text(
                        _filter == 'favorites'
                            ? t(context, 'favoritesOnly')
                            : t(context, 'allMedia'),
                      ),
                      selected: _filter == 'favorites',
                      onSelected: (_) => _toggleFavoritesFilter(),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: visibleItems.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _searchQuery.isEmpty
                                ? Icons.folder_open_rounded
                                : Icons.search_off_rounded,
                            size: 48,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            t(
                              context,
                              _searchQuery.isEmpty
                                  ? 'emptyFolder'
                                  : 'noMatches',
                            ),
                          ),
                        ],
                      ),
                    )
                  : GridView.builder(
                      controller: _gridScroll,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.all(16.0),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: _gridMaxTileExtent,
                            childAspectRatio: 1,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                      itemCount: visibleItems.length,
                      itemBuilder: (context, index) {
                        final item = visibleItems[index];
                        final isDir = item['is_dir'] == true;
                        final isMedia = item['is_media'] == true;

                        if (isMedia && !_thumbnailLoadingCancelled) {
                          _enqueueViewportThumbnail(
                            item,
                            priority: LoadPriority.critical,
                          );
                        }

                        if (isDir) {
                          return GestureDetector(
                            onLongPress: () => _toggleSelection(item),
                            onTap: () {
                              if (_isSelectionMode) {
                                _toggleSelection(item);
                                return;
                              }
                              _navigateToFolder(item);
                            },
                            child: Card(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.folder_rounded,
                                    size: 42,
                                    color: Color(0xFFDFC18A),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    item['name'] ?? '',
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (_isSelected(item))
                                    const Padding(
                                      padding: EdgeInsets.only(top: 4.0),
                                      child: Icon(
                                        Icons.check_circle,
                                        color: Colors.lightBlueAccent,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        }

                        if (isMedia) {
                          final name =
                              (item['name'] as String?)?.toLowerCase() ?? '';
                          final isVideo = _isVideoFile(name);
                          final isGif = name.endsWith('.gif');
                          final selected = _isSelected(item);

                          // Usa widget otimizado com carregamento paralelo e priorização por visibilidade
                          return GestureDetector(
                            onLongPress: () => _toggleSelection(item),
                            onTap: () {
                              if (_isSelectionMode) {
                                _toggleSelection(item);
                                return;
                              }
                              _openMedia(item, index);
                            },
                            child: Container(
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                color: selected
                                    ? Theme.of(
                                        context,
                                      ).colorScheme.primaryContainer
                                    : Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(16),
                                border: selected
                                    ? Border.all(
                                        color: Colors.lightBlueAccent,
                                        width: 2,
                                      )
                                    : null,
                              ),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  _buildGridThumbnail(
                                    item,
                                    isVideo: isVideo,
                                    isGif: isGif,
                                  ),

                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      padding: const EdgeInsets.fromLTRB(
                                        10,
                                        22,
                                        32,
                                        8,
                                      ),
                                      decoration: const BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Colors.transparent,
                                            Color(0xDD101820),
                                          ],
                                        ),
                                      ),
                                      child: Text(
                                        item['name'] as String? ?? '',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ),
                                  // Video play icon
                                  if (isVideo)
                                    const Positioned(
                                      bottom: 4,
                                      right: 4,
                                      child: Icon(
                                        Icons.play_circle,
                                        color: Colors.white,
                                        size: 24,
                                      ),
                                    ),

                                  // GIF badge
                                  if (isGif)
                                    Positioned(
                                      bottom: 4,
                                      right: 4,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.purple.withValues(
                                            alpha: 0.8,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: const Text(
                                          'GIF',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),

                                  // Duration overlay
                                  if (item['duration'] != null &&
                                      (item['duration'] as double) > 0)
                                    Positioned(
                                      top: 4,
                                      right: 4,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black54,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          _formatDurationSeconds(
                                            item['duration'] as double,
                                          ),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    ),

                                  // Favorite button
                                  if (!_isSelectionMode)
                                    Positioned(
                                      top: 0,
                                      left: 0,
                                      // 40dp hit area around the 24dp star so
                                      // it doesn't open the media by mistake.
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () => _toggleFavorite(item),
                                        child: Padding(
                                          padding: const EdgeInsets.all(8),
                                          child: Icon(
                                            _isFavorite(item)
                                                ? Icons.star
                                                : Icons.star_border,
                                            color: _isFavorite(item)
                                                ? Colors.yellow
                                                : Colors.white,
                                            size: 24,
                                            shadows: const [
                                              Shadow(
                                                color: Colors.black54,
                                                blurRadius: 4,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),

                                  if (selected)
                                    const Positioned(
                                      top: 4,
                                      left: 4,
                                      child: Icon(
                                        Icons.check_circle,
                                        color: Colors.lightBlueAccent,
                                        size: 24,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        }

                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.description_outlined,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                  size: 32,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  item['name'] ?? '',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGridThumbnail(
    Map item, {
    required bool isVideo,
    required bool isGif,
  }) {
    final thumbPath = item['thumb'] as String?;
    if (thumbPath != null && thumbPath.isNotEmpty) {
      final decodeTarget = _gridThumbDecodeTarget();
      final provider = ResizeImage.resizeIfNeeded(
        decodeTarget,
        decodeTarget,
        FileImage(File(thumbPath)),
      );
      return RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image(
            image: provider,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return Container(
                color: Colors.grey[900],
                child: Center(
                  child: isVideo
                      ? const Icon(
                          Icons.video_file,
                          color: Colors.grey,
                          size: 40,
                        )
                      : isGif
                      ? const Icon(Icons.gif_box, color: Colors.grey, size: 40)
                      : const Icon(Icons.image, color: Colors.grey, size: 40),
                ),
              );
            },
          ),
        ),
      );
    }

    return Container(
      color: Colors.grey[900],
      child: Center(
        child: isVideo
            ? const Icon(Icons.video_file, color: Colors.grey, size: 40)
            : isGif
            ? const Icon(Icons.gif_box, color: Colors.grey, size: 40)
            : const Icon(Icons.image, color: Colors.grey, size: 40),
      ),
    );
  }

  // Three columns on a typical phone so large folders need less scrolling.
  static const double _gridMaxTileExtent = 140;

  int _gridThumbDecodeTarget() {
    final mediaQuery = MediaQuery.of(context);
    final width = mediaQuery.size.width;
    final dpr = mediaQuery.devicePixelRatio;
    const horizontalPadding = 32.0;
    final columns = ((width - horizontalPadding) / (_gridMaxTileExtent + 8))
        .ceil()
        .clamp(1, 100);
    final totalSpacing = (columns - 1) * 8.0;
    final cardWidth = ((width - horizontalPadding - totalSpacing) / columns)
        .clamp(64.0, 256.0);
    final target = (cardWidth * dpr).ceil();
    return target.clamp(96, 360).toInt();
  }
}

class MediaViewerScreen extends StatefulWidget {
  final String ip;
  final String share;
  final String username;
  final String password;
  final Map<dynamic, dynamic> initialItem;
  final int initialIndex;
  final List<Map<dynamic, dynamic>> mediaList;

  const MediaViewerScreen({
    required this.ip,
    required this.share,
    this.username = '',
    this.password = '',
    required this.initialItem,
    required this.initialIndex,
    required this.mediaList,
    super.key,
  });

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _VideoStreamingProfile {
  final bool lowLatency;
  final int chunkSizeBytes;
  final int maxChunks;
  final int prefetchChunks;
  final int warmupChunks;
  final int networkCachingMs;
  final int preloadRadius;

  const _VideoStreamingProfile({
    required this.lowLatency,
    required this.chunkSizeBytes,
    required this.maxChunks,
    required this.prefetchChunks,
    required this.warmupChunks,
    required this.networkCachingMs,
    required this.preloadRadius,
  });
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  late int currentIndex;
  late Map<dynamic, dynamic> currentItem;
  late List<Map<dynamic, dynamic>> _filteredList;
  String? localPath;
  String? _cachedLocalPath;
  bool loading = true;
  String? error;
  VlcPlayerController? _videoController;
  String? _videoProxyToken;
  final Map<String, Uri> _preloadedStreamUris = {};
  final Set<String> _pendingPreloadPaths = {};
  final Set<String> _preloadedTokens = <String>{};
  Future<ui.Image>? _decodedImageFuture;
  String? _decodedImagePath;

  // Video seek/position state
  Duration _currentPosition = Duration.zero;
  Duration _videoDuration = Duration.zero;
  bool _isSeeking = false;
  double _playbackSpeed = 1.0;
  bool _showViewerControls = true;
  bool _vrModeEnabled = false;
  bool _vrLowLatencyMode = false;
  Timer? _controlsHideTimer;
  DateTime? _lastMediaLoadedAt;
  DateTime? _lastVideoRestartAt;
  DateTime? _lastVideoUiRefreshAt;

  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);

  // Navigation cancellation
  int _navigationVersion = 0;

  // Id of the in-flight full-file download, cancelled when the user moves on.
  String? _activeFetchId;

  String _startFetch() {
    _cancelActiveFetch();
    return _activeFetchId = '${identityHashCode(this)}-${++_fetchCounter}';
  }

  int _fetchCounter = 0;

  void _cancelActiveFetch() {
    final id = _activeFetchId;
    _activeFetchId = null;
    if (id != null) unawaited(SMBClient.cancelFetch(id));
  }

  // Load timing, logged as [MEDIA_TIMING] to compare media open/switch costs.
  final Stopwatch _loadWatch = Stopwatch();
  bool _firstPlayLogged = false;

  void _logTiming(String event) {
    debugPrint(
      '[MEDIA_TIMING] ${_loadWatch.elapsedMilliseconds}ms $event '
      '(${currentItem['name']})',
    );
  }

  // Download-for-edit progress state
  // ignore: unused_field
  bool _downloadingForEdit = false;
  // ignore: unused_field
  ValueNotifier<bool>? _downloadCancelToken;

  @override
  void initState() {
    super.initState();

    // Use the mediaList directly and the initialIndex passed from parent
    _filteredList = widget.mediaList;
    currentIndex = widget.initialIndex;

    debugPrint(
      'MediaViewer init: initialIndex=${widget.initialIndex}, mediaListLength=${widget.mediaList.length}, itemName=${widget.initialItem['name']}',
    );

    if (currentIndex < 0 || currentIndex >= _filteredList.length) {
      currentIndex = 0;
    }

    currentItem = _filteredList[currentIndex];
    _loadCurrentMedia();
  }

  Future<void> _disposeVideoController(VlcPlayerController? controller) async {
    if (controller == null) return;
    final watch = Stopwatch()..start();
    try {
      controller.removeListener(_videoListener);
    } catch (_) {}
    try {
      await controller.pause();
    } catch (_) {}
    try {
      await controller.stop();
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
    debugPrint('[MEDIA_TIMING] player disposed in ${watch.elapsedMilliseconds}ms');
  }

  @override
  void dispose() {
    _cancelActiveFetch();
    _downloadCancelToken?.value = true;
    _controlsHideTimer?.cancel();
    final controller = _videoController;
    _videoController = null;
    unawaited(_disposeVideoController(controller));

    // Delete current video from cache when closing viewer
    _deleteCurrentVideoFromCache();
    _releaseDecodedImage();
    smbVideoProxyServer.unregisterSource(_videoProxyToken);
    for (final token in _preloadedTokens) {
      smbVideoProxyServer.unregisterSource(token);
    }
    _preloadedTokens.clear();
    _preloadedStreamUris.clear();

    super.dispose();
  }

  Future<void> _loadCurrentMedia() async {
    final myVersion = ++_navigationVersion;
    _loadWatch
      ..reset()
      ..start();
    _firstPlayLogged = false;
    _cancelActiveFetch();
    _logTiming('load start, size=${currentItem['size']}');

    setState(() {
      loading = true;
      error = null;
      localPath = null;
      _releaseDecodedImage();
      _vrModeEnabled = false;
    });

    // Release the previous player in the background: VLC teardown took up to
    // 1.7 s and the next media does not depend on it (the listener is removed
    // synchronously, so the old player can no longer touch this state).
    final oldController = _videoController;
    _videoController = null;
    unawaited(_disposeVideoController(oldController));
    smbVideoProxyServer.unregisterSource(_videoProxyToken);
    _videoProxyToken = null;

    try {
      if (_isVideo()) {
        final smbPath = currentItem['path'] as String? ?? '';
        final size = (currentItem['size'] as num?)?.toInt();
        final profile = _buildVideoStreamingProfile(size);

        // Only short clips are downloaded whole; anything bigger streams through
        // the range proxy so playback starts after the first megabytes instead
        // of after the entire file (a 250 MB file took ~100 s on slow links).
        const maxLocalVideoSizeBytes = 8 * 1024 * 1024;
        final shouldUseLocalFallback =
            size != null && size <= maxLocalVideoSizeBytes;
        if (shouldUseLocalFallback) {
          final localResult = await SMBClient.fetchFile(
            widget.ip,
            widget.share,
            smbPath,
            username: widget.username,
            password: widget.password,
            requestId: _startFetch(),
            timeout: const Duration(minutes: 10),
          );

          _logTiming('local fetch done');
          if (myVersion != _navigationVersion || !mounted) {
            await deleteCachedFileIfNeeded(localResult.data);
            return;
          }
          _activeFetchId = null;

          if (localResult.success &&
              localResult.data != null &&
              localResult.data!.isNotEmpty) {
            final localFile = File(localResult.data!);
            if (await localFile.exists()) {
              final controller = VlcPlayerController.file(localFile);
              controller.addOnInitListener(() async {
                if (myVersion != _navigationVersion || !mounted) {
                  await _disposeVideoController(controller);
                  return;
                }
                try {
                  await controller.setLooping(true);
                  await controller.setPlaybackSpeed(_playbackSpeed);
                  await controller.play();
                } catch (_) {}
              });

              controller.addListener(_videoListener);
              // Deleted on swipe/close by _deleteCurrentVideoFromCache.
              _cachedLocalPath = localFile.path;
              setState(() {
                _videoController = controller;
                localPath = localFile.path;
                _videoDuration = controller.value.duration;
                _currentPosition = controller.value.position;
                final shouldVr = _shouldUseVrViewer();
                _vrModeEnabled = shouldVr;

                loading = false;
                _lastMediaLoadedAt = DateTime.now();
              });
              _showControlsTransiently();
              _registerFetchedFile(localFile.path);
              return;
            }
          }
        }

        final preloaded = _takePreloadedStreamUri(smbPath);
        final streamUri =
            preloaded ??
            await _registerVideoSource(
              path: smbPath,
              fileSizeOverride: size,
              profile: profile,
            );
        _videoProxyToken = streamUri.queryParameters['token'];

        if (myVersion != _navigationVersion || !mounted) return;

        final controller = VlcPlayerController.network(
          streamUri.toString(),
          autoPlay: false,
          options: VlcPlayerOptions(
            advanced: VlcAdvancedOptions([
              VlcAdvancedOptions.networkCaching(profile.networkCachingMs),
            ]),
            http: VlcHttpOptions([VlcHttpOptions.httpReconnect(true)]),
          ),
        );
        controller.addOnInitListener(() async {
          if (myVersion != _navigationVersion || !mounted) {
            await _disposeVideoController(controller);
            return;
          }

          try {
            await controller.setLooping(true);
            await controller.setPlaybackSpeed(_playbackSpeed);
            await controller.play();
          } catch (_) {}
        });

        try {
          if (myVersion != _navigationVersion) {
            await controller.dispose();
            return;
          }

          if (!mounted) return;

          controller.addListener(_videoListener);
          setState(() {
            _videoController = controller;
            localPath = streamUri.toString();
            _videoDuration = controller.value.duration;
            _currentPosition = controller.value.position;
            final shouldVr = _shouldUseVrViewer();
            _vrModeEnabled = shouldVr;

            loading = false;
            _lastMediaLoadedAt = DateTime.now();
          });
          _preloadAdjacent(profile: profile);
          _showControlsTransiently();
          return;
        } catch (e) {
          await controller.dispose();
          if (mounted) {
            setState(() {
              error = "Erro ao carregar vídeo: $e";
              loading = false;
            });
          }
          return;
        }
      }

      final result = await SMBClient.fetchFile(
        widget.ip,
        widget.share,
        currentItem['path'] as String? ?? '',
        username: widget.username,
        password: widget.password,
        requestId: _startFetch(),
        timeout: const Duration(minutes: 10),
      );
      if (myVersion == _navigationVersion) _activeFetchId = null;

      // Check if navigation happened while we were loading
      if (myVersion != _navigationVersion) {
        debugPrint(
          'Navigation happened while loading, discarding result for ${currentItem['name']}',
        );
        await deleteCachedFileIfNeeded(result.data);
        return;
      }

      if (!mounted) return;

      if (result.success && result.data != null && result.data!.isNotEmpty) {
        final fetched = result.data!;
        _registerFetchedFile(fetched);
        // Delete any previous cached file we were tracking before replacing it
        await deleteCachedFileIfNeeded(_cachedLocalPath);
        _cachedLocalPath = fetched;

        // Double-check version again after async operations
        if (myVersion != _navigationVersion) {
          debugPrint(
            'Navigation happened after fetch, discarding ${currentItem['name']}',
          );
          await deleteCachedFileIfNeeded(fetched);
          return;
        }

        _logTiming('image fetched');
        if (mounted) {
          _prepareDecodedImage(fetched);
          setState(() {
            localPath = fetched;
          });
        }

        if (!_isVideo()) {
          if (mounted) {
            setState(() {
              loading = false;
              _lastMediaLoadedAt = DateTime.now();
            });
          }
          _showControlsTransiently();
        }
      } else {
        if (mounted) {
          setState(() {
            error = 'Could not load file: ${result.error}';
            loading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = 'Error: $e';
          loading = false;
        });
      }
    }
  }

  Uri? _takePreloadedStreamUri(String path) {
    final uri = _preloadedStreamUris.remove(path);
    if (uri != null) {
      final token = uri.queryParameters['token'];
      if (token != null && token.isNotEmpty) {
        _preloadedTokens.remove(token);
      }
    }
    return uri;
  }

  _VideoStreamingProfile _buildVideoStreamingProfile(int? fileSize) {
    final safeFileSize = fileSize ?? 0;
    final lowLatency = _vrLowLatencyMode;
    final chunkSizeBytes = lowLatency
        ? 1024 * 1024
        : (safeFileSize >= 1500 * 1024 * 1024
              ? 4 * 1024 * 1024
              : 2 * 1024 * 1024);
    final maxChunks = lowLatency
        ? 8
        : (chunkSizeBytes >= 4 * 1024 * 1024 ? 8 : 10);
    final prefetchChunks = lowLatency
        ? 2
        : (chunkSizeBytes >= 4 * 1024 * 1024 ? 2 : 3);
    final warmupChunks = lowLatency
        ? 1
        : (chunkSizeBytes >= 4 * 1024 * 1024 ? 1 : 2);
    final networkCachingMs = lowLatency ? 650 : 2500;
    // Keep adjacent preload to 0/1 for SMB. A larger radius causes the connection
    // storms that result in Read timed out and app-side crashes.
    const preloadRadius = 0;
    return _VideoStreamingProfile(
      lowLatency: lowLatency,
      chunkSizeBytes: chunkSizeBytes,
      maxChunks: maxChunks,
      prefetchChunks: prefetchChunks,
      warmupChunks: warmupChunks,
      networkCachingMs: networkCachingMs,
      preloadRadius: preloadRadius,
    );
  }

  Future<Uri> _registerVideoSource({
    required String path,
    required _VideoStreamingProfile profile,
    int? fileSizeOverride,
  }) {
    return smbVideoProxyServer.registerSource(
      ip: widget.ip,
      share: widget.share,
      path: path,
      username: widget.username,
      password: widget.password,
      fileSizeOverride: fileSizeOverride,
      lowLatency: profile.lowLatency,
    );
  }

  void _preloadAdjacent({required _VideoStreamingProfile profile}) {
    if (profile.preloadRadius <= 0) {
      _cleanupPreloaded({(currentItem['path'] as String?) ?? ''});
      return;
    }

    for (var delta = 1; delta <= profile.preloadRadius; delta++) {
      _preloadVideoAt(currentIndex - delta, profile: profile);
      _preloadVideoAt(currentIndex + delta, profile: profile);
    }

    final keepPaths = <String>{(currentItem['path'] as String?) ?? ''};
    for (var delta = 1; delta <= profile.preloadRadius; delta++) {
      if (currentIndex - delta >= 0) {
        keepPaths.add(
          (_filteredList[currentIndex - delta]['path'] as String?) ?? '',
        );
      }
      if (currentIndex + delta < _filteredList.length) {
        keepPaths.add(
          (_filteredList[currentIndex + delta]['path'] as String?) ?? '',
        );
      }
    }
    _cleanupPreloaded(keepPaths);
  }

  bool _isVideoFile(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.3gp') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.flv') ||
        lower.endsWith('.wmv') ||
        lower.endsWith('.m4v');
  }

  void _preloadVideoAt(int index, {required _VideoStreamingProfile profile}) {
    if (index < 0 || index >= _filteredList.length) return;
    final item = _filteredList[index];
    final name = (item['name'] as String?)?.toLowerCase() ?? '';
    if (!_isVideoFile(name)) return;

    final path = item['path'] as String? ?? '';
    if (path.isEmpty ||
        _preloadedStreamUris.containsKey(path) ||
        !_pendingPreloadPaths.add(path)) {
      return;
    }

    final size = (item['size'] as num?)?.toInt();
    final generation = _navigationVersion;
    unawaited(() async {
      try {
        final uri = await _registerVideoSource(
          path: path,
          fileSizeOverride: size,
          profile: profile,
        );
        final token = uri.queryParameters['token'];
        if (!mounted || generation != _navigationVersion) {
          smbVideoProxyServer.unregisterSource(token);
          return;
        }
        if (token != null && token.isNotEmpty) {
          _preloadedTokens.add(token);
        }
        _preloadedStreamUris[path] = uri;
      } catch (_) {
      } finally {
        _pendingPreloadPaths.remove(path);
      }
    }());
  }

  void _cleanupPreloaded(Set<String> keepPaths) {
    final toRemove = _preloadedStreamUris.keys
        .where((p) => !keepPaths.contains(p))
        .toList();
    for (final path in toRemove) {
      final uri = _preloadedStreamUris.remove(path);
      final token = uri?.queryParameters['token'];
      if (token != null && token.isNotEmpty) {
        _preloadedTokens.remove(token);
        smbVideoProxyServer.unregisterSource(token);
      }
    }
  }

  void _releaseDecodedImage() {
    final previous = _decodedImageFuture;
    _decodedImageFuture = null;
    _decodedImagePath = null;
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          previous.then<void>(
            (image) => image.dispose(),
            onError: (Object _, StackTrace __) {},
          ),
        );
      });
    }
  }

  void _prepareDecodedImage(String path) {
    _releaseDecodedImage();
    // ImageProvider owns the animated codec; RawImage would freeze a GIF.
    if ((currentItem['name'] as String? ?? '').toLowerCase().endsWith('.gif')) {
      return;
    }
    _decodedImagePath = path;
    _decodedImageFuture = _decodeImageForViewer(path);
  }

  Future<ui.Image> _decodeImageForViewer(String path) async {
    final codec = await decodeImageToFit(
      path,
      _viewerDecodeTargetWidth(),
      _viewerDecodeTargetHeight(),
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  Future<void> _restartVideoFromBeginning(
    VlcPlayerController controller,
  ) async {
    try {
      await controller.seekTo(Duration.zero);
      await controller.play();
    } catch (_) {}
  }

  void _videoListener() {
    if (_videoController == null) return;
    final controller = _videoController!;
    final value = controller.value;
    if (!mounted) return;

    final pos = value.position;
    final dur = value.duration;
    if (!_firstPlayLogged && value.isPlaying && pos > Duration.zero) {
      _firstPlayLogged = true;
      _logTiming('first playback, duration=${dur.inSeconds}s');
    }
    final atEnd =
        dur > Duration.zero &&
        value.isPlaying &&
        pos.inMilliseconds >= dur.inMilliseconds - 250;
    if (atEnd) {
      final now = DateTime.now();
      final lastRestart = _lastVideoRestartAt;
      if (lastRestart == null ||
          now.difference(lastRestart) > const Duration(seconds: 1)) {
        _lastVideoRestartAt = now;
        unawaited(_restartVideoFromBeginning(controller));
      }
    }

    final now = DateTime.now();
    final lastUiRefresh = _lastVideoUiRefreshAt;
    final shouldRefreshUi =
        lastUiRefresh == null ||
        now.difference(lastUiRefresh) >= const Duration(milliseconds: 200);

    if (_isSeeking) {
      _videoDuration = dur;
      return;
    }

    if (!shouldRefreshUi) {
      if (dur > Duration.zero && dur != _videoDuration) {
        _videoDuration = dur;
      }
      return;
    }

    _lastVideoUiRefreshAt = now;
    final positionDelta = (pos - _currentPosition).abs();
    final durationChanged = dur != _videoDuration;
    if (!positionDelta.isNegative &&
        (positionDelta >= const Duration(milliseconds: 200) ||
            durationChanged)) {
      setState(() {
        _currentPosition = pos;
        _videoDuration = dur;
      });
    }
  }

  String _formatDuration(Duration d) {
    final total = d.inSeconds;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  double? _estimateBitrateMbps() {
    final size = (currentItem['size'] as num?)?.toInt() ?? 0;
    final durationSeconds = _videoDuration.inMilliseconds / 1000.0;
    if (size <= 0 || durationSeconds <= 0) return null;
    return (size * 8) / durationSeconds / 1000000.0;
  }

  String _formatBitrateMbps(double bitrateMbps) {
    return '${bitrateMbps.toStringAsFixed(bitrateMbps >= 100 ? 0 : 1)} Mbps';
  }

  String _buildVideoTelemetryText() {
    final bitrateMbps = _estimateBitrateMbps();
    final bitrateLabel = bitrateMbps != null
        ? _formatBitrateMbps(bitrateMbps)
        : 'bitrate indisponivel';
    final profile = _buildVideoStreamingProfile(
      (currentItem['size'] as num?)?.toInt(),
    );
    final warmSources =
        _preloadedStreamUris.length + (_videoProxyToken != null ? 1 : 0);
    final modeLabel = _vrModeEnabled ? 'VR monoscopico' : 'modo normal';
    final latencyLabel = _vrLowLatencyMode ? 'baixa latencia' : 'buffer maior';
    final chunkLabel =
        '${(profile.chunkSizeBytes / (1024 * 1024)).toStringAsFixed(profile.chunkSizeBytes >= 4 * 1024 * 1024 ? 0 : 1)}MB chunk';
    return '$modeLabel • $latencyLabel • buffer ${profile.networkCachingMs}ms • $chunkLabel • cache ${profile.maxChunks} • prefetch ${profile.prefetchChunks} • warmup ${profile.warmupChunks} • $bitrateLabel • preloads quentes $warmSources';
  }

  Future<void> _toggleLowLatencyMode() async {
    if (!_isVideo()) return;
    setState(() {
      _vrLowLatencyMode = !_vrLowLatencyMode;
      loading = true;
      error = null;
    });
    _showControlsTransiently();
    await _loadCurrentMedia();
  }

  Future<void> _seekVideoBy(Duration offset) async {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized || _isSeeking) {
      return;
    }
    final target = videoSeekTarget(
      controller.value.position,
      offset,
      controller.value.duration,
    );
    _isSeeking = true;
    try {
      await controller.seekTo(target);
      if (mounted && identical(controller, _videoController)) {
        setState(() => _currentPosition = target);
      }
    } catch (e) {
      debugPrint('Failed seeking video: $e');
    } finally {
      _isSeeking = false;
      if (mounted) _showControlsTransiently();
    }
  }

  Future<void> _toggleVideoPlayback() async {
    final loadedAt = _lastMediaLoadedAt;
    if (loadedAt != null &&
        DateTime.now().difference(loadedAt) <
            const Duration(milliseconds: 500)) {
      return;
    }

    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        await controller.play();
      }
      if (mounted) {
        setState(() {});
      }
      _showControlsTransiently();
    } catch (e) {
      debugPrint('Failed toggling video playback: $e');
    }
  }

  bool _shouldUseVrViewer() {
    final explicitFlag =
        currentItem['isVr'] == true ||
        currentItem['vr'] == true ||
        currentItem['is360'] == true ||
        currentItem['isSpherical'] == true;
    if (explicitFlag) return true;

    final name = (currentItem['name'] as String?)?.toLowerCase() ?? '';
    final baseName = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final tokens = baseName
        .split(RegExp(r'[^a-z0-9]+'))
        .where((token) => token.isNotEmpty)
        .toSet();
    const vrTokens = <String>{
      'vr',
      '360',
      'sphere',
      'spherical',
      'equirect',
      'equirectangular',
      'stereo',
      'stereoscopic',
      'oculus',
    };
    return tokens.any(vrTokens.contains);
  }

  void _toggleVrMode() {
    if (!_isVideo() || _videoController == null) return;
    setState(() => _vrModeEnabled = !_vrModeEnabled);
    _showControlsTransiently();
  }

  double _videoAspectRatio() {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) {
      return 16 / 9;
    }
    final ratio = controller.value.aspectRatio;
    if (ratio.isNaN || ratio <= 0) {
      return 16 / 9;
    }
    return ratio;
  }

  Widget _buildVideoViewport() => MonoVideoViewport(
    key: ValueKey(currentItem['path']),
    enabled: _vrModeEnabled,
    sourceAspectRatio: _videoAspectRatio(),
    showControls: _showViewerControls,
    onInteraction: _showControlsTransiently,
    child: VlcPlayer(
      controller: _videoController!,
      aspectRatio: _videoAspectRatio(),
      placeholder: const Center(child: CircularProgressIndicator()),
    ),
  );

  void _showControlsTransiently() {
    _controlsHideTimer?.cancel();
    if (!_showViewerControls && mounted) {
      setState(() {
        _showViewerControls = true;
      });
    }
    _controlsHideTimer = Timer(_controlsAutoHideDelay, () {
      if (!mounted || _isSeeking) return;
      setState(() {
        _showViewerControls = false;
      });
    });
  }

  Future<void> _pickPlaybackSpeed() async {
    if (!_isVideo()) return;
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;

    final speeds = <double>[0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final selected = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.black87,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text(
                  'Velocidade de reproducao',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              ...speeds.map((speed) {
                final isSelected = (speed - _playbackSpeed).abs() < 0.001;
                return ListTile(
                  title: Text(
                    '${speed.toStringAsFixed(speed % 1 == 0 ? 0 : 2)}x',
                    style: const TextStyle(color: Colors.white),
                  ),
                  trailing: isSelected
                      ? const Icon(Icons.check, color: Colors.white)
                      : null,
                  onTap: () => Navigator.of(context).pop(speed),
                );
              }),
            ],
          ),
        );
      },
    );

    if (selected == null ||
        !mounted ||
        !identical(controller, _videoController)) {
      return;
    }
    try {
      await controller.setPlaybackSpeed(selected);
      if (mounted && identical(controller, _videoController)) {
        setState(() => _playbackSpeed = selected);
      }
      _showControlsTransiently();
    } catch (e) {
      debugPrint('Failed setting playback speed: $e');
    }
  }

  void _showPrevious() {
    if (currentIndex > 0) {
      // Delete previous video from cache before navigating
      _deleteCurrentVideoFromCache();
      _evictCurrentImageProviders();

      setState(() {
        currentIndex--;
        currentItem = _filteredList[currentIndex];
        loading = true;
        localPath = null;
      });
      debugPrint(
        'Navigating to previous: index=$currentIndex, name=${currentItem['name']}',
      );
      _loadCurrentMedia();
    }
  }

  void _showNext() {
    if (currentIndex < _filteredList.length - 1) {
      // Delete previous video from cache before navigating
      _deleteCurrentVideoFromCache();
      _evictCurrentImageProviders();

      setState(() {
        currentIndex++;
        currentItem = _filteredList[currentIndex];
        loading = true;
        localPath = null;
      });
      debugPrint(
        'Navigating to next: index=$currentIndex, name=${currentItem['name']}',
      );
      _loadCurrentMedia();
    }
  }

  /// Delete current video file from cache (not from server)
  void _deleteCurrentVideoFromCache() {
    if (_cachedLocalPath != null) {
      try {
        final f = File(_cachedLocalPath!);
        if (f.existsSync()) {
          f.deleteSync();
          debugPrint('Deleted video from cache: $_cachedLocalPath');
        }
      } catch (e) {
        debugPrint('Error deleting video from cache: $e');
      }
      _cachedLocalPath = null;
    }
  }

  void _evictCurrentImageProviders() {
    final currentPath = localPath;
    if (currentPath == null || currentPath.isEmpty || _isVideo()) {
      return;
    }

    final baseProvider = FileImage(File(currentPath));
    final cache = PaintingBinding.instance.imageCache;
    cache.evict(baseProvider);

    final resizedProvider = ResizeImage(
      baseProvider,
      width: _viewerDecodeTargetWidth(),
      height: _viewerDecodeTargetHeight(),
      policy: ResizeImagePolicy.fit,
    );
    cache.evict(resizedProvider);
  }

  int _viewerDecodeTargetWidth() {
    final mq = MediaQuery.of(context);
    final value = (mq.size.width * mq.devicePixelRatio).round();
    return value.clamp(320, 4096).toInt();
  }

  int _viewerDecodeTargetHeight() {
    final mq = MediaQuery.of(context);
    final value = (mq.size.height * mq.devicePixelRatio).round();
    return value.clamp(320, 4096).toInt();
  }

  Future<void> _deleteCurrent() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Media'),
        content: Text(
          'Are you sure you want to delete "${currentItem['name']}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (!mounted) return;

    if (confirm == true) {
      final deletedPath = currentItem['path'] as String? ?? '';
      try {
        final result = await SMBClient.deleteFile(
          widget.ip,
          widget.share,
          currentItem['path'] as String? ?? '',
          username: widget.username,
          password: widget.password,
        );

        if (!mounted) return;

        if (result.success) {
          await thumbCache.remove(deletedPath);
          // Remove from both the original and filtered lists
          final originalIndex = widget.mediaList.indexWhere(
            (i) => i['path'] == currentItem['path'],
          );
          if (originalIndex >= 0) widget.mediaList.removeAt(originalIndex);

          // Remove from filtered list
          _filteredList.removeAt(currentIndex);

          if (_filteredList.isEmpty) {
            if (mounted) Navigator.pop(context);
          } else {
            if (currentIndex >= _filteredList.length) {
              currentIndex = _filteredList.length - 1;
            }
            currentItem = _filteredList[currentIndex];
            _loadCurrentMedia();
          }

          // Attempt to delete any cached file that belonged to the removed media
          try {
            final cached = _cachedLocalPath;
            if (cached != null) {
              final f = File(cached);
              if (f.existsSync()) {
                f.deleteSync();
                debugPrint('Deleted cached file after deletion: $cached');
              }
            }
          } catch (e) {
            debugPrint('Error deleting cached file after removal: $e');
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error deleting: ${result.error}')),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error deleting: $e')));
        }
      }
    }
  }

  bool _isVideo() => _isVideoFile(currentItem['name'] as String? ?? '');

  /// Downloads the source for editing. Close only this dialog on completion.
  Future<String?> _downloadWithProgress({required String title}) async {
    if (!mounted || _downloadingForEdit) return null;
    final cancelToken = ValueNotifier<bool>(false);
    _downloadCancelToken = cancelToken;
    _downloadingForEdit = true;
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: const LinearProgressIndicator(),
        actions: [
          TextButton(
            onPressed: () {
              cancelToken.value = true;
              if (ModalRoute.of(ctx)?.isCurrent ?? false) {
                Navigator.of(ctx).pop();
              }
            },
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
    unawaited(
      navigator.push(route).then((_) {
        cancelToken.value = true;
      }),
    );
    try {
      final result = await SMBClient.fetchFileWithProgress(
        widget.ip,
        widget.share,
        currentItem['path'] as String? ?? '',
        username: widget.username,
        password: widget.password,
        cancelToken: cancelToken,
      );
      if (!mounted || cancelToken.value) return null;
      if (!result.success || result.data == null || result.data!.isEmpty) {
        throw StateError(result.error ?? 'Download failed');
      }
      return result.data;
    } catch (e) {
      if (mounted && !cancelToken.value) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erro ao baixar: $e')));
      }
      return null;
    } finally {
      if (route.isActive) navigator.removeRoute(route);
      _downloadingForEdit = false;
      _downloadCancelToken = null;
      unawaited(route.completed.then((_) => cancelToken.dispose()));
    }
  }

  /// After editing, ask user: overwrite original on SMB, or save as copy.
  Future<void> _handlePostEditSave(
    String editedLocalPath, {
    required bool isVideo,
  }) async {
    if (!mounted) return;

    final remotePath = currentItem['path'] as String? ?? '';
    final remoteDir = remotePath.contains('/')
        ? remotePath.substring(0, remotePath.lastIndexOf('/') + 1)
        : (remotePath.contains('\\')
              ? remotePath.substring(0, remotePath.lastIndexOf('\\') + 1)
              : '/');
    final originalName = remotePath.split('/').last.split('\\').last;

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Salvar edição'),
        content: Text('O que deseja fazer com "$originalName"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'copy'),
            child: const Text('Salvar como cópia'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'replace'),
            child: const Text('Substituir original'),
          ),
        ],
      ),
    );

    if (choice == null || choice == 'cancel' || !mounted) return;

    // Build remote destination path
    String destRemotePath;
    if (choice == 'copy') {
      final ext = originalName.contains('.')
          ? '.${originalName.split('.').last}'
          : '';
      final base = originalName.contains('.')
          ? originalName.substring(0, originalName.lastIndexOf('.'))
          : originalName;
      destRemotePath = '$remoteDir${base}_editado$ext';
    } else {
      destRemotePath = remotePath;
    }

    // Show uploading indicator
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              SizedBox(width: 12),
              Text('Enviando para o servidor...'),
            ],
          ),
          // Hidden explicitly when the upload ends; large videos take minutes.
          duration: Duration(minutes: 30),
        ),
      );
    }

    try {
      final uploadResult = await SMBClient.uploadFile(
        widget.ip,
        widget.share,
        destRemotePath,
        editedLocalPath,
        username: widget.username,
        password: widget.password,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (!uploadResult.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao enviar: ${uploadResult.error}')),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            choice == 'copy'
                ? 'Cópia salva no servidor ✓'
                : 'Original substituído ✓',
          ),
        ),
      );

      // Update local view with edited file
      await deleteCachedFileIfNeeded(_cachedLocalPath);
      _cachedLocalPath = editedLocalPath;
      if (mounted) {
        if (!isVideo) _prepareDecodedImage(editedLocalPath);
        setState(() => localPath = isVideo ? localPath : editedLocalPath);
      }
      if (!isVideo) await _regenerateThumbnailForCurrentItem(editedLocalPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erro ao enviar: $e')));
    }
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  Future<void> _editMedia() async {
    final navigator = Navigator.of(context);
    try {
      if (_isVideo()) {
        // Stop streaming: playback would compete with the download for bandwidth.
        try {
          await _videoController?.pause();
        } catch (_) {}
        // localPath for videos is an HTTP proxy URL, not a local file path.
        // VideoTrimmerScreen needs a real File — always fetch to disk first.
        var pathForTrim = _cachedLocalPath;
        final isLocalFile =
            pathForTrim != null &&
            pathForTrim.isNotEmpty &&
            !pathForTrim.startsWith('http');

        if (!isLocalFile) {
          final size = (currentItem['size'] as num?)?.toInt() ?? 0;
          pathForTrim = await _downloadWithProgress(
            title: size > 0
                ? 'Baixando para edição (${_formatBytes(size)})'
                : 'Baixando para edição',
          );
          if (pathForTrim == null) return; // cancelled or failed
          _cachedLocalPath = pathForTrim;
        }

        final out = await navigator.push<String?>(
          MaterialPageRoute(
            builder: (_) => VideoTrimmerScreen(path: pathForTrim!),
          ),
        );
        if (out != null && out.isNotEmpty) {
          await _handlePostEditSave(out, isVideo: true);
        }
        return;
      }

      if (localPath == null) return;

      // image editor
      final out = await navigator.push<String?>(
        MaterialPageRoute(builder: (_) => ImageEditorScreen(path: localPath!)),
      );

      if (out != null && out.isNotEmpty) {
        await _handlePostEditSave(out, isVideo: false);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Edit failed: $e')));
    }
  }

  Future<void> _regenerateThumbnailForCurrentItem(String newLocalPath) async {
    final item = currentItem;
    final name = (item['name'] as String?)?.toLowerCase() ?? '';
    final tmpDir = Directory.systemTemp.path;
    final hash = base64Url
        .encode(utf8.encode(newLocalPath))
        .replaceAll('=', '');
    final outPath = '$tmpDir/thumb_$hash.jpg';

    try {
      String? thumb;
      if (name.endsWith('.mp4') ||
          name.endsWith('.avi') ||
          name.endsWith('.mkv') ||
          name.endsWith('.mov') ||
          name.endsWith('.3gp') ||
          name.endsWith('.webm')) {
        thumb = await VideoThumbnail.thumbnailFile(
          video: newLocalPath,
          thumbnailPath: outPath,
          imageFormat: ImageFormat.JPEG,
          maxHeight: 360,
          quality: 85,
        );
      } else {
        // Use native codec downscale to avoid heavy Dart-side decode
        thumb = await generateImageThumbnailNative(newLocalPath, outPath, 360);
      }

      if (thumb != null && thumb.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          item['thumb'] = thumb;
        });
      }
    } catch (e) {
      // ignore
    }
  }

  void _onSwipeEnd(DragEndDetails details) {
    if (_isSeeking) return;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > 500) {
      _showPrevious();
    } else if (velocity < -500) {
      _showNext();
    }
  }

  // Shows the grid thumbnail while the full media downloads.
  Widget _buildLoadingPlaceholder() {
    final thumb = currentItem['thumb'] as String?;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumb != null && thumb.isNotEmpty)
          Image.file(
            File(thumb),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        const Center(child: CircularProgressIndicator()),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _showControlsTransiently,
        // Lets the user skip media that is still loading; once loaded, the
        // inner detector below wins the gesture arena.
        onHorizontalDragEnd: _vrModeEnabled ? null : _onSwipeEnd,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (loading)
              _buildLoadingPlaceholder()
            else if (error != null)
              Center(
                child: Text(
                  error!,
                  style: const TextStyle(color: Colors.white),
                ),
              )
            else if ((_isVideo() && _videoController != null) ||
                localPath != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragEnd: _vrModeEnabled ? null : _onSwipeEnd,
                child: Center(
                  child: _isVideo()
                      ? (_videoController != null
                            ? VideoGestures(
                                onSeek: _seekVideoBy,
                                onShowControls: _showControlsTransiently,
                                child: _buildVideoViewport(),
                              )
                            : const Center(child: CircularProgressIndicator()))
                      : RepaintBoundary(
                          key: ValueKey(localPath),
                          child:
                              (_decodedImageFuture != null &&
                                  _decodedImagePath == localPath)
                              ? FutureBuilder<ui.Image>(
                                  future: _decodedImageFuture,
                                  builder: (context, snapshot) {
                                    if (snapshot.hasData) {
                                      return RawImage(
                                        image: snapshot.data,
                                        fit: BoxFit.contain,
                                        filterQuality: FilterQuality.medium,
                                      );
                                    }
                                    if (snapshot.hasError) {
                                      return const Icon(
                                        Icons.broken_image,
                                        color: Colors.white,
                                      );
                                    }
                                    return const Center(
                                      child: CircularProgressIndicator(),
                                    );
                                  },
                                )
                              : Image(
                                  image: ResizeImage(
                                    FileImage(File(localPath!)),
                                    width: _viewerDecodeTargetWidth(),
                                    height: _viewerDecodeTargetHeight(),
                                    policy: ResizeImagePolicy.fit,
                                  ),
                                  fit: BoxFit.contain,
                                ),
                        ),
                ),
              )
            else
              Center(
                child: Text(
                  'No media loaded\nIndex: $currentIndex\nName: ${currentItem['name'] ?? 'unknown'}\nLocalPath: $localPath',
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            if (_isVideo() &&
                _videoController != null &&
                _videoController!.value.isInitialized &&
                !_videoController!.value.isPlaying)
              const Center(
                child: IgnorePointer(
                  child: Icon(
                    Icons.play_circle_fill,
                    color: Colors.white70,
                    size: 72,
                  ),
                ),
              ),
            if (_showViewerControls)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppBar(
                  backgroundColor: Colors.black87,
                  title: Text('${currentIndex + 1}/${widget.mediaList.length}'),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: _deleteCurrent,
                    ),
                  ],
                ),
              ),
            if (_isVideo() &&
                _videoController != null &&
                _videoController!.value.isInitialized)
              Positioned(
                left: 8,
                right: 8,
                bottom:
                    MediaQuery.of(context).padding.bottom + 72, // above FABs
                child: IgnorePointer(
                  ignoring: !_showViewerControls,
                  child: AnimatedOpacity(
                    opacity: _showViewerControls ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Slider(
                          value: (_videoDuration.inMilliseconds > 0)
                              ? _currentPosition.inMilliseconds
                                    .clamp(0, _videoDuration.inMilliseconds)
                                    .toDouble()
                              : 0,
                          max: _videoDuration.inMilliseconds > 0
                              ? _videoDuration.inMilliseconds.toDouble()
                              : 1.0,
                          onChanged: (v) {
                            _showControlsTransiently();
                            setState(() {
                              _isSeeking = true;
                              _currentPosition = Duration(
                                milliseconds: v.toInt(),
                              );
                            });
                          },
                          onChangeEnd: (v) async {
                            final target = Duration(milliseconds: v.toInt());
                            try {
                              await _videoController?.seekTo(target);
                            } catch (e) {
                              debugPrint('Failed seeking video: $e');
                            } finally {
                              _isSeeking = false;
                              if (mounted) _showControlsTransiently();
                            }
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDuration(_currentPosition),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                              Row(
                                children: [
                                  Text(
                                    '${_formatDuration(_videoDuration)}  ${_playbackSpeed.toStringAsFixed(_playbackSpeed % 1 == 0 ? 0 : 2)}x',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    icon: Icon(
                                      _vrModeEnabled
                                          ? Icons.looks_one
                                          : Icons.vrpano_outlined,
                                    ),
                                    tooltip: _vrModeEnabled
                                        ? 'Sair do VR monoscópico'
                                        : 'VR monoscópico',
                                    color: Colors.white,
                                    onPressed: _toggleVrMode,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        // Streaming diagnostics are for development only.
                        if (kDebugMode)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
                            child: Text(
                              _buildVideoTelemetryText(),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            if ((localPath != null || _videoController != null) &&
                _showViewerControls)
              Positioned(
                left: 16,
                right: 16,
                bottom: MediaQuery.of(context).padding.bottom + 16,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (_isVideo()) ...[
                      FloatingActionButton(
                        heroTag: 'play_pause_btn',
                        mini: true,
                        tooltip: _videoController?.value.isPlaying == true
                            ? 'Pausar'
                            : 'Reproduzir',
                        backgroundColor: Colors.black87,
                        onPressed: _toggleVideoPlayback,
                        child: Icon(
                          _videoController?.value.isPlaying == true
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                      ),
                      FloatingActionButton(
                        heroTag: 'speed_btn',
                        mini: true,
                        backgroundColor: Colors.black87,
                        onPressed: () {
                          _showControlsTransiently();
                          _pickPlaybackSpeed();
                        },
                        child: const Icon(Icons.speed),
                      ),
                      const SizedBox(width: 10),
                      FloatingActionButton(
                        heroTag: 'latency_btn',
                        mini: true,
                        backgroundColor: _vrLowLatencyMode
                            ? Colors.orange.shade800
                            : Colors.black87,
                        onPressed: () async {
                          await _toggleLowLatencyMode();
                        },
                        child: Icon(
                          _vrLowLatencyMode ? Icons.bolt : Icons.bolt_outlined,
                        ),
                      ),
                    ] else
                      const SizedBox(width: 40),
                    FloatingActionButton(
                      heroTag: 'edit_btn',
                      mini: true,
                      backgroundColor: Colors.black87,
                      onPressed: () {
                        _showControlsTransiently();
                        _editMedia();
                      },
                      child: const Icon(Icons.edit),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FolderPickerScreen extends StatefulWidget {
  final String ip, share, username, password, title;
  final Set<String> excludePaths;

  const _FolderPickerScreen({
    required this.ip,
    required this.share,
    required this.username,
    required this.password,
    required this.title,
    required this.excludePaths,
  });

  @override
  State<_FolderPickerScreen> createState() => _FolderPickerScreenState();
}

class _FolderPickerScreenState extends State<_FolderPickerScreen> {
  String _currentPath = '/';
  List<Map<dynamic, dynamic>> _folders = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFolders(_currentPath);
  }

  String _normalizePath(String path) {
    if (path.isEmpty) return '/';
    // Hot path: listing paths are normalized once on load.
    if (path.startsWith('/') && !path.contains('\\') && !path.contains('//')) {
      return path;
    }
    var p = path.replaceAll('\\', '/');
    p = p.replaceAll(RegExp('/+'), '/');
    if (!p.startsWith('/')) p = '/$p';
    if (path.endsWith('/') || path.endsWith('\\')) {
      if (!p.endsWith('/')) p = '$p/';
    }
    return p;
  }

  Future<void> _loadFolders(String path) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await SMBClient.listDirectory(
        widget.ip,
        widget.share,
        path,
        username: widget.username,
        password: widget.password,
      );
      if (!mounted) return;
      if (!result.success) {
        setState(() {
          _error = result.error;
          _loading = false;
        });
        return;
      }
      final all = (result.data ?? []).cast<Map<dynamic, dynamic>>();
      final dirs = all
          .where((item) {
            final isDir =
                item['is_directory'] == true || item['type'] == 'directory';
            final p = item['path'] as String? ?? '';
            return isDir && !widget.excludePaths.contains(_normalizePath(p));
          })
          .map((item) {
            final p = item['path'] as String? ?? '';
            return {...item, 'path': _normalizePath(p)};
          })
          .toList();
      setState(() {
        _folders = dirs;
        _loading = false;
        _currentPath = _normalizePath(path);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _navigateTo(String path) => _loadFolders(path);

  void _goUp() {
    var p = _currentPath;
    if (p.endsWith('/')) p = p.substring(0, p.length - 1);
    final idx = p.lastIndexOf('/');
    final parent = idx <= 0 ? '/' : p.substring(0, idx + 1);
    _loadFolders(parent);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        leading: _currentPath == '/'
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_upward),
                tooltip: 'Pasta acima',
                onPressed: _goUp,
              ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.check, color: Colors.white),
            label: const Text(
              'Selecionar aqui',
              style: TextStyle(color: Colors.white),
            ),
            onPressed: () => Navigator.of(context).pop(_currentPath),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            )
          : _folders.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Nenhuma subpasta aqui.'),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('Usar esta pasta'),
                    onPressed: () => Navigator.of(context).pop(_currentPath),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _folders.length,
              itemBuilder: (ctx, i) {
                final item = _folders[i];
                final name = item['name'] as String? ?? '';
                final path = item['path'] as String? ?? '';
                return ListTile(
                  leading: const Icon(Icons.folder),
                  title: Text(name),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      _navigateTo(path.endsWith('/') ? path : '$path/'),
                );
              },
            ),
    );
  }
}
