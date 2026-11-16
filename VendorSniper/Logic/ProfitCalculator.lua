--[[
ProfitCalculator: profit and ROI on whole copper values.

Pure module (depends only on ns.Money).

  TotalVendorValue = VendorPricePerItem * Quantity
  PotentialProfit  = TotalVendorValue - AuctionBuyoutPrice
  ROI              = PotentialProfit / AuctionBuyoutPrice, stored as integer
                     basis points (10000 bp = 100 %)
]]
local _, ns = ...

local Money = ns.Money

local ProfitCalculator = {}
ns.ProfitCalculator = ProfitCalculator

-- Error / status codes returned as the second value when no result is produced.
ProfitCalculator.ERR_INVALID_VENDOR_PRICE = "invalid_vendor_price"
ProfitCalculator.ERR_INVALID_QUANTITY = "invalid_quantity"
ProfitCalculator.ERR_INVALID_BUYOUT = "invalid_buyout"
ProfitCalculator.ERR_ZERO_BUYOUT = "zero_buyout"
ProfitCalculator.ERR_NO_VENDOR_VALUE = "no_vendor_value"
ProfitCalculator.ERR_OVERFLOW = "overflow"

-- Signed ROI in basis points, truncated towards zero. cost must be > 0.
function ProfitCalculator.RoiBasisPoints(profit, cost)
	local negative = profit < 0
	local p = negative and -profit or profit
	-- Split the division so intermediate values stay far below 2^53.
	local q = Money.IntDiv(p, cost)
	local r = p - q * cost
	local bp = q * 10000 + Money.IntDiv(r * 10000, cost)
	return negative and -bp or bp
end

-- Price per unit (floored) for display. Returns nil for invalid input.
function ProfitCalculator.UnitPrice(totalPrice, quantity)
	if not Money.IsValid(totalPrice) or not Money.IsValid(quantity) or quantity < 1 then
		return nil
	end
	return Money.IntDiv(totalPrice, quantity)
end

--[[
Calculates the opportunity for buying `quantity` units for `buyoutTotal`
and selling them to a vendor for `vendorUnitPrice` each.

Returns a result table, or nil plus an error code:
  { vendorUnitPrice, quantity, buyoutTotal, unitBuyout, totalVendorValue,
    profit, roiBasisPoints, isProfitable }
]]
function ProfitCalculator.Calculate(vendorUnitPrice, quantity, buyoutTotal)
	if not Money.IsValid(vendorUnitPrice) then
		return nil, ProfitCalculator.ERR_INVALID_VENDOR_PRICE
	end
	if not Money.IsValid(quantity) or quantity < 1 then
		return nil, ProfitCalculator.ERR_INVALID_QUANTITY
	end
	if not Money.IsValid(buyoutTotal) then
		return nil, ProfitCalculator.ERR_INVALID_BUYOUT
	end
	if buyoutTotal == 0 then
		return nil, ProfitCalculator.ERR_ZERO_BUYOUT
	end
	if vendorUnitPrice == 0 then
		return nil, ProfitCalculator.ERR_NO_VENDOR_VALUE
	end

	local totalVendorValue = vendorUnitPrice * quantity
	if not Money.IsValid(totalVendorValue) then
		return nil, ProfitCalculator.ERR_OVERFLOW
	end

	local profit = totalVendorValue - buyoutTotal
	return {
		vendorUnitPrice = vendorUnitPrice,
		quantity = quantity,
		buyoutTotal = buyoutTotal,
		unitBuyout = Money.IntDiv(buyoutTotal, quantity),
		totalVendorValue = totalVendorValue,
		profit = profit,
		roiBasisPoints = ProfitCalculator.RoiBasisPoints(profit, buyoutTotal),
		isProfitable = profit > 0,
	}
end

--[[
Commodity purchases always fill from the cheapest units upwards. This sums
every price tier whose unit price is strictly below the vendor price: what
the player gets by buying "the first N units".

rows: array of { unitPrice = copper, quantity = n }. Invalid rows are ignored.
Returns nil when no tier is profitable, otherwise
  { units, cost, totalVendorValue, profit, roiBasisPoints, maxUnitPrice, tiers }
]]
function ProfitCalculator.CommodityAggregate(rows, vendorUnitPrice)
	if not Money.IsValid(vendorUnitPrice) or vendorUnitPrice == 0 or type(rows) ~= "table" then
		return nil
	end

	local valid = {}
	for i = 1, #rows do
		local row = rows[i]
		if type(row) == "table" and Money.IsValid(row.unitPrice) and row.unitPrice > 0
			and Money.IsValid(row.quantity) and row.quantity > 0 then
			valid[#valid + 1] = row
		end
	end
	table.sort(valid, function(a, b) return a.unitPrice < b.unitPrice end)

	local units, cost, tiers, maxUnitPrice = 0, 0, 0, 0
	for i = 1, #valid do
		local row = valid[i]
		if row.unitPrice >= vendorUnitPrice then
			break
		end
		units = units + row.quantity
		cost = cost + row.unitPrice * row.quantity
		tiers = tiers + 1
		maxUnitPrice = row.unitPrice
	end

	if units == 0 then
		return nil
	end

	local totalVendorValue = vendorUnitPrice * units
	local profit = totalVendorValue - cost
	return {
		units = units,
		cost = cost,
		totalVendorValue = totalVendorValue,
		profit = profit,
		roiBasisPoints = ProfitCalculator.RoiBasisPoints(profit, cost),
		maxUnitPrice = maxUnitPrice,
		tiers = tiers,
	}
end
