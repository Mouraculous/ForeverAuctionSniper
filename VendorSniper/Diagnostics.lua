--[[
Diagnostics: chat output, the in-game compatibility probe, and a text
listing of results. Milestone 2 has no window yet; this is how results are
inspected for now.
]]
local _, ns = ...

local Money = ns.Money
local Listings = ns.Listings
local Categories = ns.Categories

local Diagnostics = {}
ns.Diagnostics = Diagnostics

local PREFIX = "|cff33ff99Vendor Sniper|r: "

function Diagnostics.Print(fmt, ...)
	local text = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

function Diagnostics.Money(copper)
	if Money.IsValid(copper) and C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
		return C_CurrencyInfo.GetCoinTextureString(copper)
	end
	return Money.Format(copper)
end

local function signedMoney(copper)
	if copper < 0 then
		return "-" .. Diagnostics.Money(-copper)
	end
	return "+" .. Diagnostics.Money(copper)
end

local function exists(path)
	local value = _G
	for part in string.gmatch(path, "[^%.]+") do
		if type(value) ~= "table" then
			return false
		end
		value = value[part]
	end
	return value ~= nil
end

local PROBE_APIS = {
	"C_AuctionHouse.GetBrowseResults",
	"C_AuctionHouse.HasFullBrowseResults",
	"C_AuctionHouse.GetItemKeyInfo",
	"C_AuctionHouse.GetItemSearchResultInfo",
	"C_AuctionHouse.GetCommoditySearchResultInfo",
	"C_AuctionHouse.SendSearchQuery",
	"C_AuctionHouse.IsThrottledMessageSystemReady",
	"C_AuctionHouse.SupportsCopperValues",
	"C_Item.GetItemInfo",
	"C_Item.GetItemInfoInstant",
	"C_Item.RequestLoadItemDataByID",
	"C_Item.GetItemMaxStackSizeByID",
	"GetItemInfo",
	"C_Timer.After",
	"Settings.RegisterCanvasLayoutCategory",
	"CreateScrollBoxListLinearView",
}

local function itemLabel(record)
	if record.link then
		return record.link
	end
	return record.name or ("item:" .. tostring(record.itemID))
end

-- Prints the facts from the compatibility checklist (docs/COMPATIBILITY.md section 9).
function Diagnostics.Probe(core)
	local version, build, _, interface = GetBuildInfo()
	Diagnostics.Print("Client %s (build %s), interface %s, %s, WOW_PROJECT_ID=%s",
		tostring(version), tostring(build), tostring(interface), tostring(_VERSION), tostring(WOW_PROJECT_ID))

	local missing = {}
	for i = 1, #PROBE_APIS do
		if not exists(PROBE_APIS[i]) then
			missing[#missing + 1] = PROBE_APIS[i]
		end
	end
	if #missing == 0 then
		Diagnostics.Print("All %d probed APIs exist.", #PROBE_APIS)
	else
		Diagnostics.Print("Missing APIs: %s", table.concat(missing, ", "))
	end

	if C_AuctionHouse and C_AuctionHouse.SupportsCopperValues then
		Diagnostics.Print("SupportsCopperValues: %s", tostring(C_AuctionHouse.SupportsCopperValues()))
	end

	local linen = ns.WoWAPI.GetItemInfo(2589)
	Diagnostics.Print("Linen Cloth (2589) sellPrice: %s",
		linen and tostring(linen.sellPrice) or "not cached yet (run probe again)")
	if not linen then
		ns.WoWAPI.RequestLoadItemData(2589)
	end

	if not core.scanner:IsAuctionHouseOpen() then
		Diagnostics.Print("Open the Auction House and run a search for browse/listing samples.")
		return
	end

	local results = ns.WoWAPI.GetBrowseResults()
	Diagnostics.Print("Browse results held: %d (full: %s)", #results, tostring(ns.WoWAPI.HasFullBrowseResults()))
	for i = 1, math.min(3, #results) do
		local raw = results[i]
		local keyInfo = ns.WoWAPI.GetItemKeyInfo(raw.itemKey)
		Diagnostics.Print("  browse #%d key=%s minPrice=%s totalQty=%s isCommodity=%s isEquipment=%s maxStack=%s",
			i, tostring(Listings.ItemKeyString(raw.itemKey)), tostring(raw.minPrice), tostring(raw.totalQuantity),
			keyInfo and tostring(keyInfo.isCommodity) or "?", keyInfo and tostring(keyInfo.isEquipment) or "?",
			tostring(ns.WoWAPI.GetItemMaxStackSize(raw.itemKey.itemID)))
	end

	for groupKey, source in pairs(core.scanner.groupSources) do
		local row = source.rows[1]
		if row then
			if source.kind == Listings.KIND_ITEM then
				Diagnostics.Print("  item group %s: rows=%d first auctionID=%s qty=%s buyoutAmount=%s minBid=%s",
					groupKey, #source.rows, tostring(row.auctionID), tostring(row.quantity),
					tostring(row.buyoutAmount), tostring(row.minBid))
			else
				Diagnostics.Print("  commodity group %s: rows=%d first auctionID=%s qty=%s unitPrice=%s",
					groupKey, #source.rows, tostring(row.auctionID), tostring(row.quantity), tostring(row.unitPrice))
			end
		end
	end
end

local function describeOpportunity(opp, aggregate)
	local r, e = opp.record, opp.evaluation
	local detail
	if r.kind == Listings.KIND_ITEM then
		detail = r.auctionID and ("auction " .. r.auctionID) or "auction (no ID)"
	elseif r.kind == Listings.KIND_COMMODITY then
		detail = "commodity tier"
		if aggregate then
			detail = string.format("commodity tier; first %d units: %s", aggregate.units, signedMoney(aggregate.profit))
		end
	elseif r.precision == Listings.PRECISION_EXACT then
		detail = "browse, cheapest auction"
	elseif r.precision == Listings.PRECISION_PER_UNIT_MIN then
		detail = "browse, per unit, at least 1 available"
	else
		detail = "browse, lower bound"
	end
	local profitText = signedMoney(e.profit)
	if e.isLowerBound then
		profitText = ">= " .. profitText
	end
	return string.format("%s x%d [%s] buy %s, vendor %s, profit %s (ROI %s) - %s",
		itemLabel(r), r.quantity, Categories.Label(r.category),
		Diagnostics.Money(r.buyoutTotal), Diagnostics.Money(e.totalVendorValue),
		profitText, Money.FormatRoi(e.roiBasisPoints), detail)
end

function Diagnostics.PrintSummary(result, isStale)
	local s = result.stats
	Diagnostics.Print("%d opportunities shown (%d profitable, %d filtered out), %d evaluated, potential profit %s%s.",
		s.shown, s.profitable, s.filteredOut, s.evaluated,
		s.totalProfitIsLowerBound and ">= " or "", Diagnostics.Money(s.totalProfit))
	if s.vendorUnknownItems > 0 or s.possible > 0 or s.noVendorValue > 0 or s.invalid > 0 then
		Diagnostics.Print("%d items without vendor info yet, %d possible (need listing check), %d not vendorable, %d invalid.",
			s.vendorUnknownItems, s.possible, s.noVendorValue, s.invalid)
	end
	Diagnostics.Print("Profit is theoretical: buy price minus vendor value, before anything is bought.%s",
		isStale and " Data may be outdated (Auction House was closed)." or "")
end

function Diagnostics.PrintResults(result, limit, isStale)
	if not result then
		Diagnostics.Print("No results yet. Do a search in the Auction House, then /vsniper scan.")
		return
	end
	Diagnostics.PrintSummary(result, isStale)
	local opps = result.opportunities
	for i = 1, math.min(limit or 10, #opps) do
		local opp = opps[i]
		Diagnostics.Print("%d. %s", i, describeOpportunity(opp, result.commodityAggregates[opp.record.groupKey]))
	end
end

Diagnostics.SCAN_FAIL_TEXT = {
	ah_closed = "The Auction House isn't open.",
	no_api = "This client has no C_AuctionHouse API. Vendor Sniper can't run here.",
	no_results = "No browse results. Run a search in the Auction House first.",
	busy = "A scan is already running.",
}

function Diagnostics.Help()
	Diagnostics.Print("Commands (/vsniper or /vendorsniper). The Vendor Sniper tab in the Auction House does the same:")
	Diagnostics.Print("  show - open the Vendor Sniper tab (Auction House must be open)")
	Diagnostics.Print("  scan - evaluate the current Auction House browse results")
	Diagnostics.Print("  results [n] - list the top n opportunities (default 10)")
	Diagnostics.Print("  inspect - look up listings for candidates (mode: click = one, batch = all)")
	Diagnostics.Print("  stop - cancel the running scan and queued lookups")
	Diagnostics.Print("  lookup click|batch [perMinute] - set the lookup mode")
	Diagnostics.Print("  sort profit|roi|buyout|vendorValue|name|quantity")
	Diagnostics.Print("  minprofit <amount> - e.g. 50s or 1g20s")
	Diagnostics.Print("  minroi <percent> / maxbuyout <amount|0>")
	Diagnostics.Print("  sound on|off [threshold] - notification for new opportunities")
	Diagnostics.Print("  status / probe - lookup status / compatibility probe")
end
