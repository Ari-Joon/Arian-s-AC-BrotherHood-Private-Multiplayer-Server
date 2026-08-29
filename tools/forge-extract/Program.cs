// Extract a .forge into its Extracted\<name> folder of .data containers,
// without the AnvilToolkit GUI.
//
// This is the step that was missing. anvil-unpack handles .data containers and
// anvil-repack can write a .forge back, but forge -> .data was GUI-only, which
// blocked any automated pass over the map archives.
//
// ForgeFile.Deserialize(folder, fileName, Game, CreateCache, FileListCache)
// mirrors the Serialize(folder, fileName, Game) that anvil-repack already uses.
// The output folder convention matches what anvil-repack --forge expects:
//     <dir>\Extracted\<forge file name>
//
// HashedData.CheckStrings() must run first or writing files throws inside
// GetHashedString - the same trap anvil-unpack documents.
using System;
using System.IO;
using System.Linq;
using System.Reflection;

class Program
{
    static string KIT = Environment.GetEnvironmentVariable("ANVILKIT") ??
        @"C:\Users\akcar\OneDrive\Desktop\Projects\Private Assassins Creed Brother server\AnvilKit";

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
        if (argv.Length == 0) { Console.WriteLine("usage: forge-extract <file.forge ...>"); return 2; }

        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
        var forges = argv.Select(Path.GetFullPath).ToArray();
        Directory.SetCurrentDirectory(KIT);
        var asm = Assembly.LoadFrom(Path.Combine(KIT, "AnvilToolkit.dll"));
        Type[] types;
        try { types = asm.GetTypes(); }
        catch (ReflectionTypeLoadException ex) { types = ex.Types.Where(t => t != null).ToArray(); }

        types.FirstOrDefault(t => t.FullName == "AnvilToolkit.Utils.HashedData")
             ?.GetMethod("CheckStrings", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static)
             ?.Invoke(null, null);
        var gameT = types.First(t => t.Name == "Game" && t.IsEnum);
        var game = Enum.Parse(gameT, "Brotherhood");
        var ffT = types.First(t => t.FullName == "AnvilToolkit.FileTypes.AnvilNext.Containers.ForgeFile");
        var des = ffT.GetMethod("Deserialize", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);

        int bad = 0;
        foreach (var forge in forges)
        {
            if (!File.Exists(forge)) { Console.Error.WriteLine($"missing: {forge}"); bad++; continue; }

            // Read-only on the forge, but refuse if something holds it: a partial
            // read is worse than no read, and the game keeps several open.
            try { using var probe = File.Open(forge, FileMode.Open, FileAccess.Read, FileShare.Read); }
            catch { Console.Error.WriteLine($"  LOCKED, skipping: {Path.GetFileName(forge)}"); bad++; continue; }

            // Deserialize appends the forge's own name to the folder it is given,
            // so pass the PARENT. Passing the full path yields
            // Extracted\<name>\<name>\ and a caller that looks one level up
            // sees an empty directory and calls a successful extract a failure.
            var parent = Path.Combine(Path.GetDirectoryName(forge), "Extracted");
            var outDir = Path.Combine(parent, Path.GetFileName(forge));
            if (Directory.Exists(outDir) && Directory.GetFiles(outDir).Length > 0)
            {
                Console.WriteLine($"  already extracted: {Path.GetFileName(forge)} ({Directory.GetFiles(outDir).Length} files)");
                continue;
            }
            Console.WriteLine($"extracting {Path.GetFileName(forge)} ({new FileInfo(forge).Length:N0} bytes)");
            try
            {
                var ff = Activator.CreateInstance(ffT);
                des.Invoke(ff, new object[] { parent, forge, game, false, false });
                var n = Directory.Exists(outDir) ? Directory.GetFiles(outDir, "*.data").Length : 0;
                Console.WriteLine(n > 0 ? $"  {n} containers -> {outDir}"
                                        : "  FAILED: no containers written");
                if (n == 0) bad++;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"  FAILED: {ex.InnerException?.Message ?? ex.Message}");
                bad++;
            }
        }
        return bad > 0 ? 1 : 0;
    }
}
