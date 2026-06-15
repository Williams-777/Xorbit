package com.williams.xorbit

import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val MEDIA_CHANNEL = "com.williams.xorbit/media_scanner"
    private val SHARE_CHANNEL = "com.williams.xorbit/share"

    // Stored share intent data — populated when app is opened via share sheet
    private var sharedData: Map<String, Any?>? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        parseShareIntent(intent)
    }

    private fun parseShareIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        val type   = intent.type  ?: return

        when {
            // Single file shared
            action == Intent.ACTION_SEND && !type.startsWith("text/") -> {
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (uri != null) {
                    val path = getRealPath(uri)
                    if (path != null) {
                        sharedData = mapOf("type" to "files", "paths" to listOf(path))
                    }
                }
            }
            // Multiple files shared
            action == Intent.ACTION_SEND_MULTIPLE -> {
                val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                if (uris != null) {
                    val paths = uris.mapNotNull { getRealPath(it) }
                    if (paths.isNotEmpty()) {
                        sharedData = mapOf("type" to "files", "paths" to paths)
                    }
                }
            }
            // Text shared
            action == Intent.ACTION_SEND && type.startsWith("text/") -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: ""
                if (text.isNotEmpty()) {
                    sharedData = mapOf("type" to "text", "text" to text)
                }
            }
        }
    }

    // Convert content:// URI to actual file path
    private fun getRealPath(uri: Uri): String? {
        return try {
            // For file:// URIs
            if (uri.scheme == "file") return uri.path

            // For content:// URIs — copy to cache and return cache path
            val inputStream = contentResolver.openInputStream(uri) ?: return null
            val fileName    = getFileName(uri) ?: "shared_file"
            val cacheFile   = java.io.File(cacheDir, fileName)
            cacheFile.outputStream().use { output ->
                inputStream.copyTo(output)
            }
            inputStream.close()
            cacheFile.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    private fun getFileName(uri: Uri): String? {
        var name: String? = null
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) name = cursor.getString(idx)
            }
        }
        return name ?: uri.lastPathSegment
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Parse any share intent that launched the app
        parseShareIntent(intent)

        // ── MediaStore channel ──────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "scanFile") {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        MediaScannerConnection.scanFile(
                            applicationContext, arrayOf(path), null
                        ) { _, uri -> result.success(uri?.toString()) }
                    } else {
                        result.error("INVALID_PATH", "Path is null", null)
                    }
                } else result.notImplemented()
            }

        // ── Share channel ───────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getSharedData") {
                    result.success(sharedData)
                    sharedData = null // consume once
                } else result.notImplemented()
            }
    }
}