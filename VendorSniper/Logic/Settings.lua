--[[
Settings: defaults and validation for the VendorSniperDB SavedVariable.

Pure module. Settings.Apply(saved) fills in missing values, fixes values of
the wrong type or out of range, and returns the table to use.
]]
local _, ns = ...

local Money = ns.Money
local Sorting = ns.Sorting
local Categories = ns.Categories

local Settings = {}
ns.Settings = Settings

Settings.SCHEMA_VERSION = 1

Settings.LOOKUP_CLICK = "click" -- one search per player action (default)
Settings.LOOKUP_BATCH = "batch" -- one player action queues searches for all candidates
Settings.BATCH_MIN_PER_MINUTE = 1
-- Stays below the documented 100 SendSearchQuery calls per minute, leaving
-- headroom for the Blizzard UI's own searches.
Settings.BATCH_MAX_PER_MINUTE = 90

-- Item quality IDs (Enum.ItemQuality): Poor .. Artifact.
Settings.QUALITY_IDS = { 0, 1, 2, 3, 4, 5, 6 }

function Settings.Defaults()
	local qualities = {}
	for i = 1, #Settings.QUALITY_IDS do
		qualities[Settings.QUALITY_IDS[i]] = true
	end
	local categories = {}
	for i = 1, #Categories.ORDER do
		categories[Categories.ORDER[i]] = true
	end
	return {
		schemaVersion = Settings.SCHEMA_VERSION,
		minProfit = 1, -- copper; only positive profit counts anyway
		minRoiBasisPoints = 0,
		maxBuyout = 0, -- 0 = no limit
		categories = categories,
		qualities = qualities,
		sortKey = Sorting.DEFAULT,
		sound = {
			enabled = false,
			thresholdCopper = 10000, -- 1g
		},
		lookup = {
			mode = Settings.LOOKUP_CLICK,
			batchMaxPerMinute = 30,
		},
		-- No window position/size: the UI is a tab inside the fixed-size Auction House frame.
	}
end

local function isNumber(v)
	return type(v) == "number" and v == v
end

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- Copies `default` into `target` for every missing or mistyped key (recursive).
local function fill(target, default)
	for k, dv in pairs(default) do
		local tv = target[k]
		if type(dv) == "table" then
			if type(tv) ~= "table" then
				tv = {}
				target[k] = tv
			end
			fill(tv, dv)
		elseif type(tv) ~= type(dv) or (type(dv) == "number" and not isNumber(tv)) then
			target[k] = dv
		end
	end
end

--[[
Validates `saved` in place (or creates a new table when nil) and returns it.
Unknown extra keys are kept, so newer versions can downgrade gracefully.
]]
function Settings.Apply(saved)
	local defaults = Settings.Defaults()
	if type(saved) ~= "table" then
		saved = {}
	end
	fill(saved, defaults)

	if not Money.IsValid(saved.minProfit) then saved.minProfit = defaults.minProfit end
	if not Money.IsWhole(saved.minRoiBasisPoints) then saved.minRoiBasisPoints = defaults.minRoiBasisPoints end
	if not Money.IsValid(saved.maxBuyout) then saved.maxBuyout = defaults.maxBuyout end
	if not Sorting.IsValid(saved.sortKey) then saved.sortKey = defaults.sortKey end
	if not Money.IsValid(saved.sound.thresholdCopper) then
		saved.sound.thresholdCopper = defaults.sound.thresholdCopper
	end

	local mode = saved.lookup.mode
	if mode ~= Settings.LOOKUP_CLICK and mode ~= Settings.LOOKUP_BATCH then
		saved.lookup.mode = defaults.lookup.mode
	end
	saved.lookup.batchMaxPerMinute = clamp(
		math.floor(saved.lookup.batchMaxPerMinute),
		Settings.BATCH_MIN_PER_MINUTE,
		Settings.BATCH_MAX_PER_MINUTE)


	saved.schemaVersion = Settings.SCHEMA_VERSION
	return saved
end

-- Builds the filter table that AuctionEvaluator.PassesFilters expects.
function Settings.ToFilters(settings)
	return {
		minProfit = settings.minProfit,
		minRoiBasisPoints = settings.minRoiBasisPoints,
		maxBuyout = settings.maxBuyout,
		categories = settings.categories,
		qualities = settings.qualities,
	}
end
