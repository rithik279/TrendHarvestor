//+------------------------------------------------------------------+
//|                                    VolatilityCompressorEA_v0_1.mq5 |
//|                     Intraday Volatility Compression Harvester      |
//|                              DIAGNOSTIC BUILD – v0.1               |
//+------------------------------------------------------------------+
#property copyright "VolatilityCompressor"
#property version   "0.1"
#property description "v0.1 – Diagnostic Regime State Machine + Tick Velocity Decay Fade"
#property description "Separate MagicNumber. No interference with TrendPermissionEA."
#property description "M5 structure + Tick velocity decay confirmation."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| SECTION 0 — ENUMS & COMPILE-TIME CONSTANTS                      |
//+------------------------------------------------------------------+

enum RegimeState
{
    REGIME_NEUTRAL,                // No active conditions
    REGIME_TREND_EXPANSION,        // Trend permission active
    REGIME_TREND_DECELERATION,     // Expansion weakening
    REGIME_EXHAUSTION_WINDOW,      // Decay confirmed, ready to fade
    REGIME_ACTIVE_FADE,            // Basket open
    REGIME_DISABLED                // Daily loss / manual disable
};

// Basket direction constants
#define BASKET_NONE   0
#define BASKET_LONG   1
#define BASKET_SHORT -1

// Trend permission EMA parameters (FROZEN — must match TrendPermissionEA)
#define TP_EMA_TREND_LEN   200
#define TP_FAST_LEN        10
#define TP_SLOW_LEN        30
#define TP_ATR_PERIOD      14
#define TP_MIN_SLOPE       0.12

// Lot ladder (hard ceiling for array allocation)
#define MAX_GRID_LEVELS    50

//+------------------------------------------------------------------+
//| SECTION 1 — INPUT PARAMETERS                                    |
//+------------------------------------------------------------------+

input group "00. Global Risk"
input double DailyLossCap_USD         = 100.0;   // Daily loss cap ($) — disables EA for NY day
input double DailyProfitTarget_USD    = 200.0;   // Daily realized profit target ($)
input int    BrokerToNYOffsetHours    = -7;       // Broker → New York offset (hours)
input int    CompressorMagic          = 777888;   // MagicNumber (must differ from TrendPermission)

input group "01. Execution"
input double BaseLotSize              = 0.01;     // Starting lot size (Level 1)
input double LotIncrement             = 0.01;     // Lot increase per level (linear: 0.01, 0.02, 0.03...)
input double MaxTotalLots             = 1.6;      // Maximum total lots across all levels
input int    MaxPositions              = 10;       // Maximum grid positions (levels)
input double MaxSpreadPoints          = 50.0;     // Max spread (points) to allow entry
input int    SlippagePoints           = 15;       // Max slippage (points)

input group "02. Impulse Detection (M5)"
input double MinImpulseDisplacement_USD = 5.0;    // Minimum impulse displacement ($) to consider fade
input int    ImpulseLookbackBars      = 6;         // M5 bars to measure impulse
input double ImpulseBodyRatio         = 0.55;      // Min net-displacement / total-range ratio

input group "03. Velocity Decay"
input int    TickBufferSeconds        = 6;         // Tick buffer window (seconds)
input double VFastDecayRatio          = 0.45;      // v_fast <= ratio × peak_v_fast → decay
input double VSlowDecayRatio          = 0.75;      // v_slow <= ratio × prev_v_slow → decay
input double ReAccelerationRatio      = 0.90;      // v_fast >= ratio × peak → re-acceleration

input group "04. Grid Spacing"
input double MinGridSpacing_Pips      = 12.0;      // Minimum grid spacing (pips)
input double GridATR_Multiplier       = 0.80;      // Grid spacing = max(min_pips, multiplier × ATR(M1))

input group "05. Survival"
input double BasketStopPct            = 2.0;       // Hard basket stop (% of equity)
input double StructuralInvalid_Mult   = 1.8;       // Adverse move > mult × impulse → invalidation
input int    TimeStopMinutes          = 45;         // Max basket age (minutes)

input group "06. Debug"
input bool   EnableDebugPrints        = true;       // Verbose logging
input bool   EnableChartPanel         = true;       // Show debug overlay panel

//+------------------------------------------------------------------+
//| SECTION 2 — GLOBAL VARIABLES                                    |
//+------------------------------------------------------------------+

// === Regime State Machine ===
RegimeState  g_currentRegime      = REGIME_NEUTRAL;
RegimeState  g_previousRegime     = REGIME_NEUTRAL;
int          g_impulseDirection   = BASKET_NONE;     // Direction of detected impulse (+1 up, -1 down)
double       g_impulseSize        = 0.0;             // Displacement of impulse ($)
double       g_impulseAnchorPrice = 0.0;             // Price at TREND_EXPANSION start
datetime     g_expansionStartTime = 0;               // When TREND_EXPANSION began

// === Trend Permission Veto (replicated M1 logic) ===
int    hVetoEmaHigh  = INVALID_HANDLE;
int    hVetoEmaLow   = INVALID_HANDLE;
int    hVetoEmaFast  = INVALID_HANDLE;
int    hVetoEmaSlow  = INVALID_HANDLE;
int    hVetoATR_M1   = INVALID_HANDLE;

double vetoEma200High[], vetoEma200Low[];
double vetoEmaFast[], vetoEmaSlow[];
double vetoATR[];
double vetoFastSlope, vetoSlowSlope;
double vetoFastSlopePrev, vetoFastD2;
double vetoGap, vetoGapPrev, vetoGapSlope;

bool   longEntryAllowed      = false;
bool   shortEntryAllowed     = false;
bool   longEntryAllowedPrev  = false;
bool   shortEntryAllowedPrev = false;

// === Tick Velocity Engine ===
struct TickEntry
{
    double price;
    long   time_msc;   // millisecond timestamp
};
TickEntry g_tickBuffer[];
int       g_tickCount = 0;

double g_vFast          = 0.0;
double g_vSlow          = 0.0;
double g_peakVFast      = 0.0;
double g_prevVSlow      = 0.0;
bool   g_stallCondition = false;
bool   g_reAccelFlag    = false;

// === Execution Basket ===
CTrade trade;
double g_lotLadder[MAX_GRID_LEVELS];      // Filled in OnInit()
int    g_currentLevel          = 0;        // Current grid level (0 = no position)
double g_basketFloatingPL      = 0.0;
double g_basketEntryAnchor     = 0.0;      // Entry price of first fade position
double g_lastGridAnchor        = 0.0;      // Price of last grid add
int    g_fadeDirection          = BASKET_NONE;  // Direction of fade basket
datetime g_basketEntryTime     = 0;
double g_totalLotsOpen         = 0.0;

// === Daily Risk ===
double g_dailyStartEquity = 0.0;
double g_dailyRealizedPL  = 0.0;
bool   g_dailyLossHit     = false;
bool   g_tradingDisabled   = false;
string g_disableReason     = "";
datetime g_currentNYDate   = 0;

// === Indicator Handles ===
int    hATR_M1  = INVALID_HANDLE;    // ATR(14) on M1 for grid spacing

// === Bar Tracking ===
datetime g_lastM1Bar  = 0;
datetime g_lastM5Bar  = 0;

// === Veto Logging (once per bar) ===
datetime g_vetoLogBar = 0;

//+------------------------------------------------------------------+
//| SECTION 3 — SYMBOL VALIDATION                                   |
//+------------------------------------------------------------------+
bool IsGoldSymbol(string sym)
{
    string upper = sym;
    StringToUpper(upper);
    return (StringFind(upper, "XAUUSD") == 0);
}

//+------------------------------------------------------------------+
//| SECTION 3A — OnInit                                             |
//+------------------------------------------------------------------+
int OnInit()
{
    // --- Symbol check ---
    if(!IsGoldSymbol(_Symbol))
    {
        Print("ERROR: VolatilityCompressor designed for XAUUSD only. Current: ", _Symbol);
        return(INIT_FAILED);
    }
    
    // --- Trade setup ---
    trade.SetExpertMagicNumber(CompressorMagic);
    trade.SetDeviationInPoints(SlippagePoints);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    
    // --- Lot ladder (linear: BaseLotSize + level × LotIncrement) ---
    int effectiveMaxPos = MathMin(MaxPositions, MAX_GRID_LEVELS);
    for(int i = 0; i < effectiveMaxPos; i++)
        g_lotLadder[i] = BaseLotSize + (double)i * LotIncrement;
    
    // --- Indicator handles (Trend Permission veto — M1) ---
    hVetoEmaHigh = iMA(_Symbol, PERIOD_M1, TP_EMA_TREND_LEN, 0, MODE_EMA, PRICE_HIGH);
    hVetoEmaLow  = iMA(_Symbol, PERIOD_M1, TP_EMA_TREND_LEN, 0, MODE_EMA, PRICE_LOW);
    hVetoEmaFast = iMA(_Symbol, PERIOD_M1, TP_FAST_LEN, 0, MODE_EMA, PRICE_CLOSE);
    hVetoEmaSlow = iMA(_Symbol, PERIOD_M1, TP_SLOW_LEN, 0, MODE_EMA, PRICE_CLOSE);
    hVetoATR_M1  = iATR(_Symbol, PERIOD_M1, TP_ATR_PERIOD);
    
    // --- ATR for grid spacing (M1) ---
    hATR_M1      = iATR(_Symbol, PERIOD_M1, 14);
    
    if(hVetoEmaHigh == INVALID_HANDLE || hVetoEmaLow == INVALID_HANDLE ||
       hVetoEmaFast == INVALID_HANDLE || hVetoEmaSlow == INVALID_HANDLE ||
       hVetoATR_M1 == INVALID_HANDLE  || hATR_M1 == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create indicator handles");
        return(INIT_FAILED);
    }
    
    // --- Initialize tick buffer ---
    ArrayResize(g_tickBuffer, 0);
    g_tickCount = 0;
    
    // --- Initialize state ---
    InitializeDailyState();
    ResetBasketState();
    g_currentRegime = REGIME_NEUTRAL;
    g_previousRegime = REGIME_NEUTRAL;
    
    // --- Panel ---
    if(EnableChartPanel)
        CreatePanel();
    
    Print("==============================================");
    Print("VolatilityCompressorEA_v0_1 initialized (DIAGNOSTIC BUILD)");
    Print("Symbol: ", _Symbol);
    Print("MagicNumber: ", CompressorMagic);
    Print("----------------------------------------------");
    Print("Lot Ladder: Linear (Base=", DoubleToString(BaseLotSize, 2), " + ", DoubleToString(LotIncrement, 2), "/level)");
    Print("MaxPositions: ", MaxPositions, " | MaxTotalLots: ", DoubleToString(MaxTotalLots, 2));
    Print("Grid Spacing: max(", DoubleToString(MinGridSpacing_Pips, 1), " pips, ", 
          DoubleToString(GridATR_Multiplier, 2), " × ATR(M1))");
    Print("BasketStop: ", DoubleToString(BasketStopPct, 1), "% equity");
    Print("StructuralInvalidation: ", DoubleToString(StructuralInvalid_Mult, 1), " × impulse");
    Print("TimeStop: ", TimeStopMinutes, " min");
    Print("DailyLossCap: $", DoubleToString(DailyLossCap_USD, 2));
    Print("Trend Permission Veto: ACTIVE (M1 EMA replication)");
    Print("==============================================");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| SECTION 3B — OnDeinit                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // Release indicator handles
    if(hVetoEmaHigh != INVALID_HANDLE) IndicatorRelease(hVetoEmaHigh);
    if(hVetoEmaLow  != INVALID_HANDLE) IndicatorRelease(hVetoEmaLow);
    if(hVetoEmaFast != INVALID_HANDLE) IndicatorRelease(hVetoEmaFast);
    if(hVetoEmaSlow != INVALID_HANDLE) IndicatorRelease(hVetoEmaSlow);
    if(hVetoATR_M1  != INVALID_HANDLE) IndicatorRelease(hVetoATR_M1);
    if(hATR_M1      != INVALID_HANDLE) IndicatorRelease(hATR_M1);
    
    if(EnableChartPanel)
        DeletePanel();
    
    Comment("");
    Print("VolatilityCompressorEA_v0_1 deinitialized. Reason: ", reason);
    Print("Final Daily Realized P&L: $", DoubleToString(g_dailyRealizedPL, 2));
}

//+------------------------------------------------------------------+
//| SECTION 4 — OnTick (MAIN FLOW)                                 |
//+------------------------------------------------------------------+
void OnTick()
{
    // --- 1. Day reset check ---
    CheckDayReset();
    
    // --- 2. Update tick buffer + velocities ---
    UpdateTickBuffer();
    ComputeVelocities();
    
    // --- 3. Daily risk checks ---
    CheckDailyRisk();
    
    // --- 4. Basket health (survival controls) ---
    if(BasketHasPositions())
    {
        g_basketFloatingPL = CalculateBasketFloat();
        CheckSurvivalControls();
    }
    else if(g_currentLevel > 0)
    {
        // Basket closed externally — reset
        LogBasketClose("ExternalClose");
        ResetBasketState();
    }
    
    // --- 5. On new M1 bar: Update trend permission veto ---
    datetime m1Bar = iTime(_Symbol, PERIOD_M1, 0);
    if(m1Bar != g_lastM1Bar)
    {
        g_lastM1Bar = m1Bar;
        UpdateTrendPermissionVeto();
    }
    
    // --- 6. On new M5 bar: Update impulse detection ---
    datetime m5Bar = iTime(_Symbol, PERIOD_M5, 0);
    bool newM5 = false;
    if(m5Bar != g_lastM5Bar)
    {
        g_lastM5Bar = m5Bar;
        newM5 = true;
        UpdateImpulseDetection();
    }
    
    // --- 7. Update regime state machine (every tick) ---
    UpdateRegimeStateMachine();
    
    // --- 8. Execution logic ---
    if(!g_tradingDisabled)
    {
        if(g_currentRegime == REGIME_EXHAUSTION_WINDOW)
            TryFadeEntry();
        
        if(g_currentRegime == REGIME_ACTIVE_FADE)
            ManageGridAdds();
    }
    
    // --- 9. Panel update ---
    if(EnableChartPanel)
        UpdatePanel();
}

//+------------------------------------------------------------------+
//| SECTION 5 — REGIME STATE MACHINE                                |
//+------------------------------------------------------------------+

string RegimeToString(RegimeState r)
{
    switch(r)
    {
        case REGIME_NEUTRAL:              return "NEUTRAL";
        case REGIME_TREND_EXPANSION:      return "TREND_EXPANSION";
        case REGIME_TREND_DECELERATION:   return "TREND_DECELERATION";
        case REGIME_EXHAUSTION_WINDOW:    return "EXHAUSTION_WINDOW";
        case REGIME_ACTIVE_FADE:          return "ACTIVE_FADE";
        case REGIME_DISABLED:             return "DISABLED";
    }
    return "UNKNOWN";
}

void TransitionRegime(RegimeState newRegime)
{
    if(newRegime == g_currentRegime)
        return;
    
    g_previousRegime = g_currentRegime;
    g_currentRegime  = newRegime;
    
    // === REGIME TRANSITION LOG ===
    Print("========== REGIME TRANSITION ==========");
    Print("  Time:          ", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
    Print("  Previous:      ", RegimeToString(g_previousRegime));
    Print("  New:           ", RegimeToString(g_currentRegime));
    Print("  ImpulseSize:   $", DoubleToString(g_impulseSize, 2));
    Print("  v_fast:        ", DoubleToString(g_vFast, 6));
    Print("  peak_v_fast:   ", DoubleToString(g_peakVFast, 6));
    Print("  TrendPerm:     LONG=", longEntryAllowed, " SHORT=", shortEntryAllowed);
    Print("  ImpulseDir:    ", g_impulseDirection == BASKET_LONG ? "UP" : 
                               (g_impulseDirection == BASKET_SHORT ? "DOWN" : "NONE"));
    Print("=======================================");
    
    // State-entry initialization
    if(newRegime == REGIME_TREND_EXPANSION)
    {
        // Record expansion start
        g_expansionStartTime = TimeCurrent();
        g_peakVFast = 0.0;
        
        // Record anchor price at expansion start
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        g_impulseAnchorPrice = bid;
        
        // Determine impulse direction from trend permission
        if(longEntryAllowed)
            g_impulseDirection = BASKET_LONG;
        else if(shortEntryAllowed)
            g_impulseDirection = BASKET_SHORT;
    }
    else if(newRegime == REGIME_NEUTRAL)
    {
        g_impulseDirection = BASKET_NONE;
        g_impulseSize = 0.0;
        g_impulseAnchorPrice = 0.0;
        g_expansionStartTime = 0;
        g_peakVFast = 0.0;
        g_prevVSlow = 0.0;
        g_reAccelFlag = false;
    }
}

void UpdateRegimeStateMachine()
{
    // === DISABLED takes absolute precedence ===
    if(g_tradingDisabled)
    {
        TransitionRegime(REGIME_DISABLED);
        return;
    }
    
    // If currently DISABLED but trading re-enabled (new day), go NEUTRAL
    if(g_currentRegime == REGIME_DISABLED && !g_tradingDisabled)
    {
        TransitionRegime(REGIME_NEUTRAL);
        return;
    }
    
    // === ACTIVE_FADE: stays until basket closes ===
    if(g_currentRegime == REGIME_ACTIVE_FADE)
    {
        if(!BasketHasPositions())
        {
            TransitionRegime(REGIME_NEUTRAL);
        }
        return;
    }
    
    // === Update impulse size (continuously while tracking) ===
    if(g_impulseAnchorPrice > 0)
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        if(g_impulseDirection == BASKET_LONG)
            g_impulseSize = bid - g_impulseAnchorPrice;
        else if(g_impulseDirection == BASKET_SHORT)
            g_impulseSize = g_impulseAnchorPrice - bid;
        else
            g_impulseSize = MathAbs(bid - g_impulseAnchorPrice);
    }
    
    // === Track peak velocity during expansion/deceleration ===
    if(g_currentRegime == REGIME_TREND_EXPANSION || g_currentRegime == REGIME_TREND_DECELERATION)
    {
        if(g_vFast > g_peakVFast)
            g_peakVFast = g_vFast;
    }
    
    // === State transition logic ===
    switch(g_currentRegime)
    {
        case REGIME_NEUTRAL:
        {
            // NEUTRAL → TREND_EXPANSION: trend permission fires
            if(longEntryAllowed || shortEntryAllowed)
            {
                TransitionRegime(REGIME_TREND_EXPANSION);
            }
            break;
        }
        
        case REGIME_TREND_EXPANSION:
        {
            // Check if trend permission lost entirely
            if(!longEntryAllowed && !shortEntryAllowed)
            {
                // Permission dropped — check if velocity was decaying
                if(g_peakVFast > 0 && g_vFast < 0.70 * g_peakVFast)
                {
                    TransitionRegime(REGIME_TREND_DECELERATION);
                }
                else
                {
                    // Clean loss of permission without deceleration pattern
                    TransitionRegime(REGIME_NEUTRAL);
                }
                break;
            }
            
            // EXPANSION → DECELERATION: velocity weakening while still in trend
            if(g_peakVFast > 0 && g_vFast <= 0.70 * g_peakVFast)
            {
                TransitionRegime(REGIME_TREND_DECELERATION);
            }
            break;
        }
        
        case REGIME_TREND_DECELERATION:
        {
            // Re-acceleration check
            if(g_reAccelFlag)
            {
                if(EnableDebugPrints)
                    Print(">>> REGIME: RE-ACCELERATION detected in DECELERATION — back to EXPANSION");
                g_reAccelFlag = false;
                TransitionRegime(REGIME_TREND_EXPANSION);
                break;
            }
            
            // Check full velocity decay confirmed
            bool decayOK = VelocityDecayConfirmed();
            
            // Check displacement threshold
            bool displacementOK = (g_impulseSize >= MinImpulseDisplacement_USD);
            
            // Check veto clear (opposite trend permission not active)
            bool vetoOK = true;
            if(g_impulseDirection == BASKET_LONG)
            {
                // We want to SELL to fade. Blocked if longEntryAllowed.
                if(longEntryAllowed)
                    vetoOK = false;
            }
            else if(g_impulseDirection == BASKET_SHORT)
            {
                // We want to BUY to fade. Blocked if shortEntryAllowed.
                if(shortEntryAllowed)
                    vetoOK = false;
            }
            
            if(decayOK && displacementOK && vetoOK)
            {
                TransitionRegime(REGIME_EXHAUSTION_WINDOW);
            }
            // If trend permission re-fires in the original direction
            else if((g_impulseDirection == BASKET_LONG && longEntryAllowed) ||
                    (g_impulseDirection == BASKET_SHORT && shortEntryAllowed))
            {
                // Trend resumed
                TransitionRegime(REGIME_TREND_EXPANSION);
            }
            break;
        }
        
        case REGIME_EXHAUSTION_WINDOW:
        {
            // If veto re-activates, abort window
            bool vetoBlock = false;
            if(g_impulseDirection == BASKET_LONG && longEntryAllowed)
                vetoBlock = true;
            if(g_impulseDirection == BASKET_SHORT && shortEntryAllowed)
                vetoBlock = true;
            
            if(vetoBlock)
            {
                if(EnableDebugPrints)
                    Print(">>> REGIME: EXHAUSTION_WINDOW aborted — trend veto re-activated");
                TransitionRegime(REGIME_TREND_EXPANSION);
                break;
            }
            
            // Re-acceleration in exhaustion window → back to expansion
            if(g_reAccelFlag)
            {
                if(EnableDebugPrints)
                    Print(">>> REGIME: RE-ACCELERATION in EXHAUSTION_WINDOW — abort");
                g_reAccelFlag = false;
                TransitionRegime(REGIME_NEUTRAL);
                break;
            }
            
            // Entry taken transitions to ACTIVE_FADE (handled in TryFadeEntry())
            break;
        }
        
        default:
            break;
    }
}

//+------------------------------------------------------------------+
//| SECTION 6 — TREND PERMISSION VETO MODULE                       |
//|                                                                  |
//| Replicates FROZEN M1 trend permission from TrendPermissionEA     |
//| exactly: EMA200 High/Low regime, EMA 10/30 slopes + gap,         |
//| structural body clearance, ATR-normalized slope filter.           |
//+------------------------------------------------------------------+

void UpdateTrendPermissionVeto()
{
    longEntryAllowedPrev  = longEntryAllowed;
    shortEntryAllowedPrev = shortEntryAllowed;
    vetoFastSlopePrev     = vetoFastSlope;
    vetoGapPrev           = vetoGap;
    
    // --- Copy indicator buffers (M1, 3 bars) ---
    ArrayResize(vetoEma200High, 3);
    ArrayResize(vetoEma200Low, 3);
    ArrayResize(vetoEmaFast, 3);
    ArrayResize(vetoEmaSlow, 3);
    ArrayResize(vetoATR, 3);
    
    ArraySetAsSeries(vetoEma200High, true);
    ArraySetAsSeries(vetoEma200Low, true);
    ArraySetAsSeries(vetoEmaFast, true);
    ArraySetAsSeries(vetoEmaSlow, true);
    ArraySetAsSeries(vetoATR, true);
    
    if(CopyBuffer(hVetoEmaHigh, 0, 0, 3, vetoEma200High) < 3 ||
       CopyBuffer(hVetoEmaLow, 0, 0, 3, vetoEma200Low)   < 3 ||
       CopyBuffer(hVetoEmaFast, 0, 0, 3, vetoEmaFast)     < 3 ||
       CopyBuffer(hVetoEmaSlow, 0, 0, 3, vetoEmaSlow)     < 3 ||
       CopyBuffer(hVetoATR_M1, 0, 0, 3, vetoATR)          < 3)
        return;
    
    // --- Slopes ---
    vetoFastSlope = vetoEmaFast[1] - vetoEmaFast[2];
    vetoSlowSlope = vetoEmaSlow[1] - vetoEmaSlow[2];
    vetoFastD2    = vetoFastSlope - vetoFastSlopePrev;
    
    // --- Gap dynamics ---
    vetoGap      = vetoEmaFast[1] - vetoEmaSlow[1];
    vetoGapSlope = vetoGap - vetoGapPrev;
    
    // --- M1 completed bar data ---
    double completedClose = iClose(_Symbol, PERIOD_M1, 1);
    double completedOpen  = iOpen(_Symbol, PERIOD_M1, 1);
    
    // --- Regime ---
    bool isBullRegime = completedClose > vetoEma200High[1];
    bool isBearRegime = completedClose < vetoEma200Low[1];
    
    // --- Acceleration ---
    bool accelUp   = (vetoFastSlope > 0) && (vetoFastD2 > 0);
    bool accelDown = (vetoFastSlope < 0) && (vetoFastD2 < 0);
    
    // --- Gap ---
    bool gapBull     = vetoGap > 0;
    bool gapBear     = vetoGap < 0;
    bool gapWidening  = vetoGapSlope > 0;
    bool gapNarrowing = vetoGapSlope < 0;
    
    // --- Base conditions (v3.7 logic) ---
    bool longBase = isBullRegime && (vetoSlowSlope > 0) && (vetoFastSlope > 0) &&
                    accelUp && gapBull && gapWidening;
    
    bool shortBase = isBearRegime && (vetoSlowSlope < 0) && (vetoFastSlope < 0) &&
                     accelDown && gapBear && gapNarrowing;
    
    // --- Structural body clearance (v3.8) ---
    double bodyHigh   = MathMax(completedOpen, completedClose);
    double bodyLow    = MathMin(completedOpen, completedClose);
    double cloudTop   = MathMax(vetoEmaFast[1], vetoEmaSlow[1]);
    double cloudBottom = MathMin(vetoEmaFast[1], vetoEmaSlow[1]);
    
    bool longStructuralClear  = (bodyLow > cloudTop) && (bodyLow > vetoEma200High[1]);
    bool shortStructuralClear = (bodyHigh < cloudBottom) && (bodyHigh < vetoEma200Low[1]);
    
    // --- Trend force filter (v3.8 ATR-normalized slope) ---
    double currentATR = vetoATR[1];
    double normSlopeStrength = 0.0;
    if(currentATR > 0)
        normSlopeStrength = MathAbs(vetoSlowSlope) / currentATR;
    
    bool trendForceOK = (normSlopeStrength > TP_MIN_SLOPE);
    
    // --- Final gated permissions ---
    longEntryAllowed  = longBase && longStructuralClear && trendForceOK;
    shortEntryAllowed = shortBase && shortStructuralClear && trendForceOK;
    
    // --- Log permission transitions ---
    if(longEntryAllowed && !longEntryAllowedPrev && EnableDebugPrints)
        Print(">>> VETO MODULE: LONG permission START");
    if(!longEntryAllowed && longEntryAllowedPrev && EnableDebugPrints)
        Print(">>> VETO MODULE: LONG permission END");
    if(shortEntryAllowed && !shortEntryAllowedPrev && EnableDebugPrints)
        Print(">>> VETO MODULE: SHORT permission START");
    if(!shortEntryAllowed && shortEntryAllowedPrev && EnableDebugPrints)
        Print(">>> VETO MODULE: SHORT permission END");
}

//+------------------------------------------------------------------+
//| SECTION 7 — VELOCITY DECAY ENGINE (TICK BUFFER)                 |
//+------------------------------------------------------------------+

void UpdateTickBuffer()
{
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick))
        return;
    
    // Add tick to buffer
    int newSize = g_tickCount + 1;
    ArrayResize(g_tickBuffer, newSize, 200); // Reserve extra capacity
    g_tickBuffer[g_tickCount].price    = (tick.bid + tick.ask) / 2.0; // mid price
    g_tickBuffer[g_tickCount].time_msc = tick.time_msc;
    g_tickCount = newSize;
    
    // Prune ticks older than buffer window + margin
    long cutoffMs = tick.time_msc - ((long)TickBufferSeconds + 2) * 1000;
    int pruneFrom = 0;
    for(int i = 0; i < g_tickCount; i++)
    {
        if(g_tickBuffer[i].time_msc >= cutoffMs)
        {
            pruneFrom = i;
            break;
        }
        if(i == g_tickCount - 1)
            pruneFrom = g_tickCount - 1; // keep at least 1
    }
    
    if(pruneFrom > 0)
    {
        for(int i = pruneFrom; i < g_tickCount; i++)
            g_tickBuffer[i - pruneFrom] = g_tickBuffer[i];
        g_tickCount -= pruneFrom;
        ArrayResize(g_tickBuffer, g_tickCount);
    }
}

void ComputeVelocities()
{
    if(g_tickCount < 3)
    {
        g_vFast = 0.0;
        g_vSlow = 0.0;
        return;
    }
    
    long nowMs = g_tickBuffer[g_tickCount - 1].time_msc;
    double nowPrice = g_tickBuffer[g_tickCount - 1].price;
    
    // --- v_fast: velocity over last ~1.5 seconds ---
    double fastPrice = nowPrice;
    long   fastMs    = nowMs;
    long   fastCutoff = nowMs - 1500;
    for(int i = g_tickCount - 2; i >= 0; i--)
    {
        if(g_tickBuffer[i].time_msc <= fastCutoff)
        {
            fastPrice = g_tickBuffer[i].price;
            fastMs    = g_tickBuffer[i].time_msc;
            break;
        }
        fastPrice = g_tickBuffer[i].price;
        fastMs    = g_tickBuffer[i].time_msc;
    }
    
    double fastDt = (double)(nowMs - fastMs) / 1000.0; // seconds
    if(fastDt > 0.05)
        g_vFast = MathAbs(nowPrice - fastPrice) / fastDt;
    else
        g_vFast = 0.0;
    
    // --- v_slow: velocity over last ~TickBufferSeconds ---
    double slowPrice = nowPrice;
    long   slowMs    = nowMs;
    long   slowCutoff = nowMs - (long)TickBufferSeconds * 1000;
    for(int i = 0; i < g_tickCount; i++)
    {
        if(g_tickBuffer[i].time_msc >= slowCutoff)
        {
            slowPrice = g_tickBuffer[i].price;
            slowMs    = g_tickBuffer[i].time_msc;
            break;
        }
    }
    
    double slowDt = (double)(nowMs - slowMs) / 1000.0;
    if(slowDt > 0.5)
        g_vSlow = MathAbs(nowPrice - slowPrice) / slowDt;
    else
        g_vSlow = 0.0;
    
    // --- Track peak v_fast ---
    if(g_vFast > g_peakVFast)
        g_peakVFast = g_vFast;
    
    // --- Stall condition: v_fast extremely low ---
    double atrRef[1];
    if(CopyBuffer(hATR_M1, 0, 0, 1, atrRef) >= 1 && atrRef[0] > 0)
        g_stallCondition = (g_vFast < 0.01 * atrRef[0]); // Relative to ATR
    else
        g_stallCondition = (g_vFast < 0.001);
    
    // --- Re-acceleration flag ---
    g_reAccelFlag = false;
    if(g_peakVFast > 0 && g_vFast >= ReAccelerationRatio * g_peakVFast)
        g_reAccelFlag = true;
}

bool VelocityDecayConfirmed()
{
    // Rule 1: v_fast dropped to VFastDecayRatio of peak
    bool rule1 = (g_peakVFast > 0) && (g_vFast <= VFastDecayRatio * g_peakVFast);
    
    // Rule 2: v_slow decreasing (compare to previous snapshot)
    bool rule2 = (g_prevVSlow > 0) && (g_vSlow <= VSlowDecayRatio * g_prevVSlow);
    
    // Rule 3: Stall condition
    bool rule3 = g_stallCondition;
    
    // Store current v_slow for next comparison
    g_prevVSlow = g_vSlow;
    
    bool confirmed = rule1 && rule2 && rule3;
    
    if(confirmed && EnableDebugPrints)
    {
        Print(">>> VELOCITY DECAY CONFIRMED <<<");
        Print("  ImpulseSize:     $", DoubleToString(g_impulseSize, 2));
        Print("  v_fast:          ", DoubleToString(g_vFast, 6));
        Print("  v_slow:          ", DoubleToString(g_vSlow, 6));
        Print("  peak_v_fast:     ", DoubleToString(g_peakVFast, 6));
        Print("  Stall:           ", g_stallCondition);
        Print("  ReAccel:         ", g_reAccelFlag);
    }
    
    return confirmed;
}

//+------------------------------------------------------------------+
//| SECTION 8 — IMPULSE DETECTION (M5)                              |
//+------------------------------------------------------------------+

void UpdateImpulseDetection()
{
    // Only detect impulse when in NEUTRAL or TREND_EXPANSION
    // (don't overwrite during deceleration/exhaustion/fade)
    if(g_currentRegime != REGIME_NEUTRAL && g_currentRegime != REGIME_TREND_EXPANSION)
        return;
    
    // Check M5 bar count
    int barsAvailable = Bars(_Symbol, PERIOD_M5);
    if(barsAvailable < ImpulseLookbackBars + 2)
        return;
    
    // Measure net displacement over last ImpulseLookbackBars M5 bars
    double startClose = iClose(_Symbol, PERIOD_M5, ImpulseLookbackBars);
    double endClose   = iClose(_Symbol, PERIOD_M5, 1);
    
    double netDisplacement = endClose - startClose;  // Positive = up, Negative = down
    
    // Measure total range (sum of individual bar ranges)
    double totalRange = 0.0;
    for(int i = 1; i <= ImpulseLookbackBars; i++)
    {
        totalRange += iHigh(_Symbol, PERIOD_M5, i) - iLow(_Symbol, PERIOD_M5, i);
    }
    
    // Body ratio check: net displacement vs total range
    double absDisp = MathAbs(netDisplacement);
    if(totalRange > 0 && (absDisp / totalRange) >= ImpulseBodyRatio)
    {
        // Valid impulse structure
        double displacementUSD = absDisp;
        
        if(displacementUSD >= MinImpulseDisplacement_USD)
        {
            if(EnableDebugPrints)
                Print(">>> M5 IMPULSE DETECTED | Direction=", (netDisplacement > 0 ? "UP" : "DOWN"),
                      " | Displacement=$", DoubleToString(displacementUSD, 2),
                      " | Ratio=", DoubleToString(absDisp / totalRange, 3));
        }
    }
}

//+------------------------------------------------------------------+
//| SECTION 9 — EXECUTION ENGINE                                    |
//+------------------------------------------------------------------+

double GetDynamicGridSpacing()
{
    double atrBuf[1];
    double spacing = MinGridSpacing_Pips * _Point * 10; // Convert pips to price
    
    // For gold, 1 pip = $0.10 typically, but use point value
    // Gold typically: 1 point = 0.01, so 12 pips = 120 points = $1.20
    // Actually for XAUUSD, price is in dollars, so a "pip" in gold = $0.10
    // And _Point for gold 2-decimal = 0.01
    // Let's use dollar-based spacing directly
    spacing = MinGridSpacing_Pips * 0.10; // 12 pips × $0.10/pip = $1.20
    
    if(CopyBuffer(hATR_M1, 0, 0, 1, atrBuf) >= 1)
    {
        double atrSpacing = GridATR_Multiplier * atrBuf[0];
        spacing = MathMax(spacing, atrSpacing);
    }
    
    return spacing;
}

void TryFadeEntry()
{
    // Only enter from EXHAUSTION_WINDOW
    if(g_currentRegime != REGIME_EXHAUSTION_WINDOW)
        return;
    
    // Already have a basket
    if(BasketHasPositions())
        return;
    
    // Determine fade direction (opposite of impulse)
    int fadeDir = BASKET_NONE;
    if(g_impulseDirection == BASKET_LONG)
        fadeDir = BASKET_SHORT;   // Fade the up-impulse by selling
    else if(g_impulseDirection == BASKET_SHORT)
        fadeDir = BASKET_LONG;    // Fade the down-impulse by buying
    
    if(fadeDir == BASKET_NONE)
        return;
    
    // === VETO CHECK (Section 4) ===
    if(fadeDir == BASKET_LONG && shortEntryAllowed)
    {
        // Log veto once per bar
        datetime bar = iTime(_Symbol, PERIOD_M1, 0);
        if(bar != g_vetoLogBar)
        {
            g_vetoLogBar = bar;
            Print(">>> VETO: Cannot BUY — shortEntryAllowed active");
        }
        return;
    }
    if(fadeDir == BASKET_SHORT && longEntryAllowed)
    {
        datetime bar = iTime(_Symbol, PERIOD_M1, 0);
        if(bar != g_vetoLogBar)
        {
            g_vetoLogBar = bar;
            Print(">>> VETO: Cannot SELL — longEntryAllowed active");
        }
        return;
    }
    
    // === SPREAD CHECK ===
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadPts = (ask - bid) / _Point;
    
    if(spreadPts > MaxSpreadPoints)
    {
        if(EnableDebugPrints)
            Print(">>> ENTRY BLOCKED: Spread=", DoubleToString(spreadPts, 1), " > Max=", DoubleToString(MaxSpreadPoints, 1));
        return;
    }
    
    // === EXECUTE LEVEL 1 ENTRY ===
    double lot = g_lotLadder[0];
    if(lot > MaxTotalLots)
        lot = MaxTotalLots;
    
    double gridSpacing = GetDynamicGridSpacing();
    bool success = false;
    double entryPrice = 0.0;
    
    if(fadeDir == BASKET_LONG)
    {
        success = trade.Buy(lot, _Symbol, ask, 0, 0, "VC_v0.1_FADE_BUY_L1");
        entryPrice = ask;
    }
    else if(fadeDir == BASKET_SHORT)
    {
        success = trade.Sell(lot, _Symbol, bid, 0, 0, "VC_v0.1_FADE_SELL_L1");
        entryPrice = bid;
    }
    
    if(success)
    {
        g_currentLevel = 1;
        g_fadeDirection = fadeDir;
        g_basketEntryAnchor = entryPrice;
        g_lastGridAnchor = entryPrice;
        g_basketEntryTime = TimeCurrent();
        g_totalLotsOpen = lot;
        
        Print(">>> ENTRY: ", (fadeDir == BASKET_LONG ? "BUY" : "SELL"), " Level1");
        Print("    ImpulseSize:  $", DoubleToString(g_impulseSize, 2));
        Print("    GridSpacing:  $", DoubleToString(gridSpacing, 2));
        Print("    ATR(M1):      $", DoubleToString(GetCurrentATR_M1(), 2));
        Print("    Lot:          ", DoubleToString(lot, 2));
        Print("    EntryPrice:   ", DoubleToString(entryPrice, 2));
        
        TransitionRegime(REGIME_ACTIVE_FADE);
    }
    else
    {
        Print("!!! ENTRY FAILED | Dir=", fadeDir, " | Error=", GetLastError());
    }
}

void ManageGridAdds()
{
    if(g_currentRegime != REGIME_ACTIVE_FADE)
        return;
    
    if(!BasketHasPositions())
        return;
    
    if(g_currentLevel >= MaxPositions)
        return;
    
    if(g_lastGridAnchor == 0.0)
        return;
    
    // Check lot capacity
    double nextLot = g_lotLadder[g_currentLevel]; // currentLevel is 1-indexed for count, 0-indexed for ladder
    if(g_totalLotsOpen + nextLot > MaxTotalLots)
    {
        if(EnableDebugPrints)
            Print(">>> GRID ADD BLOCKED: TotalLots=", DoubleToString(g_totalLotsOpen, 2),
                  " + ", DoubleToString(nextLot, 2), " > Max=", DoubleToString(MaxTotalLots, 2));
        return;
    }
    
    // Spread check
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadPts = (ask - bid) / _Point;
    if(spreadPts > MaxSpreadPoints)
        return;
    
    double gridSpacing = GetDynamicGridSpacing();
    
    // Grid add logic: price has moved AGAINST the fade direction by gridSpacing
    bool addCondition = false;
    
    if(g_fadeDirection == BASKET_LONG)
    {
        // We are long, price drops further — add on dip
        if(ask <= g_lastGridAnchor - gridSpacing)
            addCondition = true;
    }
    else if(g_fadeDirection == BASKET_SHORT)
    {
        // We are short, price rises further — add on rally
        if(bid >= g_lastGridAnchor + gridSpacing)
            addCondition = true;
    }
    
    if(!addCondition)
        return;
    
    // === EXECUTE GRID ADD ===
    bool success = false;
    double entryPrice = 0.0;
    
    if(g_fadeDirection == BASKET_LONG)
    {
        success = trade.Buy(nextLot, _Symbol, ask, 0, 0, 
                           "VC_v0.1_FADE_BUY_L" + IntegerToString(g_currentLevel + 1));
        entryPrice = ask;
    }
    else if(g_fadeDirection == BASKET_SHORT)
    {
        success = trade.Sell(nextLot, _Symbol, bid, 0, 0,
                            "VC_v0.1_FADE_SELL_L" + IntegerToString(g_currentLevel + 1));
        entryPrice = bid;
    }
    
    if(success)
    {
        double prevAnchor = g_lastGridAnchor;
        g_lastGridAnchor = entryPrice;
        g_currentLevel++;
        g_totalLotsOpen += nextLot;
        
        Print(">>> ADD: Level", g_currentLevel);
        Print("    CurrentLots:  ", DoubleToString(g_totalLotsOpen, 2));
        Print("    FloatingDD:   $", DoubleToString(g_basketFloatingPL, 2));
        Print("    PrevAnchor:   ", DoubleToString(prevAnchor, 2));
        Print("    NewAnchor:    ", DoubleToString(entryPrice, 2));
        Print("    GridSpacing:  $", DoubleToString(gridSpacing, 2));
    }
}

//+------------------------------------------------------------------+
//| SECTION 10 — POSITION & BASKET MANAGEMENT                      |
//+------------------------------------------------------------------+

bool BasketHasPositions()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == CompressorMagic)
                return true;
        }
    }
    return false;
}

int GetBasketDirection()
{
    bool hasLong = false, hasShort = false;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == CompressorMagic)
            {
                ENUM_POSITION_TYPE t = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                if(t == POSITION_TYPE_BUY)  hasLong = true;
                if(t == POSITION_TYPE_SELL) hasShort = true;
            }
        }
    }
    if(hasLong && !hasShort) return BASKET_LONG;
    if(hasShort && !hasLong) return BASKET_SHORT;
    return BASKET_NONE;
}

double CalculateBasketFloat()
{
    double total = 0.0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == CompressorMagic)
                total += PositionGetDouble(POSITION_PROFIT);
        }
    }
    return total;
}

int CountBasketPositions()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == CompressorMagic)
                count++;
        }
    }
    return count;
}

void CloseAllBasketPositions(string reason)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == CompressorMagic)
            {
                double profit = PositionGetDouble(POSITION_PROFIT);
                if(trade.PositionClose(ticket))
                {
                    Print(">>> VC CLOSED POSITION | Reason: ", reason, 
                          " | Profit: $", DoubleToString(profit, 2));
                }
            }
        }
    }
}

void ResetBasketState()
{
    g_currentLevel = 0;
    g_fadeDirection = BASKET_NONE;
    g_basketEntryAnchor = 0.0;
    g_lastGridAnchor = 0.0;
    g_basketFloatingPL = 0.0;
    g_basketEntryTime = 0;
    g_totalLotsOpen = 0.0;
}

double GetCurrentATR_M1()
{
    double buf[1];
    if(CopyBuffer(hATR_M1, 0, 0, 1, buf) >= 1)
        return buf[0];
    return 0.0;
}

//+------------------------------------------------------------------+
//| SECTION 11 — SURVIVAL CONTROLS                                  |
//+------------------------------------------------------------------+

void CheckSurvivalControls()
{
    if(!BasketHasPositions())
        return;
    
    // --- 1. Hard Basket Stop (% of equity) ---
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double stopUSD = equity * BasketStopPct / 100.0;
    
    if(g_basketFloatingPL <= -stopUSD)
    {
        Print("!!! SURVIVAL: HARD BASKET STOP HIT !!!");
        Print("    FloatingPL: $", DoubleToString(g_basketFloatingPL, 2));
        Print("    StopLevel:  -$", DoubleToString(stopUSD, 2), " (", DoubleToString(BasketStopPct, 1), "% equity)");
        LogBasketClose("RiskCap");
        CloseAllBasketPositions("Survival_HardStop");
        ResetBasketState();
        return;
    }
    
    // --- 2. Structural Invalidation (adverse move > mult × impulse) ---
    if(g_impulseSize > 0 && g_basketEntryAnchor > 0)
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double adverseMove = 0.0;
        
        if(g_fadeDirection == BASKET_LONG)
            adverseMove = g_basketEntryAnchor - bid; // Price moved against our long
        else if(g_fadeDirection == BASKET_SHORT)
            adverseMove = ask - g_basketEntryAnchor; // Price moved against our short
        
        double invalidationLevel = StructuralInvalid_Mult * g_impulseSize;
        
        if(adverseMove > invalidationLevel)
        {
            Print("!!! SURVIVAL: STRUCTURAL INVALIDATION !!!");
            Print("    AdverseMove: $", DoubleToString(adverseMove, 2));
            Print("    Threshold:   $", DoubleToString(invalidationLevel, 2), 
                  " (", DoubleToString(StructuralInvalid_Mult, 1), " × $", DoubleToString(g_impulseSize, 2), ")");
            LogBasketClose("StructuralInvalidation");
            CloseAllBasketPositions("Survival_StructuralInvalidation");
            ResetBasketState();
            return;
        }
    }
    
    // --- 3. Time Stop ---
    if(g_basketEntryTime > 0)
    {
        int elapsedMin = (int)((TimeCurrent() - g_basketEntryTime) / 60);
        if(elapsedMin >= TimeStopMinutes)
        {
            Print("!!! SURVIVAL: TIME STOP !!!");
            Print("    Elapsed: ", elapsedMin, " min | Max: ", TimeStopMinutes, " min");
            Print("    FloatingPL: $", DoubleToString(g_basketFloatingPL, 2));
            LogBasketClose("TimeStop");
            CloseAllBasketPositions("Survival_TimeStop");
            ResetBasketState();
            return;
        }
    }
    
    // --- 4. Acceleration Resumed (re-acceleration while in fade) ---
    if(g_currentRegime == REGIME_ACTIVE_FADE && g_reAccelFlag)
    {
        Print("!!! SURVIVAL: ACCELERATION RESUMED !!!");
        Print("    v_fast: ", DoubleToString(g_vFast, 6), " >= ", DoubleToString(ReAccelerationRatio, 2),
              " × peak ", DoubleToString(g_peakVFast, 6));
        Print("    FloatingPL: $", DoubleToString(g_basketFloatingPL, 2));
        LogBasketClose("AccelerationResumed");
        CloseAllBasketPositions("Survival_AccelResumed");
        ResetBasketState();
        return;
    }
    
    // --- 5. Profit Target (simple basket profit) ---
    // Use a modest target: positive float > some threshold
    // For diagnostic build, use a simple dollar-based target proportional to grid level
    double profitTarget = 2.0 * (double)g_currentLevel; // $2 per level
    if(g_basketFloatingPL >= profitTarget && profitTarget > 0)
    {
        Print(">>> BASKET PROFIT TARGET HIT <<<");
        Print("    FloatingPL: $", DoubleToString(g_basketFloatingPL, 2));
        Print("    Target:     $", DoubleToString(profitTarget, 2));
        Print("    Levels:     ", g_currentLevel);
        LogBasketClose("ProfitTarget");
        CloseAllBasketPositions("ProfitTarget");
        ResetBasketState();
        return;
    }
}

//+------------------------------------------------------------------+
//| SECTION 12 — LOGGING                                            |
//+------------------------------------------------------------------+

void LogBasketClose(string reason)
{
    Print("========== BASKET CLOSE ==========");
    Print("  Reason:       ", reason);
    Print("  FloatingPL:   $", DoubleToString(g_basketFloatingPL, 2));
    Print("  Levels:       ", g_currentLevel);
    Print("  TotalLots:    ", DoubleToString(g_totalLotsOpen, 2));
    Print("  Direction:    ", g_fadeDirection == BASKET_LONG ? "LONG" : 
                              (g_fadeDirection == BASKET_SHORT ? "SHORT" : "NONE"));
    Print("  ImpulseSize:  $", DoubleToString(g_impulseSize, 2));
    
    if(g_basketEntryTime > 0)
    {
        int elapsed = (int)((TimeCurrent() - g_basketEntryTime) / 60);
        Print("  Duration:     ", elapsed, " min");
    }
    
    Print("  TrendVeto:    LONG=", longEntryAllowed, " SHORT=", shortEntryAllowed);
    Print("  v_fast:       ", DoubleToString(g_vFast, 6));
    Print("  peak_v_fast:  ", DoubleToString(g_peakVFast, 6));
    Print("==================================");
}

//+------------------------------------------------------------------+
//| SECTION 13 — DAILY RISK                                         |
//+------------------------------------------------------------------+

void InitializeDailyState()
{
    g_dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    g_dailyRealizedPL  = 0.0;
    g_dailyLossHit     = false;
    g_tradingDisabled   = false;
    g_disableReason     = "";
    g_currentNYDate     = GetNewYorkDate();
}

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

void CheckDayReset()
{
    datetime nyDate = GetNewYorkDate();
    if(nyDate != g_currentNYDate)
    {
        g_currentNYDate = nyDate;
        g_dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        g_dailyRealizedPL = 0.0;
        g_dailyLossHit = false;
        g_tradingDisabled = false;
        g_disableReason = "";
        
        // Reset regime
        TransitionRegime(REGIME_NEUTRAL);
        
        Print("==============================================");
        Print(">>> VC NEW NY DAY – Limits reset");
        Print("    NY Date: ", TimeToString(nyDate, TIME_DATE));
        Print("    Equity:  $", DoubleToString(g_dailyStartEquity, 2));
        Print("==============================================");
    }
}

void CheckDailyRisk()
{
    // Daily loss cap
    if(g_dailyRealizedPL <= -DailyLossCap_USD)
    {
        if(!g_dailyLossHit)
        {
            g_dailyLossHit = true;
            g_tradingDisabled = true;
            g_disableReason = "DAILY LOSS CAP";
            
            Print("!!! VC DAILY LOSS CAP HIT !!!");
            Print("    Realized P&L: $", DoubleToString(g_dailyRealizedPL, 2));
            
            if(BasketHasPositions())
            {
                LogBasketClose("DailyLossCap");
                CloseAllBasketPositions("DailyLossCap");
                ResetBasketState();
            }
        }
    }
    
    // Daily profit target
    if(g_dailyRealizedPL >= DailyProfitTarget_USD)
    {
        if(!g_tradingDisabled || g_disableReason != "DAILY TARGET")
        {
            g_tradingDisabled = true;
            g_disableReason = "DAILY TARGET";
            
            Print(">>> VC DAILY PROFIT TARGET REACHED <<<");
            Print("    Realized P&L: $", DoubleToString(g_dailyRealizedPL, 2));
            
            if(BasketHasPositions())
            {
                LogBasketClose("DailyProfitTarget");
                CloseAllBasketPositions("DailyProfitTarget");
                ResetBasketState();
            }
        }
    }
}

//+------------------------------------------------------------------+
//| SECTION 14 — OnTradeTransaction (Realized P&L Tracking)         |
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
                    
                    if(magic == CompressorMagic)
                    {
                        g_dailyRealizedPL += profit;
                        if(EnableDebugPrints)
                            Print(">>> VC DEAL CLOSED | Profit: $", DoubleToString(profit, 2),
                                  " | Daily Realized: $", DoubleToString(g_dailyRealizedPL, 2));
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| SECTION 15 — DEBUG VISUAL OVERLAY PANEL                          |
//+------------------------------------------------------------------+

#define VC_PREFIX  "VC_"
#define VC_PANEL_X 10
#define VC_PANEL_Y 25
#define VC_PANEL_W 340
#define VC_FONT    "Segoe UI"
#define VC_FONT_B  "Segoe UI Semibold"
#define VC_FONT_SZ 9

#define VC_CLR_HEADER   C'40,10,10'
#define VC_CLR_SECTION  C'55,25,25'
#define VC_CLR_CONTENT  C'20,12,12'
#define VC_CLR_SEP      C'80,40,40'
#define VC_CLR_LABEL    C'160,140,140'
#define VC_CLR_VALUE    C'230,220,210'

void CreatePanel()
{
    ObjectsDeleteAll(0, VC_PREFIX);
    
    int y = VC_PANEL_Y;
    int rh = 22;   // row height
    int pad = 12;
    int valX = VC_PANEL_X + 130;
    
    // --- Header ---
    PanelBox(VC_PREFIX + "hdr", VC_PANEL_X, y, VC_PANEL_W, 50, VC_CLR_HEADER);
    PanelLabel(VC_PREFIX + "title", VC_PANEL_X + pad, y + 6, "VOL COMPRESSOR", clrWhite, 14, "Arial Black");
    PanelLabel(VC_PREFIX + "ver", VC_PANEL_X + 250, y + 10, "v0.1 DIAG", C'255,120,80', 10, VC_FONT_B);
    PanelLabel(VC_PREFIX + "time", VC_PANEL_X + pad, y + 30, "", C'120,100,100', 8, VC_FONT);
    y += 55;
    
    // --- Regime Section ---
    PanelBox(VC_PREFIX + "regSec", VC_PANEL_X, y, VC_PANEL_W, 24, VC_CLR_SECTION);
    PanelLabel(VC_PREFIX + "regSecT", VC_PANEL_X + pad, y + 4, "◈ REGIME STATE MACHINE", clrWhite, 10, VC_FONT_B);
    y += 28;
    
    PanelBox(VC_PREFIX + "regBG", VC_PANEL_X, y, VC_PANEL_W, rh * 5 + 10, VC_CLR_CONTENT);
    int cy = y + 6;
    
    PanelLabel(VC_PREFIX + "regL", VC_PANEL_X + pad, cy, "Regime:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "regV", valX, cy, "", clrLime, 10, VC_FONT_B);
    cy += rh;
    
    PanelLabel(VC_PREFIX + "impL", VC_PANEL_X + pad, cy, "Impulse:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "impV", valX, cy, "", VC_CLR_VALUE, VC_FONT_SZ, VC_FONT_B);
    cy += rh;
    
    PanelLabel(VC_PREFIX + "vfL", VC_PANEL_X + pad, cy, "v_fast:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "vfV", valX, cy, "", VC_CLR_VALUE, VC_FONT_SZ, VC_FONT_B);
    cy += rh;
    
    PanelLabel(VC_PREFIX + "pvfL", VC_PANEL_X + pad, cy, "peak_v_fast:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "pvfV", valX, cy, "", VC_CLR_VALUE, VC_FONT_SZ, VC_FONT_B);
    cy += rh;
    
    PanelLabel(VC_PREFIX + "vetoL", VC_PANEL_X + pad, cy, "TrendVeto:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "vetoV", valX, cy, "", VC_CLR_VALUE, VC_FONT_SZ, VC_FONT_B);
    
    y += rh * 5 + 14;
    
    // --- Basket Section ---
    PanelBox(VC_PREFIX + "bskSec", VC_PANEL_X, y, VC_PANEL_W, 24, VC_CLR_SECTION);
    PanelLabel(VC_PREFIX + "bskSecT", VC_PANEL_X + pad, y + 4, "◈ BASKET STATUS", clrWhite, 10, VC_FONT_B);
    y += 28;
    
    PanelBox(VC_PREFIX + "bskBG", VC_PANEL_X, y, VC_PANEL_W, rh * 5 + 10, VC_CLR_CONTENT);
    cy = y + 6;
    
    PanelLabel(VC_PREFIX + "dirL", VC_PANEL_X + pad, cy, "Direction:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "dirV", valX, cy, "", VC_CLR_VALUE, VC_FONT_SZ, VC_FONT_B);
    cy += rh;
    
    PanelLabel(VC_PREFIX + "lvlL", VC_PANEL_X + pad, cy, "Levels:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "lvlV", valX, cy, "", VC_CLR_VALUE, VC_FONT_SZ, VC_FONT_B);
    cy += rh;
    
    PanelLabel(VC_PREFIX + "lotL", VC_PANEL_X + pad, cy, "TotalLots:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "lotV", valX, cy, "", VC_CLR_VALUE, VC_FONT_SZ, VC_FONT_B);
    cy += rh;
    
    PanelLabel(VC_PREFIX + "fltL", VC_PANEL_X + pad, cy, "FloatingPL:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "fltV", valX, cy, "", VC_CLR_VALUE, VC_FONT_SZ, VC_FONT_B);
    cy += rh;
    
    PanelLabel(VC_PREFIX + "dayL", VC_PANEL_X + pad, cy, "Daily Realized:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "dayV", valX, cy, "", VC_CLR_VALUE, VC_FONT_SZ, VC_FONT_B);
    
    ChartRedraw(0);
}

void UpdatePanel()
{
    // --- Time ---
    ObjectSetString(0, VC_PREFIX + "time", OBJPROP_TEXT, 
        TimeToString(GetNewYorkTime(), TIME_DATE|TIME_MINUTES) + " NY | " + _Symbol + " | Magic:" + IntegerToString(CompressorMagic));
    
    // --- Regime ---
    string regText = RegimeToString(g_currentRegime);
    color regClr = clrGray;
    switch(g_currentRegime)
    {
        case REGIME_NEUTRAL:              regClr = clrGray;    break;
        case REGIME_TREND_EXPANSION:      regClr = C'100,200,255'; break;
        case REGIME_TREND_DECELERATION:   regClr = clrOrange;  break;
        case REGIME_EXHAUSTION_WINDOW:    regClr = clrYellow;  break;
        case REGIME_ACTIVE_FADE:          regClr = clrLime;    break;
        case REGIME_DISABLED:             regClr = clrRed;     break;
    }
    ObjectSetString(0, VC_PREFIX + "regV", OBJPROP_TEXT, regText);
    ObjectSetInteger(0, VC_PREFIX + "regV", OBJPROP_COLOR, regClr);
    
    // --- Impulse ---
    string impDir = g_impulseDirection == BASKET_LONG ? "UP" : (g_impulseDirection == BASKET_SHORT ? "DOWN" : "---");
    ObjectSetString(0, VC_PREFIX + "impV", OBJPROP_TEXT,
        impDir + " $" + DoubleToString(g_impulseSize, 2));
    ObjectSetInteger(0, VC_PREFIX + "impV", OBJPROP_COLOR, 
        g_impulseSize >= MinImpulseDisplacement_USD ? clrYellow : VC_CLR_VALUE);
    
    // --- Velocities ---
    ObjectSetString(0, VC_PREFIX + "vfV", OBJPROP_TEXT, DoubleToString(g_vFast, 4));
    ObjectSetInteger(0, VC_PREFIX + "vfV", OBJPROP_COLOR,
        (g_peakVFast > 0 && g_vFast <= VFastDecayRatio * g_peakVFast) ? clrOrange : clrLime);
    
    ObjectSetString(0, VC_PREFIX + "pvfV", OBJPROP_TEXT, DoubleToString(g_peakVFast, 4));
    
    // --- Veto ---
    string vetoText = "";
    color vetoClr = clrGray;
    if(longEntryAllowed && shortEntryAllowed)
    {
        vetoText = "BOTH (error?)";
        vetoClr = clrRed;
    }
    else if(longEntryAllowed)
    {
        vetoText = "LONG ACTIVE (blocks SELL)";
        vetoClr = clrOrange;
    }
    else if(shortEntryAllowed)
    {
        vetoText = "SHORT ACTIVE (blocks BUY)";
        vetoClr = clrOrange;
    }
    else
    {
        vetoText = "CLEAR";
        vetoClr = clrLime;
    }
    ObjectSetString(0, VC_PREFIX + "vetoV", OBJPROP_TEXT, vetoText);
    ObjectSetInteger(0, VC_PREFIX + "vetoV", OBJPROP_COLOR, vetoClr);
    
    // --- Basket ---
    bool hasPos = BasketHasPositions();
    
    string dirText = "○ NO BASKET";
    color dirClr = clrGray;
    if(g_fadeDirection == BASKET_LONG)  { dirText = "▲ LONG FADE";  dirClr = clrLime; }
    if(g_fadeDirection == BASKET_SHORT) { dirText = "▼ SHORT FADE"; dirClr = clrRed;  }
    if(!hasPos) { dirText = "○ NO BASKET"; dirClr = clrGray; }
    ObjectSetString(0, VC_PREFIX + "dirV", OBJPROP_TEXT, dirText);
    ObjectSetInteger(0, VC_PREFIX + "dirV", OBJPROP_COLOR, dirClr);
    
    ObjectSetString(0, VC_PREFIX + "lvlV", OBJPROP_TEXT,
        hasPos ? IntegerToString(g_currentLevel) + " / " + IntegerToString(MaxPositions) : "---");
    
    ObjectSetString(0, VC_PREFIX + "lotV", OBJPROP_TEXT,
        hasPos ? DoubleToString(g_totalLotsOpen, 2) + " / " + DoubleToString(MaxTotalLots, 2) : "---");
    
    string fltText = hasPos ? "$" + DoubleToString(g_basketFloatingPL, 2) : "---";
    color fltClr = hasPos ? (g_basketFloatingPL >= 0 ? clrLime : clrRed) : clrGray;
    ObjectSetString(0, VC_PREFIX + "fltV", OBJPROP_TEXT, fltText);
    ObjectSetInteger(0, VC_PREFIX + "fltV", OBJPROP_COLOR, fltClr);
    
    string dayText = "$" + DoubleToString(g_dailyRealizedPL, 2);
    color dayClr = g_dailyRealizedPL >= 0 ? clrLime : clrRed;
    if(g_tradingDisabled) { dayText += " [" + g_disableReason + "]"; dayClr = clrOrange; }
    ObjectSetString(0, VC_PREFIX + "dayV", OBJPROP_TEXT, dayText);
    ObjectSetInteger(0, VC_PREFIX + "dayV", OBJPROP_COLOR, dayClr);
    
    ChartRedraw(0);
}

void PanelBox(string name, int x, int y, int w, int h, color bgClr)
{
    if(ObjectFind(0, name) < 0)
        ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
    ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
    ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgClr);
    ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, name, OBJPROP_COLOR, bgClr);
    ObjectSetInteger(0, name, OBJPROP_BACK, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void PanelLabel(string name, int x, int y, string text, color clr, int fontSize, string font)
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
    ObjectsDeleteAll(0, VC_PREFIX);
}

//+------------------------------------------------------------------+
//| END OF FILE                                                       |
//+------------------------------------------------------------------+
