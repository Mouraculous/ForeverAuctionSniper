using MoonSharp.Interpreter;

namespace VendorSniper.Tests;

/// <summary>
/// Loads the addon's Lua files into a MoonSharp interpreter the way the WoW
/// client does: each file is a chunk called with (addonName, ns).
/// Files that need the live game at load time (Diagnostics.lua, Core.lua)
/// are skipped. Everything else only defines functions at load time.
/// </summary>
public sealed class LuaHarness
{
    public const string AddonName = "VendorSniper";

    private static readonly HashSet<string> GameOnlyFiles = new(StringComparer.OrdinalIgnoreCase)
    {
        "Diagnostics.lua",
        "Core.lua",
    };

    public Script Script { get; }
    public Table Ns { get; }

    /// <param name="withGameStubs">
    /// When true, stub WoW globals (TestFixtures/WoWGlobals.lua, backed by
    /// AuctionData.lua) are installed first and every TOC file is loaded,
    /// Core.lua included. The stub controller is available as global <c>game</c>.
    /// </param>
    /// <param name="withUiStubs">
    /// Also installs TestFixtures/WoWUIStubs.lua: generic frame stand-ins plus
    /// AuctionHouseFrame, so the Auction House tab code can be exercised.
    /// Requires <paramref name="withGameStubs"/>.
    /// </param>
    public LuaHarness(bool withGameStubs = false, bool withUiStubs = false)
    {
        Script = new Script(CoreModules.Preset_Complete);
        Ns = new Table(Script);
        Script.Globals["fixture"] = (Func<string, DynValue>)LoadFixture;

        if (withGameStubs)
        {
            var data = LoadFixture("AuctionData");
            var stubs = LoadChunk(File.ReadAllText(FixturePath("WoWGlobals.lua")), "WoWGlobals.lua");
            Script.Globals["data"] = data;
            Script.Globals["game"] = Script.Call(stubs, data);
            if (withUiStubs)
            {
                var ui = LoadChunk(File.ReadAllText(FixturePath("WoWUIStubs.lua")), "WoWUIStubs.lua");
                Script.Globals["ui"] = Script.Call(ui, Script.Globals["game"]);
            }
        }

        foreach (var relative in Toc.ReadFiles())
        {
            if (!relative.EndsWith(".lua", StringComparison.OrdinalIgnoreCase))
            {
                continue; // XML templates are only meaningful inside the client
            }
            if (!withGameStubs && GameOnlyFiles.Contains(Path.GetFileName(relative)))
            {
                continue;
            }
            LoadAddonFile(relative);
        }

        var fakes = LoadChunk(File.ReadAllText(FixturePath("FakeWoW.lua")), "FakeWoW.lua");
        Script.Globals["Fake"] = Script.Call(fakes, Ns);
    }

    public static string RepoRoot
    {
        get
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir != null && !File.Exists(Path.Combine(dir.FullName, "VendorSniper", "VendorSniper.toc")))
            {
                dir = dir.Parent;
            }
            return dir?.FullName ?? throw new InvalidOperationException("Repository root (VendorSniper/VendorSniper.toc) not found.");
        }
    }

    public static string AddonRoot => Path.Combine(RepoRoot, "VendorSniper");

    public static string FixturePath(string name) => Path.Combine(AppContext.BaseDirectory, "TestFixtures", name);

    private DynValue LoadChunk(string code, string chunkName) => Script.LoadString(code, null, chunkName);

    private void LoadAddonFile(string relative)
    {
        var path = Path.Combine(AddonRoot, relative.Replace('\\', Path.DirectorySeparatorChar));
        var chunk = LoadChunk(File.ReadAllText(path), relative);
        Script.Call(chunk, AddonName, Ns);
    }

    private DynValue LoadFixture(string name)
    {
        var chunk = LoadChunk(File.ReadAllText(FixturePath(name + ".lua")), name);
        return Script.Call(chunk, Ns);
    }

    /// <summary>Runs a Lua snippet with <c>ns</c> in scope and returns its first result.</summary>
    public DynValue Run(string code)
    {
        var chunk = LoadChunk("local ns = ...\n" + code, "test");
        return Script.Call(chunk, Ns);
    }

    public double Number(string code) => Run(code).Number;

    public string? String(string code)
    {
        var v = Run(code);
        return v.IsNil() ? null : v.CastToString();
    }

    public bool Bool(string code) => Run(code).CastToBool();

    public bool IsNil(string code) => Run(code).IsNil();
}

/// <summary>Reads the file list from VendorSniper.toc.</summary>
public static class Toc
{
    public static string Path_ => System.IO.Path.Combine(LuaHarness.AddonRoot, "VendorSniper.toc");

    public static IReadOnlyList<string> ReadFiles() =>
        File.ReadAllLines(Path_)
            .Select(l => l.Trim())
            .Where(l => l.Length > 0 && !l.StartsWith('#'))
            .ToList();

    public static IReadOnlyDictionary<string, string> ReadMetadata() =>
        File.ReadAllLines(Path_)
            .Where(l => l.StartsWith("## "))
            .Select(l => l[3..].Split(':', 2))
            .ToDictionary(p => p[0].Trim(), p => p.Length > 1 ? p[1].Trim() : "");
}
