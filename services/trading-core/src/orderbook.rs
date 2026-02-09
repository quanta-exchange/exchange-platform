use crate::model::{Order, OrderType, Side};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, VecDeque};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TradeFill {
    pub maker_order_id: String,
    pub taker_order_id: String,
    pub maker_user_id: String,
    pub taker_user_id: String,
    pub price: u64,
    pub quantity: u64,
    pub maker_remaining_after: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct OrderBook {
    bids: BTreeMap<u64, VecDeque<String>>,
    asks: BTreeMap<u64, VecDeque<String>>,
    orders: HashMap<String, Order>,
}

impl OrderBook {
    pub fn insert(&mut self, order: Order) {
        let order_id = order.order_id.clone();
        let price = order.price.unwrap_or(0);
        match order.side {
            Side::Buy => {
                self.bids
                    .entry(price)
                    .or_default()
                    .push_back(order_id.clone());
            }
            Side::Sell => {
                self.asks
                    .entry(price)
                    .or_default()
                    .push_back(order_id.clone());
            }
        }
        self.orders.insert(order_id, order);
    }

    pub fn cancel(&mut self, order_id: &str) -> Option<Order> {
        let order = self.orders.remove(order_id)?;
        let price = order.price.unwrap_or(0);
        let levels = match order.side {
            Side::Buy => &mut self.bids,
            Side::Sell => &mut self.asks,
        };
        if let Some(queue) = levels.get_mut(&price) {
            queue.retain(|id| id != order_id);
            if queue.is_empty() {
                levels.remove(&price);
            }
        }
        Some(order)
    }

    pub fn best_bid(&self) -> Option<u64> {
        self.bids.keys().next_back().copied()
    }

    pub fn best_ask(&self) -> Option<u64> {
        self.asks.keys().next().copied()
    }

    pub fn best_opposite(&self, side: Side) -> Option<u64> {
        match side {
            Side::Buy => self.best_ask(),
            Side::Sell => self.best_bid(),
        }
    }

    pub fn open_orders(&self) -> usize {
        self.orders.len()
    }

    pub fn all_orders(&self) -> Vec<Order> {
        let mut values: Vec<Order> = self.orders.values().cloned().collect();
        values.sort_by(|a, b| a.order_id.cmp(&b.order_id));
        values
    }

    pub fn get_order(&self, order_id: &str) -> Option<&Order> {
        self.orders.get(order_id)
    }

    pub fn apply_fill(&mut self, order_id: &str, quantity: u64) -> Option<Order> {
        let mut remove = false;
        {
            let order = self.orders.get_mut(order_id)?;
            order.remaining_qty = order.remaining_qty.saturating_sub(quantity);
            if order.remaining_qty == 0 {
                remove = true;
            }
        }
        if remove {
            self.cancel(order_id)
        } else {
            self.orders.get(order_id).cloned()
        }
    }

    pub fn match_order(&mut self, incoming: &mut Order) -> Vec<TradeFill> {
        let mut fills = Vec::new();

        while incoming.remaining_qty > 0 {
            let price_level = match incoming.side {
                Side::Buy => self.best_ask(),
                Side::Sell => self.best_bid(),
            };

            let level_price = match price_level {
                Some(p) => p,
                None => break,
            };

            if !self.crosses(incoming, level_price) {
                break;
            }

            let maker_id = match self.peek_front_maker(incoming.side, level_price) {
                Some(v) => v,
                None => {
                    self.cleanup_empty_level(incoming.side, level_price);
                    continue;
                }
            };

            if maker_id == incoming.order_id {
                break;
            }

            let (maker_user_id, maker_remaining) = match self.orders.get(&maker_id) {
                Some(m) => (m.user_id.clone(), m.remaining_qty),
                None => {
                    self.pop_front_maker(incoming.side, level_price);
                    continue;
                }
            };

            let fill_qty = incoming.remaining_qty.min(maker_remaining);
            if fill_qty == 0 {
                self.pop_front_maker(incoming.side, level_price);
                continue;
            }

            incoming.remaining_qty -= fill_qty;

            let mut maker_remaining_after = 0;
            if let Some(maker) = self.orders.get_mut(&maker_id) {
                maker.remaining_qty -= fill_qty;
                maker_remaining_after = maker.remaining_qty;
                if maker.remaining_qty == 0 {
                    self.orders.remove(&maker_id);
                    self.pop_front_maker(incoming.side, level_price);
                }
            }

            fills.push(TradeFill {
                maker_order_id: maker_id,
                taker_order_id: incoming.order_id.clone(),
                maker_user_id,
                taker_user_id: incoming.user_id.clone(),
                price: level_price,
                quantity: fill_qty,
                maker_remaining_after,
            });

            self.cleanup_empty_level(incoming.side, level_price);
        }

        fills
    }

    fn crosses(&self, incoming: &Order, resting_price: u64) -> bool {
        match incoming.order_type {
            OrderType::Market => true,
            OrderType::Limit => match incoming.side {
                Side::Buy => incoming.price.unwrap_or(0) >= resting_price,
                Side::Sell => incoming.price.unwrap_or(0) <= resting_price,
            },
        }
    }

    fn peek_front_maker(&self, incoming_side: Side, price: u64) -> Option<String> {
        let levels = match incoming_side {
            Side::Buy => &self.asks,
            Side::Sell => &self.bids,
        };
        levels.get(&price).and_then(|q| q.front().cloned())
    }

    fn pop_front_maker(&mut self, incoming_side: Side, price: u64) {
        let levels = match incoming_side {
            Side::Buy => &mut self.asks,
            Side::Sell => &mut self.bids,
        };
        if let Some(queue) = levels.get_mut(&price) {
            queue.pop_front();
        }
    }

    fn cleanup_empty_level(&mut self, incoming_side: Side, price: u64) {
        let levels = match incoming_side {
            Side::Buy => &mut self.asks,
            Side::Sell => &mut self.bids,
        };
        if levels.get(&price).map(|q| q.is_empty()).unwrap_or(false) {
            levels.remove(&price);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Side, TimeInForce};

    fn mk(id: &str, side: Side, price: u64, qty: u64, user: &str) -> Order {
        Order {
            order_id: id.to_string(),
            user_id: user.to_string(),
            symbol: "BTC-KRW".to_string(),
            side,
            order_type: OrderType::Limit,
            tif: TimeInForce::Gtc,
            price: Some(price),
            original_qty: qty,
            remaining_qty: qty,
            accepted_seq: 1,
        }
    }

    #[test]
    fn fifo_on_same_level() {
        let mut book = OrderBook::default();
        book.insert(mk("ask-1", Side::Sell, 100, 10, "maker1"));
        book.insert(mk("ask-2", Side::Sell, 100, 10, "maker2"));

        let mut taker = mk("buy-1", Side::Buy, 100, 10, "taker");
        let fills = book.match_order(&mut taker);

        assert_eq!(fills.len(), 1);
        assert_eq!(fills[0].maker_order_id, "ask-1");
    }

    #[test]
    fn best_price_priority_across_levels() {
        let mut book = OrderBook::default();
        book.insert(mk("ask-110", Side::Sell, 110, 10, "m1"));
        book.insert(mk("ask-100", Side::Sell, 100, 10, "m2"));

        let mut taker = mk("buy", Side::Buy, 110, 10, "t");
        let fills = book.match_order(&mut taker);

        assert_eq!(fills[0].price, 100);
        assert_eq!(fills[0].maker_order_id, "ask-100");
    }

    #[test]
    fn partial_fill_updates_remaining_quantity() {
        let mut book = OrderBook::default();
        book.insert(mk("ask", Side::Sell, 100, 15, "m"));

        let mut taker = mk("buy", Side::Buy, 100, 10, "t");
        let fills = book.match_order(&mut taker);

        assert_eq!(fills[0].quantity, 10);
        let remaining = book
            .all_orders()
            .into_iter()
            .find(|o| o.order_id == "ask")
            .unwrap();
        assert_eq!(remaining.remaining_qty, 5);
    }

    #[test]
    fn cancel_removes_order() {
        let mut book = OrderBook::default();
        book.insert(mk("ask", Side::Sell, 100, 10, "m"));
        assert!(book.cancel("ask").is_some());
        assert!(book.cancel("ask").is_none());
        assert_eq!(book.open_orders(), 0);
    }
}
