--[[
Core: initialises Vendor Sniper, wires the services together, forwards game
events and provides the slash commands.

Data flow:
  game events -> AuctionScanner -> ResultStore -> AuctionEvaluator (+ VendorPriceService)
              -> Core.lastResult -> callbacks "RESULTS_UPDATED" -> UI / chat
]]
local addonName, ns = ...

local Settings = ns.Settings
local Sorting = ns.Sorting
local Money = ns.Money
local Listings = ns.Listings
local AuctionEvaluator = ns.AuctionEvaluator
local Diagnostics = ns.Diagnostics
local api = ns.WoWAPI

local Core = {}
ns.Core = Core
-- Global handle for debugging (/dump VendorSniper.lastResult.stats) and for UI modules.
VendorSniper = Core

Core.callbacks = ns.Callbacks.New(function(event, err)
	geterrorhandler()(string.format("%s: error in %s handler: %s", addonName, event, tostring(err)))
end)

-- Initialisation -----------------------------------------------------------

function Core:Initialize()
	VendorSniperDB = Settings.Apply(VendorSniperDB)
	self.db = VendorSniperDB
	ns.Categories.Init(Enum and Enum.ItemClass)

	self.store = ns.ResultStore.New()
	self.vendorPrices = ns.VendorPriceService.New(api, ns.ItemCache.New(), self.callbacks)
	self.scheduler = ns.ScannerScheduler.New({
		now = api.Now,
		after = api.After,
		defer = api.Defer,
		isThrottleReady = api.IsThrottleReady,
		sendSearch = function(target) return target.send() end,
		maxPerMinute = self.db.lookup.batchMaxPerMinute,
		callbacks = self.callbacks,
	})
	self.scanner = ns.AuctionScanner.New({
		api = api,
		vendorPrices = self.vendorPrices,
		scheduler = self.scheduler,
		store = self.store,
		callbacks = self.callbacks,
	})
	self.lastResult = nil
	self.browseChangedSinceScan = false

	-- Evaluation runs first; presentation handlers registered later see lastResult.
	self.callbacks:Register("SCAN_COMPLETE", function() self:Reevaluate() end, self)

	self:RegisterChatFeedback()
	self:RegisterSlashCommands()
end

-- Evaluation ---------------------------------------------------------------

function Core:PriceLookup(record)
	local link = record.kind == Listings.KIND_ITEM and record.link or nil
	return self.vendorPrices:GetVendorPrice(record.itemID, link)
end

function Core:Reevaluate()
	local result = AuctionEvaluator.Process(
		self.store:GetActiveRecords(),
		function(record) return self:PriceLookup(record) end,
		Settings.ToFilters(self.db))
	Sorting.Sort(result.opportunities, self.db.sortKey)
	self.lastResult = result

	if self.db.sound.enabled then
		local fresh = AuctionEvaluator.SelectNewNotifications(
			result.opportunities, self.store.notified, self.db.sound.thresholdCopper)
		if #fresh > 0 then
			PlaySound(SOUNDKIT and SOUNDKIT.LOOT_WINDOW_COIN_SOUND or 120)
		end
	end

	self.callbacks:Fire("RESULTS_UPDATED", result)
	return result
end

-- Many item-data events can arrive in one frame. Evaluate once, on the next frame.
function Core:RequestReevaluate()
	if self.reevaluatePending then
		return
	end
	self.reevaluatePending = true
	api.Defer(function()
		self.reevaluatePending = false
		self:Reevaluate()
	end)
end

-- Player actions -------------------------------------------------------------

function Core:StartScan()
	self.browseChangedSinceScan = false
	local ok, reason = self.scanner:ScanBrowse()
	if not ok and reason == "busy" then
		Diagnostics.Print(Diagnostics.SCAN_FAIL_TEXT.busy)
	end
	return ok, reason
end

function Core:Stop()
	local cancelledScan = self.scanner:CancelScan()
	local cancelledLookups = self.scheduler:CancelLookups()
	return cancelledScan or cancelledLookups
end

-- Browse rows worth a listing lookup, best first; skips rows already looked up or queued.
function Core:GetInspectCandidates()
	local result = self.lastResult
	local candidates = {}
	if not result then
		return candidates
	end
	local function consider(opp)
		local record = opp.record
		if record.kind == Listings.KIND_BROWSE
			and not self.scanner:HasListingsFor(record)
			and not self.scheduler:IsQueued(record.itemKeyString) then
			candidates[#candidates + 1] = record
		end
	end
	local profitable = {}
	for i = 1, #result.opportunities do
		profitable[#profitable + 1] = result.opportunities[i]
	end
	Sorting.Sort(profitable, Sorting.PROFIT)
	for i = 1, #profitable do
		consider(profitable[i])
	end
	for i = 1, #result.possible do
		consider(result.possible[i])
	end
	return candidates
end

-- Click mode: queue one lookup (the best candidate, or `record` if given).
-- Batch mode: queue every candidate. Either way, it's one player action.
function Core:Inspect(record)
	if not self.scanner:IsAuctionHouseOpen() then
		Diagnostics.Print(Diagnostics.SCAN_FAIL_TEXT.ah_closed)
		return 0
	end
	local records
	if record then
		records = { record }
	else
		records = self:GetInspectCandidates()
		if self.db.lookup.mode == Settings.LOOKUP_CLICK then
			records = { records[1] }
		end
	end
	local targets = {}
	for i = 1, #records do
		targets[#targets + 1] = self.scanner:BuildLookupTarget(records[i])
	end
	local added = self.scheduler:EnqueueLookups(targets)
	if added == 0 then
		Diagnostics.Print("Nothing new to inspect.")
	end
	return added
end

-- Events -------------------------------------------------------------------

local events = {}

function events.ADDON_LOADED(name)
	if name == addonName then
		Core:Initialize()
	end
end

function events.AUCTION_HOUSE_SHOW()
	Core.scanner:ClearSession()
	Core.lastResult = nil
	Core.scanner:SetAuctionHouseOpen(true)
	Core.callbacks:Fire("AUCTION_HOUSE_OPENED")
end

local function onAuctionHouseGone(reason)
	Core.scheduler:CancelLookups()
	Core.scanner:SetAuctionHouseOpen(false)
	Core.store:MarkStale()
	Core.callbacks:Fire("AUCTION_HOUSE_CLOSED", reason)
end

function events.AUCTION_HOUSE_CLOSED()
	onAuctionHouseGone("closed")
end

function events.AUCTION_HOUSE_DISABLED()
	onAuctionHouseGone("disabled")
end

function events.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
	Core.browseChangedSinceScan = true
	Core.callbacks:Fire("BROWSE_RESULTS_CHANGED")
end

function events.AUCTION_HOUSE_BROWSE_RESULTS_ADDED()
	Core.browseChangedSinceScan = true
	Core.callbacks:Fire("BROWSE_RESULTS_CHANGED")
end

function events.AUCTION_HOUSE_BROWSE_FAILURE()
	Core.callbacks:Fire("BROWSE_FAILED")
end

local function onItemSearch(itemKey)
	if Core.scanner:OnItemSearchResults(itemKey) then
		Core:RequestReevaluate()
	end
end
events.ITEM_SEARCH_RESULTS_UPDATED = onItemSearch
events.ITEM_SEARCH_RESULTS_ADDED = onItemSearch

local function onCommoditySearch(itemID)
	if Core.scanner:OnCommoditySearchResults(itemID) then
		Core:RequestReevaluate()
	end
end
events.COMMODITY_SEARCH_RESULTS_UPDATED = onCommoditySearch
events.COMMODITY_SEARCH_RESULTS_ADDED = onCommoditySearch

function events.ITEM_DATA_LOAD_RESULT(itemID, success)
	if Core.vendorPrices:OnItemDataLoaded(itemID, success) then
		Core.scanner:RefreshItem(itemID)
		Core:RequestReevaluate()
	end
end

function events.ITEM_KEY_ITEM_INFO_RECEIVED(itemID)
	if Core.scanner:RefreshItem(itemID) then
		Core:RequestReevaluate()
	end
end

function events.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
	Core.scheduler:OnThrottleReady()
end

function events.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED()
	Core.scheduler:OnMessageDropped()
end

local eventFrame = CreateFrame("Frame")
for event in pairs(events) do
	eventFrame:RegisterEvent(event)
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
	if event ~= "ADDON_LOADED" and not Core.db then
		return -- not initialised yet
	end
	events[event](...)
end)

-- Chat feedback (until the window exists) -------------------------------------

function Core:RegisterChatFeedback()
	local cb = self.callbacks
	cb:Register("SCAN_FAILED", function(reason)
		Diagnostics.Print(Diagnostics.SCAN_FAIL_TEXT[reason] or ("Scan failed: " .. tostring(reason)))
	end)
	cb:Register("SCAN_COMPLETE", function(summary)
		local result = self.lastResult
		Diagnostics.Print("Scanned %d browse results%s.", summary.total,
			summary.hasFullResults and "" or " (more pages exist; scroll the AH list to load them, then scan again)")
		Diagnostics.PrintResults(result, 5, self.store.isStale)
	end)
	cb:Register("SCAN_CANCELLED", function()
		Diagnostics.Print("Scan cancelled.")
	end)
	cb:Register("BROWSE_FAILED", function()
		Diagnostics.Print("The Auction House reported a browse error.")
	end)
	cb:Register("LOOKUP_DONE", function(target, outcome)
		local status = self.scheduler:GetLookupStatus()
		if outcome ~= "ok" then
			Diagnostics.Print("Lookup for %s: %s.", tostring(target.name or target.id), outcome)
		end
		if status.queued == 0 and not status.inFlight and status.total > 1 then
			Diagnostics.Print("Inspected %d items.", status.completed)
		end
	end)
end

-- Slash commands -------------------------------------------------------------

local function parsePercentToBasisPoints(text)
	local n = tonumber(text)
	if not n then
		return nil
	end
	return math.floor(n * 100 + 0.5)
end

local commands = {}

function commands.scan()
	Core:StartScan()
end

function commands.results(arg)
	if Core.lastResult then
		Core:Reevaluate()
	end
	Diagnostics.PrintResults(Core.lastResult, tonumber(arg) or 10, Core.store.isStale)
end

function commands.inspect()
	local added = Core:Inspect()
	if added > 0 then
		Diagnostics.Print("Queued %d lookup%s (%s mode).", added, added == 1 and "" or "s", Core.db.lookup.mode)
	end
end

function commands.stop()
	if not Core:Stop() then
		Diagnostics.Print("Nothing to stop.")
	end
end

function commands.lookup(arg)
	local mode, perMinute = string.match(arg or "", "^(%a+)%s*(%d*)$")
	if mode ~= Settings.LOOKUP_CLICK and mode ~= Settings.LOOKUP_BATCH then
		Diagnostics.Print("Lookup mode: %s (%d/min in batch). Use: /vsniper lookup click|batch [perMinute]",
			Core.db.lookup.mode, Core.db.lookup.batchMaxPerMinute)
		return
	end
	Core.db.lookup.mode = mode
	if perMinute and perMinute ~= "" then
		Core.db.lookup.batchMaxPerMinute = tonumber(perMinute)
	end
	Settings.Apply(Core.db)
	Core.scheduler:SetMaxPerMinute(Core.db.lookup.batchMaxPerMinute)
	Diagnostics.Print("Lookup mode set to %s (%d/min budget).", Core.db.lookup.mode, Core.db.lookup.batchMaxPerMinute)
end

function commands.sort(arg)
	if not Sorting.IsValid(arg) then
		Diagnostics.Print("Sort keys: %s", table.concat(Sorting.ORDER, ", "))
		return
	end
	Core.db.sortKey = arg
	Diagnostics.Print("Sorting by %s.", Sorting.LABELS[arg])
end

function commands.minprofit(arg)
	local copper = Money.Parse(arg)
	if not copper then
		Diagnostics.Print("Minimum profit: %s. Example: /vsniper minprofit 50s", Money.Format(Core.db.minProfit))
		return
	end
	Core.db.minProfit = copper
	Diagnostics.Print("Minimum profit set to %s.", Money.Format(copper))
end

function commands.minroi(arg)
	local bp = parsePercentToBasisPoints(arg)
	if not bp then
		Diagnostics.Print("Minimum ROI: %s. Example: /vsniper minroi 25", Money.FormatRoi(Core.db.minRoiBasisPoints))
		return
	end
	Core.db.minRoiBasisPoints = bp
	Diagnostics.Print("Minimum ROI set to %s.", Money.FormatRoi(bp))
end

function commands.maxbuyout(arg)
	local copper = Money.Parse(arg)
	if not copper then
		Diagnostics.Print("Maximum buyout: %s (0 = no limit).", Money.Format(Core.db.maxBuyout))
		return
	end
	Core.db.maxBuyout = copper
	Diagnostics.Print("Maximum buyout set to %s.", copper == 0 and "no limit" or Money.Format(copper))
end

function commands.sound(arg)
	local state, threshold = string.match(arg or "", "^(%a+)%s*(.*)$")
	if state == "on" or state == "off" then
		Core.db.sound.enabled = state == "on"
		local copper = Money.Parse(threshold)
		if copper then
			Core.db.sound.thresholdCopper = copper
		end
	end
	Diagnostics.Print("Sound notification %s (threshold %s).",
		Core.db.sound.enabled and "on" or "off", Money.Format(Core.db.sound.thresholdCopper))
end

function commands.status()
	local s = Core.scheduler:GetLookupStatus()
	Diagnostics.Print("AH open: %s, scanning: %s, browse records: %d, listing groups: %d%s",
		tostring(Core.scanner:IsAuctionHouseOpen()), tostring(Core.scanner:IsScanning()),
		Core.store:CountBrowse(), Core.store:CountGroups(),
		Core.browseChangedSinceScan and ", browse results changed since last scan" or "")
	Diagnostics.Print("Lookups (%s mode): %s, %d queued, %d/%d done, %d/%d used this minute.",
		Core.db.lookup.mode, s.state, s.queued, s.completed, s.total, s.usedThisMinute, s.maxPerMinute)
end

function commands.probe()
	Diagnostics.Probe(Core)
end

function commands.help()
	Diagnostics.Help()
end

function Core:RegisterSlashCommands()
	SLASH_VENDORSNIPER1 = "/vsniper"
	SLASH_VENDORSNIPER2 = "/vendorsniper"
	SlashCmdList.VENDORSNIPER = function(input)
		local command, rest = string.match(input or "", "^%s*(%S*)%s*(.-)%s*$")
		command = string.lower(command or "")
		local handler = commands[command] or commands.help
		handler(rest)
	end
end
