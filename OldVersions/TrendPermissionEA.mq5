//+------------------------------------------------------------------+
//|                                           TrendPermissionEA.mq5 |
//|                          Trend Entry Permission Regimes Only EA |
//|                           Direct Translation from Pine Script v5 |
//+------------------------------------------------------------------+
#property copyright "TrendPermission"
#property version   "1.0"
#property description "Entry Permission Regimes Detection - No Trading"

//--- Input parameters
input group "01. Trend EMAs"
input int    TrendEMA_Len = 200;      // Trend EMA Length
input int    FastEMA_Len  = 10;       // Fast EMA Length  
input int    SlowEMA_Len  = 30;       // Slow EMA Length

input group "02. Debug"
input bool   EnableDebugPrints = true; // Enable Debug Prints

//--- Global variables for EMA calculations
double ema200High[], ema200Low[];
double emaFast[], emaSlow[];
double emaFastPrev, emaSlowPrev;
double emaFastSlope, emaSlowSlope;
double emaFastSlopePrev, emaFastD2;
double emaGap, emaGapPrev, gapSlope;

//--- Entry Permission States
bool longPermissionActive = false;
bool shortPermissionActive = false;
bool longEntryAllowed = false;
bool shortEntryAllowed = false;
bool longEntryAllowedPrev = false;
bool shortEntryAllowedPrev = false;

//--- Bar detection
datetime lastProcessedTime = 0;

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
    
    Print("TrendPermissionEA initialized for ", _Symbol, " on M1");
    Print("Entry Permission Detection Only - No Trading Functions");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // New bar detection
    datetime currentTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentTime <= lastProcessedTime)
        return;
    
    lastProcessedTime = currentTime;
    
    // Process new bar
    ProcessNewBar();
}

//+------------------------------------------------------------------+
//| Process New Bar - Main Logic                                    |
//+------------------------------------------------------------------+
void ProcessNewBar()
{
    // Store previous states
    longEntryAllowedPrev = longEntryAllowed;
    shortEntryAllowedPrev = shortEntryAllowed;
    emaFastSlopePrev = emaFastSlope;
    emaGapPrev = emaGap;
    
    // Calculate EMAs (exact Pine semantics)
    if(!CalculateEMAs())
        return; // Exit if EMA calculation failed
    
    // Calculate slopes and derivatives
    CalculateSlopes();
    
    // Calculate gap dynamics
    CalculateGapDynamics();
    
    // Determine entry permissions (AUTHORITATIVE LOGIC)
    DetermineEntryPermissions();
    
    // Update permission states (persistence logic)
    UpdatePermissionStates();
    
    // Debug logging
    if(EnableDebugPrints)
        LogPermissionStates();
}

//+------------------------------------------------------------------+
//| Calculate EMAs - Direct Pine Translation                        |
//+------------------------------------------------------------------+
bool CalculateEMAs()
{
    // Resize arrays
    ArrayResize(ema200High, 2);
    ArrayResize(ema200Low, 2);
    ArrayResize(emaFast, 2);
    ArrayResize(emaSlow, 2);
    
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
    
    // Get EMA values
    if(CopyBuffer(handleEmaHigh, 0, 0, 2, ema200High) < 2 ||
       CopyBuffer(handleEmaLow, 0, 0, 2, ema200Low) < 2 ||
       CopyBuffer(handleEmaFast, 0, 0, 2, emaFast) < 2 ||
       CopyBuffer(handleEmaSlow, 0, 0, 2, emaSlow) < 2)
    {
        Print("ERROR: Failed to get EMA data - insufficient bars");
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
//| Calculate Slopes - First Derivatives                            |
//+------------------------------------------------------------------+
void CalculateSlopes()
{
    // First derivatives (slopes)
    emaFastSlope = emaFast[0] - emaFast[1];
    emaSlowSlope = emaSlow[0] - emaSlow[1];
    
    // Second derivative (curvature)
    emaFastD2 = emaFastSlope - emaFastSlopePrev;
}

//+------------------------------------------------------------------+
//| Calculate Gap Dynamics                                          |
//+------------------------------------------------------------------+
void CalculateGapDynamics()
{
    // Gap calculation
    emaGap = emaFast[0] - emaSlow[0];
    
    // Gap slope (first derivative of gap)
    gapSlope = emaGap - emaGapPrev;
}

//+------------------------------------------------------------------+
//| Determine Entry Permissions - AUTHORITATIVE LOGIC              |
//+------------------------------------------------------------------+
void DetermineEntryPermissions()
{
    double currentClose = iClose(_Symbol, PERIOD_CURRENT, 0);
    
    // === REGIME CONDITIONS ===
    bool isBullRegime = currentClose > ema200High[0];
    bool isBearRegime = currentClose < ema200Low[0];
    
    // === ACCELERATION CONDITIONS ===
    bool accelUp = (emaFastSlope > 0) && (emaFastD2 > 0);
    bool accelDown = (emaFastSlope < 0) && (emaFastD2 < 0);
    
    // === GAP CONDITIONS ===
    bool gapBull = emaGap > 0;
    bool gapBear = emaGap < 0;
    bool gapWidening = gapSlope > 0;
    bool gapNarrowing = gapSlope < 0;
    
    // === ENTRY PERMISSION LOGIC (DIRECT PINE TRANSLATION) ===
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
//| Update Permission States - Persistence Logic                    |
//+------------------------------------------------------------------+
void UpdatePermissionStates()
{
    // === LONG PERMISSION STATE TRANSITIONS ===
    // Start: false → true
    if(longEntryAllowed && !longEntryAllowedPrev)
    {
        longPermissionActive = true;
        shortPermissionActive = false; // Mutual exclusivity
        if(EnableDebugPrints)
            Print(">>> LONG OK START at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
    }
    
    // End: true → false  
    if(!longEntryAllowed && longEntryAllowedPrev)
    {
        longPermissionActive = false;
        if(EnableDebugPrints)
            Print(">>> LONG OK END at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
    }
    
    // === SHORT PERMISSION STATE TRANSITIONS ===
    // Start: false → true
    if(shortEntryAllowed && !shortEntryAllowedPrev)
    {
        shortPermissionActive = true;
        longPermissionActive = false; // Mutual exclusivity
        if(EnableDebugPrints)
            Print(">>> SHORT OK START at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
    }
    
    // End: true → false
    if(!shortEntryAllowed && shortEntryAllowedPrev)
    {
        shortPermissionActive = false;
        if(EnableDebugPrints)
            Print(">>> SHORT OK END at ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
    }
}

//+------------------------------------------------------------------+
//| Log Permission States - Debug Output                            |
//+------------------------------------------------------------------+
void LogPermissionStates()
{
    string timeStr = TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES);
    
    Print("=== PERMISSION STATE at ", timeStr, " ===");
    Print("longEntryAllowed: ", (longEntryAllowed ? "TRUE" : "FALSE"));
    Print("shortEntryAllowed: ", (shortEntryAllowed ? "TRUE" : "FALSE")); 
    Print("longPermissionActive: ", (longPermissionActive ? "TRUE" : "FALSE"));
    Print("shortPermissionActive: ", (shortPermissionActive ? "TRUE" : "FALSE"));
    Print("emaFastSlope: ", DoubleToString(emaFastSlope, 5));
    Print("emaSlowSlope: ", DoubleToString(emaSlowSlope, 5));
    Print("emaFastD2: ", DoubleToString(emaFastD2, 5));
    Print("gapSlope: ", DoubleToString(gapSlope, 5));
    Print("====================================");
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("TrendPermissionEA deinitialized. Reason: ", reason);
}