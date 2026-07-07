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
