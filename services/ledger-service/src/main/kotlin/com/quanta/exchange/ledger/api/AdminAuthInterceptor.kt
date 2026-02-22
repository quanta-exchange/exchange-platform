package com.quanta.exchange.ledger.api

import jakarta.servlet.http.HttpServletRequest
import jakarta.servlet.http.HttpServletResponse
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Component
import org.springframework.web.servlet.HandlerInterceptor

@Component
class AdminAuthInterceptor(
    @Value("\${ledger.admin.token:}")
    private val adminToken: String,
) : HandlerInterceptor {
    override fun preHandle(request: HttpServletRequest, response: HttpServletResponse, handler: Any): Boolean {
        if (adminToken.isBlank()) {
            return true
        }
        val provided = request.getHeader("X-Admin-Token")
        if (provided != null && provided == adminToken) {
            return true
        }
        response.status = HttpServletResponse.SC_UNAUTHORIZED
        response.contentType = "application/json"
        response.writer.write("""{"error":"admin_token_required"}""")
        response.writer.flush()
        return false
    }
}
