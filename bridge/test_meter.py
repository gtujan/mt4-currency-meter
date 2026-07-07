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
