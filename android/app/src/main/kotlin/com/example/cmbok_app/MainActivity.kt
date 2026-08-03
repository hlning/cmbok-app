package com.example.cmbok_app

import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channel = "cmbok/platform"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openDir" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(openDirectory(path))
                    }
                    "openFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        val mime = call.argument<String>("mimeType") ?: "*/*"
                        result.success(openFile(path, mime))
                    }
                    "getApkPath" -> result.success(getApkPath())
                    else -> result.notImplemented()
                }
            }
    }

    /** 打开目录：ACTION_VIEW + vnd.android.document/directory（FileProvider 授权） */
    private fun openDirectory(path: String): Boolean {
        return try {
            val dir = File(path)
            if (!dir.exists()) return false
            val uri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", dir)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "vnd.android.document/directory")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 取本应用 APK 路径（applicationInfo.sourceDir） */
    private fun getApkPath(): String? {
        return try {
            packageManager.getPackageInfo(packageName, 0).applicationInfo?.sourceDir
        } catch (e: Exception) {
            null
        }
    }

    /** 用外部应用打开文件：ACTION_VIEW + FileProvider 授权（按 mimeType 选阅读器）。
     *  无可用应用抛 ActivityNotFoundException -> 返回 false（Dart 侧 toast 提示）。 */
    private fun openFile(path: String, mimeType: String): Boolean {
        return try {
            val file = File(path)
            if (!file.exists()) return false
            val uri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, if (mimeType.isEmpty()) "*/*" else mimeType)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
