//+------------------------------------------------------------------+
//|                                        TrendPermissionEA_v3_4.mq5 |
//|                        Layer 0 Risk Governor + Execution Layer    |
//|                                                       Version 3.4 |
//+------------------------------------------------------------------+
#property copyright "TrendPermission"
#property version   "3.4"
#property description "Daily reset based on New York midnight"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "00. Layer 0 - Global Risk Governor"
input double BasketStopLoss_USD    = 20.0;     // Basket Stop Loss ($) - per basket, resets after close
input double DailyLossLimit_USD    = 100.0;    // Daily Loss Limit ($) - disables trading for day
input double DailyProfitTarget_USD = 100.0;    // Daily Realized Profit Target ($)
input double PeakGivebackFrac      = 0.25;     // Fraction of Peak Profit Allowed to Give Back
input double MinProfitToProtect_USD = 5.0;     // Minimum floating profit before giveback logic activates
input int    BrokerToNYOffsetHours = -7;       // Broker time offset to New York (hours)

input group "01. Trend EMAs (FROZEN - DO NOT MODIFY)"
input int    TrendEMA_Len = 200;      // Trend EMA Length
input int    FastEMA_Len  = 10;       // Fast EMA Length  
input int    SlowEMA_Len  = 30;       // Slow EMA Length

input group "02. Execution Settings"
input double LotSize            = 0.01;    // Fixed Lot Size
input double TakeProfitDollars  = 5.0;     // Take Profit in Dollars
input int    MagicNumber        = 123456;  // Magic Number

input group "03. Debug"
input bool   EnableDebugPrints  = true;    // Enable Debug Prints

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES - LAYER 0: RISK GOVERNOR                        |
//+------------------------------------------------------------------+

// === Account-Level Daily Tracking (v3.4: NY-based) ===
double dailyStartEquity;           // Equity at start of NY trading day
double dailyRealizedPL;            // Realized P&L for the NY day
bool   dailyLossLimitHit;          // TRUE = trading disabled for NY day
datetime currentNYDate;            // Current New York date (midnight)

// === Basket-Level Tracking (Floating P&L based) ===
double basketFloatingPL;           // Current floating P&L of all basket positions
double basketPeakPL;               // Peak floating P&L during current basket
bool   basketActive;               // TRUE = we have open positions in basket
bool   profitProtectionActivated;  // TRUE = profit protection is active

// === Status Display ===
string disableReason;              // Reason trading is disabled
bool   tradingDisabled;            // Master trading disable flag

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES - TREND PERMISSION MODULE (FROZEN)              |
//+------------------------------------------------------------------+

// === EMA Arrays (FROZEN) ===
double ema200High[], ema200Low[];
double emaFast[], emaSlow[];

// === Slope Variables (FROZEN) ===
double emaFastSlope, emaSlowSlope;
double emaFastSlopePrev, emaFastD2;
double emaGap, emaGapPrev, gapSlope;

// === Permission States (FROZEN - AUTHORITATIVE OUTPUTS) ===
bool longEntryAllowed = false;
bool shortEntryAllowed = false;
bool longEntryAllowedPrev = false;
bool shortEntryAllowedPrev = false;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES - EXECUTION LAYER                               |
//+------------------------------------------------------------------+

// === Trade State Control ===
bool tradeTakenThisPermission = false;
bool hasOpenPosition = false;

// === Bar Detection ===
datetime lastProcessedTime = 0;

// === Trade Object ===
CTrade trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Validate symbol
    if(_Symbol != "XAUUSD")
    {
        Print("ERROR: This EA is designed for XAUUSD only. Current symbol: ", _Symbol);
        return(INIT_FAILED);
    }
    
    // Validate timeframe
    if(_Period != PERIOD_M1)
    {
        Print("ERROR: This EA is designed for M1 timeframe only. Current timeframe: ", EnumToString((ENUM_TIMEFRAMES)_Period));
        return(INIT_FAILED);
    }
    
    // Configure trade object
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    
    // === INITIALIZE LAYER 0 ===
    InitializeLayer0();
    
    // === CREATE VISUAL PANEL ===
    CreatePanel();
    
    Print("==============================================");
    Print("TrendPermissionEA_v3_4 initialized");
    Print("Symbol: ", _Symbol, " | Timeframe: M1");
    Print("Lot Size: ", LotSize);
    Print("Take Profit: $", TakeProfitDollars);
    Print("Magic Number: ", MagicNumber);
    Print("----------------------------------------------");
    Print("LAYER 0 v3.4 - NY MIDNIGHT DAILY RESET");
    Print("Broker to NY Offset: ", BrokerToNYOffsetHours, " hours");
    Print("Basket Stop Loss: $", BasketStopLoss_USD, " (floating P&L)");
    Print("Daily Loss Limit: $", DailyLossLimit_USD, " (disables day)");
    Print("Daily Profit Target: $", DailyProfitTarget_USD);
    Print("Peak Giveback: ", PeakGivebackFrac * 100, "%");
    Print("Min Profit to Protect: $", MinProfitToProtect_USD);
    Print("NY Date: ", TimeToString(currentNYDate, TIME_DATE));
    Print("Daily Start Equity: $", DoubleToString(dailyStartEquity, 2));
    Print("==============================================");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//|                                                                  |
//| ================================================================ |
//| ===== LAYER 0: GLOBAL RISK GOVERNOR (v3.4 - NY Reset) ========== |
//| ================================================================ |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Initialize Layer 0                                               |
//+------------------------------------------------------------------+
void InitializeLayer0()
{
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    // === Account-Level Daily Tracking (v3.4: NY-based) ===
    dailyStartEquity = currentEquity;
    dailyRealizedPL = 0.0;
    dailyLossLimitHit = false;
    currentNYDate = GetNewYorkDate();  // v3.4: Use NY date
    
    // === Basket-Level Tracking ===
    basketFloatingPL = 0.0;
    basketPeakPL = 0.0;
    basketActive = false;
    profitProtectionActivated = false;
    
    // === Status ===
    disableReason = "";
    tradingDisabled = false;
}

//+------------------------------------------------------------------+
//| Get New York Date (v3.4)                                         |
//| Converts broker time to NY time and returns NY midnight          |
//+------------------------------------------------------------------+
datetime GetNewYorkDate()
{
    // Get current broker/server time
    datetime brokerTime = TimeCurrent();
    
    // Apply offset to get New York time
    // BrokerToNYOffsetHours is negative if NY is behind broker
    // Example: If broker is UTC+2 and NY is UTC-5, offset = -7
    datetime nyTime = brokerTime + (BrokerToNYOffsetHours * 3600);
    
    // Normalize to NY midnight (00:00:00)
    MqlDateTime nyDt;
    TimeToStruct(nyTime, nyDt);
    nyDt.hour = 0;
    nyDt.min = 0;
    nyDt.sec = 0;
    
    return StructToTime(nyDt);
}

//+------------------------------------------------------------------+
//| Get Current New York Time (for display)                          |
//+------------------------------------------------------------------+
datetime GetNewYorkTime()
{
    return TimeCurrent() + (BrokerToNYOffsetHours * 3600);
}

//+------------------------------------------------------------------+
//| Calculate Basket Floating P&L                                    |
//+------------------------------------------------------------------+
double CalculateBasketFloatingPL()
{
    double totalPL = 0.0;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                totalPL += PositionGetDouble(POSITION_PROFIT);
            }
        }
    }
    
    return totalPL;
}

//+------------------------------------------------------------------+
//| Layer 0: Main Risk Check - MUST RUN EVERY TICK                  |
//+------------------------------------------------------------------+
void Layer0_RiskCheck()
{
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    // === STEP 0: CHECK FOR NEW NY DAY (v3.4) ===
    CheckDayReset();
    
    // === PRIORITY 1: ACCOUNT-LEVEL DAILY LOSS LIMIT ===
    double dailyPL = currentEquity - dailyStartEquity;
    
    if(dailyPL <= -DailyLossLimit_USD)
    {
        if(!dailyLossLimitHit)
        {
            dailyLossLimitHit = true;
            tradingDisabled = true;
            disableReason = "DAILY LOSS LIMIT HIT";
            
            Print("!!! LAYER 0: DAILY LOSS LIMIT HIT !!!");
            Print(">>> DAILY LOSS LIMIT HIT: $", DoubleToString(dailyPL, 2), " – Trading disabled for NY day");
            Print("Daily Start Equity: $", DoubleToString(dailyStartEquity, 2));
            Print("Current Equity: $", DoubleToString(currentEquity, 2));
            
            CloseAllPositions("Layer0_DailyLossLimit");
            ResetBasketState();
        }
        return;
    }
    
    // === CALCULATE BASKET FLOATING P&L ===
    basketFloatingPL = CalculateBasketFloatingPL();
    
    // === PRIORITY 2: BASKET-LEVEL STOP LOSS ===
    if(hasOpenPosition && basketActive)
    {
        if(basketFloatingPL <= -BasketStopLoss_USD)
        {
            Print("!!! LAYER 0: BASKET STOP HIT !!!");
            Print(">>> BASKET STOP HIT: $", DoubleToString(basketFloatingPL, 2), " floating P&L – Basket closed, trading still enabled");
            
            CloseAllPositions("Layer0_BasketStop");
            ResetBasketState();
            
            disableReason = "BASKET STOP HIT (Ready)";
            return;
        }
        
        // === PRIORITY 3: PEAK PROFIT GIVEBACK CONTROL ===
        if(basketFloatingPL > basketPeakPL)
        {
            basketPeakPL = basketFloatingPL;
        }
        
        if(basketPeakPL >= MinProfitToProtect_USD)
        {
            if(!profitProtectionActivated)
            {
                profitProtectionActivated = true;
                Print(">>> LAYER 0: Profit protection activated at $", DoubleToString(basketPeakPL, 2), " peak floating P&L");
            }
            
            double allowedGiveback = PeakGivebackFrac * basketPeakPL;
            double givebackThreshold = basketPeakPL - allowedGiveback;
            
            if(basketFloatingPL <= givebackThreshold)
            {
                Print("!!! LAYER 0: PEAK GIVEBACK LIMIT HIT !!!");
                Print("Basket Peak P&L: $", DoubleToString(basketPeakPL, 2));
                Print("Current Floating P&L: $", DoubleToString(basketFloatingPL, 2));
                Print("Allowed Giveback: $", DoubleToString(allowedGiveback, 2));
                
                CloseAllPositions("Layer0_PeakGiveback");
                ResetBasketState();
                
                disableReason = "PEAK GIVEBACK (Ready)";
            }
        }
    }
    
    // === DAILY PROFIT TARGET CHECK ===
    if(dailyRealizedPL >= DailyProfitTarget_USD)
    {
        if(!tradingDisabled || disableReason != "DAILY TARGET REACHED")
        {
            tradingDisabled = true;
            disableReason = "DAILY TARGET REACHED";
            
            Print("!!! LAYER 0: DAILY TARGET REACHED !!!");
            Print("Daily Realized P&L: $", DoubleToString(dailyRealizedPL, 2));
            
            CloseAllPositions("Layer0_DailyTarget");
            ResetBasketState();
        }
    }
}

//+------------------------------------------------------------------+
//| Check for Day Reset (v3.4: New York Midnight)                    |
//+------------------------------------------------------------------+
void CheckDayReset()
{
    datetime nyDate = GetNewYorkDate();
    
    if(nyDate != currentNYDate)
    {
        // === NEW YORK DAY DETECTED ===
        currentNYDate = nyDate;
        
        double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        
        // Reset daily tracking
        dailyStartEquity = currentEquity;
        dailyRealizedPL = 0.0;
        dailyLossLimitHit = false;
        
        // Re-enable trading
        tradingDisabled = false;
        disableReason = "";
        
        // Reset basket for new day
        ResetBasketState();
        
        Print("==============================================");
        Print(">>> NEW NY DAY DETECTED – Daily limits reset");
        Print("NY Date: ", TimeToString(nyDate, TIME_DATE));
        Print("NY Time: ", TimeToString(GetNewYorkTime(), TIME_DATE|TIME_MINUTES));
        Print("Broker Time: ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
        Print("Daily Start Equity: $", DoubleToString(dailyStartEquity, 2));
        Print("Trading: ENABLED");
        Print("==============================================");
    }
}

//+------------------------------------------------------------------+
//| Reset Basket State                                               |
//+------------------------------------------------------------------+
void ResetBasketState()
{
    basketFloatingPL = 0.0;
    basketPeakPL = 0.0;
    basketActive = false;
    profitProtectionActivated = false;
}

//+------------------------------------------------------------------+
//| Start New Basket                                                 |
//+------------------------------------------------------------------+
void StartNewBasket()
{
    basketFloatingPL = 0.0;
    basketPeakPL = 0.0;
    basketActive = true;
    profitProtectionActivated = false;
    
    if(EnableDebugPrints)
        Print(">>> NEW BASKET STARTED | Floating P&L tracking begins");
}

//+------------------------------------------------------------------+
//| Close All Positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                double profit = PositionGetDouble(POSITION_PROFIT);
                
                if(trade.PositionClose(ticket))
                {
                    dailyRealizedPL += profit;
                    Print(">>> LAYER 0 CLOSED POSITION | Reason: ", reason, " | Profit: $", DoubleToString(profit, 2));
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Track Realized P&L on Trade Close                                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
    {
        if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
        {
            if(HistoryDealSelect(trans.deal))
            {
                ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
                if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
                {
                    double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
                    long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
                    
                    if(magic == MagicNumber)
                    {
                        dailyRealizedPL += profit;
                        if(EnableDebugPrints)
                            Print(">>> Trade Closed | Profit: $", DoubleToString(profit, 2), " | Daily P&L: $", DoubleToString(dailyRealizedPL, 2));
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    CheckPositionStatus();
    Layer0_RiskCheck();
    UpdatePanel();
    
    if(tradingDisabled)
        return;
    
    ManageTakeProfit();
    
    datetime currentTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentTime <= lastProcessedTime)
        return;
    
    lastProcessedTime = currentTime;
    ProcessNewBar();
}

//+------------------------------------------------------------------+
//| Process New Bar - Main Logic                                     |
//+------------------------------------------------------------------+
void ProcessNewBar()
{
    UpdateTrendPermission();
    CheckPermissionTransitions();
    ExecuteTradeLogic();
}

//+------------------------------------------------------------------+
//|                                                                  |
//| ================================================================ |
//| ===== TREND PERMISSION MODULE (FROZEN – DO NOT MODIFY) ========= |
//| ================================================================ |
//|                                                                  |
//+------------------------------------------------------------------+
void UpdateTrendPermission()
{
    longEntryAllowedPrev = longEntryAllowed;
    shortEntryAllowedPrev = shortEntryAllowed;
    emaFastSlopePrev = emaFastSlope;
    emaGapPrev = emaGap;
    
    if(!CalculateEMAs_Frozen())
        return;
    
    CalculateSlopes_Frozen();
    CalculateGapDynamics_Frozen();
    DetermineEntryPermissions_Frozen();
}

bool CalculateEMAs_Frozen()
{
    ArrayResize(ema200High, 3);
    ArrayResize(ema200Low, 3);
    ArrayResize(emaFast, 3);
    ArrayResize(emaSlow, 3);
    
    ArraySetAsSeries(ema200High, true);
    ArraySetAsSeries(ema200Low, true);
    ArraySetAsSeries(emaFast, true);
    ArraySetAsSeries(emaSlow, true);
    
    int handleEmaHigh = iMA(_Symbol, PERIOD_CURRENT, TrendEMA_Len, 0, MODE_EMA, PRICE_HIGH);
    int handleEmaLow = iMA(_Symbol, PERIOD_CURRENT, TrendEMA_Len, 0, MODE_EMA, PRICE_LOW);
    int handleEmaFast = iMA(_Symbol, PERIOD_CURRENT, FastEMA_Len, 0, MODE_EMA, PRICE_CLOSE);
    int handleEmaSlow = iMA(_Symbol, PERIOD_CURRENT, SlowEMA_Len, 0, MODE_EMA, PRICE_CLOSE);
    
    if(handleEmaHigh == INVALID_HANDLE || handleEmaLow == INVALID_HANDLE || 
       handleEmaFast == INVALID_HANDLE || handleEmaSlow == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create indicator handles");
        return false;
    }
    
    if(CopyBuffer(handleEmaHigh, 0, 0, 3, ema200High) < 3 ||
       CopyBuffer(handleEmaLow, 0, 0, 3, ema200Low) < 3 ||
       CopyBuffer(handleEmaFast, 0, 0, 3, emaFast) < 3 ||
       CopyBuffer(handleEmaSlow, 0, 0, 3, emaSlow) < 3)
    {
        Print("ERROR: Failed to get EMA data - insufficient bars");
        IndicatorRelease(handleEmaHigh);
        IndicatorRelease(handleEmaLow);
        IndicatorRelease(handleEmaFast);
        IndicatorRelease(handleEmaSlow);
        return false;
    }
    
    IndicatorRelease(handleEmaHigh);
    IndicatorRelease(handleEmaLow);
    IndicatorRelease(handleEmaFast);
    IndicatorRelease(handleEmaSlow);
    
    return true;
}

void CalculateSlopes_Frozen()
{
    emaFastSlope = emaFast[1] - emaFast[2];
    emaSlowSlope = emaSlow[1] - emaSlow[2];
    emaFastD2 = emaFastSlope - emaFastSlopePrev;
}

void CalculateGapDynamics_Frozen()
{
    emaGap = emaFast[1] - emaSlow[1];
    gapSlope = emaGap - emaGapPrev;
}

void DetermineEntryPermissions_Frozen()
{
    double completedClose = iClose(_Symbol, PERIOD_CURRENT, 1);
    
    bool isBullRegime = completedClose > ema200High[1];
    bool isBearRegime = completedClose < ema200Low[1];
    
    bool accelUp = (emaFastSlope > 0) && (emaFastD2 > 0);
    bool accelDown = (emaFastSlope < 0) && (emaFastD2 < 0);
    
    bool gapBull = emaGap > 0;
    bool gapBear = emaGap < 0;
    bool gapWidening = gapSlope > 0;
    bool gapNarrowing = gapSlope < 0;
    
    longEntryAllowed = isBullRegime && 
                      (emaSlowSlope > 0) && 
                      (emaFastSlope > 0) && 
                      accelUp && 
                      gapBull && 
                      gapWidening;
                      
    shortEntryAllowed = isBearRegime && 
                       (emaSlowSlope < 0) && 
                       (emaFastSlope < 0) && 
                       accelDown && 
                       gapBear && 
                       gapNarrowing;
}

//+------------------------------------------------------------------+
//| Check Permission Transitions                                     |
//+------------------------------------------------------------------+
void CheckPermissionTransitions()
{
    if(longEntryAllowed && !longEntryAllowedPrev)
    {
        tradeTakenThisPermission = false;
        if(EnableDebugPrints)
            Print(">>> LONG PERMISSION START at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
    }
    
    if(!longEntryAllowed && longEntryAllowedPrev)
    {
        tradeTakenThisPermission = false;
        if(EnableDebugPrints)
            Print(">>> LONG PERMISSION END at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
    }
    
    if(shortEntryAllowed && !shortEntryAllowedPrev)
    {
        tradeTakenThisPermission = false;
        if(EnableDebugPrints)
            Print(">>> SHORT PERMISSION START at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
    }
    
    if(!shortEntryAllowed && shortEntryAllowedPrev)
    {
        tradeTakenThisPermission = false;
        if(EnableDebugPrints)
            Print(">>> SHORT PERMISSION END at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
    }
}

//+------------------------------------------------------------------+
//| Execute Trade Logic                                              |
//+------------------------------------------------------------------+
void ExecuteTradeLogic()
{
    if(tradeTakenThisPermission)
        return;
    
    if(hasOpenPosition)
        return;
    
    if(longEntryAllowed)
    {
        if(OpenBuyTrade())
        {
            tradeTakenThisPermission = true;
            if(!basketActive)
                StartNewBasket();
            if(EnableDebugPrints)
                Print(">>> BUY TRADE OPENED at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
        }
    }
    
    if(shortEntryAllowed)
    {
        if(OpenSellTrade())
        {
            tradeTakenThisPermission = true;
            if(!basketActive)
                StartNewBasket();
            if(EnableDebugPrints)
                Print(">>> SELL TRADE OPENED at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
        }
    }
}

//+------------------------------------------------------------------+
//| Open Buy Trade                                                   |
//+------------------------------------------------------------------+
bool OpenBuyTrade()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    
    if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "TrendPerm_v3_4_BUY"))
        return true;
    else
    {
        Print("ERROR: Failed to open BUY trade. Error: ", GetLastError());
        return false;
    }
}

//+------------------------------------------------------------------+
//| Open Sell Trade                                                  |
//+------------------------------------------------------------------+
bool OpenSellTrade()
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "TrendPerm_v3_4_SELL"))
        return true;
    else
    {
        Print("ERROR: Failed to open SELL trade. Error: ", GetLastError());
        return false;
    }
}

//+------------------------------------------------------------------+
//| Check Position Status                                            |
//+------------------------------------------------------------------+
void CheckPositionStatus()
{
    bool hadPosition = hasOpenPosition;
    hasOpenPosition = false;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionSelectByTicket(PositionGetTicket(i)))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                hasOpenPosition = true;
                break;
            }
        }
    }
    
    if(hadPosition && !hasOpenPosition)
    {
        basketActive = false;
        if(!tradingDisabled && (disableReason == "BASKET STOP HIT (Ready)" || disableReason == "PEAK GIVEBACK (Ready)"))
            disableReason = "";
    }
}

//+------------------------------------------------------------------+
//| Manage Take Profit (Dollar-Based)                                |
//+------------------------------------------------------------------+
void ManageTakeProfit()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                double profit = PositionGetDouble(POSITION_PROFIT);
                
                if(profit >= TakeProfitDollars)
                {
                    if(trade.PositionClose(ticket))
                    {
                        if(EnableDebugPrints)
                            Print(">>> POSITION CLOSED at $", DoubleToString(profit, 2), " profit");
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Panel Constants                                                  |
//+------------------------------------------------------------------+
#define PANEL_X           10
#define PANEL_Y           25
#define PANEL_WIDTH       360
#define PANEL_FONT        "Segoe UI"
#define PANEL_FONT_BOLD   "Segoe UI Semibold"
#define PANEL_FONT_SIZE   10
#define PREFIX            "TPv34_"

#define CLR_HEADER_BG     C'15,25,45'
#define CLR_SECTION_BG    C'25,40,65'
#define CLR_CONTENT_BG    C'10,18,32'
#define CLR_SEPARATOR     C'40,60,90'
#define CLR_LABEL         C'140,160,180'
#define CLR_VALUE         C'220,230,240'

//+------------------------------------------------------------------+
//| Create Panel                                                     |
//+------------------------------------------------------------------+
void CreatePanel()
{
    ObjectsDeleteAll(0, PREFIX);
    
    int y = PANEL_Y;
    int rowHeight = 26;
    int sectionGap = 8;
    int padding = 15;
    int valueX = PANEL_X + 140;
    
    CreateBox(PREFIX + "HeaderBG", PANEL_X, y, PANEL_WIDTH, 65, CLR_HEADER_BG);
    CreateLabel(PREFIX + "Title", PANEL_X + padding, y + 10, "TREND HARVESTOR", clrWhite, 16, "Arial Black");
    CreateLabel(PREFIX + "Version", PANEL_X + 270, y + 14, "v3.4", C'100,180,255', 12, PANEL_FONT_BOLD);
    CreateLabel(PREFIX + "TimeSymbol", PANEL_X + padding, y + 40, "", C'100,140,180', PANEL_FONT_SIZE, PANEL_FONT);
    y += 70;
    
    CreateBox(PREFIX + "Layer0BG", PANEL_X, y, PANEL_WIDTH, 30, CLR_SECTION_BG);
    CreateLabel(PREFIX + "Layer0Title", PANEL_X + padding, y + 6, "◈ LAYER 0 - RISK GOVERNOR (NY)", clrWhite, 11, PANEL_FONT_BOLD);
    y += 35;
    
    CreateBox(PREFIX + "Layer0ContentBG", PANEL_X, y, PANEL_WIDTH, 260, CLR_CONTENT_BG);
    int contentY = y + 10;
    
    CreateLabel(PREFIX + "TradingLabel", PANEL_X + padding, contentY, "Trading:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "TradingValue", valueX, contentY, "", clrLime, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "ReasonLabel", PANEL_X + padding, contentY, "Status:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "ReasonValue", valueX, contentY, "", clrOrange, PANEL_FONT_SIZE, PANEL_FONT);
    contentY += rowHeight + sectionGap;
    
    CreateBox(PREFIX + "Sep1", PANEL_X + padding, contentY, PANEL_WIDTH - 30, 1, CLR_SEPARATOR);
    contentY += 12;
    
    CreateLabel(PREFIX + "NYTimeLabel", PANEL_X + padding, contentY, "NY Time:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "NYTimeValue", valueX, contentY, "", CLR_VALUE, PANEL_FONT_SIZE, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "DailyLossLabel", PANEL_X + padding, contentY, "Daily P&L:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "DailyLossValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "BasketPLLabel", PANEL_X + padding, contentY, "Basket Float P&L:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "BasketPLValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "BasketPeakLabel", PANEL_X + padding, contentY, "Basket Peak P&L:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "BasketPeakValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateBox(PREFIX + "Sep2", PANEL_X + padding, contentY, PANEL_WIDTH - 30, 1, CLR_SEPARATOR);
    contentY += 12;
    
    CreateLabel(PREFIX + "ProtectLabel", PANEL_X + padding, contentY, "Profit Protection:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "ProtectValue", valueX, contentY, "", CLR_VALUE, PANEL_FONT_SIZE, PANEL_FONT_BOLD);
    
    y += 265;
    
    CreateBox(PREFIX + "ExecBG", PANEL_X, y, PANEL_WIDTH, 30, CLR_SECTION_BG);
    CreateLabel(PREFIX + "ExecTitle", PANEL_X + padding, y + 6, "◈ EXECUTION STATUS", clrWhite, 11, PANEL_FONT_BOLD);
    y += 35;
    
    CreateBox(PREFIX + "ExecContentBG", PANEL_X, y, PANEL_WIDTH, 120, CLR_CONTENT_BG);
    contentY = y + 10;
    
    CreateLabel(PREFIX + "PermLabel", PANEL_X + padding, contentY, "Permission:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "PermValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "PosLabel", PANEL_X + padding, contentY, "Position:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "PosValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "WindowLabel", PANEL_X + padding, contentY, "This Window:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "WindowValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "FloatPLLabel", PANEL_X + padding, contentY, "Floating P&L:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "FloatPLValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    
    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Update Panel Values                                              |
//+------------------------------------------------------------------+
void UpdatePanel()
{
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double floatingPL = currentEquity - currentBalance;
    double dailyPL = currentEquity - dailyStartEquity;
    
    ObjectSetString(0, PREFIX + "TimeSymbol", OBJPROP_TEXT, 
        "⏱ " + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "  " + _Symbol);
    
    // NY Time display
    ObjectSetString(0, PREFIX + "NYTimeValue", OBJPROP_TEXT, TimeToString(GetNewYorkTime(), TIME_DATE|TIME_MINUTES) + " NY");
    
    string tradingState = "● ENABLED";
    color tradingColor = clrLime;
    if(dailyLossLimitHit)
    {
        tradingState = "✖ DAILY LOSS LIMIT";
        tradingColor = clrRed;
    }
    else if(tradingDisabled && disableReason == "DAILY TARGET REACHED")
    {
        tradingState = "★ DAILY TARGET HIT";
        tradingColor = clrGold;
    }
    else if(tradingDisabled)
    {
        tradingState = "○ DISABLED";
        tradingColor = clrOrange;
    }
    ObjectSetString(0, PREFIX + "TradingValue", OBJPROP_TEXT, tradingState);
    ObjectSetInteger(0, PREFIX + "TradingValue", OBJPROP_COLOR, tradingColor);
    
    string statusText = "READY";
    color statusColor = clrLime;
    if(disableReason != "")
    {
        statusText = disableReason;
        statusColor = (disableReason == "DAILY LOSS LIMIT HIT") ? clrRed : 
                      (disableReason == "DAILY TARGET REACHED") ? clrGold : clrOrange;
    }
    else if(basketActive)
    {
        statusText = "BASKET ACTIVE";
    }
    ObjectSetString(0, PREFIX + "ReasonValue", OBJPROP_TEXT, statusText);
    ObjectSetInteger(0, PREFIX + "ReasonValue", OBJPROP_COLOR, statusColor);
    
    string dailyText = "$" + DoubleToString(dailyPL, 2) + " / -$" + DoubleToString(DailyLossLimit_USD, 2);
    color dailyColor = dailyPL >= 0 ? clrLime : (dailyPL > -DailyLossLimit_USD * 0.5 ? clrOrange : clrRed);
    ObjectSetString(0, PREFIX + "DailyLossValue", OBJPROP_TEXT, dailyText);
    ObjectSetInteger(0, PREFIX + "DailyLossValue", OBJPROP_COLOR, dailyColor);
    
    string basketPLText = (!basketActive && !hasOpenPosition) ? "○ NO BASKET" : 
        "$" + DoubleToString(basketFloatingPL, 2) + " / -$" + DoubleToString(BasketStopLoss_USD, 2);
    color basketPLColor = (!basketActive && !hasOpenPosition) ? clrGray :
        basketFloatingPL >= 0 ? clrLime : (basketFloatingPL > -BasketStopLoss_USD * 0.5 ? clrOrange : clrRed);
    ObjectSetString(0, PREFIX + "BasketPLValue", OBJPROP_TEXT, basketPLText);
    ObjectSetInteger(0, PREFIX + "BasketPLValue", OBJPROP_COLOR, basketPLColor);
    
    string basketPeakText = (!basketActive && !hasOpenPosition) ? "○ NO BASKET" : "$" + DoubleToString(basketPeakPL, 2);
    color basketPeakColor = (!basketActive && !hasOpenPosition) ? clrGray : (basketPeakPL > 0 ? clrLime : CLR_VALUE);
    ObjectSetString(0, PREFIX + "BasketPeakValue", OBJPROP_TEXT, basketPeakText);
    ObjectSetInteger(0, PREFIX + "BasketPeakValue", OBJPROP_COLOR, basketPeakColor);
    
    string protectText = !hasOpenPosition ? "○ NO POSITION" :
        profitProtectionActivated ? "● ACTIVE ($" + DoubleToString(MinProfitToProtect_USD, 2) + "+)" :
        "○ INACTIVE (<$" + DoubleToString(MinProfitToProtect_USD, 2) + ")";
    color protectColor = !hasOpenPosition ? clrGray : (profitProtectionActivated ? clrLime : clrOrange);
    ObjectSetString(0, PREFIX + "ProtectValue", OBJPROP_TEXT, protectText);
    ObjectSetInteger(0, PREFIX + "ProtectValue", OBJPROP_COLOR, protectColor);
    
    string permState = longEntryAllowed ? "▲ LONG OK" : (shortEntryAllowed ? "▼ SHORT OK" : "NEUTRAL");
    color permColor = longEntryAllowed ? clrLime : (shortEntryAllowed ? clrRed : clrGray);
    ObjectSetString(0, PREFIX + "PermValue", OBJPROP_TEXT, permState);
    ObjectSetInteger(0, PREFIX + "PermValue", OBJPROP_COLOR, permColor);
    
    ObjectSetString(0, PREFIX + "PosValue", OBJPROP_TEXT, hasOpenPosition ? "● OPEN" : "○ NONE");
    ObjectSetInteger(0, PREFIX + "PosValue", OBJPROP_COLOR, hasOpenPosition ? clrLime : clrGray);
    
    ObjectSetString(0, PREFIX + "WindowValue", OBJPROP_TEXT, tradeTakenThisPermission ? "✓ TAKEN" : "○ READY");
    ObjectSetInteger(0, PREFIX + "WindowValue", OBJPROP_COLOR, tradeTakenThisPermission ? clrGold : clrLime);
    
    ObjectSetString(0, PREFIX + "FloatPLValue", OBJPROP_TEXT, "$" + DoubleToString(floatingPL, 2));
    ObjectSetInteger(0, PREFIX + "FloatPLValue", OBJPROP_COLOR, floatingPL >= 0 ? clrLime : clrRed);
    
    ChartRedraw(0);
}

void CreateBox(string name, int x, int y, int width, int height, color bgColor)
{
    if(ObjectFind(0, name) < 0)
        ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
    ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
    ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
    ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, name, OBJPROP_COLOR, bgColor);
    ObjectSetInteger(0, name, OBJPROP_BACK, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, string font)
{
    if(ObjectFind(0, name) < 0)
        ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetString(0, name, OBJPROP_TEXT, text);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
    ObjectSetString(0, name, OBJPROP_FONT, font);
    ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
    ObjectSetInteger(0, name, OBJPROP_BACK, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void DeletePanel()
{
    ObjectsDeleteAll(0, PREFIX);
}

void OnDeinit(const int reason)
{
    DeletePanel();
    Comment("");
    Print("TrendPermissionEA_v3_4 deinitialized. Reason: ", reason);
    Print("Final Daily P&L: $", DoubleToString(dailyRealizedPL, 2));
}
