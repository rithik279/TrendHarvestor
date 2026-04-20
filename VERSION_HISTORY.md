# Trend Harvestor — Version History

**EA Name:** TrendPermissionEA (aka "Trend Harvestor")
**Symbol:** XAUUSD (Gold) — M1 Timeframe Only
**Platform:** MetaTrader 5 (MQL5)

---

## Table of Contents

| Version | Release Name | Core Feature |
|---------|-------------|--------------|
| [v1.0](#v10--trendpermissionea) | TrendPermissionEA | Trend detection only (no trading) |
| [v2.0](#v20--trendpermissionea_v2) | Bare-Bones Execution | First live execution layer |
| [v3.0](#v30--trendpermissionea_v3) | Layer 0 Risk Governor | Risk management introduced |
| [v3.1](#v31--trendpermissionea_v3_1) | MinProfit Threshold | Profit protection refinement |
| [v3.2](#v32--trendpermissionea_v3_2) | Redesigned Risk Governor | Basket + daily loss architecture |
| [v3.3](#v33--trendpermissionea_v3_3) | Floating P&L Basket | Basket risk via floating P&L |
| [v3.4](#v34--trendpermissionea_v3_4) | NY Midnight Reset | Daily reset to New York time |
| [v3.5](#v35--trendpermissionea_v3_5) | Clarified Peak Protection | Naming clarity + basket peak |
| [v3.6](#v36--trendpermissionea_v3_6) | Force Flip | Opposite-signal basket reversal |
| [v3.7](#v37--trendpermissionea_v3_7) | Correctness Patch | Derived state + realized P&L fix |
| [v3.8](#v38--trendpermissionea_v3_8) | Trend Gating Upgrade | Body clearance + ATR slope filter |
| [v3.9](#v39--trendpermissionea_v3_9) | Grid Pyramiding | Fixed grid adds + asymmetric basket TP |
| [v3.9.1](#v391--trendpermissionea_v3_9_1) | EMA30 Structural Exit | Early exit on broken trend structure |
| [v3.9.2](#v392--trendpermissionea_v3_9_2) | Permission Silence Exit | 5-bar silence rule basket exit |
| [v4.0](#v40--trendpermissionea_v4_0) | EMA10 Invalidation | Structural trend invalidation exit |
| [v4.1](#v41--trendpermissionea_v4_1) | Continuation Reentry | Immediate reentry after peak giveback |
| [v3.9.4](#v394--trendpermissionea_v3_9_4) | HTF ADX Regime Filter | Block new baskets in low-ADX regimes |
| [v3.9.5](#v395--trendpermissionea_v3_9_5) | ATR Extension Filter | Block overextended entries from EMA10 |
| [v3.9.6](#v396--trendpermissionea_v3_9_6) | Structural Failure Controls | MAE stop, time stop, expansion failure exit |
| [v3.9.7](#v397--trendpermissionea_v3_9_7) | Expansion Maximizer | Expansion-aware grid lot sizing + basket lot cap |
| [v4.5](#v45--trendpermissionea_v4_5) | Modular Batch Engine | Clean-room execution chassis with external permission |
| [v5.0.0](#v500--trendpermissionea_v5_0_0) | Stage 0+1 Scaffolding | Overlay engine skeleton + magic-parameterized utilities |
| [v5.0.1](#v501--trendpermissionea_v5_0_1) | Tick Microstructure | Impulse candle + tick exhaustion detection |
| [v5.0.2](#v502--trendpermissionea_v5_0_2) | Full Overlay Engine | Complete overlay grid execution + structural stop + profit target |
| [v5.0.3](#v503--trendpermissionea_v5_0_3) | Overlay Hardening | 8 patches — sync close, state integrity, risk sync |
| [v5.0.4](#v504--trendpermissionea_v5_0_4) | Unified Daily Risk | Merged overlay P&L into single daily budget |
| [v5.0.5](#v505--trendpermissionea_v5_0_5) | Decoupled Basket Floor | Independent basket profit floor trigger/level |
| [v5.0.6](#v506--trendpermissionea_v5_0_6) | Overlay Activation Gate | Overlay entry gated by floating loss threshold |
| [v5.0.7](#v507--trendpermissionea_v5_0_7) | Exposure Control | Block new trend entries while overlay active |
| [v5.0.8](#v508--trendpermissionea_v5_0_8) | Handle Caching | Indicator handle caching for stability |
| [v5.0.9](#v509--trendpermissionea_v5_0_9) | Structural Stop Hardening | Overlay stop uses fixed swing reference |
| [v5.0.10](#v5010--trendpermissionea_v5_0_10) | Final Sequencing | Execution reorder + derived overlayActive + cleanup |

---

## Architecture Overview

The EA is built in layered modules:

```
┌─────────────────────────────────────────────┐
│  LAYER 0 — Risk Governor (v3.0+)            │
│  Daily limits, basket stops, peak giveback   │
├─────────────────────────────────────────────┤
│  TREND PERMISSION MODULE (v1.0+, FROZEN)    │
│  EMA200 regime, EMA10/30 slopes, gap logic   │
├─────────────────────────────────────────────┤
│  EXECUTION LAYER (v2.0+)                    │
│  Entry, grid adds, continuation, force flip  │
├─────────────────────────────────────────────┤
│  OVERLAY ENGINE (v5.0.0+, compile-gated)    │
│  Counter-trend grid, structural stop,        │
│  impulse detection, tick exhaustion           │
├─────────────────────────────────────────────┤
│  PANEL / UI (v3.0+)                         │
│  On-chart display of all state variables     │
└─────────────────────────────────────────────┘
```

---

## v1.0 — TrendPermissionEA

**File:** `TrendPermissionEA.mq5`
**Description:** *"Entry Permission Regimes Detection - No Trading"*

### Purpose

The foundation. A direct translation from Pine Script v5 to MQL5. This version **does not trade** — it only detects trend entry permission regimes and prints debug output.

### Features

- **EMA200 High/Low Channel:** Determines bull/bear regime based on whether price closes above EMA200(High) or below EMA200(Low).
- **Fast EMA (10) / Slow EMA (30):** Used for slope, acceleration, and gap dynamics.
- **Entry Permission Logic:**
  - **LONG allowed** when: Bull regime + positive slopes + upward acceleration + bullish gap widening.
  - **SHORT allowed** when: Bear regime + negative slopes + downward acceleration + bearish gap narrowing.
- **Bar-by-bar processing** on M1 candle close only.
- Debug prints on permission transitions.

### Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `TrendEMA_Len` | 200 | Trend EMA length |
| `FastEMA_Len` | 10 | Fast EMA length |
| `SlowEMA_Len` | 30 | Slow EMA length |
| `EnableDebugPrints` | true | Enable debug output |

### What It Does NOT Do

- No trade execution
- No risk management
- No position management
- No panel/UI

---

## v2.0 — TrendPermissionEA_v2

**File:** `TrendPermissionEA_v2.mq5`
**Description:** *"Permission-Gated Execution EA - Validation Build"*

### What Changed

The trend permission module from v1.0 is **frozen** (locked, never modified again). A new execution layer is added on top.

### New Features

- **Trade Execution:** Opens BUY/SELL positions when permission fires.
- **One Trade Per Permission Window:** `tradeTakenThisPermission` flag prevents multiple entries within the same permission signal.
- **Per-Position Take Profit:** Dollar-based TP managed on every tick.
- **CTrade Integration:** Uses MQL5 `CTrade` class with magic number filtering.
- **IOC Order Filling:** `ORDER_FILLING_IOC` for partial fill handling.

### New Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `LotSize` | 0.01 | Fixed lot size per trade |
| `TakeProfitDollars` | 5.0 | Per-position TP in USD |
| `MagicNumber` | 123456 | EA magic number for position filtering |

### Architecture

```
OnTick()
  → CheckPositionStatus()
  → ManageTakeProfit()         ← NEW: tick-based TP management
  → [New Bar Gate]
    → UpdateTrendPermission()  ← FROZEN from v1.0
    → CheckPermissionTransitions()
    → ExecuteTradeLogic()      ← NEW: opens trades
```

---

## v3.0 — TrendPermissionEA_v3

**File:** `TrendPermissionEA_v3.mq5`
**Description:** *"Permission-Gated Execution with Layer 0 Risk Governor"*

### What Changed

Introduction of **Layer 0 — the Risk Governor**. This is the first version with any form of risk management.

### New Features

- **Account Drawdown Stop:** Stops trading if account equity drops by `MaxAccountDD_USD` from start equity.
- **Peak Equity Tracking:** Tracks peak equity since EA start.
- **Peak Giveback Protection:** If equity falls below `peakEquity * (1 - PeakGivebackFrac)`, closes all positions.
- **Daily Profit Target:** Stops trading for the day when realized profit reaches target.
- **Daily Session Reset:** Resets daily counters at broker midnight.
- **Close All Positions:** Utility function to close all EA positions.
- **On-Chart Panel:** First version of the UI dashboard with trading status, P&L, and permission state.

### New Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `MaxAccountDD_USD` | 20.0 | Max account drawdown from start |
| `PeakGivebackFrac` | 0.25 | Fraction of peak profit allowed to give back |
| `DailyProfitTarget` | 100.0 | Daily realized profit target |

### Risk Priority Order

1. Account drawdown limit
2. Peak giveback protection
3. Daily profit target

---

## v3.1 — TrendPermissionEA_v3_1

**File:** `TrendPermissionEA_v3_1.mq5`
**Description:** *"Permission-Gated Execution with Layer 0 Risk Governor"*

### What Changed

Small but important refinement to the peak giveback logic.

### New Features

- **MinProfitToProtect Threshold:** Peak giveback protection only activates **after** floating P&L exceeds a minimum threshold. This prevents premature exits on small profits.
- **`profitProtectionActivated` flag:** Tracks whether the minimum threshold has been reached for the current session.

### New Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `MinProfitToProtect_USD` | 5.0 | Minimum floating profit before giveback activates |

### Why This Matters

Without this, a position that briefly goes $0.50 in profit could trigger giveback protection and close at $0.37. The minimum threshold ensures protection only engages on meaningful profits.

---

## v3.2 — TrendPermissionEA_v3_2

**File:** `TrendPermissionEA_v3_2.mq5`
**Description:** *"Permission-Gated Execution with Redesigned Layer 0 Risk Governor"*

### What Changed

**Major architectural redesign** of the risk governor. Separates risk into two tiers: **basket-level** and **account-level (daily)**.

### New Features

- **Basket Stop Loss:** Per-basket stop loss in USD. When a basket (group of positions) hits this loss, it closes but trading continues.
- **Daily Loss Limit:** Separate daily-scoped limit — when hit, trading is disabled for the rest of the NY day.
- **Two-Tier Architecture:**
  - **Basket-level:** Stop loss, peak giveback — resets between baskets.
  - **Account-level:** Daily loss limit, daily profit target — persists across baskets within a day.
- **Equity-Based Basket Tracking:** Uses `basketStartEquity` and `basketPeakEquity` to track basket performance.

### Changed Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `BasketStopLoss_USD` | 20.0 | Per-basket stop loss (NEW — replaces `MaxAccountDD_USD`) |
| `DailyLossLimit_USD` | 100.0 | Daily loss limit (NEW) |
| `DailyProfitTarget_USD` | 100.0 | Renamed from `DailyProfitTarget` |

### Risk Priority Order

1. Daily loss limit (account-level)
2. Basket stop loss (basket-level)
3. Peak giveback (basket-level)
4. Daily profit target (account-level)

---

## v3.3 — TrendPermissionEA_v3_3

**File:** `TrendPermissionEA_v3_3.mq5`
**Description:** *"Basket risk based on Floating P&L (not equity)"*

### What Changed

Basket risk tracking switched from **equity comparison** to **floating P&L summation**.

### Technical Change

| Before (v3.2) | After (v3.3) |
|----------------|--------------|
| `basketStartEquity` / `basketPeakEquity` | `basketFloatingPL` / `basketPeakPL` |
| Basket P&L = current equity - basket start equity | Basket P&L = sum of `POSITION_PROFIT` for all EA positions |

### Why This Matters

Equity-based tracking is polluted by:
- Other EAs running on the same account
- Deposits/withdrawals during the session
- Swap charges accumulating

Floating P&L is a **direct measurement** of the basket's actual unrealized performance.

---

## v3.4 — TrendPermissionEA_v3_4

**File:** `TrendPermissionEA_v3_4.mq5`
**Description:** *"Daily reset based on New York midnight"*

### What Changed

Daily session tracking aligned to **New York midnight** instead of broker server time.

### New Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `BrokerToNYOffsetHours` | -7 | Broker time offset to New York (hours) |

### Technical Change

- `currentSessionDate` → renamed to `currentNYDate`
- New helper functions: `GetNewYorkDate()`, `GetNewYorkTime()`
- All daily resets now fire at NY midnight regardless of broker timezone

### Why This Matters

Gold (XAUUSD) trading is dominated by NY session activity. A daily reset at broker midnight (often GMT+2/+3) would split the NY session in half, corrupting daily P&L tracking and risk limits.

---

## v3.5 — TrendPermissionEA_v3_5

**File:** `TrendPermissionEA_v3_5.mq5`
**Description:** *"Peak protection using basket floating P&L (clarified)"*

### What Changed

Naming and clarity refactor. No functional logic changes.

### Technical Change

- `basketPeakPL` → renamed to `basketPeakFloatingPL`
- Clearer init prints documenting the giveback formula:
  ```
  Giveback Formula: close if floatingPL <= peakPL * (1 - PeakGivebackFrac)
  ```

### Why This Matters

Explicit naming prevents confusion between "peak realized P&L" and "peak floating P&L" — a distinction that becomes critical in later versions.

---

## v3.6 — TrendPermissionEA_v3_6

**File:** `TrendPermissionEA_v3_6.mq5`
**Description:** *"Force Flip on Opposite Permission Signal"*

### What Changed

Added **Force Flip** — if a basket is open in one direction and the trend permission flips to the opposite direction, the basket is immediately closed and the EA can enter the new direction.

### New Features

- **`CheckForceFlip()` function:** Runs on every tick (not gated to new bars).
- **Basket Direction Tracking:** New `basketDirection` variable (1=LONG, -1=SHORT, 0=NONE).
- **Direction Constants:** `BASKET_NONE`, `BASKET_LONG`, `BASKET_SHORT` defines.

### Logic

```
If LONG basket active + shortEntryAllowed → Close all LONG → Reset → Ready for SHORT
If SHORT basket active + longEntryAllowed → Close all SHORT → Reset → Ready for LONG
```

### Why This Matters

Without force flip, the EA could hold a dying LONG basket while the trend has already reversed to SHORT. This causes unnecessary losses and misses the new trend.

---

## v3.7 — TrendPermissionEA_v3_7

**File:** `TrendPermissionEA_v3_7.mq5`
**Description:** *"Correctness Patch: Realized P&L accounting, derived basket state"*

### What Changed

**Critical correctness patch** with three fixes addressing state management bugs.

### Fix 1: Realized P&L Single Source of Truth

| Before | After |
|--------|-------|
| `dailyRealizedPL` updated in both `CloseAllPositions()` and `OnTradeTransaction()` | Updated **ONLY** in `OnTradeTransaction()` |

Double-counting was possible when a position close triggered both paths.

### Fix 2: Daily Limits Use Realized P&L Only

| Before | After |
|--------|-------|
| Daily loss/target checked via `currentEquity - dailyStartEquity` | Checked via `dailyRealizedPL` (realized trades only) |

Equity-based daily checks were corrupt because floating P&L fluctuations could prematurely trigger daily limits.

### Fix 3: Basket State is Derived, Not Flag-Based

| Before | After |
|--------|-------|
| `basketActive` flag set/cleared manually | `BasketHasPositions()` scans live positions |
| `basketDirection` stored as variable | `GetBasketDirection()` derives from position types |

Flag-based state could desync from reality (e.g., if a position was manually closed or the EA restarted).

### New Functions

- `BasketHasPositions()` — returns `true` if any position with matching symbol + magic exists
- `GetBasketDirection()` — returns `BASKET_LONG`, `BASKET_SHORT`, or `BASKET_NONE` by scanning all positions
- `ValidateBasketStateAssertions()` — debug-only assertions to catch state inconsistencies

### Display Variables

- `displayBasketActive` / `displayBasketDirection` — UI-only, derived each tick, **never trusted for logic**

---

## v3.8 — TrendPermissionEA_v3_8

**File:** `TrendPermissionEA_v3_8.mq5`
**Description:** *"Trend Gating Upgrade: Structural Body Clearance + ATR-Normalized Slope"*

### What Changed

Two new filters added to the trend permission module to reduce false entries.

### New Feature 1: Structural Body Clearance Filter

The **candle body** (not just close) must be completely clear of the EMA envelope:

- **LONG:** `bodyLow > cloudTop` AND `bodyLow > ema200High[1]`
- **SHORT:** `bodyHigh < cloudBottom` AND `bodyHigh < ema200Low[1]`

Where:
- `cloudTop` = max(EMA10, EMA30)
- `cloudBottom` = min(EMA10, EMA30)
- `bodyLow` / `bodyHigh` = min/max of open and close

### New Feature 2: ATR-Normalized Slope Filter

Raw slope values are meaningless across different volatility regimes. This normalizes the EMA30 slope by ATR(14):

```
normalizedSlopeStrength = |emaSlowSlope| / ATR(14)
trendForceOK = normalizedSlopeStrength > 0.12
```

### New Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `ATR_PERIOD` | 14 | ATR calculation period |
| `MIN_SLOPE_STRENGTH` | 0.12 | Hard-coded empirical threshold |

### Final Permission Formula (v3.8)

```
longEntryAllowed  = longBase  AND longStructuralClear  AND trendForceOK
shortEntryAllowed = shortBase AND shortStructuralClear AND trendForceOK
```

### Why This Matters

- **Body clearance** prevents entries where the candle merely wicks above the EMAs but the body is still embedded in the cloud.
- **ATR-normalized slope** prevents entries during low-volatility chop where slopes are technically positive but the trend has no real momentum.

---

## v3.9 — TrendPermissionEA_v3_9

**File:** `TrendPermissionEA_v3_9.mq5`
**Description:** *"Asymmetric Basket Take-Profit + Fixed Grid Pyramiding"*

### What Changed

Major execution layer overhaul. Per-position take profit is **disabled** and replaced by basket-level exits. Grid pyramiding is introduced.

### New Feature 1: Per-Position TP Disabled

`ManageTakeProfit()` is now an empty function. The `TakeProfitDollars` input is preserved but unused. All exits are now at the **basket level** via Layer 0:
- Peak giveback protection
- Daily profit floor
- Basket stop loss

### New Feature 2: Fixed Grid Pyramiding

New function `ManageGridAdds()` adds positions at fixed USD intervals:

| Direction | Condition | Action |
|-----------|-----------|--------|
| LONG | `bid >= lastAddAnchorPrice + FixedGridGap_USD` AND `Close[1] > EMA10[1]` | Buy another lot |
| SHORT | `ask <= lastAddAnchorPrice - FixedGridGap_USD` AND `Close[1] < EMA10[1]` | Sell another lot |

- **Anchor price** resets after each add (steps forward with the trend).
- **Trend intact check** ensures grid adds only happen while the trend is still valid (price above/below EMA10).

### New Feature 3: Daily Profit Floor

When basket peak floating P&L reaches the daily profit target:
- A **profit floor** is set at that level
- The floor **persists across baskets** for the rest of the NY day
- If any subsequent basket's floating P&L drops to the floor level, it triggers an immediate exit

### New/Changed Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `TakeProfitDollars` | 5.0 | **DEPRECATED** — preserved but unused |
| `FixedGridGap_USD` | 4.0 | **NEW** — USD gap between grid pyramiding adds |

### New Global Variables

| Variable | Description |
|----------|-------------|
| `lastAddAnchorPrice` | Grid anchor — resets per basket |
| `dailyProfitFloorActive` | Whether profit floor is active |
| `dailyProfitFloor_USD` | Floor value in USD |

### Risk Priority Order (Updated)

1. Daily loss limit
2. Basket stop loss
3. Peak giveback
4. Daily profit floor (PRIORITY 3a — checked before giveback)

---

## v3.9.1 — TrendPermissionEA_v3_9_1

**File:** `TrendPermissionEA_v3_9_1.mq5`
**Description:** *"Structural Trend Invalidation using EMA30 (Slow EMA)"*
**Base:** v3.9

### What Changed

Added an early **structural exit** using the Slow EMA (EMA30) to prevent large basket stop losses. When price structure clearly breaks against the basket direction, the basket is closed immediately — before the P&L-based basket stop loss can fire.

### New Feature: EMA30 Structural Invalidation Exit

New function `StructuralInvalidationTriggered(int basketDirection)` checks completed bar data:

| Direction | Condition | Action |
|-----------|-----------|--------|
| LONG basket | `Close[1] < emaSlow[1]` AND `Close[2] < emaSlow[2]` AND `emaFastSlope <= 0` | Close basket |
| SHORT basket | `Close[1] > emaSlow[1]` AND `Close[2] > emaSlow[2]` AND `emaFastSlope >= 0` | Close basket |

**Triple confirmation required:**
1. **Two consecutive closes** on the wrong side of EMA30 (not just a wick)
2. **EMA10 slope** confirms the reversal (not rising for longs, not falling for shorts)

### New Helper: `CountBasketPositions()`

Returns the number of open positions matching the EA's magic number. Used for debug logging when structural invalidation fires.

### Risk Priority Order (Updated)

1. **Daily loss limit** (account-level)
2. **EMA30 structural invalidation** ← NEW (PRIORITY 2)
3. **Basket stop loss** (P&L risk)
4. **Daily profit floor** (profit management)
5. **Peak giveback** (profit management)
6. **Daily profit target** (account-level)

### Why EMA30 Instead of EMA10

v4.0 uses EMA10 for structural invalidation. v3.9.1 uses EMA30 as a **research variant** — the slower EMA is more forgiving during shallow pullbacks, only triggering on deeper structural breaks. This allows direct A/B comparison between the two approaches.

### Panel

- Panel PREFIX updated to `TPv391_`
- Version label shows `v3.9.1`
- `disableReason` includes structural invalidation messaging

---

## v3.9.2 — TrendPermissionEA_v3_9_2

**File:** `TrendPermissionEA_v3_9_2.mq5`
**Description:** *"Permission Silence Invalidation (5-bar silence rule)"*
**Base:** v3.9.1

### What Changed

Added **Permission Silence Exit** — if a basket is open and no new permission "burst" (false→true rising edge) occurs within 5 closed bars, the basket is exited. This catches situations where trend permission goes silent (no new confirmations) even though it hasn't explicitly reversed.

### Core Concept: Permission Burst

A **burst** is a rising-edge event: the transition from `false` to `true` on `longEntryAllowed` or `shortEntryAllowed`. Continuous `true` is NOT a burst — only the moment permission flips on counts. This is tracked via `longEntryAllowedPrev` / `shortEntryAllowedPrev`.

### New Feature: Permission Silence Exit

New function `PermissionSilenceTriggered(int basketDirection)` checks:

| Direction | Condition | Action |
|-----------|-----------|--------|
| LONG basket | `barsSinceLongPermissionBurst >= 5` | Close basket |
| SHORT basket | `barsSinceShortPermissionBurst >= 5` | Close basket |

New function `UpdatePermissionSilenceCounters()` runs once per new bar (after `UpdateTrendPermission()`):
- Increments the relevant counter each bar
- Resets counter to 0 on burst detection (rising edge)

### New Global Variables

| Variable | Description |
|----------|-------------|
| `barsSinceLongPermissionBurst` | Bars since last long permission rising edge |
| `barsSinceShortPermissionBurst` | Bars since last short permission rising edge |

### New Define

| Define | Value | Description |
|--------|-------|-------------|
| `MAX_PERMISSION_SILENCE_BARS` | 5 | Maximum bars without a burst before exit |

### Counter Lifecycle

- **Increment:** Every new closed bar (in `UpdatePermissionSilenceCounters()`)
- **Reset to 0:** On burst detection (rising edge of permission)
- **Reset to 0:** On basket close (`ResetBasketState()`)
- **Reset to 0:** On EA init (`InitializeLayer0()`)
- **Reset to 0:** On NY day change (`CheckDayReset()`)

### Risk Priority Order (Updated)

1. **Daily loss limit** (account-level)
2. **Permission silence exit** ← NEW (PRIORITY 2, checked first in basket block)
3. **EMA30 structural invalidation** (from v3.9.1)
4. **Basket stop loss** (P&L risk)
5. **Daily profit floor** (profit management)
6. **Peak giveback** (profit management)
7. **Daily profit target** (account-level)

### Panel

- New "Perm Silence:" row in Execution Status section
  - Shows `N/5` format with color coding:
    - Green (0-2 bars): healthy
    - Yellow (3-4 bars): warning
    - Red (5+ bars): would trigger exit
  - Shows `N/A` in gray when no basket is active
- Panel PREFIX updated to `TPv392_`
- Version label shows `v3.9.2`

### Why This Matters

Before v3.9.2, a basket could remain open even when the trend permission module produced no new confirmations for many bars. The silence rule ensures baskets don't linger in "zombie" states where the trend has quietly died but no explicit reversal signal has fired.

---

## v4.0 — TrendPermissionEA_v4_0

**File:** `TrendPermissionEA_v4_0.mq5`
**Description:** *"Asymmetric Basket Take-Profit + Fixed Grid Pyramiding + EMA10 Invalidation"*

### What Changed

Added **Structural EMA10 Invalidation Exit** — a trend-truth exit that fires before any P&L-based stop.

### New Feature: EMA10 Invalidation Exit

New function `CheckEMA10Invalidation()` checks on every tick:

| Direction | Condition | Action |
|-----------|-----------|--------|
| LONG basket | `Close[1] < EMA10[1]` | Close all positions |
| SHORT basket | `Close[1] > EMA10[1]` | Close all positions |

This is a **structural exit**, not a risk exit. It fires because the trend premise is no longer valid — the completed bar has closed on the wrong side of EMA10.

### Risk Priority Order (Updated)

1. **Daily loss limit** (account-level, realized P&L)
2. **EMA10 invalidation** ← NEW (structural trend truth, PRIORITY 2)
3. **Basket stop loss** (P&L risk)
4. **Peak giveback** / **Daily profit floor** (profit management)
5. **Daily profit target** (account-level, realized P&L)

### Why This Matters

Before v4.0, a basket could ride a position deep into a pullback before any exit triggered. The EMA10 invalidation catches trend failures early — often exiting with a small gain or small loss rather than waiting for the basket stop to fire at a much larger loss.

### Panel

- Panel PREFIX updated to `TPv40_`
- Version label shows `v4.0`
- `disableReason` includes `"EMA10 INVALIDATION (Ready)"`

---

## v4.1 — TrendPermissionEA_v4_1

**File:** `TrendPermissionEA_v4_1.mq5`
**Description:** *"Asymmetric Basket TP + Grid Pyramiding + EMA10 Invalidation + Continuation Reentry"*

### What Changed

Added **Continuation Reentry Logic** — after a basket closes via peak giveback, the EA immediately re-enters if price is still on the correct side of EMA10, without waiting for full structural permission to recalculate.

### Core Concept

When a basket closes **in profit** via peak giveback, that **confirms the trend was valid**. Structural permission may toggle off during a pullback (slopes flatten, acceleration reverses), but the macro trend is still intact. Continuation reentry captures the next leg without waiting for the slow structural filters to re-confirm.

### New Global Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `continuationArmed` | `false` | Whether continuation reentry is pending |
| `continuationDirection` | `0` | Direction to re-enter (1=LONG, -1=SHORT) |

### New Function: `TryContinuationReentry()`

Runs on **every tick** (not gated to new bars):

```
if continuationArmed AND no open positions AND not disabled:
    LONG:  if Bid > EMA10[0] → open Buy immediately
    SHORT: if Ask < EMA10[0] → open Sell immediately
    Disarm after opening
```

**No structural filters.** No slope. No ATR. No body clearance. Only EMA10 side check.

### Arming Conditions

Continuation is armed **only** on peak giveback exit:

```
// Inside Layer0_RiskCheck, PRIORITY 4b block:
continuationArmed = true;
continuationDirection = currentDirection;   // captured BEFORE CloseAllPositions
CloseAllPositions("Layer0_PeakGiveback");
ResetBasketState();
```

Continuation is **NOT armed** on:
- EMA10 invalidation exit (trend failed — don't reenter)
- Basket stop loss (position lost money — don't reenter)
- Daily profit floor exit (daily target area — protect gains)
- Daily loss limit (risk limit — stop trading)
- Daily profit target (done for the day)
- Force flip (direction reversed — structural entry handles this)

### Tick Flow (Updated)

```
OnTick()
  → CheckPositionStatus()
  → Layer0_RiskCheck()              ← may arm continuation on giveback
  → UpdatePanel()
  → [if trading disabled: return]
  → CheckForceFlip()
  → TryContinuationReentry()       ← NEW: tick-based, before grid
  → ManageTakeProfit()              ← disabled (empty)
  → ManageGridAdds()
  → [New Bar Gate]
    → UpdateTrendPermission()
    → CheckPermissionTransitions()
    → ExecuteTradeLogic()
```

### Reset Conditions

- Continuation state resets on **new NY day** (`CheckDayReset`)
- Continuation state resets on **EA initialization** (`InitializeLayer0`)
- `continuationArmed` set to `false` after successful reentry trade

### Panel

- New "Continuation:" row in Execution Status section
  - `● ARMED (LONG)` or `● ARMED (SHORT)` in gold when active
  - `○ INACTIVE` in gray when not armed
- Execution box height increased from 150 to 176 pixels
- Panel PREFIX updated to `TPv41_`
- Version label shows `v4.1`

### Expected Behavior

```
1. Structural trend detected           → Initial entry
2. Grid pyramiding builds basket       → Multiple positions
3. Basket peaks                        → Peak tracking active
4. Giveback closes basket in profit    → Continuation ARMED
5. Price still above EMA10 (long)      → Immediate reentry (same tick or next)
6. New continuation basket runs        → Grid adds resume
7. Cycle repeats until trend truly ends
```

---

## v3.9.4 — TrendPermissionEA_v3_9_4

**File:** `TrendPermissionEA_v3_9_4.mq5`
**Description:** *"Asymmetric Basket Take-Profit + Fixed Grid Pyramiding + HTF ADX Regime Filter"*
**Base:** v3.9

### What Changed

Added a **Higher Timeframe ADX regime filter** to block new basket starts during low-trend-strength (choppy) market conditions. This is a pure entry-efficiency improvement — it does not modify risk logic, grid adds, or existing baskets.

### New Feature: HTF ADX Regime Filter

| Component | Detail |
|-----------|--------|
| Indicator | ADX (Average Directional Index) |
| Timeframe | M30 (configurable) |
| Period | 14 (configurable) |
| Threshold | 25.0 (configurable) |
| Scope | New basket entries only |

**Logic:**
- If `ADX < Threshold` → block new basket start
- If `ADX >= Threshold` → allow entry (system behaves like v3.9)
- Existing baskets and grid adds are **unaffected**
- ADX value is cached per M30 bar (not recalculated every tick)
- Fail-safe: if ADX data is unavailable, entry is blocked

### New Functions

| Function | Description |
|----------|-------------|
| `UpdateHTF_ADX()` | Caches M30 ADX value, recalculates only on new HTF bar |
| `RegimeAllowsNewBasket()` | Returns true/false based on ADX threshold |

### New Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ADX_Timeframe` | PERIOD_M30 | HTF timeframe for ADX calculation |
| `ADX_Period` | 14 | ADX indicator period |
| `ADX_Threshold` | 25.0 | Minimum ADX to allow new basket |
| `EnableADXFilter` | true | Enable/disable the filter |

### New Global Variables

| Variable | Description |
|----------|-------------|
| `g_adxValue` | Cached ADX value |
| `g_adxLastBarTime` | Last M30 bar time (for cache invalidation) |
| `g_adxValid` | Whether cached value is valid |

### Modified Function: `ExecuteTradeLogic()`

The ADX regime gate is inserted **before** entry logic, inside a `!BasketHasPositions()` guard:

```
if(tradeTakenThisPermission) return;
if(hasOpenPosition) return;

if(!BasketHasPositions())
{
    if(!RegimeAllowsNewBasket())    ← NEW: ADX gate
        return;
}

// existing long/short entry logic unchanged
```

### What Is NOT Changed

- Layer0_RiskCheck (unchanged)
- OnTradeTransaction (unchanged)
- Trend permission module (frozen)
- ManageGridAdds (unchanged)
- Basket state derivation (unchanged)
- Risk priority ordering (unchanged)

### Debug Output

Entry BUY/SELL prints now include ADX value:
```
>>> BUY TRADE OPENED | Anchor set: 2845.30 | ADX=32.15
>>> v3.9.4 ADX FILTER BLOCKED ENTRY | ADX=18.42
```

---

## v3.9.5 — TrendPermissionEA_v3_9_5

**File:** `TrendPermissionEA_v3_9_5.mq5`
**Description:** *"Asymmetric Basket Take-Profit + Fixed Grid Pyramiding + HTF ADX Regime Filter + ATR Extension Filter"*
**Base:** v3.9.4

### What Changed

Added an **ATR-normalized EMA extension filter** to block new basket starts when price is excessively extended from EMA10. This prevents entering at overextended prices where mean-reversion risk is highest.

### New Feature: ATR-Normalized EMA Extension Filter

| Component | Detail |
|-----------|--------|
| Metric | `\|Close[1] - EMA10[1]\| / ATR[1]` |
| Threshold | 1.0 ATR (configurable) |
| Scope | New basket entries only |
| Data source | Reuses existing `emaFast[]` and `atrValues[]` arrays |

**Logic:**
- Calculate `normalizedExtension = |completedClose - emaFast[1]| / atrValues[1]`
- If `normalizedExtension > MaxExtensionATR` → block new basket start
- If within threshold → allow entry (system behaves like v3.9.4)
- Existing baskets and grid adds are **unaffected**
- No new indicator handles created (reuses frozen trend module data)

### Fail-Safe Rules

- If `ATR = 0` → no division, extension defaults to 0 (entry allowed)
- If `emaFast[]` or `atrValues[]` arrays not ready → filter is skipped (entry allowed)
- No new state variables introduced

### New Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `EnableExtensionFilter` | true | Enable/disable the extension filter |
| `MaxExtensionATR` | 1.0 | Maximum allowed \|Close - EMA10\| / ATR |

### Modified Function: `ExecuteTradeLogic()`

The extension filter is inserted **after** the ADX regime check, inside the same `!BasketHasPositions()` guard:

```
if(!BasketHasPositions())
{
    if(!RegimeAllowsNewBasket())    ← v3.9.4: ADX gate
        return;

    if(EnableExtensionFilter ...)   ← NEW: Extension gate
    {
        if(normalizedExtension > MaxExtensionATR)
            return;
    }
}
```

### What Is NOT Changed

- Layer0_RiskCheck (unchanged)
- OnTradeTransaction (unchanged)
- Trend permission module (frozen)
- ManageGridAdds (unchanged)
- Basket state derivation (unchanged)
- ADX regime filter logic (unchanged)
- Risk priority ordering (unchanged)

### Debug Output

```
>>> v3.9.5 EXTENSION BLOCK | Dir=LONG | NormExt=1.42 | Max=1.00
```

---

## v3.9.6 — TrendPermissionEA_v3_9_6

**File:** `TrendPermissionEA_v3_9_6.mq5`
**Description:** *"Asymmetric Basket TP + Fixed Grid + HTF ADX + Structural Failure Controls"*
**Base:** v3.9.4

### What Changed

Added **three early-exit mechanisms** that fire *before* the hard basket stop loss, designed to detect structurally failing baskets and cut them early.

### New Feature 1: MAE Soft Stop (Priority 1B)

Tracks the **Maximum Adverse Excursion** — the worst floating P&L the basket has ever seen.

| Component | Detail |
|-----------|--------|
| Metric | `basketMAE = MathMin(basketMAE, basketFloatingPL)` |
| Threshold | `MAE_Stop_USD` (default $12) |
| Action | Close basket when `basketMAE <= -MAE_Stop_USD` |
| Rationale | Fires at -$12, well before the hard `BasketStopLoss_USD` at -$20 |

### New Feature 2: Time Stop (Priority 1C)

Closes stale baskets that never gained momentum.

| Component | Detail |
|-----------|--------|
| Clock | Bar count since basket first detected (`basketStartBarIndex`) |
| Trigger | `barsSinceEntry >= TimeStopBars` AND `basketMFE < MinMFEForTimeStop_USD` |
| Defaults | 12 bars, $3 MFE minimum |
| Rationale | A basket that hasn't achieved $3 in 12 minutes didn't catch the trend |

If the basket *did* reach $3+ MFE at any point, the time stop never fires.

### New Feature 3: Expansion Failure Exit (Priority 1D)

Detects when the EMA trend powering the basket has stalled.

| Component | Detail |
|-----------|--------|
| Expanding (LONG) | `gapSlope > 0` AND `emaFastSlope > 0` |
| Expanding (SHORT) | `gapSlope < 0` AND `emaFastSlope < 0` |
| Counter | `expansionFailureCounter` increments when not expanding, resets when expanding |
| Trigger | Counter `>= ExpansionFailureBars` (6) AND `basketFloatingPL <= basketMFE * 0.5` |
| Safety guard | The 50% MFE giveback requirement prevents premature closure near peak |

### New Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `EnableMAEStop` | true | Enable/disable the MAE soft stop |
| `MAE_Stop_USD` | 12.0 | MAE threshold — close basket when worst drawdown hits this |
| `EnableTimeStop` | true | Enable/disable the time stop |
| `TimeStopBars` | 12 | Bars since basket start before staleness check |
| `MinMFEForTimeStop_USD` | 3.0 | Minimum MFE required to keep basket alive past time limit |
| `EnableExpansionFailure` | true | Enable/disable expansion failure exit |
| `ExpansionFailureBars` | 6 | Consecutive non-expanding bars before exit |

### New Global Variables

| Variable | Type | Description |
|----------|------|-------------|
| `basketMAE` | double | Most negative floating P&L since basket opened (always ≤ 0) |
| `basketMFE` | double | Most positive floating P&L since basket opened (always ≥ 0) |
| `basketStartBarIndex` | int | Bar index when first position detected (-1 = unset) |
| `expansionFailureCounter` | int | Consecutive bars where trend is not expanding |

### Risk Priority Order (Updated)

| Priority | Check | v3.9.6 New? |
|----------|-------|-------------|
| 1 | Daily loss limit (realized P&L) | No |
| **1B** | **MAE Soft Stop** | **Yes** |
| **1C** | **Time Stop** | **Yes** |
| **1D** | **Expansion Failure Exit** | **Yes** |
| 2 | Basket stop loss | No |
| 3a | Daily profit floor | No |
| 3b | Peak giveback | No |
| 4 | Daily profit target | No |

### What Is NOT Changed

- Trend permission module (frozen)
- Grid pyramiding logic (unchanged)
- HTF ADX filter (unchanged)
- Force flip (unchanged)
- OnTradeTransaction (unchanged)
- Panel layout (no new rows — structural failure state is log-only)

---

## v3.9.7 — TrendPermissionEA_v3_9_7

**File:** `TrendPermissionEA_v3_9_7.mq5`
**Description:** *"Asymmetric Basket TP + Fixed Grid + HTF ADX + Expansion Maximizer"*
**Base:** v3.9.4 (note: v3.9.6 structural failure controls are NOT carried forward)

### What Changed

Added an **Expansion Maximizer** — when the market is in a strong expansion regime (high ADX + widening EMA gap + expanding ATR), grid adds use a **multiplied lot size** to capture more of the move. A **basket lot cap** prevents runaway exposure.

### New Feature 1: Expansion Regime Detection

New function `IsExpansionRegime()` returns true when **all three** conditions are met:

| Condition | Check |
|-----------|-------|
| ADX strength | `g_adxValue > ADX_Threshold + ADXExpansionBuffer` |
| EMA gap widening | `emaGap > emaGapPrev` AND `gapSlope > 0` |
| ATR expanding | `atrValues[1] > atrValues[2]` |

All three must pass simultaneously. If any fails, standard lot size is used.

### New Feature 2: Expansion-Aware Grid Lot Sizing

In `ManageGridAdds()`, the lot size for each grid add is now:

```
nextLot = IsExpansionRegime() ? LotSize * ExpansionMultiplier : LotSize
```

The initial basket entry (in `ExecuteTradeLogic()`) **always uses base `LotSize`** — only grid adds are multiplied.

### New Feature 3: Basket Lot Cap

New function `CalculateBasketLots()` sums all open position volumes. Before each grid add:

```
if(currentBasketLots + nextLot > MaxBasketLots) → block add
```

This is a hard ceiling on total basket exposure regardless of expansion state.

### New Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `EnableExpansionMultiplier` | true | Enable/disable expansion-aware lot sizing |
| `ExpansionMultiplier` | 2.0 | Lot multiplier during expansion regime |
| `ADXExpansionBuffer` | 5.0 | ADX must exceed `Threshold + Buffer` for expansion |
| `MaxBasketLots` | 0.08 | Maximum total lots across all basket positions |

### New Functions

| Function | Description |
|----------|-------------|
| `IsExpansionRegime()` | Returns true when ADX + EMA gap + ATR all confirm expansion |
| `CalculateBasketLots()` | Returns sum of all open position volumes for this EA |

### Modified Function: `ManageGridAdds()`

Before opening a grid add, the function now:
1. Calls `IsExpansionRegime()` to determine lot size
2. Checks `CalculateBasketLots() + nextLot > MaxBasketLots` → blocks if exceeded
3. Uses `nextLot` (either base or multiplied) for the `trade.Buy()` / `trade.Sell()` call

### What Is NOT Changed

- Layer0_RiskCheck (unchanged — no v3.9.6 structural failure controls)
- OnTradeTransaction (unchanged)
- Trend permission module (frozen)
- HTF ADX filter (unchanged)
- Force flip (unchanged)
- Initial entry lot size (always base `LotSize`)

### Debug Output

```
>>> v3.9.7 EXPANSION ADD | Multiplied Lot: 0.02 | ADX: 35.42 | BasketLots: 0.05
>>> v3.9.7 GRID ADD BLOCKED | BasketLots: 0.07 + nextLot: 0.02 > MaxBasketLots: 0.08
```

---

## v4.5 — TrendPermissionEA_v4_5

**File:** `TrendPermissionEA_v4_5.mq5`
**Description:** *"Modular Pullback Batch Execution Engine – Account 433140219 DNA"*

### What Changed

**Ground-up rewrite.** This is NOT an evolution of v3.x — it is a **clean-room execution chassis** that makes zero market analysis decisions. The EA is purely a grid executor with an external permission interface.

### Architecture: Separation of Concerns

```
┌─────────────────────────────────────────────┐
│  EXTERNAL TREND PERMISSION (pluggable)      │
│  AllowBuy() / AllowSell() — stubs           │
├─────────────────────────────────────────────┤
│  ENGINE STATE MACHINE                       │
│  IDLE → BASKET_ACTIVE → COOLDOWN → IDLE     │
├─────────────────────────────────────────────┤
│  GRID EXECUTOR                              │
│  Hardcoded lot ladder, tick-based adds      │
├─────────────────────────────────────────────┤
│  BREAK-EVEN TP                              │
│  Weighted-avg BE + configurable buffer      │
├─────────────────────────────────────────────┤
│  5-LAYER CIRCUIT BREAKERS + COOLDOWN        │
│  DD%, float loss, adverse pips, time, level │
└─────────────────────────────────────────────┘
```

### External Permission Interface

Two stub functions define the EA's only external dependency:

- `AllowBuy()` — returns `true` (stub, replace with your indicator/ML model)
- `AllowSell()` — returns `false` (stub)

**Contract:** Exactly one may return true at a time (or both false). If both true, buy wins. The engine makes zero trend decisions.

**Permission Flip:** If permission reverses during an active basket, adds are **frozen** (`g_permissionFrozen = true`). Existing positions continue managed toward break-even exit.

### Engine State Machine

| State | Description |
|-------|-------------|
| `STATE_IDLE` | No basket. Polls `AllowBuy()` / `AllowSell()` each tick. |
| `STATE_BASKET_ACTIVE` | Basket running. Stats → circuit breakers → permission flip → BE TP → grid adds. |
| `STATE_COOLDOWN` | Post-circuit-breaker pause. Waits `InpCooldownMinutes`, then returns to IDLE. |

### Fixed DNA Lot Ladder

Hardcoded 10-level progression (no configurable multiplier):

| Level | Lots |  | Level | Lots |
|-------|------|--|-------|------|
| L0 | 0.07 |  | L5 | 0.59 |
| L1 | 0.11 |  | L6 | 0.89 |
| L2 | 0.17 |  | L7 | 1.34 |
| L3 | 0.26 |  | L8 | 2.01 |
| L4 | 0.39 |  | L9 | 3.02 |

Total full-ladder exposure: **8.85 lots.** Each level is roughly 1.5× the previous. Bespoke to a specific account's risk budget.

### Break-Even TP Logic

Basket exit target computed from lot-weighted average open price:

- **Pips mode:** `TP = avgPrice ± (spreadBuffer + profitPips)`
- **USD mode:** `profitBuffer = (InpBEProfitUSD × tickSize) / (totalLots × tickValue)` — target **tightens dynamically** as total lots increase

### 5-Layer Circuit Breakers

All circuit breakers close the entire basket and trigger cooldown.

| Breaker | Trigger |
|---------|---------|
| A: Equity DD% | `(balance - equity) / balance × 100 ≥ InpMaxDDPercent` |
| B: Max Floating Loss | `totalProfitUSD ≤ -InpMaxFloatingLossUSD` |
| C: Max Adverse Pips | Distance from weighted avg to price > `InpMaxAdversePips` |
| D: Level Cap Emergency | At max levels AND float loss ≥ 75% of max |
| E: Time Stop | Basket age ≥ `InpMaxBasketHours` hours |

### Grid Add Logic

Tick-based, no candle confirmation:
- **LONG:** Buy when `Bid ≤ lastEntryPrice - gridSpacing`
- **SHORT:** Sell when `Ask ≥ lastEntryPrice + gridSpacing`
- Duplicate guard: rejects if any existing position is within `InpDuplicateGuardPips`
- Frozen permission blocks all adds
- Spread check blocks entries when spread > `InpMaxSpreadPips`

### Session Recovery

`RecoverBasketState()` runs on `OnInit()` — detects existing positions from prior session and reconstructs basket state. Handles mixed-direction edge cases.

### Input Parameters

| Group | Parameter | Default | Description |
|-------|-----------|---------|-------------|
| 01. Grid Engine | `InpGridSpacingPips` | 12.0 | Grid spacing between levels (pips) |
| | `InpDuplicateGuardPips` | 1.0 | Min distance to prevent duplicate adds |
| | `InpMaxLevels` | 10 | Maximum grid levels |
| 02. Exit / BE TP | `InpBEProfitPips` | 3.0 | Pips above break-even |
| | `InpBEProfitUSD` | 50.0 | USD above break-even |
| | `InpSpreadBufferPips` | 2.0 | Spread buffer on BE price |
| | `InpUsePipsBE` | false | Pips vs USD buffer mode |
| 03. Circuit Breakers | `InpMaxDDPercent` | 5.0 | Max equity drawdown % |
| | `InpMaxFloatingLossUSD` | 500.0 | Max floating loss ($) |
| | `InpMaxAdversePips` | 80.0 | Max adverse distance from weighted avg |
| | `InpMaxBasketHours` | 24 | Max basket duration (0 = disabled) |
| | `InpCooldownMinutes` | 15 | Cooldown after circuit breaker |
| 04. Execution Safety | `InpMaxSpreadPips` | 5.0 | Max spread for entry |
| | `InpSlippagePoints` | 30 | Max slippage |
| | `InpMagicNumber` | 450000 | Magic number |
| 05. General | `InpDebug` | true | Debug logging |

### Key Differences from v3.x

| Dimension | v3.x | v4.5 |
|-----------|------|------|
| Trend logic | Built-in EMAs + regime detection | Zero — external stubs only |
| Lot sizing | Configurable `LotSize` + optional multiplier | Hardcoded 10-level lookup table |
| State management | Implicit flags + position counting | Explicit 3-state FSM with logged transitions |
| Entry logic | Candle-based trend confirmation | Pure tick-based grid spacing |
| Exit logic | Asymmetric basket TP (peak giveback, daily floor) | Weighted-average break-even TP |
| Circuit breakers | Basket stop + daily limits | 5-layer standardized system + cooldown |
| Permission flip | Force flip (close + reverse) | Freeze adds, manage to exit |
| Session recovery | None | `RecoverBasketState()` reconstructs from live positions |

---

## v5.0.0 — TrendPermissionEA_v5_0_0

**File:** `TrendPermissionEA_v5_0_0.mq5`
**Description:** *"Stage 0+1 — Overlay Engine Scaffolding"*

### What Changed

Foundation for the counter-trend overlay engine. No overlay trading logic yet — this version builds the structural skeleton that all subsequent v5.x stages depend on.

### Stage 0 — Magic-Parameterized Basket Utilities

All existing basket utility functions were refactored to accept an explicit `magic` parameter instead of using the hardcoded global `MagicNumber`. This allows the same utility functions to service both the primary trend basket and the overlay basket without duplication.

**Functions refactored:**
- `CountBasketPositions(int magic)` — count open positions by magic
- `GetBasketFloatingPL(int magic)` — sum floating P&L by magic
- `CloseAllPositions(int magic)` — close all positions for a specific magic
- `OverlayHasPositions()` — convenience wrapper: `CountBasketPositions(MAGIC_OVERLAY) > 0`

### Stage 1 — Overlay Compile-Gate & Defines

- Added `#define OVERLAY_ENABLED` compile flag — all overlay code is wrapped in `#ifdef OVERLAY_ENABLED` blocks
- Added `#define MAGIC_OVERLAY 987654` — dedicated magic number for overlay positions
- Added overlay input parameter stubs (no logic yet):
  - `EnableOverlayEngine`, `OverlayGridGap_USD`, `OverlayMaxPositions`
  - `OverlayTakeProfit_USD`, `OverlayTimeExpiry_Bars`, `OverlayStructuralStop_USD`
  - `OverlayActivationThreshold_USD`
- Added empty overlay wrapper functions: `ResetOverlayState()`, `ManageOverlayGrid()`, `CheckOverlayStructuralStop()`, `CheckOverlayProfitTarget()`
- Added overlay state globals (all initialized, no mutations yet)

### Design Principle

Zero behavioral change from v4.x when `OVERLAY_ENABLED` is not defined. The compile gate ensures the overlay engine is completely inert until explicitly activated.

---

## v5.0.1 — TrendPermissionEA_v5_0_1

**File:** `TrendPermissionEA_v5_0_1.mq5`
**Description:** *"Tick-Level Microstructure Detection"*

### What Changed

Replaced the original two-bar exhaustion detection with two new tick-level microstructure functions that detect counter-trend opportunities with higher precision.

### New Functions

**`DetectImpulseCandle()`**
- Detects a completed M1 candle with body size ≥ `ImpulseBodyMultiple × ATR(ImpulseATR_Period)`
- Returns direction enum: `IMPULSE_BULL`, `IMPULSE_BEAR`, or `IMPULSE_NONE`
- Only fires on new bar (checks previous completed candle)
- Records impulse high/low into `overlayImpulseHigh` / `overlayImpulseLow` globals

**`DetectTickExhaustion()`**
- Tick-level function — runs every tick, not just on new bar
- Counts consecutive ticks that fail to make new highs (for bull impulse) or new lows (for bear impulse)
- Triggers when `ExhaustionTickCount` consecutive non-extending ticks detected
- Returns `true` only once per impulse (re-arm on next impulse detection)

### New Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ImpulseBodyMultiple` | 1.5 | Body ≥ N × ATR to qualify as impulse |
| `ImpulseATR_Period` | 14 | ATR period for impulse detection |
| `ExhaustionTickCount` | 30 | Consecutive non-extending ticks to confirm exhaustion |

---

## v5.0.2 — TrendPermissionEA_v5_0_2

**File:** `TrendPermissionEA_v5_0_2.mq5`
**Description:** *"Full Overlay Execution Engine"*

### What Changed

Complete implementation of the overlay grid execution engine. All four overlay wrapper functions now contain full trading logic.

### `ResetOverlayState()`

Clears all overlay tracking globals to initial values:
- Resets `overlayActive`, `overlayDirection`, `overlayGridCount`, `overlayEntryTime`
- Clears `overlayImpulseHigh`, `overlayImpulseLow`, `overlaySwingReference`
- Resets `overlayPeakFloatingPL`, `overlayDailyRealizedPL`

### `ManageOverlayGrid()`

Grid add logic for the overlay basket:
- **Direction:** Counter-trend — if impulse was bullish, overlay sells; if bearish, overlay buys
- **Grid spacing:** Uses `OverlayGridGap_USD` converted to price distance
- **Max positions:** Capped by `OverlayMaxPositions`
- **Lot size:** Uses same `LotSize` as trend basket
- **Magic:** All overlay orders use `MAGIC_OVERLAY` (987654)
- **Safety lock:** Blocks adds when `overlayGridCount` has already reached max (prevents runaway)

### `CheckOverlayStructuralStop()`

Structural invalidation exit for the overlay:
- For **sell overlay:** closes if price rises above `overlayImpulseHigh + OverlayStructuralStop_USD`
- For **buy overlay:** closes if price falls below `overlayImpulseLow - OverlayStructuralStop_USD`
- Calls `CloseAllPositions(MAGIC_OVERLAY)` + `ResetOverlayState()` on trigger

### `CheckOverlayProfitTarget()`

Profit target exit:
- Sums floating P&L of all `MAGIC_OVERLAY` positions
- Closes overlay basket when floating P&L ≥ `OverlayTakeProfit_USD`
- Tracks `overlayPeakFloatingPL` for potential future giveback logic

### Overlay Entry Sequence (in OnTick)

1. If `overlayActive == false` and `EnableOverlayEngine == true`
2. `DetectImpulseCandle()` — check for impulse
3. If impulse detected, `DetectTickExhaustion()` — confirm exhaustion
4. On exhaustion → open first overlay position, set `overlayActive = true`, record entry time and swing reference

---

## v5.0.3 — TrendPermissionEA_v5_0_3

**File:** `TrendPermissionEA_v5_0_3.mq5`
**Description:** *"Overlay Hardening — 8 Patches for State Integrity & Risk Sync"*

### What Changed

Eight targeted patches to close correctness gaps discovered during integration testing.

### Patch 1 — Full Sync Close at All Exit Sites

Every code path that calls `CloseAllPositions(MagicNumber)` for the trend basket now also calls `CloseAllPositions(MAGIC_OVERLAY)` + `ResetOverlayState()`. This ensures overlay positions never become orphaned when:
- Daily loss limit triggers
- Daily profit target triggers
- Basket stop loss triggers
- Peak giveback exit triggers
- EMA10 invalidation exit triggers

### Patch 2 — `tradingDisabled` Guard

Added `if(tradingDisabled) return;` guard at the top of the overlay entry block in OnTick. Prevents new overlay activation after daily limits have been hit.

### Patch 3 — Signal Re-Arm Fix

`DetectTickExhaustion()` exhaustion fired flag is now properly reset when a new impulse is detected, preventing stale exhaustion signals from persisting across impulse cycles.

### Patch 4 — Grid Safety Lock

`ManageOverlayGrid()` now checks `CountBasketPositions(MAGIC_OVERLAY) >= OverlayMaxPositions` using **live position count** rather than trusting `overlayGridCount`. Prevents count desync from causing unlimited grid expansion.

### Patch 5 — Overlay Daily P&L Tracking

Added `overlayDailyRealizedPL` accumulation in `OnTradeTransaction()` for `MAGIC_OVERLAY` closed trades. Overlay realized P&L now participates in daily accounting.

### Patch 6 — Time Expiry

Overlay basket auto-closes after `OverlayTimeExpiry_Bars` M1 bars have elapsed since `overlayEntryTime`. Prevents indefinite overlay exposure in ranging markets.

### Patch 7 — Swing Reference Fix

`overlaySwingReference` is now captured at overlay entry time (snapshot of impulse high/low) and remains fixed for the life of the overlay basket, instead of tracking live price.

### Patch 8 — OnInit Diagnostic Prints

Added overlay configuration print block in `OnInit()` that logs all overlay input parameters when `OVERLAY_ENABLED` is defined. Aids backtesting verification.

---

## v5.0.4 — TrendPermissionEA_v5_0_4

**File:** `TrendPermissionEA_v5_0_4.mq5`
**Description:** *"Unified Daily Risk Budget"*

### What Changed

Merged overlay realized P&L tracking into the single `dailyRealizedPL` variable, eliminating the separate `overlayDailyRealizedPL` introduced in v5.0.3.

### The Problem

v5.0.3 tracked overlay realized P&L in a separate `overlayDailyRealizedPL` variable. This created a split accounting problem: daily loss/profit checks only looked at `dailyRealizedPL` (trend), so overlay losses could accumulate without triggering daily safety limits.

### The Fix

- **Removed** `overlayDailyRealizedPL` global variable entirely
- **Modified** `OnTradeTransaction()`: the deal accumulation logic now matches on `deal_magic == MagicNumber || deal_magic == MAGIC_OVERLAY`
- Both trend and overlay closed P&L flow into `dailyRealizedPL`
- All existing daily risk checks (`DailyLossLimit_USD`, `DailyProfitTarget_USD`) now automatically cover overlay activity
- **Zero new code paths** — the existing risk governor framework handles both sources transparently

### Design Principle

Single source of truth. One variable, one accumulator, one set of risk checks. No split budgets, no reconciliation.

---

## v5.0.5 — TrendPermissionEA_v5_0_5

**File:** `TrendPermissionEA_v5_0_5.mq5`
**Description:** *"Decoupled Basket Floor from Daily Target"*

### What Changed

The basket profit floor exit was previously coupled to `DailyProfitTarget_USD`. This version introduces independent basket-level floor parameters.

### The Problem

In v3.9+, the floor exit used `DailyProfitTarget_USD` as its trigger, creating an unwanted dependency between daily target policy and per-basket floor behavior. Changing the daily target inadvertently changed the floor trigger.

### New Input Parameters

| Parameter | Default | Since | Description |
|-----------|---------|-------|-------------|
| `UseDailyProfitFloor` | true | v5.0.5 | Enable/disable the basket profit floor |
| `BasketProfitFloorTrigger_USD` | 50.0 | v5.0.5 | Basket floating P&L must reach this level to arm the floor |
| `BasketProfitFloorLevel_USD` | 25.0 | v5.0.5 | Once armed, exit basket if P&L falls back to this level |

### Logic

1. Basket floating P&L rises above `BasketProfitFloorTrigger_USD` → floor is **armed**
2. If P&L then falls back to `BasketProfitFloorLevel_USD` → close basket with reason `"BASKET FLOOR EXIT"`
3. Sets `tradingDisabled = true` on trigger (day is done)
4. Overlay positions are sync-closed with reason `"Layer0_BasketProfitFloor"`

### Removed

- Stale `"DAILY FLOOR EXIT (Ready)"` string from `CheckPositionStatus()` disable reason check

---

## v5.0.6 — TrendPermissionEA_v5_0_6

**File:** `TrendPermissionEA_v5_0_6.mq5`
**Description:** *"Overlay Activation Threshold Implemented"*

### What Changed

Added a floating loss gate to overlay entry. The overlay engine now only activates when the trend basket is under meaningful stress.

### Logic

In the overlay entry block (OnTick), added condition:

```
basketFloatingPL <= -OverlayActivationThreshold_USD
```

The overlay will **not** activate unless the trend basket's floating P&L is at or below the negative threshold. This prevents the overlay from firing on minor pullbacks that the trend basket can absorb naturally.

### Input Parameter

| Parameter | Default | Since | Description |
|-----------|---------|-------|-------------|
| `OverlayActivationThreshold_USD` | 10.0 | v5.0.0 (stub) / v5.0.6 (active) | Min trend basket floating loss before overlay can activate |

### Why This Matters

Without this gate, the overlay could activate on any detected impulse+exhaustion, even when the trend basket is in profit. This wastes margin and creates unnecessary counter-exposure.

---

## v5.0.7 — TrendPermissionEA_v5_0_7

**File:** `TrendPermissionEA_v5_0_7.mq5`
**Description:** *"Exposure Control — Overlay Blocks New Trend Entries"*

### What Changed

Added an exposure guard in `ExecuteTradeLogic()` that prevents new trend basket entries while the overlay engine has open positions.

### Logic

At the top of `ExecuteTradeLogic()`:

```
if(EnableOverlayEngine && OverlayHasPositions())
   return;  // Block new trend basket entries while overlay is active
```

### What This Blocks

- New initial trend basket entries
- Continuation reentry after peak giveback

### What This Does NOT Block

- Grid adds to existing trend basket (handled in `ManageGrid()`, not `ExecuteTradeLogic()`)
- Trend basket exits (stop loss, floor, peak giveback — all run before execution)
- Overlay engine operations (managed independently)

### Why This Matters

Running a counter-trend overlay while simultaneously opening new trend entries creates contradictory exposure. This guard ensures the two systems don't fight each other with new capital.

---

## v5.0.8 — TrendPermissionEA_v5_0_8

**File:** `TrendPermissionEA_v5_0_8.mq5`
**Description:** *"Indicator Handle Caching for Stability"*

### What Changed

Replaced per-call `iMA()` / `iATR()` / `iADX()` handle creation with persistent cached handles created once in `OnInit()` and released in `OnDeinit()`.

### The Problem

Previous versions called `iMA()`, `iATR()`, and `iADX()` inside calculation functions on every invocation. While MT5 internally caches handles, this pattern creates unnecessary overhead and risks handle exhaustion in long-running sessions.

### Cached Handles (6 total)

| Handle | Indicator | Parameters | Used In |
|--------|-----------|------------|---------|
| `hEmaHigh` | `iMA(EMA200, High)` | TrendEMA_Len, MODE_EMA, PRICE_HIGH | `CalculateEMAs_Frozen()` |
| `hEmaLow` | `iMA(EMA200, Low)` | TrendEMA_Len, MODE_EMA, PRICE_LOW | `CalculateEMAs_Frozen()` |
| `hEmaFast` | `iMA(EMA10)` | FastEMA_Len, MODE_EMA, PRICE_CLOSE | `CalculateEMAs_Frozen()` |
| `hEmaSlow` | `iMA(EMA30)` | SlowEMA_Len, MODE_EMA, PRICE_CLOSE | `CalculateEMAs_Frozen()` |
| `hATR` | `iATR(14)` | ImpulseATR_Period | `DetectImpulseCandle()` |
| `hADX` | `iADX(M30, 14)` | ADX_Timeframe, ADX_Period | `UpdateHTF_ADX()` |

### Lifecycle

- **OnInit:** All 6 handles created via `iMA()` / `iATR()` / `iADX()`. Each validated against `INVALID_HANDLE` — init fails with `INIT_FAILED` if any handle cannot be created.
- **CalculateEMAs_Frozen() / UpdateHTF_ADX():** Rewritten to use `CopyBuffer()` with cached handles only. No `iMA()` / `iATR()` / `iADX()` calls inside calculation loops.
- **OnDeinit:** All 6 handles released via `IndicatorRelease()` with `INVALID_HANDLE` guards (only release valid handles).

---

## v5.0.9 — TrendPermissionEA_v5_0_9

**File:** `TrendPermissionEA_v5_0_9.mq5`
**Description:** *"Overlay Structural Stop Hardening"*

### What Changed

`CheckOverlayStructuralStop()` now uses the fixed `overlaySwingReference` captured at entry time, instead of the live `overlayImpulseHigh` / `overlayImpulseLow` globals.

### The Problem

The structural stop was comparing against `overlayImpulseHigh` / `overlayImpulseLow`, which could be overwritten by a new impulse detection cycle while an overlay basket was still active. This created a moving stop level — the structural invalidation point would shift with each new impulse, defeating its purpose as a fixed invalidation reference.

### The Fix

- `CheckOverlayStructuralStop()` now reads `overlaySwingReference` exclusively
- For **sell overlay:** invalidation at `overlaySwingReference + OverlayStructuralStop_USD`
- For **buy overlay:** invalidation at `overlaySwingReference - OverlayStructuralStop_USD`
- Print messages updated to show `SwingRef=` instead of `ImpulseHigh=` / `ImpulseLow=`
- `overlaySwingReference` is set once at overlay entry and never modified during the basket's lifetime

---

## v5.0.10 — TrendPermissionEA_v5_0_10

**File:** `TrendPermissionEA_v5_0_10.mq5`
**Description:** *"Final Sequencing & State Hardening"*

### What Changed

Four targeted changes for execution correctness and state cleanliness.

### Change 1 — Execution Reorder: Stop Before Grid

Overlay execution in OnTick reordered:

**Before (v5.0.9):**
```
ManageOverlayGrid() → CheckOverlayStructuralStop() → CheckOverlayProfitTarget()
```

**After (v5.0.10):**
```
CheckOverlayStructuralStop() → CheckOverlayProfitTarget() → ManageOverlayGrid()
```

**Why:** The structural stop and profit target must be evaluated *before* allowing grid expansion. Running the grid first could add a position to a basket that should have been closed, wasting a trade on a doomed position.

### Change 2 — Time Expiry Guard

Added `overlayEntryTime > 0` guard to the time expiry check. Prevents division-by-zero or false triggering when `overlayEntryTime` has not been set (e.g., during state transitions or recovery).

### Change 3 — Remove Unused `overlayPeakFloatingPL`

Removed the `overlayPeakFloatingPL` global variable entirely:
- Removed from global declarations
- Removed from `ResetOverlayState()`
- No overlay logic referenced it (was a placeholder for potential future giveback logic that was never implemented)

### Change 4 — Derived `overlayActive`

`overlayActive` is now **fully derived** from live position data, following the same principle as the trend basket's derived state (established in v3.7).

**Implementation:**
- Single `overlayActive = OverlayHasPositions()` call at top of OnTick, immediately after Layer0_RiskCheck
- **Removed** all manual `overlayActive = true` / `overlayActive = false` mutations:
  - Removed from `ResetOverlayState()` (was setting to `false`)
  - Removed from `ManageOverlayGrid()` safety lock (was setting to `false`)
  - Removed from overlay entry success block (was setting to `true`)

**Why:** Manual flag mutations can desync from reality. Deriving from `OverlayHasPositions()` (which counts live positions with `MAGIC_OVERLAY`) is the single source of truth.

---

## Input Parameters — Complete Reference (v5.0.10)

### Group 00: Layer 0 — Global Risk Governor

| Parameter | Default | Since | Description |
|-----------|---------|-------|-------------|
| `BasketStopLoss_USD` | 20.0 | v3.2 | Per-basket stop loss in USD |
| `DailyLossLimit_USD` | 100.0 | v3.2 | Daily loss limit — disables trading for NY day |
| `DailyProfitTarget_USD` | 100.0 | v3.2 | Daily realized profit target |
| `PeakGivebackFrac` | 0.25 | v3.0 | Fraction of peak profit allowed to give back |
| `MinProfitToProtect_USD` | 5.0 | v3.1 | Min peak P&L before protection activates |
| `BrokerToNYOffsetHours` | -7 | v3.4 | Broker time offset to New York (hours) |
| `UseDailyProfitFloor` | true | v5.0.5 | Enable/disable independent basket profit floor |
| `BasketProfitFloorTrigger_USD` | 50.0 | v5.0.5 | Basket floating P&L to arm the floor |
| `BasketProfitFloorLevel_USD` | 25.0 | v5.0.5 | Once armed, exit basket if P&L falls to this level |

### Group 01: Trend EMAs (Frozen)

| Parameter | Default | Since | Description |
|-----------|---------|-------|-------------|
| `TrendEMA_Len` | 200 | v1.0 | Trend EMA length (high/low channel) |
| `FastEMA_Len` | 10 | v1.0 | Fast EMA length |
| `SlowEMA_Len` | 30 | v1.0 | Slow EMA length |

### Group 02: Execution Settings

| Parameter | Default | Since | Description |
|-----------|---------|-------|-------------|
| `LotSize` | 0.01 | v2.0 | Fixed lot size per trade |
| `TakeProfitDollars` | 5.0 | v2.0 | **DEPRECATED since v3.9** — unused |
| `FixedGridGap_USD` | 4.0 | v3.9 | USD gap between grid pyramiding adds |
| `MagicNumber` | 123456 | v2.0 | EA magic number |

### Group 04: Regime Filter — HTF ADX

| Parameter | Default | Since | Description |
|-----------|---------|-------|-------------|
| `ADX_Timeframe` | PERIOD_M30 | v3.9.4 | HTF timeframe for ADX calculation |
| `ADX_Period` | 14 | v3.9.4 | ADX indicator period |
| `ADX_Threshold` | 25.0 | v3.9.4 | Minimum ADX to allow new basket |
| `EnableADXFilter` | true | v3.9.4 | Enable/disable the filter |

### Group 05: v3.9.6 Structural Failure Controls

| Parameter | Default | Since | Description |
|-----------|---------|-------|-------------|
| `EnableMAEStop` | true | v3.9.6 | Enable/disable the MAE soft stop |
| `MAE_Stop_USD` | 12.0 | v3.9.6 | MAE threshold — close basket at this drawdown |
| `EnableTimeStop` | true | v3.9.6 | Enable/disable the time stop |
| `TimeStopBars` | 12 | v3.9.6 | Bars since basket start before staleness check |
| `MinMFEForTimeStop_USD` | 3.0 | v3.9.6 | Minimum MFE to keep basket alive past time limit |
| `EnableExpansionFailure` | true | v3.9.6 | Enable/disable expansion failure exit |
| `ExpansionFailureBars` | 6 | v3.9.6 | Consecutive non-expanding bars before exit |

### Group 06: v3.9.7 Expansion Maximizer

| Parameter | Default | Since | Description |
|-----------|---------|-------|-------------|
| `EnableExpansionMultiplier` | true | v3.9.7 | Enable/disable expansion-aware lot sizing |
| `ExpansionMultiplier` | 2.0 | v3.9.7 | Lot multiplier during expansion regime |
| `ADXExpansionBuffer` | 5.0 | v3.9.7 | ADX must exceed Threshold + Buffer for expansion |
| `MaxBasketLots` | 0.08 | v3.9.7 | Maximum total lots across all basket positions |

### Group 07: v5.0.0+ Overlay Engine — Detection

| Parameter | Default | Since | Description |
|-----------|---------|-------|-------------|
| `ImpulseBodyMultiple` | 1.5 | v5.0.1 | Body ≥ N × ATR to qualify as impulse candle |
| `ImpulseATR_Period` | 14 | v5.0.1 | ATR period for impulse detection |
| `ExhaustionTickCount` | 30 | v5.0.1 | Consecutive non-extending ticks to confirm exhaustion |

### Group 08: v5.0.0+ Overlay Engine — Execution

| Parameter | Default | Since | Description |
|-----------|---------|-------|-------------|
| `EnableOverlayEngine` | true | v5.0.0 | Master enable/disable for overlay engine |
| `OverlayGridGap_USD` | 3.0 | v5.0.0 | USD gap between overlay grid adds |
| `OverlayMaxPositions` | 4 | v5.0.0 | Maximum overlay grid positions |
| `OverlayTakeProfit_USD` | 8.0 | v5.0.0 | Overlay basket profit target in USD |
| `OverlayTimeExpiry_Bars` | 30 | v5.0.0 | Max overlay basket duration in M1 bars |
| `OverlayStructuralStop_USD` | 5.0 | v5.0.0 | USD beyond swing reference for structural invalidation |
| `OverlayActivationThreshold_USD` | 10.0 | v5.0.0 / v5.0.6 | Min trend basket floating loss to activate overlay |

### Group 03: Debug

| Parameter | Default | Since | Description |
|-----------|---------|-------|-------------|
| `EnableDebugPrints` | true | v1.0 | Enable debug print output |

---

## Risk Priority Order — Final (v5.0.10)

| Priority | Check | Scope | Action | Since |
|----------|-------|-------|--------|-------|
| 1 | Daily Loss Limit | Account/Daily | Close all (trend + overlay), disable trading | v3.2 / v5.0.3 |
| 2 | EMA10 Invalidation | Basket/Structural | Close basket + sync overlay close | v4.0 / v5.0.3 |
| 3 | Basket Stop Loss | Basket/P&L | Close basket + sync overlay close, trading continues | v3.2 / v5.0.3 |
| 4a | Basket Profit Floor | Basket/Profit | Close basket + sync overlay close, disable trading | v5.0.5 |
| 4b | Peak Giveback | Basket/Profit | Close basket + sync overlay close, **arm continuation** | v3.0 / v5.0.3 |
| 5 | Daily Profit Target | Account/Daily | Close all (trend + overlay), disable trading | v3.0 / v5.0.3 |
| 6 | Overlay Structural Stop | Overlay/Structural | Close overlay basket only | v5.0.2 / v5.0.9 |
| 7 | Overlay Profit Target | Overlay/P&L | Close overlay basket only | v5.0.2 |
| 8 | Overlay Time Expiry | Overlay/Staleness | Close overlay basket only | v5.0.3 |

---

## Key Architectural Decisions

### Frozen Trend Module (since v2.0)
The trend permission logic from v1.0 has never been modified in its core formula. New filters (v3.8) were added as **gates on top of** the existing output, not changes to the underlying calculation. This ensures the detection layer is stable and independently testable.

### Derived State (since v3.7)
All basket state (active/direction/position count) is **derived from live position data** on every tick. There are no stored flags that could desync from reality. This is the single most important correctness guarantee in the system.

### Single Source of Truth for Realized P&L (since v3.7)
`dailyRealizedPL` is updated **only** in `OnTradeTransaction()`. No other code path modifies it. This eliminates double-counting and ensures daily limits are accurate.

### Tick-Based vs Bar-Based Logic
| Logic | Timing | Reason |
|-------|--------|--------|
| Risk checks | Every tick | Must catch stop levels immediately |
| Force flip | Every tick | Must react to permission change immediately |
| Continuation reentry | Every tick | Must enter before next bar close |
| Grid adds | Every tick | Price gap is continuous |
| Overlay grid adds | Every tick | Price gap is continuous |
| Overlay structural stop | Every tick | Must catch invalidation immediately |
| Overlay profit target | Every tick | Must lock in profit immediately |
| Tick exhaustion | Every tick | Tick-level microstructure detection |
| Trend permission | New bar only | EMAs are bar-based indicators |
| Initial entry | New bar only | Follows permission transition |
| Impulse candle detection | New bar only | Evaluates completed M1 candle |

### Overlay Engine Design (since v5.0.0)
The overlay engine operates as a **compile-gated, counter-trend grid** that activates during trend basket drawdowns. Key design decisions:
- **Compile gate:** `#define OVERLAY_ENABLED` — entire overlay system compiles out when not defined
- **Separate magic:** `MAGIC_OVERLAY = 987654` — overlay positions never mix with trend positions
- **Unified daily budget:** Overlay and trend P&L share a single `dailyRealizedPL` via `OnTradeTransaction()` (v5.0.4)
- **Derived state:** `overlayActive = OverlayHasPositions()` — no stored flags, derived every tick (v5.0.10)
- **Fixed swing reference:** Structural stop uses entry-time snapshot, not live impulse data (v5.0.9)
- **Exposure control:** New trend entries blocked while overlay is active (v5.0.7)
- **Execution order:** Stop → Profit target → Grid expansion (v5.0.10) — never expand a doomed basket

---

## File List

| File | Version | Lines |
|------|---------|-------|
| `TrendPermissionEA.mq5` | v1.0 | 288 |
| `TrendPermissionEA_v2.mq5` | v2.0 | 491 |
| `TrendPermissionEA_v3.mq5` | v3.0 | 982 |
| `TrendPermissionEA_v3_1.mq5` | v3.1 | 1044 |
| `TrendPermissionEA_v3_2.mq5` | v3.2 | 1170 |
| `TrendPermissionEA_v3_3.mq5` | v3.3 | 1207 |
| `TrendPermissionEA_v3_4.mq5` | v3.4 | 988 |
| `TrendPermissionEA_v3_5.mq5` | v3.5 | 900 |
| `TrendPermissionEA_v3_6.mq5` | v3.6 | 961 |
| `TrendPermissionEA_v3_7.mq5` | v3.7 | 1063 |
| `TrendPermissionEA_v3_8.mq5` | v3.8 | 1137 |
| `TrendPermissionEA_v3_9.mq5` | v3.9 | 1283 |
| `TrendPermissionEA_v3_9_1.mq5` | v3.9.1 | 1313 |
| `TrendPermissionEA_v3_9_2.mq5` | v3.9.2 | 1440 |
| `TrendPermissionEA_v4_0.mq5` | v4.0 | 1347 |
| `TrendPermissionEA_v4_1.mq5` | v4.1 | 1448 |
| `TrendPermissionEA_v3_9_4.mq5` | v3.9.4 | 1366 |
| `TrendPermissionEA_v3_9_5.mq5` | v3.9.5 | 1394 |
| `TrendPermissionEA_v3_9_6.mq5` | v3.9.6 | 1493 |
| `TrendPermissionEA_v3_9_7.mq5` | v3.9.7 | 1446 |
| `TrendPermissionEA_v4_5.mq5` | v4.5 | 1473 |
| `TrendPermissionEA_v5_0_0.mq5` | v5.0.0 | 1498 |
| `TrendPermissionEA_v5_0_1.mq5` | v5.0.1 | 1539 |
| `TrendPermissionEA_v5_0_2.mq5` | v5.0.2 | 1729 |
| `TrendPermissionEA_v5_0_3.mq5` | v5.0.3 | 1846 |
| `TrendPermissionEA_v5_0_4.mq5` | v5.0.4 | 1837 |
| `TrendPermissionEA_v5_0_5.mq5` | v5.0.5 | 1845 |
| `TrendPermissionEA_v5_0_6.mq5` | v5.0.6 | 1846 |
| `TrendPermissionEA_v5_0_7.mq5` | v5.0.7 | 1854 |
| `TrendPermissionEA_v5_0_8.mq5` | v5.0.8 | 1856 |
| `TrendPermissionEA_v5_0_9.mq5` | v5.0.9 | 1858 |
| `TrendPermissionEA_v5_0_10.mq5` | v5.0.10 | 1861 |
| `TrendPermissionDebugger.mq5` | — | Debug utility |
