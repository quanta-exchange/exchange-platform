package com.quanta.exchange.ledger

data class HealthResponse(val service: String, val status: String)

fun health(): HealthResponse = HealthResponse(service = "ledger-service", status = "ok")

fun main() {
    println(health())
}
