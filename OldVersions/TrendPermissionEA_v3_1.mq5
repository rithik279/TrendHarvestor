//+------------------------------------------------------------------+
//|                                        TrendPermissionEA_v3_1.mq5 |
//|                        Layer 0 Risk Governor + Execution Layer    |
//|                                                       Version 3.1 |
//+------------------------------------------------------------------+
#property copyright "TrendPermission"
#property version   "3.1"
#property description "Permission-Gated Execution with Layer 0 Risk Governor"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "00. Layer 0 - Global Risk Governor"
input double MaxAccountDD_USD      = 20.0;     // Absolute Account DD from Start ($)
input double PeakGivebackFrac      = 0.25;     // Fraction of Peak Profit Allowed to Give Back
input double DailyProfitTarget     = 100.0;    // Daily Realized Profit Target ($)
input double MinProfitToProtect_USD = 5.0;     // Minimum floating profit before giveback logic activates

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

double startEquity;
double peakEquity;
double dailyStartEquity;
double dailyRealizedPL;
bool   tradingDisabled;
bool   tradingDisabledPermanent;
datetime currentSessionDate;
string disableReason;

// v3.1: Track if profit protection has been activated (for logging)
bool   profitProtectionActivated;

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
    Print("TrendPermissionEA_v3_1 initialized");
    Print("Symbol: ", _Symbol, " | Timeframe: M1");
    Print("Lot Size: ", LotSize);
    Print("Take Profit: $", TakeProfitDollars);
    Print("Magic Number: ", MagicNumber);
    Print("----------------------------------------------");
    Print("LAYER 0 ACTIVE");
    Print("Max Account DD: $", MaxAccountDD_USD);
    Print("Peak Giveback: ", PeakGivebackFrac * 100, "%");
    Print("Min Profit to Protect: $", MinProfitToProtect_USD);
    Print("Daily Target: $", DailyProfitTarget);
    Print("Start Equity: $", DoubleToString(startEquity, 2));
    Print("==============================================");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//|                                                                  |
//| ================================================================ |
//| ===== LAYER 0: GLOBAL RISK GOVERNOR ============================ |
//| ================================================================ |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Initialize Layer 0                                               |
//+------------------------------------------------------------------+
void InitializeLayer0()
{
    startEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    peakEquity = startEquity;
    dailyStartEquity = startEquity;
    dailyRealizedPL = 0.0;
    tradingDisabled = false;
    tradingDisabledPermanent = false;
    currentSessionDate = GetBrokerDate();
    disableReason = "";
    
    // v3.1: Initialize protection tracking
    profitProtectionActivated = false;
}

//+------------------------------------------------------------------+
//| Get Broker Date (day only)                                       |
//+------------------------------------------------------------------+
datetime GetBrokerDate()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    dt.hour = 0;
    dt.min = 0;
    dt.sec = 0;
    return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Layer 0: Main Risk Check - MUST RUN EVERY TICK                  |
//+------------------------------------------------------------------+
void Layer0_RiskCheck()
{
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    // === CHECK SESSION RESET ===
    CheckSessionReset();
    
    // === RULE 1: ABSOLUTE DRAWDOWN KILL SWITCH ===
    if(currentEquity <= startEquity - MaxAccountDD_USD)
    {
        if(!tradingDisabledPermanent)
        {
            disableReason = "ABSOLUTE DD LIMIT HIT";
            Print("!!! LAYER 0: ", disableReason, " !!!");
            Print("Current Equity: $", DoubleToString(currentEquity, 2));
            Print("Start Equity: $", DoubleToString(startEquity, 2));
            Print("Max DD Allowed: $", MaxAccountDD_USD);
            
            CloseAllPositions("Layer0_AbsoluteDD");
            tradingDisabled = true;
            tradingDisabledPermanent = true;  // PERMANENT - never re-enable
        }
        return;
    }
    
    // === RULE 2: PEAK PROFIT GIVEBACK CONTROL (ONLY WHILE TRADE OPEN) ===
    if(hasOpenPosition)
    {
        // Update peak equity while position is open
        if(currentEquity > peakEquity)
        {
            peakEquity = currentEquity;
        }
        
        // Calculate profit from start
        double profitFromStart = peakEquity - startEquity;
        
        // Layer 0: Peak giveback inactive until MinProfitToProtect_USD reached
        if(profitFromStart < MinProfitToProtect_USD)
        {
            // Giveback logic is DISABLED - trade can fluctuate freely
            return;
        }
        
        // v3.1: Log when protection becomes active (once per trade cycle)
        if(!profitProtectionActivated)
        {
            profitProtectionActivated = true;
            Print(">>> LAYER 0: Profit protection activated at $", DoubleToString(profitFromStart, 2), " peak profit");
        }
        
        // Giveback logic is ENABLED - threshold has been crossed
        double allowedGiveback = PeakGivebackFrac * profitFromStart;
        double givebackThreshold = peakEquity - allowedGiveback;
        
        if(currentEquity <= givebackThreshold)
        {
            disableReason = "PEAK GIVEBACK LIMIT HIT";
            Print("!!! LAYER 0: ", disableReason, " !!!");
            Print("Peak Equity: $", DoubleToString(peakEquity, 2));
            Print("Current Equity: $", DoubleToString(currentEquity, 2));
            Print("Allowed Giveback: $", DoubleToString(allowedGiveback, 2));
            
            CloseAllPositions("Layer0_PeakGiveback");
            
            // Reset cycle state (not permanent)
            peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
            
            // v3.1: Reset protection flag for next trade
            profitProtectionActivated = false;
        }
    }
    else
    {
        // v3.1: Reset protection flag when no position is open
        profitProtectionActivated = false;
    }
    
    // === RULE 3: DAILY PROFIT TARGET ===
    if(dailyRealizedPL >= DailyProfitTarget)
    {
        if(!tradingDisabled || disableReason != "DAILY TARGET REACHED")
        {
            disableReason = "DAILY TARGET REACHED";
            Print("!!! LAYER 0: ", disableReason, " !!!");
            Print("Daily Realized P&L: $", DoubleToString(dailyRealizedPL, 2));
            Print("Daily Target: $", DailyProfitTarget);
            
            CloseAllPositions("Layer0_DailyTarget");
            tradingDisabled = true;
        }
    }
}

//+------------------------------------------------------------------+
//| Check for Session Reset (New Broker Day)                         |
//+------------------------------------------------------------------+
void CheckSessionReset()
{
    datetime brokerDate = GetBrokerDate();
    
    if(brokerDate != currentSessionDate)
    {
        // New trading day
        currentSessionDate = brokerDate;
        
        // Reset daily tracking
        dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        dailyRealizedPL = 0.0;
        
        // Re-enable trading (unless permanently disabled)
        if(!tradingDisabledPermanent)
        {
            tradingDisabled = false;
            disableReason = "";
        }
        
        // Reset peak equity to current for new day
        peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        
        // v3.1: Reset protection flag for new day
        profitProtectionActivated = false;
        
        Print("=== NEW SESSION STARTED ===");
        Print("Date: ", TimeToString(brokerDate, TIME_DATE));
        Print("Daily Start Equity: $", DoubleToString(dailyStartEquity, 2));
        Print("Trading Enabled: ", !tradingDisabled);
    }
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
                    // Track realized P&L
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
    // Track closed trades for daily P&L
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
    {
        if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
        {
            // Check if this is a closing deal
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
//|                                                                  |
//| ================================================================ |
//| ===== END OF LAYER 0 =========================================== |
//| ================================================================ |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // === LAYER 0: RISK CHECK (ALWAYS RUNS FIRST) ===
    CheckPositionStatus();  // Need position status for Layer 0
    Layer0_RiskCheck();
    
    // Update chart comment
    UpdateChartComment();
    
    // === LAYER 0 GATE: STOP IF TRADING DISABLED ===
    if(tradingDisabled)
        return;
    
    // Manage Take Profit (only if trading enabled)
    ManageTakeProfit();
    
    // New bar detection
    datetime currentTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentTime <= lastProcessedTime)
        return;
    
    lastProcessedTime = currentTime;
    
    // ===== PROCESS NEW BAR =====
    ProcessNewBar();
}

//+------------------------------------------------------------------+
//| Process New Bar - Main Logic                                     |
//+------------------------------------------------------------------+
void ProcessNewBar()
{
    // === STEP 1: Update Trend Permission (FROZEN MODULE) ===
    UpdateTrendPermission();
    
    // === STEP 2: Check Permission Transitions ===
    CheckPermissionTransitions();
    
    // === STEP 3: Execute Trade Logic ===
    ExecuteTradeLogic();
}

//+------------------------------------------------------------------+
//|                                                                  |
//| ================================================================ |
//| ===== TREND PERMISSION MODULE (FROZEN – DO NOT MODIFY) ========= |
//| ================================================================ |
//|                                                                  |
//| FROZEN: TradingView parity confirmed                             |
//| DO NOT MODIFY UNDER ANY CIRCUMSTANCES                            |
//|                                                                  |
//+------------------------------------------------------------------+
void UpdateTrendPermission()
{
    // Store previous states
    longEntryAllowedPrev = longEntryAllowed;
    shortEntryAllowedPrev = shortEntryAllowed;
    emaFastSlopePrev = emaFastSlope;
    emaGapPrev = emaGap;
    
    // Calculate EMAs
    if(!CalculateEMAs_Frozen())
        return;
    
    // Calculate slopes and derivatives
    CalculateSlopes_Frozen();
    
    // Calculate gap dynamics
    CalculateGapDynamics_Frozen();
    
    // Determine entry permissions
    DetermineEntryPermissions_Frozen();
}

//+------------------------------------------------------------------+
//| Calculate EMAs - FROZEN (Direct Pine Translation)               |
//| DO NOT MODIFY UNDER ANY CIRCUMSTANCES                            |
//+------------------------------------------------------------------+
bool CalculateEMAs_Frozen()
{
    // Resize arrays
    ArrayResize(ema200High, 3);
    ArrayResize(ema200Low, 3);
    ArrayResize(emaFast, 3);
    ArrayResize(emaSlow, 3);
    
    ArraySetAsSeries(ema200High, true);
    ArraySetAsSeries(ema200Low, true);
    ArraySetAsSeries(emaFast, true);
    ArraySetAsSeries(emaSlow, true);
    
    // Create indicator handles
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
    
    // Get EMA values (need 3 bars: current[0], completed[1], previous[2])
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
    
    // Release handles
    IndicatorRelease(handleEmaHigh);
    IndicatorRelease(handleEmaLow);
    IndicatorRelease(handleEmaFast);
    IndicatorRelease(handleEmaSlow);
    
    return true;
}

//+------------------------------------------------------------------+
//| Calculate Slopes - FROZEN (First Derivatives)                   |
//| DO NOT MODIFY UNDER ANY CIRCUMSTANCES                            |
//+------------------------------------------------------------------+
void CalculateSlopes_Frozen()
{
    // First derivatives (slopes) - using completed bar [1] and previous [2]
    emaFastSlope = emaFast[1] - emaFast[2];
    emaSlowSlope = emaSlow[1] - emaSlow[2];
    
    // Second derivative (curvature)
    emaFastD2 = emaFastSlope - emaFastSlopePrev;
}

//+------------------------------------------------------------------+
//| Calculate Gap Dynamics - FROZEN                                  |
//| DO NOT MODIFY UNDER ANY CIRCUMSTANCES                            |
//+------------------------------------------------------------------+
void CalculateGapDynamics_Frozen()
{
    // Gap calculation - using completed bar [1]
    emaGap = emaFast[1] - emaSlow[1];
    
    // Gap slope (first derivative of gap)
    gapSlope = emaGap - emaGapPrev;
}

//+------------------------------------------------------------------+
//| Determine Entry Permissions - FROZEN (AUTHORITATIVE LOGIC)      |
//| DO NOT MODIFY UNDER ANY CIRCUMSTANCES                            |
//+------------------------------------------------------------------+
void DetermineEntryPermissions_Frozen()
{
    // Use completed bar close [1]
    double completedClose = iClose(_Symbol, PERIOD_CURRENT, 1);
    
    // === REGIME CONDITIONS (FROZEN) ===
    bool isBullRegime = completedClose > ema200High[1];
    bool isBearRegime = completedClose < ema200Low[1];
    
    // === ACCELERATION CONDITIONS (FROZEN) ===
    bool accelUp = (emaFastSlope > 0) && (emaFastD2 > 0);
    bool accelDown = (emaFastSlope < 0) && (emaFastD2 < 0);
    
    // === GAP CONDITIONS (FROZEN) ===
    bool gapBull = emaGap > 0;
    bool gapBear = emaGap < 0;
    bool gapWidening = gapSlope > 0;
    bool gapNarrowing = gapSlope < 0;
    
    // === ENTRY PERMISSION LOGIC (FROZEN - DIRECT PINE TRANSLATION) ===
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
//|                                                                  |
//| ================================================================ |
//| ===== END OF FROZEN MODULE ===================================== |
//| ================================================================ |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Check Permission Transitions                                     |
//+------------------------------------------------------------------+
void CheckPermissionTransitions()
{
    // === LONG PERMISSION TRANSITIONS ===
    
    // Permission START: false → true
    if(longEntryAllowed && !longEntryAllowedPrev)
    {
        tradeTakenThisPermission = false;  // Reset trade flag for new permission window
        if(EnableDebugPrints)
            Print(">>> LONG PERMISSION START at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
    }
    
    // Permission END: true → false
    if(!longEntryAllowed && longEntryAllowedPrev)
    {
        tradeTakenThisPermission = false;  // Reset trade flag
        if(EnableDebugPrints)
            Print(">>> LONG PERMISSION END at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
    }
    
    // === SHORT PERMISSION TRANSITIONS ===
    
    // Permission START: false → true
    if(shortEntryAllowed && !shortEntryAllowedPrev)
    {
        tradeTakenThisPermission = false;  // Reset trade flag for new permission window
        if(EnableDebugPrints)
            Print(">>> SHORT PERMISSION START at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
    }
    
    // Permission END: true → false
    if(!shortEntryAllowed && shortEntryAllowedPrev)
    {
        tradeTakenThisPermission = false;  // Reset trade flag
        if(EnableDebugPrints)
            Print(">>> SHORT PERMISSION END at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
    }
}

//+------------------------------------------------------------------+
//| Execute Trade Logic                                              |
//+------------------------------------------------------------------+
void ExecuteTradeLogic()
{
    // Don't trade if already taken a trade this permission window
    if(tradeTakenThisPermission)
        return;
    
    // Don't trade if already have an open position
    if(hasOpenPosition)
        return;
    
    // === LONG ENTRY ===
    if(longEntryAllowed)
    {
        if(OpenBuyTrade())
        {
            tradeTakenThisPermission = true;
            // Reset peak equity for new trade
            peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
            if(EnableDebugPrints)
                Print(">>> BUY TRADE OPENED at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
        }
    }
    
    // === SHORT ENTRY ===
    if(shortEntryAllowed)
    {
        if(OpenSellTrade())
        {
            tradeTakenThisPermission = true;
            // Reset peak equity for new trade
            peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
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
    
    // No SL, No TP set here - TP managed by dollar amount separately
    if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "TrendPerm_v3_1_BUY"))
    {
        return true;
    }
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
    
    // No SL, No TP set here - TP managed by dollar amount separately
    if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "TrendPerm_v3_1_SELL"))
    {
        return true;
    }
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
                
                // Close if profit target reached
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
//| Update Chart Comment                                             |
//+------------------------------------------------------------------+
void UpdateChartComment()
{
    // Use graphical panel instead of Comment()
    UpdatePanel();
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
#define PREFIX            "TPv3_"

// Color scheme - Navy Blue / Dark Theme
#define CLR_HEADER_BG     C'15,25,45'      // Dark navy header
#define CLR_SECTION_BG    C'25,40,65'      // Section header navy
#define CLR_CONTENT_BG    C'10,18,32'      // Dark content area
#define CLR_SEPARATOR     C'40,60,90'      // Separator line
#define CLR_LABEL         C'140,160,180'   // Gray labels
#define CLR_VALUE         C'220,230,240'   // Light values

//+------------------------------------------------------------------+
//| Create Panel - Call Once in OnInit                              |
//+------------------------------------------------------------------+
void CreatePanel()
{
    // Delete any existing panel objects
    ObjectsDeleteAll(0, PREFIX);
    
    int y = PANEL_Y;
    int rowHeight = 26;
    int sectionGap = 8;
    int padding = 15;
    int valueX = PANEL_X + 140;
    
    // === HEADER BACKGROUND ===
    CreateBox(PREFIX + "HeaderBG", PANEL_X, y, PANEL_WIDTH, 65, CLR_HEADER_BG);
    CreateLabel(PREFIX + "Title", PANEL_X + padding, y + 10, "TREND HARVESTOR", clrWhite, 16, "Arial Black");
    CreateLabel(PREFIX + "Version", PANEL_X + 270, y + 14, "v3.1", C'100,180,255', 12, PANEL_FONT_BOLD);
    CreateLabel(PREFIX + "TimeSymbol", PANEL_X + padding, y + 40, "", C'100,140,180', PANEL_FONT_SIZE, PANEL_FONT);
    y += 70;
    
    // === LAYER 0 SECTION HEADER ===
    CreateBox(PREFIX + "Layer0BG", PANEL_X, y, PANEL_WIDTH, 30, CLR_SECTION_BG);
    CreateLabel(PREFIX + "Layer0Title", PANEL_X + padding, y + 6, "◈ LAYER 0 - RISK GOVERNOR", clrWhite, 11, PANEL_FONT_BOLD);
    y += 35;
    
    // Layer 0 Content Background
    CreateBox(PREFIX + "Layer0ContentBG", PANEL_X, y, PANEL_WIDTH, 230, CLR_CONTENT_BG);
    int contentY = y + 10;
    
    CreateLabel(PREFIX + "TradingLabel", PANEL_X + padding, contentY, "Trading:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "TradingValue", valueX, contentY, "", clrLime, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "ReasonLabel", PANEL_X + padding, contentY, "Reason:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "ReasonValue", valueX, contentY, "", clrOrange, PANEL_FONT_SIZE, PANEL_FONT);
    contentY += rowHeight + sectionGap;
    
    // Separator line
    CreateBox(PREFIX + "Sep1", PANEL_X + padding, contentY, PANEL_WIDTH - 30, 1, CLR_SEPARATOR);
    contentY += 12;
    
    CreateLabel(PREFIX + "StartEqLabel", PANEL_X + padding, contentY, "Start Equity:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "StartEqValue", valueX, contentY, "", CLR_VALUE, PANEL_FONT_SIZE, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "PeakEqLabel", PANEL_X + padding, contentY, "Peak Equity:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "PeakEqValue", valueX, contentY, "", CLR_VALUE, PANEL_FONT_SIZE, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "CurrEqLabel", PANEL_X + padding, contentY, "Current Equity:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "CurrEqValue", valueX, contentY, "", CLR_VALUE, PANEL_FONT_SIZE, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "DDLabel", PANEL_X + padding, contentY, "Current DD:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "DDValue", valueX, contentY, "", CLR_VALUE, PANEL_FONT_SIZE, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "DailyPLLabel", PANEL_X + padding, contentY, "Daily P&L:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "DailyPLValue", valueX, contentY, "", CLR_VALUE, PANEL_FONT_SIZE, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    // v3.1: Add protection status display
    CreateLabel(PREFIX + "ProtectLabel", PANEL_X + padding, contentY, "Profit Protection:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "ProtectValue", valueX, contentY, "", CLR_VALUE, PANEL_FONT_SIZE, PANEL_FONT_BOLD);
    
    y += 235;
    
    // === EXECUTION STATUS SECTION HEADER ===
    CreateBox(PREFIX + "ExecBG", PANEL_X, y, PANEL_WIDTH, 30, CLR_SECTION_BG);
    CreateLabel(PREFIX + "ExecTitle", PANEL_X + padding, y + 6, "◈ EXECUTION STATUS", clrWhite, 11, PANEL_FONT_BOLD);
    y += 35;
    
    // Execution Content Background
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
    double currentDD = startEquity - currentEquity;
    double floatingPL = currentEquity - currentBalance;
    
    // Time and Symbol
    ObjectSetString(0, PREFIX + "TimeSymbol", OBJPROP_TEXT, 
        "⏱ " + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "  " + _Symbol);
    
    // Trading State
    string tradingState = "● ENABLED";
    color tradingColor = clrLime;
    if(tradingDisabledPermanent)
    {
        tradingState = "✖ PERM DISABLED";
        tradingColor = clrRed;
    }
    else if(tradingDisabled)
    {
        tradingState = "○ DISABLED";
        tradingColor = clrOrange;
    }
    ObjectSetString(0, PREFIX + "TradingValue", OBJPROP_TEXT, tradingState);
    ObjectSetInteger(0, PREFIX + "TradingValue", OBJPROP_COLOR, tradingColor);
    
    // Reason
    ObjectSetString(0, PREFIX + "ReasonValue", OBJPROP_TEXT, disableReason != "" ? disableReason : "-");
    
    // Equity values
    ObjectSetString(0, PREFIX + "StartEqValue", OBJPROP_TEXT, "$" + DoubleToString(startEquity, 2));
    ObjectSetString(0, PREFIX + "PeakEqValue", OBJPROP_TEXT, "$" + DoubleToString(peakEquity, 2));
    ObjectSetString(0, PREFIX + "CurrEqValue", OBJPROP_TEXT, "$" + DoubleToString(currentEquity, 2));
    
    // DD with color coding
    string ddText = "$" + DoubleToString(currentDD, 2) + " / $" + DoubleToString(MaxAccountDD_USD, 2);
    color ddColor = clrLime;
    if(currentDD > MaxAccountDD_USD * 0.5) ddColor = clrOrange;
    if(currentDD > MaxAccountDD_USD * 0.75) ddColor = clrRed;
    ObjectSetString(0, PREFIX + "DDValue", OBJPROP_TEXT, ddText);
    ObjectSetInteger(0, PREFIX + "DDValue", OBJPROP_COLOR, ddColor);
    
    // Daily P&L with color coding
    string dailyText = "$" + DoubleToString(dailyRealizedPL, 2) + " / $" + DoubleToString(DailyProfitTarget, 2);
    color dailyColor = dailyRealizedPL >= 0 ? clrLime : clrRed;
    if(dailyRealizedPL >= DailyProfitTarget) dailyColor = clrGold;
    ObjectSetString(0, PREFIX + "DailyPLValue", OBJPROP_TEXT, dailyText);
    ObjectSetInteger(0, PREFIX + "DailyPLValue", OBJPROP_COLOR, dailyColor);
    
    // v3.1: Protection status display
    double profitFromStart = peakEquity - startEquity;
    string protectText;
    color protectColor;
    if(!hasOpenPosition)
    {
        protectText = "○ NO POSITION";
        protectColor = clrGray;
    }
    else if(profitProtectionActivated)
    {
        protectText = "● ACTIVE ($" + DoubleToString(MinProfitToProtect_USD, 2) + "+)";
        protectColor = clrLime;
    }
    else
    {
        protectText = "○ INACTIVE (<$" + DoubleToString(MinProfitToProtect_USD, 2) + ")";
        protectColor = clrOrange;
    }
    ObjectSetString(0, PREFIX + "ProtectValue", OBJPROP_TEXT, protectText);
    ObjectSetInteger(0, PREFIX + "ProtectValue", OBJPROP_COLOR, protectColor);
    
    // Permission State
    string permState = "NEUTRAL";
    color permColor = clrGray;
    if(longEntryAllowed)
    {
        permState = "▲ LONG OK";
        permColor = clrLime;
    }
    else if(shortEntryAllowed)
    {
        permState = "▼ SHORT OK";
        permColor = clrRed;
    }
    ObjectSetString(0, PREFIX + "PermValue", OBJPROP_TEXT, permState);
    ObjectSetInteger(0, PREFIX + "PermValue", OBJPROP_COLOR, permColor);
    
    // Position State
    string posState = hasOpenPosition ? "● OPEN" : "○ NONE";
    color posColor = hasOpenPosition ? clrLime : clrGray;
    ObjectSetString(0, PREFIX + "PosValue", OBJPROP_TEXT, posState);
    ObjectSetInteger(0, PREFIX + "PosValue", OBJPROP_COLOR, posColor);
    
    // Window State
    string windowState = tradeTakenThisPermission ? "✓ TAKEN" : "○ READY";
    color windowColor = tradeTakenThisPermission ? clrGold : clrLime;
    ObjectSetString(0, PREFIX + "WindowValue", OBJPROP_TEXT, windowState);
    ObjectSetInteger(0, PREFIX + "WindowValue", OBJPROP_COLOR, windowColor);
    
    // Floating P&L
    color floatColor = floatingPL >= 0 ? clrLime : clrRed;
    ObjectSetString(0, PREFIX + "FloatPLValue", OBJPROP_TEXT, "$" + DoubleToString(floatingPL, 2));
    ObjectSetInteger(0, PREFIX + "FloatPLValue", OBJPROP_COLOR, floatColor);
    
    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Create Rectangle Label (Box)                                     |
//+------------------------------------------------------------------+
void CreateBox(string name, int x, int y, int width, int height, color bgColor)
{
    if(ObjectFind(0, name) < 0)
    {
        ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
    }
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
    ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
    ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
    ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, name, OBJPROP_COLOR, bgColor);
    ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 0);
    ObjectSetInteger(0, name, OBJPROP_BACK, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Create Text Label                                                |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, string font)
{
    if(ObjectFind(0, name) < 0)
    {
        ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
    }
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

//+------------------------------------------------------------------+
//| Delete Panel Objects                                             |
//+------------------------------------------------------------------+
void DeletePanel()
{
    ObjectsDeleteAll(0, PREFIX);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    DeletePanel();  // Remove all panel objects
    Comment("");    // Clear any remaining chart comment
    Print("TrendPermissionEA_v3_1 deinitialized. Reason: ", reason);
    Print("Final Daily P&L: $", DoubleToString(dailyRealizedPL, 2));
}
