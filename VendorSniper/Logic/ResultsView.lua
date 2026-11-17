--[[
ResultsView: turns evaluation results into display data for the window.

Pure module. It decides WHAT is shown (texts, which columns, footnotes,
tooltip lines). The UI files only decide HOW (frames, fonts, coin icons).
Money stays in copper here; the UI formats it.
]]
local _, ns = ...

local Money = ns.Money
local Listings = ns.Listings
local Categories = ns.Categories
local Sorting = ns.Sorting

local ResultsView = {}
ns.ResultsView = ResultsView

--[[
Result table columns. `sortKey` makes a header clickable. Widths are pixels
at the default window size; the name column takes the remaining space.
`money` columns are formatted with coin icons by the UI.
]]
ResultsView.COLUMNS = {
	{ key = "name", title = "Item", width = 0, sortKey = Sorting.NAME, align = "LEFT" },
	{ key = "quantity", title = "Qty", width = 38, sortKey = Sorting.QUANTITY, align = "RIGHT" },
	{ key = "buyout", title = "AH price", width = 74, sortKey = Sorting.BUYOUT, align = "RIGHT", money = true },
	{ key = "unitPrice", title = "Unit price", width = 66, align = "RIGHT", money = true },
	{ key = "vendorUnit", title = "Vendor", width = 58, align = "RIGHT", money = true },
	{ key = "vendorTotal", title = "Vendor value", width = 74, sortKey = Sorting.VENDOR_VALUE, align = "RIGHT", money = true },
	{ key = "profit", title = "Profit", width = 74, sortKey = Sorting.PROFIT, align = "RIGHT", money = true },
	{ key = "roi", title = "ROI", width = 54, sortKey = Sorting.ROI, align = "RIGHT" },
}

-- Marker appended to profit values that are only a lower bound.
ResultsView.LOWER_BOUND_MARK = "*"

local function detailText(record, aggregate)
	local category = Categories.Label(record.category)
	local kind
	if record.kind == Listings.KIND_ITEM then
		kind = record.auctionID and ("Auction #" .. record.auctionID) or "Auction (no ID)"
	elseif record.kind == Listings.KIND_COMMODITY then
		kind = "Commodity price tier"
		if aggregate and aggregate.tiers > 1 then
			kind = kind .. string.format(", first %d units profitable", aggregate.units)
		end
	elseif record.precision == Listings.PRECISION_EXACT then
		kind = "Browse: cheapest auction"
	elseif record.precision == Listings.PRECISION_PER_UNIT_MIN then
		kind = "Browse: lowest unit price"
	else
		kind = "Browse: estimate"
	end
	if record.isPartial then
		kind = kind .. " (partial)"
	end
	return category .. " - " .. kind
end

local function quantityText(record)
	if record.kind == Listings.KIND_BROWSE and record.precision ~= Listings.PRECISION_EXACT then
		return record.quantity .. "+"
	end
	return tostring(record.quantity)
end

--[[
Builds one display row per opportunity, keeping the given order.
Each row: { key, record, evaluation, icon, name, quality, link, itemID,
  detail, quantityText, buyout, unitPrice, vendorUnit, vendorTotal, profit,
  roiText, isLowerBound, canInspect }
]]
function ResultsView.BuildRows(result)
	local rows = {}
	if not result then
		return rows
	end
	local opportunities = result.opportunities
	for i = 1, #opportunities do
		local opp = opportunities[i]
		local r, e = opp.record, opp.evaluation
		local aggregate = result.commodityAggregates and result.commodityAggregates[r.groupKey]
		rows[i] = {
			key = r.key,
			record = r,
			evaluation = e,
			icon = r.icon,
			name = r.name or ("Item " .. tostring(r.itemID)),
			quality = r.quality,
			link = r.link,
			itemID = r.itemID,
			detail = detailText(r, aggregate),
			quantityText = quantityText(r),
			buyout = r.buyoutTotal,
			unitPrice = r.unitPrice,
			vendorUnit = e.vendorUnitPrice,
			vendorTotal = e.totalVendorValue,
			profit = e.profit,
			roiText = Money.FormatRoi(e.roiBasisPoints),
			isLowerBound = e.isLowerBound == true,
			canInspect = r.kind == Listings.KIND_BROWSE,
		}
	end
	return rows
end

--[[
Summary numbers for the stats bar.
Returns { opportunities, evaluated, totalProfit, totalIsLowerBound,
  vendorUnknown, possible, filteredOut }
]]
function ResultsView.Summary(result)
	if not result then
		return { opportunities = 0, evaluated = 0, totalProfit = 0, totalIsLowerBound = false,
			vendorUnknown = 0, possible = 0, filteredOut = 0 }
	end
	local s = result.stats
	return {
		opportunities = s.shown,
		evaluated = s.evaluated,
		totalProfit = s.totalProfit,
		totalIsLowerBound = s.totalProfitIsLowerBound,
		vendorUnknown = s.vendorUnknownItems,
		possible = s.possible,
		filteredOut = s.filteredOut,
	}
end

--[[
Text shown over the empty results list.
state: { isOpen, hasScanned, isScanning, result }
]]
function ResultsView.EmptyText(state)
	if not state.isOpen then
		return "The Auction House is closed."
	end
	if state.isScanning then
		return "Scanning browse results..."
	end
	if not state.hasScanned then
		return "Search for items in the Buy tab, then come back and press Scan."
	end
	local result = state.result
	if result and result.stats.evaluated == 0 then
		return "The last search returned nothing Vendor Sniper can evaluate."
	end
	if result and result.stats.filteredOut > 0 then
		return "No listings pass your filters. " .. result.stats.filteredOut .. " profitable ones are filtered out."
	end
	if result and result.stats.possible > 0 then
		return "Nothing proven profitable yet. Inspect the " .. result.stats.possible .. " possible items for exact prices."
	end
	return "No listings below vendor price in these results."
end

--[[
Status line next to the progress bar.
state: { scanDone, scanTotal, isScanning, lookup (ScannerScheduler status),
  browseChanged, isStale, lookupMode }
Returns text, progressValue (0..1) or nil when no progress bar is needed.
]]
function ResultsView.StatusText(state)
	if state.isScanning and state.scanTotal and state.scanTotal > 0 then
		return string.format("Scanning %d / %d", state.scanDone or 0, state.scanTotal), (state.scanDone or 0) / state.scanTotal
	end
	local lookup = state.lookup
	if lookup and (lookup.inFlight or lookup.queued > 0) then
		local text = string.format("Inspecting %d / %d", lookup.completed, lookup.total)
		if lookup.state == "waitingRateLimit" then
			text = text .. " (waiting for query budget)"
		elseif lookup.state == "waitingThrottle" then
			text = text .. " (waiting for server)"
		end
		local progress = lookup.total > 0 and lookup.completed / lookup.total or 0
		return text, progress
	end
	if state.isStale then
		return "Data may be outdated. Scan again.", nil
	end
	if state.browseChanged then
		return "Browse results changed. Press Scan to update.", nil
	end
	return "", nil
end

local function profitLine(evaluation)
	if evaluation.isLowerBound then
		return "Potential profit (at least)"
	end
	return "Potential profit"
end

--[[
Extra tooltip lines below the item tooltip.
Returns a list of { left, right?, color = "normal" | "highlight" | "green" | "grey" }.
Money values are copper numbers in `money`/`moneyRight` and are formatted by the UI.
]]
function ResultsView.TooltipLines(row, aggregate)
	local r, e = row.record, row.evaluation
	local lines = {}
	local function add(left, color, money)
		lines[#lines + 1] = { left = left, color = color or "normal", money = money }
	end

	add("Vendor Sniper", "highlight")
	add("Buyout (" .. r.quantity .. ")", "normal", r.buyoutTotal)
	add("Vendor value", "normal", e.totalVendorValue)
	add(profitLine(e), "green", e.profit)

	if r.kind == Listings.KIND_ITEM then
		add(r.auctionID and ("Auction ID " .. r.auctionID .. ". Find it in the Buy tab.") or "This auction has no ID.", "grey")
	elseif r.kind == Listings.KIND_COMMODITY then
		add("Commodity: buying always takes the cheapest units first.", "grey")
		if aggregate then
			add(string.format("Buying the first %d units costs", aggregate.units), "normal", aggregate.cost)
			add(string.format("and they sell to a vendor for"), "normal", aggregate.totalVendorValue)
		end
	else
		if r.precision == Listings.PRECISION_PER_UNIT_MIN then
			add(string.format("Browse data: at least 1 of %d units costs this much.", r.totalQuantity), "grey")
		elseif r.precision == Listings.PRECISION_LOWER_BOUND then
			add("Browse data only: real profit may be higher.", "grey")
		end
		add("Right-click > Inspect listings for exact prices.", "grey")
	end
	add("Profit is theoretical: nothing has been bought yet.", "grey")
	return lines
end
