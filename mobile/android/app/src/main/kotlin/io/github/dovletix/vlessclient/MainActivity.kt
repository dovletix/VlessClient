package io.github.dovletix.vlessclient

import android.Manifest
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** The Flutter window and its channel to the tunnel service ("vlessclient/vpn"). */
class MainActivity : FlutterActivity() {
    companion object {
        private const val REQ_VPN = 1001
        private const val REQ_NOTIFY = 1002
    }

    private var pending: Pair<String, MethodChannel.Result>? = null
    private var link: String? = null
    private val io = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        takeIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        takeIntent(intent)
    }

    /** vlessclient://add/<subscription link or vless:// lines>, opened from a browser or a messenger. */
    private fun takeIntent(intent: Intent?) {
        val data = intent?.dataString ?: return
        if (intent.action == Intent.ACTION_VIEW && data.startsWith("vlessclient:", ignoreCase = true)) link = data
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vlessclient/vpn").setMethodCallHandler(::handle)
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val v = work()
                main.post { result.success(v) }
            } catch (e: Exception) {
                main.post { result.error("failed", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> result.success(
                mapOf(
                    "platform" to "android",
                    "dataDir" to filesDir.absolutePath,
                    "version" to BuildConfig.VERSION_NAME,
                    "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
                    "sdk" to Build.VERSION.SDK_INT,
                    "xray" to XrayProcess.available(this),
                ),
            )
            "start" -> {
                val config = call.argument<String>("config") ?: return result.error("args", "no config", null)
                writeXray(call.argument<String>("xray"))
                askNotifications()
                val consent = VpnService.prepare(this)
                if (consent != null) {
                    pending?.second?.error("denied", "superseded", null)
                    pending = config to result
                    try {
                        @Suppress("DEPRECATION")
                        startActivityForResult(consent, REQ_VPN)
                    } catch (e: Exception) {
                        pending = null
                        result.error("failed", e.message, null)
                    }
                } else {
                    startTunnel(config, result)
                }
            }
            "reload" -> {
                val config = call.argument<String>("config") ?: return result.error("args", "no config", null)
                writeXray(call.argument<String>("xray"))
                BoxVpnService.configFile(this).writeText(config)
                BoxVpnService.send(this, BoxVpnService.ACTION_RELOAD)
                result.success(null)
            }
            "stop" -> {
                BoxVpnService.send(this, BoxVpnService.ACTION_STOP)
                result.success(null)
            }
            "status" -> result.success(
                mapOf("running" to BoxVpnService.running, "starting" to BoxVpnService.starting, "error" to BoxVpnService.lastError),
            )
            "takeLink" -> {
                result.success(link)
                link = null
            }
            "apps" -> background(result) { installedApps() }
            "icon" -> background(result) { appIcon(call.argument<String>("package") ?: "") }
            "installApk" -> background(result) {
                installApk(call.argument<String>("path") ?: "", call.argument<String>("sha256") ?: "")
                null
            }
            "openUrl" -> {
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url"))))
                    result.success(null)
                } catch (e: Exception) {
                    result.error("failed", e.message, null)
                }
            }
            "share" -> {
                val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, call.argument<String>("text") ?: "")
                startActivity(Intent.createChooser(send, "Отчёт VlessClient"))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** files/xray.json for the bundled Xray; removed when no node needs it (the service then does not start Xray). */
    private fun writeXray(config: String?) {
        val f = XrayProcess.configFile(this)
        if (config.isNullOrEmpty()) f.delete() else f.writeText(config)
    }

    private fun startTunnel(config: String, result: MethodChannel.Result) {
        try {
            BoxVpnService.configFile(this).writeText(config)
            BoxVpnService.lastError = ""
            BoxVpnService.starting = true
            BoxVpnService.send(this, BoxVpnService.ACTION_START)
            result.success(null)
        } catch (e: Exception) {
            BoxVpnService.starting = false
            result.error("failed", e.message, null)
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_VPN) return
        val p = pending ?: return
        pending = null
        if (resultCode == RESULT_OK) startTunnel(p.first, p.second) else p.second.error("denied", "VPN permission denied", null)
    }

    private fun askNotifications() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
        }
    }

    // ------------------------------------------------------------------ apps

    private fun installedApps(): List<Map<String, Any>> {
        val pm = packageManager
        @Suppress("DEPRECATION")
        val list = pm.getInstalledPackages(PackageManager.GET_PERMISSIONS)
        return list.filter { it.packageName != packageName && it.requestedPermissions?.contains(Manifest.permission.INTERNET) == true }
            .mapNotNull { pi ->
                val ai = pi.applicationInfo ?: return@mapNotNull null
                mapOf(
                    "package" to pi.packageName,
                    "label" to ai.loadLabel(pm).toString(),
                    "system" to (ai.flags and ApplicationInfo.FLAG_SYSTEM != 0 && pm.getLaunchIntentForPackage(pi.packageName) == null),
                )
            }
    }

    private fun appIcon(pkg: String): ByteArray? {
        val d = try {
            packageManager.getApplicationIcon(pkg)
        } catch (_: PackageManager.NameNotFoundException) {
            return null
        }
        val size = 96
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, size, size)
        d.draw(Canvas(bmp))
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        bmp.recycle()
        return out.toByteArray()
    }

    // ------------------------------------------------------------------ updates

    private fun installApk(path: String, sha256: String) {
        val f = File(path)
        if (!f.exists()) error("файл обновления не найден")
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { s ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = s.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        val got = md.digest().joinToString("") { "%02x".format(it) }
        if (!got.equals(sha256, ignoreCase = true)) {
            f.delete()
            error("контрольная сумма не совпала, файл удалён")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            main.post {
                startActivity(Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            }
            error("Разрешите VlessClient устанавливать приложения и нажмите «Обновить» ещё раз")
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.files", f)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        main.post { startActivity(intent) }
    }
}
