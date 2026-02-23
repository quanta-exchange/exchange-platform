package com.quanta.exchange.ledger.core

import org.springframework.beans.factory.annotation.Value
import org.springframework.boot.ApplicationArguments
import org.springframework.boot.ApplicationRunner
import org.springframework.stereotype.Component

@Component
class StartupGuardrails(
    @Value("\${ledger.runtime.env:local}")
    private val runtimeEnv: String,
    @Value("\${ledger.admin.token:}")
    private val adminToken: String,
    @Value("\${ledger.kafka.enabled:false}")
    private val kafkaEnabled: Boolean,
    @Value("\${spring.kafka.bootstrap-servers:}")
    private val kafkaBootstrapServers: String,
    @Value("\${ledger.reconciliation.core-grpc-address:localhost:50051}")
    private val coreGrpcAddress: String,
    @Value("\${ledger.reconciliation.safety-latch-enabled:true}")
    private val safetyLatchEnabled: Boolean,
    @Value("\${ledger.reconciliation.latch-release-require-dual-approval:false}")
    private val latchReleaseRequireDualApproval: Boolean,
) : ApplicationRunner {
    override fun run(args: ApplicationArguments) {
        val violations = validateRuntimeGuardrails(
            runtimeEnv = runtimeEnv,
            adminToken = adminToken,
            kafkaEnabled = kafkaEnabled,
            kafkaBootstrapServers = kafkaBootstrapServers,
            coreGrpcAddress = coreGrpcAddress,
            safetyLatchEnabled = safetyLatchEnabled,
            latchReleaseRequireDualApproval = latchReleaseRequireDualApproval,
        )
        if (violations.isNotEmpty()) {
            throw IllegalStateException("production guardrail violation(s): ${violations.joinToString("; ")}")
        }
    }
}

internal fun validateRuntimeGuardrails(
    runtimeEnv: String,
    adminToken: String,
    kafkaEnabled: Boolean,
    kafkaBootstrapServers: String,
    coreGrpcAddress: String,
    safetyLatchEnabled: Boolean,
    latchReleaseRequireDualApproval: Boolean,
): List<String> {
    if (!isProductionEnvironment(runtimeEnv)) {
        return emptyList()
    }
    val violations = mutableListOf<String>()
    if (adminToken.isBlank()) {
        violations += "LEDGER_ADMIN_TOKEN must be set in production"
    }
    if (!kafkaEnabled) {
        violations += "LEDGER_KAFKA_ENABLED must be true in production"
    }
    if (containsLoopbackEndpoint(kafkaBootstrapServers)) {
        violations += "LEDGER_KAFKA_BOOTSTRAP must not use localhost/loopback in production"
    }
    if (containsLoopbackEndpoint(coreGrpcAddress)) {
        violations += "LEDGER_RECONCILIATION_CORE_GRPC_ADDR must not use localhost/loopback in production"
    }
    if (!safetyLatchEnabled) {
        violations += "LEDGER_RECONCILIATION_SAFETY_LATCH_ENABLED must be true in production"
    }
    if (!latchReleaseRequireDualApproval) {
        violations += "LEDGER_RECONCILIATION_LATCH_RELEASE_REQUIRE_DUAL_APPROVAL must be true in production"
    }
    return violations
}

internal fun isProductionEnvironment(runtimeEnv: String): Boolean {
    return when (runtimeEnv.trim().lowercase()) {
        "prod", "production", "live" -> true
        else -> false
    }
}

private fun containsLoopbackEndpoint(rawValue: String): Boolean {
    return rawValue
        .split(',')
        .map { it.trim() }
        .filter { it.isNotEmpty() }
        .any { isLoopbackHost(hostFromEndpoint(it)) }
}

private fun hostFromEndpoint(rawEndpoint: String): String {
    val withoutScheme = rawEndpoint.substringAfter("://", rawEndpoint)
    val normalized = withoutScheme.trimStart('/')
    val withoutPath = normalized.substringBefore('/')
    val candidate = when {
        withoutPath.startsWith('[') -> withoutPath.substringBefore(']') + "]"
        else -> withoutPath.substringBefore(':')
    }
    return candidate.trim().lowercase()
}

private fun isLoopbackHost(host: String): Boolean {
    return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
}
