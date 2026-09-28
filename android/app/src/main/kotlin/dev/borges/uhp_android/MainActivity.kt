package dev.borges.uhp_android

import android.content.ActivityNotFoundException
import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class MainActivity : FlutterActivity() {
    companion object {
        private const val PICK_ATTACHMENTS = 48231
        private const val MAX_ATTACHMENT_BYTES = 25L * 1024 * 1024
        // Shared workers outlive an Activity long enough to close streams and remove partial copies.
        private val fileWorkers = Executors.newCachedThreadPool()
    }

    private class AttachmentPick(val result: MethodChannel.Result) {
        val canceled = AtomicBoolean(false)
        val signal = CancellationSignal()
        val input = AtomicReference<InputStream?>(null)
        var copying = false
    }

    private var attachmentPick: AttachmentPick? = null
    private var sessionFilesChannel: MethodChannel? = null
    private var filesDestroyed = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.borges.uhp_android/updater",
        ).setMethodCallHandler { call, result ->
            if (call.method == "installApk") {
                installApk(call, result)
            } else {
                result.notImplemented()
            }
        }
        sessionFilesChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.borges.uhp_android/session_files",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickAttachments" -> pickAttachments(result)
                    "openFile" -> launchSessionFile(call, result, false)
                    "shareFile" -> launchSessionFile(call, result, true)
                    "shareText" -> shareSessionText(call, result)
                    "discardAttachments" -> discardAttachments(call, result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun pickAttachments(result: MethodChannel.Result) {
        if (filesDestroyed) {
            result.error("activity_destroyed", "The file picker is no longer available.", null)
            return
        }
        if (attachmentPick != null) {
            result.error("picker_busy", "An attachment selection is already in progress.", null)
            return
        }
        val pick = AttachmentPick(result)
        attachmentPick = pick
        try {
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }, PICK_ATTACHMENTS)
        } catch (error: Exception) {
            attachmentPick = null
            result.error("picker_unavailable", "Could not open the attachment picker.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_ATTACHMENTS) return
        val pick = attachmentPick ?: return
        if (pick.copying) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            attachmentPick = null
            pick.result.success(emptyList<Any>())
            return
        }
        val uris = LinkedHashSet<Uri>()
        data.clipData?.let { clips ->
            for (index in 0 until clips.itemCount) uris.add(clips.getItemAt(index).uri)
        }
        data.data?.let { uris.add(it) }
        if (uris.isEmpty()) {
            attachmentPick = null
            pick.result.success(emptyList<Any>())
            return
        }
        pick.copying = true
        fileWorkers.execute {
            val batch = File(File(cacheDir, "attachments"), UUID.randomUUID().toString())
            try {
                val files = uris.map { uri -> copyAttachment(uri, batch, pick) }
                pick.signal.throwIfCanceled()
                runOnUiThread {
                    if (attachmentPick === pick && !filesDestroyed && !pick.canceled.get()) {
                        attachmentPick = null
                        pick.result.success(files)
                    } else {
                        fileWorkers.execute { batch.deleteRecursively() }
                    }
                }
            } catch (error: Exception) {
                batch.deleteRecursively()
                runOnUiThread {
                    if (attachmentPick === pick) {
                        attachmentPick = null
                        pick.result.error(
                            "attachment_copy_failed",
                            error.message ?: "Could not copy the selected attachments.",
                            null,
                        )
                    }
                }
            }
        }
    }

    private fun copyAttachment(uri: Uri, batch: File, pick: AttachmentPick): Map<String, Any?> {
        require(uri.scheme == "content") { "The selected attachment is not a document." }
        pick.signal.throwIfCanceled()
        var displayName: String? = null
        var declaredSize: Long? = null
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null, null, null, pick.signal,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameColumn >= 0 && !cursor.isNull(nameColumn)) {
                    displayName = cursor.getString(nameColumn)
                }
                if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) {
                    declaredSize = cursor.getLong(sizeColumn)
                }
            }
        }
        require((declaredSize ?: -1L) <= MAX_ATTACHMENT_BYTES) {
            "Each attachment must be 25 MiB or smaller."
        }
        val name = safeAttachmentName(displayName)
        val mediaType = contentResolver.getType(uri)
        val folder = File(batch, UUID.randomUUID().toString())
        check(folder.mkdirs()) { "Could not create the attachment cache." }
        val destination = File(folder, name)
        var size = 0L
        val descriptor = contentResolver.openAssetFileDescriptor(uri, "r", pick.signal)
            ?: error("The selected attachment could not be opened.")
        descriptor.use {
            val input = descriptor.createInputStream()
            pick.input.set(input)
            try {
                input.use { source ->
                    destination.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            pick.signal.throwIfCanceled()
                            if (pick.canceled.get()) error("Attachment selection was canceled.")
                            val count = source.read(buffer)
                            if (count < 0) break
                            if (count == 0) continue
                            size += count
                            require(size <= MAX_ATTACHMENT_BYTES) {
                                "Each attachment must be 25 MiB or smaller."
                            }
                            output.write(buffer, 0, count)
                        }
                    }
                }
            } finally {
                pick.input.compareAndSet(input, null)
            }
        }
        return mapOf("path" to destination.absolutePath, "name" to name,
            "size" to size, "mediaType" to mediaType)
    }

    private fun safeAttachmentName(value: String?): String {
        val name = buildString {
            for (character in value ?: "attachment") {
                append(if (character.isISOControl() || character in "/\\:*?\"<>|") '_' else character)
            }
        }.trim().take(180).trimEnd('.')
        return if (name.isBlank() || name == "." || name == "..") "attachment" else name
    }

    private fun cachedFile(path: String, directory: String): File {
        val root = File(cacheDir.canonicalFile, directory)
        require(root.canonicalFile == root) { "The private cache directory must not be a symbolic link." }
        val file = File(path).canonicalFile
        require(file.path.startsWith(root.path + File.separator)) {
            "The file is outside the private $directory cache."
        }
        return file
    }

    private fun launchSessionFile(call: MethodCall, result: MethodChannel.Result, share: Boolean) {
        try {
            val path = call.argument<String>("path")
            require(!path.isNullOrBlank()) { "A cached file path is required." }
            val file = cachedFile(path, "session-files")
            require(file.isFile) { "The downloaded file no longer exists." }
            val mime = call.argument<String>("mediaType")?.takeIf { it.isNotBlank() }
                ?: "application/octet-stream"
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(if (share) Intent.ACTION_SEND else Intent.ACTION_VIEW).apply {
                if (share) {
                    type = mime
                    putExtra(Intent.EXTRA_STREAM, uri)
                } else {
                    setDataAndType(uri, mime)
                }
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newRawUri(file.name, uri)
            }
            if (share) {
                startActivity(Intent.createChooser(intent, "Share file").apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    clipData = intent.clipData
                })
                result.success(null)
            } else {
                startActivity(intent)
                result.success(true)
            }
        } catch (error: ActivityNotFoundException) {
            if (share) result.error("share_unavailable", "No app can share this file.", null)
            else result.success(false)
        } catch (error: Exception) {
            result.error("file_action_failed", error.message ?: "Could not open this file.", null)
        }
    }

    private fun shareSessionText(call: MethodCall, result: MethodChannel.Result) {
        try {
            val text = call.argument<String>("text")
            require(!text.isNullOrBlank()) { "Text to share is required." }
            startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
            }, "Share link"))
            result.success(null)
        } catch (error: Exception) {
            result.error("share_failed", error.message ?: "Could not share this text.", null)
        }
    }

    private fun discardAttachments(call: MethodCall, result: MethodChannel.Result) {
        val paths = (call.arguments as? Map<*, *>)?.get("paths") as? List<*>
        if (paths == null || paths.any { it !is String }) {
            result.error("invalid_arguments", "Attachment paths are required.", null)
            return
        }
        fileWorkers.execute {
            try {
                val root = File(cacheDir.canonicalFile, "attachments").canonicalFile
                val files = paths.map { cachedFile(it as String, "attachments") }
                require(files.none { it.isDirectory }) { "Only attachment files can be discarded." }
                for (file in files) {
                    check(!file.exists() || file.delete()) { "Could not discard an attachment." }
                    var parent = file.parentFile
                    while (parent != null && parent != root && parent.delete()) {
                        parent = parent.parentFile
                    }
                }
                runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("discard_failed", error.message ?: "Could not discard attachments.", null)
                }
            }
        }
    }

    override fun onDestroy() {
        filesDestroyed = true
        sessionFilesChannel?.setMethodCallHandler(null)
        sessionFilesChannel = null
        val pick = attachmentPick
        attachmentPick = null
        if (pick != null) {
            pick.canceled.set(true)
            pick.result.error("activity_destroyed", "Attachment selection was interrupted.", null)
            fileWorkers.execute {
                try {
                    pick.signal.cancel()
                } finally {
                    try { pick.input.getAndSet(null)?.close() } catch (_: Exception) { }
                }
            }
        }
        super.onDestroy()
    }

    private fun installApk(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val path = arguments?.get("path") as? String
        val requestPermission = arguments?.get("requestPermission") as? Boolean
        if (path.isNullOrBlank() || requestPermission == null) {
            result.error(
                "invalid_arguments",
                "An APK path and a requestPermission boolean are required.",
                null,
            )
            return
        }

        try {
            val updatesDirectory = File(cacheDir.canonicalFile, "updates")
            val apk = File(path).canonicalFile
            if (!apk.path.startsWith(updatesDirectory.path + File.separator) ||
                !apk.isFile || apk.length() == 0L ||
                !apk.extension.equals("apk", ignoreCase = true)
            ) {
                result.error(
                    "invalid_apk",
                    "The update must be a nonempty APK inside the app's updates cache.",
                    null,
                )
                return
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                if (requestPermission) {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                }
                result.success("permissionRequired")
                return
            }

            val apkUri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(apkUri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newRawUri("App update", apkUri)
            }
            startActivity(intent)
            result.success("launched")
        } catch (error: ActivityNotFoundException) {
            result.error(
                "installer_unavailable",
                "Android could not open the install-permission settings or APK installer.",
                null,
            )
        } catch (error: SecurityException) {
            result.error(
                "installation_denied",
                "Android denied access to the update installer: ${error.message ?: "permission denied"}",
                null,
            )
        } catch (error: Exception) {
            result.error(
                "installation_failed",
                "Could not prepare the update installation: ${error.message ?: error.javaClass.simpleName}",
                null,
            )
        }
    }
}
