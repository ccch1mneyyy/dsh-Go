package io.github.ccch1mneyyy.dsh_app.runtime

import org.junit.Assert.*
import org.junit.Test

class LanLoginTest {
    @Test fun onlyShortLoginGetIsIntercepted() {
        assertTrue(LanLogin.isLoginRequest("GET /login HTTP/1.1"))
        assertTrue(LanLogin.isLoginRequest("GET /login HTTP/1.0"))
        assertFalse(LanLogin.isLoginRequest("GET / HTTP/1.1"))
        assertFalse(LanLogin.isLoginRequest("GET /login?token=abc HTTP/1.1"))
        assertFalse(LanLogin.isLoginRequest("POST /login HTTP/1.1"))
        assertFalse(LanLogin.isLoginRequest(null))
    }

    @Test fun redirectUsesTheShortAuthorityAndHidesTheTokenFromLogs() {
        val response = LanLogin.redirect("192.168.110.71:3080", "abc_DEF-123")
        assertNotNull(response)
        assertTrue(response!!.startsWith("HTTP/1.1 302 Found\r\n"))
        assertTrue(response.contains("Location: http://192.168.110.71:3080/?token=abc_DEF-123\r\n"))
        assertTrue(response.contains("Cache-Control: no-store\r\n"))
        assertTrue(response.contains("Referrer-Policy: no-referrer\r\n"))
        assertTrue(response.endsWith("Connection: close\r\nContent-Length: 0\r\n\r\n"))
    }

    @Test fun malformedAuthorityOrTokenNeverProducesARedirect() {
        for (authority in listOf(null, "", "localhost:3080", "8.8.8.8:3080", "192.168.110.71:65536")) {
            assertNull(LanLogin.redirect(authority, "abc_DEF-123"))
        }
        for (token in listOf(null, "", "abc=def", "abc.def", "abc%0d%0aInjected: 1")) {
            assertNull(LanLogin.redirect("192.168.110.71:3080", token))
        }
    }

    @Test fun unavailableAndOversizedResponsesStayUnauthenticated() {
        val unavailable = LanLogin.unavailable()
        assertTrue(unavailable.startsWith("HTTP/1.1 503 Service Unavailable\r\n"))
        assertFalse(unavailable.contains("Location:"))
        assertTrue(unavailable.contains("Cache-Control: no-store\r\n"))
        assertTrue(LanLogin.requestTooLarge().startsWith("HTTP/1.1 414 URI Too Long\r\n"))
    }
}
