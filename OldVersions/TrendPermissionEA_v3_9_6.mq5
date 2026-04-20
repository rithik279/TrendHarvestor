//+------------------------------------------------------------------+
//|                                      TrendPermissionEA_v3_9_6.mq5 |
//|                        Layer 0 Risk Governor + Execution Layer    |
//|                                                     Version 3.9.6 |
//+------------------------------------------------------------------+
#property copyright "TrendPermission"
#property version   "3.9.6"
#property description "Asymmetric Basket TP + Fixed Grid + HTF ADX + Structural Failure Controls"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "00. Layer 0 - Global Risk Governor"
input double BasketStopLoss_USD    = 20.0;     // Basket Stop Loss ($) - per basket
input double DailyLossLimit_USD    = 100.0;    // Daily Loss Limit ($) - disables trading for day
input double DailyProfitTarget_USD = 100.0;    // Daily Realized Profit Target ($)
input double PeakGivebackFrac      = 0.25;     // Fraction of Peak Profit Allowed to Give Back
input double MinProfitToProtect_USD = 5.0;     // Minimum peak P&L before protection activates
input int    BrokerToNYOffsetHours = -7;       // Broker time offset to New York (hours)

input group "01. Trend EMAs (FROZEN - DO NOT MODIFY)"
input int    TrendEMA_Len = 200;
input int    FastEMA_Len  = 10;
input int    SlowEMA_Len  = 30;

input group "02. Execution Settings"
input double LotSize            = 0.01;
input double TakeProfitDollars  = 5.0;        // v3.9: DEPRECATED - per-position TP disabled
input double FixedGridGap_USD   = 4.0;        // v3.9: Grid pyramiding gap ($)
input int    MagicNumber        = 123456;

input group "03. Debug"
input bool   EnableDebugPrints  = true;

input group "04. Regime Filter - HTF ADX"
input ENUM_TIMEFRAMES ADX_Timeframe = PERIOD_M30;
input int    ADX_Period = 14;
input double ADX_Threshold = 25.0;
input bool   EnableADXFilter = true;

input group "05. v3.9.6 Structural Failure Controls"
input bool   EnableMAEStop       = true;
input double MAE_Stop_USD        = 12.0;   // Soft stop before BasketStopLoss_USD
input bool   EnableTimeStop      = true;
input int    TimeStopBars         = 12;    // Bars since basket start
input double MinMFEForTimeStop_USD = 3.0;
input bool   EnableExpansionFailure = true;
input int    ExpansionFailureBars  = 6;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES - LAYER 0: RISK GOVERNOR                        |
//+------------------------------------------------------------------+

// === Account-Level Daily Tracking (NY-based) ===
double dailyStartEquity;
double dailyRealizedPL;        // v3.7: SINGLE SOURCE OF TRUTH - updated ONLY in OnTradeTransaction
bool   dailyLossLimitHit;
datetime currentNYDate;

// === Basket-Level Tracking ===
double basketFloatingPL;
double basketPeakFloatingPL;
bool   profitProtectionActivated;

// === v3.9: Daily Profit Floor (daily-scoped, persists across baskets) ===
bool   dailyProfitFloorActive;
double dailyProfitFloor_USD;

// === v3.7: Basket Direction Constants (derived state replaces flags) ===
#define BASKET_NONE   0
#define BASKET_LONG   1
#define BASKET_SHORT -1

// === UI Display Variables (derived each tick, not trusted for logic) ===
bool   displayBasketActive;
int    displayBasketDirection;

// === Status Display ===
string disableReason;
bool   tradingDisabled;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES - TREND PERMISSION MODULE (FROZEN)              |
//+------------------------------------------------------------------+

double ema200High[], ema200Low[];
double emaFast[], emaSlow[];
double emaFastSlope, emaSlowSlope;
double emaFastSlopePrev, emaFastD2;
double emaGap, emaGapPrev, gapSlope;

// v3.8: ATR for trend force filter
double atrValues[];
#define ATR_PERIOD 14
#define MIN_SLOPE_STRENGTH 0.12  // v3.8: Hard-coded empirical threshold

bool longEntryAllowed = false;
bool shortEntryAllowed = false;
bool longEntryAllowedPrev = false;
bool shortEntryAllowedPrev = false;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES - EXECUTION LAYER                               |
//+------------------------------------------------------------------+

bool tradeTakenThisPermission = false;
bool hasOpenPosition = false;
datetime lastProcessedTime = 0;
CTrade trade;

// v3.9: Grid pyramiding anchor
double lastAddAnchorPrice = 0.0;

// === v3.9.4: HTF ADX Regime Filter ===
double   g_adxValue = 0.0;
datetime g_adxLastBarTime = 0;
bool     g_adxValid = false;

// === v3.9.6: Structural Failure Tracking (basket-scoped) ===
double basketMAE = 0.0;               // Most negative floating P&L since basket start
double basketMFE = 0.0;               // Most positive floating P&L since basket start
int    basketStartBarIndex = -1;       // Bar index when basket opened
int    expansionFailureCounter = 0;    // Consecutive non-expansion bars

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    if(_Symbol != "XAUUSD")
    {
        Print("ERROR: This EA is designed for XAUUSD only. Current symbol: ", _Symbol);
        return(INIT_FAILED);
    }
    
    if(_Period != PERIOD_M1)
    {
        Print("ERROR: This EA is designed for M1 timeframe only.");
        return(INIT_FAILED);
    }
    
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    
    InitializeLayer0();
    CreatePanel();
    
    Print("==============================================");
    Print("TrendPermissionEA_v3_9_4 initialized");
    Print("Symbol: ", _Symbol, " | Timeframe: M1");
    Print("----------------------------------------------");
    Print("LAYER 0 v3.9.6 - ASYMMETRIC BASKET TP + GRID + ADX + STRUCTURAL FAILURE");
    Print("v3.9.4: HTF ADX Regime Filter (TF=", EnumToString(ADX_Timeframe), ", Period=", ADX_Period, ", Threshold=", DoubleToString(ADX_Threshold, 1), ", Enabled=", EnableADXFilter, ")");
    Print("v3.9.6: MAE Stop=$", DoubleToString(MAE_Stop_USD, 2), " En=", EnableMAEStop,
           " | TimeStop=", TimeStopBars, "bars MinMFE=$", DoubleToString(MinMFEForTimeStop_USD, 2), " En=", EnableTimeStop,
           " | ExpFail=", ExpansionFailureBars, "bars En=", EnableExpansionFailure);
    Print("KEPT: Per-position TP DISABLED, basket-level exits only");
    Print("KEPT: Fixed Grid Pyramiding (gap: $", DoubleToString(FixedGridGap_USD, 2), ")");
    Print("KEPT: Daily Profit Floor at $", DoubleToString(DailyProfitTarget_USD, 2));
    Print("KEPT: Structural Body Clearance + ATR-Normalized Slope (v3.8)");
    Print("----------------------------------------------");
    Print("Basket Stop Loss: $", BasketStopLoss_USD);
    Print("Daily Loss Limit: $", DailyLossLimit_USD, " (realized only)");
    Print("Daily Profit Target: $", DailyProfitTarget_USD, " (realized only)");
    Print("Grid Gap: $", DoubleToString(FixedGridGap_USD, 2));
    Print("==============================================");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Initialize Layer 0                                               |
//+------------------------------------------------------------------+
void InitializeLayer0()
{
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    dailyStartEquity = currentEquity;
    dailyRealizedPL = 0.0;
    dailyLossLimitHit = false;
    currentNYDate = GetNewYorkDate();
    
    basketFloatingPL = 0.0;
    basketPeakFloatingPL = 0.0;
    profitProtectionActivated = false;
    
    // v3.9: Daily profit floor
    dailyProfitFloorActive = false;
    dailyProfitFloor_USD = 0.0;
    
    // v3.9: Grid anchor
    lastAddAnchorPrice = 0.0;
    
    // v3.7: UI display variables (derived)
    displayBasketActive = false;
    displayBasketDirection = BASKET_NONE;
    
    disableReason = "";
    tradingDisabled = false;
    
    // v3.9.6: Structural failure tracking
    basketMAE = 0.0;
    basketMFE = 0.0;
    basketStartBarIndex = -1;
    expansionFailureCounter = 0;
}

//+------------------------------------------------------------------+
//| Get New York Date                                                |
//+------------------------------------------------------------------+
datetime GetNewYorkDate()
{
    datetime brokerTime = TimeCurrent();
    datetime nyTime = brokerTime + (BrokerToNYOffsetHours * 3600);
    
    MqlDateTime nyDt;
    TimeToStruct(nyTime, nyDt);
    nyDt.hour = 0;
    nyDt.min = 0;
    nyDt.sec = 0;
    
    return StructToTime(nyDt);
}

datetime GetNewYorkTime()
{
    return TimeCurrent() + (BrokerToNYOffsetHours * 3600);
}

//+------------------------------------------------------------------+
//| v3.7: DERIVED BASKET STATE FUNCTIONS                             |
//+------------------------------------------------------------------+

// Returns true if there is at least one open position with matching symbol + magic
bool BasketHasPositions()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                return true;
            }
        }
    }
    return false;
}

// Returns BASKET_LONG if all positions are BUY, BASKET_SHORT if all are SELL, BASKET_NONE if no positions
int GetBasketDirection()
{
    bool hasLong = false;
    bool hasShort = false;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                if(posType == POSITION_TYPE_BUY)
                    hasLong = true;
                else if(posType == POSITION_TYPE_SELL)
                    hasShort = true;
            }
        }
    }
    
    // v3.7: Derive direction
    if(hasLong && !hasShort)
        return BASKET_LONG;
    else if(hasShort && !hasLong)
        return BASKET_SHORT;
    else if(hasLong && hasShort)
    {
        // Mixed positions - this shouldn't happen in normal operation
        if(EnableDebugPrints)
            Print("!!! v3.7 ASSERTION: Mixed LONG/SHORT positions detected in basket");
        return BASKET_NONE;  // Treat as undefined
    }
    
    return BASKET_NONE;
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
//| v3.7: Check for Force Flip Condition (using derived state)       |
//+------------------------------------------------------------------+
bool CheckForceFlip()
{
    // v3.7: Use derived basket state instead of flags
    int currentDirection = GetBasketDirection();
    
    // Only check if we have an active basket
    if(currentDirection == BASKET_NONE)
        return false;
    
    // FORCE FLIP: LONG basket + shortEntryAllowed
    if(currentDirection == BASKET_LONG && shortEntryAllowed)
    {
        Print("==============================================");
        Print(">>> FORCE FLIP: LONG → SHORT");
        Print("    LONG basket active but shortEntryAllowed = true");
        Print("    Closing all LONG positions, resetting basket");
        Print("==============================================");
        
        CloseAllPositions("ForceFlip_LONG_to_SHORT");
        ResetBasketState();
        
        // Clear trade taken flag so we can enter new direction
        tradeTakenThisPermission = false;
        
        return true;
    }
    
    // FORCE FLIP: SHORT basket + longEntryAllowed
    if(currentDirection == BASKET_SHORT && longEntryAllowed)
    {
        Print("==============================================");
        Print(">>> FORCE FLIP: SHORT → LONG");
        Print("    SHORT basket active but longEntryAllowed = true");
        Print("    Closing all SHORT positions, resetting basket");
        Print("==============================================");
        
        CloseAllPositions("ForceFlip_SHORT_to_LONG");
        ResetBasketState();
        
        // Clear trade taken flag so we can enter new direction
        tradeTakenThisPermission = false;
        
        return true;
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| v3.7: Debug Assertions (logs only, no halts)                     |
//+------------------------------------------------------------------+
void ValidateBasketStateAssertions()
{
    if(!EnableDebugPrints)
        return;
    
    bool hasPositions = BasketHasPositions();
    int derivedDirection = GetBasketDirection();
    
    // Assertion 1: Basket direction NONE but positions exist
    if(derivedDirection == BASKET_NONE && hasPositions)
    {
        Print("!!! v3.7 ASSERTION ERROR: Basket direction is NONE but positions exist");
    }
    
    // Assertion 2: Positions exist but peak tracking is inactive (and floating PL > 0)
    if(hasPositions && basketFloatingPL > 0 && basketPeakFloatingPL == 0)
    {
        Print("!!! v3.7 ASSERTION WARNING: Positions exist with positive P&L but peak tracking shows $0");
    }
    
    // Assertion 3: Daily loss triggered but dailyRealizedPL doesn't match
    if(dailyLossLimitHit && dailyRealizedPL > -DailyLossLimit_USD)
    {
        Print("!!! v3.7 ASSERTION ERROR: Daily loss limit flagged but dailyRealizedPL ($", 
              DoubleToString(dailyRealizedPL, 2), ") > -$", DoubleToString(DailyLossLimit_USD, 2));
    }
}

//+------------------------------------------------------------------+
//| Layer 0: Main Risk Check                                         |
//+------------------------------------------------------------------+
void Layer0_RiskCheck()
{
    CheckDayReset();
    
    // v3.7: Derive basket state each tick
    bool basketExists = BasketHasPositions();
    int currentDirection = GetBasketDirection();
    
    // Update display variables (for UI only)
    displayBasketActive = basketExists;
    displayBasketDirection = currentDirection;
    
    // === PRIORITY 1: DAILY LOSS LIMIT (v3.7: REALIZED P&L ONLY) ===
    // v3.7 FIX: Use dailyRealizedPL instead of equity-based calculation
    if(dailyRealizedPL <= -DailyLossLimit_USD)
    {
        if(!dailyLossLimitHit)
        {
            dailyLossLimitHit = true;
            tradingDisabled = true;
            disableReason = "DAILY LOSS LIMIT HIT";
            
            Print("!!! LAYER 0: DAILY LOSS LIMIT HIT !!!");
            Print(">>> Daily Realized P&L: $", DoubleToString(dailyRealizedPL, 2), " – Trading disabled for NY day");
            
            CloseAllPositions("Layer0_DailyLossLimit");
            ResetBasketState();
        }
        return;
    }
    
    // === CALCULATE BASKET FLOATING P&L ===
    basketFloatingPL = CalculateBasketFloatingPL();
    
    // === v3.9.6: MAE/MFE tracking (basket-scoped) ===
    if(basketExists)
    {
        basketMAE = MathMin(basketMAE, basketFloatingPL);
        basketMFE = MathMax(basketMFE, basketFloatingPL);
        
        // Detect basket start bar
        if(basketStartBarIndex == -1)
            basketStartBarIndex = Bars(_Symbol, PERIOD_CURRENT) - 1;
    }
    
    // === v3.9.6 PRIORITY 1B: MAE SOFT STOP ===
    if(basketExists && EnableMAEStop)
    {
        if(basketMAE <= -MAE_Stop_USD)
        {
            Print("!!! v3.9.6: MAE SOFT STOP HIT !!!");
            Print("    MAE: $", DoubleToString(basketMAE, 2), " | Threshold: -$", DoubleToString(MAE_Stop_USD, 2));
            Print("    Float: $", DoubleToString(basketFloatingPL, 2));
            Print("    Direction: ", currentDirection == BASKET_LONG ? "LONG" : "SHORT");
            
            CloseAllPositions("v3.9.6_MAE_SoftStop");
            ResetBasketState();
            disableReason = "MAE STOP (Ready)";
            return;
        }
    }
    
    // === v3.9.6 PRIORITY 1C: TIME STOP ===
    if(basketExists && EnableTimeStop)
    {
        int currentBarIndex = Bars(_Symbol, PERIOD_CURRENT) - 1;
        int barsSinceEntry = currentBarIndex - basketStartBarIndex;
        
        if(barsSinceEntry >= TimeStopBars && basketMFE < MinMFEForTimeStop_USD)
        {
            Print("!!! v3.9.6: TIME STOP HIT !!!");
            Print("    Bars: ", barsSinceEntry, " >= ", TimeStopBars);
            Print("    MFE: $", DoubleToString(basketMFE, 2), " < $", DoubleToString(MinMFEForTimeStop_USD, 2));
            Print("    Float: $", DoubleToString(basketFloatingPL, 2));
            Print("    Direction: ", currentDirection == BASKET_LONG ? "LONG" : "SHORT");
            
            CloseAllPositions("v3.9.6_TimeStop");
            ResetBasketState();
            disableReason = "TIME STOP (Ready)";
            return;
        }
    }
    
    // === v3.9.6 PRIORITY 1D: EXPANSION FAILURE EXIT ===
    if(basketExists && EnableExpansionFailure)
    {
        // Read-only access to frozen trend module slopes
        double gapSlope = 0.0;
        double emaFastSlope = 0.0;
        if(ArraySize(emaFast) >= 2)
            emaFastSlope = emaFast[0] - emaFast[1];
        if(ArraySize(atrValues) >= 1 && atrValues[0] > 0)
        {
            double gap = emaFast[0] - emaSlow[0];
            double gapPrev = (ArraySize(emaFast) >= 2 && ArraySize(emaSlow) >= 2) ? emaFast[1] - emaSlow[1] : gap;
            gapSlope = gap - gapPrev;
        }
        
        // Check if trend is expanding (BUY: positive slope, SELL: negative slope)
        bool expanding = false;
        if(currentDirection == BASKET_LONG)
            expanding = (gapSlope > 0 && emaFastSlope > 0);
        else if(currentDirection == BASKET_SHORT)
            expanding = (gapSlope < 0 && emaFastSlope < 0);
        
        if(!expanding)
            expansionFailureCounter++;
        else
            expansionFailureCounter = 0;
        
        if(expansionFailureCounter >= ExpansionFailureBars)
        {
            // Safety guard: only exit if basket has given back at least 50% of MFE
            if(basketMFE > 0 && basketFloatingPL <= basketMFE * 0.5)
            {
                Print("!!! v3.9.6: EXPANSION FAILURE EXIT !!!");
                Print("    Non-expanding bars: ", expansionFailureCounter, " >= ", ExpansionFailureBars);
                Print("    MFE: $", DoubleToString(basketMFE, 2), " | Float: $", DoubleToString(basketFloatingPL, 2));
                Print("    GapSlope: ", DoubleToString(gapSlope, 6), " | EMA slope: ", DoubleToString(emaFastSlope, 6));
                Print("    Direction: ", currentDirection == BASKET_LONG ? "LONG" : "SHORT");
                
                CloseAllPositions("v3.9.6_ExpansionFailure");
                ResetBasketState();
                disableReason = "EXPANSION FAIL (Ready)";
                return;
            }
        }
    }
    
    // === PRIORITY 2: BASKET STOP LOSS ===
    // v3.7: Use derived basket state
    if(basketExists)
    {
        if(basketFloatingPL <= -BasketStopLoss_USD)
        {
            Print("!!! LAYER 0: BASKET STOP HIT !!!");
            Print(">>> BASKET STOP: $", DoubleToString(basketFloatingPL, 2), " floating P&L");
            Print(">>> Basket Direction was: ", currentDirection == BASKET_LONG ? "LONG" : "SHORT");
            Print(">>> Basket closed, trading still enabled");
            
            CloseAllPositions("Layer0_BasketStop");
            ResetBasketState();
            
            disableReason = "BASKET STOP HIT (Ready)";
            return;
        }
        
        // === PRIORITY 3: PEAK PROFIT PROTECTION + v3.9 DAILY FLOOR ===
        basketPeakFloatingPL = MathMax(basketPeakFloatingPL, basketFloatingPL);
        
        // Activate profit protection flag (existing v3.5 logic)
        if(basketPeakFloatingPL >= MinProfitToProtect_USD && !profitProtectionActivated)
        {
            profitProtectionActivated = true;
            Print(">>> LAYER 0: PROFIT PROTECTION ACTIVATED");
            Print("    Basket Peak Floating P&L: $", DoubleToString(basketPeakFloatingPL, 2));
        }
        
        // v3.9: Activate daily profit floor when basket peak reaches daily target
        if(basketPeakFloatingPL >= DailyProfitTarget_USD && !dailyProfitFloorActive)
        {
            dailyProfitFloorActive = true;
            dailyProfitFloor_USD = DailyProfitTarget_USD;
            if(EnableDebugPrints)
                Print(">>> v3.9: DAILY PROFIT FLOOR ACTIVATED at $", DoubleToString(dailyProfitFloor_USD, 2),
                      " | Basket Peak: $", DoubleToString(basketPeakFloatingPL, 2));
        }
        
        // v3.9: PRIORITY 3a - DAILY PROFIT FLOOR EXIT (tighter constraint, checked first)
        if(dailyProfitFloorActive && basketFloatingPL <= dailyProfitFloor_USD && basketPeakFloatingPL >= dailyProfitFloor_USD)
        {
            Print("!!! v3.9: DAILY PROFIT FLOOR EXIT !!!");
            Print("    Floor: $", DoubleToString(dailyProfitFloor_USD, 2));
            Print("    Basket Float: $", DoubleToString(basketFloatingPL, 2));
            Print("    Basket Peak: $", DoubleToString(basketPeakFloatingPL, 2));
            Print("    Anchor: ", DoubleToString(lastAddAnchorPrice, 2));
            Print("    Basket Direction: ", currentDirection == BASKET_LONG ? "LONG" : "SHORT");
            
            CloseAllPositions("v3.9_DailyProfitFloor");
            ResetBasketState();
            disableReason = "DAILY FLOOR EXIT (Ready)";
        }
        // PRIORITY 3b: PEAK PROFIT GIVEBACK (only if daily floor didn't close)
        else if(profitProtectionActivated)
        {
            double givebackThreshold = basketPeakFloatingPL * (1.0 - PeakGivebackFrac);
            
            if(basketFloatingPL <= givebackThreshold)
            {
                Print("!!! LAYER 0: PEAK GIVEBACK LIMIT HIT !!!");
                Print("    Basket Peak: $", DoubleToString(basketPeakFloatingPL, 2));
                Print("    Current: $", DoubleToString(basketFloatingPL, 2));
                Print("    Threshold: $", DoubleToString(givebackThreshold, 2));
                Print("    v3.9 Anchor: ", DoubleToString(lastAddAnchorPrice, 2));
                Print("    Basket Direction was: ", currentDirection == BASKET_LONG ? "LONG" : "SHORT");
                
                CloseAllPositions("Layer0_PeakGiveback");
                ResetBasketState();
                
                disableReason = "PEAK GIVEBACK (Ready)";
            }
        }
    }
    
    // === DAILY PROFIT TARGET (v3.7: REALIZED P&L ONLY) ===
    // v3.7 FIX: Use dailyRealizedPL instead of equity-based calculation
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
    
    // v3.7: Run debug assertions
    ValidateBasketStateAssertions();
}

//+------------------------------------------------------------------+
//| Check for Day Reset (NY Midnight)                                |
//+------------------------------------------------------------------+
void CheckDayReset()
{
    datetime nyDate = GetNewYorkDate();
    
    if(nyDate != currentNYDate)
    {
        currentNYDate = nyDate;
        double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        
        dailyStartEquity = currentEquity;
        dailyRealizedPL = 0.0;
        dailyLossLimitHit = false;
        tradingDisabled = false;
        disableReason = "";
        
        // v3.9: Reset daily profit floor on new NY day
        dailyProfitFloorActive = false;
        dailyProfitFloor_USD = 0.0;
        
        ResetBasketState();
        
        Print("==============================================");
        Print(">>> NEW NY DAY DETECTED – Daily limits reset");
        Print("NY Date: ", TimeToString(nyDate, TIME_DATE));
        Print("Daily Start Equity: $", DoubleToString(dailyStartEquity, 2));
        Print("Daily Realized P&L reset to: $0.00");
        Print("v3.9: Daily Profit Floor reset");
        Print("==============================================");
    }
}

//+------------------------------------------------------------------+
//| Reset Basket State                                               |
//+------------------------------------------------------------------+
void ResetBasketState()
{
    basketFloatingPL = 0.0;
    basketPeakFloatingPL = 0.0;
    profitProtectionActivated = false;
    
    // v3.9: Reset grid anchor (basket-scoped)
    lastAddAnchorPrice = 0.0;
    
    // v3.9.6: Reset structural failure tracking
    basketMAE = 0.0;
    basketMFE = 0.0;
    basketStartBarIndex = -1;
    expansionFailureCounter = 0;
    
    // v3.7: Display variables reset (they will be re-derived on next tick)
    displayBasketActive = false;
    displayBasketDirection = BASKET_NONE;
    
    if(EnableDebugPrints)
        Print(">>> BASKET STATE RESET | Peak: $0.00, Protection: false, Anchor: 0");
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
                    // v3.7 FIX: DO NOT update dailyRealizedPL here
                    // OnTradeTransaction is the SINGLE SOURCE OF TRUTH
                    Print(">>> LAYER 0 CLOSED POSITION | Reason: ", reason, " | Profit: $", DoubleToString(profit, 2));
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Track Realized P&L - v3.7: SINGLE SOURCE OF TRUTH                |
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
                        // v3.7: This is the ONLY place dailyRealizedPL is updated
                        dailyRealizedPL += profit;
                        if(EnableDebugPrints)
                            Print(">>> v3.7 OnTradeTransaction | Profit: $", DoubleToString(profit, 2), " | Daily Realized P&L: $", DoubleToString(dailyRealizedPL, 2));
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
    
    // === v3.6+: FORCE FLIP CHECK (BEFORE STANDARD LOGIC) ===
    // This must run on every tick, not just on new bars
    if(CheckForceFlip())
    {
        // Force flip occurred - basket was closed, tradeTakenThisPermission was reset
        // The ExecuteTradeLogic below will enter the new direction
    }
    
    // v3.9: Per-position TP disabled, replaced by basket-level exits in Layer0_RiskCheck
    ManageTakeProfit();
    
    // v3.9: Grid pyramiding adds (tick-based price gap check)
    ManageGridAdds();
    
    datetime currentTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentTime <= lastProcessedTime)
        return;
    
    lastProcessedTime = currentTime;
    ProcessNewBar();
}

void ProcessNewBar()
{
    UpdateTrendPermission();
    CheckPermissionTransitions();
    ExecuteTradeLogic();
}

//+------------------------------------------------------------------+
//| TREND PERMISSION MODULE (FROZEN)                                 |
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
    ArrayResize(atrValues, 3);  // v3.8: ATR array
    
    ArraySetAsSeries(ema200High, true);
    ArraySetAsSeries(ema200Low, true);
    ArraySetAsSeries(emaFast, true);
    ArraySetAsSeries(emaSlow, true);
    ArraySetAsSeries(atrValues, true);  // v3.8: ATR array
    
    int handleEmaHigh = iMA(_Symbol, PERIOD_CURRENT, TrendEMA_Len, 0, MODE_EMA, PRICE_HIGH);
    int handleEmaLow = iMA(_Symbol, PERIOD_CURRENT, TrendEMA_Len, 0, MODE_EMA, PRICE_LOW);
    int handleEmaFast = iMA(_Symbol, PERIOD_CURRENT, FastEMA_Len, 0, MODE_EMA, PRICE_CLOSE);
    int handleEmaSlow = iMA(_Symbol, PERIOD_CURRENT, SlowEMA_Len, 0, MODE_EMA, PRICE_CLOSE);
    int handleATR = iATR(_Symbol, PERIOD_CURRENT, ATR_PERIOD);  // v3.8: ATR handle
    
    if(handleEmaHigh == INVALID_HANDLE || handleEmaLow == INVALID_HANDLE || 
       handleEmaFast == INVALID_HANDLE || handleEmaSlow == INVALID_HANDLE ||
       handleATR == INVALID_HANDLE)  // v3.8: Check ATR handle
        return false;
    
    if(CopyBuffer(handleEmaHigh, 0, 0, 3, ema200High) < 3 ||
       CopyBuffer(handleEmaLow, 0, 0, 3, ema200Low) < 3 ||
       CopyBuffer(handleEmaFast, 0, 0, 3, emaFast) < 3 ||
       CopyBuffer(handleEmaSlow, 0, 0, 3, emaSlow) < 3 ||
       CopyBuffer(handleATR, 0, 0, 3, atrValues) < 3)  // v3.8: Copy ATR buffer
    {
        IndicatorRelease(handleEmaHigh);
        IndicatorRelease(handleEmaLow);
        IndicatorRelease(handleEmaFast);
        IndicatorRelease(handleEmaSlow);
        IndicatorRelease(handleATR);  // v3.8: Release ATR handle
        return false;
    }
    
    IndicatorRelease(handleEmaHigh);
    IndicatorRelease(handleEmaLow);
    IndicatorRelease(handleEmaFast);
    IndicatorRelease(handleEmaSlow);
    IndicatorRelease(handleATR);  // v3.8: Release ATR handle
    
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
    double completedOpen = iOpen(_Symbol, PERIOD_CURRENT, 1);  // v3.8: Need open for body calculation
    
    bool isBullRegime = completedClose > ema200High[1];
    bool isBearRegime = completedClose < ema200Low[1];
    
    bool accelUp = (emaFastSlope > 0) && (emaFastD2 > 0);
    bool accelDown = (emaFastSlope < 0) && (emaFastD2 < 0);
    
    bool gapBull = emaGap > 0;
    bool gapBear = emaGap < 0;
    bool gapWidening = gapSlope > 0;
    bool gapNarrowing = gapSlope < 0;
    
    // === EXISTING v3.7 LOGIC (PRESERVED) ===
    bool longBase = isBullRegime && (emaSlowSlope > 0) && (emaFastSlope > 0) && 
                    accelUp && gapBull && gapWidening;
                      
    bool shortBase = isBearRegime && (emaSlowSlope < 0) && (emaFastSlope < 0) && 
                     accelDown && gapBear && gapNarrowing;
    
    // === v3.8: STRUCTURAL BODY CLEARANCE FILTER ===
    // Calculate body boundaries from completed bar [1]
    double bodyHigh = MathMax(completedOpen, completedClose);
    double bodyLow = MathMin(completedOpen, completedClose);
    
    // EMA cloud boundaries
    double cloudTop = MathMax(emaFast[1], emaSlow[1]);
    double cloudBottom = MathMin(emaFast[1], emaSlow[1]);
    
    // LONG structural clearance: body must be ABOVE cloud and EMA200 high
    bool longStructuralClear = (bodyLow > cloudTop) && (bodyLow > ema200High[1]);
    
    // SHORT structural clearance: body must be BELOW cloud and EMA200 low
    bool shortStructuralClear = (bodyHigh < cloudBottom) && (bodyHigh < ema200Low[1]);
    
    // === v3.8: TREND FORCE FILTER (ATR-NORMALIZED SLOPE) ===
    double currentATR = atrValues[1];
    double normalizedSlopeStrength = 0.0;
    
    if(currentATR > 0)
    {
        normalizedSlopeStrength = MathAbs(emaSlowSlope) / currentATR;
    }
    
    bool trendForceOK = (normalizedSlopeStrength > MIN_SLOPE_STRENGTH);
    
    // === FINAL GATED PERMISSIONS (v3.8) ===
    // All conditions must pass: base logic + structural clearance + trend force
    longEntryAllowed = longBase && longStructuralClear && trendForceOK;
    shortEntryAllowed = shortBase && shortStructuralClear && trendForceOK;
    
    // === v3.8: Debug logging for new filters ===
    if(EnableDebugPrints && (longBase || shortBase))
    {
        if(longBase && !longEntryAllowed)
        {
            string blockReason = "";
            if(!longStructuralClear)
                blockReason += "STRUCTURAL_BLOCK(bodyLow=" + DoubleToString(bodyLow, 2) + 
                              " vs cloudTop=" + DoubleToString(cloudTop, 2) + 
                              " / ema200High=" + DoubleToString(ema200High[1], 2) + ") ";
            if(!trendForceOK)
                blockReason += "WEAK_TREND(slope=" + DoubleToString(normalizedSlopeStrength, 4) + 
                              " < " + DoubleToString(MIN_SLOPE_STRENGTH, 2) + ")";
            Print(">>> v3.8 LONG BLOCKED: ", blockReason);
        }
        
        if(shortBase && !shortEntryAllowed)
        {
            string blockReason = "";
            if(!shortStructuralClear)
                blockReason += "STRUCTURAL_BLOCK(bodyHigh=" + DoubleToString(bodyHigh, 2) + 
                              " vs cloudBottom=" + DoubleToString(cloudBottom, 2) + 
                              " / ema200Low=" + DoubleToString(ema200Low[1], 2) + ") ";
            if(!trendForceOK)
                blockReason += "WEAK_TREND(slope=" + DoubleToString(normalizedSlopeStrength, 4) + 
                              " < " + DoubleToString(MIN_SLOPE_STRENGTH, 2) + ")";
            Print(">>> v3.8 SHORT BLOCKED: ", blockReason);
        }
    }
}

//+------------------------------------------------------------------+
//| Permission Transitions                                           |
//+------------------------------------------------------------------+
void CheckPermissionTransitions()
{
    if(longEntryAllowed && !longEntryAllowedPrev)
    {
        tradeTakenThisPermission = false;
        if(EnableDebugPrints)
            Print(">>> LONG PERMISSION START");
    }
    
    if(!longEntryAllowed && longEntryAllowedPrev)
    {
        tradeTakenThisPermission = false;
        if(EnableDebugPrints)
            Print(">>> LONG PERMISSION END");
    }
    
    if(shortEntryAllowed && !shortEntryAllowedPrev)
    {
        tradeTakenThisPermission = false;
        if(EnableDebugPrints)
            Print(">>> SHORT PERMISSION START");
    }
    
    if(!shortEntryAllowed && shortEntryAllowedPrev)
    {
        tradeTakenThisPermission = false;
        if(EnableDebugPrints)
            Print(">>> SHORT PERMISSION END");
    }
}

//+------------------------------------------------------------------+
//| v3.9.4: HTF ADX Regime Filter Functions                          |
//+------------------------------------------------------------------+
bool UpdateHTF_ADX()
{
    if(!EnableADXFilter)
    {
        g_adxValue = 100.0;
        g_adxValid = true;
        return true;
    }

    datetime times[];
    ArraySetAsSeries(times, true);

    if(CopyTime(_Symbol, ADX_Timeframe, 0, 1, times) < 1)
        return false;

    if(times[0] == g_adxLastBarTime && g_adxValid)
        return true;

    int handleADX = iADX(_Symbol, ADX_Timeframe, ADX_Period);
    if(handleADX == INVALID_HANDLE)
        return false;

    double adxBuffer[];
    ArraySetAsSeries(adxBuffer, true);

    if(CopyBuffer(handleADX, 0, 0, 1, adxBuffer) < 1)
    {
        IndicatorRelease(handleADX);
        return false;
    }

    IndicatorRelease(handleADX);

    g_adxValue = adxBuffer[0];
    g_adxLastBarTime = times[0];
    g_adxValid = true;

    return true;
}

bool RegimeAllowsNewBasket()
{
    if(!EnableADXFilter)
        return true;

    if(!UpdateHTF_ADX())
        return false;   // fail-safe block

    if(g_adxValue < ADX_Threshold)
        return false;

    return true;
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
    
    // === v3.9.4: HTF ADX REGIME FILTER ===
    if(!BasketHasPositions())
    {
        if(!RegimeAllowsNewBasket())
        {
            if(EnableDebugPrints)
                Print(">>> v3.9.4 ADX FILTER BLOCKED ENTRY | ADX=",
                      DoubleToString(g_adxValue, 2));
            return;
        }
    }
    
    if(longEntryAllowed)
    {
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        if(OpenBuyTrade())
        {
            tradeTakenThisPermission = true;
            // v3.9: Set grid anchor to entry price
            lastAddAnchorPrice = ask;
            if(EnableDebugPrints)
                Print(">>> BUY TRADE OPENED | Anchor set: ", DoubleToString(lastAddAnchorPrice, 2),
                      " | ADX=", DoubleToString(g_adxValue, 2));
        }
    }
    
    if(shortEntryAllowed)
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        if(OpenSellTrade())
        {
            tradeTakenThisPermission = true;
            // v3.9: Set grid anchor to entry price
            lastAddAnchorPrice = bid;
            if(EnableDebugPrints)
                Print(">>> SELL TRADE OPENED | Anchor set: ", DoubleToString(lastAddAnchorPrice, 2),
                      " | ADX=", DoubleToString(g_adxValue, 2));
        }
    }
}

bool OpenBuyTrade()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "TrendPerm_v3_9_6_BUY"))
        return true;
    Print("ERROR: Failed to open BUY trade. Error: ", GetLastError());
    return false;
}

bool OpenSellTrade()
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "TrendPerm_v3_9_6_SELL"))
        return true;
    Print("ERROR: Failed to open SELL trade. Error: ", GetLastError());
    return false;
}

void CheckPositionStatus()
{
    bool hadPosition = hasOpenPosition;
    hasOpenPosition = BasketHasPositions();  // v3.7: Use derived function
    
    if(hadPosition && !hasOpenPosition)
    {
        // v3.7: Basket closed - reset peak tracking
        ResetBasketState();
        
        if(!tradingDisabled && (disableReason == "BASKET STOP HIT (Ready)" || 
           disableReason == "PEAK GIVEBACK (Ready)" || disableReason == "DAILY FLOOR EXIT (Ready)" ||
           disableReason == "MAE STOP (Ready)" || disableReason == "TIME STOP (Ready)" ||
           disableReason == "EXPANSION FAIL (Ready)"))
            disableReason = "";
    }
}

//+------------------------------------------------------------------+
//| v3.9: ManageTakeProfit - DISABLED (per-position TP removed)      |
//+------------------------------------------------------------------+
void ManageTakeProfit()
{
    // v3.9: Per-position TakeProfit DISABLED
    // Replaced by basket-level asymmetric exits:
    //   - Peak giveback protection (Layer0_RiskCheck PRIORITY 3b)
    //   - Daily profit floor (Layer0_RiskCheck PRIORITY 3a)
    // TakeProfitDollars input is preserved but unused.
}

//+------------------------------------------------------------------+
//| v3.9: Fixed Grid Pyramiding - Add positions at fixed gaps        |
//+------------------------------------------------------------------+
void ManageGridAdds()
{
    // Must have an active basket with a valid anchor
    if(!BasketHasPositions())
        return;
    if(lastAddAnchorPrice == 0.0)
        return;
    
    // Need EMA data for trend intact check
    if(ArraySize(emaFast) < 2)
        return;
    
    int direction = GetBasketDirection();
    double completedClose = iClose(_Symbol, PERIOD_CURRENT, 1);
    
    if(direction == BASKET_LONG)
    {
        // Trend intact check: Close[1] > EMA10[1]
        if(completedClose <= emaFast[1])
            return;
        
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        if(bid >= lastAddAnchorPrice + FixedGridGap_USD)
        {
            double prevAnchor = lastAddAnchorPrice;
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "TrendPerm_v3_9_6_GRID_BUY"))
            {
                lastAddAnchorPrice = ask;
                if(EnableDebugPrints)
                {
                    Print(">>> v3.9 GRID ADD BUY | Price: ", DoubleToString(ask, 2),
                          " | OldAnchor: ", DoubleToString(prevAnchor, 2),
                          " | NewAnchor: ", DoubleToString(lastAddAnchorPrice, 2),
                          " | Gap: $", DoubleToString(FixedGridGap_USD, 2),
                          " | BasketFloat: $", DoubleToString(basketFloatingPL, 2),
                          " | BasketPeak: $", DoubleToString(basketPeakFloatingPL, 2));
                }
            }
        }
    }
    else if(direction == BASKET_SHORT)
    {
        // Trend intact check: Close[1] < EMA10[1]
        if(completedClose >= emaFast[1])
            return;
        
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        if(ask <= lastAddAnchorPrice - FixedGridGap_USD)
        {
            double prevAnchor = lastAddAnchorPrice;
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "TrendPerm_v3_9_6_GRID_SELL"))
            {
                lastAddAnchorPrice = bid;
                if(EnableDebugPrints)
                {
                    Print(">>> v3.9 GRID ADD SELL | Price: ", DoubleToString(bid, 2),
                          " | OldAnchor: ", DoubleToString(prevAnchor, 2),
                          " | NewAnchor: ", DoubleToString(lastAddAnchorPrice, 2),
                          " | Gap: $", DoubleToString(FixedGridGap_USD, 2),
                          " | BasketFloat: $", DoubleToString(basketFloatingPL, 2),
                          " | BasketPeak: $", DoubleToString(basketPeakFloatingPL, 2));
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
#define PANEL_X           10
#define PANEL_Y           25
#define PANEL_WIDTH       360
#define PANEL_FONT        "Segoe UI"
#define PANEL_FONT_BOLD   "Segoe UI Semibold"
#define PANEL_FONT_SIZE   10
#define PREFIX            "TPv39_"

#define CLR_HEADER_BG     C'15,25,45'
#define CLR_SECTION_BG    C'25,40,65'
#define CLR_CONTENT_BG    C'10,18,32'
#define CLR_SEPARATOR     C'40,60,90'
#define CLR_LABEL         C'140,160,180'
#define CLR_VALUE         C'220,230,240'

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
    CreateLabel(PREFIX + "Version", PANEL_X + 270, y + 14, "v3.9.6", C'100,180,255', 12, PANEL_FONT_BOLD);
    CreateLabel(PREFIX + "TimeSymbol", PANEL_X + padding, y + 40, "", C'100,140,180', PANEL_FONT_SIZE, PANEL_FONT);
    y += 70;
    
    CreateBox(PREFIX + "Layer0BG", PANEL_X, y, PANEL_WIDTH, 30, CLR_SECTION_BG);
    CreateLabel(PREFIX + "Layer0Title", PANEL_X + padding, y + 6, "◈ LAYER 0 - RISK GOVERNOR", clrWhite, 11, PANEL_FONT_BOLD);
    y += 35;
    
    CreateBox(PREFIX + "Layer0ContentBG", PANEL_X, y, PANEL_WIDTH, 285, CLR_CONTENT_BG);
    int contentY = y + 10;
    
    CreateLabel(PREFIX + "TradingLabel", PANEL_X + padding, contentY, "Trading:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "TradingValue", valueX, contentY, "", clrLime, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "ReasonLabel", PANEL_X + padding, contentY, "Status:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "ReasonValue", valueX, contentY, "", clrOrange, PANEL_FONT_SIZE, PANEL_FONT);
    contentY += rowHeight + sectionGap;
    
    CreateBox(PREFIX + "Sep1", PANEL_X + padding, contentY, PANEL_WIDTH - 30, 1, CLR_SEPARATOR);
    contentY += 12;
    
    // v3.7: Daily Realized P&L (emphasized)
    CreateLabel(PREFIX + "DailyRealizedLabel", PANEL_X + padding, contentY, "Daily Realized:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "DailyRealizedValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    // v3.7: Daily Floating (for display only)
    CreateLabel(PREFIX + "DailyFloatLabel", PANEL_X + padding, contentY, "Daily Floating:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "DailyFloatValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "BasketPLLabel", PANEL_X + padding, contentY, "Basket Float P&L:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "BasketPLValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    // Basket Direction row
    CreateLabel(PREFIX + "BasketDirLabel", PANEL_X + padding, contentY, "Basket Direction:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "BasketDirValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "BasketPeakLabel", PANEL_X + padding, contentY, "Basket Peak P&L:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "BasketPeakValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateBox(PREFIX + "Sep2", PANEL_X + padding, contentY, PANEL_WIDTH - 30, 1, CLR_SEPARATOR);
    contentY += 12;
    
    CreateLabel(PREFIX + "ProtectLabel", PANEL_X + padding, contentY, "Profit Protection:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "ProtectValue", valueX, contentY, "", CLR_VALUE, PANEL_FONT_SIZE, PANEL_FONT_BOLD);
    
    y += 290;
    
    CreateBox(PREFIX + "ExecBG", PANEL_X, y, PANEL_WIDTH, 30, CLR_SECTION_BG);
    CreateLabel(PREFIX + "ExecTitle", PANEL_X + padding, y + 6, "◈ EXECUTION STATUS", clrWhite, 11, PANEL_FONT_BOLD);
    y += 35;
    
    // v3.9: Increased height from 120 to 150 for anchor row
    CreateBox(PREFIX + "ExecContentBG", PANEL_X, y, PANEL_WIDTH, 150, CLR_CONTENT_BG);
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
    
    CreateLabel(PREFIX + "FloatPLLabel", PANEL_X + padding, contentY, "Account Float:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "FloatPLValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    // v3.9: Grid anchor row
    CreateLabel(PREFIX + "AnchorLabel", PANEL_X + padding, contentY, "Next Add Anchor:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "AnchorValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    
    ChartRedraw(0);
}

void UpdatePanel()
{
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double floatingPL = currentEquity - currentBalance;
    double dailyEquityPL = currentEquity - dailyStartEquity;
    
    // v3.7: Derive basket state for display
    bool basketExists = BasketHasPositions();
    int currentDirection = GetBasketDirection();
    
    ObjectSetString(0, PREFIX + "TimeSymbol", OBJPROP_TEXT, 
        "⏱ " + TimeToString(GetNewYorkTime(), TIME_DATE|TIME_MINUTES) + " NY  " + _Symbol);
    
    string tradingState = dailyLossLimitHit ? "✖ DAILY LOSS LIMIT" :
        (tradingDisabled && disableReason == "DAILY TARGET REACHED") ? "★ DAILY TARGET HIT" :
        tradingDisabled ? "○ DISABLED" : "● ENABLED";
    color tradingColor = dailyLossLimitHit ? clrRed :
        (tradingDisabled && disableReason == "DAILY TARGET REACHED") ? clrGold :
        tradingDisabled ? clrOrange : clrLime;
    ObjectSetString(0, PREFIX + "TradingValue", OBJPROP_TEXT, tradingState);
    ObjectSetInteger(0, PREFIX + "TradingValue", OBJPROP_COLOR, tradingColor);
    
    string statusText = disableReason != "" ? disableReason : (basketExists ? "BASKET ACTIVE" : "READY");
    color statusColor = (disableReason == "DAILY LOSS LIMIT HIT") ? clrRed :
        (disableReason == "DAILY TARGET REACHED") ? clrGold :
        (disableReason != "") ? clrOrange : clrLime;
    ObjectSetString(0, PREFIX + "ReasonValue", OBJPROP_TEXT, statusText);
    ObjectSetInteger(0, PREFIX + "ReasonValue", OBJPROP_COLOR, statusColor);
    
    // v3.7: Daily Realized P&L (THE control metric)
    string dailyRealizedText = "$" + DoubleToString(dailyRealizedPL, 2) + " / ±$" + DoubleToString(DailyLossLimit_USD, 2);
    color dailyRealizedColor = dailyRealizedPL >= 0 ? clrLime : (dailyRealizedPL > -DailyLossLimit_USD * 0.5 ? clrOrange : clrRed);
    ObjectSetString(0, PREFIX + "DailyRealizedValue", OBJPROP_TEXT, dailyRealizedText);
    ObjectSetInteger(0, PREFIX + "DailyRealizedValue", OBJPROP_COLOR, dailyRealizedColor);
    
    // v3.7: Daily Floating (display only, not used for control)
    string dailyFloatText = "$" + DoubleToString(floatingPL, 2) + " (unrealized)";
    color dailyFloatColor = floatingPL >= 0 ? C'100,180,100' : C'180,100,100';  // Muted colors
    ObjectSetString(0, PREFIX + "DailyFloatValue", OBJPROP_TEXT, dailyFloatText);
    ObjectSetInteger(0, PREFIX + "DailyFloatValue", OBJPROP_COLOR, dailyFloatColor);
    
    string basketPLText = !basketExists ? "○ NO BASKET" :
        "$" + DoubleToString(basketFloatingPL, 2) + " / -$" + DoubleToString(BasketStopLoss_USD, 2);
    color basketPLColor = !basketExists ? clrGray :
        basketFloatingPL >= 0 ? clrLime : (basketFloatingPL > -BasketStopLoss_USD * 0.5 ? clrOrange : clrRed);
    ObjectSetString(0, PREFIX + "BasketPLValue", OBJPROP_TEXT, basketPLText);
    ObjectSetInteger(0, PREFIX + "BasketPLValue", OBJPROP_COLOR, basketPLColor);
    
    // Basket Direction (derived)
    string dirText;
    color dirColor;
    if(currentDirection == BASKET_LONG)
    {
        dirText = "▲ LONG BASKET";
        dirColor = clrLime;
    }
    else if(currentDirection == BASKET_SHORT)
    {
        dirText = "▼ SHORT BASKET";
        dirColor = clrRed;
    }
    else
    {
        dirText = "○ NO BASKET";
        dirColor = clrGray;
    }
    ObjectSetString(0, PREFIX + "BasketDirValue", OBJPROP_TEXT, dirText);
    ObjectSetInteger(0, PREFIX + "BasketDirValue", OBJPROP_COLOR, dirColor);
    
    string basketPeakText = !basketExists ? "○ NO BASKET" :
        "$" + DoubleToString(basketPeakFloatingPL, 2);
    color basketPeakColor = !basketExists ? clrGray :
        (basketPeakFloatingPL >= MinProfitToProtect_USD ? clrLime : CLR_VALUE);
    ObjectSetString(0, PREFIX + "BasketPeakValue", OBJPROP_TEXT, basketPeakText);
    ObjectSetInteger(0, PREFIX + "BasketPeakValue", OBJPROP_COLOR, basketPeakColor);
    
    string protectText = !basketExists ? "○ NO POSITION" :
        profitProtectionActivated ? "● ACTIVE (peak >= $" + DoubleToString(MinProfitToProtect_USD, 2) + ")" :
        "○ INACTIVE (peak < $" + DoubleToString(MinProfitToProtect_USD, 2) + ")";
    color protectColor = !basketExists ? clrGray : (profitProtectionActivated ? clrLime : clrOrange);
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
    
    // v3.9: Grid anchor display
    string anchorText;
    color anchorColor;
    if(!basketExists || lastAddAnchorPrice == 0.0)
    {
        anchorText = "○ NO BASKET";
        anchorColor = clrGray;
    }
    else
    {
        double nextPrice = (currentDirection == BASKET_LONG) ? 
            lastAddAnchorPrice + FixedGridGap_USD : lastAddAnchorPrice - FixedGridGap_USD;
        anchorText = DoubleToString(nextPrice, 2) + " (gap $" + DoubleToString(FixedGridGap_USD, 2) + ")";
        anchorColor = C'100,180,255';
    }
    ObjectSetString(0, PREFIX + "AnchorValue", OBJPROP_TEXT, anchorText);
    ObjectSetInteger(0, PREFIX + "AnchorValue", OBJPROP_COLOR, anchorColor);
    
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
    Print("TrendPermissionEA_v3_9_6 deinitialized. Reason: ", reason);
    Print("Final Daily Realized P&L: $", DoubleToString(dailyRealizedPL, 2));
}
