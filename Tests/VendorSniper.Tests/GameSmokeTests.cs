using Xunit;

namespace VendorSniper.Tests;

/// <summary>
/// End-to-end run of the whole addon (Core.lua included) against stubbed WoW
/// globals: loading, SavedVariables, events and slash commands. This is not
/// a substitute for the in-game checks in docs/COMPATIBILITY.md section 9.
/// </summary>
public class GameSmokeTests
{
    private readonly LuaHarness lua = new(withGameStubs: true);

    private void Slash(string input) => lua.Run($"SlashCmdList.VENDORSNIPER({Quote(input)})");

    private static string Quote(string s) => "'" + s.Replace("'", "\\'") + "'";

    private string Chat() => lua.String("return game.chatText()") ?? "";

    private void Open()
    {
        lua.Run("game.fire('ADDON_LOADED', 'VendorSniper')");
        lua.Run("game.fire('AUCTION_HOUSE_SHOW')");
    }

    [Fact]
    public void AddonLoadCreatesSavedVariablesWithDefaults()
    {
        lua.Run("game.fire('ADDON_LOADED', 'SomethingElse')");
        Assert.True(lua.IsNil("return VendorSniperDB"));
        lua.Run("game.fire('ADDON_LOADED', 'VendorSniper')");
        Assert.Equal("click", lua.String("return VendorSniperDB.lookup.mode"));
        Assert.True(lua.Bool("return VendorSniper.db == VendorSniperDB"));
    }

    [Fact]
    public void SavedSettingsSurviveReload()
    {
        lua.Run("VendorSniperDB = { lookup = { mode = 'batch', batchMaxPerMinute = 12 }, minProfit = 500 }");
        lua.Run("game.fire('ADDON_LOADED', 'VendorSniper')");
        Assert.Equal("batch", lua.String("return VendorSniper.db.lookup.mode"));
        Assert.Equal(12, lua.Number("return VendorSniper.scheduler.limiter.max"));
        Assert.Equal(500, lua.Number("return VendorSniper.db.minProfit"));
    }

    [Fact]
    public void EventsBeforeInitialisationAreIgnored()
    {
        lua.Run("game.fire('AUCTION_HOUSE_SHOW')");
        Assert.True(lua.IsNil("return VendorSniper.db"));
    }

    [Fact]
    public void ScanWhileClosedExplainsTheProblem()
    {
        lua.Run("game.fire('ADDON_LOADED', 'VendorSniper')");
        Slash("scan");
        Assert.Contains("isn't open", Chat());
    }

    [Fact]
    public void ScanPrintsSummaryAndResults()
    {
        Open();
        Slash("scan");
        lua.Run("game.runTimers(0)");
        var chat = Chat();
        Assert.Contains("Scanned 6 browse results", chat);
        Assert.Contains("2 opportunities shown", chat);
        Assert.Contains("[Jambiya]", chat);
        Assert.Contains("theoretical", chat);
        Assert.Equal(2, lua.Number("return #VendorSniper.lastResult.opportunities"));
    }

    [Fact]
    public void InspectInClickModeSendsExactlyOneSearch()
    {
        Open();
        Slash("scan");
        lua.Run("game.runTimers(0)");
        Slash("inspect");
        Assert.Equal(1, lua.Number("return #game.searches"));
        // Best candidate by lower-bound profit is the Jambiya (27c) over Linen (3c).
        Assert.Equal(2207, lua.Number("return game.searches[1].itemKey.itemID"));
        Assert.Equal(0, lua.Number("return game.searches[1].sorts[1].sortOrder"));

        lua.Run("game.fire('ITEM_SEARCH_RESULTS_UPDATED', game.searches[1].itemKey)");
        lua.Run("game.runTimers(0)");
        Slash("inspect");
        Assert.Equal(2, lua.Number("return #game.searches"));
        Assert.Equal(2589, lua.Number("return game.searches[2].itemKey.itemID"));
    }

    [Fact]
    public void InspectInBatchModeQueuesAllCandidatesOneAtATime()
    {
        Open();
        Slash("lookup batch 20");
        Assert.Equal("batch", lua.String("return VendorSniperDB.lookup.mode"));
        Assert.Equal(20, lua.Number("return VendorSniper.scheduler.limiter.max"));
        Slash("scan");
        lua.Run("game.runTimers(0)");
        Slash("inspect");
        // Candidates: Jambiya, Linen (profitable browse rows) and Test Scroll (possible).
        Assert.Equal(1, lua.Number("return #game.searches"));
        Assert.Equal(3, lua.Number("return VendorSniper.scheduler:GetLookupStatus().total"));
        lua.Run("game.fire('ITEM_SEARCH_RESULTS_UPDATED', game.searches[1].itemKey)");
        Assert.Equal(2, lua.Number("return #game.searches"));
        lua.Run("game.fire('COMMODITY_SEARCH_RESULTS_UPDATED', 2589)");
        Assert.Equal(3, lua.Number("return #game.searches"));
        lua.Run("game.fire('ITEM_SEARCH_RESULTS_UPDATED', game.searches[3].itemKey)");
        lua.Run("game.runTimers(0)");
        Assert.Contains("Inspected 3 items", Chat());
        // Every row is now backed by listings; totals are exact.
        Assert.False(lua.Bool("return VendorSniper.lastResult.stats.totalProfitIsLowerBound"));
        Assert.Equal(27 + 17 + 280 + 500, lua.Number("return VendorSniper.lastResult.stats.totalProfit"));
    }

    [Fact]
    public void ClosingTheAuctionHouseStopsQueuedLookups()
    {
        Open();
        Slash("lookup batch");
        Slash("scan");
        lua.Run("game.runTimers(0)");
        Slash("inspect");
        lua.Run("game.fire('AUCTION_HOUSE_CLOSED')");
        lua.Run("game.fire('ITEM_SEARCH_RESULTS_UPDATED', game.searches[1].itemKey)");
        Assert.Equal(1, lua.Number("return #game.searches"));
        Assert.Equal("idle", lua.String("return VendorSniper.scheduler:GetLookupStatus().state"));
        Assert.True(lua.Bool("return VendorSniper.store.isStale"));
    }

    [Fact]
    public void FilterAndSortCommandsUpdateSettings()
    {
        Open();
        Slash("minprofit 1g20s");
        Slash("minroi 12.5");
        Slash("maxbuyout 5g");
        Slash("sort roi");
        Slash("sound on 2g");
        Assert.Equal(12000, lua.Number("return VendorSniperDB.minProfit"));
        Assert.Equal(1250, lua.Number("return VendorSniperDB.minRoiBasisPoints"));
        Assert.Equal(50000, lua.Number("return VendorSniperDB.maxBuyout"));
        Assert.Equal("roi", lua.String("return VendorSniperDB.sortKey"));
        Assert.True(lua.Bool("return VendorSniperDB.sound.enabled"));
        Assert.Equal(20000, lua.Number("return VendorSniperDB.sound.thresholdCopper"));
    }

    [Fact]
    public void SoundPlaysOnceForNewOpportunityAboveThreshold()
    {
        Open();
        Slash("sound on 20c");
        Slash("scan");
        lua.Run("game.runTimers(0)");
        Slash("results");
        Assert.Equal(1, lua.Number("return #game.sounds"));
    }

    [Fact]
    public void ProbeStatusAndHelpRunWithoutErrors()
    {
        Open();
        Slash("scan");
        lua.Run("game.runTimers(0)");
        Slash("probe");
        Slash("status");
        Slash("");
        Slash("nonsense");
        var chat = Chat();
        Assert.Contains("interface 16001", chat);
        Assert.Contains("Missing APIs: GetItemInfo", chat); // stubs mimic beta reports: no global GetItemInfo
        Assert.Contains("Browse results held: 6", chat);
        Assert.Contains("Lookups (click mode)", chat);
        Assert.Contains("Commands (/vsniper", chat);
    }

    [Fact]
    public void LateItemDataIsPickedUpAutomatically()
    {
        lua.Run("""
            saved = data.items[2207]
            data.items[2207] = nil
            data.keyInfo[2207] = nil
            """);
        Open();
        Slash("scan");
        lua.Run("game.runTimers(0)");
        Assert.Equal(1, lua.Number("return #VendorSniper.lastResult.opportunities"));
        Assert.Equal(1, lua.Number("return VendorSniper.lastResult.stats.vendorUnknownItems"));
        Assert.Equal(2207, lua.Number("return game.loadRequests[1]"));

        lua.Run("data.items[2207] = saved");
        lua.Run("game.fire('ITEM_DATA_LOAD_RESULT', 2207, true)");
        lua.Run("game.runTimers(0)");
        Assert.Equal(2, lua.Number("return #VendorSniper.lastResult.opportunities"));
        Assert.Equal(0, lua.Number("return VendorSniper.lastResult.stats.vendorUnknownItems"));
    }
}
