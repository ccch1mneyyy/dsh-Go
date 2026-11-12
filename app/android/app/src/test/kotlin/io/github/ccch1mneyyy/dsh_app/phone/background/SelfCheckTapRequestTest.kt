package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SelfCheckTapRequestTest {
    private val owner = "33e7171b-c791-47b5-bd78-061e61ab11a4"

    @Test
    fun exactTapRequestKeepsOwner() {
        val values = mapOf(
            Proto.OP to Proto.OP_SELF_CHECK_TAP,
            Proto.OWNER to owner,
            Proto.DISPLAY_ID to 12,
            Proto.X to 180,
            Proto.Y to 400,
            Proto.TIME to 123456L,
        )
        assertEquals(owner, SelfCheckTapRequest.owner(values.keys) { values[it] })
    }

    @Test
    fun rejectsUnknownFieldsAndTypes() {
        val base = mapOf(
            Proto.OP to Proto.OP_SELF_CHECK_TAP,
            Proto.OWNER to owner,
            Proto.DISPLAY_ID to 12,
            Proto.X to 180,
            Proto.Y to 400,
            Proto.TIME to 123456L,
        )
        assertNull(SelfCheckTapRequest.owner(base.keys + "extra") { base[it] })
        assertNull(SelfCheckTapRequest.owner(base.keys) { if (it == Proto.DISPLAY_ID) "12" else base[it] })
        assertNull(SelfCheckTapRequest.owner(base.keys) { if (it == Proto.TIME) 123456 else base[it] })
        assertNull(SelfCheckTapRequest.owner(base.keys) { if (it == Proto.OWNER) "not-a-uuid" else base[it] })
    }
}
