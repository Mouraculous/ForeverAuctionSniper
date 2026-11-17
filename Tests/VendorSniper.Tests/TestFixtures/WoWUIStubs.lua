--[[
Generic stand-ins for the Blizzard UI used by the Auction House tab.

Any frame is a "proxy": unknown methods are accepted and return another
proxy, and unknown fields (child regions such as .Text or .Arrow) are
created on first access. A few methods have real behaviour (scripts,
shown state, text, checked state, money inputs, scroll box data). This
doesn't check layout or visuals. It runs the tab code end to end, so typos,
nil calls and wiring mistakes fail the tests.
]]
local game = ...

local ui = { frames = {}, rows = {}, menus = {}, tooltipLines = {} }

local proxyMeta = {}

local function newProxy(kind, name)
	local scripts = {}
	-- `scripts` / `events` use the field names WoWGlobals' game.fire() expects.
	local p = { __kind = kind, __name = name, __scripts = scripts, scripts = scripts, events = {},
		__shown = true, __text = "" }
	return setmetatable(p, proxyMeta)
end

local methods = {}

function methods:RegisterEvent(event)
	self.events[event] = true
	if not self.__registered then
		self.__registered = true
		game.frames[#game.frames + 1] = self
	end
end
function methods:SetScript(name, fn) self.__scripts[name] = fn end
function methods:GetScript(name) return self.__scripts[name] end
function methods:HookScript(name, fn)
	local original = self.__scripts[name]
	self.__scripts[name] = function(...)
		if original then original(...) end
		fn(...)
	end
end
function methods:RunScript(name, ...)
	local fn = self.__scripts[name]
	if fn then return fn(self, ...) end
end
function methods:Show() self.__shown = true end
function methods:Hide() self.__shown = false end
function methods:SetShown(shown) self.__shown = shown and true or false end
function methods:IsShown() return self.__shown end
function methods:IsVisible() return self.__shown end
function methods:SetText(text) self.__text = text end
function methods:GetText() return self.__text end
function methods:SetChecked(checked) self.__checked = checked and true or false end
function methods:GetChecked() return self.__checked == true end
function methods:SetEnabled(enabled) self.__enabled = enabled and true or false end
function methods:Enable() self.__enabled = true end
function methods:Disable() self.__enabled = false end
function methods:IsEnabled() return self.__enabled ~= false end
function methods:GetFrameLevel() return 10 end
function methods:GetWidth() return 100 end
function methods:GetHeight() return 20 end
function methods:HasFocus() return self.__focus == true end
function methods:SetFocus() self.__focus = true end
function methods:ClearFocus() self.__focus = false end
function methods:CreateFontString(name) return ui.CreateFrame("FontString", name) end
function methods:CreateTexture(name) return ui.CreateFrame("Texture", name) end
function methods:Click(button)
	if self.__enabled == false then return end
	if self.__kind == "CheckButton" then self.__checked = not self.__checked end
	return self:RunScript("OnClick", button or "LeftButton")
end

proxyMeta.__index = function(t, key)
	local method = methods[key]
	if method then
		return method
	end
	-- Like real frames, plain data fields (lowercase, or our __ internals) are nil until set.
	if type(key) ~= "string" or not key:match("^%u") then
		return nil
	end
	-- Child region (e.g. frame.Text) or any other method (e.g. SetPoint): a proxy
	-- that is also callable, so both `frame.Text:SetText()` and `frame:SetPoint()` work.
	local child = newProxy("child", key)
	rawset(t, key, child)
	return child
end
proxyMeta.__call = function()
	return newProxy("result")
end

function ui.CreateFrame(frameType, name, parent, template)
	local frame = newProxy(frameType, name)
	frame.__parent = parent
	frame.__template = template
	if frameType == "CheckButton" then frame.__checked = false end
	if template == "WowScrollBoxList" then
		function frame:SetDataProvider(provider)
			self.__provider = provider
			ui.rows = {}
			local view = self.__view
			for i, data in ipairs(provider.rows) do
				local row = ui.CreateFrame("Button", nil, self, view.__template)
				if view.__template == "VendorSniperResultRowTemplate" then
					for k, v in pairs(VendorSniperResultRowMixin) do rawset(row, k, v) end
					-- Same <Scripts> as UI/Templates.xml.
					for _, script in ipairs({ "OnClick", "OnEnter", "OnLeave" }) do
						row.__scripts[script] = VendorSniperResultRowMixin[script]
					end
					row:OnLoad()
				end
				view.__initializer(row, data)
				ui.rows[i] = row
			end
		end
	end
	if name then
		_G[name] = frame
	end
	ui.frames[#ui.frames + 1] = frame
	return frame
end

CreateFrame = ui.CreateFrame

-- Blizzard helpers the tab uses ----------------------------------------------

function hooksecurefunc(target, methodName, hook)
	local original = target[methodName]
	target[methodName] = function(...)
		local r = original and original(...)
		hook(...)
		return r
	end
end

function PanelTemplates_TabResize() end
function PanelTemplates_SelectTab(tab) tab.__selected = true end
function PanelTemplates_DeselectTab(tab) tab.__selected = false end
function PanelTemplates_UpdateTabs(frame)
	for i, tab in ipairs(frame.Tabs) do tab.__selected = (i == frame.selectedTab) end
end

function CreateScrollBoxListLinearView()
	local view = newProxy("view")
	function view:SetElementInitializer(template, initializer)
		self.__template, self.__initializer = template, initializer
	end
	return view
end

ScrollUtil = { InitScrollBoxListWithScrollBar = function(scrollBox, _, view) scrollBox.__view = view end }
ScrollBoxConstants = { RetainScrollPosition = true }
function CreateDataProvider(rows) return { rows = rows } end

MenuUtil = {
	CreateContextMenu = function(owner, generator)
		local menu = { buttons = {}, titles = {} }
		local root = {}
		function root:CreateTitle(text) menu.titles[#menu.titles + 1] = text end
		function root:CreateButton(text, fn) menu.buttons[#menu.buttons + 1] = { text = text, fn = fn } end
		generator(owner, root)
		ui.menus[#ui.menus + 1] = menu
		return menu
	end,
}

GameTooltip = newProxy("GameTooltip", "GameTooltip")
function GameTooltip:AddLine(text) ui.tooltipLines[#ui.tooltipLines + 1] = text end
function GameTooltip:AddDoubleLine(left, right) ui.tooltipLines[#ui.tooltipLines + 1] = left .. " | " .. right end
function GameTooltip:SetOwner() ui.tooltipLines = {} end
function GameTooltip_SetTitle(tooltip, text) ui.tooltipLines[#ui.tooltipLines + 1] = text end
function GameTooltip_AddNormalLine(tooltip, text) ui.tooltipLines[#ui.tooltipLines + 1] = text end

function MoneyInputFrame_SetOnValueChangedFunc(frame, fn) frame.__onValueChanged = fn end
function MoneyInputFrame_GetCopper(frame) return frame.__copper or 0 end
function MoneyInputFrame_SetCopper(frame, copper)
	frame.__copper = copper
	if frame.__onValueChanged then frame.__onValueChanged() end
end
-- Simulates the player typing an amount.
function ui.TypeMoney(frame, copper) MoneyInputFrame_SetCopper(frame, copper) end

function EditBox_ClearFocus(box) box:ClearFocus() end
function GetMoneyString(copper) return tostring(copper) .. "c" end
function IsModifiedClick() return ui.modifiedClick == true end
function HandleModifiedItemClick(link) ui.linkedToChat = link end

GameFontHighlightSmall = newProxy("Font", "GameFontHighlightSmall")
SOUNDKIT.IG_CHARACTER_INFO_TAB = 841
C_Item.GetItemQualityColor = function() return 1, 1, 1, "ffffffff" end

local loadedAddOns = {}
C_AddOns = { IsAddOnLoaded = function(name) return loadedAddOns[name] == true end }

-- The Blizzard Auction House frame (exists once Blizzard_AuctionHouseUI has loaded).
function ui.LoadAuctionHouseUI()
	local ah = ui.CreateFrame("Frame", "AuctionHouseFrame")
	ah.Tabs = { ui.CreateFrame("Button", "AuctionHouseFrameBuyTab"), ui.CreateFrame("Button", "AuctionHouseFrameSellTab"),
		ui.CreateFrame("Button", "AuctionHouseFrameAuctionsTab") }
	ah.numTabs, ah.selectedTab = 3, 1
	ah.SearchBar = ui.CreateFrame("Frame")
	ah.SearchBar.SearchBox = ui.CreateFrame("EditBox")
	ah.displayModeChanges = 0
	function ah:SetDisplayMode(mode)
		self.displayModeChanges = self.displayModeChanges + 1
		self.displayMode = mode
	end
	loadedAddOns.Blizzard_AuctionHouseUI = true
	game.fire("ADDON_LOADED", "Blizzard_AuctionHouseUI")
	return ah
end

function ui.FindFrame(predicate)
	for i = 1, #ui.frames do
		if predicate(ui.frames[i]) then return ui.frames[i] end
	end
end

function ui.FindButton(text)
	return ui.FindFrame(function(f) return f.__kind == "Button" and f.__text == text end)
end

function ui.FindCheckbox(text)
	return ui.FindFrame(function(f) return f.__kind == "CheckButton" and rawget(f, "Text") and f.Text.__text == text end)
end

return ui
