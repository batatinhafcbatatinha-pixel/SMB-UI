import 'dart:async';
import 'dart:io';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:video_thumbnail/video_thumbnail.dart';
import 'smb_client.dart';
import 'memory_cache.dart';
import 'thumbnail_cache.dart';
import 'thumbnail_events.dart';
import 'smb_video_proxy_server.dart';
import 'video_metadata.dart';
import 'image_utils.dart';

/// Estratégia de prioridade para carregamento
enum LoadPriority {
  critical, // Item visível na tela - carregar IMEDIATAMENTE
  high, // Item próximo na viewport - carregar em seguida
  medium, // Item mais adiante - carregar em background
  low, // Item longe - carregar só quando sobrar banda
}

/// Status do item de trabalho
enum WorkItemStatus {
  pending,
  downloading,
  processing,
  completed,
  failed,
  cancelled,
}

/// Tipo de trabalho
enum WorkType {
  metadata, // Duração do vídeo (precisa do arquivo local)
  thumbnail, // Geração de thumbnail
}

/// Item de trabalho para o loader
class ThumbnailWorkItem {
  final String id;
  final String ip;
  final String share;
  final String path;
  final String name;
  final String username;
  final String password;
  final WorkType type;
  final LoadPriority initialPriority;
  final Map<dynamic, dynamic> item;

  // Callbacks
  final void Function(ThumbnailWorkItem)? onThumbnailReady;
  final void Function(double duration)? onMetadataReady;
  final void Function(String error)? onError;

  // Estado mutável
  LoadPriority priority;
  WorkItemStatus status = WorkItemStatus.pending;
  String? error;
  DateTime? startedAt;
  DateTime? completedAt;

  // Campos internos para processamento
  String? localPath;
  bool processingStarted = false;

  // Cancelamento
  bool _cancelled = false;
  CancelToken? _cancelToken;

  // Debounce para atualizações de prioridade
  DateTime? _lastPriorityChange;
  int _priorityChangeCount = 0;

  ThumbnailWorkItem({
    required this.id,
    required this.ip,
    required this.share,
    required this.path,
    required this.name,
    required this.username,
    required this.password,
    required this.type,
    required this.item,
    this.initialPriority = LoadPriority.medium,
    this.onThumbnailReady,
    this.onMetadataReady,
    this.onError,
  }) : priority = initialPriority;

  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _cancelToken?.cancel();
    if (status == WorkItemStatus.pending) {
      status = WorkItemStatus.cancelled;
    }
  }

  /// Atualiza prioridade com debounce
  void updatePriority(LoadPriority newPriority) {
    final now = DateTime.now();

    // Sempre atualiza para critical
    if (newPriority == LoadPriority.critical) {
      priority = newPriority;
      _lastPriorityChange = now;
      _priorityChangeCount = 0;
      return;
    }

    // Debounce para outras mudanças
    if (_lastPriorityChange != null) {
      final elapsed = now.difference(_lastPriorityChange!);
      if (elapsed.inMilliseconds < 100) {
        // Ignora mudanças muito frequentes
        return;
      }
    }

    // Sobe a prioridade mais fácil que desce
    if (newPriority.index < priority.index || _priorityChangeCount < 3) {
      priority = newPriority;
      _lastPriorityChange = now;
      _priorityChangeCount++;
    }
  }

  bool get isVideo {
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

  bool get isImage {
    final n = name.toLowerCase();
    return n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.png') ||
        n.endsWith('.gif') ||
        n.endsWith('.bmp') ||
        n.endsWith('.webp');
  }

  bool get usesWindowsPreview {
    final n = name.toLowerCase();
    // Android/SMB preview is only useful for video/GIF media. Image files must
    // still go through normal thumb generation to avoid skipped thumbnails.
    return isVideo || n.endsWith('.gif');
  }

  // /// Score para ordenação na fila (menor = mais prioritário)
  // int get queueScore {
  //   int score = priority.index * 1000;
  //   // Itens que já começaram têm preferência
  //   if (status == WorkItemStatus.downloading) score -= 500;
  //   if (status == WorkItemStatus.processing) score -= 300;
  //   // Itens mais antigos têm preferência
  //   score -= (DateTime.now().millisecondsSinceEpoch ~/ 100) % 100;
  //   return score;
  // }
}

/// Gerenciador de tokens de cancelamento
class CancelToken {
  bool _isCancelled = false;
  final Set<void Function()> _listeners = {};

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (!_isCancelled) {
      _isCancelled = true;
      final listeners = _listeners.toList();
      _listeners.clear();
      for (final listener in listeners) {
        listener();
      }
    }
  }

  void addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }
}

/// Serviço de carregamento paralelo de thumbnails Otimizado para pastas grandes
class ParallelThumbnailLoader {
  static const String _tag = 'ParallelThumbnailLoader';

  // Singleton
  static final ParallelThumbnailLoader _instance =
      ParallelThumbnailLoader._internal();
  factory ParallelThumbnailLoader() => _instance;
  ParallelThumbnailLoader._internal();

  int _maxRetries = 3; // Tentativas por item

  // Concurrency caps
  // _maxActiveDownloads deve ser <= permits do SMB semaphore para não acumular
  // Futures esperando acquire (causa callbacks FlutterJNI-detached depois).
  static const int _maxActiveDownloads = 2;
  // Metadata usa ranged reads leves — um por vez evita contenção com downloads.
  static const int _maxActiveMetadata = 1;
  // Processing usa compute() em isolates — independente do SMB, pode ser paralelo.
  // Limitado a 2: com 3+ isolates simultâneos o engine Dart pode crashar (SIGSEGV)
  // quando o usuário navega de volta enquanto os isolates ainda estão rodando.
  static const int _maxActiveProcessing = 2;

  // Filas de trabalho
  // Pending work. The set gives O(1) membership/removal; the per-priority
  // buckets give O(1) dispatch even with thousands of queued items. Buckets may
  // hold stale entries (promoted or already dispatched) that are skipped lazily.
  final LinkedHashSet<ThumbnailWorkItem> _workQueue =
      LinkedHashSet<ThumbnailWorkItem>.identity();
  final List<ListQueue<ThumbnailWorkItem>> _thumbBuckets = List.generate(
    LoadPriority.values.length,
    (_) => ListQueue<ThumbnailWorkItem>(),
  );
  final ListQueue<ThumbnailWorkItem> _metadataQueue =
      ListQueue<ThumbnailWorkItem>();
  // Critical (on-screen) work is served most-recently-seen first, so after a
  // fling the cells the user stopped on load before the ones scrolled past.
  final LinkedHashSet<ThumbnailWorkItem> _criticalOrder =
      LinkedHashSet<ThumbnailWorkItem>.identity();

  void _markCritical(ThumbnailWorkItem item) {
    _criticalOrder.remove(item);
    _criticalOrder.add(item);
  }

  final Map<String, List<ThumbnailWorkItem>> _queuedByPath = {};

  void _enqueue(ThumbnailWorkItem item) {
    if (!_workQueue.add(item)) return;
    (_queuedByPath[item.path] ??= []).add(item);
    if (item.type == WorkType.metadata) {
      _metadataQueue.addLast(item);
    } else if (item.priority == LoadPriority.critical) {
      _markCritical(item);
    } else {
      _thumbBuckets[item.priority.index].addLast(item);
    }
  }

  void _dequeue(ThumbnailWorkItem item) {
    if (!_workQueue.remove(item)) return;
    _criticalOrder.remove(item);
    final list = _queuedByPath[item.path];
    if (list == null) return;
    list.remove(item);
    if (list.isEmpty) _queuedByPath.remove(item.path);
  }

  void _clearQueue() {
    _workQueue.clear();
    _queuedByPath.clear();
    _metadataQueue.clear();
    _criticalOrder.clear();
    for (final bucket in _thumbBuckets) {
      bucket.clear();
    }
  }

  final Map<String, ThumbnailWorkItem> _activeDownloads = {};
  final Map<String, ThumbnailWorkItem> _activeProcessing = {};
  final Map<String, ThumbnailWorkItem> _activeMetadata = {};

  // Controle de execução
  bool _isRunning = false;
  bool _paused = false;
  String currentSortType = '';

  // Cache de paths
  final Set<String> _processedPaths = {};

  // Estatísticas
  final _stats = _LoaderStats();
  final List<String> _failedPaths = [];

  /// Stream de estatísticas
  Stream<LoaderStats> get statsStream => _statsController.stream;
  final _statsController = StreamController<LoaderStats>.broadcast();

  void _logDebug(String message) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }

  /// Configura o loader
  void configure({int? maxRetries}) {
    _maxRetries = maxRetries ?? _maxRetries;
  }

  /// Adiciona itens para processamento em lote
  void addItems(List<ThumbnailWorkItem> items) {
    // Permite reprocessar imagens/GIFs sem thumb válido
    final newItems = <ThumbnailWorkItem>[];

    for (final item in items) {
      final cacheKey = '${item.path}_${item.type.name}';
      if (!_processedPaths.contains(cacheKey)) {
        newItems.add(item);
        _processedPaths.add(cacheKey);
      }
    }

    if (newItems.isEmpty) return;

    if (currentSortType == 'duration') {
      // Prioriza metadata de vídeos primeiro quando ordenando por duração
      for (final item in newItems) {
        if (item.type == WorkType.metadata && item.isVideo) {
          item.updatePriority(LoadPriority.high);
        } else if (item.type == WorkType.thumbnail && item.isVideo) {
          // Thumbs de vídeo só depois de ter metadata
          item.updatePriority(LoadPriority.medium);
        }
      }
    }

    // Atualiza prioridades baseadas em metadados (antes de escolher o bucket)
    _optimizeVideoPriorities(newItems);

    // Adiciona à fila
    for (final item in newItems) {
      _enqueue(item);
    }
    _stats.totalQueued += newItems.length;

    // Inicia processamento se não estiver rodando
    if (!_isRunning) {
      _startLoader();
    }

    _notifyStatsUpdate();
    _logDebug(
      '$_tag Added ${newItems.length} items to queue. Total: ${_workQueue.length}',
    );
  }

  /// Otimiza prioridade de vídeos que já têm metadata
  void promotePath(String path, LoadPriority priority) {
    final queued = _queuedByPath[path];
    if (queued == null) return;
    for (final item in queued) {
      if (item.type == WorkType.thumbnail &&
          priority == LoadPriority.critical) {
        item.updatePriority(priority);
        _markCritical(item);
        continue;
      }
      if (priority.index >= item.priority.index) continue;
      item.updatePriority(priority);
      if (item.type == WorkType.thumbnail && item.priority == priority) {
        _thumbBuckets[priority.index].addLast(item);
      }
    }
  }

  void _optimizeVideoPriorities(Iterable<ThumbnailWorkItem> candidates) {
    // Vídeos que já baixaram metadata são mais rápidos de processar
    // então aumentamos a prioridade deles
    for (final item
        in candidates
            .where((i) => i.type == WorkType.thumbnail && i.isVideo)
            .toList()) {
      if (item.item['duration'] != null) {
        // Já tem metadata, pode processar thumb mais rápido
        if (item.priority == LoadPriority.low) {
          item.updatePriority(LoadPriority.medium);
        }
      }
    }
  }

  // /// Marca um item como visível (viewport)
  // void setVisibleItem(String path,
  //     {bool isVisible = true, double visibilityPercent = 0}) {
  //   // Atualiza prioridade do item visível se ele estiver na fila
  //   for (final item in _workQueue.where((i) => i.path == path).toList()) {
  //     if (isVisible && visibilityPercent > 0.3) {
  //       item.updatePriority(LoadPriority.critical);
  //     } else if (isVisible && visibilityPercent > 0.1) {
  //       item.updatePriority(LoadPriority.high);
  //     }
  //   }

  //   // Reordena fila se houve mudança significativa
  //   _reorderQueueIfNeeded();

  //   // Promove downloads críticos
  //   _promoteCriticalDownloads();
  // }

  // /// Reordena a fila baseado em prioridade
  // void _reorderQueueIfNeeded() {
  //   final items = _workQueue.toList();
  //   items.sort((a, b) => a.queueScore.compareTo(b.queueScore));

  //   _workQueue.clear();
  //   _workQueue.addAll(items);
  // }

  // /// Promove downloads críticos para serem executados primeiro
  // void _promoteCriticalDownloads() {
  //   final critical =
  //       _workQueue.where((i) => i.priority == LoadPriority.critical).toList();
  //   if (critical.isEmpty) return;

  //   // Remove críticos da fila
  //   _workQueue.removeWhere((i) => i.priority == LoadPriority.critical);

  //   // Adiciona no início em ordem original
  //   final remaining = _workQueue.toList();
  //   _workQueue.clear();
  //   _workQueue.addAll(critical);
  //   _workQueue.addAll(remaining);
  // }

  /// Cancela todos os trabalhos
  void cancelAll() {
    _logDebug('$_tag Cancelling all work...');

    // Cancela downloads ativos
    for (final item in _activeDownloads.values.toList()) {
      item.cancel();
    }
    for (final item in _activeProcessing.values.toList()) {
      item.cancel();
    }
    for (final item in _activeMetadata.values.toList()) {
      item.cancel();
    }

    // Cancela pendentes
    for (final item in _workQueue.toList()) {
      item.cancel();
    }

    _clearQueue();
    smbVideoProxyServer.closeThumbnailSources();
    // Keep active work counted until it completes, including cancelled I/O.
    // Otherwise opening another folder can exceed the concurrency limits.
    _processedPaths.clear();
    _failedPaths.clear();

    _stats.reset();
    _notifyStatsUpdate();
  }

  /// Cancela trabalhos para um path específico
  void cancelForPath(String path) {
    for (final item in [
      ..._workQueue,
      ..._activeDownloads.values,
      ..._activeProcessing.values,
      ..._activeMetadata.values,
    ]) {
      if (item.path == path) {
        item.cancel();
        _processedPaths.remove('${item.path}_${item.type.name}');
      }
    }
    for (final item in List.of(_queuedByPath[path] ?? const [])) {
      _dequeue(item);
    }
  }

  /// Pausa o loader
  void pause() {
    _paused = true;
    _logDebug('$_tag Paused');
  }

  /// Retoma o loader
  void resume() {
    _paused = false;
    if (!_isRunning) {
      _startLoader();
    }
    _logDebug('$_tag Resumed');
  }

  /// Inicia o loop de carregamento
  void _startLoader() {
    if (_isRunning) return;
    _isRunning = true;

    _logDebug('$_tag Started');
    _runLoaderLoop();
  }

  /// Loop principal do loader — dispatcher não-bloqueante.
  ///
  /// Em vez de await em cada slot (serial), dispara todos os slots disponíveis
  /// como Futures independentes e aguarda apenas um timer curto. Isso mantém
  /// downloads SMB e processamento de imagem rodando em paralelo real:
  ///   • slot de download  → limitado por _maxActiveDownloads (SMB semaphore)
  ///   • slot de metadata  → limitado por _maxActiveMetadata
  ///   • slot de processing→ limitado por _maxActiveProcessing (CPU/compute)
  Future<void> _runLoaderLoop() async {
    while (_isRunning) {
      if (_paused) {
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }

      // Dispara quantos slots couberem nos limites de concorrência.
      // Nenhum await aqui — os _execute* rodam em paralelo.
      _dispatchAvailableSlots();

      // Para quando não há mais nada em nenhuma fila.
      if (_workQueue.isEmpty &&
          _activeDownloads.isEmpty &&
          _activeProcessing.isEmpty &&
          _activeMetadata.isEmpty) {
        _isRunning = false;
        _logDebug('$_tag All work completed');
        break;
      }

      // Pausa curta: deixa os Futures em andamento progredirem antes de
      // tentar despachar novos slots. 20ms é suficiente sem desperdiçar CPU.
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Despacha todos os slots que cabem dentro dos limites de concorrência.
  /// Chamado a cada tick do loop — não bloqueia.
  void _dispatchAvailableSlots() {
    if (_paused || !_isRunning) return;
    final cancelledReady = _activeDownloads.values
        .where((item) => item.cancelled && item.localPath != null)
        .toList();
    for (final item in cancelledReady) {
      unawaited(_cleanupItem(item));
    }
    // Processing primeiro: consome arquivos já baixados sem usar SMB.
    while (_activeProcessing.length < _maxActiveProcessing) {
      if (!_dispatchProcessingSlot()) break;
    }

    // Downloads: respeita o semáforo SMB via _maxActiveDownloads.
    while (_activeDownloads.length < _maxActiveDownloads) {
      if (!_dispatchDownloadSlot()) break;
    }

    // Metadata: ranged reads leves, um por vez.
    while (_activeMetadata.length < _maxActiveMetadata) {
      if (!_dispatchMetadataSlot()) break;
    }
  }

  /// Despacha um slot de download. Retorna true se despachado.
  bool _isActive(String id) =>
      _activeDownloads.containsKey(id) ||
      _activeProcessing.containsKey(id) ||
      _activeMetadata.containsKey(id);

  bool _isDispatchable(ThumbnailWorkItem i) =>
      _workQueue.contains(i) &&
      !i.cancelled &&
      i.status == WorkItemStatus.pending &&
      !_isActive(i.id);

  bool _dispatchDownloadSlot() {
    ThumbnailWorkItem? item;
    while (_criticalOrder.isNotEmpty) {
      final candidate = _criticalOrder.last;
      _criticalOrder.remove(candidate);
      if (_isDispatchable(candidate)) {
        item = candidate;
        break;
      }
      _dequeue(candidate);
    }
    for (var p = 1; p < _thumbBuckets.length && item == null; p++) {
      final bucket = _thumbBuckets[p];
      while (bucket.isNotEmpty) {
        final candidate = bucket.removeFirst();
        if (candidate.priority.index != p) {
          continue; // Stale entry: promoted into another bucket.
        }
        if (_isDispatchable(candidate)) {
          item = candidate;
          break;
        }
        _dequeue(candidate);
      }
    }

    if (item == null) return false;

    _activeDownloads[item.id] = item;
    _dequeue(item);
    item.status = WorkItemStatus.downloading;
    item.startedAt = DateTime.now();

    _notifyStatsUpdate();
    unawaited(_executeDownload(item)); // fire-and-forget
    return true;
  }

  /// Despacha um slot de metadata. Retorna true se despachado.
  bool _dispatchMetadataSlot() {
    ThumbnailWorkItem? item;
    while (_metadataQueue.isNotEmpty) {
      final candidate = _metadataQueue.removeFirst();
      if (_isDispatchable(candidate)) {
        item = candidate;
        break;
      }
      _dequeue(candidate);
    }

    if (item == null) return false;

    _activeMetadata[item.id] = item;
    _dequeue(item);
    item.status = WorkItemStatus.downloading;
    item.startedAt = DateTime.now();

    _notifyStatsUpdate();
    unawaited(_executeMetadata(item)); // fire-and-forget
    return true;
  }

  /// Despacha um slot de processamento. Retorna true se despachado.
  bool _dispatchProcessingSlot() {
    ThumbnailWorkItem? item;
    try {
      item = _activeDownloads.values.toList().firstWhere(
        (i) => !i.cancelled && i.localPath != null && !i.processingStarted,
      );
    } catch (_) {
      item = null;
    }

    if (item == null) return false;

    item.processingStarted = true;
    _activeProcessing[item.id] = item;
    _activeDownloads.remove(item.id);
    item.status = WorkItemStatus.processing;

    _notifyStatsUpdate();
    unawaited(_executeProcessing(item)); // fire-and-forget
    return true;
  }

  /// Executa o download de um arquivo
  Future<void> _executeDownload(ThumbnailWorkItem item) async {
    try {
      final cachedPath = thumbCache.getThumbOutputPath(item.path);
      final cachedStat = await File(cachedPath).stat();
      if (item.cancelled) {
        await _cleanupItem(item);
        return;
      }
      if (cachedStat.type == FileSystemEntityType.file && cachedStat.size > 0) {
        item.localPath = cachedPath;
        _dispatchAvailableSlots();
        return;
      }
      // For video thumbnails try proxy/Ranged reads first to avoid full downloads
      if (item.isVideo && item.type == WorkType.thumbnail) {
        Uri? proxyUri;
        try {
          final uri = await smbVideoProxyServer.registerSource(
            ip: item.ip,
            share: item.share,
            path: item.path,
            username: item.username,
            password: item.password,
            fileSizeOverride: (item.item['size'] as num?)?.toInt(),
            thumbnailOnly: true,
          );
          proxyUri = uri;

          // Attempt to generate thumbnail directly from proxy (HTTP Range support)
          final outPath = thumbCache.getThumbOutputPath(item.path);
          final thumb = await _generateVideoThumbnailFromProxy(uri, outPath);
          if (item.cancelled) {
            await _cleanupItem(item);
            return;
          }
          if (thumb != null) {
            await _completeWithThumb(item, thumb);
            return;
          }
        } catch (e) {
          debugPrint('$_tag Failed to start proxy for ${item.name}: $e');
        } finally {
          smbVideoProxyServer.unregisterSource(
            proxyUri?.queryParameters['token'],
          );
        }

        // Tenta leitura parcial do vídeo
        try {
          final partial = await _tryPartialDownloadForVideo(
            item,
            maxBytes: 512 * 1024,
          );
          if (partial != null) {
            item.localPath = partial;
            _stats.downloadsCompleted++;
            _dispatchAvailableSlots(); // kick processing immediately
            _notifyStatsUpdate();
            return;
          }
        } catch (e) {
          debugPrint(
            '$_tag Partial download fallback failed for ${item.name}: $e',
          );
        }
      }

      // Imagens: leitura única + decode nativo com subamostragem no Android.
      // Leituras parciais de JPEG não decodificam e acabavam em download completo.
      if (item.isImage && item.type == WorkType.thumbnail) {
        final outPath = thumbCache.getThumbOutputPath(item.path);
        final native = await SMBClient.smbImageThumbnail(
          item.ip,
          item.share,
          item.path,
          outPath: outPath,
        );
        if (item.cancelled) {
          await _cleanupItem(item);
          return;
        }
        if (native.success && native.data != null) {
          await _completeWithThumb(item, native.data!);
          return;
        }
      }

      // Para imagens: tenta leitura parcial antes do download completo
      if (item.isImage &&
          item.type == WorkType.thumbnail &&
          ((item.item['size'] as num?) ?? 0) > 256 * 1024) {
        try {
          final partial = await _tryPartialDownloadForImage(
            item,
            maxBytes: 256 * 1024,
          );
          if (partial != null) {
            item.localPath = partial;
            _stats.downloadsCompleted++;
            _dispatchAvailableSlots(); // kick processing immediately
            _notifyStatsUpdate();
            return;
          }
        } catch (e) {
          debugPrint(
            '$_tag Partial image download failed for ${item.name}: $e',
          );
        }
      }

      // Download completo (fallback)
      var attempts = 0;
      while (attempts < _maxRetries) {
        attempts++;
        final result = await SMBClient.fetchFile(
          item.ip,
          item.share,
          item.path,
          username: item.username,
          password: item.password,
        );
        if (item.cancelled) {
          _cleanupItem(item);
          return;
        }
        if (result.success && result.data != null) {
          item.localPath = result.data!;
          _stats.downloadsCompleted++;
          break;
        } else if (attempts < _maxRetries) {
          await Future.delayed(Duration(milliseconds: 200 * attempts));
        } else {
          throw Exception(
            'Download failed after $_maxRetries attempts: ${result.error}',
          );
        }
      }
    } catch (e) {
      debugPrint('$_tag Download error for ${item.name}: $e');
      item.error = e.toString();
      item.status = WorkItemStatus.failed;
      _stats.downloadsFailed++;
      _failedPaths.add(item.path);
      item.onError?.call(e.toString());
      _cleanupItem(item);
      return;
    }

    if (!item.cancelled && item.localPath != null) {
      _dispatchAvailableSlots(); // kick processing immediately after download
    } else {
      _cleanupItem(item);
    }

    _notifyStatsUpdate();
  }

  /// Registra um thumb pronto gerado sem passar pela etapa de processamento.
  Future<void> _completeWithThumb(ThumbnailWorkItem item, String thumb) async {
    await thumbCache.put(smbPath: item.path, thumbPath: thumb);
    item.localPath = thumb;
    _stats.downloadsCompleted++;
    item.status = WorkItemStatus.completed;
    _stats.thumbnailsCompleted++;
    final readyCallback = item.onThumbnailReady;
    if (readyCallback != null) {
      scheduleMicrotask(() {
        try {
          readyCallback(item);
        } catch (e) {
          debugPrint('Error in onThumbnailReady callback: $e');
        }
      });
    }
    emitThumbnailReady(
      item.path,
      thumb,
      duration: thumbCache.getDuration(item.path),
    );
    _cleanupItem(item);
    _notifyStatsUpdate();
  }

  /// Tenta baixar parcialmente os primeiros bytes da imagem e retorna um temp file
  /// Retorna null se não conseguiu gerar thumb.
  Future<String?> _tryPartialDownloadForImage(
    ThumbnailWorkItem item, {
    int maxBytes = 256 * 1024,
  }) async {
    try {
      const int chunkSize = 256 * 1024;
      int offset = 0;
      final tmpFile = File(
        '${Directory.systemTemp.path}/partialimg_${DateTime.now().microsecondsSinceEpoch}_${Uri.encodeComponent(item.name)}',
      );
      final iosink = tmpFile.openWrite();
      int totalRead = 0;
      String? thumbPath;
      while (totalRead < maxBytes) {
        final toRead = (maxBytes - totalRead) < chunkSize
            ? (maxBytes - totalRead)
            : chunkSize;
        final chunkResult = await SMBClient.readSmbFileChunk(
          item.ip,
          item.share,
          item.path,
          offset: offset,
          length: toRead,
          username: item.username,
          password: item.password,
        );
        if (!chunkResult.success || chunkResult.data == null) {
          await iosink.close();
          if (await tmpFile.exists()) await tmpFile.delete();
          return null;
        }
        final bytes = chunkResult.data!['bytes'] as Uint8List? ?? Uint8List(0);
        if (bytes.isEmpty) break;
        iosink.add(bytes);
        totalRead += bytes.length;
        offset += bytes.length;
        // Tenta gerar thumb a cada 256KB baixados
        if (totalRead % (256 * 1024) == 0 || totalRead >= maxBytes) {
          await iosink.flush();
          try {
            final outPath = thumbCache.getThumbOutputPath(item.path);
            final thumb = await _generateImageThumbnail(
              tmpFile.path,
              outPath,
              item,
            );
            if (thumb != null && thumb.isNotEmpty) {
              thumbPath = thumb;
              break;
            }
          } catch (e) {
            debugPrint('$_tag Partial image thumb gen failed: $e');
          }
        }
        if (bytes.length < toRead) break;
      }
      await iosink.close();
      if (thumbPath != null) {
        if (await tmpFile.exists()) await tmpFile.delete();
        return thumbPath;
      }
      // Última tentativa após baixar tudo
      final outPath = thumbCache.getThumbOutputPath(item.path);
      final thumb = await _generateImageThumbnail(tmpFile.path, outPath, item);
      if (thumb != null && thumb.isNotEmpty) {
        if (await tmpFile.exists()) await tmpFile.delete();
        return thumb;
      }
      if (await tmpFile.exists()) await tmpFile.delete();
      return null;
    } catch (e) {
      debugPrint('$_tag Partial image download error: $e');
      return null;
    }
  }

  /// Executa extração de metadados
  Future<void> _executeMetadata(ThumbnailWorkItem item) async {
    try {
      // For videos, try to read duration via ranged reads (moov/mvhd) before
      // doing a full fetch. This avoids downloading the whole file in most cases.
      double? duration;
      if (item.isVideo) {
        duration = await readRemoteMp4Duration(
          ip: item.ip,
          share: item.share,
          path: item.path,
          username: item.username,
          password: item.password,
          fileSize: (item.item['size'] as num?)?.toInt(),
        );
      }

      if (item.cancelled) return;
      if (duration != null) {
        // Persist duration and emit events without fetching full file
        await thumbCache.putDuration(item.path, duration);
        if (item.cancelled) return;
        _stats.metadataExtracted++;
        item.onMetadataReady?.call(duration);
        try {
          emitThumbnailReady(item.path, null, duration: duration);
        } catch (_) {}
        // Enfileira thumbnail generation (will do proxy/partial reads)
        _queueThumbnalForVideo(item);
        _cleanupItem(item);
        return;
      }

      // Let the native extractor seek over HTTP ranges for other containers.
      // Sorting must never explicitly download a complete video.
      final uri = await smbVideoProxyServer.registerSource(
        ip: item.ip,
        share: item.share,
        path: item.path,
        username: item.username,
        password: item.password,
        fileSizeOverride: (item.item['size'] as num?)?.toInt(),
        thumbnailOnly: true,
      );
      SMBResult<num?> durResult;
      try {
        if (item.cancelled) return;
        durResult = await SMBClient.getVideoDuration(uri.toString());
      } finally {
        smbVideoProxyServer.unregisterSource(uri.queryParameters['token']);
      }
      if (item.cancelled) return;

      if (durResult.success && durResult.data != null && durResult.data! > 0) {
        final d = durResult.data!.toDouble();
        await thumbCache.putDuration(item.path, d);
        if (item.cancelled) return;
        _stats.metadataExtracted++;
        item.onMetadataReady?.call(d);
        try {
          emitThumbnailReady(item.path, null, duration: d);
        } catch (_) {}
        _queueThumbnalForVideo(item);
      }
    } catch (e) {
      debugPrint('$_tag Metadata error for ${item.name}: $e');
      _stats.metadataFailed++;
      _failedPaths.add(item.path);
    } finally {
      _cleanupItem(item);
    }

    _notifyStatsUpdate();
  }

  /// Adiciona thumbnail de vídeo à fila após ter metadata
  void _queueThumbnalForVideo(ThumbnailWorkItem item) {
    // Verifica se já tem thumbnail
    if (item.cancelled ||
        item.item['thumb'] != null ||
        _processedPaths.contains('${item.path}_${WorkType.thumbnail.name}')) {
      return;
    }

    // Cria work item para thumbnail usando o arquivo já baixado
    final thumbWork = ThumbnailWorkItem(
      id: '${item.id}_thumb',
      ip: item.ip,
      share: item.share,
      path: item.path,
      name: item.name,
      username: item.username,
      password: item.password,
      type: WorkType.thumbnail,
      item: item.item,
      initialPriority: LoadPriority.medium,
      onThumbnailReady: item.onThumbnailReady,
      onError: item.onError,
    );

    // Marca como já processado e com arquivo local
    _processedPaths.add('${thumbWork.path}_${thumbWork.type.name}');

    // Adiciona diretamente à fila de processamento se já tem o arquivo
    if (item.localPath != null) {
      thumbWork.localPath = item.localPath;
      item.localPath = null;
      _activeDownloads[thumbWork.id] = thumbWork;
    } else {
      _enqueue(thumbWork);
    }
  }

  /// Processa a geração de thumbnail
  Future<void> _executeProcessing(ThumbnailWorkItem item) async {
    try {
      // Verifica cancelamento antes de iniciar o compute() (pode ter chegado
      // durante o tempo que o item ficou na fila de processing).
      if (item.cancelled) {
        _cleanupItem(item);
        return;
      }

      final thumbPath = await _generateThumbnail(
        item.localPath!,
        item.name,
        item.path,
        item,
      );

      // Verifica cancelamento DEPOIS do compute() — pode ter chegado enquanto
      // o isolate ainda processava (navegação de volta durante decode/resize).
      if (item.cancelled) {
        _cleanupItem(item);
        return;
      }

      if (thumbPath != null && !item.cancelled) {
        // Read duration from the persistent thumbnail cache (safe) so we
        // don't rely on directly mutating the shared item map.
        final duration = thumbCache.getDuration(item.path);

        await thumbCache.put(
          smbPath: item.path,
          thumbPath: thumbPath,
          duration: duration,
        );
        item.status = WorkItemStatus.completed;
        _stats.thumbnailsCompleted++;

        // Defer the write to the shared folder-items map so it never lands
        // while the caller is iterating over it (fixes ConcurrentModificationError)
        // === MUDANÇA IMPORTANTE AQUI ===
        final readyCallback = item.onThumbnailReady;

        // Executa o callback de forma segura (fora do isolate/microtask perigoso)
        if (readyCallback != null) {
          scheduleMicrotask(() {
            try {
              readyCallback(
                item,
              ); // callback que a UI deve tratar com segurança
            } catch (e) {
              debugPrint('Error in onThumbnailReady callback: $e');
            }
          });
        }
        try {
          final cachedDur = thumbCache.getDuration(item.path);
          debugPrint(
            '[EMIT_PROCESSING] Emitting: ${item.name}, thumbPath=$thumbPath',
          );
          emitThumbnailReady(item.path, thumbPath, duration: cachedDur);
        } catch (e) {
          debugPrint('[EMIT_PROCESSING] Error emitting: $e');
        }

        // Cache em memória
        final file = File(thumbPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.length <= 256 * 1024) {
            imageMemoryCache.put(thumbPath, bytes, sizeBytes: bytes.length);
          }
        }
      } else {
        throw Exception('Thumbnail generation returned null');
      }
    } catch (e) {
      debugPrint('$_tag Processing error for ${item.name}: $e');
      item.error = e.toString();
      item.status = WorkItemStatus.failed;
      _stats.thumbnailsFailed++;
      _failedPaths.add(item.path);
      item.onError?.call(e.toString());
    } finally {
      _cleanupItem(item);
    }

    _notifyStatsUpdate();
  }

  /// Gera thumbnail para arquivo.
  /// Recebe [item] para checar cancelamento antes/depois do compute().
  Future<String?> _generateThumbnail(
    String localPath,
    String name,
    String originalPath,
    ThumbnailWorkItem item,
  ) async {
    final outPath = thumbCache.getThumbOutputPath(originalPath);

    // Verifica se já existe
    final cachedFile = File(outPath);
    if (await cachedFile.exists() && await cachedFile.length() > 0) {
      return outPath;
    }

    if (item.cancelled) return null;

    final n = name.toLowerCase();

    try {
      if (isVideoFile(n)) {
        return await _generateVideoThumbnail(localPath, outPath);
      } else if (n.endsWith('.gif')) {
        return await _generateGifThumbnail(localPath, outPath, item);
      } else {
        return await _generateImageThumbnail(localPath, outPath, item);
      }
    } catch (e) {
      debugPrint('$_tag Thumbnail generation failed: $e');
      return null;
    }
  }

  /// Gera thumbnail de vídeo (local path).
  Future<String?> _generateVideoThumbnail(
    String videoPath,
    String outPath,
  ) async {
    try {
      // Usa método nativo que baixa só os frames necessários (muito mais rápido!)
      final thumbResult = await SMBClient.generateThumbnail(videoPath);
      if (thumbResult.success && thumbResult.data is Map) {
        final thumbPath = thumbResult.data['thumbPath'] as String?;
        final duration = (thumbResult.data['duration'] as num?)?.toDouble();
        if (thumbPath != null && thumbPath.isNotEmpty) {
          // Copia para nossa localização de cache
          await File(thumbPath).copy(outPath);

          // Notify processing items via event bus instead of mutating maps
          if (duration != null) {
            final toUpdate = <ThumbnailWorkItem>[];
            for (final processingItem in _activeProcessing.values.toList()) {
              if (processingItem.localPath == videoPath) {
                toUpdate.add(processingItem);
                break;
              }
            }
            for (final processingItem in toUpdate) {
              try {
                emitThumbnailReady(
                  processingItem.path,
                  null,
                  duration: duration,
                );
              } catch (_) {}
            }
          }

          return outPath;
        }
      }
    } catch (e) {
      debugPrint('$_tag Platform thumbnail failed: $e');
    }

    // Fallback: extrair frame manualmente
    try {
      final thumb = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: outPath,
        imageFormat: ImageFormat.JPEG,
        maxHeight: 256,
        quality: 70,
        timeMs: 1000, // Frame at 1s
      );
      if (thumb != null && thumb.isNotEmpty) {
        return thumb;
      }
    } catch (e) {
      debugPrint('$_tag Fallback thumbnail failed: $e');
    }

    return null;
  }

  /// Gera thumbnail a partir de um proxy HTTP (Range-aware). Retorna path do thumb ou null.
  Future<String?> _generateVideoThumbnailFromProxy(
    Uri proxyUri,
    String outPath,
  ) async {
    try {
      // VideoThumbnail supports network URIs when accessible locally (HTTP)
      final thumb = await VideoThumbnail.thumbnailFile(
        video: proxyUri.toString(),
        thumbnailPath: outPath,
        imageFormat: ImageFormat.JPEG,
        maxHeight: 256,
        quality: 70,
        timeMs: 1000,
      );
      if (thumb != null && thumb.isNotEmpty) return thumb;
    } catch (e) {
      debugPrint('$_tag Proxy-based thumbnail failed: $e');
    }
    return null;
  }

  /// Tenta baixar parcialmente os primeiros bytes do vídeo e retornar um local temp file
  /// que seja suficiente para gerar um thumbnail. Retorna null se não conseguiu.
  Future<String?> _tryPartialDownloadForVideo(
    ThumbnailWorkItem item, {
    int maxBytes = 512 * 1024,
  }) async {
    // Partial reads stay small so slow SMB responses fail fast.
    try {
      const int chunkSize = 128 * 1024; // 128 KB por leitura
      int offset = 0;
      final tmpFile = File(
        '${Directory.systemTemp.path}/partial_${DateTime.now().microsecondsSinceEpoch}_${Uri.encodeComponent(item.name)}',
      );
      final iosink = tmpFile.openWrite();
      int totalRead = 0;
      String? thumbPath;
      while (totalRead < maxBytes) {
        final toRead = (maxBytes - totalRead) < chunkSize
            ? (maxBytes - totalRead)
            : chunkSize;
        final chunkResult = await SMBClient.readSmbFileChunk(
          item.ip,
          item.share,
          item.path,
          offset: offset,
          length: toRead,
          username: item.username,
          password: item.password,
        );

        if (!chunkResult.success || chunkResult.data == null) {
          await iosink.close();
          if (await tmpFile.exists()) await tmpFile.delete();
          return null;
        }

        final bytes = chunkResult.data!['bytes'] as Uint8List? ?? Uint8List(0);
        if (bytes.isEmpty) break;
        iosink.add(bytes);
        totalRead += bytes.length;
        offset += bytes.length;

        // Tenta gerar thumb a cada 256KB baixados
        if (totalRead % (256 * 1024) == 0 || totalRead >= maxBytes) {
          await iosink.flush();
          try {
            final outPath = thumbCache.getThumbOutputPath(item.path);
            final thumb = await VideoThumbnail.thumbnailFile(
              video: tmpFile.path,
              thumbnailPath: outPath,
              imageFormat: ImageFormat.JPEG,
              maxHeight: 256,
              quality: 70,
              timeMs: 1000,
            );
            if (thumb != null && thumb.isNotEmpty) {
              thumbPath = thumb;
              break;
            }
          } catch (e) {
            // ignora e continua
          }
        }

        if (bytes.length < toRead) break;
      }

      await iosink.close();
      if (thumbPath != null) {
        if (await tmpFile.exists()) await tmpFile.delete();
        return thumbPath;
      }
      // Última tentativa após baixar tudo
      final outPath = thumbCache.getThumbOutputPath(item.path);
      final thumb = await VideoThumbnail.thumbnailFile(
        video: tmpFile.path,
        thumbnailPath: outPath,
        imageFormat: ImageFormat.JPEG,
        maxHeight: 256,
        quality: 70,
        timeMs: 1000,
      );
      if (thumb != null && thumb.isNotEmpty) {
        if (await tmpFile.exists()) await tmpFile.delete();
        return thumb;
      }
      if (await tmpFile.exists()) await tmpFile.delete();
      return null;
    } catch (e) {
      debugPrint('$_tag Partial download error: $e');
      return null;
    }
  }

  /// Gera thumbnail de GIF
  Future<String?> _generateGifThumbnail(
    String gifPath,
    String outPath,
    ThumbnailWorkItem item,
  ) async {
    try {
      if (item.cancelled) return null;
      return await _generateImageThumbnail(gifPath, outPath, item);
    } catch (e) {
      debugPrint('$_tag GIF thumbnail failed: $e');
      return await _generateImageThumbnail(gifPath, outPath, item);
    }
  }

  /// Processa GIF em isolate
  static Future<String?> _processRasterThumbnail(
    Map<String, dynamic> args,
  ) async {
    try {
      final bytes = args['bytes'] as Uint8List;
      final outPath = args['outPath'] as String;

      final source = img.decodeImage(bytes, frame: 0);
      if (source == null) {
        return null;
      }
      final decoded = img.bakeOrientation(source);
      final targetWidth = decoded.width >= decoded.height
          ? decoded.width.clamp(1, 320)
          : null;
      final targetHeight = decoded.height > decoded.width
          ? decoded.height.clamp(1, 320)
          : null;
      final resized = img.copyResize(
        decoded,
        width: targetWidth,
        height: targetHeight,
        interpolation: img.Interpolation.average,
      );
      final encoded = img.encodeJpg(resized, quality: 75);
      await File(outPath).writeAsBytes(encoded);
      return outPath;
    } catch (e) {
      return null;
    }
  }

  /// Gera thumbnail de imagem
  Future<String?> _generateImageThumbnail(
    String imagePath,
    String outPath,
    ThumbnailWorkItem item,
  ) async {
    try {
      if (item.cancelled) return null;
      final native = await generateImageThumbnailNative(
        imagePath,
        outPath,
        320,
      );
      if (item.cancelled) return null;
      if (native != null) return native;
      final bytes = await File(imagePath).readAsBytes();

      if (item.cancelled) return null;
      // Processa em isolate para manter a UI responsiva
      final result = await compute(_processRasterThumbnail, {
        'bytes': bytes,
        'outPath': outPath,
      });
      // Descarta o resultado se o item foi cancelado enquanto o isolate rodava.
      if (item.cancelled) return null;
      return result;
    } catch (e) {
      debugPrint('$_tag Image thumbnail failed: $e');
      return null;
    }
  }

  /// Limpa item após processamento
  Future<void> _cleanupItem(ThumbnailWorkItem item) async {
    if (identical(_activeDownloads[item.id], item)) {
      _activeDownloads.remove(item.id);
    }
    if (identical(_activeProcessing[item.id], item)) {
      _activeProcessing.remove(item.id);
    }
    if (identical(_activeMetadata[item.id], item)) {
      _activeMetadata.remove(item.id);
    }

    if (item.cancelled || item.status == WorkItemStatus.failed) {
      _processedPaths.remove('${item.path}_${item.type.name}');
    }

    if (item.localPath != null) {
      // Deleta após um tempo se não for thumbnail salva
      if (!item.localPath!.contains('thumb_')) {
        final f = File(item.localPath!);
        try {
          if (await f.exists()) {
            await f.delete();
          }
        } catch (_) {}
      }
    }
  }

  /// Notifica listeners de estatísticas
  void _notifyStatsUpdate() {
    // Called for every queued item; skip the snapshot work nobody consumes.
    // `stats` refreshes the counters itself when polled.
    if (!_statsController.hasListener) return;
    _refreshStats();
    _statsController.add(_stats.toPublicStats());
  }

  void _refreshStats() {
    _stats.update(
      queueSize: _workQueue.length,
      activeDownloads: _activeDownloads.length,
      activeProcessing: _activeProcessing.length,
      activeMetadata: _activeMetadata.length,
      failedPaths: _failedPaths,
    );
  }

  /// Retorna estatísticas atuais
  LoaderStats get stats {
    _refreshStats();
    return _stats.toPublicStats();
  }

  /// Verifica se é arquivo de vídeo
  static bool isVideoFile(String name) {
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

  /// Verifica se é imagem
  static bool isImageFile(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.png') ||
        n.endsWith('.gif') ||
        n.endsWith('.bmp') ||
        n.endsWith('.webp');
  }

  /// Dispose
  void dispose() {
    cancelAll();
    _isRunning = false;
    _statsController.close();
  }
}

/// Estatísticas internas
class _LoaderStats {
  int totalQueued = 0;
  int downloadsCompleted = 0;
  int downloadsFailed = 0;
  int thumbnailsCompleted = 0;
  int thumbnailsFailed = 0;
  int metadataExtracted = 0;
  int metadataFailed = 0;
  int currentQueueSize = 0;
  int activeDownloadsCount = 0;
  int activeProcessingCount = 0;
  int activeMetadataCount = 0;
  List<String> failedPaths = const <String>[];

  DateTime startedAt = DateTime.now();

  void update({
    int? queueSize,
    int? activeDownloads,
    int? activeProcessing,
    int? activeMetadata,
    List<String>? failedPaths,
  }) {
    currentQueueSize = queueSize ?? currentQueueSize;
    activeDownloadsCount = activeDownloads ?? activeDownloadsCount;
    activeProcessingCount = activeProcessing ?? activeProcessingCount;
    if (activeMetadata != null) {
      activeMetadataCount = activeMetadata;
    }
    if (failedPaths != null) {
      this.failedPaths = List<String>.unmodifiable(failedPaths);
    }
  }

  void reset() {
    totalQueued = 0;
    downloadsCompleted = 0;
    downloadsFailed = 0;
    thumbnailsCompleted = 0;
    thumbnailsFailed = 0;
    metadataExtracted = 0;
    metadataFailed = 0;
    failedPaths = const <String>[];
  }

  LoaderStats toPublicStats() {
    // Items still in progress or queue
    final itemsInProgress =
        currentQueueSize +
        activeDownloadsCount +
        activeProcessingCount +
        activeMetadataCount;
    // Items successfully completed
    final successfullyCompleted =
        totalQueued -
        itemsInProgress -
        (downloadsFailed + thumbnailsFailed + metadataFailed);

    return LoaderStats(
      totalItems: totalQueued,
      completedItems: successfullyCompleted,
      failedItems: downloadsFailed + thumbnailsFailed + metadataFailed,
      queueSize: currentQueueSize,
      activeDownloads: activeDownloadsCount,
      activeProcessing: activeProcessingCount,
      activeMetadata: activeMetadataCount,
      failedPaths: failedPaths,
      elapsed: DateTime.now().difference(startedAt),
    );
  }
}

/// Estatísticas públicas
class LoaderStats {
  final int totalItems;
  final int completedItems;
  final int failedItems;
  final int queueSize;
  final int activeDownloads;
  final int activeProcessing;
  final int activeMetadata;
  final List<String> failedPaths;
  final Duration elapsed;

  LoaderStats({
    required this.totalItems,
    required this.completedItems,
    required this.failedItems,
    required this.queueSize,
    required this.activeDownloads,
    required this.activeProcessing,
    required this.activeMetadata,
    required this.failedPaths,
    required this.elapsed,
  });

  double get progress => totalItems > 0 ? completedItems / totalItems : 0;
  int get remaining =>
      queueSize + activeDownloads + activeProcessing + activeMetadata;
  bool get isFinished =>
      remaining == 0 && completedItems + failedItems == totalItems;

  @override
  String toString() =>
      'LoaderStats(progress: ${(progress * 100).toStringAsFixed(1)}%, '
      'queue: $queueSize, downloads: $activeDownloads, processing: $activeProcessing)';
}
