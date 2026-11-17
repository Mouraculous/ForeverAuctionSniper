# ForeverAuctionSniper (Vendor Sniper)

A World of Warcraft: Forever addon that finds Auction House listings priced
below the item's vendor sell price. It only reads what the Auction House
already shows you. You do the browsing and the buying yourself.

Target client: **WoW Forever 1.60.1, interface 16001**. The API research is in
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## Status

| Milestone | State |
|---|---|
| 1. Environment, TOC, loading, `/vsniper probe` | done, not yet verified in-game |
| 2. Scanner (browse results, item and commodity listings, lifecycle) | done, not yet verified in-game |
| 3. Vendor prices, profit, evaluation, tests | done (unit + smoke tests pass) |
| 4. Auction House tab (results table, sorting, filters, progress) | done, not yet verified in-game |
| 5. Settings polish, notifications, performance pass | partly: filters, lookup mode and sound are in the tab |

## Install

Copy the `VendorSniper` folder to:

```
World of Warcraft\_forever_\Interface\AddOns\VendorSniper\
```

## Usage

1. Open the Auction House and run a normal search in the **Buy** tab.
2. Switch to the **Vendor Sniper** tab (next to Buy / Sell / Auctions) and press **Scan**.
   It evaluates the results your search returned; no extra server queries.
3. The table lists listings below vendor price, sorted by profit. Click a column header to sort.
   * Profit marked `*` is a lower bound from browse data (the AH only reports the lowest price there).
   * **Inspect** looks up the exact listings of the best candidate. With **Batch inspect** on
     (left column), **Inspect all** looks up every candidate, one search at a time and within
     a per-minute budget (default 30, max 90).
   * Opening an item in the Buy tab yourself also updates the table with its exact listings.
4. Click a row to put the item's name in the Buy tab's search box, then press Enter and buy
   it with Blizzard's own buttons. Shift-click links the item in chat; right-click for more options.
5. The left column holds the filters: categories, qualities, minimum profit, maximum buyout,
   minimum ROI, batch inspect and the optional sound alert. They're saved between sessions.

Profit is theoretical: vendor value minus buyout, before anything is bought.

Slash commands do the same from chat: `/vsniper show | scan | results | inspect | stop |
lookup click|batch [perMinute] | sort <key> | minprofit <amount> | minroi <percent> |
maxbuyout <amount|0> | sound on|off [threshold] | status | probe | help`.

## Tests

The pure-Lua logic, an end-to-end run of the whole addon against stubbed
game globals, and the Auction House tab against stub frames run in
MoonSharp (a C# Lua interpreter) under xUnit:

```bash
dotnet test Tests/VendorSniper.Tests
```

The stubs check wiring and behaviour, not how the tab looks. Layout and visuals
need a check in the real client.

## Layout

```
VendorSniper/
  VendorSniper.toc
  Core.lua                 init, events, slash commands, wiring
  Diagnostics.lua          chat output, /vsniper probe
  Logic/                   pure: Money, ProfitCalculator, Listings, AuctionEvaluator,
                           Categories, Sorting, Settings, ResultsView (display texts)
  Data/                    ItemCache, ResultStore (session only)
  Services/                WoWAPI (the only file that calls C_AuctionHouse / C_Item),
                           VendorPriceService, ScannerScheduler, AuctionScanner
  UI/                      MainWindow (AH tab), ResultsList, FilterPanel, Templates.xml
  Util/Callbacks.lua
Tests/VendorSniper.Tests/  xUnit + MoonSharp, fixtures and stubs in TestFixtures/
docs/COMPATIBILITY.md      API research and in-game checklist
```
