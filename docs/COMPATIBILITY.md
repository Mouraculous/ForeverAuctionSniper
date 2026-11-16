# Vendor Sniper: WoW Forever Compatibility Report

Milestone 1 deliverable. Written 2026-11-16, before any addon code.

## 0. Sources and confidence

| Tag | Source | Reliability |
|---|---|---|
| **[UI]** | Blizzard's own UI source for the Forever client, mirrored at `Gethe/wow-ui-source`, branch `forever`, commit `bebcb6b` titled **"1.60.1 (70938)"** (13 Nov 2026). Includes `Blizzard_APIDocumentationGenerated`, the machine-generated API docs the client ships with. | Authoritative for function names, signatures, fields and events. Says nothing about runtime behaviour. |
| **[COM]** | Community developer guides: wowforeverguides.com/addons/developers, forevermeta.me. | Mostly based on beta builds 69913–70338. Treat as hints. |
| **[INF]** | My inference from how Blizzard's own AH UI uses the API. | Needs in-game confirmation (see §9). |

I can't run the game client from here. Everything marked **[INF]** or **[COM]** is on the in-game checklist in §9.

## 1. Client identity

| Item | Finding | Tag |
|---|---|---|
| Product | *World of Warcraft: Forever*, launched 4 Nov 2026. A standalone branch that runs alongside Retail and Classic. Players are split by ruleset (Normal/PvP/RP/RP-PvP) onto one mega-realm per ruleset per region. | [COM] |
| Client version / build | **1.60.1, build 70938** | [UI] |
| Interface version (TOC) | **16001** (Classic Era is 11509, Midnight is 120100+) | [COM], probe: `/dump select(4, GetBuildInfo())` |
| UI code base | **Mainline family**, internal game type `camelot`. AH files load `Shared/` and `Mainline/` code, plus a Forever-only `Camelot/Blizzard_AuctionData.lua` for categories. | [UI] |
| `WOW_PROJECT_ID` | Reported as 18 (`WOW_PROJECT_CAMELOT`) on build 70338, 1 on build 69913. **Don't branch on it.** Probe for APIs instead. | [COM] |
| Lua | Modified Lua 5.1: no `goto`, `//`, bitwise operators, `_ENV`, `require`, `io`, `os`. `bit.*` library available. | [COM], probe: `/dump _VERSION` |
| AddOns folder | `World of Warcraft\_forever_\Interface\AddOns\VendorSniper\` | [COM] |

**Consequence:** Classic Era auction addons and the legacy `QueryAuctionItems` / `GetAuctionItemInfo` API **do not apply**. Forever uses the modern, Retail-style `C_AuctionHouse` system: ItemKeys, commodities vs. items, browse then search.

## 2. Auction House API: overview

The Forever client exposes the complete `C_AuctionHouse` namespace (86 functions, 47 events) [UI]. No AH function declares `SecretReturns`, so the "secret values" restriction that affects unit/combat data in Forever does **not** apply to AH data. `SecretArguments = AllowedWhenUntainted` only matters if you pass a secret value, and we never do.

The AH works in **two levels**, and they return different data structures. This distinction drives the whole design.

```
Player types a search / picks a category in the standard AH UI
        │  AuctionHouseFrame:SendBrowseQuery → C_AuctionHouse.SendBrowseQuery(query)
        ▼
LEVEL 1: BROWSE RESULTS   one row per ItemKey, aggregate only
        │  Player clicks a row → AuctionHouseFrame:SelectBrowseResult(browseResult)
        │  → C_AuctionHouse.SendSearchQuery(itemKey, sorts, separateOwnerItems)
        ▼
LEVEL 2: SEARCH RESULTS (individual listings), two different shapes:
        ├─ ItemKeyInfo.isCommodity == false → ItemSearchResultInfo   (one row per auction)
        └─ ItemKeyInfo.isCommodity == true  → CommoditySearchResultInfo (one row per price tier)
```

## 3. Level 1: Browse results

### 3.1 Access

| Purpose | API | Notes |
|---|---|---|
| Read current results | `C_AuctionHouse.GetBrowseResults() → table<BrowseResultInfo>` | No query is sent. Just reads what the player's last browse returned. |
| Incremental page arrived | event `AUCTION_HOUSE_BROWSE_RESULTS_ADDED(addedBrowseResults)` | Payload holds **only the new rows**. Blizzard appends them with `tAppendAll`. |
| Full result set replaced | event `AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()` | Re-read with `GetBrowseResults()`. |
| Is the list complete? | `C_AuctionHouse.HasFullBrowseResults() → bool` | |
| Load next page | `C_AuctionHouse.RequestMoreBrowseResults()` | Blizzard calls this only when the player scrolls near the end. |
| Browse failed | event `AUCTION_HOUSE_BROWSE_FAILURE()` | Blizzard shows `ERR_AUCTION_DATABASE_ERROR`. |
| Item metadata for a key | `C_AuctionHouse.GetItemKeyInfo(itemKey) → ItemKeyInfo?` | May be `nil` until event `ITEM_KEY_ITEM_INFO_RECEIVED(itemID)`. |

### 3.2 `BrowseResultInfo` structure [UI]

| Field | Type | Meaning |
|---|---|---|
| `itemKey` | `ItemKey` = `{itemID, itemLevel=0, itemSuffix=0, battlePetSpeciesID=0}` | Identity of the grouped item. |
| `totalQuantity` | number | Total units across **all** auctions for this key. |
| `minPrice` | BigUInteger (copper) | Lowest price for this key (see §3.4). |
| `containsOwnerItem` | bool | The player has an auction in this group. |
| `appearanceLink` | string? | Transmog appearance link, not an item link. |

### 3.3 `ItemKeyInfo` structure [UI]

`itemID, battlePetSpeciesID, itemName, battlePetLink?, appearanceLink?, quality, iconFileID, isPet, isCommodity, isEquipment`

### 3.4 What a browse row can and cannot tell us

**A browse row is not a listing.** It has no `auctionID` and no per-auction quantity. You also can't tell from it how many units sit at `minPrice`.

| Case | Meaning of `minPrice` | What Vendor Sniper can conclude from browse alone |
|---|---|---|
| Commodity (`isCommodity`) | Lowest **unit** price. Blizzard passes it to `CommoditiesBuyFrame:SetItemIDAndPrice(itemID, minPrice)` as the unit price. [UI] | At least 1 unit is buyable at `minPrice`. If `minPrice < vendorUnitPrice`, it's a **candidate** with a *known per-unit margin*. Quantity at that price is unknown, so total profit is unknown. |
| Non-commodity, max stack size 1 (all equipment) | Buyout of the cheapest single auction [INF] | Exact: one auction of quantity 1 at `minPrice`. Profit = `vendor − minPrice`. Still no `auctionID`. |
| Non-commodity, stackable (rare) | Ambiguous: could be a whole-stack buyout [INF] | **Can't evaluate safely.** Mark as "needs listing check". Never divide by `totalQuantity`. |

`C_Item.GetItemMaxStackSizeByID(itemID)` separates the last two cases with no server query.

## 4. Level 2: Individual listings (search results)

A per-ItemKey search fills these. It happens either when **the player clicks a browse row** in the Blizzard UI (passive for us), or when we call `C_AuctionHouse.SendSearchQuery(...)` ourselves.

> `SendSearchQuery`: *"Search queries are restricted to 100 calls per minute. These should not be used to query the entire auction house."* [UI, generated doc string]

### 4.1 Non-commodity items: `ItemSearchResultInfo` (one row = one auction)

| Purpose | API / event |
|---|---|
| Count / read | `GetNumItemSearchResults(itemKey)`, `GetItemSearchResultInfo(itemKey, index)` |
| Results (re)arrived | `ITEM_SEARCH_RESULTS_UPDATED(itemKey, newAuctionID?)`, `ITEM_SEARCH_RESULTS_ADDED(itemKey)` |
| Paging | `HasFullItemSearchResults(itemKey)`, `RequestMoreItemSearchResults(itemKey) → hasFullResults` |
| Total units | `GetItemSearchResultsQuantity(itemKey)` |
| Re-query a key the client already has | `HasSearchResults(itemKey)`, `RefreshItemSearchResults(itemKey, minLvl?, maxLvl?)` |

Fields: `itemKey, auctionID, quantity, buyoutAmount?, minBid?, bidAmount?, bidder?, itemLink?, owners, totalNumberOfOwners, timeLeft, timeLeftSeconds?, containsOwnerItem, containsAccountItem, containsSocketedItem`.

* **`auctionID` is a real, unique purchase handle.** Blizzard buys with `PlaceBid(auctionID, buyoutAmount)`.
* `buyoutAmount` is the **total price for the whole auction** [INF]. You buy the whole auction or nothing, and Blizzard's UI never multiplies it by quantity. Unit price = `buyoutAmount / quantity`, for display only.
* `buyoutAmount == nil` means a bid-only auction. **Exclude it** (no buyout to compare against).
* `itemLink` is the exact variant. Use it for the vendor price when it's present.

### 4.2 Commodities: `CommoditySearchResultInfo` (one row = one price tier)

| Purpose | API / event |
|---|---|
| Count / read | `GetNumCommoditySearchResults(itemID)`, `GetCommoditySearchResultInfo(itemID, index)`. Keyed by **itemID**, not ItemKey. |
| Results (re)arrived | `COMMODITY_SEARCH_RESULTS_UPDATED(itemID)`, `COMMODITY_SEARCH_RESULTS_ADDED(itemID)`, `COMMODITY_SEARCH_RESULTS_RECEIVED()` |
| Paging | `HasFullCommoditySearchResults(itemID)`, `RequestMoreCommoditySearchResults(itemID)` |
| Total units | `GetCommoditySearchResultsQuantity(itemID)` |
| Re-query | `RefreshCommoditySearchResults(itemID)` |

Fields: `itemID, quantity, unitPrice, auctionID, owners, totalNumberOfOwners, timeLeftSeconds?, numOwnerItems, containsOwnerItem, containsAccountItem`.

* **`unitPrice` is per unit**, and `quantity` is the units in that row.
* A row has an `auctionID`, but **it isn't a purchase handle**. Commodities are bought with `StartCommoditiesPurchase(itemID, quantity)`, which always fills from the cheapest units up. The player can't buy "row 3". Vendor Sniper must show `auctionID` as informational only, never as "the auction to buy".
* Because buying fills cheapest-first, the honest opportunity is **cumulative**: "buy the first *N* units (every row with `unitPrice < vendorUnitPrice`) for total *X*, vendor for *Y*." Blizzard has the same helper, `AuctionHouseUtil.AggregateCommoditySearchResultsByMaxPrice(itemID, maxUnitPrice)`.
* No bids exist on commodities.

### 4.3 Side by side

| | Browse row | Item listing | Commodity listing |
|---|---|---|---|
| Struct | `BrowseResultInfo` | `ItemSearchResultInfo` | `CommoditySearchResultInfo` |
| Key | `itemKey` | `itemKey` | `itemID` |
| Price field | `minPrice` (lowest) | `buyoutAmount` (**total**, nilable) | `unitPrice` (**per unit**) |
| Quantity | `totalQuantity` (all auctions) | `quantity` (this auction) | `quantity` (this tier) |
| `auctionID` | ✗ | ✓ purchase handle | ✓ informational only |
| Item link | ✗ (appearanceLink only) | `itemLink?` | ✗ |
| Requires a search query | No (already there) | Yes, per itemKey | Yes, per itemID |
| Purchase path (player only) | n/a | `PlaceBid(auctionID, buyout)` | `StartCommoditiesPurchase` → `ConfirmCommoditiesPurchase` |
| Profit precision | Lower bound / candidate | Exact | Exact per tier and cumulative |

## 5. Item information and vendor price

| Purpose | API | Notes |
|---|---|---|
| Vendor price | `C_Item.GetItemInfo(itemID \| link \| name)`, **11th return `sellPrice`** (copper, per unit) | `MayReturnNothing`. Returns nothing until the item is cached. |
| Load uncached | `C_Item.RequestLoadItemDataByID(itemID)` → event `ITEM_DATA_LOAD_RESULT(itemID, success)` | `GET_ITEM_INFO_RECEIVED(itemID, success)` also exists. |
| Cache check | `C_Item.IsItemDataCachedByID(itemID)` | |
| Category without cache | `C_Item.GetItemInfoInstant(itemID) → itemID, type, subType, equipLoc, icon, classID, subClassID` | Synchronous. |
| Stack size | `C_Item.GetItemMaxStackSizeByID(itemID)` | Resolves the ambiguity in §3.4. |
| Name / quality / icon | `C_Item.GetItemNameByID`, `GetItemQualityByID`, `GetItemIconByID`, `GetItemQualityColor` | Or take them from `ItemKeyInfo`. |

* The global `GetItemInfo` was reported **missing** on beta build 69913 [COM]. **Use `C_Item.*` exclusively.**
* `sellPrice == 0` means the item can't be vendored. Exclude it and count it as "no vendor value", not as an error.
* **Variants:** at browse level we only have `itemKey.itemID` (+ itemLevel/suffix). For random-suffix items ("of the Bear") the sell price is expected to match the base item [INF]. At listing level `itemLink` is exact, so prefer it. Cache by itemID. If a link-based price ever differs from the ID-based one, also cache by link.

**Category mapping** (`classID` from `GetItemInfoInstant`; enum names from the Forever AH category file [UI]):

| Vendor Sniper category | `Enum.ItemClass` |
|---|---|
| Equipment & weapons | `Weapon`, `Armor` (also `ItemKeyInfo.isEquipment`) |
| Crafting materials | `Tradegoods`, `Reagent` |
| Consumables | `Consumable` |
| Unsupported for now (extensible) | `Recipe`, `Container`, `Projectile`, `Quiver`, `Questitem`, `Miscellaneous`, … |

## 6. Restrictions, throttling and protected actions

| Topic | Finding | Effect on design |
|---|---|---|
| Purchases / posting / cancelling | `PlaceBid`, `StartCommoditiesPurchase`, `PostItem`, `PostCommodity`, `ConfirmPost*`, `CancelAuction` are flagged `HasRestrictions = true` [UI] | **Never called.** The player buys through Blizzard's UI. |
| Search query rate | `SendSearchQuery` / `SendSellSearchQuery`: 100 calls/minute (documented) | Only player-initiated, one item per click. No loops. |
| Throttled message system | `IsThrottledMessageSystemReady()`, events `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`, `_MESSAGE_QUEUED`, `_MESSAGE_SENT`, `_MESSAGE_DROPPED`, `_RESPONSE_RECEIVED` | ScannerScheduler waits on these events, not on timers. |
| Whole-AH dump | `C_AuctionHouse.ReplicateItems()` exists | **Out of scope** (non-goal). Will not be used. |
| Load-on-demand UI | `Blizzard_AuctionHouseUI` has `LoadOnDemand: 1`. `AuctionHouseFrame` doesn't exist until first AH open. | Hook on `ADDON_LOADED("Blizzard_AuctionHouseUI")` / `AUCTION_HOUSE_SHOW`. |
| AH lifecycle | `AUCTION_HOUSE_SHOW`, `AUCTION_HOUSE_CLOSED`, `AUCTION_HOUSE_DISABLED` | Cancel the scan, mark results stale on close. |
| Taint | Addon code calling Blizzard AH frame methods (`AuctionHouseFrame:SelectBrowseResult`, `SearchBar:StartSearch`) taints that path. The later restricted buy click could then be blocked. | Navigation (§7) defaults to the least invasive option. Test in-game. |
| Secret values | Apply to unit/combat data in Forever, not AH/item data | No special handling needed. |
| Money type | `BigUInteger` / `WOWMONEY` are plain Lua numbers (doubles). Exact up to 2^53 copper. | All maths on whole copper. ROI kept as integer basis points. |
| Copper granularity | `C_AuctionHouse.SupportsCopperValues()`. Retail rounds posted prices to silver. | Doesn't affect reading. Display honours it. |

## 7. Impact on the original spec: required adjustments

1. **"Retrieve browse results → evaluate each listing" isn't directly possible.** Browse results are aggregates, not listings. Proposed two-tier model:
   * **Tier 1, browse scan** (no queries sent): read `GetBrowseResults()` and flag **candidates** where `minPrice < vendorUnitPrice`. Exact for non-stackable items. Per-unit margin for commodities. "Needs check" for stackable non-commodities.
   * **Tier 2, listing evaluation**: exact per-auction (items) or per-tier plus cumulative (commodities) opportunities. Data arrives (a) **passively** whenever the player opens an item in the standard AH (we listen to the `ITEM_/COMMODITY_SEARCH_RESULTS_*` events), or (b) when the player asks for an **Inspect**.
   * **Lookup mode is a setting** (`lookup.mode`, decided 2026-11-16):
     * `"click"` (**default**): each player action sends at most **one** `SendSearchQuery`.
     * `"batch"` (opt-in): one player action queues searches for all candidates. The ScannerScheduler sends them one at a time, waits for each response event, and respects `IsThrottledMessageSystemReady()` / `AUCTION_HOUSE_THROTTLED_*`. It also enforces a rolling 60-second budget (`lookup.batchMaxPerMinute`, default 30, clamped to 1–90), well under the documented 100/min, so Blizzard's own UI keeps headroom. The queue can be cancelled and is cancelled automatically when the AH closes.
     * Both modes share the same rate limiter.
     * Open question for in-game testing: whether `SendSearchQuery` needs a hardware event. If it does, batch mode can't work, and the setting will be disabled with a message.
2. **Auction ID:** only item listings have a usable one. Browse rows have none. Commodity rows have one, but it isn't a purchase handle. The UI labels this honestly.
3. **Deduplication keys:**
   * Browse: `itemID:itemLevel:itemSuffix:petSpecies`. A newer snapshot replaces the old one.
   * Item listing: `auctionID`.
   * Commodity tier: `itemID:unitPrice` (quantity updated in place).
   * Two auctions of the same item at different prices stay separate.
4. **Profit for commodities** is reported both per tier and as "buy the first N units". That is what a commodity purchase actually does.
5. **Navigation to a result:** by default, fill `AuctionHouseFrame.SearchBar.SearchBox` with the item name and let the player press Search/Enter. A one-click "open item" via `AuctionHouseFrame:SelectBrowseResult` gets added only if in-game testing shows it doesn't block the later purchase.
6. **Refresh button:** re-reads the current browse/search results without a new query. A new browse is the player's job in the standard UI.

## 8. Other platform capabilities (confirmed in the Forever UI source)

| Need | Available |
|---|---|
| SavedVariables | TOC `## SavedVariables:` / `## SavedVariablesPerCharacter:`. Load **after** files run: init in `ADDON_LOADED`. Event `SAVED_VARIABLES_TOO_LARGE` exists. A persistence bug in beta build 70009 was reported fixed [COM]. |
| Scroll lists | `CreateScrollBoxListLinearView`, `ScrollUtil.InitScrollBoxListWithScrollBar` (modern ScrollBox) |
| Settings panel | `Settings.RegisterCanvasLayoutCategory`, `Settings.RegisterAddOnCategory`, `Settings.OpenToCategory` |
| Money formatting | `GetMoneyString(copper, …)`, `C_CurrencyInfo.GetCoinTextureString(copper)` |
| Sound | `PlaySound(soundKitID)` / `C_Sound.PlaySound` |
| Item links / shift-click | `HandleModifiedItemClick` (recommended for Forever [COM]) |
| Frames / XML | Standard `CreateFrame`, templates such as `PortraitFrameTemplate`, `SetResizable` / `SetResizeBounds` (Mainline). Plan: Lua-created frames, with XML only for row templates. |
| Addon helpers | `C_AddOns.IsAddOnLoaded`, `C_AddOns.GetAddOnMetadata` |

## 9. In-game verification checklist (needs you, on the live client)

Run these with the AH open and a browse search done (for example "Linen" and "Sword"):

| # | Command | Confirms |
|---|---|---|
| 1 | `/dump select(4, GetBuildInfo()), _VERSION` | Interface 16001, Lua 5.1 |
| 2 | `/dump C_AuctionHouse.GetBrowseResults()[1]` | Browse structure (§3.2) |
| 3 | `/dump C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.GetBrowseResults()[1].itemKey)` | `isCommodity` / `isEquipment` |
| 4 | Click a cloth item, then `/dump C_AuctionHouse.GetCommoditySearchResultInfo(2589, 1)` | Linen Cloth (2589) is a commodity. `unitPrice` is per unit. |
| 5 | Click a weapon, then `/dump C_AuctionHouse.GetItemSearchResultInfo(C_AuctionHouse.GetBrowseResults()[1].itemKey, 1)` | `buyoutAmount` and `auctionID` |
| 6 | Find any stackable non-commodity, and compare its browse `minPrice` with its listing `buyoutAmount`/`quantity` | Resolves the §3.4 ambiguity |
| 7 | `/dump select(11, C_Item.GetItemInfo(2589)), GetItemInfo` | Vendor price, and whether the global exists |
| 8 | `/dump C_AuctionHouse.SupportsCopperValues()` | Copper granularity |

Until #4–#6 are confirmed, the code treats those behaviours as assumptions and keeps them behind isolated adapter functions.

## 10. Testing approach

* No Lua interpreter is installed on this machine. **.NET SDK 10.0.400** is installed, and Homebrew is available.
* Proposal: xUnit test project that runs the **pure-Lua business-logic modules** (ProfitCalculator, AuctionEvaluator, Dedup, Money) inside **MoonSharp**, a pure-C# Lua interpreter. MoonSharp implements Lua 5.2, so the addon code sticks to the 5.1/5.2 common subset (`local unpack = unpack or table.unpack`, no `setfenv`, no `goto`). WoW API access goes only through injected adapters, which the tests replace with fixtures built from the structs in §3–§5.
* Optional: `brew install lua@5.1 luarocks` + `luacheck` for static analysis against real 5.1.

## 11. Revised plan

1. **M1:** TOC (`Interface: 16001`), `Core.lua` loading, a `/vsniper probe` command that prints the §9 facts in-game.
2. **M2:** `AuctionScanner` with separate `BrowseAdapter`, `ItemListingAdapter`, `CommodityListingAdapter`. Lifecycle events and diagnostics output.
3. **M3:** `VendorPriceService` (+ async load), `ProfitCalculator`, `AuctionEvaluator` (tiers, dedup keys above), and the .NET/MoonSharp tests including all 14 required cases.
4. **M4–M5:** UI, filters, sorting, SavedVariables, notifications, as specified. "Tier" and "exactness" get their own column/badge.
