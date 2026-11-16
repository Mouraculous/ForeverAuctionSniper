using Xunit;

namespace VendorSniper.Tests;

/// <summary>
/// Normalisation, evaluation, filtering, deduplication and sorting, run
/// against raw Forever API structures from TestFixtures/AuctionData.lua.
/// </summary>
public class AuctionEvaluatorTests
{
    private readonly LuaHarness lua = new();

    public AuctionEvaluatorTests()
    {
        lua.Run("""
            data = fixture('AuctionData')
            L = ns.Listings
            E = ns.AuctionEvaluator
            function info(itemID)
                local d, k = data.items[itemID], data.keyInfo[itemID]
                return { name = d.name, quality = d.quality, icon = d.icon, link = d.link, classID = d.classID,
                         maxStack = d.maxStack, isCommodity = k and k.isCommodity, isEquipment = k and k.isEquipment }
            end
            function browse(index) return L.FromBrowseResult(data.browse[index], info(data.browse[index].itemKey.itemID)) end
            function vendor(record) return data.items[record.itemID].sellPrice, 'ok' end
            function process(records, filters) return E.Process(records, vendor, filters) end
            function allFilters() return ns.Settings.ToFilters(ns.Settings.Defaults()) end
            """);
    }

    [Fact] // Required case 1 (via the evaluator)
    public void ProfitableEquipmentListingIsAnOpportunity()
    {
        lua.Run("""
            records = L.FromItemSearchResults(Fake.ItemKey(2207), data.itemRows['2207:0:0:0'], info(2207))
            eval = E.Evaluate(records[1], 77, 'ok')
            """);
        Assert.Equal("profitable", lua.String("return eval.status"));
        Assert.Equal(27, lua.Number("return eval.profit"));
        Assert.False(lua.Bool("return eval.isLowerBound"));
        Assert.Equal("purchasable", lua.String("return records[1].auctionIDKind"));
        Assert.Equal(101, lua.Number("return records[1].auctionID"));
    }

    [Fact] // Required case 2
    public void UnprofitableListingIsNotShown()
    {
        lua.Run("""
            records = L.FromItemSearchResults(Fake.ItemKey(2207), { data.itemRows['2207:0:0:0'][4] }, info(2207))
            result = process(records, allFilters())
            """);
        Assert.Equal("unprofitable", lua.String("return E.Evaluate(records[1], 77, 'ok').status"));
        Assert.Equal(0, lua.Number("return #result.opportunities"));
        Assert.Equal(1, lua.Number("return result.stats.evaluated"));
    }

    [Fact] // Required case 3
    public void StackListingUsesTotalBuyoutAndQuantity()
    {
        lua.Run("""
            records = L.FromItemSearchResults(Fake.ItemKey(4000), data.itemRows['4000:0:0:0'], info(4000))
            a = E.Evaluate(records[1], 100, 'ok')  -- 10 for 500: vendor 1000
            b = E.Evaluate(records[2], 100, 'ok')  -- 2 for 600: vendor 200
            """);
        Assert.Equal(10, lua.Number("return records[1].quantity"));
        Assert.Equal(50, lua.Number("return records[1].unitPrice"));
        Assert.Equal(1000, lua.Number("return a.totalVendorValue"));
        Assert.Equal(500, lua.Number("return a.profit"));
        Assert.Equal("unprofitable", lua.String("return b.status"));
        Assert.Equal(-400, lua.Number("return b.profit"));
    }

    [Fact] // Required case 4
    public void ZeroVendorPriceIsCountedSeparately()
    {
        lua.Run("result = process({ browse(6) }, allFilters())");
        Assert.Equal(1, lua.Number("return result.stats.noVendorValue"));
        Assert.Equal(0, lua.Number("return result.stats.profitable"));
    }

    [Fact] // Required case 5
    public void ZeroOrMissingBuyoutIsSkippedNotCrashed()
    {
        lua.Run("""
            rawBrowse = { itemKey = Fake.ItemKey(2207), totalQuantity = 1, minPrice = 0 }
            rec, why = L.FromBrowseResult(rawBrowse, info(2207))
            records, skipped = L.FromItemSearchResults(Fake.ItemKey(2207), {
                { itemKey = Fake.ItemKey(2207), auctionID = 1, quantity = 1, buyoutAmount = 0 },
                { itemKey = Fake.ItemKey(2207), auctionID = 2, quantity = 1 },               -- bid only
                { itemKey = Fake.ItemKey(2207), auctionID = 3, quantity = 0, buyoutAmount = 5 }, -- invalid quantity
                'garbage',
                { itemKey = Fake.ItemKey(2207), auctionID = 4, quantity = 1, buyoutAmount = 5 },
            }, info(2207))
            """);
        Assert.True(lua.IsNil("return rec"));
        Assert.Equal("no_buyout", lua.String("return why"));
        Assert.Equal(1, lua.Number("return #records"));
        Assert.Equal(2, lua.Number("return skipped.no_buyout"));
        Assert.Equal(2, lua.Number("return skipped.invalid"));
    }

    [Fact] // Required case 6
    public void MissingItemInformationIsReportedAsUnknownVendor()
    {
        lua.Run("""
            records = { browse(1), browse(2), L.FromBrowseResult(data.browse[2], {}) }
            result = E.Process(records, function(record)
                if record.itemID == 2589 then return nil, 'pending' end
                return nil, 'unavailable'
            end, allFilters())
            noInfo = L.FromBrowseResult(data.browse[2], nil)
            """);
        Assert.Equal(2, lua.Number("return result.stats.vendorUnknown"));
        Assert.Equal(2, lua.Number("return result.stats.vendorUnknownItems"));
        Assert.Equal(0, lua.Number("return #result.opportunities"));
        // Without ItemKeyInfo the browse row stays conservative.
        Assert.Equal("lowerBound", lua.String("return noInfo.precision"));
        Assert.Equal(2, lua.Number("return #noInfo.supersededBy"));
        Assert.True(lua.IsNil("return noInfo.category"));
    }

    [Fact] // Required case 7
    public void MissingAuctionIdsGetStableDistinctFallbackKeys()
    {
        lua.Run("""
            rows = {
                { itemKey = Fake.ItemKey(2207), quantity = 1, buyoutAmount = 40 },
                { itemKey = Fake.ItemKey(2207), quantity = 1, buyoutAmount = 40 },
                { itemKey = Fake.ItemKey(2207), quantity = 1, buyoutAmount = 45 },
            }
            first = L.FromItemSearchResults(Fake.ItemKey(2207), rows, info(2207))
            again = L.FromItemSearchResults(Fake.ItemKey(2207), rows, info(2207))
            """);
        Assert.Equal(3, lua.Number("return #first"));
        Assert.True(lua.Bool("return first[1].key ~= first[2].key"));
        Assert.True(lua.Bool("return first[1].key == again[1].key and first[2].key == again[2].key"));
        Assert.True(lua.IsNil("return first[1].auctionID"));
        Assert.True(lua.IsNil("return first[1].auctionIDKind"));
        // Processing both snapshots together doesn't double count.
        lua.Run("""
            combined = {}
            for _, r in ipairs(first) do combined[#combined + 1] = r end
            for _, r in ipairs(again) do combined[#combined + 1] = r end
            result = process(combined, allFilters())
            """);
        Assert.Equal(3, lua.Number("return result.stats.evaluated"));
    }

    [Fact] // Required case 8
    public void DuplicateBrowseResultsAreNotShownTwice()
    {
        lua.Run("""
            store = ns.ResultStore.New()
            local function snapshot()
                local list = {}
                for i = 1, #data.browse do list[#list + 1] = browse(i) end
                return list
            end
            store:SetBrowseSnapshot(snapshot())
            store:AddBrowseRecords(snapshot())
            dupList = snapshot()
            dupList[#dupList + 1] = browse(2)
            deduped = E.Dedupe(dupList)
            records = L.FromItemSearchResults(Fake.ItemKey(2207),
                { data.itemRows['2207:0:0:0'][1], data.itemRows['2207:0:0:0'][1] }, info(2207))
            """);
        Assert.Equal(6, lua.Number("return #store:GetActiveRecords()"));
        Assert.Equal(6, lua.Number("return #deduped"));
        Assert.Equal(1, lua.Number("return #records")); // same auctionID twice in one snapshot
    }

    [Fact] // Required case 9
    public void MultipleAuctionsOfTheSameItemStaySeparate()
    {
        lua.Run("""
            records = L.FromItemSearchResults(Fake.ItemKey(2207), data.itemRows['2207:0:0:0'], info(2207))
            result = process(records, allFilters())
            """);
        Assert.Equal(3, lua.Number("return #records")); // bid-only auction 103 skipped
        Assert.Equal(2, lua.Number("return #result.opportunities"));
        Assert.Equal(27 + 17, lua.Number("return result.stats.totalProfit"));
        Assert.True(lua.Bool("return result.opportunities[1].record.key ~= result.opportunities[2].record.key"));
    }

    [Fact] // Required case 12
    public void FiltersByMinimumProfit()
    {
        lua.Run("""
            records = L.FromItemSearchResults(Fake.ItemKey(2207), data.itemRows['2207:0:0:0'], info(2207))
            f = allFilters(); f.minProfit = 20
            result = process(records, f)
            """);
        Assert.Equal(1, lua.Number("return #result.opportunities"));
        Assert.Equal(27, lua.Number("return result.opportunities[1].evaluation.profit"));
        Assert.Equal(1, lua.Number("return result.stats.filteredOut"));
    }

    [Fact] // Required case 13
    public void FiltersByMinimumRoi()
    {
        lua.Run("""
            records = L.FromItemSearchResults(Fake.ItemKey(2207), data.itemRows['2207:0:0:0'], info(2207))
            f = allFilters(); f.minRoiBasisPoints = 3000  -- 30 %
            result = process(records, f)
            """);
        // 27/50 = 54 % passes, 17/60 = 28.33 % doesn't.
        Assert.Equal(1, lua.Number("return #result.opportunities"));
        Assert.Equal(5400, lua.Number("return result.opportunities[1].evaluation.roiBasisPoints"));
    }

    [Fact]
    public void FiltersByMaxBuyoutCategoryAndQuality()
    {
        lua.Run("""
            records = {}
            for i = 1, #data.browse do records[#records + 1] = browse(i) end
            base = process(records, allFilters())
            f = allFilters(); f.categories.equipment = false
            noEquip = process(records, f)
            f = allFilters(); f.maxBuyout = 40
            cheap = process(records, f)
            f = allFilters(); f.qualities[1] = false
            noCommon = process(records, f)
            """);
        // Profitable: linen (perUnitMin), jambiya (exact), recipe (unsupported category -> filtered).
        Assert.Equal(3, lua.Number("return base.stats.profitable"));
        Assert.Equal(2, lua.Number("return #base.opportunities"));
        Assert.Equal(1, lua.Number("return #noEquip.opportunities"));
        Assert.Equal("2589:0:0:0", lua.String("return noEquip.opportunities[1].record.itemKeyString"));
        Assert.Equal(1, lua.Number("return #cheap.opportunities"));
        Assert.Equal(0, lua.Number("return #noCommon.opportunities"));
    }

    [Fact] // Required case 14
    public void CommodityAndEquipmentAreHandledDifferently()
    {
        lua.Run("""
            linenBrowse, jambiyaBrowse = browse(1), browse(2)
            tiers = L.FromCommoditySearchResults(2589, data.commodityRows[2589], info(2589))
            items = L.FromItemSearchResults(Fake.ItemKey(2207), data.itemRows['2207:0:0:0'], info(2207))
            result = process(tiers, allFilters())
            agg = result.commodityAggregates['C:2589']
            """);
        // Browse level
        Assert.Equal("perUnitMin", lua.String("return linenBrowse.precision"));
        Assert.Equal("exact", lua.String("return jambiyaBrowse.precision"));
        Assert.True(lua.Bool("return E.Evaluate(linenBrowse, 13, 'ok').isLowerBound"));
        Assert.False(lua.Bool("return E.Evaluate(jambiyaBrowse, 77, 'ok').isLowerBound"));
        Assert.True(lua.IsNil("return linenBrowse.auctionID"));
        Assert.Equal("C:2589", lua.String("return linenBrowse.supersededBy[1]"));
        Assert.Equal("I:2207:0:0:0", lua.String("return jambiyaBrowse.supersededBy[1]"));
        // Commodity tiers: same unit price merged; auction IDs informational only.
        Assert.Equal(3, lua.Number("return #tiers"));
        Assert.Equal(60, lua.Number("return tiers[1].quantity"));
        Assert.Equal(600, lua.Number("return tiers[1].buyoutTotal"));
        Assert.Equal(2, lua.Number("return tiers[1].mergedRows"));
        Assert.Equal("informational", lua.String("return tiers[1].auctionIDKind"));
        Assert.Equal("purchasable", lua.String("return items[1].auctionIDKind"));
        // Cumulative "buy the first N units": 60@10 + 100@12, the 15c tier is above vendor (13c).
        Assert.Equal(2, lua.Number("return #result.opportunities"));
        Assert.Equal(160, lua.Number("return agg.units"));
        Assert.Equal(1800, lua.Number("return agg.cost"));
        Assert.Equal(280, lua.Number("return agg.profit"));
        Assert.Equal(280, lua.Number("return result.stats.totalProfit"));
    }

    [Fact]
    public void ListingGroupsSupersedeTheirBrowseRow()
    {
        lua.Run("""
            store = ns.ResultStore.New()
            local list = {}
            for i = 1, #data.browse do list[#list + 1] = browse(i) end
            store:SetBrowseSnapshot(list)
            store:SetListingGroup('C:2589', L.FromCommoditySearchResults(2589, data.commodityRows[2589], info(2589)))
            store:SetListingGroup('I:6000:0:0:0', {})  -- searched, nothing listed
            active = store:GetActiveRecords()
            kinds = {}
            for _, r in ipairs(active) do kinds[r.key] = r.kind end
            """);
        Assert.Equal(3 + 4, lua.Number("return #active"));
        Assert.True(lua.IsNil("return kinds['B:2589:0:0:0']"));
        Assert.True(lua.IsNil("return kinds['B:6000:0:0:0']"));
        Assert.Equal("browse", lua.String("return kinds['B:2207:0:0:0']"));
        Assert.Equal("commodity", lua.String("return kinds['C:2589:10']"));
    }

    [Fact]
    public void StackableNonCommodityBrowseRowIsPossibleNotProfitable()
    {
        lua.Run("""
            scroll = browse(4)  -- minPrice 500, vendor 100, stack 10
            eval = E.Evaluate(scroll, 100, 'ok')
            result = process({ scroll }, allFilters())
            """);
        Assert.Equal("lowerBound", lua.String("return scroll.precision"));
        Assert.Equal("possible", lua.String("return eval.status"));
        Assert.Equal(1, lua.Number("return result.stats.possible"));
        Assert.Equal(0, lua.Number("return #result.opportunities"));
    }

    [Fact]
    public void SortingDefaultsToProfitAndSupportsAllKeys()
    {
        lua.Run("""
            records = L.FromItemSearchResults(Fake.ItemKey(4000), {
                { auctionID = 1, quantity = 10, buyoutAmount = 500 },  -- profit 500, roi 100 %
                { auctionID = 2, quantity = 1, buyoutAmount = 10 },    -- profit 90, roi 900 %
                { auctionID = 3, quantity = 5, buyoutAmount = 300 },   -- profit 200, roi 66 %
            }, info(4000))
            opps = process(records, allFilters()).opportunities
            function order(key)
                ns.Sorting.Sort(opps, key)
                local ids = {}
                for i, o in ipairs(opps) do ids[i] = o.record.auctionID end
                return table.concat(ids, ',')
            end
            """);
        Assert.Equal("1,3,2", lua.String("return order(ns.Sorting.DEFAULT)"));
        Assert.Equal("2,1,3", lua.String("return order('roi')"));
        Assert.Equal("2,3,1", lua.String("return order('buyout')"));
        Assert.Equal("1,3,2", lua.String("return order('vendorValue')"));
        Assert.Equal("1,3,2", lua.String("return order('quantity')"));
        Assert.Equal("1,3,2", lua.String("return order('name')")); // same name -> profit tie-break
        Assert.Equal("1,3,2", lua.String("return order('bogus')"));
    }

    [Fact]
    public void NotificationsFireOnlyOncePerNewListingAboveThreshold()
    {
        lua.Run("""
            records = L.FromItemSearchResults(Fake.ItemKey(2207), data.itemRows['2207:0:0:0'], info(2207))
            opps = process(records, allFilters()).opportunities
            notified = {}
            first = E.SelectNewNotifications(opps, notified, 20)
            second = E.SelectNewNotifications(opps, notified, 20)
            """);
        Assert.Equal(1, lua.Number("return #first"));
        Assert.Equal(0, lua.Number("return #second"));
    }
}
