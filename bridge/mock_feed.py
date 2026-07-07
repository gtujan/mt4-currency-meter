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
