using Xunit;

namespace VendorSniper.Tests;

public class VendorPriceServiceTests
{
    private readonly LuaHarness lua = new();

    public VendorPriceServiceTests()
    {
        lua.Run("""
            data = fixture('AuctionData')
            api = Fake.NewAPI(data)
            svc = ns.VendorPriceService.New(api, ns.ItemCache.New())
            """);
    }

    [Fact]
    public void CachedPriceDoesNotCallTheApiAgain()
    {
        lua.Run("""
            p1, s1 = svc:GetVendorPrice(2589)
            callsAfterFirst = api.calls.getItemInfo
            p2, s2 = svc:GetVendorPrice(2589)
            """);
        Assert.Equal(13, lua.Number("return p1"));
        Assert.Equal("ok", lua.String("return s1"));
        Assert.Equal(13, lua.Number("return p2"));
        Assert.True(lua.Bool("return api.calls.getItemInfo == callsAfterFirst"));
    }

    [Fact]
    public void UncachedItemIsRequestedOnceAndResolvedByLoadEvent()
    {
        lua.Run("""
            data.uncached[2207] = true
            p1, s1 = svc:GetVendorPrice(2207)
            p2, s2 = svc:GetVendorPrice(2207)
            data.uncached[2207] = nil
            handled = svc:OnItemDataLoaded(2207, true)
            p3, s3 = svc:GetVendorPrice(2207)
            unrelated = svc:OnItemDataLoaded(9999, true)
            """);
        Assert.True(lua.IsNil("return p1"));
        Assert.Equal("pending", lua.String("return s1"));
        Assert.Equal("pending", lua.String("return s2"));
        Assert.Equal(1, lua.Number("return #api.calls.requestLoad"));
        Assert.True(lua.Bool("return handled"));
        Assert.Equal(77, lua.Number("return p3"));
        Assert.False(lua.Bool("return unrelated"));
    }

    [Fact]
    public void FailedLoadMarksItemUnavailableWithoutRetrying()
    {
        lua.Run("""
            data.uncached[2207] = true
            svc:GetVendorPrice(2207)
            svc:OnItemDataLoaded(2207, false)
            p, s = svc:GetVendorPrice(2207)
            """);
        Assert.Equal("unavailable", lua.String("return s"));
        Assert.Equal(1, lua.Number("return #api.calls.requestLoad"));
    }

    [Fact]
    public void ZeroSellPriceIsAValidAnswer()
    {
        lua.Run("p, s = svc:GetVendorPrice(7000)");
        Assert.Equal(0, lua.Number("return p"));
        Assert.Equal("ok", lua.String("return s"));
    }

    [Fact]
    public void ItemLinkVariantPriceIsUsedWhenAvailable()
    {
        lua.Run("""
            data.items['[Jambiya of the Bear]'] = { name = 'Jambiya of the Bear', sellPrice = 90, maxStack = 1, classID = 2 }
            variant = svc:GetVendorPrice(2207, '[Jambiya of the Bear]')
            unknownVariant = svc:GetVendorPrice(2207, '[Jambiya of Nothing]')
            """);
        Assert.Equal(90, lua.Number("return variant"));
        Assert.Equal(77, lua.Number("return unknownVariant"));
    }

    [Fact]
    public void InvalidSellPriceIsUnavailable()
    {
        lua.Run("""
            data.items[5555] = { name = 'Broken', sellPrice = -3 }
            p, s = svc:GetVendorPrice(5555)
            p2, s2 = svc:GetVendorPrice('not an id')
            """);
        Assert.Equal("unavailable", lua.String("return s"));
        Assert.Equal("unavailable", lua.String("return s2"));
    }
}

public class ScannerSchedulerTests
{
    private readonly LuaHarness lua = new();

    public ScannerSchedulerTests()
    {
        lua.Run("""
            clock = Fake.NewClock()
            sent = {}
            throttleReady = true
            events = {}
            cb = ns.Callbacks.New(function(e, err) error(err) end)
            cb:Register('LOOKUP_DONE', function(target, result) events[#events + 1] = target.id .. ':' .. result end)
            sched = ns.ScannerScheduler.New({
                now = clock.now, after = clock.after, defer = clock.defer,
                isThrottleReady = function() return throttleReady end,
                sendSearch = function(target) sent[#sent + 1] = target.id; return true end,
                maxPerMinute = 3, responseTimeout = 10, callbacks = cb,
            })
            function target(id) return { id = id, matchKeys = { 'G:' .. id } } end
            """);
    }

    [Fact]
    public void ChunkedJobProcessesAllItemsAcrossFrames()
    {
        lua.Run("""
            items = {}
            for i = 1, 95 do items[i] = i end
            sum, progress, doneFlag = 0, {}, nil
            ok = sched:StartJob(items, 40, function(item) sum = sum + item end,
                function(done, total) progress[#progress + 1] = done end,
                function(cancelled, failures) doneFlag = { cancelled = cancelled, failures = failures } end)
            busy, reason = sched:StartJob({ 1 }, 1, function() end)
            firstFrameSum = sum
            frames = clock.runDeferred()
            """);
        Assert.True(lua.Bool("return ok"));
        Assert.False(lua.Bool("return busy"));
        Assert.Equal("busy", lua.String("return reason"));
        Assert.Equal(820, lua.Number("return firstFrameSum")); // 1..40 in the first frame
        Assert.Equal(2, lua.Number("return frames"));
        Assert.Equal(4560, lua.Number("return sum"));
        Assert.Equal("40,80,95", lua.String("return table.concat(progress, ',')"));
        Assert.False(lua.Bool("return doneFlag.cancelled"));
        Assert.False(lua.Bool("return sched:IsJobRunning()"));
    }

    [Fact]
    public void OneMalformedItemDoesNotAbortTheJob()
    {
        lua.Run("""
            count = 0
            sched:StartJob({ 1, 'bad', 3 }, 10, function(item) count = count + item end, nil,
                function(cancelled, failures) result = failures end)
            clock.runDeferred()
            """);
        Assert.Equal(4, lua.Number("return count"));
        Assert.Equal(1, lua.Number("return result"));
    }

    [Fact]
    public void JobCanBeCancelled()
    {
        lua.Run("""
            items = {}
            for i = 1, 100 do items[i] = i end
            processed = 0
            sched:StartJob(items, 10, function() processed = processed + 1 end, nil,
                function(cancelled) wasCancelled = cancelled end)
            sched:CancelJob()
            clock.runDeferred()
            """);
        Assert.Equal(10, lua.Number("return processed"));
        Assert.True(lua.Bool("return wasCancelled"));
    }

    [Fact]
    public void LookupsAreSentOneAtATimeAfterEachResponse()
    {
        lua.Run("""
            added = sched:EnqueueLookups({ target('a'), target('b'), target('a') })
            afterEnqueue = #sent
            sched:OnSearchResults('G:unrelated')
            afterUnrelated = #sent
            sched:OnSearchResults('G:a')
            afterA = #sent
            """);
        Assert.Equal(2, lua.Number("return added"));
        Assert.Equal(1, lua.Number("return afterEnqueue"));
        Assert.Equal(1, lua.Number("return afterUnrelated"));
        Assert.Equal(2, lua.Number("return afterA"));
        Assert.Equal("a:ok", lua.String("return events[1]"));
    }

    [Fact]
    public void RollingMinuteBudgetIsEnforced()
    {
        lua.Run("""
            sched:EnqueueLookups({ target('a'), target('b'), target('c'), target('d') })
            for _, id in ipairs({ 'a', 'b', 'c' }) do sched:OnSearchResults('G:' .. id) end
            stateAt3 = sched:GetLookupStatus().state
            sentAt3 = #sent
            clock.advance(59)
            sentAt59 = #sent
            clock.advance(1.1)
            sentAt60 = #sent
            """);
        Assert.Equal(3, lua.Number("return sentAt3"));
        Assert.Equal("waitingRateLimit", lua.String("return stateAt3"));
        Assert.Equal(3, lua.Number("return sentAt59"));
        Assert.Equal(4, lua.Number("return sentAt60"));
    }

    [Fact]
    public void WaitsForTheThrottleSystem()
    {
        lua.Run("""
            throttleReady = false
            sched:EnqueueLookups({ target('a') })
            before = #sent
            state = sched:GetLookupStatus().state
            throttleReady = true
            sched:OnThrottleReady()
            """);
        Assert.Equal(0, lua.Number("return before"));
        Assert.Equal("waitingThrottle", lua.String("return state"));
        Assert.Equal(1, lua.Number("return #sent"));
    }

    [Fact]
    public void DroppedMessageIsRetriedThenGivenUp()
    {
        lua.Run("""
            sched:EnqueueLookups({ target('a') })
            sched:OnMessageDropped()
            sched:OnMessageDropped()
            sched:OnMessageDropped()  -- third drop exceeds maxRetries (2)
            """);
        Assert.Equal(3, lua.Number("return #sent"));
        Assert.Equal("a:dropped", lua.String("return events[1]"));
        Assert.Equal("idle", lua.String("return sched:GetLookupStatus().state"));
    }

    [Fact]
    public void LostResponseTimesOutAndQueueContinues()
    {
        lua.Run("""
            sched:EnqueueLookups({ target('a'), target('b') })
            clock.advance(10.5)
            """);
        Assert.Equal("a:timeout", lua.String("return events[1]"));
        Assert.Equal(2, lua.Number("return #sent"));
    }

    [Fact]
    public void CancelClearsTheQueueAndIgnoresLateTimers()
    {
        lua.Run("""
            sched:EnqueueLookups({ target('a'), target('b') })
            hadWork = sched:CancelLookups()
            clock.advance(30)
            sched:OnSearchResults('G:a')
            """);
        Assert.True(lua.Bool("return hadWork"));
        Assert.Equal(1, lua.Number("return #sent"));
        Assert.Equal(0, lua.Number("return #events"));
        Assert.Equal("idle", lua.String("return sched:GetLookupStatus().state"));
    }
}

public class AuctionScannerTests
{
    private readonly LuaHarness lua = new();

    public AuctionScannerTests()
    {
        lua.Run("env = Fake.NewEnvironment(fixture('AuctionData'))");
    }

    [Fact]
    public void ScanFailsWhenAuctionHouseIsClosed()
    {
        lua.Run("ok, reason = env.scanner:ScanBrowse()");
        Assert.False(lua.Bool("return ok"));
        Assert.Equal("ah_closed", lua.String("return reason"));
        Assert.Equal("ah_closed", lua.String("return env.lastEvent('SCAN_FAILED').args[1]"));
    }

    [Fact]
    public void ScanFailsWithoutBrowseResults()
    {
        lua.Run("""
            env.api.data.browse = {}
            env.scanner:SetAuctionHouseOpen(true)
            ok, reason = env.scanner:ScanBrowse()
            """);
        Assert.Equal("no_results", lua.String("return reason"));
    }

    [Fact]
    public void BrowseScanBuildsRecordsIncrementally()
    {
        lua.Run("""
            env.scanner:SetAuctionHouseOpen(true)
            ok = env.scanner:ScanBrowse()
            completeBeforeFrames = env.lastEvent('SCAN_COMPLETE') ~= nil
            env.clock.runDeferred()
            summary = env.lastEvent('SCAN_COMPLETE').args[1]
            result = env.evaluate(ns.Settings.ToFilters(ns.Settings.Defaults()))
            """);
        Assert.True(lua.Bool("return ok"));
        Assert.True(lua.Bool("return completeBeforeFrames")); // 6 rows fit in one chunk
        Assert.Equal(6, lua.Number("return summary.total"));
        Assert.Equal(6, lua.Number("return summary.records"));
        Assert.Equal(2, lua.Number("return #result.opportunities"));
        Assert.Equal(1, lua.Number("return result.stats.possible"));
    }

    [Fact]
    public void ClosingTheAuctionHouseCancelsTheScan()
    {
        lua.Run("""
            for i = 1, 200 do
                env.api.data.browse[#env.api.data.browse + 1] = { itemKey = Fake.ItemKey(2207, i), totalQuantity = 1, minPrice = 10 }
            end
            env.scanner:SetAuctionHouseOpen(true)
            env.scanner:ScanBrowse()
            env.scanner:SetAuctionHouseOpen(false)
            env.clock.runDeferred()
            """);
        Assert.False(lua.IsNil("return env.lastEvent('SCAN_CANCELLED')"));
        Assert.True(lua.IsNil("return env.lastEvent('SCAN_COMPLETE')"));
        Assert.Equal(0, lua.Number("return env.store:CountBrowse()"));
    }

    [Fact]
    public void PassiveListingEventsReplaceBrowseEstimates()
    {
        lua.Run("""
            env.scanner:SetAuctionHouseOpen(true)
            env.scanner:ScanBrowse()
            env.clock.runDeferred()
            env.scanner:OnItemSearchResults(Fake.ItemKey(2207))
            env.scanner:OnCommoditySearchResults(2589)
            result = env.evaluate(ns.Settings.ToFilters(ns.Settings.Defaults()))
            kinds = {}
            for _, o in ipairs(result.opportunities) do kinds[#kinds + 1] = o.record.kind end
            table.sort(kinds)
            """);
        Assert.Equal("commodity,commodity,item,item", lua.String("return table.concat(kinds, ',')"));
        Assert.Equal(27 + 17 + 280, lua.Number("return result.stats.totalProfit"));
        Assert.False(lua.Bool("return result.stats.totalProfitIsLowerBound"));
    }

    [Fact]
    public void ListingEventsAreIgnoredWhileClosed()
    {
        lua.Run("groupKey = env.scanner:OnItemSearchResults(Fake.ItemKey(2207))");
        Assert.True(lua.IsNil("return groupKey"));
        Assert.Equal(0, lua.Number("return env.store:CountGroups()"));
    }

    [Fact]
    public void LookupTargetSendsOneSearchAndCompletesOnResults()
    {
        lua.Run("""
            env.scanner:SetAuctionHouseOpen(true)
            env.scanner:ScanBrowse()
            env.clock.runDeferred()
            scroll = env.store.browseByKey['B:4000:0:0:0']
            env.scheduler:EnqueueLookups({ env.scanner:BuildLookupTarget(scroll) })
            sentCount = #env.api.calls.sendSearch
            env.scanner:OnItemSearchResults(Fake.ItemKey(4000))
            hasListings = env.scanner:HasListingsFor(scroll)
            state = env.scheduler:GetLookupStatus().state
            result = env.evaluate(ns.Settings.ToFilters(ns.Settings.Defaults()))
            """);
        Assert.Equal(1, lua.Number("return sentCount"));
        Assert.Equal(4000, lua.Number("return env.api.calls.sendSearch[1].itemID"));
        Assert.True(lua.Bool("return hasListings"));
        Assert.Equal("idle", lua.String("return state"));
        Assert.Equal(0, lua.Number("return result.stats.possible"));
    }

    [Fact]
    public void LateItemDataRebuildsRecordsWithoutQueries()
    {
        lua.Run("""
            env.api.data.uncached[2207] = true
            env.api.data.keyInfo[2207] = nil
            env.api.data.items[2207].classID = nil
            env.scanner:SetAuctionHouseOpen(true)
            env.scanner:ScanBrowse()
            env.clock.runDeferred()
            before = env.store.browseByKey['B:2207:0:0:0'].category
            env.api.data.uncached[2207] = nil
            env.api.data.items[2207].classID = 2
            env.vendorPrices:OnItemDataLoaded(2207, true)
            env.scanner:RefreshItem(2207)
            after = env.store.browseByKey['B:2207:0:0:0'].category
            """);
        Assert.True(lua.IsNil("return before"));
        Assert.Equal("equipment", lua.String("return after"));
        Assert.Equal(0, lua.Number("return #env.api.calls.sendSearch"));
    }
}

public class SettingsTests
{
    private readonly LuaHarness lua = new();

    [Fact]
    public void DefaultsAreSensible()
    {
        lua.Run("s = ns.Settings.Apply(nil)");
        Assert.Equal("click", lua.String("return s.lookup.mode"));
        Assert.Equal(30, lua.Number("return s.lookup.batchMaxPerMinute"));
        Assert.False(lua.Bool("return s.sound.enabled"));
        Assert.Equal("profit", lua.String("return s.sortKey"));
        Assert.True(lua.Bool("return s.categories.equipment and s.categories.material and s.categories.consumable"));
        Assert.Equal(0, lua.Number("return s.maxBuyout"));
    }

    [Fact]
    public void InvalidSavedValuesAreRepairedAndUnknownKeysKept()
    {
        lua.Run("""
            s = ns.Settings.Apply({
                minProfit = -5, minRoiBasisPoints = 'x', sortKey = 'bogus',
                lookup = { mode = 'turbo', batchMaxPerMinute = 500 },
                sound = 'yes', categories = { equipment = false },
                futureOption = 42,
            })
            """);
        Assert.Equal(1, lua.Number("return s.minProfit"));
        Assert.Equal(0, lua.Number("return s.minRoiBasisPoints"));
        Assert.Equal("profit", lua.String("return s.sortKey"));
        Assert.Equal("click", lua.String("return s.lookup.mode"));
        Assert.Equal(90, lua.Number("return s.lookup.batchMaxPerMinute"));
        Assert.False(lua.Bool("return s.sound.enabled"));
        Assert.False(lua.Bool("return s.categories.equipment"));
        Assert.True(lua.Bool("return s.categories.material"));
        Assert.Equal(42, lua.Number("return s.futureOption"));
    }

    [Fact]
    public void BatchModeIsPreserved()
    {
        lua.Run("s = ns.Settings.Apply({ lookup = { mode = 'batch', batchMaxPerMinute = 0 } })");
        Assert.Equal("batch", lua.String("return s.lookup.mode"));
        Assert.Equal(1, lua.Number("return s.lookup.batchMaxPerMinute"));
    }
}
