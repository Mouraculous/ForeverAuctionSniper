--[[
ResultsList: the scrollable, sortable results table.

Built from Blizzard's own pieces so it looks like the Auction House lists:
InsetFrameTemplate with the AH list background atlas, column-tab headers
with the AH sort arrow, a WowScrollBoxList with MinimalScrollBar, and
AH-style row stripes (see UI/Templates.xml).

All texts come from ns.ResultsView. This file only handles frames.
`actions` (supplied by MainWindow) implements what clicks do.
]]
local _, ns = ...

local ResultsView = ns.ResultsView

local ROW_HEIGHT = 32
local HEADER_HEIGHT = 19
local CELL_PADDING = 6
local PROFIT_COLOR = "ff1eff00"
local LOWER_BOUND_COLOR = "ff9ce59c"

-- Row --------------------------------------------------------------------------

VendorSniperResultRowMixin = {}

function VendorSniperResultRowMixin:OnLoad()
	self.cells = {}
	local previous
	for i = #ResultsView.COLUMNS, 2, -1 do
		local column = ResultsView.COLUMNS[i]
		local cell = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		cell:SetWidth(column.width - CELL_PADDING)
		cell:SetJustifyH(column.align or "RIGHT")
		cell:SetWordWrap(false)
		if previous then
			cell:SetPoint("RIGHT", previous, "LEFT", -CELL_PADDING, 0)
		else
			cell:SetPoint("RIGHT", self, "RIGHT", -CELL_PADDING, 0)
		end
		self.cells[column.key] = cell
		previous = cell
	end
	self.Name:SetPoint("RIGHT", previous, "LEFT", -CELL_PADDING, 0)
	self.Detail:SetPoint("RIGHT", previous, "LEFT", -CELL_PADDING, 0)
end

function VendorSniperResultRowMixin:Init(row, list)
	self.row = row
	self.list = list

	self.Icon:SetTexture(row.icon or 134400) -- question mark icon until item data loads
	self.Name:SetText(row.name)
	self.Name:SetTextColor(list.actions.qualityColor(row.quality))
	self.Detail:SetText(row.detail)

	local money = list.actions.formatMoney
	local cells = self.cells
	cells.quantity:SetText(row.quantityText)
	cells.buyout:SetText(money(row.buyout))
	cells.unitPrice:SetText(money(row.unitPrice))
	cells.vendorUnit:SetText(money(row.vendorUnit))
	cells.vendorTotal:SetText(money(row.vendorTotal))
	if row.isLowerBound then
		cells.profit:SetText("|c" .. LOWER_BOUND_COLOR .. money(row.profit) .. ResultsView.LOWER_BOUND_MARK .. "|r")
	else
		cells.profit:SetText("|c" .. PROFIT_COLOR .. money(row.profit) .. "|r")
	end
	cells.roi:SetText("|c" .. PROFIT_COLOR .. row.roiText .. "|r")
end

function VendorSniperResultRowMixin:OnClick(button)
	local row, actions = self.row, self.list.actions
	if not row then
		return
	end
	if button == "RightButton" then
		self.list:OpenContextMenu(self, row)
	elseif IsModifiedClick("CHATLINK") then
		actions.linkToChat(row)
	else
		actions.showInAuctionHouse(row)
	end
end

function VendorSniperResultRowMixin:OnEnter()
	self.HighlightTexture:Show()
	if self.row then
		self.list:ShowTooltip(self, self.row)
	end
end

function VendorSniperResultRowMixin:OnLeave()
	self.HighlightTexture:Hide()
	GameTooltip:Hide()
end

-- List -------------------------------------------------------------------------

local ResultsList = {}
ResultsList.__index = ResultsList
ns.ResultsList = ResultsList

--[[
actions = {
  formatMoney(copper) -> string, qualityColor(quality) -> r, g, b,
  getSortKey() -> key, setSortKey(key),
  showInAuctionHouse(row), inspect(row), linkToChat(row),
  getAggregate(row) -> commodity aggregate or nil,
}
]]
function ResultsList.Create(parent, actions)
	local self = setmetatable({ actions = actions, headers = {} }, ResultsList)

	local frame = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
	self.frame = frame

	local background = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
	background:SetAtlas("auctionhouse-background-index", true)
	background:SetPoint("TOPLEFT", 3, -3 - HEADER_HEIGHT)
	background:SetPoint("BOTTOMRIGHT", -3, 3)

	local scrollBar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
	scrollBar:SetPoint("TOPRIGHT", -6, -(HEADER_HEIGHT + 6))
	scrollBar:SetPoint("BOTTOMRIGHT", -6, 6)

	local scrollBox = CreateFrame("Frame", nil, frame, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT", 3, -(HEADER_HEIGHT + 3))
	scrollBox:SetPoint("BOTTOMRIGHT", scrollBar, "BOTTOMLEFT", -4, -3)
	self.scrollBox = scrollBox

	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_HEIGHT)
	view:SetElementInitializer("VendorSniperResultRowTemplate", function(rowFrame, row)
		rowFrame:Init(row, self)
	end)
	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

	self:CreateHeaders(scrollBox)

	local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	empty:SetPoint("TOPLEFT", scrollBox, "TOPLEFT", 20, -40)
	empty:SetPoint("TOPRIGHT", scrollBox, "TOPRIGHT", -20, -40)
	empty:SetJustifyH("CENTER")
	self.emptyText = empty

	return self
end

function ResultsList:CreateHeaders(scrollBox)
	local frame = self.frame
	local previous
	for i = #ResultsView.COLUMNS, 1, -1 do
		local column = ResultsView.COLUMNS[i]
		local header = CreateFrame("Button", nil, frame, "VendorSniperColumnHeaderTemplate")
		header:SetText(column.title)
		header:SetHeight(HEADER_HEIGHT)
		if previous then
			header:SetPoint("BOTTOMRIGHT", previous, "BOTTOMLEFT", 2, 0)
		else
			header:SetPoint("BOTTOMRIGHT", scrollBox, "TOPRIGHT", 0, 1)
		end
		if column.width > 0 then
			header:SetWidth(column.width + 2)
		else
			header:SetPoint("BOTTOMLEFT", scrollBox, "TOPLEFT", 0, 1)
		end
		if column.sortKey then
			header:SetScript("OnClick", function()
				self.actions.setSortKey(column.sortKey)
			end)
		else
			header:Disable()
			header:SetDisabledFontObject(GameFontHighlightSmall)
		end
		header.sortKey = column.sortKey
		self.headers[#self.headers + 1] = header
		previous = header
	end
end

function ResultsList:UpdateSortArrows()
	local current = self.actions.getSortKey()
	for i = 1, #self.headers do
		local header = self.headers[i]
		header.Arrow:SetShown(header.sortKey ~= nil and header.sortKey == current)
	end
end

function ResultsList:SetRows(rows, emptyText)
	local retain = ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition
	self.scrollBox:SetDataProvider(CreateDataProvider(rows), retain)
	self.emptyText:SetText(emptyText or "")
	self.emptyText:SetShown(#rows == 0)
	self:UpdateSortArrows()
end

function ResultsList:ShowTooltip(owner, row)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	local link = row.link
	if type(link) == "string" and string.find(link, "|H", 1, true) then
		GameTooltip:SetHyperlink(link)
	elseif row.itemID then
		GameTooltip:SetItemByID(row.itemID)
	end
	GameTooltip:AddLine(" ")

	local formatMoney = self.actions.formatMoney
	local lines = ResultsView.TooltipLines(row, self.actions.getAggregate(row))
	for i = 1, #lines do
		local line = lines[i]
		local r, g, b = 1, 0.82, 0 -- NORMAL_FONT_COLOR
		if line.color == "highlight" then
			r, g, b = 1, 1, 1
		elseif line.color == "green" then
			r, g, b = 0.12, 1, 0
		elseif line.color == "grey" then
			r, g, b = 0.6, 0.6, 0.6
		end
		if line.money then
			GameTooltip:AddDoubleLine(line.left, formatMoney(line.money), r, g, b, 1, 1, 1)
		else
			GameTooltip:AddLine(line.left, r, g, b, true)
		end
	end
	GameTooltip:Show()
end

function ResultsList:OpenContextMenu(owner, row)
	local actions = self.actions
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle(row.name)
		root:CreateButton("Show in Auction House", function() actions.showInAuctionHouse(row) end)
		if row.canInspect then
			root:CreateButton("Inspect listings", function() actions.inspect(row) end)
		end
		if row.link then
			root:CreateButton("Link in chat", function() actions.linkToChat(row) end)
		end
	end)
end
