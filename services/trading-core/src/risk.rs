use crate::model::{now_millis, split_symbol, Order, OrderType, RejectCode, Side, SymbolMode};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Balance {
    pub available: i128,
    pub hold: i128,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reservation {
    pub currency: String,
    pub amount: i128,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RiskSnapshot {
    pub balances: Vec<BalanceRow>,
    pub reservations: Vec<ReservationRow>,
    pub open_orders: Vec<OpenOrderRow>,
    pub recent_commands: Vec<RecentCommandRow>,
    pub volatility_violations: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BalanceRow {
    pub user_id: String,
    pub currency: String,
    pub available: i128,
    pub hold: i128,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReservationRow {
    pub order_id: String,
    pub currency: String,
    pub amount: i128,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenOrderRow {
    pub user_id: String,
    pub symbol: String,
    pub count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecentCommandRow {
    pub user_id: String,
    pub symbol: String,
    pub timestamps_ms: Vec<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RiskConfig {
    pub max_open_orders_per_user_symbol: usize,
    pub max_commands_per_sec: usize,
    pub price_band_bps: u64,
    pub dynamic_collar_bps: u64,
    pub volatility_violation_threshold: u64,
}

impl Default for RiskConfig {
    fn default() -> Self {
        Self {
            max_open_orders_per_user_symbol: 100,
            max_commands_per_sec: 200,
            price_band_bps: 1_000,
            dynamic_collar_bps: 1_500,
            volatility_violation_threshold: 3,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RiskManager {
    pub cfg: RiskConfig,
    balances: HashMap<(String, String), Balance>,
    reservations: HashMap<String, Reservation>,
    open_orders: HashMap<(String, String), usize>,
    recent_commands: HashMap<(String, String), VecDeque<i64>>,
    pub volatility_violations: u64,
}

impl RiskManager {
    pub fn new(cfg: RiskConfig) -> Self {
        Self {
            cfg,
            balances: HashMap::new(),
            reservations: HashMap::new(),
            open_orders: HashMap::new(),
            recent_commands: HashMap::new(),
            volatility_violations: 0,
        }
    }

    pub fn set_balance(&mut self, user: &str, currency: &str, available: i128, hold: i128) {
        self.balances.insert(
            (user.to_string(), currency.to_string()),
            Balance { available, hold },
        );
    }

    pub fn get_balance(&self, user: &str, currency: &str) -> Balance {
        self.balances
            .get(&(user.to_string(), currency.to_string()))
            .cloned()
            .unwrap_or_default()
    }

    pub fn validate_and_reserve(
        &mut self,
        order: &Order,
        ref_price: Option<u64>,
        symbol_mode: SymbolMode,
        symbol: &str,
    ) -> Result<Option<SymbolMode>, RejectCode> {
        self.enforce_mode(order, symbol_mode)?;
        self.enforce_rate_limit(&order.user_id, symbol)?;
        self.enforce_open_order_limit(&order.user_id, symbol)?;
        self.enforce_price_band(order, ref_price)?;
        self.reserve(order, ref_price)?;
        self.bump_open_order(&order.user_id, symbol, 1);
        Ok(self.maybe_transition_mode(order, ref_price))
    }

    fn enforce_mode(&self, order: &Order, mode: SymbolMode) -> Result<(), RejectCode> {
        match mode {
            SymbolMode::HardHalt | SymbolMode::SoftHalt => Err(RejectCode::MarketHalted),
            SymbolMode::CancelOnly => match order.order_type {
                OrderType::Limit | OrderType::Market => Err(RejectCode::CancelOnly),
            },
            SymbolMode::Normal => Ok(()),
        }
    }

    fn enforce_rate_limit(&mut self, user_id: &str, symbol: &str) -> Result<(), RejectCode> {
        let key = (user_id.to_string(), symbol.to_string());
        let now = now_millis();
        let window_start = now - 1_000;

        let queue = self.recent_commands.entry(key).or_default();
        while let Some(ts) = queue.front().copied() {
            if ts < window_start {
                let _ = queue.pop_front();
            } else {
                break;
            }
        }
        if queue.len() >= self.cfg.max_commands_per_sec {
            return Err(RejectCode::TooManyRequests);
        }
        queue.push_back(now);
        Ok(())
    }

    fn enforce_open_order_limit(&self, user_id: &str, symbol: &str) -> Result<(), RejectCode> {
        let key = (user_id.to_string(), symbol.to_string());
        let open = self.open_orders.get(&key).copied().unwrap_or(0);
        if open >= self.cfg.max_open_orders_per_user_symbol {
            return Err(RejectCode::TooManyRequests);
        }
        Ok(())
    }

    fn enforce_price_band(
        &mut self,
        order: &Order,
        ref_price: Option<u64>,
    ) -> Result<(), RejectCode> {
        if order.order_type != OrderType::Limit {
            return Ok(());
        }
        let price = order.price.ok_or(RejectCode::Validation)?;
        if let Some(reference) = ref_price {
            let band = self.cfg.price_band_bps;
            let min = reference.saturating_mul(10_000 - band) / 10_000;
            let max = reference.saturating_mul(10_000 + band) / 10_000;
            if price < min || price > max {
                self.volatility_violations = self.volatility_violations.saturating_add(1);
                return Err(RejectCode::PriceBand);
            }
            self.volatility_violations = 0;
        }
        Ok(())
    }

    fn reserve(&mut self, order: &Order, ref_price: Option<u64>) -> Result<(), RejectCode> {
        let (base, quote) = split_symbol(&order.symbol)?;
        let (currency, needed) = match order.side {
            Side::Buy => {
                let px = match order.order_type {
                    OrderType::Limit => order.price.ok_or(RejectCode::Validation)?,
                    OrderType::Market => ref_price.ok_or(RejectCode::NoLiquidity)?,
                };
                let needed = i128::from(px.saturating_mul(order.remaining_qty));
                (quote, needed)
            }
            Side::Sell => (base, i128::from(order.remaining_qty)),
        };

        let key = (order.user_id.clone(), currency.clone());
        let bal = self.balances.entry(key).or_default();
        if bal.available < needed {
            return Err(RejectCode::InsufficientFunds);
        }
        bal.available -= needed;
        bal.hold += needed;

        self.reservations.insert(
            order.order_id.clone(),
            Reservation {
                currency,
                amount: needed,
            },
        );
        Ok(())
    }

    fn maybe_transition_mode(&self, _order: &Order, ref_price: Option<u64>) -> Option<SymbolMode> {
        if ref_price.is_none() {
            return None;
        }
        if self.volatility_violations >= self.cfg.volatility_violation_threshold {
            return Some(SymbolMode::CancelOnly);
        }
        None
    }

    pub fn on_trade(
        &mut self,
        buyer_user_id: &str,
        seller_user_id: &str,
        symbol: &str,
        price: u64,
        quantity: u64,
    ) {
        let (base, quote) = match split_symbol(symbol) {
            Ok(v) => v,
            Err(_) => return,
        };
        let quote_amount = i128::from(price.saturating_mul(quantity));
        let base_amount = i128::from(quantity);

        // buyer: hold quote -> base available
        let bq = self
            .balances
            .entry((buyer_user_id.to_string(), quote.clone()))
            .or_default();
        bq.hold -= quote_amount;

        let bb = self
            .balances
            .entry((buyer_user_id.to_string(), base.clone()))
            .or_default();
        bb.available += base_amount;

        // seller: hold base -> quote available
        let sb = self
            .balances
            .entry((seller_user_id.to_string(), base.clone()))
            .or_default();
        sb.hold -= base_amount;

        let sq = self
            .balances
            .entry((seller_user_id.to_string(), quote))
            .or_default();
        sq.available += quote_amount;
    }

    pub fn release_reservation(&mut self, order: &Order) {
        if let Some(res) = self.reservations.remove(&order.order_id) {
            let key = (order.user_id.clone(), res.currency);
            let bal = self.balances.entry(key).or_default();
            bal.hold -= res.amount;
            bal.available += res.amount;
            self.bump_open_order(&order.user_id, &order.symbol, -1);
        }
    }

    pub fn settle_reservation_consumed(&mut self, order: &Order, consumed: i128) {
        if let Some(res) = self.reservations.get_mut(&order.order_id) {
            res.amount -= consumed;
            if res.amount <= 0 {
                self.reservations.remove(&order.order_id);
                self.bump_open_order(&order.user_id, &order.symbol, -1);
            }
        }
    }

    fn bump_open_order(&mut self, user_id: &str, symbol: &str, delta: isize) {
        let key = (user_id.to_string(), symbol.to_string());
        let current = self.open_orders.get(&key).copied().unwrap_or(0);
        let next = if delta.is_negative() {
            current.saturating_sub(delta.unsigned_abs())
        } else {
            current.saturating_add(delta as usize)
        };
        self.open_orders.insert(key, next);
    }

    pub fn invariant_holds(&self) -> bool {
        self.balances
            .values()
            .all(|v| v.available >= 0 && v.hold >= 0)
    }

    pub fn to_snapshot(&self) -> RiskSnapshot {
        let mut balances = Vec::with_capacity(self.balances.len());
        for ((user_id, currency), bal) in &self.balances {
            balances.push(BalanceRow {
                user_id: user_id.clone(),
                currency: currency.clone(),
                available: bal.available,
                hold: bal.hold,
            });
        }
        balances.sort_by(|a, b| {
            (a.user_id.as_str(), a.currency.as_str())
                .cmp(&(b.user_id.as_str(), b.currency.as_str()))
        });

        let mut reservations = Vec::with_capacity(self.reservations.len());
        for (order_id, res) in &self.reservations {
            reservations.push(ReservationRow {
                order_id: order_id.clone(),
                currency: res.currency.clone(),
                amount: res.amount,
            });
        }
        reservations.sort_by(|a, b| a.order_id.cmp(&b.order_id));

        let mut open_orders = Vec::with_capacity(self.open_orders.len());
        for ((user_id, symbol), count) in &self.open_orders {
            open_orders.push(OpenOrderRow {
                user_id: user_id.clone(),
                symbol: symbol.clone(),
                count: *count,
            });
        }
        open_orders.sort_by(|a, b| {
            (a.user_id.as_str(), a.symbol.as_str()).cmp(&(b.user_id.as_str(), b.symbol.as_str()))
        });

        let mut recent_commands = Vec::with_capacity(self.recent_commands.len());
        for ((user_id, symbol), timestamps) in &self.recent_commands {
            recent_commands.push(RecentCommandRow {
                user_id: user_id.clone(),
                symbol: symbol.clone(),
                timestamps_ms: timestamps.iter().copied().collect(),
            });
        }
        recent_commands.sort_by(|a, b| {
            (a.user_id.as_str(), a.symbol.as_str()).cmp(&(b.user_id.as_str(), b.symbol.as_str()))
        });

        RiskSnapshot {
            balances,
            reservations,
            open_orders,
            recent_commands,
            volatility_violations: self.volatility_violations,
        }
    }

    pub fn from_snapshot(cfg: RiskConfig, snapshot: RiskSnapshot) -> Self {
        let mut mgr = Self::new(cfg);
        for b in snapshot.balances {
            mgr.balances.insert(
                (b.user_id, b.currency),
                Balance {
                    available: b.available,
                    hold: b.hold,
                },
            );
        }
        for r in snapshot.reservations {
            mgr.reservations.insert(
                r.order_id,
                Reservation {
                    currency: r.currency,
                    amount: r.amount,
                },
            );
        }
        for o in snapshot.open_orders {
            mgr.open_orders.insert((o.user_id, o.symbol), o.count);
        }
        for rc in snapshot.recent_commands {
            mgr.recent_commands
                .insert((rc.user_id, rc.symbol), VecDeque::from(rc.timestamps_ms));
        }
        mgr.volatility_violations = snapshot.volatility_violations;
        mgr
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Order, TimeInForce};

    fn buy_order(price: u64, qty: u64) -> Order {
        Order {
            order_id: "o1".to_string(),
            user_id: "u1".to_string(),
            symbol: "BTC-KRW".to_string(),
            side: Side::Buy,
            order_type: OrderType::Limit,
            tif: TimeInForce::Gtc,
            price: Some(price),
            original_qty: qty,
            remaining_qty: qty,
            accepted_seq: 1,
        }
    }

    #[test]
    fn reserve_prevents_overspend() {
        let mut risk = RiskManager::new(RiskConfig::default());
        risk.set_balance("u1", "KRW", 100, 0);
        let order = buy_order(50, 3);
        let err = risk
            .validate_and_reserve(&order, Some(50), SymbolMode::Normal, "BTC-KRW")
            .unwrap_err();
        assert_eq!(err, RejectCode::InsufficientFunds);
    }

    #[test]
    fn price_band_rejects_out_of_range() {
        let mut risk = RiskManager::new(RiskConfig {
            price_band_bps: 100,
            ..RiskConfig::default()
        });
        risk.set_balance("u1", "KRW", 1_000_000, 0);
        let order = buy_order(150, 1);
        let err = risk
            .validate_and_reserve(&order, Some(100), SymbolMode::Normal, "BTC-KRW")
            .unwrap_err();
        assert_eq!(err, RejectCode::PriceBand);
    }

    #[test]
    fn no_negative_balances_after_reserve_release() {
        let mut risk = RiskManager::new(RiskConfig::default());
        risk.set_balance("u1", "KRW", 1_000, 0);
        let order = buy_order(100, 1);
        let _ = risk.validate_and_reserve(&order, Some(100), SymbolMode::Normal, "BTC-KRW");
        risk.release_reservation(&order);
        assert!(risk.invariant_holds());
    }
}
