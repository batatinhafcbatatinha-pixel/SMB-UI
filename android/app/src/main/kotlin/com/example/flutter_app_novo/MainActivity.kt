package com.example.flutter_app_novo

import android.util.Log
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2CreateOptions
import com.hierynomus.msfscc.fileinformation.FileIdBothDirectoryInformation
import com.hierynomus.msdtyp.FileTime
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.*
import java.util.concurrent.Executors
import java.io.File
import java.io.FileOutputStream
import java.io.ByteArrayOutputStream
import java.util.concurrent.Semaphore
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

class MainActivity : FlutterActivity() {
    private val CHANNEL = "smb_channel"
    // SMBJ share/session handling is not reliable under concurrent use here.
    // Serialize Android-side SMB work to avoid closing a share while another task is using it.
    private val executor = Executors.newSingleThreadExecutor()
    // Separate pool for chunk reads to keep video streaming responsive under 4K prefetch.
    // Reduce threads to avoid overwhelming the server and triggering connection closures.
    private val streamExecutor = Executors.newFixedThreadPool(2)
    // Video playback reads: never queued behind thumbnail/metadata chunk reads.
    // Sized for the proxy's 3 speculative reads plus the one playback waits on.
    private val playbackExecutor = Executors.newFixedThreadPool(4)
    private val metadataExecutor = Executors.newSingleThreadExecutor()
    // Parallel range reads for fetchFile (whole-file downloads).
    private val fetchReadWindow = 4
    private val fetchReadPool = Executors.newFixedThreadPool(fetchReadWindow)
    // Image thumbnails: SMB read + native decode, off the listing/fetch executor.
    private val thumbExecutor = Executors.newFixedThreadPool(2)
    // Uploads can take minutes; keep them off the listing/fetch executor.
    private val uploadExecutor = Executors.newSingleThreadExecutor()
    // Config with timeouts to prevent broken pipe errors
    private val smbConfig = SmbConfig.builder()
        .withTimeout(60, TimeUnit.SECONDS)
        // No socket read timeout: the connection is now long-lived, and an idle
        // minute made SMBJ's packet reader drop it. Per-request timeouts above
        // still catch a dead server.
        .withSoTimeout(0, TimeUnit.SECONDS)
        .build()
    private val smbClient = SMBClient(smbConfig)
    // Limit concurrent fetchFile operations to avoid overwhelming the server
    // Lower to 1 to serialize heavy fetches and reduce DiskShare closure errors.
    private val fetchSemaphore = Semaphore(1)

    // fetchFile request ids the app no longer needs (user swiped away / closed the viewer).
    private val cancelledFetches = ConcurrentHashMap.newKeySet<String>()
    private class FetchCancelledException : Exception("Fetch cancelled")

    // Diagnostics
    private val invalidationCounter = AtomicInteger(0)
    private val retryCounter = AtomicLong(0)
    private val connectionCreationCounter = AtomicInteger(0)

    private fun releaseShare(ip: String, shareName: String) {
        // no-op: connections are closed in withFreshShare finally block
    }

    private fun fileTimeToMillis(ft: FileTime?): Long {
        return ft?.toEpochMillis() ?: 0L
    }

    /**
     * Get a valid connection from pool or create a new one.
     * This method checks if the cached connection is still alive before returning it.
     */
    private fun getOrCreateConnection(ip: String): Pair<Connection, Session> {
        val connection = smbClient.connect(ip)
        val session = connection.authenticate(
            AuthenticationContext("smbuser", "5723".toCharArray(), "")
        )
        connectionCreationCounter.incrementAndGet()
        return Pair(connection, session)
    }

    private fun createFreshConnection(ip: String): Pair<Connection, Session> {
        val connection = smbClient.connect(ip)
        val session = connection.authenticate(
            AuthenticationContext("smbuser", "5723".toCharArray(), "")
        )
        connectionCreationCounter.incrementAndGet()
        return Pair(connection, session)
    }

    private class ShareHandle(val key: String, val session: Session, val share: DiskShare)

    // SMBClient.connect() returns the same pooled Connection for a host, so closing it
    // after every call tore down the transport under the other executor threads and
    // forced a full TCP + NTLM handshake per chunk. SMBJ sessions and shares are
    // thread-safe, so all executors now share one session per server/share (Windows
    // client editions only accept ~20 concurrent sessions) and reconnect after errors.
    private val shareHandles = HashMap<String, ShareHandle>()

    private fun closeHandle(handle: ShareHandle?) {
        try { handle?.share?.close() } catch (_: Exception) { }
        try { handle?.session?.close() } catch (_: Exception) { }
    }

    private fun acquireHandle(ip: String, shareName: String): ShareHandle = synchronized(shareHandles) {
        val key = "$ip|$shareName"
        val current = shareHandles[key]
        if (current != null && current.share.isConnected && current.session.connection.isConnected) {
            return current
        }
        closeHandle(current)
        shareHandles.remove(key)
        val (_, session) = createFreshConnection(ip)
        val handle = try {
            ShareHandle(key, session, session.connectShare(shareName) as DiskShare)
        } catch (e: Exception) {
            try { session.close() } catch (_: Exception) { }
            throw e
        }
        shareHandles[key] = handle
        handle
    }

    private fun invalidateHandle(handle: ShareHandle) = synchronized(shareHandles) {
        if (shareHandles[handle.key] === handle) shareHandles.remove(handle.key)
        closeHandle(handle)
    }

    private class ChunkHandle(
        val file: com.hierynomus.smbj.share.File,
        val share: DiskShare,
        val size: Long,
        @Volatile var lastUsed: Long
    )

    // Streaming reads the same file in many 1 MB chunks. Reopening it each time cost
    // create + query-info + close round trips per chunk, so keep a few handles open.
    private val chunkHandles = LinkedHashMap<String, ChunkHandle>(8, 0.75f, true)
    private val chunkHandleIdleMs = 60_000L
    private val maxChunkHandles = 4

    private fun chunkKey(ip: String, shareName: String, path: String) =
        "$ip|$shareName|${path.replace('/', '\\').trimStart('\\').lowercase()}"

    private fun openForChunks(ip: String, shareName: String, share: DiskShare, smPath: String): ChunkHandle {
        val key = chunkKey(ip, shareName, smPath)
        val now = System.currentTimeMillis()
        val stale = ArrayList<ChunkHandle>()
        val cached = synchronized(chunkHandles) {
            val it = chunkHandles.entries.iterator()
            while (it.hasNext()) {
                val e = it.next()
                if (e.key != key && now - e.value.lastUsed > chunkHandleIdleMs) {
                    stale.add(e.value); it.remove()
                }
            }
            chunkHandles[key]?.takeIf { it.share === share && share.isConnected }
        }
        stale.forEach { try { it.file.close() } catch (_: Exception) { } }
        if (cached != null) {
            cached.lastUsed = now
            return cached
        }
        val file = share.openFile(
            smPath,
            java.util.EnumSet.of(AccessMask.GENERIC_READ),
            java.util.EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL),
            java.util.EnumSet.of(SMB2ShareAccess.FILE_SHARE_READ),
            SMB2CreateDisposition.FILE_OPEN,
            java.util.EnumSet.noneOf(SMB2CreateOptions::class.java)
        )
        val opened = ChunkHandle(file, share, file.fileInformation.standardInformation.endOfFile, now)
        val evicted = ArrayList<ChunkHandle>()
        val winner = synchronized(chunkHandles) {
            val existing = chunkHandles[key]?.takeIf { it.share === share }
            if (existing != null) {
                evicted.add(opened) // another thread opened it first
                existing
            } else {
                chunkHandles[key]?.let { evicted.add(it) }
                chunkHandles[key] = opened
                while (chunkHandles.size > maxChunkHandles) {
                    val eldest = chunkHandles.entries.iterator().next()
                    evicted.add(eldest.value)
                    chunkHandles.remove(eldest.key)
                }
                opened
            }
        }
        evicted.forEach { try { it.file.close() } catch (_: Exception) { } }
        return winner
    }

    private fun dropChunkHandle(ip: String, shareName: String, path: String) {
        val removed = synchronized(chunkHandles) { chunkHandles.remove(chunkKey(ip, shareName, path)) }
        try { removed?.file?.close() } catch (_: Exception) { }
    }

    private fun <T> withFreshShare(ip: String, shareName: String, block: (DiskShare) -> T): T {
        val handle = acquireHandle(ip, shareName)
        try {
            return block(handle.share)
        } catch (e: Exception) {
            // File-level errors (not found, access denied...) and cancellations keep
            // the shared session.
            val keepSession = e is FetchCancelledException ||
                (e is com.hierynomus.mssmb2.SMBApiException && handle.share.isConnected)
            if (!keepSession) {
                invalidateHandle(handle)
            }
            throw e
        }
    }

    /**
     * Mark connection as invalid and remove from pool
     */
    private fun invalidateConnection(ip: String) {
        // no-op: using fresh connections, no pool to invalidate
    }

    private fun prunePool() {
        // no-op: using fresh connections, no pool to prune
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "discoverNetwork" -> {
                    executor.execute {
                        try {
                            // Scan the device's local /24 subnet for hosts accepting SMB (port 445).
                            val localIp = java.net.NetworkInterface.getNetworkInterfaces().toList()
                                .filter { it.isUp && !it.isLoopback }
                                .flatMap { it.inetAddresses.toList() }
                                .filterIsInstance<java.net.Inet4Address>()
                                .firstOrNull { it.isSiteLocalAddress }
                            val out = java.util.Collections.synchronizedList(ArrayList<Map<String, String>>())
                            if (localIp != null) {
                                val prefix = localIp.hostAddress!!.substringBeforeLast('.')
                                val pool = java.util.concurrent.Executors.newFixedThreadPool(32)
                                for (i in 1..254) {
                                    val ip = "$prefix.$i"
                                    if (ip == localIp.hostAddress) continue
                                    pool.execute {
                                        try {
                                            java.net.Socket().use { s ->
                                                s.connect(java.net.InetSocketAddress(ip, 445), 400)
                                            }
                                            out.add(mapOf("name" to ip, "ip" to ip))
                                        } catch (_: Exception) {}
                                    }
                                }
                                pool.shutdown()
                                pool.awaitTermination(15, java.util.concurrent.TimeUnit.SECONDS)
                            }
                            result.success(out.sortedBy { it["ip"]!!.substringAfterLast('.').toInt() })
                        } catch (e: Exception) {
                            Log.e("SMB_PLUGIN", "Network discovery error", e)
                            result.error("DISCOVERY_ERROR", e.message, null)
                        }
                    }
                }

                "listShares" -> {
                    executor.execute {
                        var connection: Connection? = null
                        var session: Session? = null
                        var ip: String = ""
                        try {
                            ip = call.argument<String>("ip") ?: run {
                                result.error("MISSING_IP", "IP address is required", null)
                                return@execute
                            }

                            val (conn, sess) = try {
                                getOrCreateConnection(ip)
                            } catch (e: Exception) {
                                Log.e("SMB_PLUGIN", "Failed to connect to $ip", e)
                                result.error("CONNECTION_ERROR", e.message, null)
                                return@execute
                            }
                            connection = conn
                            session = sess

                            val shareNames = mutableListOf<String>()
                            val sharesToTest = listOf("Documentos", "Users", "Public", "Downloads", "Fotos")

                            for (name in sharesToTest) {
                                try {
                                    sess.connectShare(name).close()
                                    shareNames.add(name)
                                } catch (_: Exception) { }
                            }

                            if (shareNames.isEmpty()) shareNames.add("Documentos")
                            result.success(shareNames)

                        } catch (e: Exception) {
                            Log.e("SMB_PLUGIN", "Error listing shares", e)
                            result.error("LIST_SHARES_ERROR", e.message ?: "Falha ao listar compartilhamentos", null)
                        } finally {
                            try { session?.close() } catch (_: Exception) { }
                        }
                    }
                }

                "listDirectory" -> {
                    executor.execute {
                        var ip: String = ""
                        var shareName: String = ""
                        var path: String = ""

                        try {
                            ip = call.argument<String>("ip")!!
                            shareName = call.argument<String>("share")!!
                            path = call.argument<String>("path") ?: ""

                            val maxRetries = 2
                            var attempt = 0
                            var lastError: Exception? = null

                            val resultList = mutableListOf<Map<String, Any>>()
                            while (attempt < maxRetries) {
                                attempt++
                                try {
                                    withFreshShare(ip, shareName) { share ->
                                        val realPath = when {
                                            path.isBlank() || path == "/" -> "\\"
                                            else -> {
                                                var p = path.replace("/", "\\")
                                                if (!p.startsWith("\\")) p = "\\$p"
                                                if (p.endsWith("\\")) p else p + "\\"
                                            }
                                        }

                                        val files = share.list(realPath)

                                        for (f in files) {
                                            val isDir = (f.fileAttributes and FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value) != 0L
                                            if (f.fileName == "." || f.fileName == "..") continue
                                            val fileName = f.fileName.lowercase()
                                            val isMedia = fileName.endsWith(".jpg") || fileName.endsWith(".jpeg") || fileName.endsWith(".png") || fileName.endsWith(".gif") || fileName.endsWith(".bmp") || fileName.endsWith(".mp4") || fileName.endsWith(".avi") || fileName.endsWith(".mkv") || fileName.endsWith(".mov") || fileName.endsWith(".3gp") || fileName.endsWith(".webm") || fileName.endsWith(".flv")

                                            resultList.add(
                                                mapOf(
                                                    "name" to f.fileName,
                                                    "is_dir" to isDir,
                                                    "is_media" to (isMedia && !isDir),
                                                    "path" to (realPath + f.fileName + if (isDir) "\\" else ""),
                                                    "size" to f.endOfFile,
                                                    "modified" to fileTimeToMillis(f.lastWriteTime)
                                                )
                                            )
                                        }
                                    }

                                    result.success(resultList)
                                    lastError = null
                                    break
                                } catch (e: Exception) {
                                    lastError = e
                                    Log.e("SMB_PLUGIN", "Error listing directory (attempt $attempt/$maxRetries)", e)
                                    if (attempt < maxRetries) {
                                        retryCounter.incrementAndGet()
                                        val backoff = 100L * (1 shl (attempt - 1)) + java.util.Random().nextInt(200)
                                        Thread.sleep(backoff)
                                        continue
                                    } else {
                                        result.error("LIST_DIR_ERROR", e.message, null)
                                    }
                                }
                            }

                            if (lastError != null) {
                                // already reported
                            }

                        } catch (e: Exception) {
                            Log.e("SMB_PLUGIN", "Error listing directory", e)
                            val ipArg = call.argument<String>("ip")
                            result.error("LIST_DIR_ERROR", e.message, null)
                        }
                    }
                }

                "fetchFile" -> {
                    executor.execute {
                        var smbFile: com.hierynomus.smbj.share.File? = null
                        var ip: String = ""
                        var shareName: String = ""
                        var path: String = ""

                        ip = call.argument<String>("ip")!!
                        shareName = call.argument<String>("share")!!
                        path = call.argument<String>("path")!!
                        val requestId = call.argument<String>("requestId")
                        fun checkCancelled() {
                            if (requestId != null && cancelledFetches.contains(requestId)) throw FetchCancelledException()
                        }

                        val maxRetries = 2
                        var attempt = 0
                        var lastError: Exception? = null

                        try {
                            fetchSemaphore.acquire()
                            checkCancelled()

                            while (attempt < maxRetries) {
                                attempt++
                                try {
                                    withFreshShare(ip, shareName) { share ->
                                        var smPath = path.replace("/", "\\")
                                        if (!smPath.startsWith("\\")) smPath = "\\$smPath"

                                        smbFile = share.openFile(
                                            smPath,
                                            java.util.EnumSet.of(AccessMask.GENERIC_READ),
                                            java.util.EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL),
                                            java.util.EnumSet.of(SMB2ShareAccess.FILE_SHARE_READ),
                                            SMB2CreateDisposition.FILE_OPEN,
                                            java.util.EnumSet.noneOf(SMB2CreateOptions::class.java)
                                        )

                                        val reader = smbFile!!
                                        val fileName = path.replace("\\", "/").substringAfterLast("/")
                                        val localFile = File(cacheDir, "temp_${UUID.randomUUID()}_${fileName}")
                                        val size = reader.fileInformation.standardInformation.endOfFile

                                        try {
                                            // Several 1 MB reads in flight: one sequential stream was
                                            // latency-bound (~0.9 MB/s where the link gave 2.3 MB/s).
                                            val chunk = 1 shl 20
                                            val pending = ArrayDeque<java.util.concurrent.Future<ByteArray>>()
                                            var next = 0L
                                            fun submitNext() {
                                                val off = next
                                                val len = minOf(chunk.toLong(), size - off).toInt()
                                                next += len
                                                pending.addLast(fetchReadPool.submit<ByteArray> {
                                                    val buf = ByteArray(len)
                                                    var got = 0
                                                    while (got < len) {
                                                        val n = reader.read(buf, off + got, got, len - got)
                                                        if (n <= 0) throw java.io.EOFException("short read at ${off + got}")
                                                        got += n
                                                    }
                                                    buf
                                                })
                                            }
                                            FileOutputStream(localFile).use { output ->
                                                try {
                                                    while (next < size && pending.size < fetchReadWindow) submitNext()
                                                    while (pending.isNotEmpty()) {
                                                        checkCancelled()
                                                        val bytes = try {
                                                            pending.removeFirst().get(120, TimeUnit.SECONDS)
                                                        } catch (e: java.util.concurrent.ExecutionException) {
                                                            throw (e.cause as? Exception) ?: e
                                                        }
                                                        output.write(bytes)
                                                        if (next < size) submitNext()
                                                    }
                                                } finally {
                                                    pending.forEach { it.cancel(true) }
                                                }
                                            }
                                        } catch (e: Exception) {
                                            localFile.delete()
                                            throw e
                                        }

                                        result.success(localFile.absolutePath)
                                    }
                                    lastError = null
                                    break
                                } catch (e: FetchCancelledException) {
                                    throw e
                                } catch (e: com.hierynomus.mssmb2.SMBApiException) {
                                    lastError = e
                                    Log.e("SMB_PLUGIN", "SMBApiException fetching '$path' from share '$shareName' (attempt $attempt/$maxRetries)", e)
                                    if (attempt < maxRetries) {
                                        retryCounter.incrementAndGet()
                                        val backoff = 200L * (1 shl (attempt - 1)) + java.util.Random().nextInt(200)
                                        Thread.sleep(backoff)
                                        continue
                                    } else throw e
                                } catch (e: Exception) {
                                    lastError = e
                                    Log.e("SMB_PLUGIN", "Error fetching file '$path' from share '$shareName' (attempt $attempt/$maxRetries)", e)
                                    if (attempt < maxRetries) {
                                        retryCounter.incrementAndGet()
                                        val backoff = 200L * (1 shl (attempt - 1)) + java.util.Random().nextInt(200)
                                        Thread.sleep(backoff)
                                        continue
                                    } else throw e
                                } finally {
                                    try { smbFile?.close() } catch (_: Exception) { }
                                    smbFile = null
                                }
                            }

                            if (lastError != null) result.error("FETCH_FILE_ERROR", lastError.message, null)

                        } catch (e: FetchCancelledException) {
                            Log.d("SMB_PLUGIN", "fetchFile cancelled: $path")
                            result.error("FETCH_CANCELLED", "cancelled", null)
                        } catch (e: Exception) {
                            Log.e("SMB_PLUGIN", "Error fetching file", e)
                            result.error("FETCH_FILE_ERROR", e.message, null)
                        } finally {
                            try { fetchSemaphore.release() } catch (_: Exception) { }
                            if (requestId != null) cancelledFetches.remove(requestId)
                        }
                    }
                }

                "generateThumbnail" -> {
                    executor.execute {
                        try {
                            val localPath = call.argument<String>("localPath")!!
                            val file = File(localPath)
                            val fileName = file.name.lowercase()

                            var durationSeconds: Double? = null

                            val thumbnail = when {
                                fileName.endsWith(".mp4") || fileName.endsWith(".avi") || fileName.endsWith(".mkv") || fileName.endsWith(".mov") || fileName.endsWith(".3gp") || fileName.endsWith(".webm") || fileName.endsWith(".flv") -> {
                                    val retriever = MediaMetadataRetriever()
                                    retriever.setDataSource(localPath)
                                    val thumb = retriever.getFrameAtTime(1000000)
                                    val durStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                                    durationSeconds = durStr?.toDoubleOrNull()?.div(1000.0)
                                    retriever.release()
                                    thumb
                                }
                                fileName.endsWith(".gif") -> android.graphics.BitmapFactory.decodeFile(localPath)
                                fileName.endsWith(".jpg") || fileName.endsWith(".jpeg") || fileName.endsWith(".png") || fileName.endsWith(".bmp") -> android.graphics.BitmapFactory.decodeFile(localPath)
                                else -> null
                            }

                            if (thumbnail != null) {
                                val thumbFile = File(cacheDir, "thumb_" + file.nameWithoutExtension + ".jpg")
                                val stream = FileOutputStream(thumbFile)
                                thumbnail.compress(Bitmap.CompressFormat.JPEG, 80, stream)
                                stream.close()
                                val map = HashMap<String, Any?>()
                                map["thumbPath"] = thumbFile.absolutePath
                                map["duration"] = durationSeconds
                                result.success(map)
                            } else result.success(null)

                        } catch (e: Exception) {
                            Log.e("SMB_PLUGIN", "Error generating thumbnail", e)
                            result.error("THUMB_ERROR", e.message, null)
                        }
                    }
                }

                "getVideoDuration" -> {
                    metadataExecutor.execute {
                        val retriever = MediaMetadataRetriever()
                        try {
                            val localPath = call.argument<String>("localPath")!!
                            if (localPath.startsWith("http://127.0.0.1:")) {
                                retriever.setDataSource(localPath, emptyMap<String, String>())
                            } else {
                                retriever.setDataSource(localPath)
                            }
                            val durStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                            val durMs = durStr?.toLongOrNull() ?: 0L
                            result.success(durMs.toDouble() / 1000.0)
                        } catch (e: Exception) {
                            Log.e("SMB_PLUGIN", "Error getting video duration", e)
                            result.error("DURATION_ERROR", e.message, null)
                        } finally {
                            retriever.release()
                        }
                    }
                }

                "getSmbFileInfo" -> {
                    executor.execute {
                        var smbFile: com.hierynomus.smbj.share.File? = null
                        var ip: String = ""
                        var shareName: String = ""

                        val maxRetries = 2
                        var attempt = 0
                        var lastError: Exception? = null

                        while (attempt < maxRetries) {
                            attempt++
                            try {
                                ip = call.argument<String>("ip")!!
                                shareName = call.argument<String>("share")!!
                                val path = call.argument<String>("path")!!

                                withFreshShare(ip, shareName) { share ->
                                    var smPath = path.replace("/", "\\")
                                    if (!smPath.startsWith("\\")) smPath = "\\" + smPath

                                    smbFile = share.openFile(
                                        smPath,
                                        java.util.EnumSet.of(AccessMask.GENERIC_READ),
                                        java.util.EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL),
                                        java.util.EnumSet.of(SMB2ShareAccess.FILE_SHARE_READ),
                                        SMB2CreateDisposition.FILE_OPEN,
                                        java.util.EnumSet.noneOf(SMB2CreateOptions::class.java)
                                    )

                                    val size = smbFile!!.fileInformation.standardInformation.endOfFile
                                    val out = HashMap<String, Any>()
                                    out["size"] = size
                                    result.success(out)
                                }
                                lastError = null
                                break
                            } catch (e: Exception) {
                                lastError = e
                                Log.e("SMB_PLUGIN", "Error getting SMB file info (attempt $attempt/$maxRetries)", e)
                                if (attempt < maxRetries) {
                                    retryCounter.incrementAndGet()
                                    val backoff = 150L * (1 shl (attempt - 1)) + java.util.Random().nextInt(200)
                                    Thread.sleep(backoff)
                                    continue
                                } else {
                                    result.error("SMB_FILE_INFO_ERROR", e.message, null)
                                }
                            } finally {
                                try { smbFile?.close() } catch (_: Exception) { }
                                smbFile = null
                            }
                        }

                        if (lastError != null) {
                            // already returned error above
                        }
                    }
                }

                "readSmbFileChunk" -> {
                    val lane = if (call.argument<Boolean>("playback") == true) playbackExecutor else streamExecutor
                    lane.execute {
                        var ip: String = ""
                        var shareName: String = ""

                        val maxRetries = 2
                        var attempt = 0
                        var lastError: Exception? = null

                        try {
                            ip = call.argument<String>("ip")!!
                            shareName = call.argument<String>("share")!!
                            val path = call.argument<String>("path")!!
                            val offset = (call.argument<Number>("offset") ?: 0).toLong()
                            val length = (call.argument<Number>("length") ?: 0).toInt().coerceAtLeast(0)

                            while (attempt < maxRetries) {
                                attempt++
                                try {
                                    withFreshShare(ip, shareName) { share ->
                                        var smPath = path.replace("/", "\\")
                                        if (!smPath.startsWith("\\")) smPath = "\\" + smPath

                                        val open = openForChunks(ip, shareName, share, smPath)
                                        val reader = open.file
                                        val fileSize = open.size
                                        val safeOffset = offset.coerceIn(0, fileSize)
                                        val maxReadable = (fileSize - safeOffset).coerceAtLeast(0)
                                        val bytesToRead = length.toLong().coerceAtMost(maxReadable).toInt()

                                        if (bytesToRead <= 0) {
                                            val emptyOut = HashMap<String, Any>()
                                            emptyOut["offset"] = safeOffset
                                            emptyOut["bytesRead"] = 0
                                            emptyOut["fileSize"] = fileSize
                                            emptyOut["bytes"] = ByteArray(0)
                                            result.success(emptyOut)
                                            return@withFreshShare
                                        }

                                        val buffer = ByteArray(bytesToRead)
                                        var totalRead = 0
                                        while (totalRead < bytesToRead) {
                                            val read = reader.read(
                                                buffer,
                                                safeOffset + totalRead,
                                                totalRead,
                                                bytesToRead - totalRead
                                            )
                                            if (read <= 0) break
                                            totalRead += read
                                        }

                                        val chunkBytes = if (totalRead == buffer.size) buffer else buffer.copyOfRange(0, totalRead)
                                        val out = HashMap<String, Any>()
                                        out["offset"] = safeOffset
                                        out["bytesRead"] = chunkBytes.size
                                        out["fileSize"] = fileSize
                                        out["bytes"] = chunkBytes
                                        result.success(out)
                                    }
                                    lastError = null
                                    break
                                } catch (e: Exception) {
                                    lastError = e
                                    // Reopen on retry: the cached handle may be stale.
                                    dropChunkHandle(ip, shareName, path)
                                    Log.e("SMB_PLUGIN", "Error reading SMB chunk '$path' (attempt $attempt/$maxRetries)", e)
                                    if (attempt < maxRetries) {
                                        retryCounter.incrementAndGet()
                                        val backoff = 50L * (1 shl (attempt - 1)) + java.util.Random().nextInt(200)
                                        Thread.sleep(backoff)
                                        continue
                                    } else {
                                        result.error("SMB_CHUNK_ERROR", e.message, null)
                                    }
                                }
                            }

                            if (lastError != null) {
                                // already reported
                            }

                        } catch (e: Exception) {
                            Log.e("SMB_PLUGIN", "Error reading SMB chunk", e)
                            result.error("SMB_CHUNK_ERROR", e.message, null)
                        }
                    }
                }
                "copyFile" -> {
                    executor.execute {
                        try {
                            val ip        = call.argument<String>("ip")!!
                            val shareName = call.argument<String>("share")!!
                            val srcPath   = call.argument<String>("srcPath")!!
                            val dstPath   = call.argument<String>("dstPath")!!
                            smbCopyFile(ip, shareName, srcPath, dstPath, deleteSrc = false)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e("SMB_PLUGIN", "copyFile error", e)
                            result.error("COPY_ERROR", e.message, null)
                        }
                    }
                }

                "moveFile" -> {
                    executor.execute {
                        try {
                            val ip        = call.argument<String>("ip")!!
                            val shareName = call.argument<String>("share")!!
                            val srcPath   = call.argument<String>("srcPath")!!
                            val dstPath   = call.argument<String>("dstPath")!!
                            smbCopyFile(ip, shareName, srcPath, dstPath, deleteSrc = true)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e("SMB_PLUGIN", "moveFile error", e)
                            result.error("MOVE_ERROR", e.message, null)
                        }
                    }
                }

                "cancelFetch" -> {
                    // Handled inline: the fetch it targets may be occupying the executor.
                    call.argument<String>("requestId")?.let { cancelledFetches.add(it) }
                    result.success(true)
                }

                "smbImageThumbnail" -> {
                    thumbExecutor.execute {
                        try {
                            val ip        = call.argument<String>("ip")!!
                            val shareName = call.argument<String>("share")!!
                            val path      = call.argument<String>("path")!!
                            val outPath   = call.argument<String>("outPath")!!
                            val maxSize   = call.argument<Int>("maxSize") ?: 320
                            // Spooled to disk: decoding from a byte array kept whole files
                            // (up to ~90 MB GIF/PNG here) on the heap, twice in parallel.
                            val source = File(cacheDir, "temp_thumbsrc_${UUID.randomUUID()}")
                            try {
                                withFreshShare(ip, shareName) { share ->
                                    var p = path.replace("/", "\\")
                                    if (!p.startsWith("\\")) p = "\\$p"
                                    share.openFile(
                                        p,
                                        java.util.EnumSet.of(AccessMask.GENERIC_READ),
                                        java.util.EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL),
                                        java.util.EnumSet.of(SMB2ShareAccess.FILE_SHARE_READ),
                                        SMB2CreateDisposition.FILE_OPEN,
                                        java.util.EnumSet.noneOf(SMB2CreateOptions::class.java)
                                    ).use { f ->
                                        f.inputStream.use { ins -> FileOutputStream(source).use { ins.copyTo(it, 262144) } }
                                    }
                                }
                                result.success(if (writeImageThumbnail(source, outPath, maxSize)) outPath else null)
                            } finally {
                                source.delete()
                            }
                        } catch (e: Exception) {
                            Log.e("SMB_PLUGIN", "smbImageThumbnail error", e)
                            result.error("THUMB_ERROR", e.message, null)
                        }
                    }
                }

                "uploadFile" -> {
                    uploadExecutor.execute {
                        try {
                            val ip        = call.argument<String>("ip")!!
                            val shareName = call.argument<String>("share")!!
                            val path      = call.argument<String>("path")!!
                            val local     = File(call.argument<String>("localPath")!!)
                            // Our cached streaming handle would block replacing the file.
                            dropChunkHandle(ip, shareName, path)
                            withFreshShare(ip, shareName) { share ->
                                var dst = path.replace("/", "\\")
                                if (!dst.startsWith("\\")) dst = "\\$dst"
                                // Write next to the target and swap at the end, so an
                                // interrupted upload never truncates the original.
                                val tmp = "$dst.smbui-upload"
                                try {
                                    share.openFile(
                                        tmp,
                                        java.util.EnumSet.of(AccessMask.GENERIC_WRITE),
                                        java.util.EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL),
                                        java.util.EnumSet.noneOf(SMB2ShareAccess::class.java),
                                        SMB2CreateDisposition.FILE_OVERWRITE_IF,
                                        java.util.EnumSet.noneOf(SMB2CreateOptions::class.java)
                                    ).use { f ->
                                        // Synchronous 1 MB writes: SMBJ's async OutputStream
                                        // queued large parallel writes that timed out on
                                        // slower uplinks and left a 0-byte file.
                                        val buf = ByteArray(1 shl 20)
                                        var filePos = 0L
                                        local.inputStream().use { ins ->
                                            while (true) {
                                                val n = ins.read(buf)
                                                if (n <= 0) break
                                                var off = 0
                                                while (off < n) {
                                                    val w = f.write(buf, filePos + off, off, n - off).toInt()
                                                    if (w <= 0) throw java.io.IOException("SMB write returned $w")
                                                    off += w
                                                }
                                                filePos += n
                                            }
                                        }
                                    }
                                    // SMB2 rename targets are share-relative without a leading '\'.
                                    share.openFile(
                                        tmp,
                                        java.util.EnumSet.of(AccessMask.DELETE, AccessMask.GENERIC_READ),
                                        java.util.EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL),
                                        java.util.EnumSet.of(SMB2ShareAccess.FILE_SHARE_READ),
                                        SMB2CreateDisposition.FILE_OPEN,
                                        java.util.EnumSet.noneOf(SMB2CreateOptions::class.java)
                                    ).use { it.rename(dst.trimStart('\\'), true) }
                                } catch (e: Exception) {
                                    try { share.rm(tmp) } catch (_: Exception) { }
                                    throw e
                                }
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e("SMB_PLUGIN", "uploadFile error", e)
                            result.error("UPLOAD_ERROR", e.message, null)
                        }
                    }
                }

                "deleteFile" -> {
                    executor.execute {
                        try {
                            val ip        = call.argument<String>("ip")!!
                            val shareName = call.argument<String>("share")!!
                            val path      = call.argument<String>("path")!!
                            withFreshShare(ip, shareName) { share ->
                                var p = path.replace("/", "\\")
                                if (!p.startsWith("\\")) p = "\\$p"
                                if (p.length > 1 && p.endsWith("\\")) {
                                    share.rmdir(p.trimEnd('\\'), true)
                                } else {
                                    share.rm(p)
                                }
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e("SMB_PLUGIN", "deleteFile error", e)
                            result.error("DELETE_ERROR", e.message, null)
                        }
                    }
                }

                "getSmbDiagnostics" -> {
                    executor.execute {
                        try {
                            val out = HashMap<String, Any>()
                            out["invalidations"] = invalidationCounter.get()
                            out["retries"] = retryCounter.get()
                            out["connectionsCreated"] = connectionCreationCounter.get()
                            result.success(out)
                        } catch (e: Exception) {
                            result.error("DIAG_ERROR", e.message, null)
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * Decodes [source] subsampled so the shorter side is about [maxSize] px (the grid crops
     * with BoxFit.cover), applies EXIF rotation and writes a JPEG to [outPath].
     */
    private fun writeImageThumbnail(source: File, outPath: String, maxSize: Int): Boolean {
        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        android.graphics.BitmapFactory.decodeFile(source.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return false
        var sample = 1
        while (minOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSize) sample *= 2
        val decoded = android.graphics.BitmapFactory.decodeFile(
            source.path,
            android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }
        ) ?: return false

        val shortest = minOf(decoded.width, decoded.height)
        var bitmap = if (shortest > maxSize) {
            val scale = maxSize.toFloat() / shortest
            Bitmap.createScaledBitmap(
                decoded,
                (decoded.width * scale).toInt().coerceAtLeast(1),
                (decoded.height * scale).toInt().coerceAtLeast(1),
                true
            ).also { if (it !== decoded) decoded.recycle() }
        } else decoded

        if (android.os.Build.VERSION.SDK_INT >= 24) {
            val rotation = try {
                when (android.media.ExifInterface(source.path).getAttributeInt(
                    android.media.ExifInterface.TAG_ORIENTATION, android.media.ExifInterface.ORIENTATION_NORMAL
                )) {
                    android.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                    android.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                    android.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                    else -> 0f
                }
            } catch (_: Exception) { 0f }
            if (rotation != 0f) {
                val m = android.graphics.Matrix().apply { postRotate(rotation) }
                val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
                if (rotated !== bitmap) bitmap.recycle()
                bitmap = rotated
            }
        }

        val tmp = File("$outPath.tmp")
        FileOutputStream(tmp).use { bitmap.compress(Bitmap.CompressFormat.JPEG, 82, it) }
        bitmap.recycle()
        return tmp.renameTo(File(outPath))
    }

    private fun smbCopyFile(
        ip: String, shareName: String,
        srcPath: String, dstPath: String,
        deleteSrc: Boolean
    ) {
        var srcFile: com.hierynomus.smbj.share.File? = null
        var dstFile: com.hierynomus.smbj.share.File? = null

        try {
            withFreshShare(ip, shareName) { share ->
                fun norm(p: String): String {
                    var s = p.replace("/", "\\")
                    if (!s.startsWith("\\")) s = "\\$s"
                    return s
                }

                val src = norm(srcPath)
                val dst = norm(dstPath)

                val dstParent = dst.substringBeforeLast("\\")
                if (dstParent.isNotEmpty() && dstParent != "\\") {
                    try { share.mkdir(dstParent) } catch (_: Exception) { }
                }

                srcFile = share.openFile(
                    src,
                    java.util.EnumSet.of(AccessMask.GENERIC_READ),
                    java.util.EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL),
                    java.util.EnumSet.of(SMB2ShareAccess.FILE_SHARE_READ),
                    SMB2CreateDisposition.FILE_OPEN,
                    java.util.EnumSet.noneOf(SMB2CreateOptions::class.java)
                )

                dstFile = share.openFile(
                    dst,
                    java.util.EnumSet.of(AccessMask.GENERIC_WRITE),
                    java.util.EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL),
                    java.util.EnumSet.of(SMB2ShareAccess.FILE_SHARE_WRITE),
                    SMB2CreateDisposition.FILE_OVERWRITE_IF,
                    java.util.EnumSet.noneOf(SMB2CreateOptions::class.java)
                )

                srcFile!!.inputStream.use { ins ->
                    dstFile!!.outputStream.use { out ->
                        val buf = ByteArray(65536)
                        var n = ins.read(buf)
                        while (n > 0) {
                            out.write(buf, 0, n)
                            n = ins.read(buf)
                        }
                    }
                }

                srcFile = null
                dstFile = null

                if (deleteSrc) share.rm(src)
            }

        } finally {
            try { srcFile?.close() } catch (_: Exception) { }
            try { dstFile?.close() } catch (_: Exception) { }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        metadataExecutor.shutdownNow()
        thumbExecutor.shutdownNow()
        fetchReadPool.shutdownNow()
        playbackExecutor.shutdownNow()
        synchronized(chunkHandles) {
            chunkHandles.values.forEach { try { it.file.close() } catch (_: Exception) { } }
            chunkHandles.clear()
        }
        synchronized(chunkHandles) {
            chunkHandles.values.forEach { try { it.file.close() } catch (_: Exception) { } }
            chunkHandles.clear()
        }
        try {
            smbClient.close()
        } catch (e: Exception) {
            Log.e("SMB_PLUGIN", "Error closing SMB client", e)
        }
    }
}
