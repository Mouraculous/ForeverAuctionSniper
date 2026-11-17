using Xunit;

namespace VendorSniper.Tests;

/// <summary>Pure display logic (ns.ResultsView).</summary>
public class ResultsViewTests
{
    private readonly LuaHarness lua = new();

    public ResultsViewTests()
    {
        lua.Run("""
            env = Fake.NewEnvironment(fixture('AuctionData'))
            env.scanner:SetAuctionHouseOpen(true)
            env.scanner:ScanBrowse()
            env.clock.runDeferred()
            filters = ns.Settings.ToFilters(ns.Settings.Defaults())
            browseResult = env.evaluate(filters)
            V = ns.ResultsView
            """);
    }

    [Fact]
    public void BrowseRowsAreMarkedAsLowerBoundOrExact()
    {
        lua.Run("""
            rows = V.BuildRows(browseResult)
            byName = {}
            for _, r in ipairs(rows) do byName[r.name] = r end
            """);
        Assert.Equal(2, lua.Number("return #rows"));
        Assert.Equal("1+", lua.String("return byName['Linen Cloth'].quantityText"));
        Assert.True(lua.Bool("return byName['Linen Cloth'].isLowerBound"));
        Assert.Equal("Material - Browse: lowest unit price", lua.String("return byName['Linen Cloth'].detail"));
        Assert.Equal("1", lua.String("return byName['Jambiya'].quantityText"));
        Assert.False(lua.Bool("return byName['Jambiya'].isLowerBound"));
        Assert.Equal("Equipment - Browse: cheapest auction", lua.String("return byName['Jambiya'].detail"));
        Assert.True(lua.Bool("return byName['Jambiya'].canInspect"));
        Assert.Equal("54.00%", lua.String("return byName['Jambiya'].roiText"));
    }

    [Fact]
    public void ListingRowsDescribeAuctionAndCommodityTiers()
    {
        lua.Run("""
            env.scanner:OnItemSearchResults(Fake.ItemKey(2207))
            env.scanner:OnCommoditySearchResults(2589)
            result = env.evaluate(filters)
            rows = V.BuildRows(result)
            details = {}
            for _, r in ipairs(rows) do details[#details + 1] = r.detail end
            table.sort(details)
            linenRow = nil
            for _, r in ipairs(rows) do if r.record.kind == 'commodity' then linenRow = r end end
            tooltip = V.TooltipLines(linenRow, result.commodityAggregates['C:2589'])
            tooltipText = {}
            for _, l in ipairs(tooltip) do tooltipText[#tooltipText + 1] = l.left end
            """);
        Assert.Equal(
            "Equipment - Auction #101|Equipment - Auction #102|Material - Commodity price tier, first 160 units profitable|Material - Commodity price tier, first 160 units profitable",
            lua.String("return table.concat(details, '|')"));
        Assert.False(lua.Bool("return linenRow.canInspect"));
        Assert.Contains("Buying the first 160 units costs", lua.String("return table.concat(tooltipText, '|')"));
        Assert.Contains("Profit is theoretical", lua.String("return table.concat(tooltipText, '|')"));
    }

    [Fact]
    public void SummaryAndEmptyTexts()
    {
        lua.Run("summary = V.Summary(browseResult)");
        Assert.Equal(2, lua.Number("return summary.opportunities"));
        Assert.Equal(30, lua.Number("return summary.totalProfit")); // 3 (linen, per unit) + 27
        Assert.True(lua.Bool("return summary.totalIsLowerBound"));
        Assert.Equal(1, lua.Number("return summary.possible"));

        Assert.Equal("The Auction House is closed.", lua.String("return V.EmptyText({ isOpen = false })"));
        Assert.Contains("press Scan", lua.String("return V.EmptyText({ isOpen = true, hasScanned = false })"));
        lua.Run("""
            local f = ns.Settings.ToFilters(ns.Settings.Defaults()); f.minProfit = 1000000
            filtered = env.evaluate(f)
            """);
        Assert.Contains("filtered out", lua.String("return V.EmptyText({ isOpen = true, hasScanned = true, result = filtered })"));
    }

    [Fact]
    public void StatusTextReportsProgressAndWaitingStates()
    {
        lua.Run("t, p = V.StatusText({ isScanning = true, scanDone = 40, scanTotal = 80 })");
        Assert.Equal("Scanning 40 / 80", lua.String("return t"));
        Assert.Equal(0.5, lua.Number("return p"));
        lua.Run("t, p = V.StatusText({ lookup = { inFlight = 'x', queued = 2, completed = 1, total = 4, state = 'waitingRateLimit' } })");
        Assert.Equal("Inspecting 1 / 4 (waiting for query budget)", lua.String("return t"));
        Assert.Equal(0.25, lua.Number("return p"));
        lua.Run("t, p = V.StatusText({ lookup = { queued = 0, completed = 0, total = 0 }, browseChanged = true })");
        Assert.Contains("Press Scan", lua.String("return t"));
        Assert.True(lua.IsNil("return p"));
    }
}

/// <summary>
/// The Auction House tab, run end to end against stub frames
/// (TestFixtures/WoWUIStubs.lua). This checks wiring and behaviour, not visuals.
/// </summary>
public class AuctionHouseTabTests
{
    private readonly LuaHarness lua = new(withGameStubs: true, withUiStubs: true);

    public AuctionHouseTabTests()
    {
        lua.Run("""
            game.fire('ADDON_LOADED', 'VendorSniper')
            ah = ui.LoadAuctionHouseUI()
            game.fire('AUCTION_HOUSE_SHOW')
            tab = VendorSniperAuctionHouseTab
            panel = VendorSniperPanel
            """);
    }

    private void Slash(string input) => lua.Run($"SlashCmdList.VENDORSNIPER('{input}')");

    [Fact]
    public void TabIsCreatedAfterTheBlizzardAuctionHouseLoads()
    {
        Assert.False(lua.IsNil("return tab"));
        Assert.Equal("Vendor Sniper", lua.String("return tab:GetText()"));
        Assert.False(lua.Bool("return panel:IsShown()"));
        // The Blizzard tab list is untouched.
        Assert.Equal(3, lua.Number("return #ah.Tabs"));
    }

    [Fact]
    public void ClickingTheTabShowsThePanelAndBlizzardTabHidesIt()
    {
        lua.Run("tab:Click()");
        Assert.True(lua.Bool("return panel:IsShown()"));
        Assert.True(lua.Bool("return tab.__selected"));
        Assert.False(lua.Bool("return ah.Tabs[1].__selected"));
        Assert.Equal(0, lua.Number("return ah.displayModeChanges"));

        lua.Run("ah:SetDisplayMode('Sell')"); // the player clicked a Blizzard tab
        Assert.False(lua.Bool("return panel:IsShown()"));
        Assert.False(lua.Bool("return tab.__selected"));
        Assert.True(lua.Bool("return ah.Tabs[1].__selected")); // Blizzard's own selection restored
    }

    [Fact]
    public void ScanButtonFillsTheResultsTable()
    {
        lua.Run("""
            tab:Click()
            scanButton = ui.FindButton('Scan')
            scanButton:Click()
            game.runTimers(0)
            """);
        Assert.Equal(2, lua.Number("return #ui.rows"));
        Assert.Equal("Jambiya", lua.String("return ui.rows[1].Name:GetText()"));       // default sort: profit
        Assert.Equal("77c", lua.String("return ui.rows[1].cells.vendorTotal:GetText()"));
        Assert.Contains("27c", lua.String("return ui.rows[1].cells.profit:GetText()"));
        Assert.DoesNotContain("*", lua.String("return ui.rows[1].cells.profit:GetText()")); // exact
        Assert.Contains("*", lua.String("return ui.rows[2].cells.profit:GetText()"));       // Linen: lower bound
        lua.Run("summaryText = ui.FindFrame(function(f) return type(f.__text) == 'string' and f.__text:find('Opportunities', 1, true) end).__text");
        Assert.Contains("Opportunities: |cffffffff2|r", lua.String("return summaryText"));
        Assert.Equal("Rescan", lua.String("return scanButton:GetText()"));
        Assert.True(lua.Bool("return ui.FindButton('Inspect'):IsEnabled()"));
    }

    [Fact]
    public void HeaderClickChangesSortOrder()
    {
        lua.Run("""
            tab:Click()
            ui.FindButton('Scan'):Click()
            game.runTimers(0)
            header = ui.FindFrame(function(f) return f.__template == 'VendorSniperColumnHeaderTemplate' and f.__text == 'AH price' end)
            header:Click()
            game.runTimers(0)
            """);
        Assert.Equal("buyout", lua.String("return VendorSniperDB.sortKey"));
        Assert.Equal("Linen Cloth", lua.String("return ui.rows[1].Name:GetText()")); // 10c before 50c
    }

    [Fact]
    public void RowInteractionsTooltipMenuInspectAndShowInAuctionHouse()
    {
        lua.Run("""
            tab:Click()
            ui.FindButton('Scan'):Click()
            game.runTimers(0)
            row = ui.rows[1]
            row:RunScript('OnEnter')
            tooltip = table.concat(ui.tooltipLines, '|')
            row:RunScript('OnClick', 'RightButton')
            menu = ui.menus[#ui.menus]
            labels = {}
            for _, b in ipairs(menu.buttons) do labels[#labels + 1] = b.text end
            """);
        Assert.Contains("Vendor Sniper", lua.String("return tooltip"));
        Assert.Contains("Potential profit", lua.String("return tooltip"));
        Assert.Equal("Show in Auction House|Inspect listings|Link in chat", lua.String("return table.concat(labels, '|')"));

        lua.Run("menu.buttons[2].fn()"); // Inspect listings
        Assert.Equal(1, lua.Number("return #game.searches"));
        Assert.Equal(2207, lua.Number("return game.searches[1].itemKey.itemID"));

        lua.Run("row:RunScript('OnClick', 'LeftButton')"); // Show in Auction House
        Assert.False(lua.Bool("return panel:IsShown()"));
        Assert.Equal("Jambiya", lua.String("return ah.SearchBar.SearchBox:GetText()"));
        Assert.True(lua.Bool("return ah.SearchBar.SearchBox:HasFocus()"));
        Assert.Equal(0, lua.Number("return ah.displayModeChanges")); // no Blizzard view switch from addon code

        lua.Run("ui.modifiedClick = true; row:RunScript('OnClick', 'LeftButton')");
        Assert.Equal("[Jambiya]", lua.String("return ui.linkedToChat"));
    }

    [Fact]
    public void FilterControlsUpdateSettingsAndResults()
    {
        lua.Run("""
            tab:Click()
            ui.FindButton('Scan'):Click()
            game.runTimers(0)
            ui.TypeMoney(VendorSniperMinProfitInput, 20)
            game.runTimers(0)
            afterMinProfit = #ui.rows
            equipment = ui.FindCheckbox('Equipment & weapons')
            equipmentChecked = equipment:GetChecked()
            equipment:Click()
            game.runTimers(0)
            afterEquipmentOff = #ui.rows
            """);
        Assert.Equal(20, lua.Number("return VendorSniperDB.minProfit"));
        Assert.Equal(1, lua.Number("return afterMinProfit"));
        Assert.True(lua.Bool("return equipmentChecked"));
        Assert.False(lua.Bool("return VendorSniperDB.categories.equipment"));
        Assert.Equal(0, lua.Number("return afterEquipmentOff"));
    }

    [Fact]
    public void BatchCheckboxSwitchesLookupModeAndInspectAll()
    {
        lua.Run("""
            tab:Click()
            ui.FindButton('Scan'):Click()
            game.runTimers(0)
            ui.FindCheckbox('Batch inspect'):Click()
            inspectAll = ui.FindButton('Inspect all')
            inspectAll:Click()
            """);
        Assert.Equal("batch", lua.String("return VendorSniperDB.lookup.mode"));
        Assert.False(lua.IsNil("return inspectAll"));
        Assert.Equal(3, lua.Number("return VendorSniper.scheduler:GetLookupStatus().total"));
        Assert.Equal(1, lua.Number("return #game.searches"));
        Assert.True(lua.Bool("return ui.FindButton('Stop'):IsEnabled()"));
        lua.Run("ui.FindButton('Stop'):Click()");
        Assert.Equal("idle", lua.String("return VendorSniper.scheduler:GetLookupStatus().state"));
    }

    [Fact]
    public void SlashCommandChangesAreReflectedInTheControls()
    {
        Slash("minprofit 1g");
        Slash("lookup batch");
        Assert.Equal(10000, lua.Number("return VendorSniperMinProfitInput.__copper"));
        Assert.True(lua.Bool("return ui.FindCheckbox('Batch inspect'):GetChecked()"));
        Slash("show");
        Assert.True(lua.Bool("return panel:IsShown()"));
    }

    [Fact]
    public void ScanFromThePanelDoesNotSpamChat()
    {
        lua.Run("""
            tab:Click()
            ui.FindButton('Scan'):Click()
            game.runTimers(0)
            """);
        Assert.DoesNotContain("opportunities shown", lua.String("return game.chatText()") ?? "");
    }
}
