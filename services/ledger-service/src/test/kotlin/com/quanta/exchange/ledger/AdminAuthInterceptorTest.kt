package com.quanta.exchange.ledger

import com.quanta.exchange.ledger.api.AdminAuthInterceptor
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.springframework.mock.web.MockHttpServletRequest
import org.springframework.mock.web.MockHttpServletResponse

class AdminAuthInterceptorTest {
    @Test
    fun allowsRequestsWhenAdminTokenIsUnset() {
        val interceptor = AdminAuthInterceptor(adminToken = "")
        val request = MockHttpServletRequest("GET", "/v1/admin/reconciliation/status")
        val response = MockHttpServletResponse()

        assertTrue(interceptor.preHandle(request, response, Any()))
    }

    @Test
    fun rejectsWhenTokenConfiguredAndHeaderMissing() {
        val interceptor = AdminAuthInterceptor(adminToken = "ops-secret")
        val request = MockHttpServletRequest("POST", "/v1/admin/rebuild-balances")
        val response = MockHttpServletResponse()

        assertFalse(interceptor.preHandle(request, response, Any()))
        assertEquals(401, response.status)
        assertEquals("""{"error":"admin_token_required"}""", response.contentAsString)
    }

    @Test
    fun allowsWhenTokenMatches() {
        val interceptor = AdminAuthInterceptor(adminToken = "ops-secret")
        val request = MockHttpServletRequest("GET", "/v1/admin/balances")
        request.addHeader("X-Admin-Token", "ops-secret")
        val response = MockHttpServletResponse()

        assertTrue(interceptor.preHandle(request, response, Any()))
    }
}
