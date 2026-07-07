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
