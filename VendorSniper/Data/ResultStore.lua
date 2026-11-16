--[[
ResultStore: temporary in-memory store for the current session's scan data.

Pure module. It holds:
  * the latest browse snapshot (one record per ItemKey)
  * listing groups (per searched ItemKey / commodity item ID), each a full
    snapshot of that search's rows
  * the set of record keys we've already notified about

A browse record is hidden once a listing group that supersedes it exists,
because the listings are more precise. Nothing here is written to
SavedVariables.
]]
local _, ns = ...

local ResultStore = {}
ResultStore.__index = ResultStore
ns.ResultStore = ResultStore

function ResultStore.New()
	local self = setmetatable({}, ResultStore)
	self:Clear()
	self.notified = {}
	return self
end

-- Drops scan data but keeps the notification history for the session.
function ResultStore:Clear()
	self.browseByKey = {}
	self.browseOrder = {}
	self.groups = {}
	self.groupOrder = {}
	self.isStale = false
end

-- Replaces the whole browse snapshot (a new browse search was scanned).
function ResultStore:SetBrowseSnapshot(records)
	self.browseByKey = {}
	self.browseOrder = {}
	self:AddBrowseRecords(records)
	self.isStale = false
end

-- Merges browse records by key (a newer row for the same ItemKey replaces the old one).
function ResultStore:AddBrowseRecords(records)
	for i = 1, #records do
		local record = records[i]
		if not self.browseByKey[record.key] then
			self.browseOrder[#self.browseOrder + 1] = record.key
		end
		self.browseByKey[record.key] = record
	end
end

-- Replaces the listing snapshot for one group. An empty list keeps the group,
-- which records that "this item was searched and nothing is listed".
function ResultStore:SetListingGroup(groupKey, records)
	if not self.groups[groupKey] then
		self.groupOrder[#self.groupOrder + 1] = groupKey
	end
	self.groups[groupKey] = records
end

function ResultStore:HasListingGroup(groupKey)
	return self.groups[groupKey] ~= nil
end

function ResultStore:GetListingGroup(groupKey)
	return self.groups[groupKey]
end

function ResultStore:IsSuperseded(browseRecord)
	local keys = browseRecord.supersededBy
	if keys then
		for i = 1, #keys do
			if self.groups[keys[i]] then
				return true
			end
		end
	end
	return false
end

-- All records that should be evaluated: listing records first, then
-- browse records that no listing group supersedes.
function ResultStore:GetActiveRecords()
	local result = {}
	for i = 1, #self.groupOrder do
		local records = self.groups[self.groupOrder[i]]
		for j = 1, #records do
			result[#result + 1] = records[j]
		end
	end
	for i = 1, #self.browseOrder do
		local record = self.browseByKey[self.browseOrder[i]]
		if record and not self:IsSuperseded(record) then
			result[#result + 1] = record
		end
	end
	return result
end

function ResultStore:GetBrowseRecords()
	local result = {}
	for i = 1, #self.browseOrder do
		result[#result + 1] = self.browseByKey[self.browseOrder[i]]
	end
	return result
end

function ResultStore:CountBrowse()
	return #self.browseOrder
end

function ResultStore:CountGroups()
	return #self.groupOrder
end

-- Marks the data as possibly outdated (for example, the AH was closed).
function ResultStore:MarkStale()
	self.isStale = true
end
