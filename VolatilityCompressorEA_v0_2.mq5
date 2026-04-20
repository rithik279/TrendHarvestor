//+------------------------------------------------------------------+
//|                                    VolatilityCompressorEA_v0_2.mq5 |
//|                     Intraday Volatility Compression Harvester      |
//|                            PRODUCTION BUILD – v0.2                 |
//+------------------------------------------------------------------+
#property copyright "VolatilityCompressor"
#property version   "0.2"
#property description "v0.2 – Physics-Driven Impulse Detection + Velocity Decay Fade"
#property description "Layer 1: Impulse Physics | Layer 2: Velocity Decay | Layer 3: Trend Veto"
#property description "Layer 4: Fade Execution  | Layer 5: Survival Controls"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| SECTION 0 — ENUMS & COMPILE-TIME CONSTANTS                      |
//+------------------------------------------------------------------+

enum RegimeState
{
    REGIME_NEUTRAL,                // No impulse detected
    REGIME_TREND_EXPANSION,        // Physics-detected impulse underway
    REGIME_TREND_DECELERATION,     // Velocity decaying from peak
    REGIME_EXHAUSTION_WINDOW,      // Decay confirmed — ready to fade
    REGIME_ACTIVE_FADE,            // Basket open against impulse
    REGIME_DISABLED                // Daily loss / manual disable
};

#define BASKET_NONE   0
#define BASKET_LONG   1
#define BASKET_SHORT -1

// Trend permission EMA parameters (FROZEN — must replicate TrendPermissionEA)
#define TP_EMA_TREND_LEN   200
#define TP_FAST_LEN        10
#define TP_SLOW_LEN        30
#define TP_ATR_PERIOD      14
#define TP_MIN_SLOPE       0.12

#define MAX_GRID_LEVELS    50
#define MAX_VEL_BUFFER     600   // Velocity history buffer hard ceiling

//+------------------------------------------------------------------+
//| SECTION 1 — INPUT PARAMETERS                                    |
//+------------------------------------------------------------------+

input group "00. Global Risk"
input double DailyLossCap_USD         = 100.0;   // Daily loss cap ($)
input double DailyProfitTarget_USD    = 200.0;   // Daily realized profit target ($)
input int    BrokerToNYOffsetHours    = -7;       // Broker → New York offset (hours)
input int    CompressorMagic          = 777888;   // MagicNumber (must differ from TrendPermission)

input group "01. Execution"
input double BaseLotSize              = 0.01;     // Starting lot size (Level 1)
input double LotIncrement             = 0.01;     // Lot increase per level
input double MaxTotalLots             = 1.6;      // Maximum total lots across all levels
input int    MaxPositions             = 10;       // Maximum grid positions
input double MaxSpreadPoints          = 50.0;     // Max spread (points)
input int    SlippagePoints           = 15;       // Max slippage (points)

input group "02. Impulse Physics Engine (Layer 1)"
input double MinImpulseDisplacement_USD = 5.0;    // Minimum M5 net displacement ($) for impulse
input int    ImpulseLookbackBars      = 6;         // M5 bars to measure impulse
input double ImpulseBodyRatio         = 0.55;      // Min displacement/range efficiency
input double ExpansionFactor          = 1.2;       // ATR(M1) must exceed RollingATRMean × this
input int    VelocityMedianSeconds    = 60;        // Rolling window for v_fast median baseline (sec)
input int    ATRRollingBars           = 30;        // M1 bars for rolling ATR mean
input int    MaxExpansionMinutes      = 15;        // Max time in expansion/decel before NEUTRAL fallback
// --- v0.2.1 PATCH 3 ---
input double VelocityImpulseMultiplier  = 1.25;   // v_fast must exceed baseline × this multiplier
// --- v0.2.2 Structural Exhaustion ---
input double ExtensionMaturityMult      = 1.30;   // g_impulseSize must be >= this × g_initialImpulseSize
input double HighFailureMarginRatio     = 0.10;   // Current high/low must miss swing peak by ratio × initialSize
input int    MomentumStallBars          = 2;      // Consecutive closes not exceeding prior swing high/low

input group "03. Velocity Decay (Layer 2)"
input int    TickBufferSeconds        = 6;         // Tick buffer window (seconds)
input double VFastDecayRatio          = 0.45;      // v_fast <= ratio × peak_v_fast → decay
input double VSlowDecayRatio          = 0.75;      // v_slow <= ratio × prev_v_slow → decay
input double ReAccelerationRatio      = 0.90;      // v_fast >= ratio × peak → re-acceleration

input group "04. Grid Spacing (Layer 4)"
input double MinGridSpacing_Pips      = 12.0;      // Minimum grid spacing (gold pips → × $0.10)
input double GridATR_Multiplier       = 0.80;      // Spacing = max(..., mult × ATR(M1), ...)
input double ImpulseSpacingFraction   = 0.15;      // Spacing also considers impulse × this fraction

input group "05. Survival Controls (Layer 5)"
input double BasketStopPct            = 2.0;       // Hard basket stop (% of equity)
input double StructuralInvalid_Mult   = 1.8;       // Adverse move > mult × impulse → exit
input int    TimeStopMinutes          = 45;         // Max basket age (minutes)
input double ATRExpansionExitFactor   = 1.5;       // ATR expands × expansion ATR + re-accel → exit
input double ProfitHarvestRatio       = 0.10;      // Profit target = BE ± ratio × ImpulseSize

input group "06. Debug"
input bool   EnableDebugPrints        = true;       // Key state transition logging
input bool   EnableChartPanel         = true;       // Debug overlay panel

//+------------------------------------------------------------------+
//| SECTION 2 — GLOBAL VARIABLES                                    |
//+------------------------------------------------------------------+

// === Regime State Machine ===
RegimeState  g_currentRegime      = REGIME_NEUTRAL;
RegimeState  g_previousRegime     = REGIME_NEUTRAL;
int          g_impulseDirection   = BASKET_NONE;
double       g_impulseSize        = 0.0;             // Dynamic: tracks ongoing displacement
// --- v0.2.1 PATCH 1 ---
double       g_initialImpulseSize = 0.0;             // Frozen: snapshot at impulse detection (used for risk/profit)
double       g_impulseAnchorPrice = 0.0;
datetime     g_expansionStartTime = 0;
double       g_expansionATR       = 0.0;     // ATR(M1) recorded at TREND_EXPANSION entry

// === Trend Permission Veto (Layer 3 — replicated M1 logic) ===
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

// === Tick Velocity Engine (Layer 2) ===
struct TickEntry
{
    double price;
    long   time_msc;
};
TickEntry g_tickBuffer[];
int       g_tickCount = 0;

double g_vFast          = 0.0;
double g_vSlow          = 0.0;
double g_peakVFast      = 0.0;
// --- v0.2.1 PATCH 2: g_prevVSlow replaced by g_peakVSlow ---
double g_peakVSlow      = 0.0;             // Peak v_slow during expansion/deceleration
bool   g_stallCondition = false;
bool   g_reAccelFlag    = false;

// === Velocity Median Baseline (Layer 1 input) ===
struct VelocitySnapshot
{
    double vFast;
    long   time_msc;
};
VelocitySnapshot g_velHistory[];
int    g_velHistoryCount       = 0;
double g_dynamicVelocityBaseline = 0.0;

// === ATR Rolling Mean (Layer 1 input) ===
double g_atrRollingBuffer[];
int    g_atrRollingIdx   = 0;
int    g_atrRollingCount = 0;
double g_rollingATRMean  = 0.0;

// === Execution Basket (Layer 4) ===
CTrade trade;
double g_lotLadder[MAX_GRID_LEVELS];
int    g_currentLevel          = 0;
double g_basketFloatingPL      = 0.0;
double g_basketEntryAnchor     = 0.0;
double g_lastGridAnchor        = 0.0;
int    g_fadeDirection          = BASKET_NONE;
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
int    hATR_M1  = INVALID_HANDLE;

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
    if(!IsGoldSymbol(_Symbol))
    {
        Print("ERROR: VolatilityCompressor designed for XAUUSD only. Current: ", _Symbol);
        return(INIT_FAILED);
    }

    trade.SetExpertMagicNumber(CompressorMagic);
    trade.SetDeviationInPoints(SlippagePoints);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    // --- Lot ladder (linear) ---
    int effectiveMaxPos = MathMin(MaxPositions, MAX_GRID_LEVELS);
    for(int i = 0; i < effectiveMaxPos; i++)
        g_lotLadder[i] = BaseLotSize + (double)i * LotIncrement;

    // --- Indicator handles: Trend Permission veto (M1) ---
    hVetoEmaHigh = iMA(_Symbol, PERIOD_M1, TP_EMA_TREND_LEN, 0, MODE_EMA, PRICE_HIGH);
    hVetoEmaLow  = iMA(_Symbol, PERIOD_M1, TP_EMA_TREND_LEN, 0, MODE_EMA, PRICE_LOW);
    hVetoEmaFast = iMA(_Symbol, PERIOD_M1, TP_FAST_LEN, 0, MODE_EMA, PRICE_CLOSE);
    hVetoEmaSlow = iMA(_Symbol, PERIOD_M1, TP_SLOW_LEN, 0, MODE_EMA, PRICE_CLOSE);
    hVetoATR_M1  = iATR(_Symbol, PERIOD_M1, TP_ATR_PERIOD);

    // --- ATR for physics engine & grid spacing (M1) ---
    hATR_M1 = iATR(_Symbol, PERIOD_M1, 14);

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

    // --- Initialize velocity history buffer ---
    ArrayResize(g_velHistory, 0);
    g_velHistoryCount = 0;
    g_dynamicVelocityBaseline = 0.0;

    // --- Initialize ATR rolling buffer ---
    int atrBufSize = MathMax(ATRRollingBars, 1);
    ArrayResize(g_atrRollingBuffer, atrBufSize);
    ArrayInitialize(g_atrRollingBuffer, 0.0);
    g_atrRollingIdx = 0;
    g_atrRollingCount = 0;
    g_rollingATRMean = 0.0;

    // --- Initialize state ---
    InitializeDailyState();
    ResetBasketState();
    g_currentRegime = REGIME_NEUTRAL;
    g_previousRegime = REGIME_NEUTRAL;
    g_expansionATR = 0.0;

    if(EnableChartPanel)
        CreatePanel();

    Print("==============================================");
    Print("VolatilityCompressorEA_v0_2 initialized");
    Print("Symbol: ", _Symbol, " | Magic: ", CompressorMagic);
    Print("----------------------------------------------");
    Print("ARCHITECTURE v0.2:");
    Print("  Layer 1: Impulse Physics Engine (M5 displacement + vel baseline + ATR expansion)");
    Print("  Layer 2: Velocity Decay Confirmation (tick-level v_fast/v_slow)");
    Print("  Layer 3: Trend Permission Veto (M1 EMA — FADE VETO ONLY)");
    Print("  Layer 4: Fade Execution (linear grid, dynamic spacing)");
    Print("  Layer 5: Survival Controls (basket stop, structural, time, ATR guard)");
    Print("----------------------------------------------");
    Print("Impulse: disp>=$", DoubleToString(MinImpulseDisplacement_USD, 2),
          " ratio>=", DoubleToString(ImpulseBodyRatio, 2),
          " ATR×", DoubleToString(ExpansionFactor, 1));
    Print("VelBaseline: median over ", VelocityMedianSeconds, "s");
    Print("Grid: max(", DoubleToString(MinGridSpacing_Pips, 0), "pip, ",
          DoubleToString(GridATR_Multiplier, 2), "×ATR, ",
          DoubleToString(ImpulseSpacingFraction, 2), "×impulse)");
    Print("Profit: BE ± ", DoubleToString(ProfitHarvestRatio, 2), " × ImpulseSize");
    Print("==============================================");

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| SECTION 3B — OnDeinit                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(hVetoEmaHigh != INVALID_HANDLE) IndicatorRelease(hVetoEmaHigh);
    if(hVetoEmaLow  != INVALID_HANDLE) IndicatorRelease(hVetoEmaLow);
    if(hVetoEmaFast != INVALID_HANDLE) IndicatorRelease(hVetoEmaFast);
    if(hVetoEmaSlow != INVALID_HANDLE) IndicatorRelease(hVetoEmaSlow);
    if(hVetoATR_M1  != INVALID_HANDLE) IndicatorRelease(hVetoATR_M1);
    if(hATR_M1      != INVALID_HANDLE) IndicatorRelease(hATR_M1);

    if(EnableChartPanel)
        DeletePanel();

    Comment("");
    Print("VolatilityCompressorEA_v0_2 deinitialized. Reason: ", reason);
    Print("Final Daily Realized P&L: $", DoubleToString(g_dailyRealizedPL, 2));
}

//+------------------------------------------------------------------+
//| SECTION 4 — OnTick (MAIN FLOW)                                 |
//|                                                                  |
//| Execution order:                                                 |
//|   1. Day reset                                                   |
//|   2. Tick buffer + velocities + velocity baseline                |
//|   3. Daily risk                                                  |
//|   4. Basket health (survival)                                    |
//|   5. M1 bar: update trend permission veto + ATR rolling mean     |
//|   6. M5 bar: (future hooks — impulse is now physics-driven)      |
//|   7. Regime state machine (every tick)                           |
//|   8. Execution (fade entry + grid adds)                          |
//|   9. Panel                                                       |
//+------------------------------------------------------------------+
void OnTick()
{
    // --- 1. Day reset ---
    CheckDayReset();

    // --- 2. Tick velocity engine ---
    UpdateTickBuffer();
    ComputeVelocities();
    UpdateVelocityBaseline();

    // --- 3. Daily risk ---
    CheckDailyRisk();

    // --- 4. Basket health ---
    if(BasketHasPositions())
    {
        g_basketFloatingPL = CalculateBasketFloat();
        CheckSurvivalControls();
    }
    else if(g_currentLevel > 0)
    {
        LogBasketClose("ExternalClose");
        ResetBasketState();
    }

    // --- 5. M1 bar: trend permission veto + ATR rolling mean ---
    datetime m1Bar = iTime(_Symbol, PERIOD_M1, 0);
    if(m1Bar != g_lastM1Bar)
    {
        g_lastM1Bar = m1Bar;
        UpdateTrendPermissionVeto();
        UpdateATRRollingMean();
    }

    // --- 6. M5 bar tracking ---
    datetime m5Bar = iTime(_Symbol, PERIOD_M5, 0);
    if(m5Bar != g_lastM5Bar)
    {
        g_lastM5Bar = m5Bar;
    }

    // --- 7. Regime state machine (every tick) ---
    UpdateRegimeStateMachine();

    // --- 8. Execution ---
    if(!g_tradingDisabled)
    {
        if(g_currentRegime == REGIME_EXHAUSTION_WINDOW)
            TryFadeEntry();

        if(g_currentRegime == REGIME_ACTIVE_FADE)
            ManageGridAdds();
    }

    // --- 9. Panel ---
    if(EnableChartPanel)
        UpdatePanel();
}

//+------------------------------------------------------------------+
//| SECTION 5 — REGIME STATE MACHINE                                |
//|                                                                  |
//| v0.2 CORE CHANGE: NEUTRAL → EXPANSION is triggered by           |
//| ImpulsePhysicsDetected(), NOT by TrendPermission.                |
//| TrendPermission is Layer 3 — it can ONLY veto fade entries.      |
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

// Transition regime state with key-transition logging
void TransitionRegime(RegimeState newRegime)
{
    if(newRegime == g_currentRegime)
        return;

    g_previousRegime = g_currentRegime;
    g_currentRegime  = newRegime;

    Print("========== REGIME TRANSITION ==========");
    Print("  ", RegimeToString(g_previousRegime), " -> ", RegimeToString(g_currentRegime));
    Print("  ImpulseSize:   $", DoubleToString(g_impulseSize, 2),
          " | Dir: ", g_impulseDirection == BASKET_LONG ? "UP" :
                      (g_impulseDirection == BASKET_SHORT ? "DOWN" : "NONE"));
    Print("  v_fast:        ", DoubleToString(g_vFast, 6),
          " | peak: ", DoubleToString(g_peakVFast, 6),
          " | baseline: ", DoubleToString(g_dynamicVelocityBaseline, 6));
    Print("=======================================");

    // State-entry cleanup for NEUTRAL
    if(newRegime == REGIME_NEUTRAL)
    {
        g_impulseDirection   = BASKET_NONE;
        g_impulseSize        = 0.0;
        // --- v0.2.1 PATCH 1 ---
        g_initialImpulseSize = 0.0;
        g_impulseAnchorPrice = 0.0;
        g_expansionStartTime = 0;
        g_expansionATR       = 0.0;
        g_peakVFast          = 0.0;
        // --- v0.2.1 PATCH 2 ---
        g_peakVSlow          = 0.0;
        g_reAccelFlag        = false;
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

    if(g_currentRegime == REGIME_DISABLED && !g_tradingDisabled)
    {
        TransitionRegime(REGIME_NEUTRAL);
        return;
    }

    // === ACTIVE_FADE: locked until basket closes ===
    if(g_currentRegime == REGIME_ACTIVE_FADE)
    {
        if(!BasketHasPositions())
            TransitionRegime(REGIME_NEUTRAL);
        return;
    }

    // === Update impulse displacement continuously ===
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

    // === Track peak velocities during expansion/deceleration ===
    if(g_currentRegime == REGIME_TREND_EXPANSION ||
       g_currentRegime == REGIME_TREND_DECELERATION)
    {
        if(g_vFast > g_peakVFast)
            g_peakVFast = g_vFast;
        // --- v0.2.1 PATCH 2 ---
        if(g_vSlow > g_peakVSlow)
            g_peakVSlow = g_vSlow;
    }

    // === State-specific transitions ===
    switch(g_currentRegime)
    {
        case REGIME_NEUTRAL:
        {
            // NEUTRAL → EXPANSION: physics-driven impulse detection
            if(ImpulsePhysicsDetected())
                TransitionRegime(REGIME_TREND_EXPANSION);
            break;
        }

        case REGIME_TREND_EXPANSION:
        {
            // Fallback: no impulse persists — impulse reversed or timed out
            if(g_impulseSize < 0)
            {
                if(EnableDebugPrints)
                    Print(">>> REGIME: Impulse reversed past anchor — NEUTRAL");
                TransitionRegime(REGIME_NEUTRAL);
                break;
            }

            if(g_expansionStartTime > 0)
            {
                int elapsed = (int)((TimeCurrent() - g_expansionStartTime) / 60);
                if(elapsed >= MaxExpansionMinutes)
                {
                    if(EnableDebugPrints)
                        Print(">>> REGIME: Expansion timeout (", elapsed, " min) — NEUTRAL");
                    TransitionRegime(REGIME_NEUTRAL);
                    break;
                }
            }

            // EXPANSION → DECELERATION: velocity weakening
            if(g_peakVFast > 0 && g_vFast <= 0.70 * g_peakVFast)
            {
                TransitionRegime(REGIME_TREND_DECELERATION);
            }
            break;
        }

        case REGIME_TREND_DECELERATION:
        {
            // Re-acceleration → back to EXPANSION
            if(g_reAccelFlag)
            {
                g_reAccelFlag = false;
                TransitionRegime(REGIME_TREND_EXPANSION);
                break;
            }

            // Fallback: impulse reversed or timed out
            if(g_impulseSize < 0)
            {
                TransitionRegime(REGIME_NEUTRAL);
                break;
            }

            if(g_expansionStartTime > 0)
            {
                int elapsed = (int)((TimeCurrent() - g_expansionStartTime) / 60);
                if(elapsed >= MaxExpansionMinutes)
                {
                    if(EnableDebugPrints)
                        Print(">>> REGIME: Deceleration timeout (", elapsed, " min) — NEUTRAL");
                    TransitionRegime(REGIME_NEUTRAL);
                    break;
                }
            }

            // DECELERATION → EXHAUSTION_WINDOW: decay + displacement + structural exhaustion
            // NOTE: TrendPermission veto is NOT checked here. Veto only blocks fade ENTRY.
            bool decayOK        = VelocityDecayConfirmed();
            bool displacementOK = (g_impulseSize >= MinImpulseDisplacement_USD);
            // --- v0.2.2: Structural exhaustion gate prevents fading during live impulse ---
            bool structOK       = StructuralExhaustionConfirmed();

            if(decayOK && displacementOK && structOK)
            {
                TransitionRegime(REGIME_EXHAUSTION_WINDOW);
            }
            break;
        }

        case REGIME_EXHAUSTION_WINDOW:
        {
            // Re-acceleration → back to EXPANSION (impulse resumed)
            if(g_reAccelFlag)
            {
                g_reAccelFlag = false;
                TransitionRegime(REGIME_TREND_EXPANSION);
                break;
            }

            // Timeout fallback
            if(g_expansionStartTime > 0)
            {
                int elapsed = (int)((TimeCurrent() - g_expansionStartTime) / 60);
                if(elapsed >= MaxExpansionMinutes * 2)
                {
                    if(EnableDebugPrints)
                        Print(">>> REGIME: Exhaustion timeout — NEUTRAL");
                    TransitionRegime(REGIME_NEUTRAL);
                    break;
                }
            }

            // Entry taken transitions to ACTIVE_FADE (handled in TryFadeEntry)
            break;
        }

        default:
            break;
    }
}

//+------------------------------------------------------------------+
//| SECTION 6 — TREND PERMISSION VETO MODULE (Layer 3)              |
//|                                                                  |
//| Replicates FROZEN M1 trend permission from TrendPermissionEA.    |
//| v0.2 RESTRICTION: longEntryAllowed / shortEntryAllowed are used  |
//| ONLY to veto fade entries in TryFadeEntry(). They do NOT drive   |
//| the regime state machine.                                        |
//+------------------------------------------------------------------+

void UpdateTrendPermissionVeto()
{
    longEntryAllowedPrev  = longEntryAllowed;
    shortEntryAllowedPrev = shortEntryAllowed;
    vetoFastSlopePrev     = vetoFastSlope;
    vetoGapPrev           = vetoGap;

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

    // --- Base conditions (FROZEN v3.7 logic) ---
    bool longBase = isBullRegime && (vetoSlowSlope > 0) && (vetoFastSlope > 0) &&
                    accelUp && gapBull && gapWidening;

    bool shortBase = isBearRegime && (vetoSlowSlope < 0) && (vetoFastSlope < 0) &&
                     accelDown && gapBear && gapNarrowing;

    // --- Structural body clearance (FROZEN v3.8) ---
    double bodyHigh   = MathMax(completedOpen, completedClose);
    double bodyLow    = MathMin(completedOpen, completedClose);
    double cloudTop   = MathMax(vetoEmaFast[1], vetoEmaSlow[1]);
    double cloudBottom = MathMin(vetoEmaFast[1], vetoEmaSlow[1]);

    bool longStructuralClear  = (bodyLow > cloudTop) && (bodyLow > vetoEma200High[1]);
    bool shortStructuralClear = (bodyHigh < cloudBottom) && (bodyHigh < vetoEma200Low[1]);

    // --- Trend force filter (FROZEN v3.8 ATR-normalized slope) ---
    double currentATR = vetoATR[1];
    double normSlopeStrength = 0.0;
    if(currentATR > 0)
        normSlopeStrength = MathAbs(vetoSlowSlope) / currentATR;

    bool trendForceOK = (normSlopeStrength > TP_MIN_SLOPE);

    // --- Final gated permissions ---
    longEntryAllowed  = longBase && longStructuralClear && trendForceOK;
    shortEntryAllowed = shortBase && shortStructuralClear && trendForceOK;

    // --- Log transitions ---
    if(longEntryAllowed && !longEntryAllowedPrev && EnableDebugPrints)
        Print(">>> VETO: LONG permission START (blocks SELL fades)");
    if(!longEntryAllowed && longEntryAllowedPrev && EnableDebugPrints)
        Print(">>> VETO: LONG permission END");
    if(shortEntryAllowed && !shortEntryAllowedPrev && EnableDebugPrints)
        Print(">>> VETO: SHORT permission START (blocks BUY fades)");
    if(!shortEntryAllowed && shortEntryAllowedPrev && EnableDebugPrints)
        Print(">>> VETO: SHORT permission END");
}

//+------------------------------------------------------------------+
//| SECTION 7 — VELOCITY DECAY ENGINE (Layer 2)                     |
//|                                                                  |
//| Tick-level velocity computation: v_fast (~1.5s), v_slow (~buffer)|
//| Tracks peak v_fast, stall condition, re-acceleration flag.       |
//| v0.2: Also feeds velocity history for median baseline.           |
//+------------------------------------------------------------------+

void UpdateTickBuffer()
{
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick))
        return;

    int newSize = g_tickCount + 1;
    ArrayResize(g_tickBuffer, newSize, 200);
    g_tickBuffer[g_tickCount].price    = (tick.bid + tick.ask) / 2.0;
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
            pruneFrom = g_tickCount - 1;
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

    double fastDt = (double)(nowMs - fastMs) / 1000.0;
    if(fastDt > 0.05)
        g_vFast = MathAbs(nowPrice - fastPrice) / fastDt;
    else
        g_vFast = 0.0;

    // --- v_slow: velocity over full buffer window ---
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

    // --- Peak v_fast tracking ---
    if(g_vFast > g_peakVFast)
        g_peakVFast = g_vFast;

    // --- Stall condition: v_fast below ATR noise floor ---
    double atrRef[1];
    if(CopyBuffer(hATR_M1, 0, 0, 1, atrRef) >= 1 && atrRef[0] > 0)
        g_stallCondition = (g_vFast < 0.01 * atrRef[0]);
    else
        g_stallCondition = (g_vFast < 0.001);

    // --- Re-acceleration flag ---
    g_reAccelFlag = false;
    if(g_peakVFast > 0 && g_vFast >= ReAccelerationRatio * g_peakVFast)
        g_reAccelFlag = true;
}

// Update the rolling velocity history buffer and compute median baseline
void UpdateVelocityBaseline()
{
    if(g_tickCount < 1)
        return;

    long nowMs = g_tickBuffer[g_tickCount - 1].time_msc;

    // Add current v_fast snapshot
    if(g_velHistoryCount < MAX_VEL_BUFFER)
    {
        ArrayResize(g_velHistory, g_velHistoryCount + 1, 100);
        g_velHistory[g_velHistoryCount].vFast    = g_vFast;
        g_velHistory[g_velHistoryCount].time_msc = nowMs;
        g_velHistoryCount++;
    }
    else
    {
        // Shift left by 1 and append (simple ring fallback)
        for(int i = 1; i < g_velHistoryCount; i++)
            g_velHistory[i - 1] = g_velHistory[i];
        g_velHistory[g_velHistoryCount - 1].vFast    = g_vFast;
        g_velHistory[g_velHistoryCount - 1].time_msc = nowMs;
    }

    // Prune entries older than VelocityMedianSeconds
    long cutoffMs = nowMs - (long)VelocityMedianSeconds * 1000;
    int pruneFrom = 0;
    for(int i = 0; i < g_velHistoryCount; i++)
    {
        if(g_velHistory[i].time_msc >= cutoffMs)
        {
            pruneFrom = i;
            break;
        }
        if(i == g_velHistoryCount - 1)
            pruneFrom = g_velHistoryCount - 1;
    }

    if(pruneFrom > 0)
    {
        for(int i = pruneFrom; i < g_velHistoryCount; i++)
            g_velHistory[i - pruneFrom] = g_velHistory[i];
        g_velHistoryCount -= pruneFrom;
        ArrayResize(g_velHistory, g_velHistoryCount);
    }

    // Compute median of v_fast values in buffer
    g_dynamicVelocityBaseline = ComputeVelocityMedian();
}

// Compute median of all v_fast values in the velocity history buffer
double ComputeVelocityMedian()
{
    if(g_velHistoryCount == 0)
        return 0.0;

    double temp[];
    ArrayResize(temp, g_velHistoryCount);
    for(int i = 0; i < g_velHistoryCount; i++)
        temp[i] = g_velHistory[i].vFast;

    ArraySort(temp);

    int mid = g_velHistoryCount / 2;
    if(g_velHistoryCount % 2 == 0)
        return (temp[mid - 1] + temp[mid]) / 2.0;
    else
        return temp[mid];
}

// v0.2: Velocity decay confirmation using v_fast, v_slow, and stall
bool VelocityDecayConfirmed()
{
    bool rule1 = (g_peakVFast > 0) && (g_vFast <= VFastDecayRatio * g_peakVFast);
    // --- v0.2.1 PATCH 2: compare to peak v_slow, not previous tick v_slow ---
    bool rule2 = (g_peakVSlow > 0) && (g_vSlow <= VSlowDecayRatio * g_peakVSlow);
    bool rule3 = g_stallCondition;

    return (rule1 && rule2 && rule3);
}

//+------------------------------------------------------------------+
//| SECTION 7B — STRUCTURAL EXHAUSTION FILTER (v0.2.2)              |
//|                                                                  |
//| Price-structure gates that prevent fading during live vertical   |
//| moves. Called before DECELERATION→EXHAUSTION_WINDOW transition.  |
//| All logic is bar-based and non-lagging.                          |
//+------------------------------------------------------------------+
bool StructuralExhaustionConfirmed()
{
    // === GUARD 0: Direction must be set ===
    if(g_impulseDirection == BASKET_NONE)
        return false;

    // === GUARD 1: Re-acceleration active — still in live impulse ===
    if(g_reAccelFlag)
        return false;

    // === GUARD 2: Minimum expansion age — prohibits exhaustion during spike onset ===
    if(g_expansionStartTime > 0 && (TimeCurrent() - g_expansionStartTime) < 30)
        return false;

    // === GUARD 3: ATR still expanding — in-progress vertical spike ===
    // If current M1 ATR still exceeds the expansion threshold, the impulse is live.
    double currentATR = GetCurrentATR_M1();
    if(currentATR > 0 && g_rollingATRMean > 0 &&
       currentATR > ExpansionFactor * g_rollingATRMean)
        return false;

    // === CONDITION 1: Extension Maturity ===
    // Impulse must have extended beyond the initial snapshot before we fade.
    // If g_impulseSize < 1.3 × g_initialImpulseSize, the move hasn't matured.
    if(g_initialImpulseSize <= 0)
        return false;

    if(g_impulseSize < ExtensionMaturityMult * g_initialImpulseSize)
        return false;

    // === Fetch last (ImpulseLookbackBars + MomentumStallBars) M5 bars ===
    // We need enough history for swing peak + stall check bars.
    int totalBars = ImpulseLookbackBars + MomentumStallBars;
    double highs[], lows[], closes[];

    // shift=1 → start from most recently completed M5 bar
    if(CopyHigh (_Symbol, PERIOD_M5, 1, totalBars, highs)  < totalBars) return false;
    if(CopyLow  (_Symbol, PERIOD_M5, 1, totalBars, lows)   < totalBars) return false;
    if(CopyClose(_Symbol, PERIOD_M5, 1, totalBars, closes) < totalBars) return false;
    // Array layout: index 0 = bar[1] (most recent closed), index N-1 = oldest bar.

    double failureMargin = HighFailureMarginRatio * g_initialImpulseSize;

    if(g_impulseDirection == BASKET_LONG)  // UP impulse — fade SHORT
    {
        // Find swing high over the lookback window
        double swingHigh = highs[0];
        for(int i = 1; i < ImpulseLookbackBars; i++)
            if(highs[i] > swingHigh) swingHigh = highs[i];

        // === CONDITION 2: High Failure — current bar fails to challenge swing high ===
        // Most recent closed bar's high is clearly below the swing peak.
        if(highs[0] > swingHigh - failureMargin)
            return false;  // Price still pressing the high — not exhausted

        // === CONDITION 3: Momentum Stall — N consecutive closes below swing high ===
        for(int i = 0; i < MomentumStallBars; i++)
        {
            if(closes[i] >= swingHigh)
                return false;  // At least one recent close broke swing high — still trending
        }
    }
    else  // BASKET_SHORT → DOWN impulse — fade LONG
    {
        // Find swing low over the lookback window
        double swingLow = lows[0];
        for(int i = 1; i < ImpulseLookbackBars; i++)
            if(lows[i] < swingLow) swingLow = lows[i];

        // === CONDITION 2: Low Failure — current bar fails to challenge swing low ===
        // Most recent closed bar's low is clearly above the swing trough.
        if(lows[0] < swingLow + failureMargin)
            return false;  // Price still pressing the low — not exhausted

        // === CONDITION 3: Momentum Stall — N consecutive closes above swing low ===
        for(int i = 0; i < MomentumStallBars; i++)
        {
            if(closes[i] <= swingLow)
                return false;  // At least one recent close broke swing low — still trending
        }
    }

    if(EnableDebugPrints)
    {
        Print(">>> STRUCTURAL EXHAUSTION CONFIRMED");
        Print("    Direction:   ", g_impulseDirection == BASKET_LONG ? "UP(fade SHORT)" : "DOWN(fade LONG)");
        Print("    InitSize:    $", DoubleToString(g_initialImpulseSize, 2));
        Print("    CurSize:     $", DoubleToString(g_impulseSize, 2),
              " (", DoubleToString(g_impulseSize / g_initialImpulseSize, 2), "x maturity)");
        Print("    ExpansionAge: ", (int)(TimeCurrent() - g_expansionStartTime), "s");
        Print("    ATR(M1):     ", DoubleToString(currentATR, 4),
              " vs RollingMean ", DoubleToString(g_rollingATRMean, 4));
    }

    return true;
}

//+------------------------------------------------------------------+
//| SECTION 7A — ATR ROLLING MEAN                                   |
//|                                                                  |
//| Circular buffer of ATR(M1) values over ATRRollingBars M1 bars.   |
//| Used by Impulse Physics Engine to detect ATR expansion.           |
//+------------------------------------------------------------------+

void UpdateATRRollingMean()
{
    double atr = GetCurrentATR_M1();
    if(atr <= 0)
        return;

    int bufSize = MathMax(ATRRollingBars, 1);

    g_atrRollingBuffer[g_atrRollingIdx] = atr;
    g_atrRollingIdx = (g_atrRollingIdx + 1) % bufSize;
    if(g_atrRollingCount < bufSize)
        g_atrRollingCount++;

    // --- v0.2.1 PATCH 4: exclude most recently inserted value to prevent self-dilution ---
    // Mean is computed from all previous values only.
    // If fewer than 2 values exist, baseline is undefined — skip.
    if(g_atrRollingCount < 2)
    {
        g_rollingATRMean = 0.0;
        return;
    }

    int mostRecentSlot = (g_atrRollingIdx - 1 + bufSize) % bufSize;
    double sum = 0.0;
    int counted = 0;
    for(int i = 0; i < g_atrRollingCount; i++)
    {
        if(i == mostRecentSlot)
            continue;   // skip the most recently inserted slot
        sum += g_atrRollingBuffer[i];
        counted++;
    }

    g_rollingATRMean = (counted > 0) ? sum / (double)counted : 0.0;
}

//+------------------------------------------------------------------+
//| SECTION 8 — IMPULSE PHYSICS ENGINE (Layer 1)                    |
//|                                                                  |
//| v0.2 CORE: Replaces TrendPermission-driven expansion trigger.    |
//|                                                                  |
//| Impulse detected when ALL conditions met:                        |
//|   1. M5 net displacement >= MinImpulseDisplacement_USD           |
//|   2. Displacement efficiency >= ImpulseBodyRatio                 |
//|   3. v_fast > DynamicVelocityBaseline (rolling 60s median)       |
//|   4. ATR(M1) > RollingATRMean × ExpansionFactor                 |
//|                                                                  |
//| On detection: sets impulse direction, anchor, peak, start time.  |
//+------------------------------------------------------------------+

bool ImpulsePhysicsDetected()
{
    // Only detect from NEUTRAL
    if(g_currentRegime != REGIME_NEUTRAL)
        return false;

    // Need sufficient M5 bars
    int barsAvailable = Bars(_Symbol, PERIOD_M5);
    if(barsAvailable < ImpulseLookbackBars + 2)
        return false;

    // Need sufficient velocity history for baseline
    if(g_velHistoryCount < 10)
        return false;

    // Need ATR rolling mean established
    if(g_atrRollingCount < 5)
        return false;

    // === CONDITION 1: M5 net displacement ===
    double startClose = iClose(_Symbol, PERIOD_M5, ImpulseLookbackBars);
    double endClose   = iClose(_Symbol, PERIOD_M5, 1);
    double netDisplacement = endClose - startClose;
    double absDisp = MathAbs(netDisplacement);

    if(absDisp < MinImpulseDisplacement_USD)
        return false;

    // === CONDITION 2: Displacement efficiency ratio ===
    double totalRange = 0.0;
    for(int i = 1; i <= ImpulseLookbackBars; i++)
        totalRange += iHigh(_Symbol, PERIOD_M5, i) - iLow(_Symbol, PERIOD_M5, i);

    if(totalRange <= 0)
        return false;

    double efficiencyRatio = absDisp / totalRange;
    if(efficiencyRatio < ImpulseBodyRatio)
        return false;

    // === CONDITION 3: v_fast >= VelocityImpulseMultiplier × dynamic baseline ===
    // --- v0.2.1 PATCH 3: strengthen from '>baseline' to '>= multiplier × baseline' ---
    if(g_dynamicVelocityBaseline <= 0)
        return false;

    if(g_vFast < VelocityImpulseMultiplier * g_dynamicVelocityBaseline)
        return false;

    // === CONDITION 4: ATR(M1) > RollingATRMean × ExpansionFactor ===
    double currentATR = GetCurrentATR_M1();
    if(currentATR <= 0 || g_rollingATRMean <= 0)
        return false;

    if(currentATR <= g_rollingATRMean * ExpansionFactor)
        return false;

    // === ALL CONDITIONS MET — SET IMPULSE STATE ===
    g_impulseDirection   = (netDisplacement > 0) ? BASKET_LONG : BASKET_SHORT;
    g_impulseAnchorPrice = startClose;
    g_impulseSize        = absDisp;
    // --- v0.2.1 PATCH 1: freeze initial size snapshot ---
    g_initialImpulseSize = absDisp;
    g_peakVFast          = g_vFast;
    g_expansionStartTime = TimeCurrent();
    g_expansionATR       = currentATR;

    Print(">>> IMPULSE PHYSICS DETECTED <<<");
    Print("  Direction:     ", g_impulseDirection == BASKET_LONG ? "UP" : "DOWN");
    Print("  Displacement:  $", DoubleToString(absDisp, 2),
          " (min $", DoubleToString(MinImpulseDisplacement_USD, 2), ")");
    Print("  InitialSize:   $", DoubleToString(g_initialImpulseSize, 2), " [FROZEN]");
    Print("  Efficiency:    ", DoubleToString(efficiencyRatio, 3),
          " (min ", DoubleToString(ImpulseBodyRatio, 2), ")");
    Print("  v_fast:        ", DoubleToString(g_vFast, 6),
          " >= ", DoubleToString(VelocityImpulseMultiplier, 2), " × baseline ",
          DoubleToString(g_dynamicVelocityBaseline, 6));
    Print("  ATR(M1):       ", DoubleToString(currentATR, 4),
          " > ", DoubleToString(g_rollingATRMean, 4), " × ", DoubleToString(ExpansionFactor, 1));
    Print("  Anchor:        ", DoubleToString(g_impulseAnchorPrice, 2));

    return true;
}

//+------------------------------------------------------------------+
//| SECTION 9 — EXECUTION ENGINE (Layer 4)                          |
//|                                                                  |
//| v0.2 changes:                                                    |
//|  - Grid spacing: max(minPips, ATR×mult, impulse×fraction)        |
//|  - Trade comments tagged v0.2                                    |
//|  - Veto is the ONLY role of TrendPermission here                 |
//+------------------------------------------------------------------+

// Dynamic grid spacing tied to impulse magnitude
double GetDynamicGridSpacing()
{
    // Minimum floor: pips → USD for gold ($0.10 per pip)
    double spacing = MinGridSpacing_Pips * 0.10;

    // ATR-based spacing
    double atrBuf[1];
    if(CopyBuffer(hATR_M1, 0, 0, 1, atrBuf) >= 1)
    {
        double atrSpacing = GridATR_Multiplier * atrBuf[0];
        spacing = MathMax(spacing, atrSpacing);
    }

    // Impulse-proportional spacing
    if(g_impulseSize > 0)
    {
        double impulseSpacing = g_impulseSize * ImpulseSpacingFraction;
        spacing = MathMax(spacing, impulseSpacing);
    }

    return spacing;
}

// Attempt fade entry from EXHAUSTION_WINDOW
void TryFadeEntry()
{
    if(g_currentRegime != REGIME_EXHAUSTION_WINDOW)
        return;

    if(BasketHasPositions())
        return;

    // Determine fade direction (opposite of impulse)
    int fadeDir = BASKET_NONE;
    if(g_impulseDirection == BASKET_LONG)
        fadeDir = BASKET_SHORT;
    else if(g_impulseDirection == BASKET_SHORT)
        fadeDir = BASKET_LONG;

    if(fadeDir == BASKET_NONE)
        return;

    // === LAYER 3: TREND PERMISSION VETO ===
    // This is the ONLY place TrendPermission affects execution.
    // If fading SHORT (selling) and longEntryAllowed → blocked
    // If fading LONG (buying) and shortEntryAllowed → blocked
    if(fadeDir == BASKET_SHORT && longEntryAllowed)
    {
        datetime bar = iTime(_Symbol, PERIOD_M1, 0);
        if(bar != g_vetoLogBar)
        {
            g_vetoLogBar = bar;
            if(EnableDebugPrints)
                Print(">>> VETO: Cannot SELL fade — longEntryAllowed active");
        }
        return;
    }
    if(fadeDir == BASKET_LONG && shortEntryAllowed)
    {
        datetime bar = iTime(_Symbol, PERIOD_M1, 0);
        if(bar != g_vetoLogBar)
        {
            g_vetoLogBar = bar;
            if(EnableDebugPrints)
                Print(">>> VETO: Cannot BUY fade — shortEntryAllowed active");
        }
        return;
    }

    // === SPREAD CHECK ===
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadPts = (ask - bid) / _Point;

    if(spreadPts > MaxSpreadPoints)
        return;

    // === EXECUTE LEVEL 1 FADE ENTRY ===
    double lot = g_lotLadder[0];
    if(lot > MaxTotalLots)
        lot = MaxTotalLots;

    bool success = false;
    double entryPrice = 0.0;

    if(fadeDir == BASKET_LONG)
    {
        success = trade.Buy(lot, _Symbol, ask, 0, 0, "VC_v0.2_FADE_BUY_L1");
        entryPrice = ask;
    }
    else if(fadeDir == BASKET_SHORT)
    {
        success = trade.Sell(lot, _Symbol, bid, 0, 0, "VC_v0.2_FADE_SELL_L1");
        entryPrice = bid;
    }

    if(success)
    {
        g_currentLevel      = 1;
        g_fadeDirection      = fadeDir;
        g_basketEntryAnchor = entryPrice;
        g_lastGridAnchor    = entryPrice;
        g_basketEntryTime   = TimeCurrent();
        g_totalLotsOpen     = lot;

        Print(">>> FADE ENTRY: ", (fadeDir == BASKET_LONG ? "BUY" : "SELL"), " L1");
        Print("    ImpulseSize:  $", DoubleToString(g_impulseSize, 2));
        Print("    GridSpacing:  $", DoubleToString(GetDynamicGridSpacing(), 2));
        Print("    Lot:          ", DoubleToString(lot, 2));
        Print("    Entry:        ", DoubleToString(entryPrice, 2));

        TransitionRegime(REGIME_ACTIVE_FADE);
    }
    else
    {
        Print("!!! FADE ENTRY FAILED | Dir=", fadeDir, " | Error=", GetLastError());
    }
}

// Add grid positions at dynamic spacing when price moves against fade
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

    // Lot capacity check
    double nextLot = g_lotLadder[g_currentLevel];
    if(g_totalLotsOpen + nextLot > MaxTotalLots)
        return;

    // Spread check
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadPts = (ask - bid) / _Point;
    if(spreadPts > MaxSpreadPoints)
        return;

    double gridSpacing = GetDynamicGridSpacing();

    // Price moved AGAINST fade direction by gridSpacing → add
    bool addCondition = false;

    if(g_fadeDirection == BASKET_LONG)
    {
        if(ask <= g_lastGridAnchor - gridSpacing)
            addCondition = true;
    }
    else if(g_fadeDirection == BASKET_SHORT)
    {
        if(bid >= g_lastGridAnchor + gridSpacing)
            addCondition = true;
    }

    if(!addCondition)
        return;

    bool success = false;
    double entryPrice = 0.0;

    if(g_fadeDirection == BASKET_LONG)
    {
        success = trade.Buy(nextLot, _Symbol, ask, 0, 0,
                           "VC_v0.2_FADE_BUY_L" + IntegerToString(g_currentLevel + 1));
        entryPrice = ask;
    }
    else if(g_fadeDirection == BASKET_SHORT)
    {
        success = trade.Sell(nextLot, _Symbol, bid, 0, 0,
                            "VC_v0.2_FADE_SELL_L" + IntegerToString(g_currentLevel + 1));
        entryPrice = bid;
    }

    if(success)
    {
        g_lastGridAnchor = entryPrice;
        g_currentLevel++;
        g_totalLotsOpen += nextLot;

        if(EnableDebugPrints)
        {
            Print(">>> GRID ADD L", g_currentLevel,
                  " | Lots: ", DoubleToString(g_totalLotsOpen, 2),
                  " | Float: $", DoubleToString(g_basketFloatingPL, 2),
                  " | Spacing: $", DoubleToString(gridSpacing, 2));
        }
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

// v0.2: Compute volume-weighted average entry price across basket
double BasketBreakEvenPrice()
{
    double sumPriceTimesLot = 0.0;
    double sumLots = 0.0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == CompressorMagic)
            {
                double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                double volume    = PositionGetDouble(POSITION_VOLUME);
                sumPriceTimesLot += openPrice * volume;
                sumLots          += volume;
            }
        }
    }

    if(sumLots > 0)
        return sumPriceTimesLot / sumLots;

    return 0.0;
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
                    Print(">>> VC CLOSED | Reason: ", reason,
                          " | Profit: $", DoubleToString(profit, 2));
                }
            }
        }
    }
}

void ResetBasketState()
{
    g_currentLevel      = 0;
    g_fadeDirection      = BASKET_NONE;
    g_basketEntryAnchor = 0.0;
    g_lastGridAnchor    = 0.0;
    g_basketFloatingPL  = 0.0;
    g_basketEntryTime   = 0;
    g_totalLotsOpen     = 0.0;
}

double GetCurrentATR_M1()
{
    double buf[1];
    if(CopyBuffer(hATR_M1, 0, 0, 1, buf) >= 1)
        return buf[0];
    return 0.0;
}

//+------------------------------------------------------------------+
//| SECTION 11 — SURVIVAL CONTROLS (Layer 5)                        |
//|                                                                  |
//| Priority order:                                                  |
//|   1. Hard basket stop (% equity)                                 |
//|   2. Structural invalidation (adverse move > mult × impulse)     |
//|   3. ATR expansion guard (ATR re-expands + re-acceleration)      |
//|   4. Time stop (max basket age)                                  |
//|   5. Re-acceleration exit (velocity resumes during fade)         |
//|   6. Profit target (price crosses BE ± harvest ratio × impulse)  |
//+------------------------------------------------------------------+

void CheckSurvivalControls()
{
    if(!BasketHasPositions())
        return;

    // --- 1. Hard Basket Stop (% of equity) ---
    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
    double stopUSD = equity * BasketStopPct / 100.0;

    if(g_basketFloatingPL <= -stopUSD)
    {
        Print("!!! SURVIVAL: HARD BASKET STOP | Float: $", DoubleToString(g_basketFloatingPL, 2),
              " <= -$", DoubleToString(stopUSD, 2));
        LogBasketClose("HardStop");
        CloseAllBasketPositions("Survival_HardStop");
        ResetBasketState();
        return;
    }

    // --- 2. Structural Invalidation (adverse move exceeds threshold) ---
    // --- v0.2.1 PATCH 1: use frozen g_initialImpulseSize, not dynamic g_impulseSize ---
    if(g_initialImpulseSize > 0 && g_basketEntryAnchor > 0)
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double adverseMove = 0.0;

        if(g_fadeDirection == BASKET_LONG)
            adverseMove = g_basketEntryAnchor - bid;
        else if(g_fadeDirection == BASKET_SHORT)
            adverseMove = ask - g_basketEntryAnchor;

        double invalidationLevel = StructuralInvalid_Mult * g_initialImpulseSize;

        if(adverseMove > invalidationLevel)
        {
            Print("!!! SURVIVAL: STRUCTURAL INVALIDATION | Adverse: $", DoubleToString(adverseMove, 2),
                  " > $", DoubleToString(invalidationLevel, 2),
                  " (", DoubleToString(StructuralInvalid_Mult, 1), " × $",
                  DoubleToString(g_initialImpulseSize, 2), " initial)");
            LogBasketClose("StructuralInvalidation");
            CloseAllBasketPositions("Survival_StructuralInvalidation");
            ResetBasketState();
            return;
        }
    }

    // --- 3. ATR Expansion Guard (v0.2 NEW) ---
    //     If ATR(M1) re-expands to ATRExpansionExitFactor × expansion ATR
    //     AND velocity re-accelerates → new impulse forming, exit immediately
    if(g_expansionATR > 0)
    {
        double currentATR = GetCurrentATR_M1();
        if(currentATR > ATRExpansionExitFactor * g_expansionATR && g_reAccelFlag)
        {
            Print("!!! SURVIVAL: ATR EXPANSION GUARD | ATR: ", DoubleToString(currentATR, 4),
                  " > ", DoubleToString(ATRExpansionExitFactor, 1), " × ", DoubleToString(g_expansionATR, 4),
                  " + re-acceleration");
            LogBasketClose("ATRExpansionGuard");
            CloseAllBasketPositions("Survival_ATRExpansionGuard");
            ResetBasketState();
            return;
        }
    }

    // --- 4. Time Stop ---
    if(g_basketEntryTime > 0)
    {
        int elapsedMin = (int)((TimeCurrent() - g_basketEntryTime) / 60);
        if(elapsedMin >= TimeStopMinutes)
        {
            Print("!!! SURVIVAL: TIME STOP | ", elapsedMin, " min >= ", TimeStopMinutes, " min",
                  " | Float: $", DoubleToString(g_basketFloatingPL, 2));
            LogBasketClose("TimeStop");
            CloseAllBasketPositions("Survival_TimeStop");
            ResetBasketState();
            return;
        }
    }

    // --- 5. Re-acceleration Exit (velocity resumes during active fade) ---
    if(g_currentRegime == REGIME_ACTIVE_FADE && g_reAccelFlag)
    {
        Print("!!! SURVIVAL: RE-ACCELERATION | v_fast: ", DoubleToString(g_vFast, 6),
              " >= ", DoubleToString(ReAccelerationRatio, 2), " × peak ", DoubleToString(g_peakVFast, 6));
        LogBasketClose("AccelerationResumed");
        CloseAllBasketPositions("Survival_AccelResumed");
        ResetBasketState();
        return;
    }

    // --- 6. Profit Target (BE ± ProfitHarvestRatio × InitialImpulseSize) ---
    // --- v0.2.1 PATCH 1: use frozen g_initialImpulseSize for harvest offset ---
    if(g_initialImpulseSize > 0)
    {
        double be = BasketBreakEvenPrice();
        if(be > 0)
        {
            double targetOffset = ProfitHarvestRatio * g_initialImpulseSize;
            if(targetOffset < 0.10) targetOffset = 0.10; // Floor: $0.10 minimum

            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            bool targetHit = false;

            if(g_fadeDirection == BASKET_LONG)
                targetHit = (bid >= be + targetOffset);
            else if(g_fadeDirection == BASKET_SHORT)
                targetHit = (ask <= be - targetOffset);

            if(targetHit)
            {
                Print(">>> PROFIT TARGET HIT <<<");
                Print("    BE:          ", DoubleToString(be, 2));
                Print("    Offset:      $", DoubleToString(targetOffset, 2),
                      " (", DoubleToString(ProfitHarvestRatio, 2), " × $",
                      DoubleToString(g_initialImpulseSize, 2), " initial)");
                Print("    Float:       $", DoubleToString(g_basketFloatingPL, 2));
                Print("    Levels:      ", g_currentLevel);
                LogBasketClose("ProfitTarget");
                CloseAllBasketPositions("ProfitTarget");
                ResetBasketState();
                return;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| SECTION 12 — LOGGING                                            |
//+------------------------------------------------------------------+

void LogBasketClose(string reason)
{
    Print("========== BASKET CLOSE ==========");
    Print("  Reason:       ", reason);
    Print("  Float:        $", DoubleToString(g_basketFloatingPL, 2));
    Print("  Levels:       ", g_currentLevel, " | Lots: ", DoubleToString(g_totalLotsOpen, 2));
    Print("  Direction:    ", g_fadeDirection == BASKET_LONG ? "LONG" :
                              (g_fadeDirection == BASKET_SHORT ? "SHORT" : "NONE"));
    Print("  ImpulseSize:  $", DoubleToString(g_impulseSize, 2));
    if(g_basketEntryTime > 0)
        Print("  Duration:     ", (int)((TimeCurrent() - g_basketEntryTime) / 60), " min");
    Print("  BE:           ", DoubleToString(BasketBreakEvenPrice(), 2));
    Print("  v_fast:       ", DoubleToString(g_vFast, 6),
          " | peak: ", DoubleToString(g_peakVFast, 6));
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
    nyDt.min  = 0;
    nyDt.sec  = 0;
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
        g_currentNYDate     = nyDate;
        g_dailyStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
        g_dailyRealizedPL   = 0.0;
        g_dailyLossHit      = false;
        g_tradingDisabled    = false;
        g_disableReason      = "";

        TransitionRegime(REGIME_NEUTRAL);

        // Reset ATR rolling buffer for fresh day
        ArrayInitialize(g_atrRollingBuffer, 0.0);
        g_atrRollingIdx   = 0;
        g_atrRollingCount = 0;
        g_rollingATRMean  = 0.0;

        Print("==============================================");
        Print(">>> VC NEW NY DAY – All limits reset");
        Print("    NY Date: ", TimeToString(nyDate, TIME_DATE));
        Print("    Equity:  $", DoubleToString(g_dailyStartEquity, 2));
        Print("==============================================");
    }
}

void CheckDailyRisk()
{
    if(g_dailyRealizedPL <= -DailyLossCap_USD)
    {
        if(!g_dailyLossHit)
        {
            g_dailyLossHit    = true;
            g_tradingDisabled = true;
            g_disableReason   = "DAILY LOSS CAP";

            Print("!!! VC DAILY LOSS CAP | Realized: $", DoubleToString(g_dailyRealizedPL, 2));

            if(BasketHasPositions())
            {
                LogBasketClose("DailyLossCap");
                CloseAllBasketPositions("DailyLossCap");
                ResetBasketState();
            }
        }
    }

    if(g_dailyRealizedPL >= DailyProfitTarget_USD)
    {
        if(!g_tradingDisabled || g_disableReason != "DAILY TARGET")
        {
            g_tradingDisabled = true;
            g_disableReason   = "DAILY TARGET";

            Print(">>> VC DAILY TARGET | Realized: $", DoubleToString(g_dailyRealizedPL, 2));

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
                            Print(">>> VC DEAL | Profit: $", DoubleToString(profit, 2),
                                  " | Daily: $", DoubleToString(g_dailyRealizedPL, 2));
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| SECTION 15 — DEBUG VISUAL OVERLAY PANEL                          |
//+------------------------------------------------------------------+

#define VC_PREFIX  "VC2_"
#define VC_PANEL_X 10
#define VC_PANEL_Y 25
#define VC_PANEL_W 360
#define VC_FONT    "Segoe UI"
#define VC_FONT_B  "Segoe UI Semibold"
#define VC_FONT_SZ 9

#define VC_CLR_HEADER   C'10,25,50'
#define VC_CLR_SECTION  C'20,40,70'
#define VC_CLR_CONTENT  C'8,15,30'
#define VC_CLR_SEP      C'40,60,100'
#define VC_CLR_LABEL    C'140,160,190'
#define VC_CLR_VALUE    C'220,230,245'

void CreatePanel()
{
    ObjectsDeleteAll(0, VC_PREFIX);

    int y = VC_PANEL_Y;
    int rh = 22;
    int pad = 12;
    int valX = VC_PANEL_X + 140;

    // --- Header ---
    PanelBox(VC_PREFIX + "hdr", VC_PANEL_X, y, VC_PANEL_W, 50, VC_CLR_HEADER);
    PanelLabel(VC_PREFIX + "title", VC_PANEL_X + pad, y + 6, "VOL COMPRESSOR", clrWhite, 14, "Arial Black");
    PanelLabel(VC_PREFIX + "ver", VC_PANEL_X + 260, y + 10, "v0.2 PHYSICS", C'80,180,255', 10, VC_FONT_B);
    PanelLabel(VC_PREFIX + "time", VC_PANEL_X + pad, y + 30, "", C'100,120,150', 8, VC_FONT);
    y += 55;

    // --- Regime Section ---
    PanelBox(VC_PREFIX + "regSec", VC_PANEL_X, y, VC_PANEL_W, 24, VC_CLR_SECTION);
    PanelLabel(VC_PREFIX + "regSecT", VC_PANEL_X + pad, y + 4, "◈ IMPULSE PHYSICS + REGIME", clrWhite, 10, VC_FONT_B);
    y += 28;

    PanelBox(VC_PREFIX + "regBG", VC_PANEL_X, y, VC_PANEL_W, rh * 7 + 10, VC_CLR_CONTENT);
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

    PanelLabel(VC_PREFIX + "baseL", VC_PANEL_X + pad, cy, "v_baseline:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "baseV", valX, cy, "", VC_CLR_VALUE, VC_FONT_SZ, VC_FONT_B);
    cy += rh;

    PanelLabel(VC_PREFIX + "atrL", VC_PANEL_X + pad, cy, "ATR ratio:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "atrV", valX, cy, "", VC_CLR_VALUE, VC_FONT_SZ, VC_FONT_B);
    cy += rh;

    PanelLabel(VC_PREFIX + "vetoL", VC_PANEL_X + pad, cy, "TrendVeto:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "vetoV", valX, cy, "", VC_CLR_VALUE, VC_FONT_SZ, VC_FONT_B);

    y += rh * 7 + 14;

    // --- Basket Section ---
    PanelBox(VC_PREFIX + "bskSec", VC_PANEL_X, y, VC_PANEL_W, 24, VC_CLR_SECTION);
    PanelLabel(VC_PREFIX + "bskSecT", VC_PANEL_X + pad, y + 4, "◈ BASKET STATUS", clrWhite, 10, VC_FONT_B);
    y += 28;

    PanelBox(VC_PREFIX + "bskBG", VC_PANEL_X, y, VC_PANEL_W, rh * 6 + 10, VC_CLR_CONTENT);
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

    PanelLabel(VC_PREFIX + "beL", VC_PANEL_X + pad, cy, "Break-Even:", VC_CLR_LABEL, VC_FONT_SZ, VC_FONT);
    PanelLabel(VC_PREFIX + "beV", valX, cy, "", VC_CLR_VALUE, VC_FONT_SZ, VC_FONT_B);
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
    // --- Time bar ---
    ObjectSetString(0, VC_PREFIX + "time", OBJPROP_TEXT,
        TimeToString(GetNewYorkTime(), TIME_DATE|TIME_MINUTES) + " NY | " +
        _Symbol + " | Magic:" + IntegerToString(CompressorMagic));

    // --- Regime ---
    string regText = RegimeToString(g_currentRegime);
    color regClr = clrGray;
    switch(g_currentRegime)
    {
        case REGIME_NEUTRAL:              regClr = clrGray;       break;
        case REGIME_TREND_EXPANSION:      regClr = C'80,180,255'; break;
        case REGIME_TREND_DECELERATION:   regClr = clrOrange;     break;
        case REGIME_EXHAUSTION_WINDOW:    regClr = clrYellow;     break;
        case REGIME_ACTIVE_FADE:          regClr = clrLime;       break;
        case REGIME_DISABLED:             regClr = clrRed;        break;
    }
    ObjectSetString(0, VC_PREFIX + "regV", OBJPROP_TEXT, regText);
    ObjectSetInteger(0, VC_PREFIX + "regV", OBJPROP_COLOR, regClr);

    // --- Impulse ---
    string impDir = g_impulseDirection == BASKET_LONG ? "UP" :
                    (g_impulseDirection == BASKET_SHORT ? "DOWN" : "---");
    ObjectSetString(0, VC_PREFIX + "impV", OBJPROP_TEXT,
        impDir + " $" + DoubleToString(g_impulseSize, 2));
    ObjectSetInteger(0, VC_PREFIX + "impV", OBJPROP_COLOR,
        g_impulseSize >= MinImpulseDisplacement_USD ? clrYellow : VC_CLR_VALUE);

    // --- v_fast ---
    ObjectSetString(0, VC_PREFIX + "vfV", OBJPROP_TEXT, DoubleToString(g_vFast, 4));
    ObjectSetInteger(0, VC_PREFIX + "vfV", OBJPROP_COLOR,
        (g_peakVFast > 0 && g_vFast <= VFastDecayRatio * g_peakVFast) ? clrOrange : clrLime);

    // --- peak v_fast ---
    ObjectSetString(0, VC_PREFIX + "pvfV", OBJPROP_TEXT, DoubleToString(g_peakVFast, 4));

    // --- velocity baseline ---
    ObjectSetString(0, VC_PREFIX + "baseV", OBJPROP_TEXT, DoubleToString(g_dynamicVelocityBaseline, 4));
    ObjectSetInteger(0, VC_PREFIX + "baseV", OBJPROP_COLOR,
        (g_vFast > g_dynamicVelocityBaseline && g_dynamicVelocityBaseline > 0) ? clrLime : clrGray);

    // --- ATR ratio (current / rolling mean) ---
    double currentATR = GetCurrentATR_M1();
    string atrText = "---";
    color atrClr = clrGray;
    if(g_rollingATRMean > 0)
    {
        double ratio = currentATR / g_rollingATRMean;
        atrText = DoubleToString(ratio, 2) + "x (need " + DoubleToString(ExpansionFactor, 1) + "x)";
        atrClr = (ratio >= ExpansionFactor) ? clrLime : clrGray;
    }
    ObjectSetString(0, VC_PREFIX + "atrV", OBJPROP_TEXT, atrText);
    ObjectSetInteger(0, VC_PREFIX + "atrV", OBJPROP_COLOR, atrClr);

    // --- Veto ---
    string vetoText = "";
    color vetoClr = clrGray;
    if(longEntryAllowed && shortEntryAllowed)
    {
        vetoText = "BOTH (anomaly)";
        vetoClr = clrRed;
    }
    else if(longEntryAllowed)
    {
        vetoText = "LONG (blocks SELL fade)";
        vetoClr = clrOrange;
    }
    else if(shortEntryAllowed)
    {
        vetoText = "SHORT (blocks BUY fade)";
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

    // --- Break-even price ---
    string beText = "---";
    color beClr = clrGray;
    if(hasPos)
    {
        double be = BasketBreakEvenPrice();
        if(be > 0)
        {
            // --- v0.2.1 PATCH 1: display uses frozen initial size ---
            double targetOffset = (g_initialImpulseSize > 0) ? ProfitHarvestRatio * g_initialImpulseSize : 0.0;
            if(targetOffset < 0.10) targetOffset = 0.10;
            double targetPrice = (g_fadeDirection == BASKET_LONG) ? be + targetOffset : be - targetOffset;
            beText = DoubleToString(be, 2) + " → " + DoubleToString(targetPrice, 2);
            beClr = C'100,200,255';
        }
    }
    ObjectSetString(0, VC_PREFIX + "beV", OBJPROP_TEXT, beText);
    ObjectSetInteger(0, VC_PREFIX + "beV", OBJPROP_COLOR, beClr);

    // --- Floating PL ---
    string fltText = hasPos ? "$" + DoubleToString(g_basketFloatingPL, 2) : "---";
    color fltClr = hasPos ? (g_basketFloatingPL >= 0 ? clrLime : clrRed) : clrGray;
    ObjectSetString(0, VC_PREFIX + "fltV", OBJPROP_TEXT, fltText);
    ObjectSetInteger(0, VC_PREFIX + "fltV", OBJPROP_COLOR, fltClr);

    // --- Daily realized ---
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
//| END OF FILE — VolatilityCompressorEA_v0_2.mq5                   |
//+------------------------------------------------------------------+
