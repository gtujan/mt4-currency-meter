"""Pure computation: quotes -> currency-strength-meter state.

No I/O. `compute()` takes the raw {"ts":.., "quotes": {...}} snapshot posted
by MT4 (or the mock feed) and returns the JSON-serializable state dict that
the server broadcasts to browsers over /ws, per the spec's data contract.
"""

from symbols import (
    PAIRS, CURRENCIES, GOLD, GOLD_DEFAULT_RANK,
    base_of, quote_of, lookup_rank,
)


def _pip_size(pair: str) -> float:
    return 0.01 if pair.endswith("JPY") else 0.0001


def _point_size(pair: str) -> float:
    # One MT4 "point" = 1/10 pip on 5-digit (3-digit for JPY) brokers.
    return _pip_size(pair) / 10.0


def _pair_active(q: dict) -> bool:
    if not q:
        return False
    bid, high, low = q.get("bid"), q.get("high"), q.get("low")
    if bid is None or high is None or low is None:
        return False
    if bid <= 0 or high <= 0 or low <= 0:
        return False
    if high <= low:
        return False
    return True


def compute(quotes: dict, ts: float = 0, stale: bool = False) -> dict:
    """quotes: {"EURUSD": {"bid":..,"ask":..,"high":..,"low":..}, ...}"""

    # --- per-pair pos/rank -------------------------------------------------
    pair_calc = {}  # pair -> dict(pos, rank_base, rank_quote) or None if inactive
    for p in PAIRS:
        q = quotes.get(p)
        if not _pair_active(q):
            pair_calc[p] = None
            continue
        bid, high, low = q["bid"], q["high"], q["low"]
        pos = (bid - low) / (high - low)
        rank_base = lookup_rank(100 * pos)
        rank_quote = 9 - rank_base
        pair_calc[p] = {"pos": pos, "rank_base": rank_base, "rank_quote": rank_quote}

    # --- currency strength S[c] ---------------------------------------------
    strength = {}
    for c in CURRENCIES:
        contribs = []
        for p in PAIRS:
            calc = pair_calc[p]
            if calc is None:
                continue
            if base_of(p) == c:
                contribs.append(calc["rank_base"])
            elif quote_of(p) == c:
                contribs.append(calc["rank_quote"])
        strength[c] = (sum(contribs) / len(contribs)) if contribs else 0.0

    # --- gold (standalone, does not feed the 8 currencies) ------------------
    gold_q = quotes.get(GOLD)
    gold_rank = None
    gold_pos = None
    if _pair_active(gold_q):
        bid, high, low = gold_q["bid"], gold_q["high"], gold_q["low"]
        gold_pos = (bid - low) / (high - low)
        gold_rank = lookup_rank(100 * gold_pos)
        strength["XAU"] = gold_rank

    # --- signal threshold -----------------------------------------------------
    thr_rank_for_avg = gold_rank if gold_rank is not None else GOLD_DEFAULT_RANK
    mean_all = (sum(strength[c] for c in CURRENCIES) + thr_rank_for_avg) / (len(CURRENCIES) + 1)
    threshold = 0.75 * mean_all

    # --- momentum M[c] ----------------------------------------------------
    momentum = {}
    for c in CURRENCIES:
        contribs = []
        for p in PAIRS:
            calc = pair_calc[p]
            if calc is None:
                continue
            if base_of(p) == c:
                contribs.append(calc["pos"])
            elif quote_of(p) == c:
                contribs.append(1 - calc["pos"])
        pct = (sum(contribs) / len(contribs)) if contribs else 0.0
        if pct >= 0.65:
            state = "STRONG"
        elif pct <= 0.35:
            state = "WEAK"
        else:
            state = ""
        momentum[c] = {"pct": pct, "state": state}

    # --- per-pair signal/gauge/delta ----------------------------------------
    pairs_out = []
    for p in PAIRS:
        base, quote = base_of(p), quote_of(p)
        q = quotes.get(p) or {}
        calc = pair_calc[p]
        active = calc is not None
        entry = {
            "pair": p,
            "base": base,
            "quote": quote,
            "active": active,
            "bid": q.get("bid"),
            "ask": q.get("ask"),
            "high": q.get("high"),
            "low": q.get("low"),
        }
        # Spread in whole points, as MT4 shows it. Prefer the EA's authoritative
        # value; fall back to (ask-bid)/point for feeds that don't send it.
        if q.get("spread") is not None:
            entry["spread"] = int(round(q["spread"]))
        elif q.get("bid") is not None and q.get("ask") is not None:
            entry["spread"] = int(round((q["ask"] - q["bid"]) / _point_size(p)))
        else:
            entry["spread"] = None

        if active:
            s_base, s_quote = strength[base], strength[quote]
            delta = s_base - s_quote
            if delta >= threshold:
                signal = "BUY"
            elif delta <= -threshold:
                signal = "SELL"
            else:
                signal = "WAIT"
            entry.update({
                "signal": signal,
                "sBase": round(s_base, 2),
                "sQuote": round(s_quote, 2),
                "buy": round(calc["pos"], 4),
                "sell": round(1 - calc["pos"], 4),
                "delta": round(delta, 2),
            })
        else:
            entry.update({
                "signal": None,
                "sBase": None,
                "sQuote": None,
                "buy": None,
                "sell": None,
                "delta": None,
            })
        pairs_out.append(entry)

    # --- gold (XAUUSD) as a standalone signal row, mirroring OPENBIDASK -----
    # XAU vs USD: uses gold's own rank when its quote is live, else the
    # workbook's cached default rank (GOLD_DEFAULT_RANK), same as the
    # threshold average does.
    gold_active = gold_rank is not None
    gold_eff_rank = gold_rank if gold_active else GOLD_DEFAULT_RANK
    usd_str = strength["USD"]
    gold_delta = gold_eff_rank - usd_str
    if gold_delta >= threshold:
        gold_signal = "BUY"
    elif gold_delta <= -threshold:
        gold_signal = "SELL"
    else:
        gold_signal = "WAIT"
    gq = gold_q or {}
    gold = {
        "pair": GOLD,
        "base": "XAU",
        "quote": "USD",
        "active": gold_active,
        "bid": gq.get("bid"),
        "ask": gq.get("ask"),
        "high": gq.get("high"),
        "low": gq.get("low"),
        "spread": (int(round(gq["spread"])) if gq.get("spread") is not None
                   else (int(round((gq["ask"] - gq["bid"]) / 0.01))
                         if gq.get("ask") is not None and gq.get("bid") is not None else None)),
        "signal": gold_signal,
        "sBase": round(gold_eff_rank, 2),
        "sQuote": round(usd_str, 2),
        "buy": round(gold_pos, 4) if gold_pos is not None else None,
        "sell": round(1 - gold_pos, 4) if gold_pos is not None else None,
        "delta": round(gold_delta, 2),
    }

    strength_rounded = {c: round(v, 2) for c, v in strength.items()}
    ranked = sorted(
        ((c, strength_rounded[c]) for c in CURRENCIES),
        key=lambda kv: kv[1],
        reverse=True,
    )

    return {
        "ts": ts,
        "stale": stale,
        "strength": strength_rounded,
        "ranked": ranked,
        "pairs": pairs_out,
        "gold": gold,
        "momentum": {c: {"pct": round(m["pct"], 4), "state": m["state"]} for c, m in momentum.items()},
        "threshold": round(threshold, 2),
    }
