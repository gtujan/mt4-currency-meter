#!/usr/bin/env bash
#
# Currency Strength Meter — self-contained installer.
#
# One-liner:
#   curl -fsSL <URL>/install.sh | bash
# or download then run:
#   bash install.sh
#
# Installs into $CM_DIR (default: $HOME/currency_meter). Override with:
#   CM_DIR=/path/to/dir  curl -fsSL <URL>/install.sh | bash
#
# All source files are embedded below — no git clone, no extra downloads.
# The bridge/web app runs on any OS with Python 3.8+. MT4-specific setup
# (macOS/Wine, port 80, launchd) is documented in the installed INSTALL.md.

set -euo pipefail

CM_DIR="${CM_DIR:-$HOME/currency_meter}"

c()   { printf '\033[%sm%s\033[0m' "$1" "$2"; }
say() { printf '%s %s\n' "$(c 36 '==>')" "$1"; }
ok()  { printf '%s %s\n' "$(c 32 '✓')" "$1"; }
die() { printf '%s %s\n' "$(c 31 '✗')" "$1" >&2; exit 1; }

say "$(c 1 'Currency Strength Meter installer')"

# ---- prerequisites ----
command -v python3 >/dev/null 2>&1 || die "python3 not found — install Python 3.8+ and re-run."
PYV="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
python3 -c 'import sys;sys.exit(0 if sys.version_info[:2]>=(3,8) else 1)' \
  || die "Python $PYV is too old; need 3.8+."
python3 -m venv --help >/dev/null 2>&1 \
  || die "python3 'venv' module missing. On Debian/Ubuntu: sudo apt-get install python3-venv"
ok "python3 $PYV"

# ---- target directory ----
if [ -e "$CM_DIR" ] && [ -n "$(ls -A "$CM_DIR" 2>/dev/null)" ]; then
  say "$(c 33 "note:") $CM_DIR exists and is not empty — files will be overwritten."
fi
mkdir -p "$CM_DIR"
say "Installing into $(c 1 "$CM_DIR")"

# ---- project files (embedded) ----
mkdir -p "$CM_DIR/bridge"
cat > "$CM_DIR/bridge/server.py" <<'___CM_EOF___'
"""aiohttp bridge server: receives MT4 quote snapshots, recomputes the
currency-strength meter, and broadcasts state to browsers over WebSocket.

Routes:
  POST /tick   - {"ts":.., "quotes": {...}} snapshot from MT4 (or mock_feed.py)
  GET  /ws     - WebSocket; server pushes computed state on every update
  GET  /state  - latest computed state as JSON (debug/polling convenience)
  GET  /       - serves web/index.html

Only dependency: aiohttp. Bind: 127.0.0.1:8010.
"""

import asyncio
import json
import os
import time

from aiohttp import web, WSMsgType

from meter import compute

HOST = os.environ.get("METER_HOST", "127.0.0.1")
PORT = int(os.environ.get("METER_PORT", "8010"))
STALE_AFTER_S = 5
WEB_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "web")

latest_quotes: dict = {}
last_tick_time: float = 0.0
last_state: dict = compute({})
websockets: set = set()


def recompute(stale: bool = False) -> dict:
    global last_state
    last_state = compute(latest_quotes, ts=last_tick_time, stale=stale)
    return last_state


async def broadcast(state: dict):
    if not websockets:
        return
    msg = json.dumps(state)
    dead = set()
    for ws in websockets:
        try:
            await ws.send_str(msg)
        except Exception:
            dead.add(ws)
    websockets.difference_update(dead)


async def handle_tick(request: web.Request) -> web.Response:
    global latest_quotes, last_tick_time
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"error": "invalid JSON"}, status=400)

    quotes = body.get("quotes")
    if not isinstance(quotes, dict):
        return web.json_response({"error": "missing 'quotes' object"}, status=400)

    latest_quotes = quotes
    last_tick_time = body.get("ts") or time.time()
    state = recompute(stale=False)
    await broadcast(state)
    return web.json_response({"ok": True})


async def handle_state(request: web.Request) -> web.Response:
    stale = (time.time() - last_tick_time) > STALE_AFTER_S if last_tick_time else True
    if stale != last_state.get("stale"):
        recompute(stale=stale)
    return web.json_response(last_state)


async def handle_ws(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    websockets.add(ws)
    try:
        stale = (time.time() - last_tick_time) > STALE_AFTER_S if last_tick_time else True
        await ws.send_str(json.dumps(recompute(stale=stale)))
        async for msg in ws:
            if msg.type == WSMsgType.ERROR:
                break
    finally:
        websockets.discard(ws)
    return ws


async def handle_index(request: web.Request) -> web.Response:
    return web.FileResponse(os.path.join(WEB_DIR, "index.html"))


async def stale_watcher(app: web.Application):
    """Background task: mark state stale and push it if no tick for >5s."""
    was_stale = False
    while True:
        await asyncio.sleep(1)
        if not last_tick_time:
            continue
        is_stale = (time.time() - last_tick_time) > STALE_AFTER_S
        if is_stale != was_stale:
            was_stale = is_stale
            state = recompute(stale=is_stale)
            await broadcast(state)


async def start_background_tasks(app: web.Application):
    app["stale_watcher"] = asyncio.create_task(stale_watcher(app))


async def cleanup_background_tasks(app: web.Application):
    app["stale_watcher"].cancel()


def make_app() -> web.Application:
    app = web.Application()
    app.router.add_post("/tick", handle_tick)
    app.router.add_get("/ws", handle_ws)
    app.router.add_get("/state", handle_state)
    app.router.add_get("/", handle_index)
    app.on_startup.append(start_background_tasks)
    app.on_cleanup.append(cleanup_background_tasks)
    return app


if __name__ == "__main__":
    web.run_app(make_app(), host=HOST, port=PORT)
___CM_EOF___
mkdir -p "$CM_DIR/bridge"
cat > "$CM_DIR/bridge/meter.py" <<'___CM_EOF___'
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
___CM_EOF___
mkdir -p "$CM_DIR/bridge"
cat > "$CM_DIR/bridge/symbols.py" <<'___CM_EOF___'
"""Static definitions for the currency-strength meter: pairs, currencies,
LOOKUP thresholds/ranks, and base/quote helpers.

Ported from the OPENBIDASK / MAIN sheets of Excel-Currency-Meter-2026.xlsx.
"""

# 28 FX pairs, exact order matching MAIN sheet columns C..AD.
PAIRS = [
    "AUDCAD", "AUDCHF", "AUDJPY", "AUDNZD", "AUDUSD",
    "CADCHF", "CADJPY",
    "CHFJPY",
    "EURAUD", "EURCAD", "EURCHF", "EURGBP", "EURJPY", "EURNZD", "EURUSD",
    "GBPAUD", "GBPCAD", "GBPCHF", "GBPJPY", "GBPNZD", "GBPUSD",
    "NZDCAD", "NZDCHF", "NZDJPY", "NZDUSD",
    "USDCAD", "USDCHF", "USDJPY",
]

# 8 currencies, display/header order.
CURRENCIES = ["USD", "EUR", "GBP", "CHF", "CAD", "AUD", "NZD", "JPY"]

# Standalone extra instrument (not one of the 8 currencies, not in PAIRS).
GOLD = "XAUUSD"
GOLD_DEFAULT_RANK = 7.0  # workbook's cached fallback when gold quote is absent

# Excel LOOKUP(100*pos, THRESHOLDS, RANKS) semantics: rank of the largest
# threshold <= 100*pos.
THRESHOLDS = [0, 3, 10, 25, 40, 50, 60, 75, 90, 97]
RANKS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]


def base_of(pair: str) -> str:
    return pair[:3]


def quote_of(pair: str) -> str:
    return pair[3:]


def lookup_rank(pct: float) -> float:
    """Excel LOOKUP(pct, THRESHOLDS, RANKS): rank of the largest threshold
    <= pct. THRESHOLDS is sorted ascending, matching Excel's LOOKUP
    assumption (approximate match uses the last value <= lookup value).
    """
    rank = RANKS[0]
    for t, r in zip(THRESHOLDS, RANKS):
        if pct >= t:
            rank = r
        else:
            break
    return rank
___CM_EOF___
mkdir -p "$CM_DIR/bridge"
cat > "$CM_DIR/bridge/mock_feed.py" <<'___CM_EOF___'
"""Dev feeder: replays bridge/sample_quotes.json to POST /tick so the UI
can be exercised without a live MT4 connection.

Usage:
  python bridge/mock_feed.py            # loop, POSTing every ~1s with tiny jitter
  python bridge/mock_feed.py --once     # POST a single tick and exit
  python bridge/mock_feed.py --test     # no server needed: run the golden
                                         # meter.compute() assertions and exit
"""

import json
import os
import random
import sys
import time
import urllib.request

SAMPLE_PATH = os.path.join(os.path.dirname(__file__), "sample_quotes.json")
# Honor the same env vars as server.py so both stay aligned (default 127.0.0.1:8010).
_HOST = os.environ.get("METER_HOST", "127.0.0.1")
_PORT = os.environ.get("METER_PORT", "8010")
SERVER_URL = f"http://{_HOST}:{_PORT}/tick"


def load_sample() -> dict:
    with open(SAMPLE_PATH) as f:
        return json.load(f)


def jittered(quotes: dict, pct: float = 0.0003) -> dict:
    """Nudge bid/ask by a tiny random amount (within the high/low range)
    so a running mock feed looks alive, without invalidating pos/rank math."""
    out = {}
    for pair, q in quotes.items():
        bid, ask, high, low = q["bid"], q["ask"], q["high"], q["low"]
        spread = ask - bid
        span = (high - low) or bid * pct
        nudge = random.uniform(-1, 1) * span * pct
        new_bid = min(max(bid + nudge, low), high)
        out[pair] = {
            "bid": round(new_bid, 6),
            "ask": round(new_bid + spread, 6),
            "high": high,
            "low": low,
        }
    return out


def post_tick(quotes: dict):
    payload = json.dumps({"ts": time.time(), "quotes": quotes}).encode()
    req = urllib.request.Request(
        SERVER_URL, data=payload, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return resp.status, resp.read()


def run_test():
    """Golden-value assertions, importable/runnable without a server."""
    sys.path.insert(0, os.path.dirname(__file__))
    from meter import compute

    sample = load_sample()
    state = compute(sample["quotes"])

    expected_strength = {
        "USD": 1.71, "EUR": 4.86, "GBP": 5.14, "CHF": 3.86,
        "CAD": 2.71, "AUD": 7.00, "NZD": 8.14, "JPY": 2.57,
    }
    for c, exp in expected_strength.items():
        actual = state["strength"][c]
        assert actual == exp, f"strength[{c}] = {actual}, expected {exp}"

    order = [c for c, _ in state["ranked"]]
    expected_order = ["NZD", "AUD", "GBP", "EUR", "CHF", "CAD", "JPY", "USD"]
    assert order == expected_order, f"ranked order = {order}"

    by_pair = {p["pair"]: p for p in state["pairs"]}
    checks = [("AUDCAD", "BUY", 4.29), ("EURUSD", "WAIT", 3.14), ("NZDUSD", "BUY", 6.43)]
    for pair, sig, delta in checks:
        p = by_pair[pair]
        assert p["signal"] == sig, f"{pair} signal = {p['signal']}, expected {sig}"
        assert abs(p["delta"] - delta) < 0.01, f"{pair} delta = {p['delta']}, expected {delta}"

    print("ALL GOLDEN ASSERTIONS PASSED")
    print("strength:", state["strength"])
    print("ranked:", order)
    print("threshold:", state["threshold"])


def main():
    args = sys.argv[1:]
    if "--test" in args:
        run_test()
        return

    sample = load_sample()
    quotes = sample["quotes"]

    if "--once" in args:
        status, body = post_tick(quotes)
        print(f"POST /tick -> {status} {body}")
        return

    print(f"Feeding {SERVER_URL} every ~1s (Ctrl+C to stop)...")
    try:
        while True:
            status, _ = post_tick(jittered(quotes))
            print(f"tick sent -> {status}")
            time.sleep(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
___CM_EOF___
mkdir -p "$CM_DIR/bridge"
cat > "$CM_DIR/bridge/test_meter.py" <<'___CM_EOF___'
"""Golden test: meter.compute() against bridge/sample_quotes.json, the
cached values captured from the live workbook.

Run with: python -m pytest bridge/test_meter.py -v
or standalone: python bridge/test_meter.py
"""

import json
import os

from meter import compute

SAMPLE_PATH = os.path.join(os.path.dirname(__file__), "sample_quotes.json")

EXPECTED_STRENGTH = {
    "USD": 1.71, "EUR": 4.86, "GBP": 5.14, "CHF": 3.86,
    "CAD": 2.71, "AUD": 7.00, "NZD": 8.14, "JPY": 2.57,
}

EXPECTED_RANKED_ORDER = ["NZD", "AUD", "GBP", "EUR", "CHF", "CAD", "JPY", "USD"]


def _load_sample():
    with open(SAMPLE_PATH) as f:
        return json.load(f)


def test_golden_strengths():
    sample = _load_sample()
    state = compute(sample["quotes"])
    for c, expected in EXPECTED_STRENGTH.items():
        assert state["strength"][c] == expected, (c, state["strength"][c], expected)


def test_golden_ranked_order():
    sample = _load_sample()
    state = compute(sample["quotes"])
    order = [c for c, _ in state["ranked"]]
    assert order == EXPECTED_RANKED_ORDER, order


def test_golden_signals():
    sample = _load_sample()
    state = compute(sample["quotes"])
    by_pair = {p["pair"]: p for p in state["pairs"]}

    audcad = by_pair["AUDCAD"]
    assert audcad["signal"] == "BUY", audcad
    assert abs(audcad["delta"] - 4.29) < 0.01, audcad["delta"]

    eurusd = by_pair["EURUSD"]
    assert eurusd["signal"] == "WAIT", eurusd
    assert abs(eurusd["delta"] - 3.14) < 0.01, eurusd["delta"]

    nzdusd = by_pair["NZDUSD"]
    assert nzdusd["signal"] == "BUY", nzdusd
    assert abs(nzdusd["delta"] - 6.43) < 0.01, nzdusd["delta"]


def test_missing_gold_does_not_crash():
    sample = _load_sample()
    quotes = dict(sample["quotes"])
    quotes.pop("XAUUSD", None)
    state = compute(quotes)
    assert "XAU" not in state["strength"]
    assert state["threshold"] > 0


def test_inactive_pair_excluded():
    sample = _load_sample()
    quotes = dict(sample["quotes"])
    quotes["EURUSD"] = {"bid": 1.0, "ask": 1.0, "high": 1.0, "low": 1.0}  # high<=low
    state = compute(quotes)
    by_pair = {p["pair"]: p for p in state["pairs"]}
    assert by_pair["EURUSD"]["active"] is False
    assert by_pair["EURUSD"]["signal"] is None


def _run_all():
    tests = [v for k, v in globals().items() if k.startswith("test_")]
    for t in tests:
        t()
        print(f"PASS {t.__name__}")
    print(f"\nAll {len(tests)} tests passed.")
    sample = _load_sample()
    state = compute(sample["quotes"])
    print("\nGolden strengths:", state["strength"])
    print("Ranked order:", [c for c, _ in state["ranked"]])
    print("Threshold:", state["threshold"])


if __name__ == "__main__":
    _run_all()
___CM_EOF___
mkdir -p "$CM_DIR/bridge"
cat > "$CM_DIR/bridge/requirements.txt" <<'___CM_EOF___'
aiohttp
___CM_EOF___
mkdir -p "$CM_DIR/bridge"
cat > "$CM_DIR/bridge/sample_quotes.json" <<'___CM_EOF___'
{
 "ts": 0,
 "quotes": {
  "AUDCAD": {
   "bid": 0.97525,
   "ask": 0.97528,
   "high": 0.97622,
   "low": 0.96708
  },
  "AUDCHF": {
   "bid": 0.55893,
   "ask": 0.55894,
   "high": 0.55942,
   "low": 0.55452
  },
  "AUDJPY": {
   "bid": 111.933,
   "ask": 111.936,
   "high": 112.028,
   "low": 111.139
  },
  "AUDNZD": {
   "bid": 1.21775,
   "ask": 1.21783,
   "high": 1.21968,
   "low": 1.21406
  },
  "AUDUSD": {
   "bid": 0.70319,
   "ask": 0.70319,
   "high": 0.70401,
   "low": 0.69644
  },
  "CADCHF": {
   "bid": 0.57309,
   "ask": 0.57312,
   "high": 0.57542,
   "low": 0.57257
  },
  "CADJPY": {
   "bid": 114.77,
   "ask": 114.773,
   "high": 114.943,
   "low": 114.65
  },
  "CHFJPY": {
   "bid": 200.263,
   "ask": 200.269,
   "high": 200.325,
   "low": 199.44
  },
  "EURAUD": {
   "bid": 1.6557,
   "ask": 1.65574,
   "high": 1.66376,
   "low": 1.65418
  },
  "EURCAD": {
   "bid": 1.61458,
   "ask": 1.61463,
   "high": 1.61621,
   "low": 1.60921
  },
  "EURCHF": {
   "bid": 0.92532,
   "ask": 0.92537,
   "high": 0.92571,
   "low": 0.92316
  },
  "EURGBP": {
   "bid": 0.87184,
   "ask": 0.87185,
   "high": 0.87293,
   "low": 0.87103
  },
  "EURJPY": {
   "bid": 185.318,
   "ask": 185.324,
   "high": 185.381,
   "low": 184.946
  },
  "EURNZD": {
   "bid": 2.0164,
   "ask": 2.01652,
   "high": 2.02931,
   "low": 2.01609
  },
  "EURUSD": {
   "bid": 1.16418,
   "ask": 1.16419,
   "high": 1.16529,
   "low": 1.15868
  },
  "GBPAUD": {
   "bid": 1.89899,
   "ask": 1.89904,
   "high": 1.90768,
   "low": 1.89709
  },
  "GBPCAD": {
   "bid": 1.85185,
   "ask": 1.85191,
   "high": 1.85362,
   "low": 1.84413
  },
  "GBPCHF": {
   "bid": 1.06131,
   "ask": 1.06136,
   "high": 1.0619,
   "low": 1.05783
  },
  "GBPJPY": {
   "bid": 212.545,
   "ask": 212.552,
   "high": 212.583,
   "low": 211.989
  },
  "GBPNZD": {
   "bid": 2.31245,
   "ask": 2.31257,
   "high": 2.32385,
   "low": 2.31233
  },
  "GBPUSD": {
   "bid": 1.33516,
   "ask": 1.33517,
   "high": 1.33632,
   "low": 1.32842
  },
  "NZDCAD": {
   "bid": 0.80078,
   "ask": 0.80082,
   "high": 0.80087,
   "low": 0.79178
  },
  "NZDCHF": {
   "bid": 0.45893,
   "ask": 0.45896,
   "high": 0.45896,
   "low": 0.45402
  },
  "NZDJPY": {
   "bid": 91.909,
   "ask": 91.914,
   "high": 91.916,
   "low": 90.928
  },
  "NZDUSD": {
   "bid": 0.57737,
   "ask": 0.57739,
   "high": 0.57754,
   "low": 0.56946
  },
  "USDCAD": {
   "bid": 1.38704,
   "ask": 1.38706,
   "high": 1.39003,
   "low": 1.3865
  },
  "USDCHF": {
   "bid": 0.79488,
   "ask": 0.79488,
   "high": 0.79905,
   "low": 0.79429
  },
  "USDJPY": {
   "bid": 159.185,
   "ask": 159.186,
   "high": 159.778,
   "low": 159.055
  }
 }
}
___CM_EOF___
mkdir -p "$CM_DIR/web"
cat > "$CM_DIR/web/index.html" <<'___CM_EOF___'
<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<title>Currency Strength Meter</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  /* ---- design tokens (dataviz reference palette; both modes selected) ---- */
  :root, :root[data-theme="dark"] {
    --plane:      #0d0d0d;
    --surface:    #1a1a19;
    --surface-2:  #222221;
    --ink:        #ffffff;
    --ink-2:      #c3c2b7;
    --muted:      #898781;
    --grid:       #2c2c2a;
    --axis:       #383835;
    --border:     rgba(255,255,255,0.10);
    --good:       #0ca30c;
    --good-text:  #2fbd2f;
    --critical:   #e0574f;
    --warning:    #fab219;
    --neutral:    #6b7280;
    /* categorical currency hues (dark steps), fixed order USD..JPY */
    --c-USD: #3987e5; --c-EUR: #199e70; --c-GBP: #c98500; --c-CHF: #2e9e2e;
    --c-CAD: #9085e9; --c-AUD: #e66767; --c-NZD: #d55181; --c-JPY: #d95926;
    --c-XAU: #e0b64a;
  }
  :root[data-theme="light"] {
    --plane:      #f2f2ef;
    --surface:    #fcfcfb;
    --surface-2:  #f4f4f1;
    --ink:        #0b0b0b;
    --ink-2:      #52514e;
    --muted:      #898781;
    --grid:       #e1e0d9;
    --axis:       #c3c2b7;
    --border:     rgba(11,11,11,0.10);
    --good:       #0ca30c;
    --good-text:  #067a06;
    --critical:   #d03b3b;
    --warning:    #b9820a;
    --neutral:    #6b7280;
    --c-USD: #2a78d6; --c-EUR: #1baf7a; --c-GBP: #c98500; --c-CHF: #008300;
    --c-CAD: #4a3aa7; --c-AUD: #e34948; --c-NZD: #d5477f; --c-JPY: #d9531f;
    --c-XAU: #b7891f;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; }
  body {
    background: var(--plane);
    color: var(--ink);
    font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    font-size: 14px;
    line-height: 1.4;
    padding: 0 20px 40px;
  }
  .wrap { max-width: 1260px; margin: 0 auto; }

  /* ---- header ---- */
  header {
    position: sticky; top: 0; z-index: 20;
    display: flex; align-items: center; gap: 16px; flex-wrap: wrap;
    padding: 14px 0 12px;
    background: color-mix(in srgb, var(--plane) 88%, transparent);
    backdrop-filter: blur(8px);
    border-bottom: 1px solid var(--border);
    margin-bottom: 20px;
  }
  header .title { font-size: 17px; font-weight: 650; letter-spacing: 0.01em; }
  header .title .sub { display:block; font-weight: 400; font-size: 11.5px; color: var(--muted); letter-spacing: 0.02em; }
  header .spacer { flex: 1; }
  .limits { font-size: 12px; color: var(--ink-2); font-variant-numeric: tabular-nums; white-space: nowrap; }
  .limits b { color: var(--ink); }
  .limits .up { color: var(--good-text); }
  .limits .dn { color: var(--critical); }
  .status { display: flex; align-items: center; gap: 7px; font-size: 12px; font-weight: 600; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--neutral); box-shadow: 0 0 0 3px color-mix(in srgb, var(--neutral) 25%, transparent); }
  .status.live .dot { background: var(--good); box-shadow: 0 0 0 3px color-mix(in srgb, var(--good) 25%, transparent); animation: pulse 2s infinite; }
  .status.stale .dot { background: var(--warning); box-shadow: 0 0 0 3px color-mix(in srgb, var(--warning) 25%, transparent); }
  .status.down .dot { background: var(--critical); box-shadow: 0 0 0 3px color-mix(in srgb, var(--critical) 25%, transparent); }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.55} }
  .clock { font-size: 12px; color: var(--muted); font-variant-numeric: tabular-nums; }
  .tbtn {
    background: var(--surface-2); color: var(--ink-2); border: 1px solid var(--border);
    border-radius: 7px; width: 32px; height: 30px; cursor: pointer; font-size: 15px; line-height: 1;
  }
  .tbtn:hover { color: var(--ink); }

  .banner {
    display: none; align-items: center; gap: 8px;
    background: color-mix(in srgb, var(--critical) 16%, var(--surface));
    border: 1px solid color-mix(in srgb, var(--critical) 45%, transparent);
    color: var(--ink); padding: 9px 14px; border-radius: 8px; margin-bottom: 18px;
    font-size: 13px; font-weight: 600;
  }
  .banner.show { display: flex; }

  /* ---- cards ---- */
  .app { display: grid; grid-template-columns: minmax(320px, 0.82fr) minmax(0, 1.6fr); gap: 18px; align-items: start; }
  @media (max-width: 1000px) { .app { grid-template-columns: 1fr; } }
  .left { display: flex; flex-direction: column; gap: 18px; min-width: 0; }
  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 12px; padding: 16px 16px 14px;
    display: flex; flex-direction: column;
  }
  .card > h2 {
    display: flex; align-items: baseline; gap: 8px;
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.09em;
    color: var(--muted); font-weight: 700; margin: 0 0 14px;
  }
  .card > h2 .note { margin-left: auto; text-transform: none; letter-spacing: 0; font-weight: 500; font-size: 11px; }

  /* ---- strength leaderboard ---- */
  #leaderboard { flex: 1; display: flex; flex-direction: column; justify-content: space-between; }
  .lb-row { display: grid; grid-template-columns: 20px 46px minmax(0,1fr) auto; align-items: center; gap: 10px; padding: 5px 0; cursor: default; }
  .lb-rank { color: var(--muted); font-size: 11px; text-align: right; font-variant-numeric: tabular-nums; }
  .chip { display: inline-flex; align-items: center; gap: 6px; font-weight: 700; }
  .swatch { width: 10px; height: 10px; border-radius: 3px; flex-shrink: 0; }
  .lb-track { position: relative; height: 20px; background: var(--surface-2); border-radius: 5px; overflow: hidden; }
  .lb-fill { height: 100%; border-radius: 5px; transition: width .35s cubic-bezier(.2,.7,.2,1); }
  .lb-val { text-align: right; font-weight: 650; font-variant-numeric: tabular-nums; white-space: nowrap; display: flex; align-items: center; justify-content: flex-end; }
  .mtag { font-size: 9.5px; font-weight: 800; letter-spacing: 0.04em; padding: 1px 5px; border-radius: 4px; margin-left: 6px; vertical-align: middle; }
  .mtag.STRONG { color: var(--good-text); background: color-mix(in srgb, var(--good) 20%, transparent); }
  .mtag.WEAK { color: var(--critical); background: color-mix(in srgb, var(--critical) 18%, transparent); }

  /* ---- momentum cards ---- */
  .mgrid { display: grid; grid-template-columns: 1fr 1fr; gap: 9px; flex: 1; }
  @media (max-width: 520px) { .mgrid { grid-template-columns: 1fr; } }
  .mcard { background: var(--surface-2); border: 1px solid var(--border); border-left-width: 3px; border-radius: 8px; padding: 8px 10px; }
  .mcard .top { display: flex; align-items: baseline; justify-content: space-between; }
  .mcard .name { font-size: 11px; color: var(--muted); }
  .mcard .code { font-weight: 750; }
  .mcard .big { font-size: 20px; font-weight: 700; margin: 1px 0 3px; font-variant-numeric: tabular-nums; }
  .mcard .big small { font-size: 12px; font-weight: 500; color: var(--muted); }
  .mbar { height: 5px; border-radius: 3px; background: var(--surface); overflow: hidden; }
  .mbar > div { height: 100%; border-radius: 3px; }
  .mcard .idx { font-size: 11px; color: var(--muted); margin-top: 5px; font-variant-numeric: tabular-nums; }
  .mcard .state { font-weight: 700; font-size: 10px; letter-spacing: 0.05em; }
  .st-STRONG { color: var(--good-text); }
  .st-WEAK { color: var(--critical); }
  .st-NEUTRAL { color: var(--muted); }

  /* ---- filter pills ---- */
  .pills { display: flex; gap: 6px; margin-left: auto; }
  .pill { font: inherit; font-size: 11px; font-weight: 600; padding: 3px 10px; border-radius: 999px;
    border: 1px solid var(--border); background: transparent; color: var(--ink-2); cursor: pointer; }
  .pill:hover { color: var(--ink); }
  .pill.on { background: var(--ink); color: var(--plane); border-color: var(--ink); }

  /* ---- signals table ---- */
  .tscroll { overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; font-size: 12.5px; min-width: 640px; }
  th { text-align: left; color: var(--muted); font-weight: 600; text-transform: uppercase;
    font-size: 10px; letter-spacing: 0.05em; padding: 6px 9px; border-bottom: 1px solid var(--axis);
    white-space: nowrap; cursor: pointer; user-select: none; }
  th.sortable:hover { color: var(--ink); }
  th .arw { opacity: 0.5; font-size: 9px; }
  th.num, td.num { text-align: right; font-variant-numeric: tabular-nums; }
  td { padding: 3.5px 9px; border-bottom: 1px solid var(--grid); vertical-align: middle; }
  tbody tr { border-left: 3px solid transparent; }
  tbody tr:hover { background: var(--surface-2); }
  tr.inactive td { color: var(--muted); opacity: 0.6; }
  tr.gold td { background: color-mix(in srgb, var(--c-XAU) 8%, transparent); }
  .pair-name { font-weight: 700; letter-spacing: 0.01em; }
  .qtag { color: var(--muted); font-weight: 500; }
  .sig { display: inline-block; padding: 2px 9px; border-radius: 5px; font-weight: 750; font-size: 10.5px; letter-spacing: 0.03em; }
  .sig-BUY { background: color-mix(in srgb, var(--good) 20%, transparent); color: var(--good-text); }
  .sig-SELL { background: color-mix(in srgb, var(--critical) 20%, transparent); color: var(--critical); }
  .sig-WAIT { background: color-mix(in srgb, var(--neutral) 22%, transparent); color: var(--ink-2); }
  .meter-cell { display: inline-flex; align-items: center; gap: 6px; }
  .delta-pos { color: var(--good-text); font-weight: 650; }
  .delta-neg { color: var(--critical); font-weight: 650; }
  .delta-zero { color: var(--muted); }
  /* day-range viz */
  .range { display: grid; grid-template-columns: 52px 1fr 52px; align-items: center; gap: 7px; min-width: 190px; }
  .range .lo, .range .hi { font-size: 10.5px; color: var(--muted); font-variant-numeric: tabular-nums; }
  .range .hi { text-align: right; }
  .rtrack { position: relative; height: 8px; background: linear-gradient(90deg, color-mix(in srgb,var(--critical) 45%,transparent), color-mix(in srgb,var(--good) 45%,transparent)); border-radius: 5px; }
  .rmark { position: absolute; top: 50%; width: 3px; height: 14px; border-radius: 2px; background: var(--ink); transform: translate(-50%,-50%); box-shadow: 0 0 0 2px var(--surface); }
  .rbuy { font-size: 10px; color: var(--muted); text-align: center; margin-top: 2px; font-variant-numeric: tabular-nums; }

  /* ---- tooltip ---- */
  #tip { position: fixed; z-index: 50; pointer-events: none; opacity: 0; transition: opacity .1s;
    background: var(--surface); color: var(--ink); border: 1px solid var(--axis); border-radius: 8px;
    padding: 8px 10px; font-size: 11.5px; box-shadow: 0 8px 24px rgba(0,0,0,0.35); max-width: 260px; }
  #tip.show { opacity: 1; }
  #tip .tt { font-weight: 700; margin-bottom: 4px; }
  #tip .tr { display: flex; justify-content: space-between; gap: 14px; color: var(--ink-2); }
  #tip .tr b { color: var(--ink); font-variant-numeric: tabular-nums; }

  footer { margin-top: 22px; font-size: 11px; color: var(--muted); text-align: center; }
</style>
</head>
<body>
<div class="wrap">

<header>
  <div class="title">Currency Strength Meter</div>
  <div class="spacer"></div>
  <div class="limits">Signal limits &nbsp;<span class="up">BUY &ge; +<b id="lim-buy">–</b></span> &nbsp;<span class="dn">SELL &le; &minus;<b id="lim-sell">–</b></span></div>
  <div class="clock" id="clock">–</div>
  <div class="status down" id="status"><span class="dot"></span><span id="status-text">Connecting…</span></div>
  <button class="tbtn" id="theme" title="Toggle light / dark">◐</button>
</header>

<div class="banner" id="banner"></div>

<div class="app">
  <div class="left">
    <div class="card">
      <h2>Currency Strength <span class="note">index 0–9</span></h2>
      <div id="leaderboard"></div>
    </div>

    <div class="card">
      <h2>Momentum <span class="note">STRONG ≥ 65% · WEAK ≤ 35%</span></h2>
      <div class="mgrid" id="momentum"></div>
    </div>
  </div>

  <div class="card">
  <h2>Signals
    <div class="pills" id="pills">
      <button class="pill on" data-f="ALL">All</button>
      <button class="pill" data-f="BUY">Buy</button>
      <button class="pill" data-f="SELL">Sell</button>
      <button class="pill" data-f="WAIT">Wait</button>
    </div>
  </h2>
  <div class="tscroll">
    <table>
      <thead>
        <tr>
          <th class="sortable" data-sort="pair">Pair <span class="arw" data-for="pair"></span></th>
          <th class="sortable" data-sort="signal">Signal <span class="arw" data-for="signal"></span></th>
          <th class="sortable num" data-sort="sBase">Base <span class="arw" data-for="sBase"></span></th>
          <th class="sortable num" data-sort="sQuote">Quote <span class="arw" data-for="sQuote"></span></th>
          <th class="sortable num" data-sort="delta">&Delta; <span class="arw" data-for="delta"></span></th>
          <th>Day range · position</th>
          <th class="sortable num" data-sort="spread">Spread <span class="note" style="text-transform:none;letter-spacing:0">pts</span> <span class="arw" data-for="spread"></span></th>
        </tr>
      </thead>
      <tbody id="signals-body"></tbody>
    </table>
  </div>
  </div>
</div>

<footer id="foot">Awaiting data…</footer>
</div>

<div id="tip"></div>

<script>
const CCY_ORDER = ["USD","EUR","GBP","CHF","CAD","AUD","NZD","JPY"];
const NAMES = {
  USD:"US Dollar", EUR:"Euro", GBP:"British Pound", CHF:"Swiss Franc",
  CAD:"Canadian Dollar", AUD:"Australian Dollar", NZD:"New Zealand Dollar",
  JPY:"Japanese Yen", XAU:"Gold",
};
const cvar = (c) => getComputedStyle(document.documentElement).getPropertyValue("--c-"+c).trim() || "#888";

const $ = (id) => document.getElementById(id);
const statusEl = $("status"), statusText = $("status-text"), bannerEl = $("banner");
const tip = $("tip");

let lastState = null;
let filter = "ALL";
let sortKey = null, sortDir = -1;

/* ---------- helpers ---------- */
function fmtPrice(v, jpy) {
  if (v === null || v === undefined) return "–";
  return jpy ? v.toFixed(3) : v.toFixed(5);
}
function esc(s){ return String(s).replace(/[&<>]/g, c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c])); }

/* ---------- tooltip ---------- */
function showTip(html, ev){
  tip.innerHTML = html; tip.classList.add("show");
  const pad = 14, w = tip.offsetWidth, h = tip.offsetHeight;
  let x = ev.clientX + pad, y = ev.clientY + pad;
  if (x + w > innerWidth) x = ev.clientX - w - pad;
  if (y + h > innerHeight) y = ev.clientY - h - pad;
  tip.style.left = x+"px"; tip.style.top = y+"px";
}
function hideTip(){ tip.classList.remove("show"); }
function bindTip(el, htmlFn){
  el.addEventListener("mousemove", (e)=>showTip(htmlFn(), e));
  el.addEventListener("mouseleave", hideTip);
}

/* ---------- render ---------- */
function render(state){
  lastState = state;

  // status
  if (state.stale){
    statusEl.className = "status stale"; statusText.textContent = "Stale";
    bannerEl.className = "banner show";
    bannerEl.innerHTML = "⚠&nbsp; STALE DATA — no tick received in the last few seconds (market closed or feed stopped).";
  } else {
    statusEl.className = "status live"; statusText.textContent = "Live";
    bannerEl.className = "banner";
  }

  $("lim-buy").textContent = state.threshold.toFixed(2);
  $("lim-sell").textContent = state.threshold.toFixed(2);

  // leaderboard
  $("leaderboard").innerHTML = state.ranked.map(([c,v], i)=>{
    const w = Math.max(2, Math.min(100, v/9*100));
    const m = state.momentum[c] || {pct:0, state:""};
    const tag = m.state ? `<span class="mtag ${m.state}">${m.state}</span>` : "";
    return `<div class="lb-row" data-ccy="${c}">
      <div class="lb-rank">${i+1}</div>
      <div class="chip"><span class="swatch" style="background:${cvar(c)}"></span>${c}</div>
      <div class="lb-track"><div class="lb-fill" style="width:${w}%;background:${cvar(c)}"></div></div>
      <div class="lb-val">${v.toFixed(2)}${tag}</div>
    </div>`;
  }).join("");
  [...$("leaderboard").children].forEach(row=>{
    const c = row.dataset.ccy, m = state.momentum[c]||{pct:0,state:""};
    bindTip(row, ()=>`<div class="tt">${c} · ${NAMES[c]}</div>
      <div class="tr">Strength index<b>${state.strength[c].toFixed(2)} / 9</b></div>
      <div class="tr">Momentum<b>${(m.pct*100).toFixed(1)}%</b></div>
      <div class="tr">State<b>${m.state||"neutral"}</b></div>`);
  });

  // momentum cards (fixed order)
  $("momentum").innerHTML = CCY_ORDER.map(c=>{
    const m = state.momentum[c] || {pct:0, state:""};
    const pct = m.pct*100;
    const st = m.state || "NEUTRAL";
    const col = st==="STRONG" ? "var(--good)" : st==="WEAK" ? "var(--critical)" : "var(--neutral)";
    return `<div class="mcard" style="border-left-color:${cvar(c)}">
      <div class="top"><span class="code chip"><span class="swatch" style="background:${cvar(c)}"></span>${c}</span>
        <span class="name">${NAMES[c]}</span></div>
      <div class="big">${pct.toFixed(0)}<small>%</small></div>
      <div class="mbar"><div style="width:${pct.toFixed(1)}%;background:${col}"></div></div>
      <div class="idx">Index <b style="color:var(--ink)">${state.strength[c].toFixed(2)}</b>
        · <span class="state st-${st}">${st}</span></div>
    </div>`;
  }).join("");

  renderTable();
  const dt = state.ts ? new Date(state.ts*1000).toLocaleTimeString() : "n/a";
  $("clock").textContent = dt;
  $("foot").textContent = `Threshold ${state.threshold.toFixed(2)} · 28 pairs + XAUUSD · last tick ${dt}`;
}

function renderTable(){
  const s = lastState; if(!s) return;
  let rows = s.pairs.slice();
  if (s.gold) rows.push(s.gold);

  if (filter !== "ALL") rows = rows.filter(p => p.active && p.signal === filter);

  if (sortKey){
    rows.sort((a,b)=>{
      let av=a[sortKey], bv=b[sortKey];
      if (sortKey==="pair" || sortKey==="signal"){ av=av||""; bv=bv||""; return av<bv?-sortDir:av>bv?sortDir:0; }
      av = (av===null||av===undefined)?-Infinity:av; bv=(bv===null||bv===undefined)?-Infinity:bv;
      return (av-bv)*sortDir;
    });
  }

  const body = $("signals-body");
  body.innerHTML = rows.map(p=>{
    const gold = p.pair==="XAUUSD";
    const accent = cvar(p.base);
    if (!p.active){
      return `<tr class="inactive ${gold?"gold":""}" style="border-left-color:${accent}">
        <td class="pair-name">${p.pair}</td>
        <td colspan="6">inactive — no range data (show it in MT4 Market&nbsp;Watch)</td></tr>`;
    }
    const jpy = p.pair.endsWith("JPY");
    const pos = p.buy!=null ? p.buy*100 : null;
    const dcls = p.delta>0.0001?"delta-pos":p.delta<-0.0001?"delta-neg":"delta-zero";
    const rangeCell = pos===null ? `<td class="num">–</td>` : `<td>
      <div class="range">
        <span class="lo">${fmtPrice(p.low,jpy)}</span>
        <div class="rtrack"><div class="rmark" style="left:${pos.toFixed(1)}%"></div></div>
        <span class="hi">${fmtPrice(p.high,jpy)}</span>
      </div>
    </td>`;
    return `<tr data-pair="${p.pair}" class="${gold?"gold":""}" style="border-left-color:${accent}">
      <td class="pair-name">${p.base}<span class="qtag">${p.quote}</span></td>
      <td><span class="sig sig-${p.signal}">${p.signal}</span></td>
      <td class="num"><span class="meter-cell"><span class="swatch" style="background:${accent}"></span>${p.sBase.toFixed(2)}</span></td>
      <td class="num"><span class="meter-cell"><span class="swatch" style="background:${cvar(p.quote)}"></span>${p.sQuote.toFixed(2)}</span></td>
      <td class="num ${dcls}">${p.delta>0?"+":""}${p.delta.toFixed(2)}</td>
      ${rangeCell}
      <td class="num">${p.spread!=null?p.spread:"–"}</td>
    </tr>`;
  }).join("");

  // row tooltips
  [...body.querySelectorAll("tr[data-pair]")].forEach(tr=>{
    const p = rows.find(x=>x.pair===tr.dataset.pair); if(!p) return;
    const jpy = p.pair.endsWith("JPY");
    bindTip(tr, ()=>`<div class="tt">${p.pair} · ${p.signal}</div>
      <div class="tr">${p.base} strength<b>${p.sBase.toFixed(2)}</b></div>
      <div class="tr">${p.quote} strength<b>${p.sQuote.toFixed(2)}</b></div>
      <div class="tr">Δ (base − quote)<b>${p.delta>0?"+":""}${p.delta.toFixed(2)}</b></div>
      <div class="tr">High<b>${fmtPrice(p.high,jpy)}</b></div>
      <div class="tr">Bid<b>${fmtPrice(p.bid,jpy)}</b></div>
      <div class="tr">Ask<b>${fmtPrice(p.ask,jpy)}</b></div>
      <div class="tr">Low<b>${fmtPrice(p.low,jpy)}</b></div>
      <div class="tr">Position<b>buy ${(p.buy*100).toFixed(0)}% · sell ${(p.sell*100).toFixed(0)}%</b></div>
      <div class="tr">Spread<b>${p.spread!=null?p.spread+" pts":"–"}</b></div>`);
  });

  // sort arrows
  document.querySelectorAll(".arw").forEach(a=>a.textContent = a.dataset.for===sortKey ? (sortDir<0?"▼":"▲") : "");
}

/* ---------- controls ---------- */
$("pills").addEventListener("click", e=>{
  const b = e.target.closest(".pill"); if(!b) return;
  filter = b.dataset.f;
  [...$("pills").children].forEach(x=>x.classList.toggle("on", x===b));
  renderTable();
});
document.querySelectorAll("th.sortable").forEach(th=>{
  th.addEventListener("click", ()=>{
    const k = th.dataset.sort;
    if (sortKey===k) sortDir=-sortDir; else { sortKey=k; sortDir = (k==="pair"||k==="signal")?1:-1; }
    renderTable();
  });
});

// theme
const themeBtn = $("theme");
function applyTheme(t){ document.documentElement.setAttribute("data-theme", t); try{localStorage.setItem("meter-theme",t);}catch(e){} if(lastState) render(lastState); }
themeBtn.addEventListener("click", ()=>{
  const cur = document.documentElement.getAttribute("data-theme");
  applyTheme(cur==="dark"?"light":"dark");
});
(function initTheme(){
  let t; try{ t = localStorage.getItem("meter-theme"); }catch(e){}
  if(!t) t = matchMedia("(prefers-color-scheme: light)").matches ? "light":"dark";
  document.documentElement.setAttribute("data-theme", t);
})();

/* ---------- websocket ---------- */
let ws=null, retry=null;
function connect(){
  const proto = location.protocol==="https:"?"wss:":"ws:";
  ws = new WebSocket(`${proto}//${location.host}/ws`);
  ws.onmessage = ev=>{ try{ render(JSON.parse(ev.data)); }catch(e){ console.error("bad message", e); } };
  ws.onclose = ()=>{
    statusEl.className="status down"; statusText.textContent="Disconnected";
    bannerEl.className="banner show"; bannerEl.innerHTML="⚠&nbsp; DISCONNECTED — retrying connection to the bridge…";
    clearTimeout(retry); retry=setTimeout(connect, 1500);
  };
  ws.onerror = ()=>ws.close();
}
connect();
</script>
</body>
</html>
___CM_EOF___
mkdir -p "$CM_DIR/mt4"
cat > "$CM_DIR/mt4/CurrencyMeterFeed.mq4" <<'___CM_EOF___'
//+------------------------------------------------------------------+
//| CurrencyMeterFeed.mq4                                             |
//| Feeds the Currency Meter web app via native MT4 WebRequest POST.  |
//| No DDE, no ZeroMQ, no DLL.                                        |
//|                                                                    |
//| SETUP:                                                             |
//|  1. In MT4: Tools > Options > Expert Advisors >                    |
//|     "Allow WebRequest for listed URL" -> add http://127.0.0.1:8010 |
//|     (must match ServerURL's host:port exactly, no trailing path).  |
//|  2. Start the bridge server: python bridge/server.py               |
//|  3. Attach this EA to ANY ONE chart (symbol/timeframe don't         |
//|     matter -- it iterates all 28 pairs + XAUUSD itself via          |
//|     MarketInfo). AllowLiveTrading is not required.                  |
//|  4. If your broker suffixes symbols (e.g. EURUSD.raw, EURUSDm),     |
//|     set SymbolSuffix accordingly so MarketInfo() finds them.        |
//|  5. Watch the Experts tab for errors. Error 4060 or -1 on           |
//|     WebRequest means the URL is not whitelisted -- redo step 1.     |
//+------------------------------------------------------------------+
#property strict
#property copyright "Currency Meter"
#property version   "1.00"

input string ServerURL   = "http://127.0.0.1:8010/tick";
input string SymbolSuffix = "";
input int    SendMs      = 250;

string Pairs[28] = {
   "AUDCAD","AUDCHF","AUDJPY","AUDNZD","AUDUSD",
   "CADCHF","CADJPY",
   "CHFJPY",
   "EURAUD","EURCAD","EURCHF","EURGBP","EURJPY","EURNZD","EURUSD",
   "GBPAUD","GBPCAD","GBPCHF","GBPJPY","GBPNZD","GBPUSD",
   "NZDCAD","NZDCHF","NZDJPY","NZDUSD",
   "USDCAD","USDCHF","USDJPY"
};
string GoldSymbol = "XAUUSD";

datetime lastSendMs = 0;
bool     warnedWebRequest = false;
int      sendCount = 0;
int      warnedNoSymbols = 0;

int OnInit()
{
   lastSendMs = 0;
   warnedWebRequest = false;
   sendCount = 0;
   warnedNoSymbols = 0;
   // Push on a timer so data flows even when ticks are sparse or the market is
   // closed (e.g. weekends). OnTick also triggers a send for freshness.
   EventSetMillisecondTimer(SendMs < 50 ? 50 : SendMs);
   Print("CurrencyMeterFeed initialized. ServerURL=", ServerURL,
         " SymbolSuffix='", SymbolSuffix, "' SendMs=", SendMs);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

// Append one symbol's quote as a JSON object, if tradeable/available.
// Returns true if appended (and prepends a comma if 'first' is false).
bool AppendQuoteJson(string &json, string sym, bool first)
{
   string full = sym + SymbolSuffix;
   double bid  = MarketInfo(full, MODE_BID);
   if(bid == 0)
      return(false); // symbol not available / not subscribed

   double ask  = MarketInfo(full, MODE_ASK);
   double high = MarketInfo(full, MODE_HIGH);
   double low  = MarketInfo(full, MODE_LOW);

   // Spread in points, exactly as MT4's Market Watch shows it. MODE_SPREAD is
   // the authoritative broker value; if it reports 0 (some floating-spread
   // feeds), fall back to (Ask-Bid)/Point.
   double point = MarketInfo(full, MODE_POINT);
   int spread = (int)MarketInfo(full, MODE_SPREAD);
   if(spread <= 0 && point > 0)
      spread = (int)MathRound((ask - bid) / point);

   if(!first)
      json = json + ",";
   json = json + "\"" + sym + "\":{" +
          "\"bid\":" + DoubleToString(bid, 6) + "," +
          "\"ask\":" + DoubleToString(ask, 6) + "," +
          "\"high\":" + DoubleToString(high, 6) + "," +
          "\"low\":" + DoubleToString(low, 6) + "," +
          "\"spread\":" + IntegerToString(spread) +
          "}";
   return(true);
}

void OnTick()
{
   SendQuotes();
}

void OnTimer()
{
   SendQuotes();
}

void SendQuotes()
{
   datetime nowMs = GetTickCount();
   if(nowMs - lastSendMs < SendMs)
      return;
   lastSendMs = nowMs;

   string json = "{\"ts\":" + IntegerToString((int)TimeCurrent()) + ",\"quotes\":{";
   int found = 0;

   for(int i = 0; i < ArraySize(Pairs); i++)
   {
      if(AppendQuoteJson(json, Pairs[i], found == 0))
         found++;
   }
   // Gold is a standalone extra row, appended the same way.
   if(AppendQuoteJson(json, GoldSymbol, found == 0))
      found++;

   json = json + "}}";

   if(found == 0)
   {
      // No symbols resolved: usually a wrong SymbolSuffix or symbols not in
      // Market Watch. Send an empty tick anyway so the page shows "connected"
      // (zeros) rather than "stale", making the cause obvious, and warn once.
      if(warnedNoSymbols < 3)
      {
         Print("No symbols found via MarketInfo. Check SymbolSuffix (broker may use ",
               "'.raw','m','.i' etc.) and that pairs are shown in Market Watch ",
               "(right-click -> Show All). Example lookup: '", Pairs[0] + SymbolSuffix, "'.");
         warnedNoSymbols++;
      }
   }

   char data[];
   int len = StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   ArrayResize(data, len);

   char result[];
   string resultHeaders;

   ResetLastError();
   int status = WebRequest("POST", ServerURL,
                           "Content-Type: application/json\r\n",
                           5000, data, result, resultHeaders);

   if(status == -1)
   {
      int err = GetLastError();
      if(err == 4060 || err == -1)
      {
         if(!warnedWebRequest)
         {
            Print("WebRequest FAILED (error ", err, "). ",
                  "You must whitelist the URL: MT4 -> Tools -> Options -> ",
                  "Expert Advisors -> 'Allow WebRequest for listed URL' -> add ",
                  ServerURL, " (host:port only, e.g. http://127.0.0.1:8010).");
            warnedWebRequest = true;
         }
      }
      else
      {
         Print("WebRequest error ", err, " posting to ", ServerURL);
      }
      return;
   }

   // Success. Heartbeat: log the first send and then every ~40 sends so the
   // Experts tab confirms data is flowing and how many symbols were resolved.
   sendCount++;
   if(sendCount == 1 || (sendCount % 40) == 0)
      Print("POST ok (HTTP ", status, "), symbols=", found, ", send #", sendCount);
}
//+------------------------------------------------------------------+
___CM_EOF___
mkdir -p "$CM_DIR/mt4"
cat > "$CM_DIR/mt4/WebRequestTest.mq4" <<'___CM_EOF___'
//+------------------------------------------------------------------+
//| WebRequestTest.mq4                                                |
//| Diagnostic script: isolates whether WebRequest fails only for     |
//| the local bridge or for every URL (e.g. a broken Wine WinInet     |
//| shim). Run as a Script (drag onto any chart), read the Experts    |
//| tab. Whitelist BOTH URLs first:                                   |
//|   https://www.google.com                                          |
//|   http://127.0.0.1:8010                                           |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

void TestOne(string label, string url)
{
   char data[];
   char result[];
   string resultHeaders;

   ResetLastError();
   int status = WebRequest("GET", url, "", 5000, data, result, resultHeaders);

   if(status == -1)
      Print(label, " -> FAILED, error ", GetLastError(), " url=", url);
   else
      Print(label, " -> OK, HTTP ", status, " url=", url);
}

void OnStart()
{
   TestOne("HTTPS-EXT ", "https://www.google.com");
   TestOne("HTTP-EXT  ", "http://example.com");
   TestOne("HTTP-EXT80", "http://neverssl.com");
   TestOne("LOCAL-IP  ", "http://192.168.1.100:8010/state"); // <- set to your Mac's LAN IP
}
//+------------------------------------------------------------------+
___CM_EOF___
cat > "$CM_DIR/meterctl.sh" <<'___CM_EOF___'
#!/usr/bin/env bash
#
# meterctl.sh - start / stop / restart the Currency Meter bridge server.
#
#   ./meterctl.sh start      launch the bridge in the background
#   ./meterctl.sh stop       stop it
#   ./meterctl.sh restart    stop then start
#   ./meterctl.sh status     show whether it's running + a health check
#   ./meterctl.sh logs       follow the server log (Ctrl-C to stop following)
#   ./meterctl.sh install    install as a launchd daemon (auto-start at boot)
#   ./meterctl.sh uninstall  remove the launchd daemon
#
# Once installed as a daemon, start/stop/restart automatically route through
# launchctl instead of a background process, so you never fight KeepAlive.
# install/uninstall (and start/stop/restart while installed) use sudo; run
# them from a real terminal so the password prompt works.
#
# Defaults are tuned for MT4-under-CrossOver/Wine, which can only reach the
# Mac's LAN IP on port 80:
#   METER_HOST   bind address   (default: auto-detected LAN IP, else 0.0.0.0)
#   METER_PORT   bind port      (default: 80)
# So `./meterctl.sh start` just works - no need to pass anything. Both are
# still overridable, e.g. for a plain local run:
#   METER_HOST=127.0.0.1 METER_PORT=8010 ./meterctl.sh start
# Ports below 1024 need root; this script re-invokes the server under sudo
# automatically in that case.

set -euo pipefail

# Resolve the project directory (where this script lives) so it works from
# anywhere.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PYTHON="$DIR/.venv/bin/python"
SERVER="$DIR/bridge/server.py"
LOG="$DIR/server.log"
PATTERN="bridge/server.py"          # what pgrep/pkill match against

# launchd daemon identity/paths.
LABEL="com.currencymeter.bridge"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"

# Auto-detect the Mac's LAN IP (the address MT4-under-Wine must POST to).
# Prefer the interface behind the default route, then fall back to the usual
# Wi-Fi/Ethernet interfaces.
detect_ip() {
  local iface ip
  iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  [ -n "$iface" ] && ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
  [ -z "${ip:-}" ] && ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
  [ -z "${ip:-}" ] && ip="$(ipconfig getifaddr en1 2>/dev/null || true)"
  echo "${ip:-}"
}

HOST="${METER_HOST:-$(detect_ip)}"
HOST="${HOST:-0.0.0.0}"             # fall back to all interfaces if no LAN IP
PORT="${METER_PORT:-80}"

# Ports < 1024 require root on macOS. Prefix privileged commands with sudo so
# the server can bind e.g. port 80 for MT4-under-Wine.
SUDO=""
if [ "$PORT" -lt 1024 ]; then
  SUDO="sudo"
fi

color() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
ok()   { color "32" "$1"; }   # green
warn() { color "33" "$1"; }   # yellow
err()  { color "31" "$1"; }   # red

# Print the PID(s) of any running server, or nothing.
server_pids() {
  pgrep -f "$PATTERN" 2>/dev/null || true
}

is_running() {
  [ -n "$(server_pids)" ]
}

# The daemon is "installed" once its plist is in /Library/LaunchDaemons.
daemon_installed() {
  [ -f "$PLIST_DST" ]
}

do_start() {
  # If installed as a daemon, hand off to launchd rather than spawning our
  # own background process (which launchd's KeepAlive would just duplicate).
  if daemon_installed; then
    echo "daemon installed -> starting via launchctl ..."
    sudo launchctl bootstrap system "$PLIST_DST" 2>/dev/null \
      || sudo launchctl kickstart "system/$LABEL"
    sleep 1
    do_status
    return 0
  fi

  if is_running; then
    echo "$(warn "already running") (PID $(server_pids | tr '\n' ' '))"
    do_status
    return 0
  fi

  if [ ! -x "$PYTHON" ]; then
    echo "$(err "no venv python at $PYTHON")"
    echo "Create it first:  python3 -m venv .venv && .venv/bin/pip install -r bridge/requirements.txt"
    exit 1
  fi

  echo "starting bridge on $(ok "http://$HOST:$PORT") ..."
  if [ -z "${METER_HOST:-}" ] && [ "$HOST" != "0.0.0.0" ]; then
    echo "(auto-detected LAN IP $HOST -- point MT4 at $(ok "http://$HOST$( [ "$PORT" = 80 ] && echo "" || echo ":$PORT" )/tick"))"
  fi
  if [ -n "$SUDO" ]; then
    echo "(port $PORT < 1024 -> using sudo; you may be prompted for your password)"
  fi

  # nohup + background so it survives this shell. sudo drops the activated
  # venv, so we pass the env vars through explicitly and call the venv python
  # by absolute path.
  $SUDO env METER_HOST="$HOST" METER_PORT="$PORT" \
    nohup "$PYTHON" "$SERVER" >>"$LOG" 2>&1 &

  # Give it a moment to bind (or fail).
  sleep 1
  if is_running; then
    echo "$(ok "started") (PID $(server_pids | tr '\n' ' ')), logging to $LOG"
    do_status
  else
    echo "$(err "failed to start") - last log lines:"
    tail -n 15 "$LOG" 2>/dev/null || true
    exit 1
  fi
}

do_stop() {
  # Daemon mode: bootout unloads it (and, with KeepAlive, that's the only way
  # to make it stay down until the next boot or an explicit start).
  if daemon_installed; then
    echo "daemon installed -> stopping via launchctl (bootout) ..."
    sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
    sleep 1
    do_status
    return 0
  fi

  if ! is_running; then
    echo "$(warn "not running")"
    return 0
  fi
  echo "stopping (PID $(server_pids | tr '\n' ' ')) ..."
  # A port-80 server runs as root, so a plain pkill can't touch it. Try
  # without sudo first (covers the common 8010 case with no password
  # prompt); if anything survives, it's root-owned, so escalate to sudo.
  pkill -f "$PATTERN" 2>/dev/null || true
  sleep 1
  if is_running; then
    echo "(escalating to sudo for root-owned server; you may be prompted)"
    sudo pkill -f "$PATTERN" || true
  fi
  # Wait up to ~5s for it to exit, then escalate to SIGKILL.
  for _ in 1 2 3 4 5; do
    is_running || break
    sleep 1
  done
  if is_running; then
    echo "$(warn "did not exit, sending SIGKILL")"
    pkill -9 -f "$PATTERN" 2>/dev/null || true
    sudo pkill -9 -f "$PATTERN" 2>/dev/null || true
    sleep 1
  fi
  if is_running; then
    echo "$(err "still running") (PID $(server_pids | tr '\n' ' '))"
    exit 1
  fi
  echo "$(ok "stopped")"
}

do_status() {
  if is_running; then
    echo "server: $(ok "running") (PID $(server_pids | tr '\n' ' '))"
  else
    echo "server: $(err "stopped")"
    return 0
  fi
  # Health-check the port the server is *actually* on: prefer METER_PORT as
  # seen on the running process's command line (that's how do_start launches
  # it), falling back to this invocation's configured PORT.
  local port host
  port="$(ps -Ao args 2>/dev/null | grep "$PATTERN" | grep -oE 'METER_PORT=[0-9]+' | head -1 | cut -d= -f2)"
  port="${port:-$PORT}"
  host="$HOST"
  # Can't curl a wildcard bind address; hit loopback instead.
  [ "$host" = "0.0.0.0" ] && host="127.0.0.1"
  local url="http://$host:$port/state"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url" 2>/dev/null)"
  code="${code:-000}"
  if [ "$code" = "200" ]; then
    echo "health: $(ok "OK")  ($url -> 200)"
  else
    echo "health: $(warn "no response")  ($url -> $code)"
  fi
}

do_logs() {
  if [ ! -f "$LOG" ]; then
    echo "$(warn "no log file yet at $LOG")"
    exit 0
  fi
  echo "following $LOG (Ctrl-C to stop) ..."
  tail -n 30 -f "$LOG"
}

# Install as a launchd daemon: generate the plist from the current config,
# drop it in /Library/LaunchDaemons, and bootstrap it so it runs now and at
# every boot. Binds 0.0.0.0 by default so it survives DHCP IP changes without
# a reload (override by setting METER_HOST before running install).
do_install() {
  if daemon_installed; then
    echo "$(warn "already installed") at $PLIST_DST"
    echo "Use '$0 restart' to reload, or '$0 uninstall' first to reinstall."
    return 0
  fi
  if [ ! -x "$PYTHON" ]; then
    echo "$(err "no venv python at $PYTHON")"
    echo "Create it first:  python3 -m venv .venv && .venv/bin/pip install -r bridge/requirements.txt"
    exit 1
  fi

  local dhost dport
  dhost="${METER_HOST:-0.0.0.0}"    # daemons prefer all-interfaces (DHCP-proof)
  dport="${METER_PORT:-80}"

  echo "installing daemon $LABEL (bind $dhost:$dport) ..."
  echo "(needs sudo; you may be prompted for your password)"

  # Free port 80 from any manually-started instance so the daemon can bind.
  pkill -f "$PATTERN" 2>/dev/null || true
  sudo pkill -f "$PATTERN" 2>/dev/null || true

  # Generate the plist to a temp file, then install it root-owned.
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON</string>
    <string>$SERVER</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>METER_HOST</key>
    <string>$dhost</string>
    <key>METER_PORT</key>
    <string>$dport</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>$DIR</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>$LOG</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
</dict>
</plist>
PLIST

  sudo cp "$tmp" "$PLIST_DST"
  rm -f "$tmp"
  sudo chown root:wheel "$PLIST_DST"
  sudo chmod 644 "$PLIST_DST"
  sudo launchctl bootstrap system "$PLIST_DST"

  sleep 1
  if is_running; then
    echo "$(ok "installed and running") -> $PLIST_DST"
    echo "It now starts automatically at boot. Manage with: $0 {start|stop|restart|status|logs|uninstall}"
    do_status
  else
    echo "$(err "installed but not running") - last log lines:"
    tail -n 15 "$LOG" 2>/dev/null || true
    exit 1
  fi
}

do_uninstall() {
  if ! daemon_installed; then
    echo "$(warn "not installed") (no $PLIST_DST)"
    return 0
  fi
  echo "uninstalling daemon $LABEL ..."
  echo "(needs sudo; you may be prompted for your password)"
  sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
  sudo rm -f "$PLIST_DST"
  sleep 1
  if daemon_installed; then
    echo "$(err "failed to remove") $PLIST_DST"
    exit 1
  fi
  echo "$(ok "uninstalled"). The server is stopped and will not start at boot."
  echo "Run '$0 start' to launch it manually again."
}

usage() {
  echo "usage: $0 {start|stop|restart|status|logs|install|uninstall}"
  exit 2
}

case "${1:-}" in
  start)     do_start ;;
  stop)      do_stop ;;
  restart)
    if daemon_installed; then
      echo "daemon installed -> restarting via launchctl ..."
      sudo launchctl bootstrap system "$PLIST_DST" 2>/dev/null || true
      sudo launchctl kickstart -k "system/$LABEL"
      sleep 1
      do_status
    else
      do_stop; echo; do_start
    fi
    ;;
  status)    do_status ;;
  logs)      do_logs ;;
  install)   do_install ;;
  uninstall) do_uninstall ;;
  *)         usage ;;
esac
___CM_EOF___
cat > "$CM_DIR/README.md" <<'___CM_EOF___'
# Currency Strength Meter

Reproduces the `OPENBIDASK` tab of `Excel-Currency-Meter-2026.xlsx` as a
small web app, fed live from MetaTrader 4 over native `WebRequest()` HTTP
POST — no DDE, no ZeroMQ, no DLL. All math (ranks, strengths, signals,
gauges, momentum) runs in Python (`bridge/meter.py`), matching the
workbook's hidden `MAIN` sheet exactly. The browser only renders.

## Install

One-line install (recreates the project, sets up a venv, installs deps):

```bash
curl -fsSL https://raw.githubusercontent.com/gtujan/mt4-currency-meter/main/install.sh | bash
```

Installs into `~/currency_meter` by default; override with
`CM_DIR=/path curl -fsSL … | bash`. The script is self-contained — it embeds
every source file, so no `git clone` is needed. You can also just download
`install.sh` and run `bash install.sh`.

Then see [`INSTALL.md`](INSTALL.md) for the full MT4 + Wine + port-80 setup,
or try the mock demo below.

## Quick start (no MT4 needed — mock feed demo)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r bridge/requirements.txt

python bridge/server.py &      # starts the bridge at http://127.0.0.1:8010
python bridge/mock_feed.py     # replays bridge/sample_quotes.json to /tick every ~1s
```

Open **http://127.0.0.1:8010** in a browser. Stop `mock_feed.py` and the
page shows a "STALE DATA" banner after ~5s with no ticks.

## Verify the algorithm (no server needed)

```bash
python bridge/mock_feed.py --test
```

Asserts the golden values reverse-engineered from the live workbook:
strengths `USD 1.71, EUR 4.86, GBP 5.14, CHF 3.86, CAD 2.71, AUD 7.00,
NZD 8.14, JPY 2.57`; ranked order (strong→weak) `NZD, AUD, GBP, EUR, CHF,
CAD, JPY, USD`; `AUDCAD` signal `BUY` (δ≈4.29), `EURUSD` `WAIT` (δ≈3.14),
`NZDUSD` `BUY` (δ≈6.43).

Alternatively: `python -m pytest bridge/test_meter.py -v`.

## Debug endpoint

`GET /state` returns the latest computed state as JSON (same payload
pushed over `/ws`). Handy for `curl http://127.0.0.1:8010/state | jq` or
polling without a WebSocket client.

## Running with real MT4

1. **Whitelist the URL.** In MT4: `Tools > Options > Expert Advisors >
   Allow WebRequest for listed URL`, add `http://127.0.0.1:8010` (host:port
   only, no path). WebRequest fails with error 4060 otherwise — the EA
   prints a reminder to the Experts tab if this happens. (On **CrossOver /
   Wine**, `127.0.0.1` and non-standard ports don't work at all — see the
   macOS note below; use the Mac's LAN IP on port 80.)
2. **Copy the EA.** Put `mt4/CurrencyMeterFeed.mq4` in your terminal's
   `MQL4/Experts/` folder and compile it in MetaEditor (or just open it —
   MT4 auto-compiles `.mq4` on load in most builds).
3. **Attach it to any one chart** (symbol/timeframe don't matter — the EA
   iterates all 28 pairs + XAUUSD itself via `MarketInfo()`).
   `AllowLiveTrading` is not required since no orders are placed.
4. **Symbol suffix.** If your broker suffixes symbols (e.g. `EURUSD.raw`,
   `EURUSDm`), set the EA's `SymbolSuffix` input accordingly so
   `MarketInfo()` can find them.
5. Start `python bridge/server.py`, open `http://127.0.0.1:8010` in a
   browser, and confirm live updates. (CrossOver / Wine users: start it
   bound to the LAN IP on port 80 per the macOS note below, and open
   `http://<LAN-IP>` instead.)

**macOS / CrossOver (Wine):** two Wine-specific gotchas make the default
`http://127.0.0.1:8010` fail — use the setup below instead.

- **Loopback is not shared.** Contrary to what you might expect, the Wine
  bottle does *not* reach the host Mac's `127.0.0.1`. `WebRequest` to
  `http://127.0.0.1:8010` (or `http://localhost:8010`) fails; you must
  point the EA at the Mac's **LAN IP** (e.g. `192.168.1.100` — find yours
  with `ipconfig getifaddr en0`) and bind the server so it's reachable
  there.
- **Non-standard ports are rejected.** Wine's `WebRequest` only accepts
  ports **80** (`http://`) and **443** (`https://`) — the port is derived
  from the protocol, matching the MQL docs. Any explicit port like `:8010`
  fails during URL validation with **error 5200** (`INVALID_ADDRESS`),
  *before* any connection attempt, so the whitelist and a working server
  don't help. Run the bridge on port 80.

Putting both together, the easiest path is the `meterctl.sh` helper, which
auto-detects your LAN IP and defaults to port 80 (see *Managing the server*
below):

```bash
./meterctl.sh start    # binds the detected LAN IP on port 80 (prompts for sudo)
```

or do it by hand:

```bash
# Bind to the LAN IP on port 80 (needs sudo for :80; sudo drops the venv,
# so call the venv's python explicitly). Binding the LAN IP rather than
# 0.0.0.0 leaves 127.0.0.1:80 free for other local web apps.
sudo METER_HOST=192.168.1.100 METER_PORT=80 .venv/bin/python bridge/server.py
```

Then in MT4 whitelist `http://192.168.1.100` (host only, no port, no path)
and set the EA's `ServerURL` input to `http://192.168.1.100/tick`. Open
the browser UI at `http://192.168.1.100` (also no port). `METER_HOST` and
`METER_PORT` are read by `bridge/server.py`.

*Diagnosing WebRequest under Wine:* copy `mt4/WebRequestTest.mq4` into
`MQL4/Scripts/`, whitelist the URLs it hits, and drag it onto a chart. It
GETs an external HTTPS URL, an external HTTP URL, and your local bridge,
printing the HTTP status or error for each to the Experts tab — an external
URL succeeding while the local one returns 5200 isolates the problem to the
port/address rather than `WebRequest` itself.

## Managing the server (`meterctl.sh`)

`meterctl.sh` starts, stops, and health-checks the bridge without you having
to remember the `sudo`/`METER_HOST`/`METER_PORT` incantation. It auto-detects
the Mac's LAN IP and defaults to port 80 — the config MT4-under-Wine needs —
so a bare `start` just works:

```bash
./meterctl.sh start      # background, auto LAN IP + port 80 (prompts for sudo on :80)
./meterctl.sh stop       # stop it (auto-escalates to sudo for a root/port-80 server)
./meterctl.sh restart    # stop then start
./meterctl.sh status     # running? + a GET /state health check
./meterctl.sh logs       # follow server.log
```

Override the defaults with env vars, e.g. a plain local (non-Wine) run:

```bash
METER_HOST=127.0.0.1 METER_PORT=8010 ./meterctl.sh start
```

### Run it as a launchd daemon (auto-start at boot)

To have the bridge start automatically at boot and relaunch if it ever
crashes — so you never start it by hand or type `sudo` again:

```bash
./meterctl.sh install    # generate + install /Library/LaunchDaemons plist, start now & at boot
./meterctl.sh uninstall  # stop and remove the daemon
```

Once installed, `start`/`stop`/`restart` automatically route through
`launchctl` (bootstrap/bootout/kickstart) instead of a background process,
so they don't fight the daemon's `KeepAlive`; `status` and `logs` work the
same in both modes. `install` binds `0.0.0.0` by default so the daemon keeps
working across DHCP IP changes with no reload — set `METER_HOST` before
`install` to pin a fixed LAN IP instead. `install`/`uninstall` use `sudo`,
so run them from a real terminal where the password prompt works.

## Files

```
mt4/CurrencyMeterFeed.mq4   EA: throttled OnTick -> build JSON by hand -> WebRequest POST
mt4/WebRequestTest.mq4      diagnostic Script: GET external + local URLs, print status/error
bridge/symbols.py           28 pairs, 8 currencies, LOOKUP thresholds/ranks, base/quote helpers
bridge/meter.py             pure compute(quotes) -> state dict (the algorithm, unit-tested)
bridge/server.py            aiohttp: POST /tick, GET /ws, GET /state, GET / (serves web/index.html)
bridge/mock_feed.py         dev feeder + --test golden-value assertions
bridge/test_meter.py        pytest-compatible golden tests
bridge/requirements.txt     aiohttp (only dependency)
web/index.html              single-file dark UI: bar chart, signals table, %/Index/Mmt panel
meterctl.sh                 start/stop/restart/status/logs + install as a launchd daemon
com.currencymeter.bridge.plist  reference LaunchDaemon plist (meterctl.sh install generates its own)
```

## Algorithm summary

For each of the 28 FX pairs (base = first 3 letters, quote = last 3):

1. `pos = (bid - low) / (high - low)`. If `high <= low` or bid/high/low
   missing/≤0, the pair is inactive (excluded from all averages).
2. `rank_base = LOOKUP(100*pos, [0,3,10,25,40,50,60,75,90,97], [0..9])`
   (rank of the largest threshold ≤ `100*pos`); `rank_quote = 9 - rank_base`.
3. Currency strength `S[c]` = mean of rank contributions over the currency's
   *active* pairs (7 when all are active).
4. `delta[pair] = S[base] - S[quote]`.
5. `threshold = 0.75 * mean(S over the 8 currencies + XAU's rank)`. `XAUUSD`
   is a standalone extra row — it does **not** feed the 8 currency
   strengths, but its own rank (or the workbook's cached default of `7`
   when gold's quote is absent) is included in the threshold average.
   `signal = BUY` if `delta >= threshold`, `SELL` if `delta <= -threshold`,
   else `WAIT`.
6. Gauge: `buy = pos`, `sell = 1 - pos`.
7. Momentum `M[c]` = mean over active pairs of (`pos` if base, `1-pos` if
   quote). `STRONG` if `M >= 0.65`, `WEAK` if `M <= 0.35`, else neutral.
___CM_EOF___
cat > "$CM_DIR/INSTALL.md" <<'___CM_EOF___'
# Installation Guide

Get the Currency Strength Meter running with live data from MetaTrader 4.
Written for **macOS with MT4 under CrossOver/Wine** (the setup this project
was built for). Should take about 10 minutes.

There are three pieces:

1. **The bridge** — a small Python server on your Mac that receives quotes
   and computes the meter.
2. **The MT4 Expert Advisor (EA)** — sends quotes from MT4 to the bridge.
3. **The web page** — shows the meter in your browser.

---

## Step 1 — Set up the Python bridge

Open Terminal, go to the project folder, and create the environment (one time):

```bash
cd ~/currency_meter
python3 -m venv .venv
source .venv/bin/activate
pip install -r bridge/requirements.txt
```

## Step 2 — Find your Mac's LAN IP

MT4 running under Wine **cannot** reach `127.0.0.1`/`localhost`, so you must
use your Mac's network IP. Find it with:

```bash
ipconfig getifaddr en0        # Wi-Fi; try en1 if that's blank (Ethernet)
```

Write down the result — this guide uses **`192.168.1.100`** as the example.
Replace it with yours everywhere below.

> Tip: this IP can change when your Mac reconnects to Wi-Fi. A DHCP
> reservation on your router keeps it fixed. (The launch script auto-detects
> it each run, so day to day you don't have to think about it.)

## Step 3 — Start the bridge

```bash
./meterctl.sh start
```

This auto-detects your LAN IP and starts the server on **port 80**. It will
ask for your Mac password (port 80 requires it). You should see
`started` and `health: OK`.

Useful commands:

```bash
./meterctl.sh status     # is it running? + health check
./meterctl.sh stop       # stop it
./meterctl.sh restart    # restart it
./meterctl.sh logs       # watch the log (Ctrl-C to stop watching)
```

**Optional — start automatically at boot** (so you never launch it by hand):

```bash
./meterctl.sh install    # installs a background service; asks for password once
./meterctl.sh uninstall  # removes it
```

## Step 4 — Configure MetaTrader 4

1. **Allow the URL.** In MT4: `Tools > Options > Expert Advisors` →
   tick **"Allow WebRequest for listed URL"** and add exactly (host only, no
   path, no slash at the end):

   ```
   http://192.168.1.100
   ```

2. **Install the EA.** Copy `mt4/CurrencyMeterFeed.mq4` into your MT4
   terminal's `MQL4/Experts/` folder. In MetaTrader open it once in
   MetaEditor (or just restart MT4) so it compiles.

3. **Attach it to a chart.** Drag `CurrencyMeterFeed` from the Navigator onto
   **any one chart** (symbol/timeframe don't matter). In the dialog:

   - Go to the **Inputs** tab and set:
     - `ServerURL` → `http://192.168.1.100/tick`   *(note the `/tick`)*
     - `SymbolSuffix` → leave blank, unless your broker names symbols like
       `EURUSD.raw` or `EURUSDm` — then enter that suffix (`.raw`, `m`, …).
   - Click **OK**.

4. **Check the Experts tab** (bottom of MT4). Within a second or two you
   should see `POST ok (HTTP 200)`. If you see an error, jump to
   *Troubleshooting* below.

## Step 5 — View the currency strength meter

Open a browser and go to:

```
http://192.168.1.100
```

(Use your own IP.) You'll see the live bar chart, signals table, and the
%/Index/Momentum panel updating as quotes arrive. If the feed stops, the
page shows a **"STALE DATA"** banner after ~5 seconds.

---

## Try it without MT4 (optional demo)

To see the UI working before wiring up MT4, run the built-in mock feed (this
uses the plain local defaults — no LAN IP or port 80 needed):

```bash
source .venv/bin/activate
python bridge/server.py &        # http://127.0.0.1:8010
python bridge/mock_feed.py       # replays sample quotes every ~1s
```

Then open `http://127.0.0.1:8010`. Stop it with `kill %1` when done.

---

## Troubleshooting

**Experts tab shows `WebRequest error 5200`** — MT4 rejected the URL. Under
Wine this almost always means the address or port is wrong:

- You must use the **LAN IP**, not `127.0.0.1` or `localhost`.
- You must use **port 80** — MT4 under Wine refuses custom ports like `:8010`.
  Make sure the bridge is started on port 80 (the default for `meterctl.sh`)
  and that neither the whitelist nor `ServerURL` has a port number in it.

**Experts tab shows `WebRequest error 4060`** — the URL isn't whitelisted.
Re-check Step 4.1: it must be `http://192.168.1.100` (your IP), host only,
and the checkbox must be ticked.

**`ServerURL` has a stray space** — the EA log will show a double space
before the URL. Retype it with no leading/trailing spaces.

**Nothing wrong but still failing** — copy `mt4/WebRequestTest.mq4` into
`MQL4/Scripts/`, whitelist the URLs it prints, and drag it onto a chart. It
tests an external site and your local bridge, so you can see exactly which
one fails and with what code.

**Page says "STALE DATA"** — the bridge is up but not receiving quotes.
Check the MT4 Experts tab (is the EA sending?) and `./meterctl.sh status`.

**`No symbols found` in the Experts tab** — your broker suffixes symbol
names. Set the EA's `SymbolSuffix` input (Step 4.3) to match.
___CM_EOF___
cat > "$CM_DIR/com.currencymeter.bridge.plist" <<'___CM_EOF___'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  LaunchDaemon for the Currency Meter bridge server.

  Runs bridge/server.py as root at boot so it can bind port 80 (the port
  MT4-under-Wine requires), restarts it if it ever exits, and logs to
  server.log. Once installed you never start it by hand or type sudo again.

  Binds 0.0.0.0 (all interfaces) on purpose: a daemon should keep working
  when your DHCP LAN IP changes, without needing a restart. If you'd rather
  it claim port 80 only on your LAN IP (leaving 127.0.0.1:80 free for other
  local web apps), change METER_HOST below to that fixed IP -- but then
  you'll need to reload the daemon whenever the IP changes.

  Install / manage: see the commands your assistant printed, or:
    sudo cp com.currencymeter.bridge.plist /Library/LaunchDaemons/
    sudo chown root:wheel /Library/LaunchDaemons/com.currencymeter.bridge.plist
    sudo launchctl bootstrap system /Library/LaunchDaemons/com.currencymeter.bridge.plist
-->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.currencymeter.bridge</string>

  <key>ProgramArguments</key>
  <array>
    <string>/ABSOLUTE/PATH/TO/currency_meter/.venv/bin/python</string>
    <string>/ABSOLUTE/PATH/TO/currency_meter/bridge/server.py</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>METER_HOST</key>
    <string>0.0.0.0</string>
    <key>METER_PORT</key>
    <string>80</string>
  </dict>

  <key>WorkingDirectory</key>
  <string>/ABSOLUTE/PATH/TO/currency_meter</string>

  <!-- Start at boot. -->
  <key>RunAtLoad</key>
  <true/>

  <!-- Restart if it exits/crashes. ThrottleInterval avoids a tight crash
       loop if startup fails (waits 10s between relaunch attempts). -->
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>

  <key>StandardOutPath</key>
  <string>/ABSOLUTE/PATH/TO/currency_meter/server.log</string>
  <key>StandardErrorPath</key>
  <string>/ABSOLUTE/PATH/TO/currency_meter/server.log</string>
</dict>
</plist>
___CM_EOF___

chmod +x "$CM_DIR/meterctl.sh"
ok "wrote project files"

# ---- python environment ----
say "Creating virtualenv and installing dependencies…"
python3 -m venv "$CM_DIR/.venv"
"$CM_DIR/.venv/bin/python" -m pip install --quiet --upgrade pip
"$CM_DIR/.venv/bin/pip" install --quiet -r "$CM_DIR/bridge/requirements.txt"
ok "dependencies installed (aiohttp)"

# ---- self-check ----
( cd "$CM_DIR/bridge" && "$CM_DIR/.venv/bin/python" test_meter.py >/dev/null 2>&1 ) \
  && ok "algorithm self-test passed" || say "$(c 33 'note:') self-test skipped/failed (non-fatal)"

printf '\n'
ok "$(c 1 'Installed.')"
cat <<DONE

Next steps:

  1. Try the demo (no MT4 needed):
       cd "$CM_DIR"
       source .venv/bin/activate
       python bridge/server.py &
       python bridge/mock_feed.py
     then open  http://127.0.0.1:8010

  2. Manage the server:
       cd "$CM_DIR"
       ./meterctl.sh start | stop | restart | status | logs

  3. Connect real MT4 and (on macOS) run at boot:
       see  "$CM_DIR/INSTALL.md"   (full MT4 + Wine + port-80 + launchd guide)

DONE
