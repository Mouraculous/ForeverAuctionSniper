using Xunit;

namespace VendorSniper.Tests;

public class ProfitCalculatorTests
{
    private readonly LuaHarness lua = new();

    private void Calc(double vendor, double qty, double buyout) =>
        lua.Run($"result, err = ns.ProfitCalculator.Calculate({vendor:R}, {qty:R}, {buyout:R})");

    [Fact] // Required case 1
    public void ProfitableSingleItem()
    {
        Calc(500, 1, 300);
        Assert.Equal(500, lua.Number("return result.totalVendorValue"));
        Assert.Equal(200, lua.Number("return result.profit"));
        Assert.Equal(6666, lua.Number("return result.roiBasisPoints"));
        Assert.True(lua.Bool("return result.isProfitable"));
    }

    [Fact] // Required case 2
    public void UnprofitableSingleItem()
    {
        Calc(100, 1, 300);
        Assert.Equal(-200, lua.Number("return result.profit"));
        Assert.Equal(-6666, lua.Number("return result.roiBasisPoints"));
        Assert.False(lua.Bool("return result.isProfitable"));
    }

    [Fact] // Required case 3
    public void StackUsesVendorPricePerUnitTimesQuantity()
    {
        Calc(25, 20, 400);
        Assert.Equal(500, lua.Number("return result.totalVendorValue"));
        Assert.Equal(100, lua.Number("return result.profit"));
        Assert.Equal(20, lua.Number("return result.unitBuyout"));
        Assert.Equal(2500, lua.Number("return result.roiBasisPoints"));
    }

    [Fact] // Required case 4
    public void ZeroVendorPriceIsReportedNotProfitable()
    {
        Calc(0, 5, 100);
        Assert.True(lua.IsNil("return result"));
        Assert.Equal("no_vendor_value", lua.String("return err"));
    }

    [Fact] // Required case 5
    public void ZeroBuyoutIsRejected()
    {
        Calc(100, 1, 0);
        Assert.True(lua.IsNil("return result"));
        Assert.Equal("zero_buyout", lua.String("return err"));
    }

    [Theory]
    [InlineData("-1, 1, 100", "invalid_vendor_price")]
    [InlineData("1.5, 1, 100", "invalid_vendor_price")]
    [InlineData("0/0, 1, 100", "invalid_vendor_price")]
    [InlineData("10, 0, 100", "invalid_quantity")]
    [InlineData("10, 2.5, 100", "invalid_quantity")]
    [InlineData("10, 1, -5", "invalid_buyout")]
    [InlineData("10, 1, nil", "invalid_buyout")]
    [InlineData("'10', 1, 100", "invalid_vendor_price")]
    public void InvalidInputsAreRejectedSafely(string args, string expected)
    {
        lua.Run($"result, err = ns.ProfitCalculator.Calculate({args})");
        Assert.True(lua.IsNil("return result"));
        Assert.Equal(expected, lua.String("return err"));
    }

    [Fact] // Required case 10
    public void LargeCopperValuesStayExact()
    {
        // 500,000 gold per unit x 200 units = 100 million gold of vendor value.
        Calc(5_000_000_000, 200, 999_999_999_999);
        Assert.Equal(1_000_000_000_000, lua.Number("return result.totalVendorValue"));
        Assert.Equal(1, lua.Number("return result.profit"));
        Assert.Equal(0, lua.Number("return result.roiBasisPoints"));

        Calc(100_000_000_000, 1, 1);
        Assert.Equal(99_999_999_999, lua.Number("return result.profit"));
        Assert.Equal(999_999_999_990_000, lua.Number("return result.roiBasisPoints"));
    }

    [Fact]
    public void OverflowBeyondSafeIntegersIsRejected()
    {
        Calc(9_007_199_254_740_991, 2, 1);
        Assert.Equal("overflow", lua.String("return err"));
    }

    [Theory] // Required case 11
    [InlineData(1, 3, 3333)]
    [InlineData(2, 3, 6666)]
    [InlineData(1, 1, 10000)]
    [InlineData(150, 100, 15000)]
    [InlineData(-1, 3, -3333)]
    [InlineData(7_000, 10_000_000, 7)]
    [InlineData(7, 10_000_000, 0)]
    public void RoiIsTruncatedBasisPoints(double profit, double cost, double expectedBp)
    {
        Assert.Equal(expectedBp, lua.Number($"return ns.ProfitCalculator.RoiBasisPoints({profit:R}, {cost:R})"));
    }

    [Fact]
    public void IntDivIsExactForLargeValues()
    {
        Assert.Equal(3, lua.Number("return ns.Money.IntDiv(10, 3)"));
        Assert.Equal(900719925474099, lua.Number("return ns.Money.IntDiv(9007199254740991, 10)"));
        Assert.Equal(0, lua.Number("return ns.Money.IntDiv(2, 3)"));
    }

    [Fact]
    public void CommodityAggregateBuysCheapestFirstBelowVendorPrice()
    {
        lua.Run("""
            agg = ns.ProfitCalculator.CommodityAggregate({
                { unitPrice = 120, quantity = 20 },
                { unitPrice = 50, quantity = 10 },
                { unitPrice = 80, quantity = 5 },
                { unitPrice = 0, quantity = 99 },   -- invalid, ignored
                { unitPrice = 60, quantity = 0 },   -- invalid, ignored
            }, 100)
            """);
        Assert.Equal(15, lua.Number("return agg.units"));
        Assert.Equal(900, lua.Number("return agg.cost"));
        Assert.Equal(1500, lua.Number("return agg.totalVendorValue"));
        Assert.Equal(600, lua.Number("return agg.profit"));
        Assert.Equal(80, lua.Number("return agg.maxUnitPrice"));
        Assert.Equal(2, lua.Number("return agg.tiers"));
        Assert.Equal(6666, lua.Number("return agg.roiBasisPoints"));
    }

    [Fact]
    public void CommodityAggregateIsNilWhenNothingIsBelowVendorPrice()
    {
        Assert.True(lua.IsNil("return ns.ProfitCalculator.CommodityAggregate({ { unitPrice = 100, quantity = 5 } }, 100)"));
        Assert.True(lua.IsNil("return ns.ProfitCalculator.CommodityAggregate({ { unitPrice = 1, quantity = 5 } }, 0)"));
    }
}

public class MoneyTests
{
    private readonly LuaHarness lua = new();

    [Theory]
    [InlineData(10000, "1g")]
    [InlineData(100, "1s")]
    [InlineData(1, "1c")]
    [InlineData(0, "0c")]
    [InlineData(12345, "1g 23s 45c")]
    [InlineData(10203, "1g 2s 3c")]
    [InlineData(10005, "1g 5c")]
    [InlineData(-150, "-1s 50c")]
    [InlineData(99_999_999_999, "9999999g 99s 99c")]
    public void FormatsStandardCurrency(double copper, string expected)
    {
        Assert.Equal(expected, lua.String($"return ns.Money.Format({copper:R})"));
    }

    [Theory]
    [InlineData("1g20s", 12000)]
    [InlineData("1g 2s 3c", 10203)]
    [InlineData("50s", 5000)]
    [InlineData("75c", 75)]
    [InlineData("75", 75)]
    [InlineData("2G", 20000)]
    public void ParsesMoney(string text, double expected)
    {
        Assert.Equal(expected, lua.Number($"return ns.Money.Parse('{text}')"));
    }

    [Theory]
    [InlineData("abc")]
    [InlineData("1x")]
    [InlineData("")]
    [InlineData("g")]
    public void RejectsMalformedMoney(string text)
    {
        Assert.True(lua.IsNil($"return ns.Money.Parse('{text}')"));
    }

    [Theory]
    [InlineData(12345, "123.45%")]
    [InlineData(5, "0.05%")]
    [InlineData(-2500, "-25.00%")]
    public void FormatsRoi(double bp, string expected)
    {
        Assert.Equal(expected, lua.String($"return ns.Money.FormatRoi({bp:R})"));
    }
}
