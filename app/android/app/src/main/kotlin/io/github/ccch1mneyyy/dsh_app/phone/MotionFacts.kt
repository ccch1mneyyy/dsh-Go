package io.github.ccch1mneyyy.dsh_app.phone

import android.view.MotionEvent

/**
 * How one touch reached a guarded button, read from what Android says produced it.
 *
 * The previous test keyed on `deviceId > 0`: on the API 35 emulator that is the only fact
 * separating our own `dispatchGesture` stroke (device -1) from a hardware tap (device 12),
 * because both carry FLAG_IS_ACCESSIBILITY_EVENT. Some ROMs report `deviceId <= 0` for
 * ordinary touches that land on a TYPE_ACCESSIBILITY_OVERLAY window, and there every real
 * press was classified as an injected stroke: the card appeared, nothing answered, and the
 * request timed out as a refusal. Tool type describes the same thing without that guess.
 */
object MotionFacts {
    /** MotionEvent.FLAG_IS_ACCESSIBILITY_EVENT (hidden, API 31+). Real fingers carry it too. */
    const val FLAG_IS_ACCESSIBILITY_EVENT = 0x800

    /** The touch came through another app's window on top of this one (tapjacking). */
    fun obscured(event: MotionEvent): Boolean =
        event.flags and (MotionEvent.FLAG_WINDOW_IS_OBSCURED or MotionEvent.FLAG_WINDOW_IS_PARTIALLY_OBSCURED) != 0

    /**
     * Looks like a stroke an accessibility service injected rather than a person's input
     * device: the event has no pointing tool at all. A finger, stylus, mouse or eraser is
     * never one of those, whatever `deviceId` reports; `dispatchGesture` arrives as
     * TOOL_TYPE_UNKNOWN. The flag alone cannot decide it — hardware taps carry it too.
     */
    fun injectedStroke(event: MotionEvent): Boolean = when (event.getToolType(0)) {
        MotionEvent.TOOL_TYPE_FINGER, MotionEvent.TOOL_TYPE_STYLUS,
        MotionEvent.TOOL_TYPE_MOUSE, MotionEvent.TOOL_TYPE_ERASER -> false
        else -> true
    }

    /** One line for the debug verdict: what the event said about itself. */
    fun describe(event: MotionEvent): String =
        "flags=0x${Integer.toHexString(event.flags)} device=${event.deviceId} " +
            "source=0x${Integer.toHexString(event.source)} tool=${event.getToolType(0)}"
}
