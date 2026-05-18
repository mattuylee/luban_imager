package com.example.luban_imager

import android.app.Activity
import android.content.ClipData
import android.content.ContentValues
import android.content.Intent
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import top.zibin.luban.api.Luban
import top.zibin.luban.api.OnCompressListener

class MainActivity : FlutterActivity() {
    private val channelName = "luban_imager/native_images"
    private val pickImagesRequest = 4101

    private var channel: MethodChannel? = null
    private var pendingPickResult: MethodChannel.Result? = null
    private val pendingSharedImages = mutableListOf<Map<String, Any>>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickImages" -> pickImages(result)
                "takeSharedImages" -> takeSharedImages(result)
                "compressImage" -> compressImage(call.arguments, result)
                "overwriteOriginal" -> overwriteOriginal(call.arguments, result)
                "saveToGallery" -> saveToGallery(call.arguments, result)
                "shareImage" -> shareImage(call.arguments, result)
                else -> result.notImplemented()
            }
        }
        consumeSharedIntent(intent, notifyFlutter = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeSharedIntent(intent, notifyFlutter = true)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            pickImagesRequest -> finishPickImages(resultCode, data)
        }
    }

    private fun pickImages(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("busy", "正在选择图片", null)
            return
        }

        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }

        try {
            startActivityForResult(intent, pickImagesRequest)
        } catch (error: Exception) {
            pendingPickResult = null
            result.error("picker_unavailable", error.message, null)
        }
    }

    private fun finishPickImages(resultCode: Int, data: Intent?) {
        val result = pendingPickResult ?: return
        pendingPickResult = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Map<String, Any>>())
            return
        }

        val flags = data.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        val payload = mutableListOf<Map<String, Any>>()

        try {
            val uri = extractUri(data)
            if (uri != null) {
                try {
                    if (flags != 0) {
                        contentResolver.takePersistableUriPermission(uri, flags)
                    }
                } catch (_: SecurityException) {
                    // Some providers grant temporary access only.
                }
                payload.add(buildPickedImage(uri))
            }
            result.success(payload)
        } catch (error: Exception) {
            result.error("pick_failed", error.message, null)
        }
    }

    private fun extractUri(data: Intent): Uri? {
        return data.data ?: data.clipData?.getItemAt(0)?.uri
    }

    private fun takeSharedImages(result: MethodChannel.Result) {
        val images = pendingSharedImages.toList()
        pendingSharedImages.clear()
        result.success(images)
    }

    private fun consumeSharedIntent(intent: Intent?, notifyFlutter: Boolean) {
        val uris = extractSharedUris(intent)
        if (uris.isEmpty()) {
            return
        }

        val payload = uris.mapNotNull { uri ->
            try {
                buildSharedImage(uri)
            } catch (_: Exception) {
                null
            }
        }
        if (payload.isEmpty()) {
            return
        }

        pendingSharedImages.clear()
        pendingSharedImages.addAll(payload)
        if (notifyFlutter) {
            channel?.invokeMethod("sharedImages", payload)
        }
    }

    @Suppress("DEPRECATION")
    private fun extractSharedUris(intent: Intent?): List<Uri> {
        if (intent == null || intent.type?.startsWith("image/") != true) {
            return emptyList()
        }

        return when (intent.action) {
            Intent.ACTION_SEND -> {
                val stream = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                listOfNotNull(stream ?: intent.data)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.toList()
                    ?: emptyList()
            }
            else -> emptyList()
        }
    }

    private fun buildSharedImage(uri: Uri): Map<String, Any> {
        val displayName = queryDisplayName(uri) ?: "image"
        val previewFile = copyUriToCache(uri, displayName, "shared-originals")
        val dimensions = readDimensionsFromFile(previewFile)
        val originalSize = previewFile.length()

        return mapOf(
            "sourceHandle" to Uri.fromFile(previewFile).toString(),
            "displayName" to displayName,
            "previewPath" to previewFile.absolutePath,
            "originalSize" to originalSize,
            "width" to dimensions.first,
            "height" to dimensions.second,
            "canOverwrite" to false,
        )
    }

    private fun buildPickedImage(uri: Uri): Map<String, Any> {
        val displayName = queryDisplayName(uri) ?: "image"
        val previewFile = copyUriToCache(uri, displayName, "originals")
        val dimensions = readDimensionsFromUri(uri).takeIf { it.first > 0 && it.second > 0 }
            ?: readDimensionsFromFile(previewFile)
        val originalSize = querySize(uri).takeIf { it > 0 } ?: previewFile.length()

        return mapOf(
            "sourceHandle" to uri.toString(),
            "displayName" to displayName,
            "previewPath" to previewFile.absolutePath,
            "originalSize" to originalSize,
            "width" to dimensions.first,
            "height" to dimensions.second,
            "canOverwrite" to canOverwrite(uri),
        )
    }

    private fun compressImage(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *>
        val source = args?.get("sourceHandle") as? String
        val previewPath = args?.get("previewPath") as? String
        val originalSize = (args?.get("originalSize") as? Number)?.toLong() ?: -1L
        val originalWidth = (args?.get("originalWidth") as? Number)?.toInt() ?: 0
        val originalHeight = (args?.get("originalHeight") as? Number)?.toInt() ?: 0
        if (source.isNullOrBlank()) {
            result.error("bad_args", "缺少 sourceHandle", null)
            return
        }

        val outputDir = File(cacheDir, "compressed").apply { mkdirs() }
        val uri = Uri.parse(source)

        try {
            Luban.with(this)
                .load(uri)
                .setTargetDir(outputDir)
                .setCompressListener(object : OnCompressListener {
                    override fun onStart() = Unit

                    override fun onSuccess(file: File) {
                        val previewFile = previewPath?.let { File(it) }
                        val shouldUseOriginal = originalSize > 0 &&
                            file.length() >= originalSize &&
                            previewFile?.exists() == true
                        val outputFile = if (shouldUseOriginal) previewFile!! else file
                        val dimensions = if (shouldUseOriginal &&
                            originalWidth > 0 &&
                            originalHeight > 0
                        ) {
                            Pair(originalWidth, originalHeight)
                        } else {
                            readDimensionsFromFile(outputFile)
                        }
                        val outputSize = if (shouldUseOriginal && originalSize > 0) {
                            originalSize
                        } else {
                            outputFile.length()
                        }
                        runOnUiThread {
                            result.success(
                                mapOf(
                                    "path" to outputFile.absolutePath,
                                    "outputSize" to outputSize,
                                    "width" to dimensions.first,
                                    "height" to dimensions.second,
                                    "passthrough" to shouldUseOriginal,
                                ),
                            )
                        }
                    }

                    override fun onError(e: Throwable) {
                        runOnUiThread {
                            result.error("compress_failed", e.message, null)
                        }
                    }
                })
                .launch()
        } catch (error: Exception) {
            result.error("compress_failed", error.message, null)
        }
    }

    private fun overwriteOriginal(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *>
        val source = args?.get("sourceHandle") as? String
        val compressedPath = args?.get("compressedPath") as? String
        if (source.isNullOrBlank() || compressedPath.isNullOrBlank()) {
            result.error("bad_args", "缺少覆盖参数", null)
            return
        }

        try {
            copyFileToUri(File(compressedPath), Uri.parse(source))
            result.success(mapOf("overwritten" to true, "target" to source))
        } catch (error: Exception) {
            result.error("overwrite_failed", error.message, null)
        }
    }

    private fun shareImage(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *>
        val compressedPath = args?.get("compressedPath") as? String
        val suggestedName = args?.get("suggestedName") as? String ?: "luban-image.jpg"
        if (compressedPath.isNullOrBlank()) {
            result.error("bad_args", "缺少 compressedPath", null)
            return
        }

        try {
            val shareFile = makeShareCopy(File(compressedPath), suggestedName)
            val shareUri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                shareFile,
            )
            val shareIntent = Intent(Intent.ACTION_SEND).apply {
                type = mimeTypeForName(shareFile.name)
                putExtra(Intent.EXTRA_STREAM, shareUri)
                clipData = ClipData.newUri(contentResolver, shareFile.name, shareUri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(shareIntent, getString(R.string.share_image_title)))
            result.success(mapOf("shared" to true))
        } catch (error: Exception) {
            result.error("share_failed", error.message, null)
        }
    }

    private fun saveToGallery(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *>
        val compressedPath = args?.get("compressedPath") as? String
        val suggestedName = args?.get("suggestedName") as? String ?: "luban-image.jpg"
        if (compressedPath.isNullOrBlank()) {
            result.error("bad_args", "缺少 compressedPath", null)
            return
        }

        try {
            val savedUri = writeImageToGallery(File(compressedPath), suggestedName)
            result.success(mapOf("savedTo" to savedUri.toString()))
        } catch (error: Exception) {
            result.error("save_failed", error.message, null)
        }
    }

    private fun copyUriToCache(uri: Uri, displayName: String, child: String): File {
        val dir = File(cacheDir, child).apply { mkdirs() }
        val safeName = sanitizeFileName(displayName)
        val target = File(dir, "${UUID.randomUUID()}-$safeName")
        contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "无法读取图片" }
            FileOutputStream(target).use { output -> input.copyTo(output) }
        }
        return target
    }

    private fun writeImageToGallery(source: File, suggestedName: String): Uri {
        require(source.exists()) { "压缩文件不存在" }
        val safeName = sanitizeFileName(suggestedName)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            writeImageToMediaStore(source, safeName)
        } else {
            writeImageToPublicPictures(source, safeName)
        }
    }

    private fun writeImageToMediaStore(source: File, safeName: String): Uri {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, safeName)
            put(MediaStore.Images.Media.MIME_TYPE, mimeTypeForName(safeName))
            put(
                MediaStore.Images.Media.RELATIVE_PATH,
                "${Environment.DIRECTORY_PICTURES}/Luban Imager",
            )
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val collection = MediaStore.Images.Media.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY,
        )
        val uri = requireNotNull(contentResolver.insert(collection, values)) {
            "无法创建相册图片"
        }

        try {
            copyFileToUri(source, uri)
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri
        } catch (error: Exception) {
            contentResolver.delete(uri, null, null)
            throw error
        }
    }

    @Suppress("DEPRECATION")
    private fun writeImageToPublicPictures(source: File, safeName: String): Uri {
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
            "Luban Imager",
        ).apply { mkdirs() }
        val target = uniqueFile(dir, safeName)
        source.inputStream().use { input ->
            FileOutputStream(target).use { output -> input.copyTo(output) }
        }
        MediaScannerConnection.scanFile(
            this,
            arrayOf(target.absolutePath),
            arrayOf(mimeTypeForName(target.name)),
            null,
        )
        return Uri.fromFile(target)
    }

    private fun uniqueFile(dir: File, name: String): File {
        val dot = name.lastIndexOf('.')
        val baseName = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        var index = 0
        var candidate = File(dir, name)

        while (candidate.exists()) {
            index += 1
            candidate = File(dir, "${baseName}_$index$extension")
        }
        return candidate
    }

    private fun makeShareCopy(source: File, suggestedName: String): File {
        require(source.exists()) { "压缩文件不存在" }
        val dir = File(cacheDir, "shared").apply { mkdirs() }
        val target = File(dir, sanitizeFileName(suggestedName))
        if (target.exists()) {
            target.delete()
        }
        source.inputStream().use { input ->
            FileOutputStream(target).use { output -> input.copyTo(output) }
        }
        return target
    }

    private fun copyFileToUri(source: File, targetUri: Uri) {
        require(source.exists()) { "压缩文件不存在" }
        source.inputStream().use { input ->
            if (targetUri.scheme == "file") {
                val path = requireNotNull(targetUri.path) { "目标路径无效" }
                FileOutputStream(File(path)).use { output -> input.copyTo(output) }
            } else {
                contentResolver.openOutputStream(targetUri, "wt").use { output ->
                    requireNotNull(output) { "无法写入目标文件" }
                    input.copyTo(output)
                }
            }
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) {
                        return cursor.getString(index)
                    }
                }
            }
        return uri.lastPathSegment
    }

    private fun querySize(uri: Uri): Long {
        contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (index >= 0) {
                        return cursor.getLong(index)
                    }
                }
            }
        return -1L
    }

    private fun readDimensionsFromUri(uri: Uri): Pair<Int, Int> {
        return try {
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            contentResolver.openInputStream(uri).use { input ->
                BitmapFactory.decodeStream(input, null, options)
            }
            Pair(options.outWidth.coerceAtLeast(0), options.outHeight.coerceAtLeast(0))
        } catch (_: Exception) {
            Pair(0, 0)
        }
    }

    private fun readDimensionsFromFile(file: File): Pair<Int, Int> {
        return try {
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, options)
            Pair(options.outWidth.coerceAtLeast(0), options.outHeight.coerceAtLeast(0))
        } catch (_: Exception) {
            Pair(0, 0)
        }
    }

    private fun canOverwrite(uri: Uri): Boolean {
        return try {
            if (uri.scheme == "file") {
                val path = uri.path ?: return false
                return File(path).canWrite()
            }
            contentResolver.openFileDescriptor(uri, "rw")?.use { true } ?: false
        } catch (_: Exception) {
            false
        }
    }

    private fun sanitizeFileName(name: String): String {
        val safe = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
        return safe.ifBlank { "image.jpg" }
    }

    private fun mimeTypeForName(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "image/jpeg"
    }
}
