//+------------------------------------------------------------------+
//|                                          TrendPermissionEA_v2.mq5 |
//|                        Bare-Bones Execution with Frozen Trend Logic|
//|                                                         Version 2.0|
//+------------------------------------------------------------------+
#property copyright "TrendPermission"
#property version   "2.0"
#property description "Permission-Gated Execution EA - Validation Build"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

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
    
    Print("==============================================");
    Print("TrendPermissionEA_v2 initialized");
    Print("Symbol: ", _Symbol, " | Timeframe: M1");
    Print("Lot Size: ", LotSize);
    Print("Take Profit: $", TakeProfitDollars);
    Print("Magic Number: ", MagicNumber);
    Print("==============================================");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Check for open position every tick (for TP management)
    CheckPositionStatus();
    ManageTakeProfit();
    
    // Update chart comment
    UpdateChartComment();
    
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
    if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "TrendPerm_v2_BUY"))
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
    if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "TrendPerm_v2_SELL"))
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
    string permissionState = "NEUTRAL";
    if(longEntryAllowed)
        permissionState = "LONG OK";
    else if(shortEntryAllowed)
        permissionState = "SHORT OK";
    
    string tradeState = hasOpenPosition ? "POSITION OPEN" : "NO POSITION";
    string tradeTakenState = tradeTakenThisPermission ? "TRADE TAKEN" : "READY TO TRADE";
    
    string comment = "=== TrendPermissionEA v2 ===\n";
    comment += "Permission: " + permissionState + "\n";
    comment += "Trade State: " + tradeState + "\n";
    comment += "This Window: " + tradeTakenState + "\n";
    comment += "Time: " + TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES);
    
    Comment(comment);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Comment("");  // Clear chart comment
    Print("TrendPermissionEA_v2 deinitialized. Reason: ", reason);
}
