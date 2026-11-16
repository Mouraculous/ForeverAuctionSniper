--[[
ItemCache: session cache of item details used for vendor pricing and display.

Pure module. It stores what C_Item.GetItemInfo returned for an item, plus a
load status, so the API is only asked once per item. Item info is static
game data, so nothing here expires during a session. Entries keyed by an
item link are kept separately for variants whose price differs from the
base item.
]]
local _, ns = ...

local ItemCache = {}
ItemCache.__index = ItemCache
ns.ItemCache = ItemCache

ItemCache.STATUS_UNKNOWN = "unknown"
ItemCache.STATUS_PENDING = "pending"
ItemCache.STATUS_LOADED = "loaded"
ItemCache.STATUS_UNAVAILABLE = "unavailable"

function ItemCache.New()
	local self = setmetatable({}, ItemCache)
	self:Wipe()
	return self
end

function ItemCache:Wipe()
	self.byID = {}
	self.byLink = {}
	self.status = {}
end

-- details: { sellPrice, name, link, quality, icon, classID, subClassID, maxStack }
function ItemCache:Set(itemID, details)
	self.byID[itemID] = details
	self.status[itemID] = ItemCache.STATUS_LOADED
end

function ItemCache:Get(itemID)
	return self.byID[itemID]
end

function ItemCache:SetLinkPrice(link, sellPrice)
	self.byLink[link] = sellPrice
end

function ItemCache:GetLinkPrice(link)
	return self.byLink[link]
end

function ItemCache:GetStatus(itemID)
	return self.status[itemID] or ItemCache.STATUS_UNKNOWN
end

function ItemCache:MarkPending(itemID)
	if self.status[itemID] ~= ItemCache.STATUS_LOADED then
		self.status[itemID] = ItemCache.STATUS_PENDING
	end
end

function ItemCache:MarkUnavailable(itemID)
	if self.status[itemID] ~= ItemCache.STATUS_LOADED then
		self.status[itemID] = ItemCache.STATUS_UNAVAILABLE
	end
end
