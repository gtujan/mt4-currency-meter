# Currency Strength Meter

A small web app, fed live from MetaTrader 4 over native `WebRequest()` HTTP
POST — no DDE, no ZeroMQ, no DLL. All math (ranks, strengths, signals,
gauges, momentum) runs in Python (`bridge/meter.py`), fetching bid and ask values from MT4 and 
renders it on the browser. No need for DDE or Excel.

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
