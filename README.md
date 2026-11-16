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
| 4. Main window | not started; results print to chat for now |
| 5. Settings panel, polish | not started; settings work through slash commands |

## Install

Copy the `VendorSniper` folder to:

```
World of Warcraft\_forever_\Interface\AddOns\VendorSniper\
```

## Usage

1. Open the Auction House and run a normal search.
2. `/vsniper scan` evaluates the browse results that search returned.
3. `/vsniper results` lists the opportunities.
4. `/vsniper inspect` fetches the individual listings for promising rows. Browse rows only show the lowest price, so their profit is a lower bound.
   * `click` mode (default): one search per command.
   * `batch` mode (`/vsniper lookup batch [perMinute]`): queues every candidate. Searches are sent one at a time, within the AH throttle and a per-minute budget (default 30, max 90).
5. Opening an item in the normal Auction House window is picked up automatically. Its exact listings replace the browse estimate.

Other commands: `stop`, `sort <key>`, `minprofit <amount>`, `minroi <percent>`,
`maxbuyout <amount|0>`, `sound on|off [threshold]`, `status`, `probe`, `help`.

Profit is theoretical: vendor value minus buyout, before anything is bought.

## Tests

The pure-Lua logic and an end-to-end run of the whole addon against stubbed
game globals run in MoonSharp (a C# Lua interpreter) under xUnit:

```bash
dotnet test Tests/VendorSniper.Tests
```

## Layout

```
VendorSniper/
  VendorSniper.toc
  Core.lua                 init, events, slash commands, wiring
  Diagnostics.lua          chat output, /vsniper probe
  Logic/                   pure: Money, ProfitCalculator, Listings, AuctionEvaluator,
                           Categories, Sorting, Settings
  Data/                    ItemCache, ResultStore (session only)
  Services/                WoWAPI (the only file that calls C_AuctionHouse / C_Item),
                           VendorPriceService, ScannerScheduler, AuctionScanner
  Util/Callbacks.lua
Tests/VendorSniper.Tests/  xUnit + MoonSharp, fixtures in TestFixtures/
docs/COMPATIBILITY.md      API research and in-game checklist
```
