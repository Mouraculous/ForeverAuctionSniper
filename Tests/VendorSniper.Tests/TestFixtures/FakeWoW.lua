--[[
Test doubles for the WoW API surface the services use.
Raw data uses the exact field names of the Forever API structures
(BrowseResultInfo, ItemSearchResultInfo, CommoditySearchResultInfo, ItemKeyInfo).
]]
local ns = ...

local Fake = {}

-- A manual clock: after() timers fire on advance(), defer() runs on runDeferred().
function Fake.NewClock()
	local clock = { t = 0, timers = {}, deferred = {}, frames = 0 }

	function clock.now()
		return clock.t
	end

	function clock.after(seconds, fn)
		clock.timers[#clock.timers + 1] = { at = clock.t + seconds, fn = fn }
	end

	function clock.defer(fn)
		clock.deferred[#clock.deferred + 1] = fn
	end

	-- Runs deferred callbacks frame by frame until none are left. Returns frames run.
	function clock.runDeferred()
		local frames = 0
		while #clock.deferred > 0 do
			local list = clock.deferred
			clock.deferred = {}
			frames = frames + 1
			for i = 1, #list do
				list[i]()
			end
		end
		clock.frames = clock.frames + frames
		return frames
	end

	function clock.advance(seconds)
		local target = clock.t + seconds
		while true do
			local index, best
			for i = 1, #clock.timers do
				local timer = clock.timers[i]
				if timer.at <= target and (not best or timer.at < best.at) then
					index, best = i, timer
				end
			end
			if not index then
				break
			end
			table.remove(clock.timers, index)
			clock.t = best.at
			best.fn()
		end
		clock.t = target
	end

	return clock
end

function Fake.ItemKey(itemID, itemLevel, itemSuffix)
	return { itemID = itemID, itemLevel = itemLevel or 0, itemSuffix = itemSuffix or 0, battlePetSpeciesID = 0 }
end

--[[
data = {
  items        = { [itemID or link] = { name, link, quality, maxStack, icon, sellPrice, classID, subClassID } },
  uncached     = { [itemID] = true }   -- GetItemInfo returns nil until cleared
  keyInfo      = { [itemID] = ItemKeyInfo },
  browse       = { BrowseResultInfo, ... },
  itemRows     = { [itemKeyString] = { ItemSearchResultInfo, ... } },
  commodityRows= { [itemID] = { CommoditySearchResultInfo, ... } },
}
]]
function Fake.NewAPI(data)
	data = data or {}
	local api = {
		data = data,
		throttleReady = true,
		hasFullBrowse = true,
		calls = { requestLoad = {}, getItemInfo = 0, sendSearch = {} },
	}
	data.items = data.items or {}
	data.uncached = data.uncached or {}
	data.keyInfo = data.keyInfo or {}
	data.browse = data.browse or {}
	data.itemRows = data.itemRows or {}
	data.commodityRows = data.commodityRows or {}

	function api.HasAuctionHouseAPI() return true end
	function api.GetBrowseResults() return data.browse end
	function api.HasFullBrowseResults() return api.hasFullBrowse end
	function api.GetItemKeyInfo(itemKey) return data.keyInfo[itemKey.itemID] end
	function api.GetItemSearchRows(itemKey)
		return data.itemRows[ns.Listings.ItemKeyString(itemKey)] or {}, true
	end
	function api.GetCommoditySearchRows(itemID)
		return data.commodityRows[itemID] or {}, true
	end
	function api.SendSearchQuery(itemKey)
		api.calls.sendSearch[#api.calls.sendSearch + 1] = itemKey
		return true
	end
	function api.IsThrottleReady() return api.throttleReady end
	function api.GetItemInfo(item)
		api.calls.getItemInfo = api.calls.getItemInfo + 1
		if data.uncached[item] then
			return nil
		end
		return data.items[item]
	end
	function api.GetItemInfoInstant(itemID)
		local item = data.items[itemID]
		if item then
			return item.classID, item.subClassID, item.icon
		end
		return nil
	end
	function api.GetItemMaxStackSize(itemID)
		local item = data.items[itemID]
		return item and item.maxStack or nil
	end
	function api.RequestLoadItemData(itemID)
		api.calls.requestLoad[#api.calls.requestLoad + 1] = itemID
	end

	return api
end

-- Builds a full service graph (as Core does) on top of fakes.
function Fake.NewEnvironment(data)
	local env = {}
	env.clock = Fake.NewClock()
	env.api = Fake.NewAPI(data)
	env.callbacks = ns.Callbacks.New(function(event, err) error(event .. ": " .. tostring(err)) end)
	env.fired = {}
	local originalFire = env.callbacks.Fire
	env.callbacks.Fire = function(self, event, ...)
		env.fired[#env.fired + 1] = { event = event, args = { ... } }
		return originalFire(self, event, ...)
	end
	env.store = ns.ResultStore.New()
	env.vendorPrices = ns.VendorPriceService.New(env.api, ns.ItemCache.New(), env.callbacks)
	env.scheduler = ns.ScannerScheduler.New({
		now = env.clock.now,
		after = env.clock.after,
		defer = env.clock.defer,
		isThrottleReady = function() return env.api.IsThrottleReady() end,
		sendSearch = function(target) return target.send() end,
		maxPerMinute = 30,
		callbacks = env.callbacks,
	})
	env.scanner = ns.AuctionScanner.New({
		api = env.api,
		vendorPrices = env.vendorPrices,
		scheduler = env.scheduler,
		store = env.store,
		callbacks = env.callbacks,
	})

	function env.lastEvent(name)
		for i = #env.fired, 1, -1 do
			if env.fired[i].event == name then
				return env.fired[i]
			end
		end
		return nil
	end

	function env.evaluate(filters)
		return ns.AuctionEvaluator.Process(env.store:GetActiveRecords(), function(record)
			local link = record.kind == ns.Listings.KIND_ITEM and record.link or nil
			return env.vendorPrices:GetVendorPrice(record.itemID, link)
		end, filters)
	end

	return env
end

return Fake
