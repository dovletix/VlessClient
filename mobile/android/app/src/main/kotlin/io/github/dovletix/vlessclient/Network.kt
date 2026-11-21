package io.github.dovletix.vlessclient

import android.content.Context
import android.net.ConnectivityManager
import android.net.DnsResolver
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.HandlerThread
import android.system.ErrnoException
import androidx.annotation.RequiresApi
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.Func
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.LocalDNSTransport
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Tracks the physical network sing-box must send its own traffic through (not our tunnel)
 * and reports it to libbox's default interface monitor. Modelled on SFA's DefaultNetworkMonitor/Listener.
 */
object DefaultNetworkMonitor {
    @Volatile var defaultNetwork: Network? = null
    private var listener: InterfaceUpdateListener? = null
    private var cm: ConnectivityManager? = null
    private var registered = false
    private val handler by lazy { Handler(HandlerThread("network-callback").apply { start() }.looper) }

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            defaultNetwork = network
            notifyListener(network)
        }

        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
            if (network == defaultNetwork) notifyListener(network)
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            if (network == defaultNetwork) notifyListener(network)
        }

        override fun onLost(network: Network) {
            if (network == defaultNetwork) {
                defaultNetwork = null
                notifyListener(null)
            }
        }
    }

    @Synchronized
    fun start(ctx: Context) {
        val c = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        cm = c
        if (registered) return
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()
        // registerDefaultNetworkCallback would report our own VPN since Android 9; ask for the best real network instead
        when {
            Build.VERSION.SDK_INT >= 31 -> c.registerBestMatchingNetworkCallback(request, callback, handler)
            Build.VERSION.SDK_INT >= 28 -> c.requestNetwork(request, callback, handler)
            Build.VERSION.SDK_INT >= 26 -> c.registerDefaultNetworkCallback(callback, handler)
            else -> c.registerDefaultNetworkCallback(callback)
        }
        registered = true
        if (defaultNetwork == null) defaultNetwork = c.activeNetwork
    }

    @Synchronized
    fun stop() {
        if (!registered) return
        try {
            cm?.unregisterNetworkCallback(callback)
        } catch (_: Exception) {
        }
        registered = false
        defaultNetwork = null
    }

    fun setListener(l: InterfaceUpdateListener?) {
        listener = l
        notifyListener(defaultNetwork)
    }

    private fun notifyListener(network: Network?) {
        val l = listener ?: return
        if (network == null) {
            l.updateDefaultInterface("", -1, false, false)
            return
        }
        repeat(10) {
            val link = cm?.getLinkProperties(network)
            if (link == null) {
                Thread.sleep(100)
                return@repeat
            }
            val index = try {
                NetworkInterface.getByName(link.interfaceName).index
            } catch (_: Exception) {
                Thread.sleep(100)
                return@repeat
            }
            l.updateDefaultInterface(link.interfaceName, index, false, false)
            return
        }
    }
}

/** DNS for the "local" (direct) server: the phone's own resolver on the physical network. Modelled on SFA's LocalResolver. */
object LocalResolver : LocalDNSTransport {
    private const val RCODE_NXDOMAIN = 3
    private val executor = Executors.newCachedThreadPool()

    override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    private fun network(): Network = DefaultNetworkMonitor.defaultNetwork ?: error("missing default interface")

    private fun <T> await(ctx: ExchangeContext, run: (CancellationSignal, (T?, Throwable?) -> Unit) -> Unit): T? {
        val latch = CountDownLatch(1)
        var value: T? = null
        var failure: Throwable? = null
        val signal = CancellationSignal()
        ctx.onCancel(object : Func {
            override fun invoke() {
                signal.cancel()
                latch.countDown()
            }
        })
        run(signal) { v, e ->
            value = v
            failure = e
            latch.countDown()
        }
        latch.await(15, TimeUnit.SECONDS)
        failure?.let { throw it }
        return value
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        val net = network()
        await<Unit>(ctx) { signal, done ->
            DnsResolver.getInstance().rawQuery(net, message, DnsResolver.FLAG_NO_RETRY, executor, signal,
                object : DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(answer: ByteArray, rcode: Int) {
                        if (rcode == 0) ctx.rawSuccess(answer) else ctx.errorCode(rcode)
                        done(Unit, null)
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        val cause = error.cause
                        if (cause is ErrnoException) {
                            ctx.errnoCode(cause.errno)
                            done(Unit, null)
                        } else {
                            done(null, error)
                        }
                    }
                })
        }
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        val net = network()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            await<Unit>(ctx) { signal, done ->
                val cb = object : DnsResolver.Callback<List<InetAddress>> {
                    override fun onAnswer(answer: List<InetAddress>, rcode: Int) {
                        if (rcode == 0) ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n")) else ctx.errorCode(rcode)
                        done(Unit, null)
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        val cause = error.cause
                        if (cause is ErrnoException) {
                            ctx.errnoCode(cause.errno)
                            done(Unit, null)
                        } else {
                            done(null, error)
                        }
                    }
                }
                val type = when {
                    network.endsWith("4") -> DnsResolver.TYPE_A
                    network.endsWith("6") -> DnsResolver.TYPE_AAAA
                    else -> null
                }
                if (type != null) {
                    DnsResolver.getInstance().query(net, domain, type, DnsResolver.FLAG_NO_RETRY, executor, signal, cb)
                } else {
                    DnsResolver.getInstance().query(net, domain, DnsResolver.FLAG_NO_RETRY, executor, signal, cb)
                }
            }
        } else {
            val answer = try {
                net.getAllByName(domain)
            } catch (_: UnknownHostException) {
                ctx.errorCode(RCODE_NXDOMAIN)
                return
            }
            ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
        }
    }
}
