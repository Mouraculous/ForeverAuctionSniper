--[[
Minimal stand-ins for the WoW client globals that Core.lua, Diagnostics.lua
and WoWAPI.lua touch, backed by an AuctionData fixture. Used only for the
end-to-end smoke test. It doesn't simulate the client faithfully. It checks
that the wiring, events and slash commands run without errors.
]]
local data = ...

local game = { frames = {}, chat = {}, timers = {}, now = 0, searches = {}, sounds = {}, loadRequests = {} }

function CreateFrame()
	local frame = { events = {}, scripts = {} }
	function frame:RegisterEvent(event) self.events[event] = true end
	function frame:SetScript(name, fn) self.scripts[name] = fn end
	game.frames[#game.frames + 1] = frame
	return frame
end

function game.fire(event, ...)
	for i = 1, #game.frames do
		local frame = game.frames[i]
		if frame.events[event] and frame.scripts.OnEvent then
			frame.scripts.OnEvent(frame, event, ...)
		end
	end
end

function game.runTimers(seconds)
	local target = game.now + (seconds or 0)
	while true do
		local index, best
		for i = 1, #game.timers do
			local t = game.timers[i]
			if t.at <= target and (not best or t.at < best.at) then
				index, best = i, t
			end
		end
		if not index then break end
		table.remove(game.timers, index)
		game.now = math.max(game.now, best.at)
		best.fn()
	end
	game.now = target
end

function game.chatText()
	return table.concat(game.chat, "\n")
end

DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) game.chat[#game.chat + 1] = text end }
SlashCmdList = {}
function geterrorhandler() return function(err) error(err, 0) end end
function GetTime() return game.now end
function GetBuildInfo() return "1.60.1", "70938", "Nov 13 2026", 16001, "", "" end
WOW_PROJECT_ID = 18
SOUNDKIT = { LOOT_WINDOW_COIN_SOUND = 120 }
function PlaySound(id) game.sounds[#game.sounds + 1] = id end
Enum = {
	ItemClass = { Consumable = 0, Container = 1, Weapon = 2, Armor = 4, Reagent = 5, Tradegoods = 7, Recipe = 9 },
	AuctionHouseSortOrder = { Price = 0, Name = 1, Level = 2, Bid = 3, Buyout = 4, TimeRemaining = 5 },
}

C_Timer = {
	After = function(seconds, fn)
		game.timers[#game.timers + 1] = { at = game.now + seconds, fn = fn }
	end,
}

local function keyString(itemKey)
	return string.format("%d:%d:%d:%d", itemKey.itemID, itemKey.itemLevel or 0, itemKey.itemSuffix or 0, itemKey.battlePetSpeciesID or 0)
end

C_AuctionHouse = {
	GetBrowseResults = function() return data.browse end,
	HasFullBrowseResults = function() return true end,
	GetItemKeyInfo = function(itemKey) return data.keyInfo[itemKey.itemID] end,
	GetNumItemSearchResults = function(itemKey) return #(data.itemRows[keyString(itemKey)] or {}) end,
	GetItemSearchResultInfo = function(itemKey, i) return (data.itemRows[keyString(itemKey)] or {})[i] end,
	HasFullItemSearchResults = function() return true end,
	GetNumCommoditySearchResults = function(itemID) return #(data.commodityRows[itemID] or {}) end,
	GetCommoditySearchResultInfo = function(itemID, i) return (data.commodityRows[itemID] or {})[i] end,
	HasFullCommoditySearchResults = function() return true end,
	SendSearchQuery = function(itemKey, sorts, separateOwnerItems)
		game.searches[#game.searches + 1] = { itemKey = itemKey, sorts = sorts, separateOwnerItems = separateOwnerItems }
	end,
	IsThrottledMessageSystemReady = function() return true end,
	SupportsCopperValues = function() return true end,
}

C_Item = {
	GetItemInfo = function(item)
		local d = data.items[item]
		if not d then return nil end
		return d.name, d.link, d.quality, 1, 1, "", "", d.maxStack, "", d.icon, d.sellPrice, d.classID, d.subClassID, 0, 0, nil, false, ""
	end,
	GetItemInfoInstant = function(itemID)
		local d = data.items[itemID]
		if not d then return nil end
		return itemID, "", "", "", d.icon, d.classID, d.subClassID
	end,
	GetItemMaxStackSizeByID = function(itemID)
		local d = data.items[itemID]
		return d and d.maxStack
	end,
	RequestLoadItemDataByID = function(itemID) game.loadRequests[#game.loadRequests + 1] = itemID end,
}

return game
