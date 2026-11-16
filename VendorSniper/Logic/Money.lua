--[[
Money: copper arithmetic and formatting.

Pure module. It uses only the Lua standard library, so it runs inside the
game and in the out-of-game test harness.

WoW money values (BigUInteger / WOWMONEY) arrive as Lua numbers (doubles).
Whole numbers are exact up to 2^53, far above the gold cap. All maths here
stays on whole copper values. Division only happens through IntDiv, which
corrects any off-by-one from floating-point rounding.
]]
local _, ns = ...

local floor = math.floor

local Money = {}
ns.Money = Money

Money.COPPER_PER_SILVER = 100
Money.COPPER_PER_GOLD = 10000

-- Largest whole number we accept as a money value (2^53 - 1).
Money.MAX_SAFE = 9007199254740991

-- True when v is a finite, non-negative whole number in the safe range.
function Money.IsValid(v)
	return type(v) == "number"
		and v == v -- not NaN
		and v >= 0
		and v <= Money.MAX_SAFE
		and floor(v) == v
end

-- True when v is a finite whole number (may be negative) in the safe range.
function Money.IsWhole(v)
	return type(v) == "number"
		and v == v
		and v >= -Money.MAX_SAFE
		and v <= Money.MAX_SAFE
		and floor(v) == v
end

-- Exact floor division for non-negative whole numbers (b > 0).
function Money.IntDiv(a, b)
	local q = floor(a / b)
	if q * b > a then
		q = q - 1
	elseif (q + 1) * b <= a then
		q = q + 1
	end
	return q
end

-- Splits an absolute copper amount into gold, silver and copper.
function Money.Split(copper)
	local amount = copper < 0 and -copper or copper
	local gold = Money.IntDiv(amount, Money.COPPER_PER_GOLD)
	local rest = amount - gold * Money.COPPER_PER_GOLD
	local silver = Money.IntDiv(rest, Money.COPPER_PER_SILVER)
	return gold, silver, rest - silver * Money.COPPER_PER_SILVER
end

-- Plain-text money string, e.g. 12345 -> "1g 23s 45c", 10000 -> "1g",
-- 0 -> "0c", -150 -> "-1s 50c". Zero components are left out.
function Money.Format(copper)
	if not Money.IsWhole(copper) then
		return "?"
	end
	if copper == 0 then
		return "0c"
	end
	local gold, silver, rest = Money.Split(copper)
	local parts = {}
	if gold > 0 then parts[#parts + 1] = gold .. "g" end
	if silver > 0 then parts[#parts + 1] = silver .. "s" end
	if rest > 0 then parts[#parts + 1] = rest .. "c" end
	local text = table.concat(parts, " ")
	if copper < 0 then
		text = "-" .. text
	end
	return text
end

-- Formats ROI given in basis points (1 bp = 0.01 %), e.g. 12345 -> "123.45%".
function Money.FormatRoi(basisPoints)
	if not Money.IsWhole(basisPoints) then
		return "?"
	end
	local negative = basisPoints < 0
	local bp = negative and -basisPoints or basisPoints
	local whole = Money.IntDiv(bp, 100)
	local frac = bp - whole * 100
	local text = string.format("%d.%02d%%", whole, frac)
	if negative then
		text = "-" .. text
	end
	return text
end

-- Parses "1g 2s 3c", "1g", "250s", "75c" or a bare copper number into copper.
-- Returns nil for malformed input.
function Money.Parse(text)
	if type(text) == "number" then
		return Money.IsValid(text) and text or nil
	end
	if type(text) ~= "string" then
		return nil
	end
	local s = string.lower(text):gsub("%s+", "")
	if s == "" then
		return nil
	end
	if s:match("^%d+$") then
		return tonumber(s)
	end
	local total, consumed = 0, 0
	for amount, unit in s:gmatch("(%d+)([gsc])") do
		local n = tonumber(amount)
		if unit == "g" then
			total = total + n * Money.COPPER_PER_GOLD
		elseif unit == "s" then
			total = total + n * Money.COPPER_PER_SILVER
		else
			total = total + n
		end
		consumed = consumed + #amount + 1
	end
	if consumed ~= #s or not Money.IsValid(total) then
		return nil
	end
	return total
end
