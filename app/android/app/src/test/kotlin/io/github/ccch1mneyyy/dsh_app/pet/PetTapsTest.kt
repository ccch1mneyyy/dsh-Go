package io.github.ccch1mneyyy.dsh_app.pet

import org.junit.Assert.*
import org.junit.Test

class PetTapsTest {
    @Test fun aTapPlaysAndOnlyAQuickNearbySecondOneOpensTheConversation() {
        val taps = PetTaps(timeoutMs = 300, slop = 100f)
        assertFalse(taps.second(1_000, 50f, 50f))
        assertTrue(taps.second(1_300, 120f, 50f))
        // The pair is spent: a third tap starts over rather than opening again.
        assertFalse(taps.second(1_400, 120f, 50f))
        assertFalse("too late", taps.second(1_701, 120f, 50f))
        assertFalse("too far", taps.second(1_800, 120f, 151f))
        assertTrue(taps.second(1_900, 120f, 151f))
    }
}
