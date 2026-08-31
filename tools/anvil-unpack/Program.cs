// Unpack Anvil .data containers without the AnvilToolkit GUI.
//
// WHY THIS EXISTS
// The container codec resisted every standard decompressor: LZ4, zlib, raw
// deflate, gzip, bz2, LZMA in three forms, and a hand-written LZO1X - none
// reproduced the declared uncompressed size. AnvilToolkit's own tables say why
// the last one nearly worked: GetCompressionAlgorithm(1, 2, Brotherhood)
// returns LZO1X, so the codec was right and the implementation was not.
//
// Rather than keep reimplementing it, this calls AnvilToolkit's code directly.
// It is .NET 9, so a small reflection host can drive DataFile.Deserialize and
// get exactly what the GUI produces. That turns unpacking from a per-file
// manual click into a batch operation.
//
// TWO THINGS THE GUI DOES AT STARTUP THAT A HOST MUST DO ITSELF
//   1. HashedData.CheckStrings() populates the ID-to-name table. Without it,
//      GetHashedString throws a NullReferenceException while writing files and
//      the unpack silently produces an empty folder.
//   2. Do NOT pre-create the output folder. DataFile treats an existing folder
//      as "already unpacked" and skips.
//
// USAGE
//   dotnet run --project tools/anvil-unpack -- <file.data> [more.data ...]
//   dotnet run --project tools/anvil-unpack -- --all <forge-extracted-dir>
//   dotnet run --project tools/anvil-unpack -- --all <dir> --filter _Set
//   ... --force   re-unpack even if the output folder exists
//
// No game assets are redistributed; this reads your own installation.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;

class Program
{
    // AnvilToolkit ships alongside this repo; override with ANVILKIT.
    static string KIT = Environment.GetEnvironmentVariable("ANVILKIT") ??
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "AnvilKit"));

    // Resource type IDs -> the extensions AnvilToolkit's GUI writes. The tool
    // resolves these from tables we cannot reach from outside the app, so the
    // few that matter are mapped here and anything unknown keeps its numeric
    // extension rather than being given a wrong one.
    static readonly Dictionary<string, string> EXT = new() {
        { "2729961751", "TextureMap" },
        { "3608045168", "TextureSet" },
    };

    static Assembly Resolve(object s, ResolveEventArgs e)
    {
        var n = new AssemblyName(e.Name).Name + ".dll";
        foreach (var d in new[] { Path.Combine(KIT, "Libs"), KIT })
        {
            var p = Path.Combine(d, n);
            if (File.Exists(p)) { try { return Assembly.LoadFrom(p); } catch { } }
        }
        return null;
    }

    static int Main(string[] argv)
    {
        if (argv.Length == 0) { Console.WriteLine("usage: anvil-unpack <file.data ...> | --all <dir> [--filter TEXT] [--force]"); return 2; }
        if (!Directory.Exists(KIT)) { Console.Error.WriteLine($"AnvilKit not found at {KIT}; set ANVILKIT"); return 2; }

        bool force = argv.Contains("--force");
        string filter = null;
        var fi = Array.IndexOf(argv, "--filter");
        if (fi >= 0 && fi + 1 < argv.Length) filter = argv[fi + 1];

        var files = new List<string>();
        var ai = Array.IndexOf(argv, "--all");
        if (ai >= 0 && ai + 1 < argv.Length)
        {
            foreach (var f in Directory.GetFiles(argv[ai + 1], "*.data").OrderBy(x => x))
                if (filter == null || Path.GetFileName(f).Contains(filter)) files.Add(f);
        }
        else
        {
            foreach (var a in argv)
                if (a.EndsWith(".data", StringComparison.OrdinalIgnoreCase) && File.Exists(a)) files.Add(a);
        }
        if (files.Count == 0) { Console.WriteLine("nothing to do"); return 1; }

        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
        Directory.SetCurrentDirectory(KIT);
        var asm = Assembly.LoadFrom(Path.Combine(KIT, "AnvilToolkit.dll"));
        Type[] types;
        try { types = asm.GetTypes(); }
        catch (ReflectionTypeLoadException ex) { types = ex.Types.Where(t => t != null).ToArray(); }

        // Without this the unpack writes nothing and reports a null reference.
        types.FirstOrDefault(t => t.FullName == "AnvilToolkit.Utils.HashedData")
             ?.GetMethod("CheckStrings", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static)
             ?.Invoke(null, null);

        var gameT = types.First(t => t.Name == "Game" && t.IsEnum);
        var game = Enum.Parse(gameT, "Brotherhood");
        var dfT = types.First(t => t.FullName == "AnvilToolkit.FileTypes.AnvilNext.Containers.DataFile");
        var ctor = dfT.GetConstructors(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)
                      .First(c => c.GetParameters().Length == 1 && c.GetParameters()[0].ParameterType == gameT);
        var des = dfT.GetMethods().First(m => m.Name == "Deserialize" && m.GetParameters().Length == 1
                                           && m.GetParameters()[0].ParameterType == typeof(string));

        int done = 0, skipped = 0, failed = 0;
        foreach (var file in files)
        {
            var outDir = Path.Combine(Path.GetDirectoryName(file), "Extracted", Path.GetFileName(file));
            if (Directory.Exists(outDir) && !force)
            {
                // A non-empty folder is treated as already unpacked. Note that a
                // PARTIAL unpack looks identical to a complete one here, so a
                // re-run will NOT repair it - and anvil-repack will then write a
                // truncated container from the fragment. Use --force to redo one.
                if (Directory.GetFiles(outDir).Length > 0) { skipped++; continue; }
                Directory.Delete(outDir, true);          // empty folder from a failed run
            }
            else if (Directory.Exists(outDir)) Directory.Delete(outDir, true);

            try
            {
                var df = ctor.Invoke(new object[] { game });
                dfT.GetProperty("ExtractFolder").SetValue(df, outDir);
                dfT.GetProperty("Version").SetValue(df, game);
                foreach (var pn in new[] { "Cache", "FileListCache", "Batch" })
                {
                    var pi = dfT.GetProperty(pn);
                    if (pi != null && pi.CanWrite) pi.SetValue(df, false);
                }
                des.Invoke(df, new object[] { file });

                int renamed = 0, wrote = 0;
                if (Directory.Exists(outDir))
                    foreach (var f in Directory.GetFiles(outDir))
                    {
                        wrote++;
                        var ext = Path.GetExtension(f).TrimStart('.');
                        if (EXT.TryGetValue(ext, out var name))
                        {
                            var target = Path.ChangeExtension(f, name);
                            if (!File.Exists(target)) { File.Move(f, target); renamed++; }
                        }
                    }
                if (wrote == 0) { Console.WriteLine($"  FAILED  {Path.GetFileName(file)} (no output)"); failed++; }
                else { Console.WriteLine($"  ok      {Path.GetFileName(file)}  {wrote} files, {renamed} named"); done++; }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"  FAILED  {Path.GetFileName(file)}: {ex.InnerException?.Message ?? ex.Message}");
                failed++;
            }
        }
        Console.WriteLine($"\n{done} unpacked, {skipped} already present, {failed} failed");
        return failed > 0 ? 1 : 0;
    }
}
