package io.github.ccch1mneyyy.dsh_app.phone.background

import android.app.Activity
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.os.ResultReceiver
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import kotlin.concurrent.thread

/**
 * Focus owner for the gate's disposable display, launched by the app itself.
 *
 * ColorOS does not deliver injected touches to a display that has no focused application window.
 * This empty Activity is launched onto the probe display for the short lifetime of one gate check;
 * it gives that display a real Activity window and hosts the inert touch receiver itself.
 */
class BackgroundProbeHostActivity : Activity() {
    private var receiver: ResultReceiver? = null
    private var displayId = -1
    private var probe: InputProbe? = null
    private var started = false

    private class ProbeView(context: Context) : View(context) {
        var onReady: ((Int, Int) -> Unit)? = null
        var onTouch: ((MotionEvent) -> Unit)? = null
        private var readySent = false

        override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
            super.onSizeChanged(w, h, oldw, oldh)
            if (w >= 4 && h >= 4 && !readySent) {
                readySent = true
                // Let WindowManager finish the first draw and register the activity window with
                // InputDispatcher before the privileged side injects the probe touch.
                postDelayed({ onReady?.invoke(w, h) }, 300)
            }
        }

        override fun onTouchEvent(event: MotionEvent): Boolean {
            onTouch?.invoke(event)
            return true
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        displayId = intent.getIntExtra(EXTRA_DISPLAY_ID, -1)
        receiver = intent.getParcelableExtra(EXTRA_RECEIVER)
        probe = InputProbe(displayId)
        val view = ProbeView(this)
        view.onReady = { w, h ->
            probe?.ready(InputProbe.Target(displayId, w / 2, h / 2))
            if (!started) {
                started = true
                startProbe()
            }
        }
        view.onTouch = { event ->
            probe?.accept(displayId, event.downTime, event.actionMasked, event.rawX, event.rawY)
        }
        setContentView(view)
    }

    private fun startProbe() {
        val display = (getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager)
            ?.getDisplay(displayId)
        if (display == null || display.displayId <= 0 || !display.isValid) {
            reportFailure("inputWindowNotReady", null)
            return
        }
        thread(name = "dsh-gate-probe") {
            try {
                probe?.verify(
                    now = { SystemClock.uptimeMillis() },
                    send = { target, time ->
                        receiver?.send(RESULT_ARMED, Bundle().apply {
                            putInt(EXTRA_DISPLAY_ID, target.displayId)
                            putInt(EXTRA_X, target.x)
                            putInt(EXTRA_Y, target.y)
                            putLong(EXTRA_TIME, time)
                        })
                    },
                )
                receiver?.send(RESULT_OK, null)
            } catch (e: Exception) {
                val failure = e as? InputProbe.Failure
                reportFailure(
                    failure?.code ?: "deviceUnavailable",
                    failure?.observation?.encode() ?: (e as? SecurityException)?.message,
                )
            } finally {
                finish()
            }
        }
    }

    private fun reportFailure(code: String, detail: String?) {
        receiver?.send(RESULT_FAIL, Bundle().apply {
            putString(EXTRA_ERROR, code)
            putString(EXTRA_DETAIL, detail)
        })
        finish()
    }

    companion object {
        const val EXTRA_RECEIVER = "io.github.ccch1mneyyy.dsh_app.extra.PROBE_HOST_RECEIVER"
        const val EXTRA_DISPLAY_ID = "io.github.ccch1mneyyy.dsh_app.extra.PROBE_HOST_DISPLAY_ID"
        const val EXTRA_X = "io.github.ccch1mneyyy.dsh_app.extra.PROBE_HOST_X"
        const val EXTRA_Y = "io.github.ccch1mneyyy.dsh_app.extra.PROBE_HOST_Y"
        const val EXTRA_TIME = "io.github.ccch1mneyyy.dsh_app.extra.PROBE_HOST_TIME"
        const val EXTRA_ERROR = "io.github.ccch1mneyyy.dsh_app.extra.PROBE_HOST_ERROR"
        const val EXTRA_DETAIL = "io.github.ccch1mneyyy.dsh_app.extra.PROBE_HOST_DETAIL"
        const val RESULT_ARMED = 1
        const val RESULT_OK = 2
        const val RESULT_FAIL = 3
    }
}
