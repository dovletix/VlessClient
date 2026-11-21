package io.github.dovletix.vlessclient

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.OsConstants
import android.util.Log
import io.nekohasekai.libbox.BridgeOptions
import io.nekohasekai.libbox.BridgeSession
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NeighborUpdateListener
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.PlatformUser
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.ShellSession
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.io.File
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.InterfaceAddress
import java.net.NetworkInterface
import java.util.concurrent.Executors
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface
import io.nekohasekai.libbox.Notification as LibboxNotification

/**
 * The tunnel: Android's VpnService around sing-box (libbox). The app writes the sing-box config to
 * files/config.json and sends START / RELOAD / STOP; everything else (statistics, node choice) goes
 * through sing-box's Clash API on 127.0.0.1. Modelled on sing-box for Android (SFA, GPL-3.0).
 */
class BoxVpnService : VpnService(), PlatformInterface, CommandServerHandler {
    companion object {
        private const val TAG = "VlessClient"
        const val ACTION_START = "io.github.dovletix.vlessclient.START"
        const val ACTION_RELOAD = "io.github.dovletix.vlessclient.RELOAD"
        const val ACTION_STOP = "io.github.dovletix.vlessclient.STOP"
        private const val CHANNEL = "vpn"
        private const val NOTIFICATION_ID = 1

        @Volatile var running = false
        @Volatile var starting = false
        @Volatile var lastError = ""
        private var setupDone = false

        fun configFile(ctx: Context) = File(ctx.filesDir, "config.json")

        fun send(ctx: Context, action: String) {
            val intent = Intent(ctx, BoxVpnService::class.java).setAction(action)
            if (action == ACTION_STOP) {
                if (running || starting) ctx.startService(intent)
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(intent) else ctx.startService(intent)
        }

        @Synchronized
        fun setup(ctx: Context) {
            if (setupDone) return
            val work = File(ctx.filesDir, "work").apply { mkdirs() }
            val options = SetupOptions().also {
                it.basePath = ctx.filesDir.path
                it.workingPath = work.path
                it.tempPath = ctx.cacheDir.path
                // https://github.com/golang/go/issues/68760
                it.fixAndroidStack = Build.VERSION.SDK_INT in Build.VERSION_CODES.N..Build.VERSION_CODES.N_MR1 ||
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                it.logMaxLines = 1000
                it.debug = false
                it.crashReportSource = "Application"
                it.appVersion = "1"
                it.appMarketingVersion = BuildConfig.VERSION_NAME
            }
            Libbox.setup(options)
            setupDone = true
        }
    }

    private val worker = Executors.newSingleThreadExecutor()
    private var server: CommandServer? = null
    private var tun: ParcelFileDescriptor? = null
    private val connectivity by lazy { getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> worker.execute { stopTunnel() }
            ACTION_RELOAD -> {
                foreground()
                worker.execute { reloadTunnel() }
            }
            else -> {
                // ACTION_START, or "android.net.VpnService" when Android starts an always-on VPN by itself
                foreground()
                worker.execute { startTunnel() }
            }
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        // another VPN app took over, or the user switched us off in the system settings
        worker.execute { stopTunnel() }
    }

    override fun onDestroy() {
        worker.execute { stopTunnel() }
        worker.shutdown()
        super.onDestroy()
    }

    private fun foreground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "VPN", NotificationManager.IMPORTANCE_LOW))
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT), flags)
        val stop = PendingIntent.getService(this, 1, Intent(this, BoxVpnService::class.java).setAction(ACTION_STOP), flags)
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val n = b.setContentTitle("VlessClient")
            .setContentText("VPN включён")
            .setSmallIcon(R.drawable.ic_vpn)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .addAction(@Suppress("DEPRECATION") Notification.Action.Builder(0, "Выключить", stop).build())
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun readConfig(): String {
        val f = configFile(this)
        if (!f.exists()) error("нет настроек туннеля — откройте приложение и нажмите кнопку")
        return f.readText()
    }

    private fun startTunnel() {
        if (running && server != null) {
            reloadTunnel()
            return
        }
        starting = true
        lastError = ""
        try {
            setup(this)
            DefaultNetworkMonitor.start(this)
            XrayProcess.start(this)
            val s = CommandServer(this, this)
            s.start()
            server = s
            s.startOrReloadService(readConfig(), OverrideOptions())
            running = true
        } catch (e: Exception) {
            Log.e(TAG, "start", e)
            lastError = e.message ?: e.toString()
            stopTunnel()
        } finally {
            starting = false
        }
    }

    private fun reloadTunnel() {
        val s = server
        if (s == null) {
            startTunnel()
            return
        }
        try {
            lastError = ""
            closeTun()
            XrayProcess.start(this)
            s.startOrReloadService(readConfig(), OverrideOptions())
            running = true
        } catch (e: Exception) {
            Log.e(TAG, "reload", e)
            lastError = e.message ?: e.toString()
            stopTunnel()
        }
    }

    private fun closeTun() {
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
    }

    private fun stopTunnel() {
        running = false
        val s = server
        server = null
        if (s != null) {
            try {
                s.closeService()
            } catch (e: Exception) {
                Log.w(TAG, "close service", e)
            }
            try {
                s.close()
            } catch (_: Exception) {
            }
        }
        closeTun()
        XrayProcess.stop()
        DefaultNetworkMonitor.stop()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // ------------------------------------------------------------------ CommandServerHandler

    override fun serviceStop() {
        worker.execute { stopTunnel() }
    }

    override fun serviceReload() {
        worker.execute { reloadTunnel() }
    }

    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()

    override fun setSystemProxyEnabled(isEnabled: Boolean) {}

    override fun triggerNativeCrash() {}

    override fun writeDebugMessage(message: String?) {
        Log.d(TAG, message ?: "")
    }

    override fun connectSSHAgent(): Int = -1

    // ------------------------------------------------------------------ PlatformInterface

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        // sing-box's own sockets (to the VLESS servers, direct traffic) must bypass the tunnel
        protect(fd)
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("нет разрешения на VPN")
        val builder = Builder().setSession("VlessClient").setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        val inet4 = options.inet4Address
        while (inet4.hasNext()) {
            val a = inet4.next()
            builder.addAddress(a.address(), a.prefix())
        }
        val inet6 = options.inet6Address
        while (inet6.hasNext()) {
            val a = inet6.next()
            builder.addAddress(a.address(), a.prefix())
        }

        if (options.autoRoute) {
            if (options.dnsMode.value != Libbox.DNSModeDisabled) {
                val dns = options.dnsServerAddress
                while (dns.hasNext()) builder.addDnsServer(dns.next())
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val r4 = options.inet4RouteAddress
                if (r4.hasNext()) {
                    while (r4.hasNext()) builder.addRoute(r4.next().toIpPrefix())
                } else if (options.inet4Address.hasNext()) {
                    builder.addRoute("0.0.0.0", 0)
                }
                val r6 = options.inet6RouteAddress
                if (r6.hasNext()) {
                    while (r6.hasNext()) builder.addRoute(r6.next().toIpPrefix())
                } else if (options.inet6Address.hasNext()) {
                    builder.addRoute("::", 0)
                }
                val e4 = options.inet4RouteExcludeAddress
                while (e4.hasNext()) builder.excludeRoute(e4.next().toIpPrefix())
                val e6 = options.inet6RouteExcludeAddress
                while (e6.hasNext()) builder.excludeRoute(e6.next().toIpPrefix())
            } else {
                val r4 = options.inet4RouteRange
                while (r4.hasNext()) {
                    val a = r4.next()
                    builder.addRoute(a.address(), a.prefix())
                }
                val r6 = options.inet6RouteRange
                while (r6.hasNext()) {
                    val a = r6.next()
                    builder.addRoute(a.address(), a.prefix())
                }
            }
            val include = options.includePackage
            while (include.hasNext()) {
                try {
                    builder.addAllowedApplication(include.next())
                } catch (_: PackageManager.NameNotFoundException) {
                }
            }
            val exclude = options.excludePackage
            while (exclude.hasNext()) {
                try {
                    builder.addDisallowedApplication(exclude.next())
                } catch (_: PackageManager.NameNotFoundException) {
                }
            }
        }

        val pfd = builder.establish() ?: error("Android не дал создать VPN (разрешение отозвано)")
        tun = pfd
        return pfd.fd
    }

    private fun RoutePrefix.toIpPrefix() = IpPrefix(InetAddress.getByName(address()), prefix())

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        val owner = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val uid = connectivity.getConnectionOwnerUid(
                ipProtocol,
                InetSocketAddress(sourceAddress, sourcePort),
                InetSocketAddress(destinationAddress, destinationPort),
            )
            if (uid == Process.INVALID_UID) error("connection owner not found")
            ConnectionOwner().also { it.userId = uid }
        } else {
            Libbox.findConnectionOwner(ipProtocol, sourceAddress, sourcePort, destinationAddress, destinationPort)
        }
        val packages = packageManager.getPackagesForUid(owner.userId)
        owner.userName = packages?.firstOrNull() ?: ""
        owner.setAndroidPackageNames(StringArray((packages?.toList() ?: emptyList()).iterator()))
        return owner
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.setListener(listener)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.setListener(null)
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val javaIfaces = NetworkInterface.getNetworkInterfaces()?.toList() ?: emptyList()
        val result = mutableListOf<LibboxNetworkInterface>()
        @Suppress("DEPRECATION")
        for (network in connectivity.allNetworks) {
            val link = connectivity.getLinkProperties(network) ?: continue
            val caps = connectivity.getNetworkCapabilities(network) ?: continue
            val ni = javaIfaces.find { it.name == link.interfaceName } ?: continue
            val box = LibboxNetworkInterface()
            box.name = link.interfaceName
            box.dnsServer = StringArray(link.dnsServers.mapNotNull { it.hostAddress }.iterator())
            box.gateway = StringArray(
                link.routes.filter { it.destination.prefixLength == 0 }.mapNotNull { it.gateway }
                    .filterNot { it.isAnyLocalAddress }.mapNotNull { it.hostAddress }.iterator(),
            )
            box.type = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                else -> Libbox.InterfaceTypeOther
            }
            box.index = ni.index
            try {
                box.mtu = ni.mtu
            } catch (_: Exception) {
            }
            box.addresses = StringArray(ni.interfaceAddresses.map { it.toPrefix() }.iterator())
            var f = 0
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) f = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
            if (ni.isLoopback) f = f or OsConstants.IFF_LOOPBACK
            if (ni.isPointToPoint) f = f or OsConstants.IFF_POINTOPOINT
            if (ni.supportsMulticast()) f = f or OsConstants.IFF_MULTICAST
            box.flags = f
            box.metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            result.add(box)
        }
        return InterfaceArray(result.iterator())
    }

    private fun InterfaceAddress.toPrefix(): String =
        if (address is Inet6Address) "${Inet6Address.getByAddress(address.address).hostAddress}/$networkPrefixLength"
        else "${address.hostAddress}/$networkPrefixLength"

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun clearDNSCache() {}

    override fun readWIFIState(): WIFIState? = null

    override fun localDNSTransport(): LocalDNSTransport = LocalResolver

    override fun sendNotification(notification: LibboxNotification?) {}

    override fun cancelNotification(identifier: String?, typeID: Int) {}

    override fun startNeighborMonitor(listener: NeighborUpdateListener?) {}

    override fun closeNeighborMonitor(listener: NeighborUpdateListener?) {}

    override fun registerMyInterface(name: String?) {}

    override fun usePlatformShell(): Boolean = false

    override fun checkPlatformShell() {
        error("not supported")
    }

    override fun openShellSession(
        user: PlatformUser?,
        command: String?,
        environ: StringIterator?,
        term: String?,
        rows: Int,
        cols: Int,
    ): ShellSession = error("not supported")

    override fun lookupUser(username: String?): PlatformUser = error("not supported")

    override fun lookupSFTPServer(): String = error("not supported")

    override fun readSystemSSHHostKey(): String = error("not supported")

    override fun tailscaleHostname(): String = Build.MODEL ?: "android"

    override fun usePlatformBridge(): Boolean = false

    override fun createBridge(options: BridgeOptions?): BridgeSession = error("not supported")

    private class InterfaceArray(private val it: Iterator<LibboxNetworkInterface>) : NetworkInterfaceIterator {
        override fun hasNext(): Boolean = it.hasNext()
        override fun next(): LibboxNetworkInterface = it.next()
    }
}

class StringArray(private val it: Iterator<String>) : StringIterator {
    override fun len(): Int = 0
    override fun hasNext(): Boolean = it.hasNext()
    override fun next(): String = it.next()
}
