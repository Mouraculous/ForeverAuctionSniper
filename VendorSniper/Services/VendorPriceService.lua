--[[
VendorPriceService: vendor sell prices (copper per unit) with caching.

Dependencies (injected):
  api.GetItemInfo(itemOrLink) -> details | nil   (see WoWAPI.GetItemInfo)
  api.RequestLoadItemData(itemID)
  cache                                          (ItemCache instance)
  callbacks (optional)                           fires ITEM_DETAILS_READY / ITEM_DETAILS_UNAVAILABLE

Behaviour:
  * Cached items are answered without calling the API.
  * Uncached items: a load is requested once. The status stays "pending"
    until ITEM_DATA_LOAD_RESULT arrives (forwarded to OnItemDataLoaded).
  * A sell price of 0 is a valid answer ("can't be vendored").
  * Variants: when an item link is given, its own sell price is used if
    the client returns one. Otherwise the base item's price is used.
]]
local _, ns = ...

local Money = ns.Money
local ItemCache = ns.ItemCache

local VendorPriceService = {}
VendorPriceService.__index = VendorPriceService
ns.VendorPriceService = VendorPriceService

VendorPriceService.OK = "ok"
VendorPriceService.PENDING = "pending"
VendorPriceService.UNAVAILABLE = "unavailable"

function VendorPriceService.New(api, cache, callbacks)
	return setmetatable({
		api = api,
		cache = cache or ItemCache.New(),
		callbacks = callbacks,
		loadRequests = 0,
	}, VendorPriceService)
end

-- Returns details, status. details is nil unless status is OK.
function VendorPriceService:GetDetails(itemID)
	if type(itemID) ~= "number" then
		return nil, VendorPriceService.UNAVAILABLE
	end
	local cache = self.cache
	local details = cache:Get(itemID)
	if details then
		return details, VendorPriceService.OK
	end
	local status = cache:GetStatus(itemID)
	if status == ItemCache.STATUS_UNAVAILABLE then
		return nil, VendorPriceService.UNAVAILABLE
	end

	-- The client may already have the data (a cheap local lookup, not a server request).
	details = self.api.GetItemInfo(itemID)
	if details then
		cache:Set(itemID, details)
		return details, VendorPriceService.OK
	end

	if status ~= ItemCache.STATUS_PENDING then
		cache:MarkPending(itemID)
		self.loadRequests = self.loadRequests + 1
		self.api.RequestLoadItemData(itemID)
	end
	return nil, VendorPriceService.PENDING
end

-- Returns vendorUnitPrice, status.
function VendorPriceService:GetVendorPrice(itemID, itemLink)
	local details, status = self:GetDetails(itemID)
	if not details then
		return nil, status
	end
	local price = details.sellPrice

	if type(itemLink) == "string" and itemLink ~= details.link then
		local linkPrice = self.cache:GetLinkPrice(itemLink)
		if linkPrice == nil then
			local linkDetails = self.api.GetItemInfo(itemLink)
			if linkDetails and Money.IsValid(linkDetails.sellPrice) then
				linkPrice = linkDetails.sellPrice
				self.cache:SetLinkPrice(itemLink, linkPrice)
			end
		end
		if linkPrice ~= nil then
			price = linkPrice
		end
	end

	if not Money.IsValid(price) then
		return nil, VendorPriceService.UNAVAILABLE
	end
	return price, VendorPriceService.OK
end

-- Forward ITEM_DATA_LOAD_RESULT here. Returns true when this service was
-- waiting for the item (callers can then re-evaluate).
function VendorPriceService:OnItemDataLoaded(itemID, success)
	if self.cache:GetStatus(itemID) ~= ItemCache.STATUS_PENDING then
		return false
	end
	if success then
		local details = self.api.GetItemInfo(itemID)
		if details then
			self.cache:Set(itemID, details)
			if self.callbacks then
				self.callbacks:Fire("ITEM_DETAILS_READY", itemID)
			end
			return true
		end
	end
	self.cache:MarkUnavailable(itemID)
	if self.callbacks then
		self.callbacks:Fire("ITEM_DETAILS_UNAVAILABLE", itemID)
	end
	return true
end
