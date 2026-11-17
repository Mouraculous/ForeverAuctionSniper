--[[
MainWindow: the "Vendor Sniper" tab inside the Auction House window.

How it integrates without disturbing the Blizzard UI:
  * The tab is our own PanelTabButtonTemplate button placed after the last
    AH tab. It isn't added to AuctionHouseFrame.Tabs and doesn't register a
    display mode, so no Blizzard table is modified.
  * Selecting the tab shows our panel on top of the AH content area.
    Blizzard's own frames stay as they are underneath, so the AH state
    (and the later Blizzard-driven purchase) is untouched.
  * A hooksecurefunc on AuctionHouseFrame:SetDisplayMode notices when the
    player picks a Blizzard tab (or the AH switches views) and hides our panel.
  * "Show in Auction House" only fills the Blizzard search box. The player
    presses Enter / Search and buys through Blizzard's own buttons.

Layout mirrors the Buy tab: a bar on top (where the search bar sits), the
filter column where the category list sits, and the results on the right.
]]
local _, ns = ...

local ResultsView = ns.ResultsView
local Settings = ns.Settings
local Money = ns.Money

local MainWindow = {}
ns.MainWindow = MainWindow

local TAB_TEXT = "Vendor Sniper"
local TOP_BAR_HEIGHT = 34

-- Formatting helpers -----------------------------------------------------------

local function formatMoney(copper)
	if not Money.IsValid(copper) then
		return "-"
	end
	if GetMoneyString then
		return GetMoneyString(copper, true)
	end
	return Money.Format(copper)
end

-- Setup ------------------------------------------------------------------------

function MainWindow:Init(core)
	self.core = core
	local cb = core.callbacks
	cb:Register("BLIZZARD_AH_LOADED", function() self:Build() end, self)
	cb:Register("RESULTS_UPDATED", function() self:RefreshResults() end, self)
	for _, event in ipairs({ "SCAN_STARTED", "SCAN_PROGRESS", "SCAN_COMPLETE", "SCAN_CANCELLED", "SCAN_FAILED",
		"LOOKUP_STATE_CHANGED", "LOOKUP_DONE", "BROWSE_RESULTS_CHANGED", "AUCTION_HOUSE_OPENED" }) do
		cb:Register(event, function() self:RefreshStatus() end, self)
	end
	cb:Register("AUCTION_HOUSE_OPENED", function() self:RefreshResults() end, self)
	cb:Register("SETTINGS_CHANGED", function() self:SyncSettings() end, self)
end

function MainWindow:IsBuilt()
	return self.panel ~= nil
end

function MainWindow:Build()
	local ah = AuctionHouseFrame
	if self.panel or not ah then
		return
	end
	self.ah = ah
	self:BuildTab(ah)
	self:BuildPanel(ah)

	hooksecurefunc(ah, "SetDisplayMode", function()
		if self.active then
			self:Deactivate()
		end
	end)
	ah:HookScript("OnHide", function()
		if self.active then
			self:Deactivate()
		end
	end)
	self:RefreshResults()
	self:RefreshStatus()
end

function MainWindow:BuildTab(ah)
	-- Our tab lives in its own holder, so the template's parentArray="Tabs"
	-- fills holder.Tabs instead of AuctionHouseFrame.Tabs.
	local holder = CreateFrame("Frame", nil, ah)
	holder:SetAllPoints(ah)
	holder.tabPadding = 20
	holder.minTabWidth = 70
	self.tabHolder = holder

	local tab = CreateFrame("Button", "VendorSniperAuctionHouseTab", holder, "PanelTabButtonTemplate")
	tab:SetText(TAB_TEXT)
	local lastTab = ah.Tabs and ah.Tabs[#ah.Tabs]
	if lastTab then
		tab:SetPoint("LEFT", lastTab, "RIGHT", -15, 0)
	else
		tab:SetPoint("TOPLEFT", ah, "BOTTOMLEFT", 20, 2)
	end
	tab:SetScript("OnShow", function(button)
		PanelTemplates_TabResize(button, holder.tabPadding, nil, holder.minTabWidth)
	end)
	tab:SetScript("OnClick", function()
		PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
		self:Activate()
	end)
	PanelTemplates_TabResize(tab, holder.tabPadding, nil, holder.minTabWidth)
	PanelTemplates_DeselectTab(tab)
	self.tab = tab
end

function MainWindow:BuildPanel(ah)
	local core = self.core
	local panel = CreateFrame("Frame", "VendorSniperPanel", ah)
	panel:SetPoint("TOPLEFT", ah, "TOPLEFT", 3, -24)
	panel:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -3, 30)
	panel:SetFrameLevel(ah:GetFrameLevel() + 100)
	panel:EnableMouse(true)
	panel:Hide()
	self.panel = panel

	local background = panel:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetColorTexture(0.06, 0.06, 0.06, 1)

	-- Top bar ----------------------------------------------------------------
	local scan = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	scan:SetSize(110, 22)
	scan:SetPoint("TOPLEFT", 4, -6)
	scan:SetText("Scan")
	scan:SetScript("OnClick", function() core:StartScan() end)
	self:SetButtonTooltip(scan, "Scan", "Evaluates the results of your last search in the Buy tab. No extra server queries.")
	self.scanButton = scan

	local inspect = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	inspect:SetSize(110, 22)
	inspect:SetPoint("LEFT", scan, "RIGHT", 6, 0)
	inspect:SetScript("OnClick", function() core:Inspect() end)
	self:SetButtonTooltip(inspect, "Inspect", function()
		if core.db.lookup.mode == Settings.LOOKUP_BATCH then
			return string.format("Looks up the individual listings of every candidate, one search at a time "
				.. "(at most %d per minute).", core.db.lookup.batchMaxPerMinute)
		end
		return "Looks up the individual listings of the best candidate (one search)."
	end)
	self.inspectButton = inspect

	local stop = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	stop:SetSize(70, 22)
	stop:SetPoint("LEFT", inspect, "RIGHT", 6, 0)
	stop:SetText("Stop")
	stop:SetScript("OnClick", function() core:Stop() end)
	self.stopButton = stop

	local bar = CreateFrame("StatusBar", nil, panel)
	bar:SetSize(240, 14)
	bar:SetPoint("TOPRIGHT", -14, -10)
	bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	bar:SetStatusBarColor(0.26, 0.42, 1)
	bar:SetMinMaxValues(0, 1)
	local barBackground = bar:CreateTexture(nil, "BACKGROUND")
	barBackground:SetAllPoints()
	barBackground:SetColorTexture(0, 0, 0, 0.6)
	self.progressBar = bar

	local status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
	status:SetPoint("LEFT", stop, "RIGHT", 12, 0)
	status:SetJustifyH("RIGHT")
	status:SetWordWrap(false)
	self.statusText = status

	-- Filter column ----------------------------------------------------------
	self.filters = ns.FilterPanel.Create(panel, core, function() core:OnSettingsChanged() end)
	self.filters.frame:SetPoint("TOPLEFT", 1, -TOP_BAR_HEIGHT)
	self.filters.frame:SetPoint("BOTTOMLEFT", 1, 0)

	-- Summary ----------------------------------------------------------------
	local summary = CreateFrame("Frame", nil, panel, "InsetFrameTemplate")
	summary:SetPoint("TOPLEFT", self.filters.frame, "TOPRIGHT", 6, 0)
	summary:SetPoint("RIGHT", panel, "RIGHT", -1, 0)
	summary:SetHeight(42)
	local line1 = summary:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	line1:SetPoint("TOPLEFT", 10, -7)
	line1:SetPoint("RIGHT", -10, 0)
	line1:SetJustifyH("LEFT")
	local line2 = summary:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	line2:SetPoint("TOPLEFT", line1, "BOTTOMLEFT", 0, -4)
	line2:SetPoint("RIGHT", -10, 0)
	line2:SetJustifyH("LEFT")
	self.summaryLine = line1
	self.summaryNote = line2

	-- Results ----------------------------------------------------------------
	self.list = ns.ResultsList.Create(panel, {
		formatMoney = formatMoney,
		qualityColor = ns.WoWAPI.GetQualityColor,
		getSortKey = function() return core.db.sortKey end,
		setSortKey = function(key)
			core.db.sortKey = key
			core:OnSettingsChanged()
		end,
		showInAuctionHouse = function(row) self:ShowInAuctionHouse(row) end,
		inspect = function(row) core:Inspect(row.record) end,
		linkToChat = function(row) self:LinkToChat(row) end,
		getAggregate = function(row)
			local result = core.lastResult
			return result and result.commodityAggregates[row.record.groupKey]
		end,
	})
	self.list.frame:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -4)
	self.list.frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -1, 0)
end

function MainWindow:SetButtonTooltip(button, title, text)
	button:SetScript("OnEnter", function(owner)
		GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
		GameTooltip_SetTitle(GameTooltip, title)
		GameTooltip_AddNormalLine(GameTooltip, type(text) == "function" and text() or text, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Tab switching ----------------------------------------------------------------

function MainWindow:Activate()
	if not self.panel then
		return
	end
	local ah = self.ah
	self.active = true
	for i = 1, #ah.Tabs do
		PanelTemplates_DeselectTab(ah.Tabs[i])
	end
	PanelTemplates_SelectTab(self.tab)
	local searchBox = ah.SearchBar and ah.SearchBar.SearchBox
	if searchBox and searchBox:HasFocus() then
		searchBox:ClearFocus()
	end
	self.filters:Sync()
	self.panel:Show()
	self:RefreshResults()
	self:RefreshStatus()
end

function MainWindow:Deactivate()
	if not self.panel then
		return
	end
	self.active = false
	self.panel:Hide()
	PanelTemplates_DeselectTab(self.tab)
	-- Re-applies Blizzard's own selected-tab state (frame.selectedTab is untouched).
	PanelTemplates_UpdateTabs(self.ah)
end

function MainWindow:IsActive()
	return self.active == true
end

-- Actions ----------------------------------------------------------------------

function MainWindow:ShowInAuctionHouse(row)
	self:Deactivate()
	local searchBar = self.ah.SearchBar
	local searchBox = searchBar and searchBar.SearchBox
	if not searchBox then
		return
	end
	searchBox:SetText(row.name or "")
	if searchBar:IsShown() then
		searchBox:SetFocus()
		searchBox:HighlightText(0, 0)
		ns.Diagnostics.Print("Press Enter to search for %s, then buy it in the normal Auction House view.", row.name or "the item")
	else
		ns.Diagnostics.Print("Search text set to %s. Open the Buy tab and press Enter.", row.name or "the item")
	end
end

function MainWindow:LinkToChat(row)
	if not row.link then
		return
	end
	if HandleModifiedItemClick then
		HandleModifiedItemClick(row.link)
	elseif ChatEdit_InsertLink then
		ChatEdit_InsertLink(row.link)
	end
end

-- Refresh ----------------------------------------------------------------------

function MainWindow:RefreshResults()
	if not self.panel then
		return
	end
	local core = self.core
	local result = core.lastResult
	local state = core:GetViewState()

	self.list:SetRows(ResultsView.BuildRows(result), ResultsView.EmptyText(state))

	local summary = ResultsView.Summary(result)
	local profit = formatMoney(summary.totalProfit)
	if summary.totalIsLowerBound then
		profit = profit .. ResultsView.LOWER_BOUND_MARK
	end
	local text = string.format("Opportunities: |cffffffff%d|r    Evaluated: |cffffffff%d|r    Potential profit: |cff1eff00%s|r",
		summary.opportunities, summary.evaluated, profit)
	if summary.vendorUnknown > 0 then
		text = text .. string.format("    No vendor info: |cffffffff%d|r", summary.vendorUnknown)
	end
	if summary.possible > 0 then
		text = text .. string.format("    To inspect: |cffffffff%d|r", summary.possible)
	end
	self.summaryLine:SetText(text)
	self.summaryNote:SetText("Profit is theoretical: vendor value minus buyout, before anything is bought. "
		.. ResultsView.LOWER_BOUND_MARK .. " = at least (browse data).")

	self:RefreshButtons()
end

function MainWindow:RefreshStatus()
	if not self.panel then
		return
	end
	local text, progress = ResultsView.StatusText(self.core:GetViewState())
	self.statusText:SetText(text)
	if progress then
		self.progressBar:SetValue(progress)
		self.progressBar:Show()
		self.statusText:ClearAllPoints()
		self.statusText:SetPoint("CENTER", self.progressBar, "CENTER")
	else
		self.progressBar:Hide()
		self.statusText:ClearAllPoints()
		self.statusText:SetPoint("RIGHT", self.progressBar, "RIGHT")
		self.statusText:SetPoint("LEFT", self.stopButton, "RIGHT", 12, 0)
	end
	self:RefreshButtons()
end

function MainWindow:RefreshButtons()
	local core = self.core
	local state = core:GetViewState()
	local lookup = state.lookup
	local lookupBusy = lookup and (lookup.inFlight ~= nil or lookup.queued > 0)

	self.scanButton:SetText(state.hasScanned and "Rescan" or "Scan")
	self.scanButton:SetEnabled(state.isOpen and not state.isScanning)

	local batch = core.db.lookup.mode == Settings.LOOKUP_BATCH
	self.inspectButton:SetText(batch and "Inspect all" or "Inspect")
	self.inspectButton:SetEnabled(state.isOpen and not state.isScanning and #core:GetInspectCandidates() > 0)

	self.stopButton:SetEnabled(state.isScanning or lookupBusy)
end

function MainWindow:SyncSettings()
	if self.filters then
		self.filters:Sync()
	end
	if self.panel then
		self:RefreshButtons()
	end
end
