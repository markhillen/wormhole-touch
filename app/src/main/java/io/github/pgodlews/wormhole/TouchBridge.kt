package io.github.pgodlews.wormhole

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import android.view.MotionEvent
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * Forwards touches on the mirrored video to companion apps on the sending Mac.
 *
 * Wire format: one ASCII line per touch event, coordinates normalised to the video (0..1):
 *   "P <count> <x1> <y1> [<x2> <y2> ...]"  fingers still down after the event (count 0 = last finger
 *                                          lifted; the lifted finger's position follows)
 *   "C"                                    gesture cancelled
 * The Mac helper (mac-helper/, see docs/touch-forwarding.md) discovers this via Bonjour
 * (_wormholetouch._tcp, TXT "display" = AirPlay name) and only acts while a display with that
 * name is attached to it. TCP 7100 is UxPlay's mirror data socket, hence 7213.
 */
object TouchBridge {
    private const val TAG = "WormholeTouch"
    const val PORT = 7213
    private const val SERVICE_TYPE = "_wormholetouch._tcp"

    private val clients = CopyOnWriteArrayList<Socket>()
    private val writer = Executors.newSingleThreadExecutor { r -> Thread(r, "Wormhole touch writer") }
    private var server: ServerSocket? = null
    private var nsd: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var started = false

    @Synchronized
    fun start(context: Context, displayName: String) {
        if (started) return
        started = true
        nsd = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
        Thread({ acceptLoop() }, "Wormhole touch accept").apply { isDaemon = true }.start()
        register(displayName)
    }

    @Synchronized
    fun updateDisplayName(displayName: String) {
        if (!started) return
        unregister()
        register(displayName)
    }

    private fun acceptLoop() {
        try {
            val socket = ServerSocket()
            socket.reuseAddress = true
            socket.bind(InetSocketAddress(PORT))
            server = socket
            Log.i(TAG, "Touch bridge listening on port $PORT")
            while (!socket.isClosed) {
                val client = socket.accept()
                client.tcpNoDelay = true
                clients.add(client)
                Log.i(TAG, "Touch client connected: ${client.inetAddress.hostAddress}")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Touch bridge stopped: ${e.message}")
        }
    }

    @Synchronized
    private fun register(displayName: String) {
        val manager = nsd ?: return
        val info = NsdServiceInfo().apply {
            serviceName = displayName
            serviceType = SERVICE_TYPE
            port = PORT
            setAttribute("display", displayName)
            setAttribute("v", "1")
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) { Log.i(TAG, "Advertised ${info.serviceName}") }
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) { Log.w(TAG, "Advertise failed: $code") }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
        }
        registration = listener
        try { manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) } catch (e: Exception) {
            Log.w(TAG, "Advertise error: ${e.message}")
        }
    }

    @Synchronized
    private fun unregister() {
        val listener = registration ?: return
        registration = null
        try { nsd?.unregisterService(listener) } catch (_: Exception) {}
    }

    /** Called on the UI thread for touches on the video surface. */
    fun onTouch(event: MotionEvent, viewWidth: Int, viewHeight: Int) {
        if (viewWidth <= 0 || viewHeight <= 0 || clients.isEmpty()) return
        val line = when (event.actionMasked) {
            MotionEvent.ACTION_CANCEL -> "C"
            else -> encode(event, viewWidth.toFloat(), viewHeight.toFloat())
        }
        writer.execute { broadcast(line) }
    }

    private fun encode(event: MotionEvent, w: Float, h: Float): String {
        val action = event.actionMasked
        val lifting = action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_POINTER_UP
        val liftedIndex = if (lifting) event.actionIndex else -1
        val down = ArrayList<Pair<Float, Float>>(event.pointerCount)
        var lifted: Pair<Float, Float>? = null
        for (i in 0 until event.pointerCount) {
            val point = event.getX(i) / w to event.getY(i) / h
            if (i == liftedIndex) lifted = point else down.add(point)
        }
        return encodeLine(down, lifted)
    }

    /**
     * Builds one "P" line. [down] holds the normalised positions of fingers still touching after the
     * event; when none remain, the lifted finger's position is sent so the receiver knows where the
     * gesture ended.
     */
    internal fun encodeLine(down: List<Pair<Float, Float>>, lifted: Pair<Float, Float>?): String {
        val sb = StringBuilder("P ").append(down.size)
        val points = if (down.isEmpty()) listOfNotNull(lifted) else down
        for ((x, y) in points) sb.append(' ').append(fmt(x)).append(' ').append(fmt(y))
        return sb.toString()
    }

    private fun fmt(v: Float): String = String.format(Locale.US, "%.5f", v.coerceIn(0f, 1f))

    private fun broadcast(line: String) {
        val bytes = (line + "\n").toByteArray(Charsets.US_ASCII)
        for (client in clients) {
            try {
                val out: OutputStream = client.getOutputStream()
                out.write(bytes)
                out.flush()
            } catch (e: Exception) {
                clients.remove(client)
                try { client.close() } catch (_: Exception) {}
            }
        }
    }
}
