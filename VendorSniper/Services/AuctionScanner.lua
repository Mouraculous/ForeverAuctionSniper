--[[
AuctionScanner: reads Auction House data the client already holds and turns
it into records in the ResultStore.

  * ScanBrowse(): player-initiated. Reads C_AuctionHouse.GetBrowseResults()
    in chunks (no server query) and replaces the browse snapshot.
  * OnItemSearchResults / OnCommoditySearchResults: called for the
    ITEM_/COMMODITY_SEARCH_RESULTS_* events. This catches listings whether the
    player opened the item in the Blizzard UI or Vendor Sniper looked it up.
  * BuildLookupTarget(): describes a listing lookup for ScannerScheduler.

Dependencies (injected): api (WoWAPI shape), vendorPrices
(VendorPriceService), scheduler (ScannerScheduler), store (ResultStore),
callbacks (Callbacks).

Fires: SCAN_STARTED(total), SCAN_PROGRESS(done, total),
SCAN_COMPLETE(summary), SCAN_CANCELLED(), SCAN_FAILED(reason),
LISTINGS_UPDATED(groupKey, count, skipped).
The scanner has no knowledge of any UI.
]]
local _, ns = ...

local Listings = ns.Listings

local AuctionScanner = {}
AuctionScanner.__index = AuctionScanner
ns.AuctionScanner = AuctionScanner

AuctionScanner.CHUNK_SIZE = 40

AuctionScanner.FAIL_AH_CLOSED = "ah_closed"
AuctionScanner.FAIL_NO_API = "no_api"
AuctionScanner.FAIL_NO_RESULTS = "no_results"
AuctionScanner.FAIL_BUSY = "busy"

function AuctionScanner.New(deps)
	local self = setmetatable({}, AuctionScanner)
	self.api = deps.api
	self.vendorPrices = deps.vendorPrices
	self.scheduler = deps.scheduler
	self.store = deps.store
	self.callbacks = deps.callbacks
	self.isOpen = false
	self.browseRaw = {} -- record key -> raw BrowseResultInfo (for rebuilding)
	self.groupSources = {} -- groupKey -> { kind, itemKey | itemID, rows, isPartial }
	return self
end

function AuctionScanner:SetAuctionHouseOpen(isOpen)
	self.isOpen = isOpen and true or false
	if not self.isOpen then
		if self.scheduler:IsJobRunning() then
			self.scheduler:CancelJob()
		end
	end
end

function AuctionScanner:IsAuctionHouseOpen()
	return self.isOpen
end

function AuctionScanner:IsScanning()
	return self.scheduler:IsJobRunning()
end

-- Collects item metadata for an ItemKey from ItemKeyInfo and the item cache.
-- Missing pieces stay nil; a later ITEM_* event lets us rebuild.
function AuctionScanner:GetItemInfoForKey(itemKey)
	local itemID = itemKey.itemID
	local keyInfo = self.api.GetItemKeyInfo(itemKey)
	local details = self.vendorPrices:GetDetails(itemID)

	local classID
	if details then
		classID = details.classID
	else
		classID = self.api.GetItemInfoInstant(itemID)
	end

	local maxStack = details and details.maxStack
	if maxStack == nil then
		maxStack = self.api.GetItemMaxStackSize(itemID)
	end

	local info = {
		classID = classID,
		maxStack = maxStack,
		link = details and details.link or nil,
		name = details and details.name or nil,
		quality = details and details.quality or nil,
		icon = details and details.icon or nil,
	}
	if keyInfo then
		info.isCommodity = keyInfo.isCommodity == true
		info.isEquipment = keyInfo.isEquipment == true
		info.name = keyInfo.itemName or info.name
		info.quality = keyInfo.quality or info.quality
		info.icon = keyInfo.iconFileID or info.icon
	end
	return info
end

-- Browse scan --------------------------------------------------------------

function AuctionScanner:ScanBrowse()
	if not self.api.HasAuctionHouseAPI() then
		self.callbacks:Fire("SCAN_FAILED", AuctionScanner.FAIL_NO_API)
		return false, AuctionScanner.FAIL_NO_API
	end
	if not self.isOpen then
		self.callbacks:Fire("SCAN_FAILED", AuctionScanner.FAIL_AH_CLOSED)
		return false, AuctionScanner.FAIL_AH_CLOSED
	end
	if self.scheduler:IsJobRunning() then
		return false, AuctionScanner.FAIL_BUSY
	end

	local rawResults = self.api.GetBrowseResults()
	local hasFull = self.api.HasFullBrowseResults()
	if #rawResults == 0 then
		self.callbacks:Fire("SCAN_FAILED", AuctionScanner.FAIL_NO_RESULTS, hasFull)
		return false, AuctionScanner.FAIL_NO_RESULTS
	end

	-- Copy so new pages arriving during the scan don't shift indices.
	local snapshot = {}
	for i = 1, #rawResults do
		snapshot[i] = rawResults[i]
	end

	local records, browseRaw = {}, {}
	local skipped = {}

	local function processItem(raw)
		local record, reason
		if type(raw) == "table" and type(raw.itemKey) == "table" then
			record, reason = Listings.FromBrowseResult(raw, self:GetItemInfoForKey(raw.itemKey))
		else
			reason = Listings.SKIP_INVALID
		end
		if record then
			records[#records + 1] = record
			browseRaw[record.key] = raw
		else
			skipped[reason] = (skipped[reason] or 0) + 1
		end
	end

	local function onProgress(done, total)
		self.callbacks:Fire("SCAN_PROGRESS", done, total)
	end

	local function onComplete(cancelled, failures)
		if cancelled then
			self.callbacks:Fire("SCAN_CANCELLED")
			return
		end
		if failures > 0 then
			skipped[Listings.SKIP_INVALID] = (skipped[Listings.SKIP_INVALID] or 0) + failures
		end
		self.browseRaw = browseRaw
		self.store:SetBrowseSnapshot(records)
		self.callbacks:Fire("SCAN_COMPLETE", {
			total = #snapshot,
			records = #records,
			skipped = skipped,
			hasFullResults = hasFull,
		})
	end

	self.callbacks:Fire("SCAN_STARTED", #snapshot)
	return self.scheduler:StartJob(snapshot, AuctionScanner.CHUNK_SIZE, processItem, onProgress, onComplete)
end

function AuctionScanner:CancelScan()
	return self.scheduler:CancelJob()
end

-- Listings -----------------------------------------------------------------

function AuctionScanner:BuildItemGroup(itemKey, rows, isPartial)
	local info = self:GetItemInfoForKey(itemKey)
	info.isCommodity = false
	return Listings.FromItemSearchResults(itemKey, rows, info, isPartial)
end

function AuctionScanner:BuildCommodityGroup(itemID, rows, isPartial)
	local itemKey = { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
	local info = self:GetItemInfoForKey(itemKey)
	info.isCommodity = true
	return Listings.FromCommoditySearchResults(itemID, rows, info, isPartial)
end

-- ITEM_SEARCH_RESULTS_UPDATED / _ADDED (itemKey)
function AuctionScanner:OnItemSearchResults(itemKey)
	if not self.isOpen or type(itemKey) ~= "table" then
		return nil
	end
	local itemKeyString = Listings.ItemKeyString(itemKey)
	if not itemKeyString then
		return nil
	end
	local groupKey = Listings.ItemGroupKey(itemKeyString)
	local rows, hasFull = self.api.GetItemSearchRows(itemKey)
	local records, skipped = self:BuildItemGroup(itemKey, rows, not hasFull)
	self.groupSources[groupKey] = { kind = Listings.KIND_ITEM, itemKey = itemKey, itemID = itemKey.itemID, rows = rows, isPartial = not hasFull }
	self.store:SetListingGroup(groupKey, records)
	self.scheduler:OnSearchResults(groupKey)
	self.callbacks:Fire("LISTINGS_UPDATED", groupKey, #records, skipped)
	return groupKey
end

-- COMMODITY_SEARCH_RESULTS_UPDATED / _ADDED (itemID)
function AuctionScanner:OnCommoditySearchResults(itemID)
	if not self.isOpen or type(itemID) ~= "number" then
		return nil
	end
	local groupKey = Listings.CommodityGroupKey(itemID)
	local rows, hasFull = self.api.GetCommoditySearchRows(itemID)
	local records, skipped = self:BuildCommodityGroup(itemID, rows, not hasFull)
	self.groupSources[groupKey] = { kind = Listings.KIND_COMMODITY, itemID = itemID, rows = rows, isPartial = not hasFull }
	self.store:SetListingGroup(groupKey, records)
	self.scheduler:OnSearchResults(groupKey)
	self.callbacks:Fire("LISTINGS_UPDATED", groupKey, #records, skipped)
	return groupKey
end

-- Rebuilds records for itemID after its item data or ItemKeyInfo arrived.
-- Uses the raw rows we already hold, so no API query is made.
-- Returns true when anything was rebuilt.
function AuctionScanner:RefreshItem(itemID)
	local changed = false
	local rebuilt = {}
	for key, raw in pairs(self.browseRaw) do
		if raw.itemKey and raw.itemKey.itemID == itemID then
			local record = Listings.FromBrowseResult(raw, self:GetItemInfoForKey(raw.itemKey))
			if record then
				rebuilt[#rebuilt + 1] = record
			end
		end
	end
	if #rebuilt > 0 then
		self.store:AddBrowseRecords(rebuilt)
		changed = true
	end
	for groupKey, source in pairs(self.groupSources) do
		if source.itemID == itemID then
			local records
			if source.kind == Listings.KIND_ITEM then
				records = self:BuildItemGroup(source.itemKey, source.rows, source.isPartial)
			else
				records = self:BuildCommodityGroup(source.itemID, source.rows, source.isPartial)
			end
			self.store:SetListingGroup(groupKey, records)
			changed = true
		end
	end
	return changed
end

function AuctionScanner:ClearSession()
	self.browseRaw = {}
	self.groupSources = {}
	self.store:Clear()
end

-- Lookups ------------------------------------------------------------------

-- Describes a listing lookup for a browse record (or any record with an itemKey).
function AuctionScanner:BuildLookupTarget(record)
	local matchKeys = record.supersededBy
	if not matchKeys then
		matchKeys = { record.groupKey }
	end
	local api = self.api
	return {
		id = record.itemKeyString,
		itemKey = record.itemKey,
		itemID = record.itemID,
		name = record.name,
		matchKeys = matchKeys,
		send = function()
			return api.SendSearchQuery(record.itemKey)
		end,
	}
end

-- True when listings for this browse record were already read this session.
function AuctionScanner:HasListingsFor(record)
	return self.store:IsSuperseded(record)
end
