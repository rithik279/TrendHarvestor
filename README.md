# Trend Harvestor

**TrendPermissionEA** — A layered, regime-aware gold (XAUUSD) trading system for MetaTrader 5.

> Built from the ground up on M1/M5 with a frozen trend permission module, a grid pyramiding execution layer, a Layer 0 risk governor, and an optional counter-trend overlay engine. Version history spans 30+ iterations.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [File Map](#file-map)
- [Version History](#version-history)
- [Key Design Decisions](#key-design-decisions)
- [Risk Priority Order](#risk-priority-order)

---

## Overview

| Property | Value |
|---|---|
| **Symbol** | XAUUSD (Gold) |
| **Platform** | MetaTrader 5 (MQL5) |
| **Primary Timeframe** | M1 (main) / M5 (v5.1) |
| **Strategy Type** | Trend-following grid pyramid with counter-trend overlay |
| **Magic Number** | `123456` (trend basket), `987654` (overlay basket) |

### What It Does

1. **Detects** trend entry permission regimes using a frozen EMA200/EMA10/EMA30 channel system
2. **Enters** a basket of positions and pyramids adds as the trend extends
3. **Manages** risk via a 5-priority Layer 0 risk governor (daily limits, basket stops, structural exits)
4. **Optionally fades** the impulse with a counter-trend overlay grid when the trend basket is under stress
5. **Never** modifies the core trend permission formula after v1.0

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  LAYER 0 — Risk Governor (v3.0+)                            │
│  Daily limits · Basket stops · Peak giveback · Floor exits   │
├──────────────────────────────────────────────────────────────┤
│  TREND PERMISSION MODULE (v1.0+, FROZEN — never modified)   │
│  EMA200 regime · EMA10/EMA30 slopes · Gap dynamics            │
├──────────────────────────────────────────────────────────────┤
│  EXECUTION LAYER (v2.0+)                                     │
│  Grid pyramiding · Continuation reentry · Force flip          │
├──────────────────────────────────────────────────────────────┤
│  OVERLAY ENGINE (v5.0.0+, compile-gated)                     │
│  Counter-trend grid · Structural stop · Impulse detection     │
├──────────────────────────────────────────────────────────────┤
│  PANEL / UI (v3.0+)                                          │
│  On-chart dashboard of all state variables                    │
└──────────────────────────────────────────────────────────────┘
```

---

## Quick Start

1. Copy the `.mq5` file of your chosen version into your MT5 `MQL5/Experts/` directory
2. Compile in the MetaEditor
3. Attach to an XAUUSD M1 chart (or M5 for v5.1)
4. Configure input parameters as needed

### Enabling the Overlay Engine (v5.0.0+)

Add this define at the top of the file:
```mql5
#define OVERLAY_ENABLED
```
The overlay engine is compile-gated and completely inert when undefined.

---

## File Map

### Active Versions (Root Directory)

| File | Version | Description |
|------|---------|-------------|
| `TrendPermissionEA_v5_1.mq5` | **v5.1** | M5 port of v3.9.4 — latest production variant |
| `TrendPermissionEA_v3_9_7.mq5` | v3.9.7 | M1 — Expansion Maximizer |
| `TrendPermissionEA_v3_9_4.mq5` | v3.9.4 | M1 — HTF ADX regime filter |
| `TrendPermissionEA_v3_9.mq5` | v3.9 | M1 — Grid pyramiding + asymmetric basket TP |
| `TrendPermissionDebugger.mq5` | — | Debugging utility |
| `VolatilityCompressorEA_v0_2.mq5` | v0.2 | Production — Physics-driven impulse detection + velocity decay |
| `VolatilityCompressorEA_v0_1.mq5` | v0.1 | Diagnostic — Regime state machine + tick velocity |
| `VERSION_HISTORY.md` | — | Full version-by-version changelog |

### OldVersions (Full Version Archive)

Contains all 30+ intermediate builds from v1.0 through v5.0.10:
- `TrendPermissionEA.mq5` (v1.0) through `TrendPermissionEA_v5_0_11.mq5`
- Full changelog in `VERSION_HISTORY.md`

---

## Version History

> Full detailed changelog with rationale, code changes, and architecture decisions is available in [VERSION_HISTORY.md](./VERSION_HISTORY.md).

### Major Milestones

| Version | Release Name | Core Feature |
|---------|-------------|--------------|
| [v1.0](#v10) | TrendPermissionEA | Trend detection only (no trading) |
| [v2.0](#v20) | Bare-Bones Execution | First live execution layer |
| [v3.0](#v30) | Layer 0 Risk Governor | Risk management introduced |
| [v3.9](#v39) | Grid Pyramiding | Fixed grid adds + asymmetric basket TP |
| [v4.0](#v40) | EMA10 Invalidation | Structural trend invalidation exit |
| [v4.5](#v45) | Modular Batch Engine | Clean-room execution chassis |
| [v5.0.0](#v500) | Overlay Scaffolding | Compile-gated overlay engine foundation |
| [v5.0.10](#v5010) | Final Sequencing | Overlay execution hardening |
| [v5.1](#v51) | M5 Timeframe Port | v3.9.4 ported to M5 timeframe |

---

## Key Design Decisions

### 1. Frozen Trend Module (since v2.0)

The trend permission logic from v1.0 has **never been modified in its core formula**. New filters were added as **gates on top of** the existing output. This makes the detection layer stable and independently testable across all subsequent versions.

### 2. Derived State (since v3.7)

All basket state (active/direction/position count) is **derived from live position data** on every tick. There are no stored flags that could desync from reality. This is the single most important correctness guarantee in the system.

```mql5
// Basket active is NEVER a stored flag — always derived:
bool BasketHasPositions() { return CountBasketPositions(MagicNumber) > 0; }
```

### 3. Single Source of Truth for Realized P&L (since v3.7)

`dailyRealizedPL` is updated **only** in `OnTradeTransaction()`. No other code path modifies it. This eliminates double-counting and ensures daily limits are accurate.

### 4. Tick-Based vs Bar-Based Logic

| Logic | Timing | Reason |
|-------|--------|--------|
| Risk checks | Every tick | Must catch stop levels immediately |
| Force flip | Every tick | Must react to permission change immediately |
| Grid adds | Every tick | Price gap is continuous |
| Trend permission | New bar only | EMAs are bar-based indicators |
| Initial entry | New bar only | Follows permission transition |
| Impulse detection | New bar only | Evaluates completed M1/M5 candle |

### 5. Overlay Engine Design (since v5.0.0)

The overlay engine operates as a **compile-gated, counter-trend grid** that activates during trend basket drawdowns:

- **Compile gate:** `#define OVERLAY_ENABLED` — compiles out entirely when undefined
- **Separate magic:** `MAGIC_OVERLAY = 987654` — never mixes with trend positions
- **Unified daily budget:** Overlay and trend P&L share a single `dailyRealizedPL`
- **Fixed swing reference:** Structural stop uses entry-time snapshot, never live price
- **Execution order:** Stop → Profit target → Grid expansion (never expand a doomed basket)

---

## Risk Priority Order

### Trend Basket (Layer 0)

| Priority | Check | Scope | Action | Since |
|----------|-------|-------|--------|-------|
| 1 | Daily Loss Limit | Account/Daily | Close all + disable trading | v3.2 |
| 2 | EMA10 Invalidation | Basket/Structural | Close basket | v4.0 |
| 3 | Basket Stop Loss | Basket/P&L | Close basket, trading continues | v3.2 |
| 4a | Basket Profit Floor | Basket/Profit | Close basket + disable trading | v5.0.5 |
| 4b | Peak Giveback | Basket/Profit | Close basket + arm continuation | v3.0 |
| 5 | Daily Profit Target | Account/Daily | Close all + disable trading | v3.0 |

### Overlay Basket

| Priority | Check | Scope | Action | Since |
|----------|-------|-------|--------|-------|
| 6 | Structural Stop | Overlay/Structural | Close overlay only | v5.0.2 |
| 7 | Profit Target | Overlay/P&L | Close overlay only | v5.0.2 |
| 8 | Time Expiry | Overlay/Staleness | Close overlay only | v5.0.3 |

---

## License

MIT License — Free to use, modify, and distribute.
