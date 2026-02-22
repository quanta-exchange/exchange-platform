package com.quanta.exchange.ledger.core

import com.exchange.v1.CommandMetadata
import com.exchange.v1.SetSymbolModeRequest
import com.exchange.v1.SymbolMode
import com.exchange.v1.TradingCoreServiceGrpc
import io.grpc.ManagedChannel
import io.grpc.ManagedChannelBuilder
import jakarta.annotation.PreDestroy
import org.slf4j.LoggerFactory
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Component
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit

interface SymbolModeSwitcher {
    fun setSymbolMode(symbol: String, mode: SafetyMode, reason: String): Boolean
    fun restoreSymbolMode(symbol: String, reason: String): Boolean
}

@Component
@ConditionalOnProperty(prefix = "ledger.reconciliation", name = ["auto-switch-enabled"], havingValue = "true", matchIfMissing = true)
class GrpcSymbolModeSwitcher(
    @Value("\${ledger.reconciliation.core-grpc-address:localhost:50051}")
    coreGrpcAddress: String,
    @Value("\${ledger.reconciliation.core-grpc-timeout-ms:1500}")
    private val timeoutMs: Long,
) : SymbolModeSwitcher {
    private val log = LoggerFactory.getLogger(javaClass)
    private val channel: ManagedChannel = ManagedChannelBuilder.forTarget(coreGrpcAddress).usePlaintext().build()
    private val stub = TradingCoreServiceGrpc.newBlockingStub(channel)

    override fun setSymbolMode(symbol: String, mode: SafetyMode, reason: String): Boolean {
        return applySymbolMode(symbol, toProtoMode(mode), reason)
    }

    override fun restoreSymbolMode(symbol: String, reason: String): Boolean {
        return applySymbolMode(symbol, SymbolMode.SYMBOL_MODE_NORMAL, reason)
    }

    private fun applySymbolMode(symbol: String, mode: SymbolMode, reason: String): Boolean {
        val now = Instant.now()
        val commandId = "recon-${symbol}-${now.toEpochMilli()}-${UUID.randomUUID()}"
        val metadata = CommandMetadata.newBuilder()
            .setCommandId(commandId)
            .setIdempotencyKey(commandId)
            .setUserId("ledger-reconciliation")
            .setSymbol(symbol)
            .setTsServer(toProtoTimestamp(now))
            .setTraceId(commandId)
            .setCorrelationId(commandId)
            .build()
        val req = SetSymbolModeRequest.newBuilder()
            .setMeta(metadata)
            .setMode(mode)
            .setReason(reason)
            .build()

        return try {
            val resp = stub.withDeadlineAfter(timeoutMs.coerceAtLeast(1), TimeUnit.MILLISECONDS).setSymbolMode(req)
            if (!resp.accepted) {
                log.error(
                    "service=ledger msg=reconciliation_safety_rejected symbol={} mode={} reason={}",
                    symbol,
                    mode.name,
                    reason,
                )
            }
            resp.accepted
        } catch (ex: Exception) {
            log.error(
                "service=ledger msg=reconciliation_safety_failed symbol={} mode={} reason={} err={}",
                symbol,
                mode.name,
                reason,
                ex.message,
            )
            false
        }
    }

    @PreDestroy
    fun shutdown() {
        channel.shutdownNow()
        channel.awaitTermination(2, TimeUnit.SECONDS)
    }

    private fun toProtoMode(mode: SafetyMode): SymbolMode {
        return when (mode) {
            SafetyMode.NORMAL -> SymbolMode.SYMBOL_MODE_NORMAL
            SafetyMode.CANCEL_ONLY -> SymbolMode.SYMBOL_MODE_CANCEL_ONLY
            SafetyMode.SOFT_HALT -> SymbolMode.SYMBOL_MODE_SOFT_HALT
            SafetyMode.HARD_HALT -> SymbolMode.SYMBOL_MODE_HARD_HALT
        }
    }

    private fun toProtoTimestamp(value: Instant): com.google.protobuf.Timestamp {
        return com.google.protobuf.Timestamp.newBuilder()
            .setSeconds(value.epochSecond)
            .setNanos(value.nano)
            .build()
    }
}

@Component
@ConditionalOnProperty(prefix = "ledger.reconciliation", name = ["auto-switch-enabled"], havingValue = "false")
class NoopSymbolModeSwitcher : SymbolModeSwitcher {
    override fun setSymbolMode(symbol: String, mode: SafetyMode, reason: String): Boolean {
        return false
    }

    override fun restoreSymbolMode(symbol: String, reason: String): Boolean {
        return false
    }
}
