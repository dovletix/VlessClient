package io.github.dovletix.vlessclient

import android.content.Context
import android.util.Log
import java.io.File
import kotlin.concurrent.thread

/**
 * The bundled Xray (jniLibs/<abi>/libxray.so, the official Android build of Xray-core) for the nodes sing-box
 * cannot carry: XHTTP, VLESS encryption. It runs as a child process with files/xray.json, which the app writes
 * (one local SOCKS port per node). Being a separate process it cannot protect its sockets from the VPN, so its
 * config dials the servers through sing-box's "xray-in" inbound, which sends them out directly.
 */
object XrayProcess {
    private const val TAG = "VlessClient"
    private var proc: Process? = null
    @Volatile private var wanted = false
    private var watchdog: Thread? = null
    private var restarts = 0

    fun binary(ctx: Context) = File(ctx.applicationInfo.nativeLibraryDir, "libxray.so")

    fun available(ctx: Context) = binary(ctx).exists()

    fun configFile(ctx: Context) = File(ctx.filesDir, "xray.json")

    private fun alive(p: Process?): Boolean {
        if (p == null) return false
        return try {
            p.exitValue()
            false
        } catch (_: IllegalThreadStateException) {
            true
        }
    }

    /** (Re)starts Xray with files/xray.json; stops it when there is no such file (no node needs Xray). */
    @Synchronized
    fun start(ctx: Context) {
        stop()
        val cfg = configFile(ctx)
        if (!cfg.exists() || cfg.length() == 0L) return
        if (!available(ctx)) error("в этой сборке нет Xray, серверы XHTTP недоступны")
        killStale()
        wanted = true
        restarts = 0
        launch(ctx)
        watchdog = thread(name = "xray-watchdog", isDaemon = true) {
            while (wanted) {
                try {
                    Thread.sleep(3000)
                } catch (_: InterruptedException) {
                    return@thread
                }
                synchronized(this) {
                    if (wanted && !alive(proc) && restarts < 20) {
                        restarts++
                        Log.w(TAG, "xray exited, restarting ($restarts)")
                        launch(ctx)
                    }
                }
            }
        }
    }

    private fun launch(ctx: Context) {
        val pb = ProcessBuilder(binary(ctx).path, "run", "-c", configFile(ctx).path)
            .directory(ctx.filesDir)
            .redirectErrorStream(true)
        pb.environment()["XRAY_LOCATION_ASSET"] = ctx.filesDir.path
        val p = pb.start()
        proc = p
        // Xray logs to the file named in its config; drain the console so that it never blocks on a full pipe
        thread(name = "xray-output", isDaemon = true) {
            try {
                p.inputStream.use { s ->
                    val buf = ByteArray(4096)
                    while (s.read(buf) >= 0) { /* discard */ }
                }
            } catch (_: Exception) {
            }
        }
    }

    @Synchronized
    fun stop() {
        wanted = false
        watchdog?.interrupt()
        watchdog = null
        val p = proc ?: return
        proc = null
        // Android's Process.destroy() is SIGKILL; wait a moment so that the ports are free for the next start
        p.destroy()
        repeat(20) {
            if (!alive(p)) return
            Thread.sleep(100)
        }
    }

    /** An Xray left over from a crashed service would hold the ports. */
    private fun killStale() {
        try {
            val k = Runtime.getRuntime().exec(arrayOf("pkill", "-f", "libxray.so"))
            repeat(20) {
                if (!alive(k)) return
                Thread.sleep(50)
            }
        } catch (_: Exception) {
        }
    }
}
