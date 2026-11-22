package com.mankafe.app

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/**
 * 「保存到相册」的原生实现。
 *
 * Flutter 侧（`lib/services/album_saver.dart`）只管把整页图的字节和文件名丢过来，
 * 这里负责真正落进系统相册：
 *
 * - **Android 10（Q）及以上**：走 `MediaStore` 写 `Pictures/Mankafe`，用
 *   `IS_PENDING` 标记「正在写」，写完再置 0 —— 相册索引不会看到半张图；不需要任何
 *   存储权限，也不用 `requestLegacyExternalStorage`。
 * - **Android 9 及以下**：`MediaStore` 的 `RELATIVE_PATH` 还不存在，写到公共
 *   `Pictures/Mankafe` 再触发 `MediaScannerConnection` 扫描，图片才会出现在相册里。
 *   这条路径需要 `WRITE_EXTERNAL_STORAGE`，清单里带 `maxSdkVersion=28`，
 *   运行时在这里申请（用户拒绝时回 `permission_denied`，Flutter 侧给可读文案）。
 *
 * 文件名去重交给系统：Q+ 上同名文件由 MediaStore 自动改成 `名字 (1).jpg`；
 * 9 及以下由 [writeToPictures] 自己加序号，绝不覆盖用户相册里已有的图片。
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "mankafe/album"
        const val ALBUM = "Mankafe"
        const val WRITE_REQUEST = 4101
        const val TAG = "AlbumSaver"
    }

    /** 等权限回调期间暂存的这次保存请求（同一时刻只允许一个）。 */
    private var pendingBytes: ByteArray? = null
    private var pendingName: String = "manga.jpg"
    private var pendingMime: String = "image/jpeg"
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImage" -> saveImage(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun saveImage(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        val name = call.argument<String>("name") ?: "manga.jpg"
        val mime = call.argument<String>("mime") ?: "image/jpeg"

        if (bytes == null || bytes.isEmpty()) {
            result.error("save_failed", "图片数据为空", null)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                result.success(insertIntoMediaStore(bytes, name, mime))
            } catch (error: Exception) {
                Log.w(TAG, "MediaStore 写入失败", error)
                result.error("save_failed", error.message ?: "保存失败", null)
            }
            return
        }

        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            if (pendingResult != null) {
                result.error("save_failed", "上一次保存还在等待权限", null)
                return
            }
            pendingBytes = bytes
            pendingName = name
            pendingMime = mime
            pendingResult = result
            requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                WRITE_REQUEST,
            )
            return
        }

        try {
            result.success(writeToPictures(bytes, name, mime))
        } catch (error: Exception) {
            Log.w(TAG, "Pictures 写入失败", error)
            result.error("save_failed", error.message ?: "保存失败", null)
        }
    }

    /** Android 10+：直接插 `MediaStore`，图片立刻出现在系统相册的「Mankafe」相册里。 */
    private fun insertIntoMediaStore(bytes: ByteArray, name: String, mime: String): String {
        val relative = Environment.DIRECTORY_PICTURES + File.separator + ALBUM
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, mime)
            put(MediaStore.Images.Media.RELATIVE_PATH, relative)
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val resolver = contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("MediaStore 拒绝写入 $relative")
        try {
            val stream = resolver.openOutputStream(uri)
                ?: throw IOException("无法打开相册文件流")
            stream.use { it.write(bytes) }
            val done = ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }
            resolver.update(uri, done, null, null)
        } catch (error: Exception) {
            // 写失败要删掉这条空记录，否则相册里会留一张 0 字节的坏图。
            runCatching { resolver.delete(uri, null, null) }
            throw error
        }
        return "$relative${File.separator}$name"
    }

    /** Android 9 及以下：写公共 Pictures 目录 + 媒体扫描。 */
    private fun writeToPictures(bytes: ByteArray, name: String, mime: String): String {
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
            ALBUM,
        )
        if (!dir.exists() && !dir.mkdirs()) {
            throw IOException("无法创建相册目录 ${dir.absolutePath}")
        }
        val dot = name.lastIndexOf('.')
        val stem = if (dot < 0) name else name.substring(0, dot)
        val extension = if (dot < 0) "" else name.substring(dot)
        var file = File(dir, name)
        var index = 1
        while (file.exists()) {
            file = File(dir, "$stem ($index)$extension")
            index++
        }
        file.writeBytes(bytes)
        MediaScannerConnection.scanFile(
            applicationContext,
            arrayOf(file.absolutePath),
            arrayOf(mime),
            null,
        )
        return file.absolutePath
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != WRITE_REQUEST) return

        val result = pendingResult ?: return
        val bytes = pendingBytes
        val name = pendingName
        val mime = pendingMime
        pendingResult = null
        pendingBytes = null

        if (bytes != null &&
            grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            try {
                result.success(writeToPictures(bytes, name, mime))
            } catch (error: Exception) {
                Log.w(TAG, "Pictures 写入失败（授权后）", error)
                result.error("save_failed", error.message ?: "保存失败", null)
            }
        } else {
            result.error("permission_denied", "没有存储写入权限", null)
        }
    }
}
