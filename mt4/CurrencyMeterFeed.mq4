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
