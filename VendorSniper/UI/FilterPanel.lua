--[[
FilterPanel: the left-hand filter column, styled like the Auction House
category list (InsetFrameTemplate + the AH categories background).

Every control writes straight into the SavedVariables table (core.db) and
then calls onChanged(). Sync() re-reads the values, for example after a
slash command changed them.
]]
local _, ns = ...

local Categories = ns.Categories
local Settings = ns.Settings

local FilterPanel = {}
FilterPanel.__index = FilterPanel
ns.FilterPanel = FilterPanel

FilterPanel.WIDTH = 168

local QUALITY_FALLBACK = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary" }
local SHOWN_QUALITIES = { 0, 1, 2, 3, 4, 5 }
local CATEGORY_LABELS = {
	[Categories.EQUIPMENT] = "Equipment & weapons",
	[Categories.MATERIAL] = "Crafting materials",
	[Categories.CONSUMABLE] = "Consumables",
}

local function qualityName(quality)
	return _G["ITEM_QUALITY" .. quality .. "_DESC"] or QUALITY_FALLBACK[quality] or tostring(quality)
end

local function setTooltip(frame, title, text)
	frame:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip_SetTitle(GameTooltip, title)
		GameTooltip_AddNormalLine(GameTooltip, text, true)
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function FilterPanel.Create(parent, core, onChanged)
	local self = setmetatable({ core = core, onChanged = onChanged, syncers = {} }, FilterPanel)

	local frame = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
	frame:SetWidth(FilterPanel.WIDTH)
	self.frame = frame

	local background = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
	background:SetAtlas("auctionhouse-background-categories", true)
	background:SetPoint("TOPLEFT", 3, -3)

	self.y = -8
	self:Build()
	return self
end

function FilterPanel:Changed()
	if self.onChanged then
		self.onChanged()
	end
end

function FilterPanel:Header(text)
	local label = self.frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	label:SetPoint("TOPLEFT", 10, self.y)
	label:SetText(text)
	self.y = self.y - 18
end

function FilterPanel:Label(text)
	local label = self.frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	label:SetPoint("TOPLEFT", 12, self.y)
	label:SetText(text)
	self.y = self.y - 14
	return label
end

-- A Blizzard checkbox. column (0 or 1) allows two checkboxes per line.
function FilterPanel:Checkbox(text, get, set, column, tooltip)
	local check = CreateFrame("CheckButton", nil, self.frame, "UICheckButtonTemplate")
	check:SetSize(22, 22)
	check:SetPoint("TOPLEFT", 8 + (column or 0) * 76, self.y)
	check.Text:SetFontObject(GameFontHighlightSmall)
	check.Text:SetText(text)
	check:SetScript("OnClick", function(button)
		set(button:GetChecked())
		self:Changed()
	end)
	if tooltip then
		setTooltip(check, text, tooltip)
	end
	self.syncers[#self.syncers + 1] = function() check:SetChecked(get()) end
	if not column or column == 1 then
		self.y = self.y - 20
	end
	return check
end

-- Blizzard's gold/silver/copper input (needs a global name for its child boxes).
function FilterPanel:MoneyInput(name, get, set)
	local input = CreateFrame("Frame", name, self.frame, "MoneyInputFrameTemplate")
	input:SetScale(0.82)
	input:SetPoint("TOPLEFT", 16 / 0.82, (self.y - 2) / 0.82)
	local syncing = false
	MoneyInputFrame_SetOnValueChangedFunc(input, function()
		if syncing then
			return
		end
		set(MoneyInputFrame_GetCopper(input) or 0)
		self:Changed()
	end)
	self.syncers[#self.syncers + 1] = function()
		syncing = true
		MoneyInputFrame_SetCopper(input, get())
		syncing = false
	end
	self.y = self.y - 24
	return input
end

function FilterPanel:Build()
	local db = self.core.db

	self:Header("Categories")
	for i = 1, #Categories.ORDER do
		local category = Categories.ORDER[i]
		self:Checkbox(CATEGORY_LABELS[category] or Categories.Label(category),
			function() return db.categories[category] == true end,
			function(checked) db.categories[category] = checked end)
	end

	self.y = self.y - 4
	self:Header("Quality")
	for i = 1, #SHOWN_QUALITIES do
		local quality = SHOWN_QUALITIES[i]
		local check = self:Checkbox(qualityName(quality),
			function() return db.qualities[quality] ~= false end,
			function(checked) db.qualities[quality] = checked end,
			(i - 1) % 2)
		local r, g, b = ns.WoWAPI.GetQualityColor(quality)
		check.Text:SetTextColor(r, g, b)
	end

	self.y = self.y - 4
	self:Header("Price limits")
	self:Label("Minimum profit")
	self:MoneyInput("VendorSniperMinProfitInput",
		function() return db.minProfit end,
		function(copper) db.minProfit = math.max(1, copper) end)
	self:Label("Maximum buyout (0 = any)")
	self:MoneyInput("VendorSniperMaxBuyoutInput",
		function() return db.maxBuyout end,
		function(copper) db.maxBuyout = copper end)

	self:Label("Minimum ROI (%)")
	local roi = CreateFrame("EditBox", "VendorSniperMinRoiInput", self.frame, "InputBoxTemplate")
	roi:SetAutoFocus(false)
	roi:SetNumeric(true)
	roi:SetMaxLetters(5)
	roi:SetSize(52, 20)
	roi:SetPoint("TOPLEFT", 20, self.y)
	roi:SetScript("OnTextChanged", function(box, userInput)
		if userInput then
			db.minRoiBasisPoints = (tonumber(box:GetText()) or 0) * 100
			self:Changed()
		end
	end)
	roi:SetScript("OnEnterPressed", EditBox_ClearFocus)
	roi:SetScript("OnEscapePressed", EditBox_ClearFocus)
	self.syncers[#self.syncers + 1] = function()
		roi:SetText(tostring(math.floor((db.minRoiBasisPoints or 0) / 100)))
	end
	self.y = self.y - 26

	self:Header("Options")
	self:Checkbox("Batch inspect",
		function() return db.lookup.mode == Settings.LOOKUP_BATCH end,
		function(checked) self.core:SetLookupMode(checked and Settings.LOOKUP_BATCH or Settings.LOOKUP_CLICK) end,
		nil,
		"When on, Inspect looks up every candidate in one go: one search at a time, "
			.. "at most the configured number per minute. When off, each click looks up one item.")
	self:Checkbox("Sound for new deals",
		function() return db.sound.enabled end,
		function(checked) db.sound.enabled = checked end,
		nil,
		"Plays a sound once when a new listing with at least this much profit appears.")
	self:MoneyInput("VendorSniperSoundThresholdInput",
		function() return db.sound.thresholdCopper end,
		function(copper) db.sound.thresholdCopper = copper end)

	self:Sync()
end

function FilterPanel:Sync()
	for i = 1, #self.syncers do
		self.syncers[i]()
	end
end
