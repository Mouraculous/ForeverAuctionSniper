--[[
WoWAPI: the only module that calls Auction House and item APIs directly.

Every other service receives this table (or a test fake with the same shape)
as a dependency. Only APIs confirmed in the Forever 1.60.1 (70938) API
documentation are used (see docs/COMPATIBILITY.md). No restricted function
(PlaceBid, StartCommoditiesPurchase, Post*, Cancel*) is ever called.
]]
local _, ns = ...

local WoWAPI = {}
ns.WoWAPI = WoWAPI

local function ah()
	return C_AuctionHouse
end

-- True when the C_AuctionHouse functions we rely on exist in this client.
function WoWAPI.HasAuctionHouseAPI()
	local api = ah()
	return type(api) == "table"
		and type(api.GetBrowseResults) == "function"
		and type(api.GetItemKeyInfo) == "function"
		and type(api.GetItemSearchResultInfo) == "function"
		and type(api.GetCommoditySearchResultInfo) == "function"
end

function WoWAPI.HasItemAPI()
	return type(C_Item) == "table" and type(C_Item.GetItemInfo) == "function"
end

-- Browse level -------------------------------------------------------------

-- Returns the browse rows the client currently holds (no server query).
function WoWAPI.GetBrowseResults()
	return ah().GetBrowseResults() or {}
end

function WoWAPI.HasFullBrowseResults()
	return ah().HasFullBrowseResults() == true
end

-- ItemKeyInfo or nil (nil until ITEM_KEY_ITEM_INFO_RECEIVED).
function WoWAPI.GetItemKeyInfo(itemKey)
	return ah().GetItemKeyInfo(itemKey)
end

-- Listing level ------------------------------------------------------------

-- Reads every ItemSearchResultInfo row the client holds for itemKey.
-- Returns rows, hasFullResults.
function WoWAPI.GetItemSearchRows(itemKey)
	local api = ah()
	local rows = {}
	local n = api.GetNumItemSearchResults(itemKey) or 0
	for i = 1, n do
		local row = api.GetItemSearchResultInfo(itemKey, i)
		if row then
			rows[#rows + 1] = row
		end
	end
	return rows, api.HasFullItemSearchResults(itemKey) == true
end

-- Reads every CommoditySearchResultInfo row the client holds for itemID.
-- Returns rows, hasFullResults.
function WoWAPI.GetCommoditySearchRows(itemID)
	local api = ah()
	local rows = {}
	local n = api.GetNumCommoditySearchResults(itemID) or 0
	for i = 1, n do
		local row = api.GetCommoditySearchResultInfo(itemID, i)
		if row then
			rows[#rows + 1] = row
		end
	end
	return rows, api.HasFullCommoditySearchResults(itemID) == true
end

-- Sends ONE item search (documented limit: 100 per minute). Only called by
-- ScannerScheduler, which enforces the rate limit and the lookup-mode setting.
function WoWAPI.SendSearchQuery(itemKey)
	local sortOrder = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
	local sorts = { { sortOrder = sortOrder, reverseSort = false } }
	ah().SendSearchQuery(itemKey, sorts, false)
	return true
end

function WoWAPI.IsThrottleReady()
	local api = ah()
	if type(api.IsThrottledMessageSystemReady) ~= "function" then
		return true
	end
	return api.IsThrottledMessageSystemReady() == true
end

-- Items ----------------------------------------------------------------------

--[[
Returns item details or nil when the item isn't cached yet.
item may be an itemID, an item link or a name (as for C_Item.GetItemInfo).
{ name, link, quality, maxStack, icon, sellPrice, classID, subClassID }
]]
function WoWAPI.GetItemInfo(item)
	local name, link, quality, _, _, _, _, maxStack, _, icon, sellPrice, classID, subClassID = C_Item.GetItemInfo(item)
	if not name then
		return nil
	end
	return {
		name = name,
		link = link,
		quality = quality,
		maxStack = maxStack,
		icon = icon,
		sellPrice = sellPrice,
		classID = classID,
		subClassID = subClassID,
	}
end

-- Synchronous class lookup that needs no item cache. Returns classID, subClassID, icon.
function WoWAPI.GetItemInfoInstant(itemID)
	if type(C_Item.GetItemInfoInstant) ~= "function" then
		return nil
	end
	local _, _, _, _, icon, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
	return classID, subClassID, icon
end

function WoWAPI.GetItemMaxStackSize(itemID)
	if type(C_Item.GetItemMaxStackSizeByID) ~= "function" then
		return nil
	end
	return C_Item.GetItemMaxStackSizeByID(itemID)
end

-- Asks the client to load item data. The answer arrives as ITEM_DATA_LOAD_RESULT.
function WoWAPI.RequestLoadItemData(itemID)
	C_Item.RequestLoadItemDataByID(itemID)
end

-- Time / scheduling ----------------------------------------------------------

function WoWAPI.Now()
	return GetTime()
end

function WoWAPI.After(seconds, fn)
	C_Timer.After(seconds, fn)
end

-- Runs fn on the next frame so long work doesn't block rendering.
function WoWAPI.Defer(fn)
	C_Timer.After(0, fn)
end
