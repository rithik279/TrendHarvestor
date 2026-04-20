//+------------------------------------------------------------------+
//|                                      TrendPermissionEA_v4_5.mq5  |
//|           Modular Pullback Batch Engine – Execution DNA           |
//|                                                      Version 4.5 |
//+------------------------------------------------------------------+
#property copyright "TrendPermission"
#property version   "4.50"
#property description "Modular Pullback Batch Execution Engine – Account 433140219 DNA"
#property description "External trend permission interface + hardcoded lot ladder"
#property description "Weighted-average break-even TP + equity-based circuit breakers"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "01. Grid Engine"
input double InpGridSpacingPips     = 12.0;    // Grid spacing between levels (pips)
input double InpDuplicateGuardPips  = 1.0;     // Min pip distance to prevent duplicate adds
input int    InpMaxLevels           = 10;      // Maximum grid levels (hard cap)

input group "02. Exit / Break-Even TP"
input double InpBEProfitPips        = 3.0;     // Profit buffer above break-even (pips)
input double InpBEProfitUSD         = 50.0;    // Profit buffer above break-even ($)
input double InpSpreadBufferPips    = 2.0;     // Spread buffer added to BE price (pips)
input bool   InpUsePipsBE          = false;     // true = pips buffer, false = USD buffer

input group "03. Circuit Breakers"
input double InpMaxDDPercent        = 5.0;     // Max equity drawdown % (of balance)
input double InpMaxFloatingLossUSD  = 500.0;   // Max floating loss absolute ($)
input double InpMaxAdversePips      = 80.0;    // Max adverse distance from weighted avg (pips)
input int    InpMaxBasketHours      = 24;      // Max basket duration (hours, 0 = disabled)
input int    InpCooldownMinutes     = 15;      // Cooldown after circuit breaker (minutes)

input group "04. Execution Safety"
input double InpMaxSpreadPips       = 5.0;     // Max allowed spread for entry (pips)
input int    InpSlippagePoints      = 30;      // Max slippage (points)
input int    InpMagicNumber         = 450000;  // Magic number

input group "05. General"
input bool   InpDebug               = true;    // Enable debug logging

//+------------------------------------------------------------------+
//| DEFINES                                                           |
//+------------------------------------------------------------------+
#define DIR_NONE   0
#define DIR_LONG   1
#define DIR_SHORT -1

#define MAX_LEVELS 10

//+------------------------------------------------------------------+
//| STRUCTS                                                           |
//+------------------------------------------------------------------+
struct BasketStats
{
    int      levelCount;       // Number of open positions in basket
    double   totalLots;        // Sum of all position lots
    double   avgOpenPrice;     // Lot-weighted average open price
    double   totalProfitUSD;   // Sum of all open position floating P&L
    double   topProfitUSD;     // Profit of the LATEST (most recent) position
    ulong    topTicket;        // Ticket of the latest position (by POSITION_TIME)
    datetime oldestOpenTime;   // Earliest position open time (for time stop)
};

//+------------------------------------------------------------------+
//| ENGINE STATE MACHINE                                              |
//+------------------------------------------------------------------+
enum ENUM_ENGINE_STATE
{
    STATE_IDLE,             // No basket, waiting for permission
    STATE_BASKET_ACTIVE,    // Basket running, managing adds/exits
    STATE_COOLDOWN          // Post-circuit-breaker pause
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade g_trade;

// === Fixed DNA Lot Ladder (hardcoded, no multiplier drift) ===
double g_lotLevels[MAX_LEVELS] =
{
    0.07, 0.11, 0.17, 0.26, 0.39,
    0.59, 0.89, 1.34, 2.01, 3.02
};

// === Engine State ===
ENUM_ENGINE_STATE g_state = STATE_IDLE;
int    g_basketDir        = DIR_NONE;
int    g_currentLevel     = 0;
double g_lastEntryPrice   = 0.0;
bool   g_permissionFrozen = false;   // True when permission flipped during active basket

// === Cooldown ===
datetime g_cooldownUntil  = 0;

// === Anti-Spam: one entry attempt per tick ===
datetime g_lastTickTime   = 0;

// === Daily P&L Tracking ===
double   g_dailyRealizedPL = 0.0;
datetime g_currentDayStart = 0;

//+------------------------------------------------------------------+
//| TREND PERMISSION INTERFACE (EXTERNAL PLUG-IN POINT)              |
//|                                                                   |
//| Replace these stub functions with your actual trend filter.       |
//| The engine calls AllowBuy() / AllowSell() each tick.             |
//| Contract:                                                         |
//|   - Exactly one may return true at a time, or both false          |
//|   - Never return both true simultaneously                         |
//|   - Engine guarantees: one basket direction at a time             |
//+------------------------------------------------------------------+

//--- STUB: Always allows buy (replace with your trend logic) --------
bool AllowBuy()
{
    // ==========================================
    // INTEGRATION POINT: Replace this function
    // body with your trend filter logic.
    //
    // Example integration with EMA-based filter:
    //   return (emaFastSlope > 0 && emaSlowSlope > 0 && isBullRegime);
    //
    // For testing: returns true so buy baskets can form.
    // ==========================================
    return true;
}

//--- STUB: Always allows sell (replace with your trend logic) -------
bool AllowSell()
{
    // ==========================================
    // INTEGRATION POINT: Replace this function
    // body with your trend filter logic.
    //
    // Example integration with EMA-based filter:
    //   return (emaFastSlope < 0 && emaSlowSlope < 0 && isBearRegime);
    //
    // For testing: returns true so sell baskets can form.
    // WARNING: If both AllowBuy() and AllowSell() return true,
    // the engine takes the first signal (buy priority).
    // ==========================================
    return false;
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
    // Symbol validation — allow XAUUSD variants
    string sym = _Symbol;
    if(StringFind(sym, "XAUUSD") < 0 && StringFind(sym, "xauusd") < 0 &&
       StringFind(sym, "GOLD") < 0   && StringFind(sym, "gold") < 0)
    {
        Print("WARNING: EA designed for XAUUSD. Current symbol: ", _Symbol);
    }

    // Trade object setup
    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetDeviationInPoints(InpSlippagePoints);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);

    // Reset state
    g_state            = STATE_IDLE;
    g_basketDir        = DIR_NONE;
    g_currentLevel     = 0;
    g_lastEntryPrice   = 0.0;
    g_permissionFrozen = false;
    g_cooldownUntil    = 0;
    g_lastTickTime     = 0;
    g_dailyRealizedPL  = 0.0;
    g_currentDayStart  = GetDayStart();

    // Recover basket from previous session (if EA restarted)
    RecoverBasketState();

    // Create display panel
    CreatePanel();

    // Log initialization
    Print("==============================================");
    Print("TrendPermissionEA v4.5 – Modular Batch Execution Engine");
    Print("Symbol: ", _Symbol, " | TF: ", EnumToString(_Period));
    Print("----------------------------------------------");
    Print("Architecture: External Trend Permission Interface");
    Print("AllowBuy()/AllowSell() → plug your filter here");
    Print("----------------------------------------------");
    Print("HARDCODED DNA LOT LADDER (Account 433140219):");
    double totalExposure = 0.0;
    for(int i = 0; i < MAX_LEVELS; i++)
    {
        totalExposure += g_lotLevels[i];
        Print("  L", i, ": ", DoubleToString(g_lotLevels[i], 2), " lots");
    }
    Print("  Total exposure (full ladder): ", DoubleToString(totalExposure, 2), " lots");
    Print("----------------------------------------------");
    Print("Grid Spacing: ", DoubleToString(InpGridSpacingPips, 1), " pips ($",
          DoubleToString(PipsToPrice(InpGridSpacingPips), 2), ")");
    Print("BE Buffer: ", InpUsePipsBE ?
        DoubleToString(InpBEProfitPips, 1) + " pips" :
        "$" + DoubleToString(InpBEProfitUSD, 2));
    Print("Spread Buffer: ", DoubleToString(InpSpreadBufferPips, 1), " pips");
    Print("----------------------------------------------");
    Print("CIRCUIT BREAKERS:");
    Print("  Max DD%: ", DoubleToString(InpMaxDDPercent, 1), "%");
    Print("  Max Float Loss: $", DoubleToString(InpMaxFloatingLossUSD, 2));
    Print("  Max Adverse: ", DoubleToString(InpMaxAdversePips, 1), " pips");
    Print("  Max Duration: ", InpMaxBasketHours > 0 ?
        IntegerToString(InpMaxBasketHours) + " hours" : "DISABLED");
    Print("  Cooldown: ", InpCooldownMinutes, " min");
    Print("  Max Spread: ", DoubleToString(InpMaxSpreadPips, 1), " pips");
    Print("==============================================");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    DeletePanel();
    Comment("");
    Print("v4.5 deinitialized. Reason: ", reason,
          " | Daily Realized: $", DoubleToString(g_dailyRealizedPL, 2));
}

//+------------------------------------------------------------------+
//| OnTradeTransaction – SINGLE SOURCE OF TRUTH for realized P&L     |
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
                    long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
                    if(magic == InpMagicNumber)
                    {
                        double profit     = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
                        double commission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
                        double swap       = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
                        double netPL      = profit + commission + swap;

                        g_dailyRealizedPL += netPL;

                        if(InpDebug)
                            Print(">>> DEAL CLOSED | Gross: $", DoubleToString(profit, 2),
                                  " | Comm: $", DoubleToString(commission, 2),
                                  " | Swap: $", DoubleToString(swap, 2),
                                  " | Net: $", DoubleToString(netPL, 2),
                                  " | Daily: $", DoubleToString(g_dailyRealizedPL, 2));
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| OnTick – State Machine Router                                    |
//+------------------------------------------------------------------+
void OnTick()
{
    CheckDayReset();
    UpdatePanel();

    // Anti-spam: only one engine pass per unique server time
    datetime serverTime = TimeCurrent();
    if(serverTime == g_lastTickTime)
        return;
    g_lastTickTime = serverTime;

    // ═══════════════════════════════════════════
    //  STATE MACHINE – Core execution flow
    // ═══════════════════════════════════════════
    switch(g_state)
    {
        case STATE_COOLDOWN:
            if(!CooldownActive())
                TransitionTo(STATE_IDLE);
            break;

        case STATE_IDLE:
            EngineIdle();
            break;

        case STATE_BASKET_ACTIVE:
            EngineBasketActive();
            break;
    }
}

//+------------------------------------------------------------------+
//| TransitionTo – Clean state transition with logging               |
//+------------------------------------------------------------------+
void TransitionTo(ENUM_ENGINE_STATE newState)
{
    if(InpDebug)
        Print(">>> STATE: ", EnumToStateString(g_state), " → ", EnumToStateString(newState));
    g_state = newState;
}

string EnumToStateString(ENUM_ENGINE_STATE s)
{
    switch(s)
    {
        case STATE_IDLE:           return "IDLE";
        case STATE_BASKET_ACTIVE:  return "BASKET_ACTIVE";
        case STATE_COOLDOWN:       return "COOLDOWN";
    }
    return "UNKNOWN";
}

//+------------------------------------------------------------------+
//| EngineIdle – No basket active. Check permission, start basket.   |
//+------------------------------------------------------------------+
void EngineIdle()
{
    if(!SpreadOK()) return;

    bool canBuy  = AllowBuy();
    bool canSell = AllowSell();

    // Safety: never both — if stub error, buy takes priority
    if(canBuy && canSell) canSell = false;

    if(canBuy)
    {
        TryStartBasket(DIR_LONG);
    }
    else if(canSell)
    {
        TryStartBasket(DIR_SHORT);
    }
}

//+------------------------------------------------------------------+
//| EngineBasketActive – Manage circuit breakers, exits, adds        |
//+------------------------------------------------------------------+
void EngineBasketActive()
{
    BasketStats stats;
    ComputeBasketStats(stats);

    // Sync level count with live positions
    g_currentLevel = stats.levelCount;

    // Externally closed → reset
    if(stats.levelCount == 0)
    {
        if(InpDebug) Print(">>> Basket empty (external close). Resetting.");
        ResetBasketState();
        TransitionTo(STATE_IDLE);
        return;
    }

    // === CIRCUIT BREAKERS (highest priority) ===
    if(CircuitBreaker(stats))
        return;

    // === CHECK PERMISSION FLIP ===
    // If trend permission reverses while basket active:
    //   → Freeze new adds, let existing basket manage to exit
    CheckPermissionFlip();

    // === BREAK-EVEN EXIT CHECK ===
    if(ShouldCloseBasket(stats))
    {
        if(InpDebug)
        {
            Print("==============================================");
            Print(">>> BASKET EXIT – BREAK-EVEN TARGET REACHED");
            Print("    Direction: ", (g_basketDir == DIR_LONG ? "LONG" : "SHORT"));
            Print("    Levels: ", stats.levelCount,
                  " | Total Lots: ", DoubleToString(stats.totalLots, 2));
            Print("    Weighted Avg Open: ", DoubleToString(stats.avgOpenPrice, _Digits));
            Print("    Basket P&L: $", DoubleToString(stats.totalProfitUSD, 2));
            Print("==============================================");
        }
        CloseBasket("BE_TargetReached");
        return;
    }

    // === ADD NEXT GRID LEVEL (if spread OK and permission not frozen) ===
    if(!g_permissionFrozen && SpreadOK())
        TryAddLevel();
}

//+------------------------------------------------------------------+
//| CheckPermissionFlip – Detect if trend reversed during basket     |
//|                                                                   |
//| Rules:                                                            |
//|   - If long basket active and AllowBuy() becomes false → freeze  |
//|   - If short basket active and AllowSell() becomes false → freeze|
//|   - Frozen = no new adds, but basket continues to exit logic     |
//+------------------------------------------------------------------+
void CheckPermissionFlip()
{
    if(g_permissionFrozen) return;   // Already frozen

    if(g_basketDir == DIR_LONG && !AllowBuy())
    {
        g_permissionFrozen = true;
        if(InpDebug)
            Print(">>> PERMISSION FLIP: AllowBuy() → false while LONG basket active. Adds frozen.");
    }
    else if(g_basketDir == DIR_SHORT && !AllowSell())
    {
        g_permissionFrozen = true;
        if(InpDebug)
            Print(">>> PERMISSION FLIP: AllowSell() → false while SHORT basket active. Adds frozen.");
    }
}

//+------------------------------------------------------------------+
//| TryStartBasket – Open Level 0 position                           |
//|                                                                   |
//| Pure execution — no candle assumptions.                           |
//| Simply opens the first position in the requested direction.       |
//+------------------------------------------------------------------+
void TryStartBasket(int direction)
{
    if(g_basketDir != DIR_NONE) return;

    double lot = g_lotLevels[0];

    if(direction == DIR_LONG)
    {
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        if(g_trade.Buy(lot, _Symbol, ask, 0, 0, "v4.5_L0_BUY"))
        {
            g_basketDir        = DIR_LONG;
            g_currentLevel     = 1;
            g_lastEntryPrice   = ask;
            g_permissionFrozen = false;

            TransitionTo(STATE_BASKET_ACTIVE);

            if(InpDebug)
                Print(">>> BASKET START BUY L0 | Lot: ", DoubleToString(lot, 2),
                      " | Entry: ", DoubleToString(ask, _Digits));
        }
        else
        {
            Print("!!! BASKET START BUY FAILED | Error: ", GetLastError());
        }
    }
    else if(direction == DIR_SHORT)
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        if(g_trade.Sell(lot, _Symbol, bid, 0, 0, "v4.5_L0_SELL"))
        {
            g_basketDir        = DIR_SHORT;
            g_currentLevel     = 1;
            g_lastEntryPrice   = bid;
            g_permissionFrozen = false;

            TransitionTo(STATE_BASKET_ACTIVE);

            if(InpDebug)
                Print(">>> BASKET START SELL L0 | Lot: ", DoubleToString(lot, 2),
                      " | Entry: ", DoubleToString(bid, _Digits));
        }
        else
        {
            Print("!!! BASKET START SELL FAILED | Error: ", GetLastError());
        }
    }
}

//+------------------------------------------------------------------+
//| TryAddLevel – Add next grid level when price moves AGAINST       |
//|                                                                   |
//| LONG basket: buy  when Bid <= lastEntry - GridSpacing             |
//| SHORT basket: sell when Ask >= lastEntry + GridSpacing            |
//| No delay. No wick confirmation. Tick-based. Rapid-fire.          |
//+------------------------------------------------------------------+
void TryAddLevel()
{
    if(g_basketDir == DIR_NONE)        return;
    if(g_currentLevel >= InpMaxLevels) return;
    if(g_currentLevel >= MAX_LEVELS)   return;   // Hard safety
    if(g_lastEntryPrice == 0.0)        return;

    double gridDist  = PipsToPrice(InpGridSpacingPips);
    double guardDist = PipsToPrice(InpDuplicateGuardPips);

    if(g_basketDir == DIR_LONG)
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        // Price must drop below last entry by at least grid spacing
        if(bid <= g_lastEntryPrice - gridDist)
        {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

            // Duplicate guard
            if(IsTooCloseToExisting(ask, guardDist))
                return;

            double lot = g_lotLevels[g_currentLevel];

            if(g_trade.Buy(lot, _Symbol, ask, 0, 0,
                           "v4.5_L" + IntegerToString(g_currentLevel) + "_BUY"))
            {
                double prevEntry = g_lastEntryPrice;
                g_lastEntryPrice = ask;
                g_currentLevel++;

                if(InpDebug)
                    Print(">>> GRID ADD BUY L", g_currentLevel - 1,
                          " | Lot: ", DoubleToString(lot, 2),
                          " | Price: ", DoubleToString(ask, _Digits),
                          " | Gap: ", DoubleToString(PriceToPips(prevEntry - ask), 1), " pips",
                          " | Levels: ", g_currentLevel, "/", InpMaxLevels);
            }
            else
            {
                Print("!!! GRID ADD BUY FAILED L", g_currentLevel, " | Error: ", GetLastError());
            }
        }
    }
    else if(g_basketDir == DIR_SHORT)
    {
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        // Price must rise above last entry by at least grid spacing
        if(ask >= g_lastEntryPrice + gridDist)
        {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

            // Duplicate guard
            if(IsTooCloseToExisting(bid, guardDist))
                return;

            double lot = g_lotLevels[g_currentLevel];

            if(g_trade.Sell(lot, _Symbol, bid, 0, 0,
                            "v4.5_L" + IntegerToString(g_currentLevel) + "_SELL"))
            {
                double prevEntry = g_lastEntryPrice;
                g_lastEntryPrice = bid;
                g_currentLevel++;

                if(InpDebug)
                    Print(">>> GRID ADD SELL L", g_currentLevel - 1,
                          " | Lot: ", DoubleToString(lot, 2),
                          " | Price: ", DoubleToString(bid, _Digits),
                          " | Gap: ", DoubleToString(PriceToPips(bid - prevEntry), 1), " pips",
                          " | Levels: ", g_currentLevel, "/", InpMaxLevels);
            }
            else
            {
                Print("!!! GRID ADD SELL FAILED L", g_currentLevel, " | Error: ", GetLastError());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| IsTooCloseToExisting – Duplicate guard against all open positions |
//+------------------------------------------------------------------+
bool IsTooCloseToExisting(double proposedPrice, double guardDist)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        if(MathAbs(proposedPrice - openPrice) < guardDist)
        {
            if(InpDebug)
                Print(">>> DUPLICATE GUARD: proposed ", DoubleToString(proposedPrice, _Digits),
                      " too close to existing ", DoubleToString(openPrice, _Digits));
            return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| ComputeBasketStats – MANDATORY basket accounting                  |
//|                                                                   |
//| Computes:                                                         |
//|   totalLots      = Σ(lot)                                        |
//|   avgOpenPrice   = Σ(lot × price) / Σ(lot)                      |
//|   totalProfitUSD = Σ(POSITION_PROFIT)                            |
//|   topTicket / topProfitUSD = latest position by POSITION_TIME    |
//|   oldestOpenTime = earliest position open time                   |
//+------------------------------------------------------------------+
void ComputeBasketStats(BasketStats &stats)
{
    stats.levelCount     = 0;
    stats.totalLots      = 0.0;
    stats.avgOpenPrice   = 0.0;
    stats.totalProfitUSD = 0.0;
    stats.topProfitUSD   = 0.0;
    stats.topTicket      = 0;
    stats.oldestOpenTime = D'2099.12.31';

    double sumLotPrice   = 0.0;
    datetime latestTime  = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        double   lots   = PositionGetDouble(POSITION_VOLUME);
        double   price  = PositionGetDouble(POSITION_PRICE_OPEN);
        double   profit = PositionGetDouble(POSITION_PROFIT);
        datetime oTime  = (datetime)PositionGetInteger(POSITION_TIME);

        stats.levelCount++;
        stats.totalLots      += lots;
        sumLotPrice          += lots * price;
        stats.totalProfitUSD += profit;

        // Latest position (most recently opened)
        if(oTime > latestTime)
        {
            latestTime         = oTime;
            stats.topProfitUSD = profit;
            stats.topTicket    = ticket;
        }

        // Earliest position
        if(oTime < stats.oldestOpenTime)
            stats.oldestOpenTime = oTime;
    }

    // Weighted average open price
    if(stats.totalLots > 0.0)
        stats.avgOpenPrice = sumLotPrice / stats.totalLots;
}

//+------------------------------------------------------------------+
//| ShouldCloseBasket – Basket Break-Even TP with configurable buffer|
//|                                                                   |
//| Formula:                                                          |
//|   WeightedAvgPrice = Σ(entry_price × lot) / Σ(lot)              |
//|                                                                   |
//| For BUY basket:                                                   |
//|   TP_Price = WeightedAvgPrice + SpreadBuffer + ProfitBuffer      |
//|   Close when Bid >= TP_Price                                      |
//|                                                                   |
//| For SELL basket:                                                  |
//|   TP_Price = WeightedAvgPrice - SpreadBuffer - ProfitBuffer      |
//|   Close when Ask <= TP_Price                                      |
//|                                                                   |
//| ProfitBuffer can be pips-based or USD-based:                      |
//|   Pips mode: ProfitBuffer = InpBEProfitPips in price             |
//|   USD mode:  Convert InpBEProfitUSD to price distance:           |
//|     priceDist = InpBEProfitUSD / (totalLots × contractSize × 1)  |
//+------------------------------------------------------------------+
bool ShouldCloseBasket(BasketStats &stats)
{
    if(stats.levelCount == 0) return false;

    double spreadBuffer = PipsToPrice(InpSpreadBufferPips);
    double profitBuffer = 0.0;

    if(InpUsePipsBE)
    {
        // Pips-based profit buffer
        profitBuffer = PipsToPrice(InpBEProfitPips);
    }
    else
    {
        // USD-based profit buffer → convert to price distance
        // For XAUUSD: 1 lot = 100 oz, $1 price move = $100 per lot
        // PriceDistance = USD / (totalLots × tickValue / tickSize)
        double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

        if(tickValue > 0 && tickSize > 0 && stats.totalLots > 0)
            profitBuffer = (InpBEProfitUSD * tickSize) / (stats.totalLots * tickValue);
        else
            profitBuffer = PipsToPrice(InpBEProfitPips);  // Fallback to pips
    }

    if(g_basketDir == DIR_LONG)
    {
        double tpPrice = stats.avgOpenPrice + spreadBuffer + profitBuffer;
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        if(bid >= tpPrice)
        {
            if(InpDebug)
                Print(">>> BE EXIT LONG: Bid ", DoubleToString(bid, _Digits),
                      " >= TP ", DoubleToString(tpPrice, _Digits),
                      " (Avg: ", DoubleToString(stats.avgOpenPrice, _Digits),
                      " + Spread: ", DoubleToString(spreadBuffer, _Digits),
                      " + Profit: ", DoubleToString(profitBuffer, _Digits), ")");
            return true;
        }
    }
    else if(g_basketDir == DIR_SHORT)
    {
        double tpPrice = stats.avgOpenPrice - spreadBuffer - profitBuffer;
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        if(ask <= tpPrice)
        {
            if(InpDebug)
                Print(">>> BE EXIT SHORT: Ask ", DoubleToString(ask, _Digits),
                      " <= TP ", DoubleToString(tpPrice, _Digits),
                      " (Avg: ", DoubleToString(stats.avgOpenPrice, _Digits),
                      " - Spread: ", DoubleToString(spreadBuffer, _Digits),
                      " - Profit: ", DoubleToString(profitBuffer, _Digits), ")");
            return true;
        }
    }

    return false;
}

//+------------------------------------------------------------------+
//| CloseBasket – Close all positions belonging to this EA            |
//+------------------------------------------------------------------+
void CloseBasket(string reason)
{
    int closed = 0;
    double totalProfit = 0.0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        double profit = PositionGetDouble(POSITION_PROFIT);

        if(g_trade.PositionClose(ticket))
        {
            totalProfit += profit;
            closed++;
        }
        else
        {
            Print("!!! CLOSE FAILED ticket ", ticket, " | Error: ", GetLastError());
        }
    }

    if(InpDebug)
        Print(">>> BASKET CLOSED | Reason: ", reason,
              " | Positions: ", closed,
              " | Gross P&L: $", DoubleToString(totalProfit, 2));

    ResetBasketState();
}

//+------------------------------------------------------------------+
//| CircuitBreaker – Multi-layer emergency protection                |
//|                                                                   |
//| BREAKER A: Equity Drawdown % (account-based)                     |
//| BREAKER B: Max Floating Loss (absolute USD)                      |
//| BREAKER C: Max Adverse Distance from weighted avg                |
//| BREAKER D: Max Levels + Deep Negative (75% of max loss)          |
//| BREAKER E: Time Stop (optional basket duration limit)            |
//+------------------------------------------------------------------+
bool CircuitBreaker(BasketStats &stats)
{
    if(stats.levelCount == 0) return false;

    // === BREAKER A: Equity Drawdown % ===
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

    if(balance > 0)
    {
        double ddPercent = ((balance - equity) / balance) * 100.0;

        if(ddPercent >= InpMaxDDPercent)
        {
            Print("!!! CIRCUIT BREAKER A: MAX EQUITY DRAWDOWN !!!");
            Print("    DD%: ", DoubleToString(ddPercent, 2),
                  "% >= limit ", DoubleToString(InpMaxDDPercent, 1), "%");
            Print("    Balance: $", DoubleToString(balance, 2),
                  " | Equity: $", DoubleToString(equity, 2));

            CloseBasket("CB_MaxDD%");
            ActivateCooldown();
            TransitionTo(STATE_COOLDOWN);
            return true;
        }
    }

    // === BREAKER B: Max Floating Loss (absolute USD) ===
    if(stats.totalProfitUSD <= -InpMaxFloatingLossUSD)
    {
        Print("!!! CIRCUIT BREAKER B: MAX FLOATING LOSS !!!");
        Print("    Float P&L: $", DoubleToString(stats.totalProfitUSD, 2),
              " <= -$", DoubleToString(InpMaxFloatingLossUSD, 2));
        Print("    Levels: ", stats.levelCount,
              " | Total Lots: ", DoubleToString(stats.totalLots, 2));

        CloseBasket("CB_MaxFloatLoss");
        ActivateCooldown();
        TransitionTo(STATE_COOLDOWN);
        return true;
    }

    // === BREAKER C: Max Adverse Distance from weighted avg ===
    double adverseDistance = 0.0;

    if(g_basketDir == DIR_LONG)
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        adverseDistance = stats.avgOpenPrice - bid;
    }
    else if(g_basketDir == DIR_SHORT)
    {
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        adverseDistance = ask - stats.avgOpenPrice;
    }

    double maxAdversePrice = PipsToPrice(InpMaxAdversePips);

    if(adverseDistance > maxAdversePrice)
    {
        Print("!!! CIRCUIT BREAKER C: MAX ADVERSE DISTANCE !!!");
        Print("    Adverse: ", DoubleToString(PriceToPips(adverseDistance), 1),
              " pips > limit ", DoubleToString(InpMaxAdversePips, 1), " pips");
        Print("    Avg Price: ", DoubleToString(stats.avgOpenPrice, _Digits));
        Print("    Levels: ", stats.levelCount,
              " | Float P&L: $", DoubleToString(stats.totalProfitUSD, 2));

        CloseBasket("CB_MaxAdverse");
        ActivateCooldown();
        TransitionTo(STATE_COOLDOWN);
        return true;
    }

    // === BREAKER D: Level Cap Emergency ===
    if(stats.levelCount >= InpMaxLevels &&
       stats.totalProfitUSD <= -(InpMaxFloatingLossUSD * 0.75))
    {
        Print("!!! CIRCUIT BREAKER D: MAX LEVELS + DEEP LOSS !!!");
        Print("    Levels: ", stats.levelCount, " (MAX)");
        Print("    Float P&L: $", DoubleToString(stats.totalProfitUSD, 2),
              " <= -$", DoubleToString(InpMaxFloatingLossUSD * 0.75, 2), " (75% threshold)");

        CloseBasket("CB_MaxLevelsDeepLoss");
        ActivateCooldown();
        TransitionTo(STATE_COOLDOWN);
        return true;
    }

    // === BREAKER E: Time Stop (optional) ===
    if(InpMaxBasketHours > 0)
    {
        int elapsedSec = (int)(TimeCurrent() - stats.oldestOpenTime);
        int maxSec     = InpMaxBasketHours * 3600;

        if(elapsedSec >= maxSec)
        {
            double hours = elapsedSec / 3600.0;
            Print("!!! CIRCUIT BREAKER E: TIME STOP !!!");
            Print("    Duration: ", DoubleToString(hours, 1), " hours >= limit ",
                  InpMaxBasketHours, " hours");
            Print("    Levels: ", stats.levelCount,
                  " | Float P&L: $", DoubleToString(stats.totalProfitUSD, 2));

            CloseBasket("CB_TimeStop");
            ActivateCooldown();
            TransitionTo(STATE_COOLDOWN);
            return true;
        }
    }

    return false;
}

//+------------------------------------------------------------------+
//| ResetBasketState – Clear all basket tracking variables            |
//+------------------------------------------------------------------+
void ResetBasketState()
{
    g_basketDir        = DIR_NONE;
    g_currentLevel     = 0;
    g_lastEntryPrice   = 0.0;
    g_permissionFrozen = false;

    if(g_state == STATE_BASKET_ACTIVE)
        TransitionTo(STATE_IDLE);

    if(InpDebug)
        Print(">>> BASKET STATE RESET");
}

//+------------------------------------------------------------------+
//| RecoverBasketState – Detect positions from previous EA session    |
//+------------------------------------------------------------------+
void RecoverBasketState()
{
    BasketStats stats;
    ComputeBasketStats(stats);

    if(stats.levelCount == 0)
    {
        ResetBasketState();
        return;
    }

    // Determine direction from existing positions
    bool hasLong = false, hasShort = false;
    double latestPrice = 0.0;
    datetime latestTime = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        datetime ptime = (datetime)PositionGetInteger(POSITION_TIME);
        double pprice  = PositionGetDouble(POSITION_PRICE_OPEN);

        if(ptype == POSITION_TYPE_BUY)  hasLong  = true;
        if(ptype == POSITION_TYPE_SELL) hasShort = true;

        if(ptime > latestTime)
        {
            latestTime  = ptime;
            latestPrice = pprice;
        }
    }

    // Mixed directions = invalid state → close all
    if(hasLong && hasShort)
    {
        Print("!!! RECOVERY: Mixed LONG/SHORT positions. Closing all.");
        CloseBasket("Recovery_MixedDirections");
        return;
    }

    if(hasLong)       g_basketDir = DIR_LONG;
    else if(hasShort) g_basketDir = DIR_SHORT;

    g_currentLevel     = stats.levelCount;
    g_lastEntryPrice   = latestPrice;
    g_permissionFrozen = false;
    g_state            = STATE_BASKET_ACTIVE;

    Print(">>> BASKET RECOVERED",
          " | Dir: ", (g_basketDir == DIR_LONG ? "LONG" : "SHORT"),
          " | Levels: ", g_currentLevel,
          " | Avg: ", DoubleToString(stats.avgOpenPrice, _Digits),
          " | LastEntry: ", DoubleToString(g_lastEntryPrice, _Digits),
          " | Float: $", DoubleToString(stats.totalProfitUSD, 2));
}

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| NormalizeLot – Floor to broker lot step, clamp to min/max        |
//+------------------------------------------------------------------+
double NormalizeLot(double rawLot)
{
    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    if(lotStep <= 0) lotStep = 0.01;

    double lots = MathFloor(rawLot / lotStep) * lotStep;

    if(lots < minLot) lots = minLot;
    if(lots > maxLot) lots = maxLot;

    return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| PipsToPrice – Convert pips to price distance                     |
//|                                                                   |
//| Gold  (_Digits==2): 1 pip = 0.10                                 |
//| Gold  (_Digits==3): 1 pip = 0.10                                 |
//| Forex (_Digits==4): 1 pip = 0.0001                               |
//| Forex (_Digits==5): 1 pip = 0.0001                               |
//+------------------------------------------------------------------+
double PipsToPrice(double pips)
{
    double pipSize;

    if(_Digits <= 3)
        pipSize = (_Digits == 2) ? _Point * 10.0 : _Point * 100.0;
    else
        pipSize = (_Digits == 4) ? _Point : _Point * 10.0;

    return pips * pipSize;
}

//+------------------------------------------------------------------+
//| PriceToPips – Inverse conversion                                 |
//+------------------------------------------------------------------+
double PriceToPips(double priceDistance)
{
    double onePip = PipsToPrice(1.0);
    if(onePip == 0.0) return 0.0;
    return priceDistance / onePip;
}

//+------------------------------------------------------------------+
//| SpreadOK – Gate entries on excessive spread                      |
//+------------------------------------------------------------------+
bool SpreadOK()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadPips = PriceToPips(ask - bid);
    return (spreadPips <= InpMaxSpreadPips);
}

//+------------------------------------------------------------------+
//| CooldownActive – True if circuit breaker cooldown is running     |
//+------------------------------------------------------------------+
bool CooldownActive()
{
    if(g_cooldownUntil == 0) return false;

    if(TimeCurrent() < g_cooldownUntil)
        return true;

    g_cooldownUntil = 0;
    if(InpDebug) Print(">>> Cooldown expired. Trading re-enabled.");
    return false;
}

//+------------------------------------------------------------------+
//| ActivateCooldown                                                  |
//+------------------------------------------------------------------+
void ActivateCooldown()
{
    g_cooldownUntil = TimeCurrent() + InpCooldownMinutes * 60;

    if(InpDebug)
        Print("!!! COOLDOWN ACTIVATED for ", InpCooldownMinutes,
              " min | Expires: ", TimeToString(g_cooldownUntil, TIME_MINUTES));
}

//+------------------------------------------------------------------+
//| GetDayStart – Midnight of current server day                     |
//+------------------------------------------------------------------+
datetime GetDayStart()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    dt.hour = 0;
    dt.min  = 0;
    dt.sec  = 0;
    return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| CheckDayReset – Reset daily P&L on new day                       |
//+------------------------------------------------------------------+
void CheckDayReset()
{
    datetime dayStart = GetDayStart();
    if(dayStart != g_currentDayStart)
    {
        g_currentDayStart = dayStart;
        g_dailyRealizedPL = 0.0;
        if(InpDebug)
            Print(">>> NEW DAY | Daily Realized P&L reset to $0.00");
    }
}

//+------------------------------------------------------------------+
//|                                                                   |
//| ██████╗  █████╗ ███╗   ██╗███████╗██╗                            |
//| ██╔══██╗██╔══██╗████╗  ██║██╔════╝██║                            |
//| ██████╔╝███████║██╔██╗ ██║█████╗  ██║                            |
//| ██╔═══╝ ██╔══██║██║╚██╗██║██╔══╝  ██║                            |
//| ██║     ██║  ██║██║ ╚████║███████╗███████╗                       |
//| ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝                       |
//|                                                                   |
//+------------------------------------------------------------------+

#define PNL_X        10
#define PNL_Y        25
#define PNL_W        420
#define PNL_FONT     "Segoe UI"
#define PNL_FONT_B   "Segoe UI Semibold"
#define PNL_FS       10
#define PFX          "v45_"

#define C_HDR_BG     C'15,25,45'
#define C_SEC_BG     C'25,40,65'
#define C_CON_BG     C'10,18,32'
#define C_SEP        C'40,60,90'
#define C_LBL        C'140,160,180'
#define C_VAL        C'220,230,240'

//+------------------------------------------------------------------+
void PanelBox(string n, int x, int y, int w, int h, color c)
{
    if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
    ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
    ObjectSetInteger(0, n, OBJPROP_BGCOLOR, c);
    ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, n, OBJPROP_COLOR, c);
    ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, n, OBJPROP_BACK, false);
    ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
}

void PanelLabel(string n, int x, int y, string txt, color c, int fs, string f)
{
    if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
    ObjectSetString(0, n, OBJPROP_TEXT, txt);
    ObjectSetInteger(0, n, OBJPROP_COLOR, c);
    ObjectSetInteger(0, n, OBJPROP_FONTSIZE, fs);
    ObjectSetString(0, n, OBJPROP_FONT, f);
    ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, n, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
    ObjectSetInteger(0, n, OBJPROP_BACK, false);
    ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| CreatePanel                                                       |
//+------------------------------------------------------------------+
void CreatePanel()
{
    ObjectsDeleteAll(0, PFX);

    int y   = PNL_Y;
    int rh  = 26;
    int pad = 15;
    int vx  = PNL_X + 180;

    // ─── Header ────────────────────────────────────────
    PanelBox(PFX + "HdrBG", PNL_X, y, PNL_W, 65, C_HDR_BG);
    PanelLabel(PFX + "Title", PNL_X + pad, y + 10, "BATCH ENGINE", clrWhite, 16, "Arial Black");
    PanelLabel(PFX + "Ver", PNL_X + 310, y + 14, "v4.5", C'100,180,255', 12, PNL_FONT_B);
    PanelLabel(PFX + "Time", PNL_X + pad, y + 40, "", C'100,140,180', PNL_FS, PNL_FONT);
    y += 70;

    // ─── Permission Section ────────────────────────────
    PanelBox(PFX + "PermSec", PNL_X, y, PNL_W, 30, C_SEC_BG);
    PanelLabel(PFX + "PermSecT", PNL_X + pad, y + 6, "◈ TREND PERMISSION", clrWhite, 11, PNL_FONT_B);
    y += 35;

    int permH = 10 + 3 * rh + 10;
    PanelBox(PFX + "PermCon", PNL_X, y, PNL_W, permH, C_CON_BG);
    int cy = y + 10;

    PanelLabel(PFX + "PermBuyL", PNL_X + pad, cy, "AllowBuy():", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "PermBuyV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    cy += rh;
    PanelLabel(PFX + "PermSellL", PNL_X + pad, cy, "AllowSell():", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "PermSellV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    cy += rh;
    PanelLabel(PFX + "FrozenL", PNL_X + pad, cy, "Permission:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "FrozenV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    y += permH + 5;

    // ─── Basket Status Section ─────────────────────────
    PanelBox(PFX + "BskSec", PNL_X, y, PNL_W, 30, C_SEC_BG);
    PanelLabel(PFX + "BskSecT", PNL_X + pad, y + 6, "◈ BASKET STATUS", clrWhite, 11, PNL_FONT_B);
    y += 35;

    int bskH = 10 + 10 * rh + 12 + 10;
    PanelBox(PFX + "BskCon", PNL_X, y, PNL_W, bskH, C_CON_BG);
    cy = y + 10;

    PanelLabel(PFX + "StateL", PNL_X + pad, cy, "Engine State:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "StateV", vx, cy, "", clrLime, 11, PNL_FONT_B);
    cy += rh;

    PanelLabel(PFX + "DirL", PNL_X + pad, cy, "Direction:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "DirV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    cy += rh;

    PanelLabel(PFX + "LevelsL", PNL_X + pad, cy, "Levels:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "LevelsV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    cy += rh;

    PanelLabel(PFX + "AvgL", PNL_X + pad, cy, "Weighted Avg Price:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "AvgV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    cy += rh;

    PanelLabel(PFX + "BEL", PNL_X + pad, cy, "BE Target Price:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "BEV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    cy += rh;

    PanelLabel(PFX + "FloatL", PNL_X + pad, cy, "Basket Float P&L:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "FloatV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    cy += rh;

    PanelLabel(PFX + "LotsL", PNL_X + pad, cy, "Total Lots:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "LotsV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    cy += rh;

    PanelLabel(PFX + "NextL", PNL_X + pad, cy, "Next Add Price:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "NextV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    cy += rh;

    PanelLabel(PFX + "DurL", PNL_X + pad, cy, "Duration:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "DurV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    cy += rh;

    PanelBox(PFX + "Sep1", PNL_X + pad, cy, PNL_W - 30, 1, C_SEP);
    cy += 12;

    PanelLabel(PFX + "DailyL", PNL_X + pad, cy, "Daily Realized:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "DailyV", vx, cy, "", C_VAL, 11, PNL_FONT_B);

    y += bskH + 5;

    // ─── Circuit Breakers Section ──────────────────────
    PanelBox(PFX + "CBSec", PNL_X, y, PNL_W, 30, C_SEC_BG);
    PanelLabel(PFX + "CBSecT", PNL_X + pad, y + 6, "◈ CIRCUIT BREAKERS", clrWhite, 11, PNL_FONT_B);
    y += 35;

    int cbH = 10 + 4 * rh + 10;
    PanelBox(PFX + "CBCon", PNL_X, y, PNL_W, cbH, C_CON_BG);
    cy = y + 10;

    PanelLabel(PFX + "DDL", PNL_X + pad, cy, "Equity DD%:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "DDV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    cy += rh;

    PanelLabel(PFX + "SpreadL", PNL_X + pad, cy, "Spread:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "SpreadV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    cy += rh;

    PanelLabel(PFX + "AdvL", PNL_X + pad, cy, "Adverse Distance:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "AdvV", vx, cy, "", C_VAL, 11, PNL_FONT_B);
    cy += rh;

    PanelLabel(PFX + "CoolL", PNL_X + pad, cy, "Cooldown:", C_LBL, PNL_FS, PNL_FONT);
    PanelLabel(PFX + "CoolV", vx, cy, "", C_VAL, 11, PNL_FONT_B);

    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| UpdatePanel                                                       |
//+------------------------------------------------------------------+
void UpdatePanel()
{
    int vx = PNL_X + 180;

    ObjectSetString(0, PFX + "Time", OBJPROP_TEXT,
        "⏱ " + TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + "  " + _Symbol);

    BasketStats stats;
    ComputeBasketStats(stats);

    // --- Permission ---
    bool cb = AllowBuy(), cs = AllowSell();
    ObjectSetString(0, PFX + "PermBuyV", OBJPROP_TEXT, cb ? "● TRUE" : "○ FALSE");
    ObjectSetInteger(0, PFX + "PermBuyV", OBJPROP_COLOR, cb ? clrLime : clrGray);
    ObjectSetString(0, PFX + "PermSellV", OBJPROP_TEXT, cs ? "● TRUE" : "○ FALSE");
    ObjectSetInteger(0, PFX + "PermSellV", OBJPROP_COLOR, cs ? clrRed : clrGray);
    ObjectSetString(0, PFX + "FrozenV", OBJPROP_TEXT,
        g_permissionFrozen ? "⚠ FROZEN (flip during basket)" : "● ACTIVE");
    ObjectSetInteger(0, PFX + "FrozenV", OBJPROP_COLOR,
        g_permissionFrozen ? clrOrange : clrLime);

    // --- Engine State ---
    ObjectSetString(0, PFX + "StateV", OBJPROP_TEXT, EnumToStateString(g_state));
    color stateClr = (g_state == STATE_BASKET_ACTIVE) ? clrLime :
                     (g_state == STATE_COOLDOWN) ? clrOrange : clrGray;
    ObjectSetInteger(0, PFX + "StateV", OBJPROP_COLOR, stateClr);

    // --- Direction ---
    string dirTxt = "○ NONE";
    color  dirClr = clrGray;
    if(g_basketDir == DIR_LONG)       { dirTxt = "▲ LONG";  dirClr = clrLime; }
    else if(g_basketDir == DIR_SHORT) { dirTxt = "▼ SHORT"; dirClr = clrRed; }
    ObjectSetString(0, PFX + "DirV", OBJPROP_TEXT, dirTxt);
    ObjectSetInteger(0, PFX + "DirV", OBJPROP_COLOR, dirClr);

    // --- Levels ---
    ObjectSetString(0, PFX + "LevelsV", OBJPROP_TEXT,
        IntegerToString(stats.levelCount) + " / " + IntegerToString(InpMaxLevels));
    ObjectSetInteger(0, PFX + "LevelsV", OBJPROP_COLOR,
        (stats.levelCount >= InpMaxLevels) ? clrRed : (stats.levelCount > 0 ? C_VAL : clrGray));

    // --- Weighted Avg Price ---
    ObjectSetString(0, PFX + "AvgV", OBJPROP_TEXT,
        stats.levelCount > 0 ? DoubleToString(stats.avgOpenPrice, _Digits) : "—");

    // --- BE Target Price ---
    string beTxt = "—";
    color  beClr = clrGray;
    if(stats.levelCount > 0 && stats.totalLots > 0)
    {
        double spreadBuf = PipsToPrice(InpSpreadBufferPips);
        double profitBuf = 0.0;
        if(InpUsePipsBE)
        {
            profitBuf = PipsToPrice(InpBEProfitPips);
        }
        else
        {
            double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
            double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
            if(tv > 0 && ts > 0)
                profitBuf = (InpBEProfitUSD * ts) / (stats.totalLots * tv);
        }

        double bePrice = (g_basketDir == DIR_LONG) ?
            stats.avgOpenPrice + spreadBuf + profitBuf :
            stats.avgOpenPrice - spreadBuf - profitBuf;
        beTxt = DoubleToString(bePrice, _Digits);
        beClr = C'100,180,255';
    }
    ObjectSetString(0, PFX + "BEV", OBJPROP_TEXT, beTxt);
    ObjectSetInteger(0, PFX + "BEV", OBJPROP_COLOR, beClr);

    // --- Basket Float P&L ---
    string fTxt = stats.levelCount > 0 ? "$" + DoubleToString(stats.totalProfitUSD, 2) : "—";
    color  fClr = (stats.levelCount == 0) ? clrGray : (stats.totalProfitUSD >= 0 ? clrLime : clrRed);
    ObjectSetString(0, PFX + "FloatV", OBJPROP_TEXT, fTxt);
    ObjectSetInteger(0, PFX + "FloatV", OBJPROP_COLOR, fClr);

    // --- Total Lots ---
    ObjectSetString(0, PFX + "LotsV", OBJPROP_TEXT,
        stats.levelCount > 0 ? DoubleToString(stats.totalLots, 2) : "—");

    // --- Next Add Price ---
    string nextTxt = "—";
    color  nextClr = clrGray;
    if(g_basketDir != DIR_NONE && g_lastEntryPrice > 0 && g_currentLevel < InpMaxLevels)
    {
        if(g_permissionFrozen)
        {
            nextTxt = "FROZEN (perm flip)";
            nextClr = clrOrange;
        }
        else
        {
            double gd = PipsToPrice(InpGridSpacingPips);
            double np = (g_basketDir == DIR_LONG) ? g_lastEntryPrice - gd : g_lastEntryPrice + gd;
            int nextIdx = MathMin(g_currentLevel, MAX_LEVELS - 1);
            nextTxt = DoubleToString(np, _Digits) +
                      " (L" + IntegerToString(g_currentLevel) +
                      " @ " + DoubleToString(g_lotLevels[nextIdx], 2) + ")";
            nextClr = C'100,180,255';
        }
    }
    else if(g_currentLevel >= InpMaxLevels)
    {
        nextTxt = "MAX LEVELS REACHED";
        nextClr = clrRed;
    }
    ObjectSetString(0, PFX + "NextV", OBJPROP_TEXT, nextTxt);
    ObjectSetInteger(0, PFX + "NextV", OBJPROP_COLOR, nextClr);

    // --- Duration ---
    string durTxt = "—";
    color  durClr = clrGray;
    if(stats.levelCount > 0)
    {
        int elapsed = (int)(TimeCurrent() - stats.oldestOpenTime);
        int hrs = elapsed / 3600;
        int mns = (elapsed % 3600) / 60;
        durTxt = IntegerToString(hrs) + "h " + IntegerToString(mns) + "m";
        if(InpMaxBasketHours > 0)
        {
            durTxt += " / " + IntegerToString(InpMaxBasketHours) + "h";
            double pct = (double)elapsed / (InpMaxBasketHours * 3600.0);
            durClr = (pct > 0.75) ? clrRed : (pct > 0.5) ? clrOrange : clrLime;
        }
        else
        {
            durClr = C_VAL;
        }
    }
    ObjectSetString(0, PFX + "DurV", OBJPROP_TEXT, durTxt);
    ObjectSetInteger(0, PFX + "DurV", OBJPROP_COLOR, durClr);

    // --- Daily Realized ---
    ObjectSetString(0, PFX + "DailyV", OBJPROP_TEXT, "$" + DoubleToString(g_dailyRealizedPL, 2));
    ObjectSetInteger(0, PFX + "DailyV", OBJPROP_COLOR, g_dailyRealizedPL >= 0 ? clrLime : clrRed);

    // --- Equity DD% ---
    double bal = AccountInfoDouble(ACCOUNT_BALANCE);
    double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
    double dd  = (bal > 0) ? ((bal - eq) / bal) * 100.0 : 0.0;
    ObjectSetString(0, PFX + "DDV", OBJPROP_TEXT,
        DoubleToString(dd, 2) + "% / " + DoubleToString(InpMaxDDPercent, 1) + "%");
    ObjectSetInteger(0, PFX + "DDV", OBJPROP_COLOR,
        (dd >= InpMaxDDPercent * 0.75) ? clrRed : (dd >= InpMaxDDPercent * 0.5) ? clrOrange : clrLime);

    // --- Spread ---
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spPips = PriceToPips(ask - bid);
    ObjectSetString(0, PFX + "SpreadV", OBJPROP_TEXT,
        DoubleToString(spPips, 1) + " / " + DoubleToString(InpMaxSpreadPips, 1) + " pips");
    ObjectSetInteger(0, PFX + "SpreadV", OBJPROP_COLOR,
        (spPips <= InpMaxSpreadPips) ? clrLime : clrRed);

    // --- Adverse Distance ---
    string aTxt = "—";
    color  aClr = clrGray;
    if(stats.levelCount > 0 && stats.avgOpenPrice > 0)
    {
        double ad = 0.0;
        if(g_basketDir == DIR_LONG)        ad = stats.avgOpenPrice - bid;
        else if(g_basketDir == DIR_SHORT)  ad = ask - stats.avgOpenPrice;
        double adPips = PriceToPips(MathMax(ad, 0.0));
        aTxt = DoubleToString(adPips, 1) + " / " + DoubleToString(InpMaxAdversePips, 1) + " pips";
        aClr = (adPips > InpMaxAdversePips * 0.75) ? clrRed :
               (adPips > InpMaxAdversePips * 0.5) ? clrOrange : clrLime;
    }
    ObjectSetString(0, PFX + "AdvV", OBJPROP_TEXT, aTxt);
    ObjectSetInteger(0, PFX + "AdvV", OBJPROP_COLOR, aClr);

    // --- Cooldown ---
    if(g_cooldownUntil > 0 && TimeCurrent() < g_cooldownUntil)
    {
        int rem = (int)(g_cooldownUntil - TimeCurrent());
        ObjectSetString(0, PFX + "CoolV", OBJPROP_TEXT,
            IntegerToString(rem / 60) + "m " + IntegerToString(rem % 60) + "s");
        ObjectSetInteger(0, PFX + "CoolV", OBJPROP_COLOR, clrOrange);
    }
    else
    {
        ObjectSetString(0, PFX + "CoolV", OBJPROP_TEXT, "○ CLEAR");
        ObjectSetInteger(0, PFX + "CoolV", OBJPROP_COLOR, clrLime);
    }

    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| DeletePanel                                                       |
//+------------------------------------------------------------------+
void DeletePanel()
{
    ObjectsDeleteAll(0, PFX);
}
//+------------------------------------------------------------------+
