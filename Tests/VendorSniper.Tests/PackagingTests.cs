using System.Text.RegularExpressions;
using Xunit;

namespace VendorSniper.Tests;

/// <summary>Checks the manifest and that the sources avoid Lua features the Forever client lacks.</summary>
public class PackagingTests
{
    [Fact]
    public void TocTargetsForeverInterface()
    {
        var meta = Toc.ReadMetadata();
        Assert.Equal("16001", meta["Interface"]);
        Assert.Equal("VendorSniperDB", meta["SavedVariables"]);
        Assert.Equal("Vendor Sniper", meta["Title"]);
    }

    [Fact]
    public void TocListsExactlyTheAddonLuaFiles()
    {
        var listed = Toc.ReadFiles().Select(f => f.Replace('\\', '/')).ToHashSet();
        var onDisk = Directory.EnumerateFiles(LuaHarness.AddonRoot, "*.lua", SearchOption.AllDirectories)
            .Select(f => Path.GetRelativePath(LuaHarness.AddonRoot, f).Replace('\\', '/'))
            .ToHashSet();
        Assert.Equal(onDisk.OrderBy(x => x), listed.OrderBy(x => x));
        // WoW TOC paths use backslashes.
        Assert.All(Toc.ReadFiles(), f => Assert.DoesNotContain('/', f));
    }

    public static IEnumerable<object[]> AddonFiles() =>
        Directory.EnumerateFiles(LuaHarness.AddonRoot, "*.lua", SearchOption.AllDirectories)
            .Select(f => new object[] { Path.GetRelativePath(LuaHarness.AddonRoot, f) });

    private static readonly (string Name, Regex Pattern)[] ForbiddenInLua51 =
    {
        ("goto", new Regex(@"\bgoto\b")),
        ("integer division //", new Regex(@"//")),
        ("_ENV", new Regex(@"\b_ENV\b")),
        ("require", new Regex(@"\brequire\s*\(")),
        ("table.unpack", new Regex(@"\btable\.unpack\b")),
        ("bitwise operator", new Regex(@"[^~=<>]~[^=]|<<|>>|\s&\s")),
        ("io/os library", new Regex(@"\b(io|os)\.\w+")),
        ("dofile/loadfile", new Regex(@"\b(dofile|loadfile)\s*\(")),
    };

    // Removes comments and string literals so only code is checked.
    private static string CodeOnly(string source)
    {
        var noLongComments = Regex.Replace(source, @"--\[(=*)\[.*?\]\1\]", "", RegexOptions.Singleline);
        var noLongStrings = Regex.Replace(noLongComments, @"\[(=*)\[.*?\]\1\]", "\"\"", RegexOptions.Singleline);
        var noStrings = Regex.Replace(noLongStrings, "\"(\\\\.|[^\"\\\\])*\"|'(\\\\.|[^'\\\\])*'", "\"\"");
        return Regex.Replace(noStrings, @"--[^\n]*", "");
    }

    [Theory]
    [MemberData(nameof(AddonFiles))]
    public void SourcesUseOnlyLua51Features(string relativePath)
    {
        var code = CodeOnly(File.ReadAllText(Path.Combine(LuaHarness.AddonRoot, relativePath)));
        foreach (var (name, pattern) in ForbiddenInLua51)
        {
            Assert.False(pattern.IsMatch(code), $"{relativePath} uses {name}");
        }
    }

    [Theory]
    [MemberData(nameof(AddonFiles))]
    public void NoRestrictedAuctionFunctionIsCalled(string relativePath)
    {
        var code = CodeOnly(File.ReadAllText(Path.Combine(LuaHarness.AddonRoot, relativePath)));
        var restricted = new Regex(@"\b(PlaceBid|StartCommoditiesPurchase|ConfirmCommoditiesPurchase|PostItem|PostCommodity|ConfirmPostItem|ConfirmPostCommodity|CancelAuction|ReplicateItems)\b");
        Assert.False(restricted.IsMatch(code), $"{relativePath} references a restricted or out-of-scope C_AuctionHouse function");
    }

    [Theory]
    [MemberData(nameof(AddonFiles))]
    public void OnlyWoWApiAdapterAndDiagnosticsTouchGameNamespaces(string relativePath)
    {
        var name = Path.GetFileName(relativePath);
        if (name is "WoWAPI.lua" or "Diagnostics.lua")
        {
            return;
        }
        var code = CodeOnly(File.ReadAllText(Path.Combine(LuaHarness.AddonRoot, relativePath)));
        Assert.False(Regex.IsMatch(code, @"\b(C_AuctionHouse|C_Item)\b"), $"{relativePath} should go through ns.WoWAPI");
    }
}
