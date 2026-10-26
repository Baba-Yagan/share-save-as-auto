package com.example.share_save

import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream

/**
 * Bridge between the Dart UI and the SAF / share plumbing of the host activity.
 *
 * The app has no services and no background execution: everything happens on
 * the main thread of this activity, only while it is visible.
 * - Action `PROCESS_TEXT` gives the raw selection text.
 * - `ACTION_SEND`/`ACTION_SEND_MULTIPLE` gives text (EXTRA_TEXT) and/or
 *   one/more content streams (EXTRA_STREAM).
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val APP_CHANNEL = "share_save/app"
        const val RC_PICK_TREE = 42
        val SHARE_ACTIONS = setOf(
            Intent.ACTION_SEND,
            Intent.ACTION_SEND_MULTIPLE,
            Intent.ACTION_PROCESS_TEXT,
        )
        const val MAX_EXTENSION_LENGTH = 12 // characters after the dot
        const val COPY_BUFFER_SIZE = 32 * 1024
    }

    private var appChannel: MethodChannel? = null

    /** Share intent delivered before the Dart side was ready, or null. */
    private var pendingShare: Intent? = null

    /** Result callback of an in-flight SAF folder picker. */
    private var pendingPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        appChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_CHANNEL,
        ).apply {
            setMethodCallHandler { call, result -> handleMethodCall(call, result) }
        }
        // Cold start via a share: keep the payload until Dart asks for it.
        if (intent != null && intent.action in SHARE_ACTIONS) {
            pendingShare = intent
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // App already open (singleTask): forward the share to the running UI.
        if (intent.action !in SHARE_ACTIONS) return
        pendingShare = null
        appChannel?.invokeMethod("onShareIntent", extractShare(intent))
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getPendingShare" -> { // returns null when the channel missed no share
                val share = pendingShare
                pendingShare = null
                result.success(share?.let { extractShare(it) })
            }
            "getSaveDirStatus" -> result.success(dirStatus(call.argument<String>("treeUri")))
            "canWrite" -> result.success(canWrite(call.argument<String>("treeUri")))
            "pickTree" -> pickTree(result)
            "closeActivity" -> {
                result.success(null)
                finish() // return to the app that shared, right after saving
            }
            "saveText" -> saveText(
                call.argument<String>("treeUri"),
                call.argument<String>("baseName") ?: "",
                call.argument<String>("mime") ?: "text/plain",
                call.argument<String>("ext") ?: ".txt",
                call.argument<String>("text") ?: "",
                result,
            )
            "saveStream" -> saveStream(
                call.argument<String>("treeUri"),
                call.argument<String>("streamUri").orEmpty(),
                call.argument<String>("mime") ?: "*/*",
                call.argument<String>("baseName") ?: "",
                call.argument<Int>("baseIndex") ?: 0,
                result,
            )
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------
    // Folder picker (ACTION_OPEN_DOCUMENT_TREE)
    // ---------------------------------------------------------------------

    private fun pickTree(result: MethodChannel.Result) {
        val intent =
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        pendingPickResult = result
        try {
            @Suppress("DEPRECATION") // startActivityForResult(Intent, code)
            startActivityForResult(intent, RC_PICK_TREE)
        } catch (e: Exception) {
            pendingPickResult = null
            result.error("pickerUnavailable", e.message, null)
        }
    }

    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != RC_PICK_TREE) return
        val result = pendingPickResult
        pendingPickResult = null
        if (result == null) return // already answered
        val treeUri = data?.data
        if (treeUri == null) { // user cancelled
            result.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            result.success(treeUri.toString())
        } catch (e: SecurityException) {
            result.error("noWritePermission", e.message, null)
        }
    }

    // ---------------------------------------------------------------------
    // Directory status, write-grant queries
    // ---------------------------------------------------------------------

    private fun dirStatus(treeUri: String?): Map<String, Any?> =
        mapOf(
            "defaultDir" to defaultDir()?.absolutePath,
            "treePath" to prettyTreePath(treeUri),
        )

    /** "primary:Download/share-save" -> "Download/share-save" (null when no tree). */
    private fun prettyTreePath(uriStr: String?): String? {
        if (uriStr == null) return null
        return try {
            DocumentsContract.getTreeDocumentId(Uri.parse(uriStr))?.replace(':', '/')
        } catch (e: Exception) {
            uriStr
        }
    }

    private fun canWrite(treeUri: String?): Boolean {
        if (treeUri == null) {
            val dir = defaultDir() ?: return false
            return dir.canWrite()
        }
        return contentResolver.persistedUriPermissions.any {
            it.uri.toString() == treeUri && it.isWritePermission
        }
    }

    /** App-external files dir, created if needed; falls back to internal files dir. */
    private fun defaultDir(): File? {
        val dir = getExternalFilesDir(null) ?: filesDir
        if (!dir.isDirectory && !dir.mkdirs()) return null
        return dir
    }

    // ---------------------------------------------------------------------
    // Saving: text shares
    // ---------------------------------------------------------------------

    private fun saveText(
        treeUri: String?,
        baseName: String,
        mime: String,
        ext: String,
        text: String,
        result: MethodChannel.Result,
    ) {
        try {
            val content = text.toByteArray(Charsets.UTF_8)
            val fileName = baseName + ext
            val name = if (treeUri != null) {
                val target = DocumentsContract.createDocument(
                    contentResolver,
                    treeDocumentUri(treeUri),
                    mime,
                    fileName,
                ) ?: throw IllegalStateException("Provider refused to create the document")
                try {
                    val output = contentResolver.openOutputStream(target)
                        ?: throw IOException("Cannot write into the chosen directory")
                    output.use { it.write(content) }
                } catch (t: Throwable) {
                    runCatching { DocumentsContract.deleteDocument(contentResolver, target) }
                    throw t
                }
                fileName
            } else {
                val file = File(defaultDir() ?: throw IOException("No storage available"), fileName)
                FileOutputStream(file).use { it.write(content) }
                file.name
            }
            result.success(name)
        } catch (e: SecurityException) {
            result.error("noWritePermission", e.message, null)
        } catch (e: Exception) {
            result.error("saveFailed", e.message, null)
        }
    }

    // ---------------------------------------------------------------------
    // Saving: file/stream shares (EXTRA_STREAM), possibly several per share
    // ---------------------------------------------------------------------

    private fun saveStream(
        treeUri: String?,
        streamUriStr: String,
        mime: String,
        baseName: String,
        baseIndex: Int, // ordinal within one multi-stream share, used to avoid name collisions
        result: MethodChannel.Result,
    ) {
        try {
            val resolver = contentResolver
            val source = Uri.parse(streamUriStr)
            val detectedMime = mime.substringBefore(';').trim().ifBlank { "*/*" }
            val extension = extensionFor(source, detectedMime)
            val docMime = if (detectedMime == "*/*") "application/octet-stream" else detectedMime
            val name =
                baseName + (if (baseIndex == 0) "" else "-${baseIndex + 1}") + extension

            if (treeUri != null) {
                val created = DocumentsContract.createDocument(
                    resolver,
                    treeDocumentUri(treeUri),
                    docMime,
                    name,
                ) ?: throw IllegalStateException("Provider refused to create the document")
                try {
                    val input =
                        resolver.openInputStream(source) ?: throw IOException("Cannot open the shared file")
                    val output = resolver.openOutputStream(created)
                        ?: throw IOException("Cannot write into the chosen directory")
                    input.use { ins -> output.use { outs -> ins.copyTo(outs, COPY_BUFFER_SIZE) } }
                } catch (t: Throwable) {
                    runCatching { DocumentsContract.deleteDocument(resolver, created) }
                    throw t
                }
                result.success(name)
            } else {
                val dir = defaultDir() ?: throw IOException("No storage available")
                val file = File(dir, name)
                val input = resolver.openInputStream(source) ?: throw IOException("Cannot open the shared file")
                try {
                    input.use { ins -> FileOutputStream(file).use(ins::copyTo) }
                } catch (t: Throwable) {
                    runCatching { file.delete() }
                    throw t
                }
                result.success(file.name)
            }
        } catch (e: SecurityException) {
            result.error("noWritePermission", e.message, null)
        } catch (e: Exception) {
            result.error("saveFailed", e.message, null)
        }
    }

    private fun treeDocumentUri(uriStr: String): Uri {
        val tree = Uri.parse(uriStr)
        val documentId = DocumentsContract.getTreeDocumentId(tree)
        return DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
    }

    /** Extension decision: display name of the stream, else MIME map, else ".bin". */
    private fun extensionFor(source: Uri, mime: String): String {
        usableExtension(displayName(source))?.let { return it }
        return extensionForMime(mime) ?: ".bin"
    }

    private fun displayName(uri: Uri): String? =
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor: Cursor -> cursorDisplayName(cursor) }
        } catch (e: Exception) {
            null
        }

    private fun cursorDisplayName(cursor: Cursor): String? {
        val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        if (column < 0 || cursor.isNull(column)) return null
        return cursor.getString(column)
    }

    /** Example: "cat.jpg" -> ".jpg"; hidden files without a real extension -> null. */
    private fun usableExtension(name: String?): String? {
        if (name == null) return null
        val dot = name.lastIndexOf('.')
        if (dot <= 0 || dot >= name.length - 1) return null
        val ext = name.substring(dot).lowercase()
        if (ext.length > MAX_EXTENSION_LENGTH + 1) return null
        return ext.takeIf {
            ext.drop(1).all { c -> c.isLetterOrDigit() || c == '-' || c == '+' || c == '_' }
        }
    }

    /** Common MIME type -> file extension map; subtypes not listed here fall back to
     * {@link #genericExtension} or ".bin". */
    private val MIME_EXTENSIONS: Map<String, String> = mapOf(
        "image/jpeg" to ".jpg",
        "image/jpg" to ".jpg",
        "image/png" to ".png",
        "image/gif" to ".gif",
        "image/webp" to ".webp",
        "image/bmp" to ".bmp",
        "image/svg+xml" to ".svg",
        "image/heic" to ".heic",
        "image/heif" to ".heif",
        "application/pdf" to ".pdf",
        "application/zip" to ".zip",
        "application/gzip" to ".gz",
        "application/x-tar" to ".tar",
        "application/json" to ".json",
        "application/xml" to ".xml",
        "text/plain" to ".txt",
        "text/html" to ".html",
        "text/csv" to ".csv",
        "text/markdown" to ".md",
        "audio/mpeg" to ".mp3",
        "audio/mp3" to ".mp3",
        "audio/wav" to ".wav",
        "audio/wave" to ".wav",
        "audio/mp4" to ".m4a",
        "audio/m4a" to ".m4a",
        "audio/ogg" to ".ogg",
        "audio/flac" to ".flac",
        "audio/aac" to ".aac",
        "video/mp4" to ".mp4",
        "video/mpeg" to ".mpg",
        "video/quicktime" to ".mov",
        "video/x-msvideo" to ".avi",
        "video/x-matroska" to ".mkv",
        "video/webm" to ".webm",
        "application/vnd.android.package-archive" to ".apk",
    )

    private fun extensionForMime(mime: String): String? {
        val normalized = mime.substringBefore(';').trim().lowercase()
        MIME_EXTENSIONS[normalized]?.let { return it }
        // Generic wildcards cannot be mapped to a single extension.
        return if (normalized.endsWith("/*")) null else genericExtension(normalized)
    }

    /** Last-ditch based on the subtype for types like `foo/msword`… */
    private fun genericExtension(normalized: String): String? {
        val type = normalized.substringBefore('/')
        val subtype = normalized.substringAfter('/')
        return when (type) {
            "image" -> mapKnownImageSubtype(subtype)
            "video" -> mapKnownVideoSubtype(subtype)
            "audio" -> mapKnownAudioSubtype(subtype)
            else -> null
        }
    }

    private fun mapKnownImageSubtype(subtype: String): String? = when (subtype) {
        "jpeg", "jpg", "jpe", "pjpeg", "pipeg" -> ".jpg"
        else -> null
    }

    private fun mapKnownVideoSubtype(subtype: String): String? = when (subtype) {
        "mp4", "mp4v", "avc" -> ".mp4"
        else -> null
    }

    private fun mapKnownAudioSubtype(subtype: String): String? = when (subtype) {
        "mpeg", "mp3", "mp4a-latm", "mp4a" -> ".mp3"
        else -> null
    }

    // ---------------------------------------------------------------------
    // Share intent -> Dart payload
    // ---------------------------------------------------------------------

    @Suppress("DEPRECATION")
    private fun extractShare(intent: Intent): Map<String, Any?>? {
        val action = intent.action ?: return null

        val streams = ArrayList<HashMap<String, Any?>>()
        if (action != Intent.ACTION_PROCESS_TEXT) {
            val singleStream = @Suppress("DEPRECATION") intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (singleStream != null) {
                streams.add(streamItem(singleStream, intent.type))
            } else {
                @Suppress("DEPRECATION") val multipleStreams =
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                multipleStreams?.forEach { uri -> if (uri != null) streams.add(streamItem(uri, intent.type)) }
            }
        }

        if (streams.isNotEmpty()) {
            return mapOf("type" to "stream", "streams" to streams)
        }

        val text: String? = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?: intent.getCharSequenceArrayListExtra(Intent.EXTRA_TEXT)?.joinToString("\n") { it.toString() }
            ?: (if (action == Intent.ACTION_PROCESS_TEXT) {
                intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            } else {
                null
            })
        if (text.isNullOrEmpty()) {
            return null // share contained nothing we understand
        }

        return mapOf(
            "type" to "text",
            "text" to text,
            "title" to intent.getCharSequenceExtra(Intent.EXTRA_TITLE)?.toString(),
            "subject" to intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString(),
            "action" to action,
            "mime" to (intent.type ?: "*/*"),
            "sender" to senderReferrer(intent),
        )
    }

    /** Sending app, if available: package name derived from the referrer URI. */
    private fun senderReferrer(intent: Intent): String? {
        // Activity.getReferrer() mirrors Intent.EXTRA_REFERRER; try the extra,
        // then the activity-level referrer (API 22+; minSdk is above that).
        @Suppress("DEPRECATION")
        val referrerUri: Uri? =
            intent.getParcelableExtra<Uri>(Intent.EXTRA_REFERRER) ?: getReferrer()
        return when {
            referrerUri == null -> null
            referrerUri.scheme == "android-app" -> referrerUri.host
            else -> referrerUri.toString()
        }
    }

    private fun streamItem(uri: Uri, fallbackType: String?): HashMap<String, Any?> {
        val mime = try {
            contentResolver.getType(uri)?.trim().takeUnless { it.isNullOrEmpty() }
                ?: fallbackType?.trim().takeUnless { it.isNullOrEmpty() }
                ?: "*/*"
        } catch (e: Exception) {
            fallbackType ?: "*/*"
        }
        return hashMapOf("uri" to uri.toString(), "mime" to mime)
    }
}
