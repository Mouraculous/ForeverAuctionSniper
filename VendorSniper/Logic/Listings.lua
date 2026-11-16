--[[
Listings: turns raw C_AuctionHouse structures into normalised records.

Pure module. It takes the raw tables exactly as the API returns them
(BrowseResultInfo, ItemSearchResultInfo, CommoditySearchResultInfo) plus an
`info` table of item metadata. It does not call any WoW API itself.

There are three record kinds. They are never merged, because their prices
mean different things (see docs/COMPATIBILITY.md, sections 3-4):

  browse     One row per ItemKey, aggregate. No auction ID. buyoutTotal is
             `minPrice` for one unit. Evaluating it gives a guaranteed
             LOWER BOUND on profit (exact for non-stackable items).
  item       One row per auction. auctionID is a real purchase handle.
             buyoutTotal is the price of the whole auction.
  commodity  One row per price tier. unitPrice is per unit. auctionID is
             informational only: commodity purchases fill cheapest-first and
             can't target a row.

Common record fields:
  kind, key (dedup key), groupKey (listing group), itemID, itemKey,
  itemKeyString, quantity, buyoutTotal, unitPrice, precision, auctionID?,
  auctionIDKind?, name?, quality?, icon?, link?, classID?, category?,
  isCommodity?, maxStack?, isPartial
]]
local _, ns = ...

local Money = ns.Money
local Categories = ns.Categories

local Listings = {}
ns.Listings = Listings

Listings.KIND_BROWSE = "browse"
Listings.KIND_ITEM = "item"
Listings.KIND_COMMODITY = "commodity"

-- How much a record's numbers can be trusted.
Listings.PRECISION_EXACT = "exact" -- real per-auction / per-tier data
Listings.PRECISION_PER_UNIT_MIN = "perUnitMin" -- commodity browse: >= 1 unit at minPrice
Listings.PRECISION_LOWER_BOUND = "lowerBound" -- browse row with unknown stack layout

-- Auction ID meaning.
Listings.AUCTION_ID_PURCHASABLE = "purchasable"
Listings.AUCTION_ID_INFORMATIONAL = "informational"

-- Skip reasons reported by the normalisers.
Listings.SKIP_INVALID = "invalid"
Listings.SKIP_NO_BUYOUT = "no_buyout"

local function num(v, default)
	if type(v) == "number" then
		return v
	end
	return default
end

-- Canonical string for an ItemKey: "itemID:itemLevel:itemSuffix:battlePetSpeciesID".
function Listings.ItemKeyString(itemKey)
	if type(itemKey) ~= "table" or type(itemKey.itemID) ~= "number" then
		return nil
	end
	return string.format("%d:%d:%d:%d",
		itemKey.itemID,
		num(itemKey.itemLevel, 0),
		num(itemKey.itemSuffix, 0),
		num(itemKey.battlePetSpeciesID, 0))
end

function Listings.ItemGroupKey(itemKeyString)
	return "I:" .. itemKeyString
end

function Listings.CommodityGroupKey(itemID)
	return "C:" .. tostring(itemID)
end

local function applyInfo(record, info)
	info = info or {}
	record.name = info.name
	record.quality = info.quality
	record.icon = info.icon
	record.link = record.link or info.link
	record.classID = info.classID
	record.maxStack = info.maxStack
	record.isEquipment = info.isEquipment
	record.category = Categories.FromClassID(info.classID, info.isEquipment)
end

--[[
Normalises one BrowseResultInfo.
info.isCommodity may be nil when ItemKeyInfo isn't loaded yet. The record
then stays conservative (lower bound) and can be superseded by either
kind of listing group.
Returns record or nil, skipReason.
]]
function Listings.FromBrowseResult(raw, info)
	if type(raw) ~= "table" then
		return nil, Listings.SKIP_INVALID
	end
	local itemKeyString = Listings.ItemKeyString(raw.itemKey)
	if not itemKeyString then
		return nil, Listings.SKIP_INVALID
	end
	local minPrice = raw.minPrice
	if not Money.IsValid(minPrice) or minPrice == 0 then
		return nil, Listings.SKIP_NO_BUYOUT
	end
	info = info or {}

	local itemID = raw.itemKey.itemID
	local isCommodity = info.isCommodity
	local precision
	if isCommodity == true then
		precision = Listings.PRECISION_PER_UNIT_MIN
	elseif isCommodity == false and info.maxStack == 1 then
		precision = Listings.PRECISION_EXACT
	else
		precision = Listings.PRECISION_LOWER_BOUND
	end

	local supersededBy
	if isCommodity == true then
		supersededBy = { Listings.CommodityGroupKey(itemID) }
	elseif isCommodity == false then
		supersededBy = { Listings.ItemGroupKey(itemKeyString) }
	else
		supersededBy = { Listings.CommodityGroupKey(itemID), Listings.ItemGroupKey(itemKeyString) }
	end

	local record = {
		kind = Listings.KIND_BROWSE,
		key = "B:" .. itemKeyString,
		groupKey = "B",
		supersededBy = supersededBy,
		itemID = itemID,
		itemKey = raw.itemKey,
		itemKeyString = itemKeyString,
		isCommodity = isCommodity,
		-- One unit is guaranteed to be available at minPrice. Evaluating that
		-- unit gives a profit that is a lower bound for every interpretation.
		quantity = 1,
		buyoutTotal = minPrice,
		unitPrice = minPrice,
		minPrice = minPrice,
		totalQuantity = num(raw.totalQuantity, 0),
		containsOwnerItem = raw.containsOwnerItem == true,
		precision = precision,
		isPartial = false,
	}
	applyInfo(record, info)
	return record
end

--[[
Normalises the ItemSearchResultInfo rows for one searched ItemKey.
Auctions without a buyout (bid-only) and malformed rows are skipped.
Auctions without an auction ID get a fallback key that stays stable when the
same snapshot is processed again, while identical auctions stay separate.
Returns records, skipped (table reason -> count).
]]
function Listings.FromItemSearchResults(searchedItemKey, rows, info, isPartial)
	local records, skipped = {}, {}
	local itemKeyString = Listings.ItemKeyString(searchedItemKey)
	if not itemKeyString or type(rows) ~= "table" then
		skipped[Listings.SKIP_INVALID] = 1
		return records, skipped
	end
	local groupKey = Listings.ItemGroupKey(itemKeyString)
	local fallbackOrdinal = {}
	local seen = {}

	for i = 1, #rows do
		local row = rows[i]
		local reason
		if type(row) ~= "table" or not Money.IsValid(row.quantity) or row.quantity < 1 then
			reason = Listings.SKIP_INVALID
		elseif row.buyoutAmount == nil or row.buyoutAmount == 0 then
			reason = Listings.SKIP_NO_BUYOUT
		elseif not Money.IsValid(row.buyoutAmount) then
			reason = Listings.SKIP_INVALID
		end

		if reason then
			skipped[reason] = (skipped[reason] or 0) + 1
		else
			local key, auctionID
			if type(row.auctionID) == "number" then
				auctionID = row.auctionID
				key = "I:" .. auctionID
			else
				local base = string.format("I:%s:%d:%d", itemKeyString, row.buyoutAmount, row.quantity)
				local n = (fallbackOrdinal[base] or 0) + 1
				fallbackOrdinal[base] = n
				key = base .. "#" .. n
			end

			if not seen[key] then
				seen[key] = true
				local record = {
					kind = Listings.KIND_ITEM,
					key = key,
					groupKey = groupKey,
					itemID = searchedItemKey.itemID,
					itemKey = row.itemKey or searchedItemKey,
					itemKeyString = itemKeyString,
					isCommodity = false,
					quantity = row.quantity,
					buyoutTotal = row.buyoutAmount,
					unitPrice = Money.IntDiv(row.buyoutAmount, row.quantity),
					auctionID = auctionID,
					auctionIDKind = auctionID and Listings.AUCTION_ID_PURCHASABLE or nil,
					link = row.itemLink,
					containsOwnerItem = row.containsOwnerItem == true,
					timeLeft = row.timeLeft,
					precision = Listings.PRECISION_EXACT,
					isPartial = isPartial == true,
				}
				applyInfo(record, info)
				records[#records + 1] = record
			end
		end
	end
	return records, skipped
end

--[[
Normalises the CommoditySearchResultInfo rows for one item ID.
Rows with the same unit price are merged into one tier (quantities summed).
They are indistinguishable for a commodity purchase.
Returns records (sorted by unit price), skipped.
]]
function Listings.FromCommoditySearchResults(itemID, rows, info, isPartial)
	local records, skipped = {}, {}
	if type(itemID) ~= "number" or type(rows) ~= "table" then
		skipped[Listings.SKIP_INVALID] = 1
		return records, skipped
	end
	local groupKey = Listings.CommodityGroupKey(itemID)
	local itemKey = { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
	local itemKeyString = Listings.ItemKeyString(itemKey)
	local byPrice = {}

	for i = 1, #rows do
		local row = rows[i]
		if type(row) ~= "table" or not Money.IsValid(row.quantity) or row.quantity < 1
			or not Money.IsValid(row.unitPrice) or row.unitPrice == 0 then
			skipped[Listings.SKIP_INVALID] = (skipped[Listings.SKIP_INVALID] or 0) + 1
		else
			local record = byPrice[row.unitPrice]
			if record then
				record.quantity = record.quantity + row.quantity
				record.buyoutTotal = record.unitPrice * record.quantity
				record.mergedRows = record.mergedRows + 1
				record.containsOwnerItem = record.containsOwnerItem or row.containsOwnerItem == true
			else
				record = {
					kind = Listings.KIND_COMMODITY,
					key = "C:" .. itemID .. ":" .. row.unitPrice,
					groupKey = groupKey,
					itemID = itemID,
					itemKey = itemKey,
					itemKeyString = itemKeyString,
					isCommodity = true,
					quantity = row.quantity,
					unitPrice = row.unitPrice,
					buyoutTotal = row.unitPrice * row.quantity,
					auctionID = type(row.auctionID) == "number" and row.auctionID or nil,
					auctionIDKind = type(row.auctionID) == "number" and Listings.AUCTION_ID_INFORMATIONAL or nil,
					containsOwnerItem = row.containsOwnerItem == true,
					mergedRows = 1,
					precision = Listings.PRECISION_EXACT,
					isPartial = isPartial == true,
				}
				applyInfo(record, info)
				byPrice[row.unitPrice] = record
				records[#records + 1] = record
			end
		end
	end
	table.sort(records, function(a, b) return a.unitPrice < b.unitPrice end)
	return records, skipped
end
