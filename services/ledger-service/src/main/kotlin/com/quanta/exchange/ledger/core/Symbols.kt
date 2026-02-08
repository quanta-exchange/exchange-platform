package com.quanta.exchange.ledger.core

data class SymbolParts(
    val base: String,
    val quote: String,
)

fun parseSymbol(symbol: String): SymbolParts {
    val parts = symbol.split("-")
    require(parts.size == 2 && parts[0].isNotBlank() && parts[1].isNotBlank()) {
        "symbol must be BASE-QUOTE"
    }
    return SymbolParts(parts[0], parts[1])
}
