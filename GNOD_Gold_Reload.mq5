//+------------------------------------------------------------------+
//|                                           GNOD_Gold_Reload.mq5   |
//|     GNOD Gold Reload - Impulse & Pullback continuation EA        |
//|                     XAUUSD / GOLD • H1 Timeframe                 |
//+------------------------------------------------------------------+
#define EA_NAME    "GNOD Gold Reload"
#define EA_VERSION "1.0.0"                     // 3 phần X.Y.Z, khớp tag vX.Y.Z

#property copyright EA_NAME
#property version   EA_VERSION
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Kiểu đổi giờ mùa hè của SERVER (chỉ dùng trong Strategy Tester)
enum ENUM_SRV_DST
{
   SRV_DST_NONE = 0, // None (e.g. Exness, UTC+0)
   SRV_DST_US   = 1, // US rules (e.g. IC Markets, UTC+2/+3)
   SRV_DST_EU   = 2  // EU rules
};

//--- INPUT PARAMETERS
//--- Tên biến giữ nguyên để các file .set cũ vẫn nạp được; chỉ nhóm lại và đặt lại nhãn hiển thị.
//--- Đơn vị pip trên XAUUSD: 1 pip = $0.10 (250 pip = $25.00)

input group "1. Position Sizing"
input double       Lot                      = 0.0;              // Fixed lot (0 = auto by balance)
input double       percent                  = 0.01;             // Auto lot: lot per balance step
input double       balance                  = 2000.0;           // Auto lot: balance step
input int          MaxCountOrders           = 2;                // Max simultaneous positions

input group "2. Stop Loss / Take Profit"
input double       RST                      = 400.0;            // Stop Loss (pips)
input double       TKProfit                 = 250.0;            // Take Profit (pips)

input group "3. Trailing Stop"
input bool         trail                    = true;             // Enable trailing stop
input double       TrailStart               = 160.0;            // Activate when profit reaches (pips)
input double       TrailFrom                = 160.0;            // Minimum locked profit (pips)
input double       TrailCushionPips         = 15.0;             // Trail distance behind price (pips)
input double       TrailStep                = 5.0;              // Trail step (points)
input bool         StretchTPWithTrail       = true;             // Extend TP when price approaches it

input group "4. Entry Signal (H1)"
input double       ImpulseMinPips           = 200.0;            // Min impulse, bars 12..6 (pips)
input double       ImpulseBarMinPips        = 30.0;             // Min breakout move, bars 8..6 (pips)
input double       PullbackMinPips          = 80.0;             // Min pullback from 8-bar extreme (pips)
input int          TrendMAPeriod            = 20;               // Trend SMA period
input int          FastMAPeriod             = 5;                // Fast SMA period
input bool         RequireFastDip           = false;            // Require close beyond fast SMA
input int          CooldownHoursSameDir     = 3;                // Cooldown between same-direction entries (hours)

input group "5. Trading Session (reference time = New York + 7h)"
input int          BeginHour                = 15;               // Session start hour
input int          BeginMinute              = 0;                // Session start minute
input int          EndHour                  = 11;               // Session end hour
input int          EndMinute                = 0;                // Session end minute
input bool         SkipWhipsawHours         = true;             // Skip entries at 16:00 and 23:00
input bool         ONB                      = false;            // Buy only
input bool         ONS                      = false;            // Sell only

input group "6. Friday Close"
input bool         Friday                   = true;             // Close all positions on Friday
input int          FrHour                   = 0;                // Close hour (0 = before market close)
input int          FridayCloseMinutesBefore = 31;               // Minutes before market close (when hour = 0)

input group "7. Server Time Sync"
input bool         AutoSessionTime          = true;             // Convert server time to reference time
input int          ServerUTCOffsetWinter    = 0;                // [Tester] Server UTC offset in winter
input ENUM_SRV_DST ServerDSTMode            = SRV_DST_NONE;     // [Tester] Server daylight saving mode

input group "8. News Filter"
input bool         NewsFilter               = false;            // Enable news filter
input int          DontOpBef                = 30;               // No entries before news (minutes)
input int          DontOpAft                = 30;               // No entries after news (minutes)
input bool         IH                       = true;             // Filter high-importance news
input bool         IM                       = false;            // Filter moderate-importance news

input group "9. Execution & Display"
input int          MaxSpred                 = 150;              // Max spread (points, 2-digit gold)
input int          Slippage                 = 50;               // Max slippage (points)
input long         Magic                    = 222;              // Magic number
input string       Commen                   = EA_NAME;          // Order comment
input bool         ShowInfoPanel            = true;             // Show info panel on chart

//--- Global variables
CTrade        g_trade;
CPositionInfo g_pos;
datetime      g_lastBarTime       = 0;
datetime      g_lastBuyOpenTime   = 0;
datetime      g_lastSellOpenTime  = 0;

//+------------------------------------------------------------------+
//| Quy đổi 1 Pip trên XAUUSD ($0.10) và các cặp ngoại tệ            |
//+------------------------------------------------------------------+
double GetPipSize()
{
   string sym = _Symbol;
   StringToUpper(sym);
   if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0)
      return 0.10;

   if(_Digits == 3 || _Digits == 5)
      return 10.0 * _Point;
   return _Point;
}

//+------------------------------------------------------------------+
//| Chuẩn hóa Spread về đơn vị Point chuẩn 2 chữ số của XAUUSD       |
//+------------------------------------------------------------------+
int GetNormalizedSpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   double stdPoint = GetPipSize() * 0.1;
   if(stdPoint <= 0.0)
      stdPoint = _Point;

   return (int)MathRound((ask - bid) / stdPoint);
}

//+------------------------------------------------------------------+
//| Tính khối lượng vào lệnh theo Balance Step & Lot Step            |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double rawLot = Lot;
   if(rawLot <= 0.0)
   {
      double accBal  = AccountInfoDouble(ACCOUNT_BALANCE);
      double stepBal = (balance > 0.0) ? balance : 250.0;
      int    blocks  = (int)MathFloor(accBal / stepBal);
      rawLot         = blocks * percent;
   }

   double marginPerLot = 0.0;
   double ask          = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, ask, marginPerLot) && marginPerLot > 0.0)
   {
      double freeMargin   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double maxMarginLot = (freeMargin * 0.80) / marginPerLot;
      if(rawLot > maxMarginLot && maxMarginLot >= minLot)
         rawLot = maxMarginLot;
   }

   if(rawLot < minLot)
      rawLot = minLot;
   if(rawLot > maxLot)
      rawLot = maxLot;

   if(lotStep > 0.0)
      rawLot = MathFloor((rawLot + 1e-9) / lotStep) * lotStep;

   return NormalizeDouble(rawLot, 2);
}

//+------------------------------------------------------------------+
//| Đếm số lệnh đang mở của EA                                       |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(g_pos.SelectByIndex(i))
      {
         if(g_pos.Symbol() == _Symbol && g_pos.Magic() == Magic)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Ngày Chủ Nhật thứ n (n>=1) hoặc cuối cùng (n=0) của tháng        |
//+------------------------------------------------------------------+
int NthSundayOfMonth(int year, int mon, int n)
{
   MqlDateTime d;
   if(n > 0)
   {
      datetime first = StringToTime(StringFormat("%04d.%02d.01 00:00", year, mon));
      TimeToStruct(first, d);
      int firstSunday = 1 + ((7 - d.day_of_week) % 7);
      return firstSunday + 7 * (n - 1);
   }
   // Chủ Nhật cuối cùng của tháng (tháng 3 và tháng 10 đều có 31 ngày)
   datetime last = StringToTime(StringFormat("%04d.%02d.31 00:00", year, mon));
   TimeToStruct(last, d);
   return 31 - d.day_of_week;
}

//+------------------------------------------------------------------+
//| Mỹ đang giờ mùa hè? (CN thứ 2 tháng 3 07:00 UTC -> CN đầu tháng 11 06:00 UTC) |
//+------------------------------------------------------------------+
bool IsUSDST(datetime utc)
{
   MqlDateTime d;
   TimeToStruct(utc, d);
   datetime start = StringToTime(StringFormat("%04d.03.%02d 07:00", d.year, NthSundayOfMonth(d.year, 3, 2)));
   datetime end   = StringToTime(StringFormat("%04d.11.%02d 06:00", d.year, NthSundayOfMonth(d.year, 11, 1)));
   return (utc >= start && utc < end);
}

//+------------------------------------------------------------------+
//| Châu Âu đang giờ mùa hè? (CN cuối tháng 3 -> CN cuối tháng 10, 01:00 UTC) |
//+------------------------------------------------------------------+
bool IsEUDST(datetime utc)
{
   MqlDateTime d;
   TimeToStruct(utc, d);
   datetime start = StringToTime(StringFormat("%04d.03.%02d 01:00", d.year, NthSundayOfMonth(d.year, 3, 0)));
   datetime end   = StringToTime(StringFormat("%04d.10.%02d 01:00", d.year, NthSundayOfMonth(d.year, 10, 0)));
   return (utc >= start && utc < end);
}

//+------------------------------------------------------------------+
//| Độ lệch (giây) của giờ server so với UTC                         |
//| Live: tự đo bằng TimeTradeServer() - TimeGMT()                   |
//| Tester: không đo được -> dùng input ServerUTCOffsetWinter + DST  |
//+------------------------------------------------------------------+
int GetServerUTCOffsetSec(datetime serverTime)
{
   if(!MQLInfoInteger(MQL_TESTER))
   {
      long diff = (long)(TimeTradeServer() - TimeGMT());
      return (int)(MathRound((double)diff / 1800.0) * 1800.0);
   }

   int      off       = ServerUTCOffsetWinter * 3600;
   datetime utcApprox = serverTime - off;
   if(ServerDSTMode == SRV_DST_US && IsUSDST(utcApprox)) off += 3600;
   if(ServerDSTMode == SRV_DST_EU && IsEUDST(utcApprox)) off += 3600;
   return off;
}

//+------------------------------------------------------------------+
//| Giờ chuẩn = giờ New York + 7h (UTC+3 mùa hè Mỹ, UTC+2 mùa đông)  |
//+------------------------------------------------------------------+
datetime GetReferenceTime()
{
   datetime srv = TimeCurrent();
   if(!AutoSessionTime)
      return srv;

   datetime utc = srv - GetServerUTCOffsetSec(srv);
   return utc + (IsUSDST(utc) ? 3 : 2) * 3600;
}

//+------------------------------------------------------------------+
//| [Live] Số giây từ 00:00 (giờ server) đến lúc symbol đóng cửa     |
//| ngày Thứ Sáu, lấy từ lịch phiên của sàn. -1 nếu không xác định   |
//+------------------------------------------------------------------+
int GetFridaySessionEndSec()
{
   datetime from, to;
   int lastEnd = -1;
   for(uint i = 0; i < 10; i++)
   {
      if(!SymbolInfoSessionTrade(_Symbol, FRIDAY, i, from, to))
         break;
      if((int)to > lastEnd)
         lastEnd = (int)to;
   }
   // Phiên kéo tới 24:00 mà Thứ Bảy vẫn còn phiên -> giờ đóng tuần nằm ở Thứ Bảy (server lệch múi xa), bỏ qua
   if(lastEnd >= 86400 && SymbolInfoSessionTrade(_Symbol, SATURDAY, 0, from, to))
      return -1;
   return lastEnd;
}

//+------------------------------------------------------------------+
//| Kiểm tra khung giờ cho phép mở lệnh mới (15:00 -> 11:00 giờ chuẩn)|
//+------------------------------------------------------------------+
bool IsTradingSessionOpen()
{
   MqlDateTime dt;
   TimeToStruct(GetReferenceTime(), dt);

   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;

   if(dt.hour == 0)
      return false;

   // Trong báo cáo Gold_1 trên Exness XAUUSDc: Giờ 16:00 và 23:00 từng lỗ.
   // LƯU Ý: 2 giờ này được rút ra theo giờ server Exness (UTC+0); từ v1.92 chúng được áp theo giờ chuẩn (NY+7)
   if(SkipWhipsawHours && (dt.hour == 16 || dt.hour == 23))
      return false;

   int curMinutes   = dt.hour * 60 + dt.min;
   int startMinutes = BeginHour * 60 + BeginMinute;
   int endMinutes   = EndHour * 60 + EndMinute;

   if(startMinutes <= endMinutes)
   {
      return (curMinutes >= startMinutes && curMinutes <= endMinutes);
   }
   else
   {
      return (curMinutes >= startMinutes || curMinutes <= endMinutes);
   }
}

//+------------------------------------------------------------------+
//| Kiểm tra bộ lọc tin tức từ Lịch kinh tế tích hợp của MT5         |
//+------------------------------------------------------------------+
bool IsBlockedByNews()
{
   if(!NewsFilter)
      return false;

   MqlCalendarValue values[];
   datetime fromTime = TimeCurrent() - DontOpAft * 60;
   datetime toTime   = TimeCurrent() + DontOpBef * 60;

   if(!CalendarValueHistory(values, fromTime, toTime, NULL, "USD"))
      return false;

   for(int i = 0; i < ArraySize(values); i++)
   {
      MqlCalendarEvent event;
      if(CalendarEventById(values[i].event_id, event))
      {
         if(IH && event.importance == CALENDAR_IMPORTANCE_HIGH)
            return true;
         if(IM && event.importance == CALENDAR_IMPORTANCE_MODERATE)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Đóng toàn bộ lệnh vào tối Thứ Sáu (23:29 nếu FrHour == 0)        |
//+------------------------------------------------------------------+
void ManageFridayClose()
{
   if(!Friday)
      return;

   // 1) Theo giờ chuẩn: vàng đóng tuần lúc 24:00 Thứ Sáu (= 17:00 New York), đúng cả mùa đông lẫn mùa hè
   MqlDateTime dt;
   TimeToStruct(GetReferenceTime(), dt);

   bool shouldClose = false;
   if(dt.day_of_week == 5)
   {
      if(FrHour == 0)
         shouldClose = (dt.hour * 60 + dt.min >= 1440 - FridayCloseMinutesBefore);
      else
         shouldClose = (dt.hour >= FrHour);
   }

   // 2) [Live] Lớp an toàn: đọc giờ đóng cửa Thứ Sáu thật từ lịch phiên của sàn
   //    (Tester chỉ có lịch phiên hiện tại, không có lịch theo mùa trong quá khứ nên không dùng)
   if(!shouldClose && FrHour == 0 && !MQLInfoInteger(MQL_TESTER))
   {
      MqlDateTime sdt;
      TimeCurrent(sdt);
      int endSec = GetFridaySessionEndSec();
      if(sdt.day_of_week == 5 && endSec > 0)
         shouldClose = (sdt.hour * 3600 + sdt.min * 60 + sdt.sec >= endSec - FridayCloseMinutesBefore * 60);
   }

   if(!shouldClose)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(g_pos.SelectByIndex(i))
      {
         if(g_pos.Symbol() == _Symbol && g_pos.Magic() == Magic)
            g_trade.PositionClose(g_pos.Ticket(), Slippage);
      }
   }
}

//+------------------------------------------------------------------+
//| Quản lý Trailing Stop: Khóa cứng tối thiểu +160 pip ($16.00)     |
//| (Tuyệt đối không cho tụt về $12.50 như Gold_2) + Nới TP khi cần  |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(!trail)
      return;

   double pipSize     = GetPipSize();
   double startDist   = TrailStart       * pipSize; // 160 pip = $16.00
   double fromDist    = TrailFrom        * pipSize; // Khóa tối thiểu 160 pip = $16.00 (Không bao giờ thấp hơn $16!)
   double cushionDist = TrailCushionPips * pipSize; // Khoảng đệm 15 pip = $1.50 khi giá chạy vượt xa > $17.50
   double stepPrice   = TrailStep        * _Point;
   if(stepPrice <= 0.0)
      stepPrice = _Point;

   long   stopLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist  = (stopLevelPts > 0) ? (stopLevelPts + 2) * _Point : 2 * _Point;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i))
         continue;
      if(g_pos.Symbol() != _Symbol || g_pos.Magic() != Magic)
         continue;

      ulong  ticket    = g_pos.Ticket();
      double openPrice = g_pos.PriceOpen();
      double curSL     = g_pos.StopLoss();
      double curTP     = g_pos.TakeProfit();

      if(g_pos.PositionType() == POSITION_TYPE_BUY)
      {
         double profitMove = bid - openPrice;
         if(profitMove >= startDist)
         {
            // 1. Mốc khóa sàn bắt buộc là OpenPrice + $16.00 (giống Gold_1 để bảo toàn 100% lệnh thắng >= $16)
            // 2. Nếu giá bứt tốc vượt quá $16.00 + cushionDist ($17.50), SL sẽ trượt bám theo Bid - $1.50
            double rawTargetSL = openPrice + fromDist;
            if(profitMove > fromDist + cushionDist)
               rawTargetSL = bid - cushionDist;

            if(rawTargetSL > bid - minStopDist)
               rawTargetSL = bid - minStopDist;

            double steps = MathFloor(((rawTargetSL - openPrice) + 1e-9) / stepPrice);
            double newSL = NormalizeDouble(openPrice + steps * stepPrice, _Digits);

            // Tự động nới rộng TP (Stretch TP) nếu giá tiến sát vào vùng 40 pip ($4.00) trước TP
            double newTP = curTP;
            if(StretchTPWithTrail && curTP > 0.0 && (curTP - bid) <= 40.0 * pipSize)
            {
               newTP = NormalizeDouble(bid + 120.0 * pipSize, _Digits);
            }

            if(newSL >= NormalizeDouble(openPrice + fromDist, _Digits))
            {
               bool slImproved  = (curSL < openPrice || (newSL - curSL) >= stepPrice - 1e-9);
               bool tpStretched = (MathAbs(newTP - curTP) >= pipSize);
               if(slImproved || tpStretched)
               {
                  g_trade.PositionModify(ticket, slImproved ? newSL : curSL, newTP);
               }
            }
         }
      }
      else if(g_pos.PositionType() == POSITION_TYPE_SELL)
      {
         double profitMove = openPrice - ask;
         if(profitMove >= startDist)
         {
            double rawTargetSL = openPrice - fromDist;
            if(profitMove > fromDist + cushionDist)
               rawTargetSL = ask + cushionDist;

            if(rawTargetSL < ask + minStopDist)
               rawTargetSL = ask + minStopDist;

            double steps = MathFloor(((openPrice - rawTargetSL) + 1e-9) / stepPrice);
            double newSL = NormalizeDouble(openPrice - steps * stepPrice, _Digits);

            double newTP = curTP;
            if(StretchTPWithTrail && curTP > 0.0 && (ask - curTP) <= 40.0 * pipSize)
            {
               newTP = NormalizeDouble(ask - 120.0 * pipSize, _Digits);
            }

            if(newSL <= NormalizeDouble(openPrice - fromDist, _Digits))
            {
               bool slImproved  = (curSL == 0.0 || curSL > openPrice || (curSL - newSL) >= stepPrice - 1e-9);
               bool tpStretched = (MathAbs(newTP - curTP) >= pipSize);
               if(slImproved || tpStretched)
               {
                  g_trade.PositionModify(ticket, slImproved ? newSL : curSL, newTP);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Tính giá trị tín hiệu H1 (1 = BUY, -1 = SELL, 0 = HOLD)          |
//+------------------------------------------------------------------+
int EvaluateH1Signal()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, PERIOD_H1, 0, 30, rates);
   if(copied < 25)
      return 0;

   double pipSize     = GetPipSize();
   double minImpulse  = ImpulseMinPips    * pipSize; // 200 pip = $20.00 (Giống Gold_1)
   double minBarBody  = ImpulseBarMinPips * pipSize; // 30 pip  = $3.00  (Giống Gold_1)
   double minPullback = PullbackMinPips   * pipSize; // 80 pip  = $8.00  (Giống Gold_1)

   double sumTrend = 0.0;
   for(int i = 1; i <= TrendMAPeriod; i++)
      sumTrend += rates[i].close;
   double smaTrend = sumTrend / TrendMAPeriod;

   double sumFast = 0.0;
   for(int i = 1; i <= FastMAPeriod; i++)
      sumFast += rates[i].close;
   double smaFast = sumFast / FastMAPeriod;

   double highest8 = rates[1].high;
   double lowest8  = rates[1].low;
   for(int i = 2; i <= 8; i++)
   {
      if(rates[i].high > highest8) highest8 = rates[i].high;
      if(rates[i].low  < lowest8)  lowest8  = rates[i].low;
   }

   double imp6_12     = rates[6].close - rates[12].close;
   double imp7_11     = rates[7].close - rates[11].close;
   double wave8_6     = rates[6].close - rates[8].open;
   double wave8_7     = rates[7].close - rates[8].open;
   double maxBuyWave  = MathMax(wave8_6, wave8_7);
   double minSellWave = MathMin(wave8_6, wave8_7);

   double c1 = rates[1].close;

   bool buyImpulse  = (imp6_12 >= minImpulse && imp7_11 > 0.0 && maxBuyWave >= minBarBody);
   bool buyTrend    = (c1 > smaTrend);
   bool buyPullback = ((highest8 - c1) >= minPullback && c1 > rates[12].close);
   bool buyDip      = (!RequireFastDip || c1 <= smaFast);

   if(buyImpulse && buyTrend && buyPullback && buyDip)
      return 1;

   bool sellImpulse  = (imp6_12 <= -minImpulse && imp7_11 < 0.0 && minSellWave <= -minBarBody);
   bool sellTrend    = (c1 < smaTrend);
   bool sellPullback = ((c1 - lowest8) >= minPullback && c1 < rates[12].close);
   bool sellBounce   = (!RequireFastDip || c1 >= smaFast);

   if(sellImpulse && sellTrend && sellPullback && sellBounce)
      return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| Mở lệnh BUY hoặc SELL với cách tính SL/TP chuẩn theo Bid/Ask     |
//+------------------------------------------------------------------+
bool ExecuteTrade(int signal)
{
   if(signal == 1 && ONS)  return false;
   if(signal == -1 && ONB) return false;
   if(ONB && ONS)          return false;

   double pipSize = GetPipSize();
   double tpDist  = TKProfit * pipSize;
   double slDist  = RST      * pipSize;
   double vol     = CalculateLotSize();

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(signal == 1)
   {
      double sl = (RST > 0.0)      ? NormalizeDouble(bid - slDist, _Digits) : 0.0;
      double tp = (TKProfit > 0.0) ? NormalizeDouble(bid + tpDist, _Digits) : 0.0;
      return g_trade.Buy(vol, _Symbol, ask, sl, tp, Commen);
   }
   else if(signal == -1)
   {
      double sl = (RST > 0.0)      ? NormalizeDouble(ask + slDist, _Digits) : 0.0;
      double tp = (TKProfit > 0.0) ? NormalizeDouble(ask - tpDist, _Digits) : 0.0;
      return g_trade.Sell(vol, _Symbol, bid, sl, tp, Commen);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Hiển thị bảng thông tin trên biểu đồ                             |
//+------------------------------------------------------------------+
void UpdateInfoPanel()
{
   if(!ShowInfoPanel)
      return;

   int    spreadPts = GetNormalizedSpreadPoints();
   double nextLot   = CalculateLotSize();
   int    openDeals = CountOpenPositions();
   bool   inSession = IsTradingSessionOpen();
   datetime refTime = GetReferenceTime();
   int    offHours  = GetServerUTCOffsetSec(TimeCurrent()) / 3600;

   string info = StringFormat(
      "=== " + EA_NAME + " v" + EA_VERSION + " ===\n"
      "Symbol: %s | Magic: %d\n"
      "Calculated Next Lot: %.2f (Balance Step: %.0f)\n"
      "Open Deals: %d / %d\n"
      "Current Spread (norm): %d / %d pts\n"
      "Server: %s (UTC%+d) | Ref time: %s\n"
      "Session (%02d:%02d - %02d:%02d ref): %s\n"
      "SL: %.0f pips ($%.1f) | TP: %.0f pips ($%.1f)\n"
      "Trailing: %s (MinLock +$%.1f / Cushion $%.1f / StretchTP: %s)",
      _Symbol, Magic,
      nextLot, balance,
      openDeals, MaxCountOrders,
      spreadPts, MaxSpred,
      TimeToString(TimeCurrent(), TIME_MINUTES), offHours, TimeToString(refTime, TIME_DATE | TIME_MINUTES),
      BeginHour, BeginMinute, EndHour, EndMinute,
      (inSession ? "ACTIVE" : "PAUSED"),
      RST, RST * GetPipSize(), TKProfit, TKProfit * GetPipSize(),
      (trail ? "ON" : "OFF"), TrailFrom * GetPipSize(), TrailCushionPips * GetPipSize(), (StretchTPWithTrail ? "YES" : "NO")
   );
   Comment(info);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(Magic);
   g_trade.SetDeviationInPoints(Slippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_lastBarTime = iTime(_Symbol, PERIOD_H1, 0);
   UpdateInfoPanel();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(ShowInfoPanel)
      Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   ManageFridayClose();
   ManageTrailingStop();
   UpdateInfoPanel();

   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   if(currentBarTime == 0 || currentBarTime == g_lastBarTime)
      return;

   g_lastBarTime = currentBarTime;

   if(!IsTradingSessionOpen())
      return;

   if(CountOpenPositions() >= MaxCountOrders)
      return;

   int currentSpread = GetNormalizedSpreadPoints();
   if(currentSpread > MaxSpred)
      return;

   if(IsBlockedByNews())
      return;

   int signal = EvaluateH1Signal();
   if(signal == 0)
      return;

   // Cooldown 3h cùng chiều: Chặn nhồi lệnh 1h-2h (PF=0.97), nhưng CHO PHÉP vào lệnh thứ 2 ở giờ thứ 3-5 (WR=83.9%, PF=2.48)!
   datetime now = TimeCurrent();
   if(signal == 1 && (now - g_lastBuyOpenTime) < CooldownHoursSameDir * 3600)
      return;
   if(signal == -1 && (now - g_lastSellOpenTime) < CooldownHoursSameDir * 3600)
      return;

   if(ExecuteTrade(signal))
   {
      if(signal == 1)  g_lastBuyOpenTime  = now;
      if(signal == -1) g_lastSellOpenTime = now;
   }
}
//+------------------------------------------------------------------+
