--[[
AuctionEvaluator: decides whether a normalised record is an opportunity,
applies the player's filters, removes duplicates and builds summary stats.

Pure module (depends on ns.ProfitCalculator, ns.Listings, ns.Money).
Vendor prices come in through a lookup function, so this module never
talks to the WoW API.
]]
local _, ns = ...

local Money = ns.Money
local ProfitCalculator = ns.ProfitCalculator
local Listings = ns.Listings

local AuctionEvaluator = {}
ns.AuctionEvaluator = AuctionEvaluator

-- Evaluation statuses.
AuctionEvaluator.PROFITABLE = "profitable"
AuctionEvaluator.UNPROFITABLE = "unprofitable"
-- Browse row that might be profitable but needs its listings checked.
AuctionEvaluator.POSSIBLE = "possible"
AuctionEvaluator.NO_VENDOR_VALUE = "no_vendor_value"
AuctionEvaluator.VENDOR_PENDING = "vendor_pending"
AuctionEvaluator.VENDOR_UNAVAILABLE = "vendor_unavailable"
AuctionEvaluator.INVALID = "invalid"

-- Vendor lookup statuses (shared with VendorPriceService).
AuctionEvaluator.PRICE_OK = "ok"
AuctionEvaluator.PRICE_PENDING = "pending"
AuctionEvaluator.PRICE_UNAVAILABLE = "unavailable"

--[[
Evaluates one record against a vendor unit price.
vendorStatus is one of PRICE_OK / PRICE_PENDING / PRICE_UNAVAILABLE.
Returns an evaluation table:
  { status, vendorUnitPrice?, totalVendorValue?, profit?, roiBasisPoints?,
    isLowerBound, error? }
]]
function AuctionEvaluator.Evaluate(record, vendorUnitPrice, vendorStatus)
	local isLowerBound = record.kind == Listings.KIND_BROWSE
		and record.precision ~= Listings.PRECISION_EXACT

	if vendorStatus == AuctionEvaluator.PRICE_PENDING then
		return { status = AuctionEvaluator.VENDOR_PENDING, isLowerBound = isLowerBound }
	end
	if vendorStatus == AuctionEvaluator.PRICE_UNAVAILABLE or vendorUnitPrice == nil then
		return { status = AuctionEvaluator.VENDOR_UNAVAILABLE, isLowerBound = isLowerBound }
	end

	local calc, err = ProfitCalculator.Calculate(vendorUnitPrice, record.quantity, record.buyoutTotal)
	if not calc then
		if err == ProfitCalculator.ERR_NO_VENDOR_VALUE then
			return { status = AuctionEvaluator.NO_VENDOR_VALUE, vendorUnitPrice = 0, isLowerBound = isLowerBound }
		end
		return { status = AuctionEvaluator.INVALID, error = err, isLowerBound = isLowerBound }
	end

	local status
	if calc.isProfitable then
		status = AuctionEvaluator.PROFITABLE
	elseif record.kind == Listings.KIND_BROWSE
		and record.precision == Listings.PRECISION_LOWER_BOUND
		and record.isCommodity ~= true
		and Money.IsValid(record.maxStack) and record.maxStack > 1
		and record.minPrice < vendorUnitPrice * record.maxStack then
		-- minPrice might be a whole-stack buyout. A full stack would then be
		-- profitable, but browse data can't prove it.
		status = AuctionEvaluator.POSSIBLE
	else
		status = AuctionEvaluator.UNPROFITABLE
	end

	return {
		status = status,
		vendorUnitPrice = calc.vendorUnitPrice,
		totalVendorValue = calc.totalVendorValue,
		profit = calc.profit,
		roiBasisPoints = calc.roiBasisPoints,
		isLowerBound = isLowerBound,
	}
end

--[[
Applies the player's filters to a PROFITABLE evaluation.
filters: { minProfit = copper, minRoiBasisPoints = bp, maxBuyout = copper (0 = no limit),
           categories = { [category] = bool }, qualities = { [quality] = bool } }
Returns true, or false plus a reason.
]]
function AuctionEvaluator.PassesFilters(record, evaluation, filters)
	if evaluation.status ~= AuctionEvaluator.PROFITABLE then
		return false, "not_profitable"
	end
	filters = filters or {}
	if filters.minProfit and evaluation.profit < filters.minProfit then
		return false, "min_profit"
	end
	if filters.minRoiBasisPoints and evaluation.roiBasisPoints < filters.minRoiBasisPoints then
		return false, "min_roi"
	end
	if filters.maxBuyout and filters.maxBuyout > 0 and record.buyoutTotal > filters.maxBuyout then
		return false, "max_buyout"
	end
	if filters.categories then
		if record.category == nil then
			return false, "unsupported_category"
		end
		if not filters.categories[record.category] then
			return false, "category"
		end
	end
	if filters.qualities and record.quality ~= nil and not filters.qualities[record.quality] then
		return false, "quality"
	end
	return true
end

-- Removes records with duplicate keys. The last occurrence wins, keeping first-seen order.
function AuctionEvaluator.Dedupe(records)
	local indexByKey, result = {}, {}
	for i = 1, #records do
		local record = records[i]
		local key = record.key
		if key ~= nil then
			local index = indexByKey[key]
			if index then
				result[index] = record
			else
				result[#result + 1] = record
				indexByKey[key] = #result
			end
		end
	end
	return result
end

--[[
Runs the full pipeline over a list of records.
priceLookup(record) -> vendorUnitPrice | nil, status
Returns {
  opportunities = { { record = r, evaluation = e }, ... }  (passed filters)
  possible      = { ... } (browse rows that need a listing check)
  stats = { evaluated, profitable, shown, filteredOut, possible,
            vendorUnknown, vendorUnknownItems, noVendorValue, invalid,
            totalProfit, totalProfitIsLowerBound },
  commodityAggregates = { [groupKey] = ProfitCalculator.CommodityAggregate(...) },
}
]]
function AuctionEvaluator.Process(records, priceLookup, filters)
	local unique = AuctionEvaluator.Dedupe(records)
	local stats = {
		evaluated = 0,
		profitable = 0,
		shown = 0,
		filteredOut = 0,
		possible = 0,
		vendorUnknown = 0,
		vendorUnknownItems = 0,
		noVendorValue = 0,
		invalid = 0,
		totalProfit = 0,
		totalProfitIsLowerBound = false,
	}
	local opportunities, possible = {}, {}
	local unknownItems = {}
	local commodityTiers, commodityVendor = {}, {}

	for i = 1, #unique do
		local record = unique[i]
		local price, status = priceLookup(record)
		local evaluation = AuctionEvaluator.Evaluate(record, price, status)
		stats.evaluated = stats.evaluated + 1

		local s = evaluation.status
		if s == AuctionEvaluator.PROFITABLE then
			stats.profitable = stats.profitable + 1
			if AuctionEvaluator.PassesFilters(record, evaluation, filters) then
				opportunities[#opportunities + 1] = { record = record, evaluation = evaluation }
				stats.shown = stats.shown + 1
				stats.totalProfit = stats.totalProfit + evaluation.profit
				if evaluation.isLowerBound then
					stats.totalProfitIsLowerBound = true
				end
			else
				stats.filteredOut = stats.filteredOut + 1
			end
		elseif s == AuctionEvaluator.POSSIBLE then
			stats.possible = stats.possible + 1
			possible[#possible + 1] = { record = record, evaluation = evaluation }
		elseif s == AuctionEvaluator.VENDOR_PENDING or s == AuctionEvaluator.VENDOR_UNAVAILABLE then
			stats.vendorUnknown = stats.vendorUnknown + 1
			if record.itemID and not unknownItems[record.itemID] then
				unknownItems[record.itemID] = true
				stats.vendorUnknownItems = stats.vendorUnknownItems + 1
			end
		elseif s == AuctionEvaluator.NO_VENDOR_VALUE then
			stats.noVendorValue = stats.noVendorValue + 1
		elseif s == AuctionEvaluator.INVALID then
			stats.invalid = stats.invalid + 1
		end

		if record.kind == Listings.KIND_COMMODITY and evaluation.vendorUnitPrice then
			local tiers = commodityTiers[record.groupKey]
			if not tiers then
				tiers = {}
				commodityTiers[record.groupKey] = tiers
				commodityVendor[record.groupKey] = evaluation.vendorUnitPrice
			end
			tiers[#tiers + 1] = record
		end
	end

	local commodityAggregates = {}
	for groupKey, tiers in pairs(commodityTiers) do
		commodityAggregates[groupKey] = ProfitCalculator.CommodityAggregate(tiers, commodityVendor[groupKey])
	end

	return {
		opportunities = opportunities,
		possible = possible,
		stats = stats,
		commodityAggregates = commodityAggregates,
	}
end

--[[
Picks opportunities that haven't been notified yet and meet the threshold.
notified is a set (key -> true) that this function updates.
Returns the list of newly notified opportunities.
]]
function AuctionEvaluator.SelectNewNotifications(opportunities, notified, thresholdCopper)
	local fresh = {}
	for i = 1, #opportunities do
		local opp = opportunities[i]
		local key = opp.record.key
		if not notified[key] and opp.evaluation.profit >= (thresholdCopper or 0) then
			notified[key] = true
			fresh[#fresh + 1] = opp
		end
	end
	return fresh
end
