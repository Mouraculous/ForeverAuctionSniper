--[[
Sorting: comparators for opportunity lists ({ record, evaluation } pairs).

Pure module. Ties fall back to profit (desc) and then the record key, so the
order is deterministic and doesn't jump around between refreshes.
]]
local _, ns = ...

local Sorting = {}
ns.Sorting = Sorting

Sorting.PROFIT = "profit" -- potential profit, descending (default)
Sorting.ROI = "roi" -- ROI, descending
Sorting.BUYOUT = "buyout" -- lowest buyout first
Sorting.VENDOR_VALUE = "vendorValue" -- highest total vendor value first
Sorting.NAME = "name" -- item name, A-Z
Sorting.QUANTITY = "quantity" -- largest quantity first

Sorting.DEFAULT = Sorting.PROFIT
Sorting.ORDER = { Sorting.PROFIT, Sorting.ROI, Sorting.BUYOUT, Sorting.VENDOR_VALUE, Sorting.NAME, Sorting.QUANTITY }
Sorting.LABELS = {
	[Sorting.PROFIT] = "Profit",
	[Sorting.ROI] = "ROI",
	[Sorting.BUYOUT] = "Lowest buyout",
	[Sorting.VENDOR_VALUE] = "Vendor value",
	[Sorting.NAME] = "Name",
	[Sorting.QUANTITY] = "Quantity",
}

local function tieBreak(a, b)
	if a.evaluation.profit ~= b.evaluation.profit then
		return a.evaluation.profit > b.evaluation.profit
	end
	return a.record.key < b.record.key
end

local function lowerName(opp)
	return string.lower(opp.record.name or "")
end

local comparators = {
	[Sorting.PROFIT] = function(a, b)
		return tieBreak(a, b)
	end,
	[Sorting.ROI] = function(a, b)
		if a.evaluation.roiBasisPoints ~= b.evaluation.roiBasisPoints then
			return a.evaluation.roiBasisPoints > b.evaluation.roiBasisPoints
		end
		return tieBreak(a, b)
	end,
	[Sorting.BUYOUT] = function(a, b)
		if a.record.buyoutTotal ~= b.record.buyoutTotal then
			return a.record.buyoutTotal < b.record.buyoutTotal
		end
		return tieBreak(a, b)
	end,
	[Sorting.VENDOR_VALUE] = function(a, b)
		if a.evaluation.totalVendorValue ~= b.evaluation.totalVendorValue then
			return a.evaluation.totalVendorValue > b.evaluation.totalVendorValue
		end
		return tieBreak(a, b)
	end,
	[Sorting.NAME] = function(a, b)
		local na, nb = lowerName(a), lowerName(b)
		if na ~= nb then
			return na < nb
		end
		return tieBreak(a, b)
	end,
	[Sorting.QUANTITY] = function(a, b)
		if a.record.quantity ~= b.record.quantity then
			return a.record.quantity > b.record.quantity
		end
		return tieBreak(a, b)
	end,
}

function Sorting.IsValid(sortKey)
	return comparators[sortKey] ~= nil
end

-- Sorts the list in place and returns it.
function Sorting.Sort(opportunities, sortKey)
	table.sort(opportunities, comparators[sortKey] or comparators[Sorting.DEFAULT])
	return opportunities
end
