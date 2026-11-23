package io.github.dovletix.vlessclient

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log

/**
 * The quick settings tile: one tap switches the VPN on or off without opening the app. It starts the tunnel with the
 * last config the app wrote (files/config.json), the same way Android starts an always-on VPN. When there is no
 * config yet or Android has not allowed the VPN, the tap opens the app instead.
 */
class VpnTile : TileService() {
    companion object {
        private const val TAG = "VlessClient"

        /** Asks Android to call onStartListening again so the tile shows the new state. */
        fun refresh(ctx: Context) {
            try {
                requestListeningState(ctx, ComponentName(ctx, VpnTile::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "tile refresh", e)
            }
        }
    }

    private val main = Handler(Looper.getMainLooper())

    override fun onStartListening() {
        super.onStartListening()
        update()
    }

    override fun onClick() {
        super.onClick()
        if (BoxVpnService.running || BoxVpnService.starting) {
            BoxVpnService.send(this, BoxVpnService.ACTION_STOP)
            pollUntilSettled()
            return
        }
        if (!BoxVpnService.configFile(this).exists() || VpnService.prepare(this) != null) {
            // first start (no settings yet) or the VPN permission is missing: both need the app on screen
            if (isLocked) unlockAndRun { openApp() } else openApp()
            return
        }
        try {
            BoxVpnService.lastError = ""
            BoxVpnService.starting = true
            BoxVpnService.send(this, BoxVpnService.ACTION_START)
        } catch (e: Exception) {
            // e.g. Android refused a foreground start: the app can always start it
            Log.w(TAG, "tile start", e)
            BoxVpnService.starting = false
            openApp()
            return
        }
        update()
        pollUntilSettled()
    }

    /** The service changes state on its own thread; follow it for a few seconds while the panel is open. */
    private fun pollUntilSettled(left: Int = 30) {
        main.postDelayed({
            update()
            if (left > 0 && BoxVpnService.starting) pollUntilSettled(left - 1)
        }, 300)
    }

    private fun update() {
        val tile = qsTile ?: return
        val on = BoxVpnService.running
        val busy = BoxVpnService.starting
        tile.state = if (on || busy) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "VlessClient"
        tile.icon = Icon.createWithResource(this, R.drawable.ic_vpn)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = when {
                busy -> "Подключение…"
                on -> "Включён"
                BoxVpnService.lastError.isNotEmpty() -> "Ошибка"
                else -> "Выключен"
            }
        }
        tile.updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startActivityAndCollapse(PendingIntent.getActivity(this, 2, intent, PendingIntent.FLAG_IMMUTABLE))
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        } catch (e: Exception) {
            Log.w(TAG, "tile open app", e)
        }
    }
}
