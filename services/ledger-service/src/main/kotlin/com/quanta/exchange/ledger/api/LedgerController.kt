package com.quanta.exchange.ledger.api

import com.quanta.exchange.ledger.core.LedgerMetrics
import com.quanta.exchange.ledger.core.LedgerService
import com.quanta.exchange.ledger.core.KafkaConsumerControl
import org.springframework.beans.factory.annotation.Value
import org.springframework.http.HttpStatus
import org.springframework.http.MediaType
import org.springframework.http.ResponseEntity
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController

@RestController
class SystemController(
    private val jdbc: JdbcTemplate,
    private val metrics: LedgerMetrics,
) {
    @GetMapping("/healthz")
    fun health(): Map<String, String> {
        return mapOf("service" to "ledger-service", "status" to "ok")
    }

    @GetMapping("/readyz")
    fun ready(): ResponseEntity<Map<String, String>> {
        return try {
            jdbc.queryForObject("SELECT 1", Int::class.java)
            ResponseEntity.ok(mapOf("status" to "ready"))
        } catch (_: Exception) {
            ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(mapOf("status" to "db_unready"))
        }
    }

    @GetMapping("/metrics", produces = [MediaType.TEXT_PLAIN_VALUE])
    fun prometheus(): String {
        return metrics.renderPrometheus()
    }
}

@RestController
@RequestMapping("/v1")
class LedgerController(
    private val ledgerService: LedgerService,
    private val consumerControl: KafkaConsumerControl,
    @Value("\${ledger.reconciliation.lag-threshold:10}")
    private val lagThreshold: Long,
    @Value("\${ledger.reconciliation.safety-mode:CANCEL_ONLY}")
    private val safetyMode: String,
    @Value("\${ledger.reconciliation.safety-latch-enabled:true}")
    private val safetyLatchEnabled: Boolean,
) {
    @PostMapping("/internal/trades/executed")
    fun tradeExecuted(@RequestBody req: TradeExecutedDto): Map<String, Any> {
        val result = ledgerService.consumeTrade(req.toModel())
        return mapOf(
            "applied" to result.applied,
            "entryId" to result.entryId,
            "reason" to result.reason,
        )
    }

    @PostMapping("/internal/orders/reserve")
    fun reserve(@RequestBody req: ReserveDto): Map<String, Any> {
        val applied = ledgerService.reserve(req.toModel())
        return mapOf("applied" to applied)
    }

    @PostMapping("/internal/orders/release")
    fun release(@RequestBody req: ReserveDto): Map<String, Any> {
        val applied = ledgerService.release(req.toModel())
        return mapOf("applied" to applied)
    }

    @PostMapping("/internal/reconciliation/engine-seq")
    fun recordEngineSeq(@RequestBody req: EngineSeqDto): Map<String, Any> {
        ledgerService.updateEngineSeq(req.symbol, req.seq)
        val status = ledgerService.reconciliation(req.symbol)
        return mapOf(
            "symbol" to status.symbol,
            "lastEngineSeq" to status.lastEngineSeq,
            "lastSettledSeq" to status.lastSettledSeq,
            "gap" to status.gap,
        )
    }

    @PostMapping("/admin/adjustments")
    fun adjustments(@RequestBody req: BalanceAdjustmentDto): Map<String, Any> {
        val applied = ledgerService.adjustAvailable(req.toModel())
        return mapOf("applied" to applied)
    }

    @GetMapping("/balances")
    fun balances(): Map<String, Any> {
        return mapOf("balances" to ledgerService.listBalances())
    }

    @PostMapping("/admin/rebuild-balances")
    fun rebuildBalances(): Map<String, String> {
        ledgerService.rebuildBalances()
        return mapOf("status" to "rebuild_started")
    }

    @PostMapping("/admin/invariants/check")
    fun invariantCheck(): Map<String, Any> {
        val result = ledgerService.runInvariantCheck()
        return mapOf(
            "ok" to result.ok,
            "violations" to result.violations,
            "recommendation" to if (result.ok) "NONE" else "SEV1: HALT withdrawals + CANCEL_ONLY",
        )
    }

    @GetMapping("/admin/reconciliation/{symbol}")
    fun reconciliation(@PathVariable symbol: String): Map<String, Any?> {
        val status = ledgerService.reconciliation(symbol)
        val lag = status.lastEngineSeq - status.lastSettledSeq
        val mismatch = lag < 0
        val thresholdBreached = lag > lagThreshold
        return mapOf(
            "symbol" to status.symbol,
            "lastEngineSeq" to status.lastEngineSeq,
            "lastSettledSeq" to status.lastSettledSeq,
            "gap" to lag,
            "lagThreshold" to lagThreshold,
            "mismatch" to mismatch,
            "thresholdBreached" to thresholdBreached,
            "updatedAt" to status.updatedAt,
            "recommendation" to if (mismatch || thresholdBreached) "$safetyMode + investigate/replay" else "NONE",
        )
    }

    @GetMapping("/admin/reconciliation/status")
    fun reconciliationStatus(
        @RequestParam(name = "historyLimit", defaultValue = "50")
        historyLimit: Int,
    ): Map<String, Any?> {
        val dashboard = ledgerService.reconciliationStatus(
            historyLimit = historyLimit,
            lagThreshold = lagThreshold,
        )
        return mapOf(
            "checkedAt" to dashboard.checkedAt,
            "lagThreshold" to lagThreshold,
            "safetyMode" to safetyMode,
            "safetyLatchEnabled" to safetyLatchEnabled,
            "statuses" to dashboard.statuses,
            "history" to dashboard.history,
        )
    }

    @PostMapping("/admin/reconciliation/latch/{symbol}/release")
    fun releaseReconciliationLatch(
        @PathVariable symbol: String,
        @RequestBody req: ReconciliationLatchReleaseDto,
    ): Map<String, Any?> {
        val result = ledgerService.releaseReconciliationLatch(
            symbol = symbol,
            lagThreshold = lagThreshold,
            approvedBy = req.approvedBy,
            reason = req.reason,
            restoreSymbolMode = req.restoreSymbolMode,
        )
        return mapOf(
            "symbol" to result.symbol,
            "released" to result.released,
            "modeRestored" to result.modeRestored,
            "reason" to result.reason,
            "lag" to result.lag,
            "mismatch" to result.mismatch,
            "thresholdBreached" to result.thresholdBreached,
            "releasedAt" to result.releasedAt,
            "releasedBy" to result.releasedBy,
        )
    }

    @PostMapping("/admin/consumers/settlement/pause")
    fun pauseSettlementConsumer(): Map<String, Any> {
        val status = consumerControl.pauseSettlement()
        return mapOf(
            "available" to status.available,
            "listenerId" to status.listenerId,
            "running" to status.running,
            "pauseRequested" to status.pauseRequested,
            "containerPaused" to status.containerPaused,
            "gatePaused" to status.gatePaused,
        )
    }

    @PostMapping("/admin/consumers/settlement/resume")
    fun resumeSettlementConsumer(): Map<String, Any> {
        val status = consumerControl.resumeSettlement()
        return mapOf(
            "available" to status.available,
            "listenerId" to status.listenerId,
            "running" to status.running,
            "pauseRequested" to status.pauseRequested,
            "containerPaused" to status.containerPaused,
            "gatePaused" to status.gatePaused,
        )
    }

    @GetMapping("/admin/consumers/settlement/status")
    fun settlementConsumerStatus(): Map<String, Any> {
        val status = consumerControl.settlementStatus()
        return mapOf(
            "available" to status.available,
            "listenerId" to status.listenerId,
            "running" to status.running,
            "pauseRequested" to status.pauseRequested,
            "containerPaused" to status.containerPaused,
            "gatePaused" to status.gatePaused,
        )
    }

    @GetMapping("/admin/trades/{tradeId}")
    fun tradeLookup(@PathVariable tradeId: String): ResponseEntity<Map<String, Any>> {
        val trade = ledgerService.findTrade(tradeId) ?: return ResponseEntity.notFound().build()
        return ResponseEntity.ok(
            mapOf(
                "tradeId" to trade.tradeId,
                "entryId" to trade.entryId,
                "symbol" to trade.symbol,
                "engineSeq" to trade.engineSeq,
                "occurredAt" to trade.occurredAt,
            ),
        )
    }

    @PostMapping("/admin/corrections/requests")
    fun createCorrection(@RequestBody req: CreateCorrectionDto): Map<String, Any> {
        ledgerService.createCorrection(
            correctionId = req.correctionId,
            originalEntryId = req.originalEntryId,
            mode = req.mode,
            reason = req.reason,
            ticketId = req.ticketId,
            requestedBy = req.requestedBy,
        )
        return mapOf("status" to "PENDING", "correctionId" to req.correctionId)
    }

    @PostMapping("/admin/corrections/{correctionId}/approve")
    fun approveCorrection(
        @PathVariable correctionId: String,
        @RequestBody req: ApproveCorrectionDto,
    ): Map<String, Any?> {
        val correction = ledgerService.approveCorrection(correctionId, req.approver)
        return mapOf(
            "correctionId" to correction.correctionId,
            "status" to correction.status,
            "approver1" to correction.approver1,
            "approver2" to correction.approver2,
        )
    }

    @PostMapping("/admin/corrections/{correctionId}/apply")
    fun applyCorrection(
        @PathVariable correctionId: String,
        @RequestBody req: ApplyCorrectionDto,
    ): Map<String, Any> {
        val result = ledgerService.applyCorrection(correctionId, req.envelope.toModel())
        return mapOf(
            "applied" to result.applied,
            "entryId" to result.entryId,
            "reason" to result.reason,
        )
    }
}
