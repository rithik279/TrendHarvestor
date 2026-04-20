//+------------------------------------------------------------------+
//|                                        TrendPermissionEA_v3_6.mq5 |
//|                        Layer 0 Risk Governor + Execution Layer    |
//|                                                       Version 3.6 |
//+------------------------------------------------------------------+
#property copyright "TrendPermission"
#property version   "3.6"
#property description "Force Flip on Opposite Permission Signal"

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
input double TakeProfitDollars  = 5.0;
input int    MagicNumber        = 123456;

input group "03. Debug"
input bool   EnableDebugPrints  = true;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES - LAYER 0: RISK GOVERNOR                        |
//+------------------------------------------------------------------+

// === Account-Level Daily Tracking (NY-based) ===
double dailyStartEquity;
double dailyRealizedPL;
bool   dailyLossLimitHit;
datetime currentNYDate;

// === Basket-Level Tracking ===
double basketFloatingPL;
double basketPeakFloatingPL;
bool   basketActive;
bool   profitProtectionActivated;

// === v3.6: Basket Direction Tracking ===
int basketDirection;  // 1 = LONG, -1 = SHORT, 0 = NONE
#define BASKET_NONE   0
#define BASKET_LONG   1
#define BASKET_SHORT -1

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
    Print("TrendPermissionEA_v3_6 initialized");
    Print("Symbol: ", _Symbol, " | Timeframe: M1");
    Print("----------------------------------------------");
    Print("LAYER 0 v3.6 - FORCE FLIP ON OPPOSITE PERMISSION");
    Print("Basket Stop Loss: $", BasketStopLoss_USD);
    Print("Daily Loss Limit: $", DailyLossLimit_USD);
    Print("Peak Giveback: ", PeakGivebackFrac * 100, "%");
    Print("NEW: If LONG basket + shortEntryAllowed → FORCE FLIP");
    Print("NEW: If SHORT basket + longEntryAllowed → FORCE FLIP");
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
    basketActive = false;
    profitProtectionActivated = false;
    basketDirection = BASKET_NONE;  // v3.6
    
    disableReason = "";
    tradingDisabled = false;
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
//| v3.6: Check for Force Flip Condition                             |
//+------------------------------------------------------------------+
bool CheckForceFlip()
{
    // Only check if we have an active basket
    if(!basketActive || basketDirection == BASKET_NONE)
        return false;
    
    // FORCE FLIP: LONG basket + shortEntryAllowed
    if(basketDirection == BASKET_LONG && shortEntryAllowed)
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
    if(basketDirection == BASKET_SHORT && longEntryAllowed)
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
//| Layer 0: Main Risk Check                                         |
//+------------------------------------------------------------------+
void Layer0_RiskCheck()
{
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    CheckDayReset();
    
    // === PRIORITY 1: DAILY LOSS LIMIT ===
    double dailyPL = currentEquity - dailyStartEquity;
    
    if(dailyPL <= -DailyLossLimit_USD)
    {
        if(!dailyLossLimitHit)
        {
            dailyLossLimitHit = true;
            tradingDisabled = true;
            disableReason = "DAILY LOSS LIMIT HIT";
            
            Print("!!! LAYER 0: DAILY LOSS LIMIT HIT !!!");
            Print(">>> Daily P&L: $", DoubleToString(dailyPL, 2), " – Trading disabled for NY day");
            
            CloseAllPositions("Layer0_DailyLossLimit");
            ResetBasketState();
        }
        return;
    }
    
    // === CALCULATE BASKET FLOATING P&L ===
    basketFloatingPL = CalculateBasketFloatingPL();
    
    // === PRIORITY 2: BASKET STOP LOSS ===
    if(hasOpenPosition && basketActive)
    {
        if(basketFloatingPL <= -BasketStopLoss_USD)
        {
            Print("!!! LAYER 0: BASKET STOP HIT !!!");
            Print(">>> BASKET STOP: $", DoubleToString(basketFloatingPL, 2), " floating P&L");
            Print(">>> Basket Direction was: ", basketDirection == BASKET_LONG ? "LONG" : "SHORT");
            Print(">>> Basket closed, trading still enabled");
            
            CloseAllPositions("Layer0_BasketStop");
            ResetBasketState();
            
            disableReason = "BASKET STOP HIT (Ready)";
            return;
        }
        
        // === PRIORITY 3: PEAK PROFIT GIVEBACK ===
        basketPeakFloatingPL = MathMax(basketPeakFloatingPL, basketFloatingPL);
        
        if(basketPeakFloatingPL >= MinProfitToProtect_USD)
        {
            if(!profitProtectionActivated)
            {
                profitProtectionActivated = true;
                Print(">>> LAYER 0: PROFIT PROTECTION ACTIVATED");
                Print("    Basket Peak Floating P&L: $", DoubleToString(basketPeakFloatingPL, 2));
            }
            
            double givebackThreshold = basketPeakFloatingPL * (1.0 - PeakGivebackFrac);
            
            if(basketFloatingPL <= givebackThreshold)
            {
                Print("!!! LAYER 0: PEAK GIVEBACK LIMIT HIT !!!");
                Print("    Basket Peak: $", DoubleToString(basketPeakFloatingPL, 2));
                Print("    Current: $", DoubleToString(basketFloatingPL, 2));
                Print("    Threshold: $", DoubleToString(givebackThreshold, 2));
                Print("    Basket Direction was: ", basketDirection == BASKET_LONG ? "LONG" : "SHORT");
                
                CloseAllPositions("Layer0_PeakGiveback");
                ResetBasketState();
                
                disableReason = "PEAK GIVEBACK (Ready)";
            }
        }
    }
    
    // === DAILY PROFIT TARGET ===
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
        
        ResetBasketState();
        
        Print("==============================================");
        Print(">>> NEW NY DAY DETECTED – Daily limits reset");
        Print("NY Date: ", TimeToString(nyDate, TIME_DATE));
        Print("Daily Start Equity: $", DoubleToString(dailyStartEquity, 2));
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
    basketActive = false;
    profitProtectionActivated = false;
    basketDirection = BASKET_NONE;  // v3.6: Reset direction
    
    if(EnableDebugPrints)
        Print(">>> BASKET STATE RESET | Direction: NONE, Peak: $0.00, Active: false");
}

//+------------------------------------------------------------------+
//| Start New Basket                                                 |
//+------------------------------------------------------------------+
void StartNewBasket(int direction)
{
    basketFloatingPL = 0.0;
    basketPeakFloatingPL = 0.0;
    basketActive = true;
    profitProtectionActivated = false;
    basketDirection = direction;  // v3.6: Track direction
    
    string dirStr = direction == BASKET_LONG ? "LONG" : "SHORT";
    
    if(EnableDebugPrints)
        Print(">>> NEW BASKET STARTED | Direction: ", dirStr, " | Peak tracking begins at $0.00");
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
//| Track Realized P&L                                               |
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
    
    // === v3.6: FORCE FLIP CHECK (BEFORE STANDARD LOGIC) ===
    // This must run on every tick, not just on new bars
    if(CheckForceFlip())
    {
        // Force flip occurred - basket was closed, tradeTakenThisPermission was reset
        // The ExecuteTradeLogic below will enter the new direction
    }
    
    ManageTakeProfit();
    
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
        return false;
    
    if(CopyBuffer(handleEmaHigh, 0, 0, 3, ema200High) < 3 ||
       CopyBuffer(handleEmaLow, 0, 0, 3, ema200Low) < 3 ||
       CopyBuffer(handleEmaFast, 0, 0, 3, emaFast) < 3 ||
       CopyBuffer(handleEmaSlow, 0, 0, 3, emaSlow) < 3)
    {
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
    
    longEntryAllowed = isBullRegime && (emaSlowSlope > 0) && (emaFastSlope > 0) && 
                      accelUp && gapBull && gapWidening;
                      
    shortEntryAllowed = isBearRegime && (emaSlowSlope < 0) && (emaFastSlope < 0) && 
                       accelDown && gapBear && gapNarrowing;
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
                StartNewBasket(BASKET_LONG);  // v3.6: Track direction
            if(EnableDebugPrints)
                Print(">>> BUY TRADE OPENED");
        }
    }
    
    if(shortEntryAllowed)
    {
        if(OpenSellTrade())
        {
            tradeTakenThisPermission = true;
            if(!basketActive)
                StartNewBasket(BASKET_SHORT);  // v3.6: Track direction
            if(EnableDebugPrints)
                Print(">>> SELL TRADE OPENED");
        }
    }
}

bool OpenBuyTrade()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "TrendPerm_v3_6_BUY"))
        return true;
    Print("ERROR: Failed to open BUY trade. Error: ", GetLastError());
    return false;
}

bool OpenSellTrade()
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "TrendPerm_v3_6_SELL"))
        return true;
    Print("ERROR: Failed to open SELL trade. Error: ", GetLastError());
    return false;
}

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
        basketDirection = BASKET_NONE;  // v3.6: Reset direction
        if(!tradingDisabled && (disableReason == "BASKET STOP HIT (Ready)" || disableReason == "PEAK GIVEBACK (Ready)"))
            disableReason = "";
    }
}

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
//| Panel                                                            |
//+------------------------------------------------------------------+
#define PANEL_X           10
#define PANEL_Y           25
#define PANEL_WIDTH       360
#define PANEL_FONT        "Segoe UI"
#define PANEL_FONT_BOLD   "Segoe UI Semibold"
#define PANEL_FONT_SIZE   10
#define PREFIX            "TPv36_"

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
    CreateLabel(PREFIX + "Version", PANEL_X + 270, y + 14, "v3.6", C'100,180,255', 12, PANEL_FONT_BOLD);
    CreateLabel(PREFIX + "TimeSymbol", PANEL_X + padding, y + 40, "", C'100,140,180', PANEL_FONT_SIZE, PANEL_FONT);
    y += 70;
    
    CreateBox(PREFIX + "Layer0BG", PANEL_X, y, PANEL_WIDTH, 30, CLR_SECTION_BG);
    CreateLabel(PREFIX + "Layer0Title", PANEL_X + padding, y + 6, "◈ LAYER 0 - RISK GOVERNOR", clrWhite, 11, PANEL_FONT_BOLD);
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
    
    CreateLabel(PREFIX + "DailyLossLabel", PANEL_X + padding, contentY, "Daily P&L:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "DailyLossValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    CreateLabel(PREFIX + "BasketPLLabel", PANEL_X + padding, contentY, "Basket Float P&L:", CLR_LABEL, PANEL_FONT_SIZE, PANEL_FONT);
    CreateLabel(PREFIX + "BasketPLValue", valueX, contentY, "", CLR_VALUE, 11, PANEL_FONT_BOLD);
    contentY += rowHeight;
    
    // v3.6: Basket Direction row
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

void UpdatePanel()
{
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double floatingPL = currentEquity - currentBalance;
    double dailyPL = currentEquity - dailyStartEquity;
    
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
    
    string statusText = disableReason != "" ? disableReason : (basketActive ? "BASKET ACTIVE" : "READY");
    color statusColor = (disableReason == "DAILY LOSS LIMIT HIT") ? clrRed :
        (disableReason == "DAILY TARGET REACHED") ? clrGold :
        (disableReason != "") ? clrOrange : clrLime;
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
    
    // v3.6: Basket Direction
    string dirText;
    color dirColor;
    if(basketDirection == BASKET_LONG)
    {
        dirText = "▲ LONG BASKET";
        dirColor = clrLime;
    }
    else if(basketDirection == BASKET_SHORT)
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
    
    string basketPeakText = (!basketActive && !hasOpenPosition) ? "○ NO BASKET" :
        "$" + DoubleToString(basketPeakFloatingPL, 2);
    color basketPeakColor = (!basketActive && !hasOpenPosition) ? clrGray :
        (basketPeakFloatingPL >= MinProfitToProtect_USD ? clrLime : CLR_VALUE);
    ObjectSetString(0, PREFIX + "BasketPeakValue", OBJPROP_TEXT, basketPeakText);
    ObjectSetInteger(0, PREFIX + "BasketPeakValue", OBJPROP_COLOR, basketPeakColor);
    
    string protectText = !hasOpenPosition ? "○ NO POSITION" :
        profitProtectionActivated ? "● ACTIVE (peak >= $" + DoubleToString(MinProfitToProtect_USD, 2) + ")" :
        "○ INACTIVE (peak < $" + DoubleToString(MinProfitToProtect_USD, 2) + ")";
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
    Print("TrendPermissionEA_v3_6 deinitialized. Reason: ", reason);
    Print("Final Daily P&L: $", DoubleToString(dailyRealizedPL, 2));
}
