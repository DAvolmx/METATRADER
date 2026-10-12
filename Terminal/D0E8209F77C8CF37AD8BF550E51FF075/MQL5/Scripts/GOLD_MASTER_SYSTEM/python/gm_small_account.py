"""Read-only feasibility check for a hypothetical small account."""
import math
from gm_feed import quote_valid


def feasibility(api, symbol, balance=10.0, risk_pct=1.0, stop_distance=None, now=None):
    """Ask MT5 for cash loss and margin at minimum volume; never send an order.

    stop_distance is a price distance, not points. No commission or gap guarantee
    is implied. A missing input or broker calculation yields unknown, not approval.
    """
    out = {"balance": balance, "risk_pct": risk_pct, "symbol": symbol,
           "status": "unknown", "execution": "disabled"}
    if (not all(math.isfinite(x) for x in (balance, risk_pct)) or
            balance <= 0 or not 0 < risk_pct <= 100):
        out["reason"] = "invalid_inputs"; return out
    info, tick = api.symbol_info(symbol), api.symbol_info_tick(symbol)
    if info is None or not quote_valid(tick,now):
        out["reason"] = "market_data_unavailable"; return out
    volume = float(info.volume_min)
    point = float(info.point)
    if not (math.isfinite(volume) and volume > 0 and math.isfinite(point) and point > 0):
        out["reason"] = "invalid_contract"; return out
    if stop_distance is None or not math.isfinite(stop_distance) or stop_distance <= 0:
        out["reason"] = "stop_distance_required"; return out
    # A BUY enters at Ask but its protective stop is checked against Bid;
    # a SELL enters at Bid while its protective stop is checked against Ask.
    legal_min = max(float(info.trade_stops_level)*point, point) + (tick.ask-tick.bid)
    out.update(min_volume=volume, stop_distance=stop_distance,
               broker_min_stop_distance=legal_min, risk_budget=balance*risk_pct/100)
    if stop_distance < legal_min:
        out["status"] = "infeasible"; out["reason"] = "stop_below_broker_minimum"; return out
    sides = []
    for kind, entry, stop in ((api.ORDER_TYPE_BUY,tick.ask,tick.ask-stop_distance),
                              (api.ORDER_TYPE_SELL,tick.bid,tick.bid+stop_distance)):
        loss = api.order_calc_profit(kind,symbol,volume,entry,stop)
        margin = api.order_calc_margin(kind,symbol,volume,entry)
        if (loss is None or margin is None or not math.isfinite(loss) or
                not math.isfinite(margin) or loss >= 0 or margin < 0):
            out["reason"] = "broker_calculation_unavailable"; return out
        sides.append((-float(loss),float(margin)))
    out["minimum_lot_loss"] = max(s[0] for s in sides)
    out["minimum_lot_margin"] = max(s[1] for s in sides)
    out["margin_within_hypothetical_balance"] = out["minimum_lot_margin"] <= balance
    out["entry_margin_note"] = "estimate_only; existing_positions_and_order_check_not_included"
    out["minimum_lot_risk_pct"] = 100*out["minimum_lot_loss"]/balance
    out["estimated_max_stop_for_budget"] = (
        stop_distance*out["risk_budget"]/out["minimum_lot_loss"])
    out["estimated_max_stop_as_fraction_of_illustrative"] = (
        out["estimated_max_stop_for_budget"]/stop_distance)
    if out["minimum_lot_loss"] > out["risk_budget"]:
        out["status"] = "infeasible"; out["reason"] = "minimum_lot_exceeds_risk_budget"
    elif out["minimum_lot_margin"] > balance:
        out["status"] = "infeasible"; out["reason"] = "minimum_lot_exceeds_hypothetical_balance"
    else:
        # Costs, historical slippage and the actual account's free margin remain unknown.
        out["status"] = "preliminary_only"; out["reason"] = "costs_and_slippage_uncalibrated"
    return out
