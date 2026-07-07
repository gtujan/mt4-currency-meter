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
   TestOne("LOCAL-IP  ", "http://192.168.68.103:8010/state");
}
//+------------------------------------------------------------------+
