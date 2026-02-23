package com.quanta.exchange.ledger

import com.quanta.exchange.ledger.core.validateRuntimeGuardrails
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test

class StartupGuardrailsTest {
    @Test
    fun `allows development defaults outside production`() {
        val violations = validateRuntimeGuardrails(
            runtimeEnv = "local",
            adminToken = "",
            kafkaEnabled = false,
            kafkaBootstrapServers = "localhost:29092",
            coreGrpcAddress = "localhost:50051",
            safetyLatchEnabled = true,
            latchReleaseRequireDualApproval = false,
        )
        assertThat(violations).isEmpty()
    }

    @Test
    fun `rejects production when admin token is missing`() {
        val violations = validateRuntimeGuardrails(
            runtimeEnv = "prod",
            adminToken = " ",
            kafkaEnabled = true,
            kafkaBootstrapServers = "redpanda-0:9092",
            coreGrpcAddress = "trading-core:50051",
            safetyLatchEnabled = true,
            latchReleaseRequireDualApproval = true,
        )
        assertThat(violations).anyMatch { it.contains("LEDGER_ADMIN_TOKEN") }
    }

    @Test
    fun `rejects production when kafka consumer integration is disabled`() {
        val violations = validateRuntimeGuardrails(
            runtimeEnv = "production",
            adminToken = "secret",
            kafkaEnabled = false,
            kafkaBootstrapServers = "redpanda-0:9092",
            coreGrpcAddress = "trading-core:50051",
            safetyLatchEnabled = true,
            latchReleaseRequireDualApproval = true,
        )
        assertThat(violations).anyMatch { it.contains("LEDGER_KAFKA_ENABLED") }
    }

    @Test
    fun `rejects production loopback kafka bootstrap`() {
        val violations = validateRuntimeGuardrails(
            runtimeEnv = "prod",
            adminToken = "secret",
            kafkaEnabled = true,
            kafkaBootstrapServers = "localhost:29092,redpanda-0:9092",
            coreGrpcAddress = "trading-core:50051",
            safetyLatchEnabled = true,
            latchReleaseRequireDualApproval = true,
        )
        assertThat(violations).anyMatch { it.contains("LEDGER_KAFKA_BOOTSTRAP") }
    }

    @Test
    fun `rejects production loopback core grpc address`() {
        val violations = validateRuntimeGuardrails(
            runtimeEnv = "live",
            adminToken = "secret",
            kafkaEnabled = true,
            kafkaBootstrapServers = "redpanda-0:9092",
            coreGrpcAddress = "dns:///127.0.0.1:50051",
            safetyLatchEnabled = true,
            latchReleaseRequireDualApproval = true,
        )
        assertThat(violations).anyMatch { it.contains("LEDGER_RECONCILIATION_CORE_GRPC_ADDR") }
    }

    @Test
    fun `rejects production when safety latch is disabled`() {
        val violations = validateRuntimeGuardrails(
            runtimeEnv = "prod",
            adminToken = "secret",
            kafkaEnabled = true,
            kafkaBootstrapServers = "redpanda-0:9092",
            coreGrpcAddress = "trading-core:50051",
            safetyLatchEnabled = false,
            latchReleaseRequireDualApproval = true,
        )
        assertThat(violations).anyMatch { it.contains("LEDGER_RECONCILIATION_SAFETY_LATCH_ENABLED") }
    }

    @Test
    fun `rejects production when latch release dual approval is disabled`() {
        val violations = validateRuntimeGuardrails(
            runtimeEnv = "prod",
            adminToken = "secret",
            kafkaEnabled = true,
            kafkaBootstrapServers = "redpanda-0:9092",
            coreGrpcAddress = "trading-core:50051",
            safetyLatchEnabled = true,
            latchReleaseRequireDualApproval = false,
        )
        assertThat(violations).anyMatch { it.contains("LEDGER_RECONCILIATION_LATCH_RELEASE_REQUIRE_DUAL_APPROVAL") }
    }

    @Test
    fun `accepts valid production configuration`() {
        val violations = validateRuntimeGuardrails(
            runtimeEnv = "prod",
            adminToken = "secret",
            kafkaEnabled = true,
            kafkaBootstrapServers = "redpanda-0:9092,redpanda-1:9092",
            coreGrpcAddress = "trading-core:50051",
            safetyLatchEnabled = true,
            latchReleaseRequireDualApproval = true,
        )
        assertThat(violations).isEmpty()
    }
}
