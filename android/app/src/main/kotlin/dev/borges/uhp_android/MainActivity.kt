package dev.borges.uhp_android

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
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
