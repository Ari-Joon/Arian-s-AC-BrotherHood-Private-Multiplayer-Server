// Repack Anvil .data containers and .forge archives without the GUI.
//
// This is the write half of tools/anvil-unpack, and it is destructive: it
// overwrites files inside your game installation. Two safety nets:
//
//   * A backup is taken before each container is written, via AnvilToolkit's
//     own CreateBackup, into the Backups folder beside the container.
//   * Steam file verification restores anything that goes wrong. The forge is
//     a shipped game file, so nothing here is unrecoverable.
//
// ORDER MATTERS. Repack inner .data containers FIRST, then the .forge. The
// forge gathers up the .data files as they are on disk, so doing the forge
// first just re-packs the originals and silently discards your edits.
//
// CLOSE THE GAME AND ANVILTOOLKIT FIRST. Both hold the forge open, and a
// repack against an open forge fails silently - no error, no log line, and a
// file that looks written but is not. That failure mode has bitten this
// project twice.
//
// USAGE
//   dotnet run --project tools/anvil-repack -- --data <file.data ...>
//   dotnet run --project tools/anvil-repack -- --data-all <extracted-dir> [--only-modified]
//   dotnet run --project tools/anvil-repack -- --forge <file.forge>
//
// --only-modified repacks a container only when a file inside its unpacked
// folder is newer than the container itself, which is the usual case after a
// recolour and avoids rewriting 60 untouched archives.
//
// No game assets are redistributed; this reads and writes your own install.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;

class Program
{
    static string KIT = Environment.GetEnvironmentVariable("ANVILKIT") ??
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "AnvilKit"));

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

    static Type[] types;
    static object game;

    static int Main(string[] argv)
    {
        if (argv.Length == 0)
        {
            Console.WriteLine("usage: anvil-repack --data <f.data ...> | --data-all <dir> [--only-modified] | --forge <f.forge>");
            return 2;
        }
        if (!Directory.Exists(KIT)) { Console.Error.WriteLine($"AnvilKit not found at {KIT}"); return 2; }

        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
        Directory.SetCurrentDirectory(KIT);
        var asm = Assembly.LoadFrom(Path.Combine(KIT, "AnvilToolkit.dll"));
        try { types = asm.GetTypes(); }
        catch (ReflectionTypeLoadException ex) { types = ex.Types.Where(t => t != null).ToArray(); }

        // Without this, writing files throws inside GetHashedString.
        types.FirstOrDefault(t => t.FullName == "AnvilToolkit.Utils.HashedData")
             ?.GetMethod("CheckStrings", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static)
             ?.Invoke(null, null);
        var gameT = types.First(t => t.Name == "Game" && t.IsEnum);
        game = Enum.Parse(gameT, "Brotherhood");

        var mode = argv[0];
        if (mode == "--forge")
            return RepackForge(argv[1]);

        var files = new List<string>();
        if (mode == "--data-all")
        {
            var dir = argv[1];
            bool onlyMod = argv.Contains("--only-modified");
            foreach (var f in Directory.GetFiles(dir, "*.data").OrderBy(x => x))
            {
                var ex = Path.Combine(dir, "Extracted", Path.GetFileName(f));
                if (!Directory.Exists(ex)) continue;
                if (onlyMod)
                {
                    var cont = new FileInfo(f).LastWriteTimeUtc;
                    if (!Directory.GetFiles(ex).Any(x => new FileInfo(x).LastWriteTimeUtc > cont)) continue;
                }
                files.Add(f);
            }
        }
        else
        {
            files.AddRange(argv.Where(a => a.EndsWith(".data", StringComparison.OrdinalIgnoreCase) && File.Exists(a)));
        }

        if (files.Count == 0) { Console.WriteLine("nothing to repack"); return 1; }
        Console.WriteLine($"repacking {files.Count} container(s)\n");
        int ok = 0, bad = 0;
        foreach (var f in files)
        {
            if (RepackData(f)) ok++; else bad++;
        }
        Console.WriteLine($"\n{ok} repacked, {bad} failed");
        return bad > 0 ? 1 : 0;
    }

    static bool RepackData(string file)
    {
        var dir = Path.GetDirectoryName(file);
        var extracted = Path.Combine(dir, "Extracted", Path.GetFileName(file));
        if (!Directory.Exists(extracted))
        {
            Console.WriteLine($"  skip    {Path.GetFileName(file)} (not unpacked)");
            return true;
        }
        var before = new FileInfo(file).Length;
        var beforeHash = Hash(file);
        try
        {
            var dfT = types.First(t => t.FullName == "AnvilToolkit.FileTypes.AnvilNext.Containers.DataFile");

            // The (fileName, Game, batch) constructor sees an existing unpacked
            // folder and SKIPS loading, which leaves Serialize with nothing to
            // write - it prints "This data file is not unpacked!" and returns
            // without touching the file. Build the metadata explicitly instead
            // and use the overload that takes the extracted folder.
            object oldMeta;
            using (var rs = File.OpenRead(file))
            using (var rb = new BinaryReader(rs))
            {
                var gm = dfT.GetMethod("GetMetaData", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static);
                oldMeta = gm.Invoke(null, new object[] { rb, game });
            }

            var ctor = dfT.GetConstructors(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)
                          .First(c => c.GetParameters().Length == 1);
            var df = ctor.Invoke(new object[] { game });
            dfT.GetProperty("ExtractFolder").SetValue(df, extracted);
            dfT.GetProperty("Version").SetValue(df, game);

            var backupDir = Path.Combine(dir, "Backups");
            Directory.CreateDirectory(backupDir);
            var backup = Path.Combine(backupDir, Path.GetFileName(file));
            if (!File.Exists(backup)) File.Copy(file, backup);

            var ser = dfT.GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)
                .First(m => m.Name == "Serialize" && m.GetParameters().Length == 4
                         && m.GetParameters()[0].ParameterType == typeof(Stream));
            var tmp = file + ".new";
            using (var os = File.Create(tmp))
                ser.Invoke(df, new object[] { os, extracted, oldMeta, false });

            var written = new FileInfo(tmp).Length;
            if (written < 64) { File.Delete(tmp); Console.WriteLine($"  FAILED  {Path.GetFileName(file)} (wrote {written} bytes)"); return false; }
            File.Delete(file);
            File.Move(tmp, file);

            var after = new FileInfo(file).Length;
            // A repack that changes nothing is a silent failure, not a success.
            if (Hash(file) == beforeHash)
            {
                Console.WriteLine($"  UNCHANGED {Path.GetFileName(file)} - repack did not take");
                return false;
            }
            Console.WriteLine($"  ok      {Path.GetFileName(file)}  {before} -> {after} bytes");
            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"  FAILED  {Path.GetFileName(file)}: {ex.InnerException?.Message ?? ex.Message}");
            return false;
        }
    }

    static string Hash(string path)
    {
        using var md5 = System.Security.Cryptography.MD5.Create();
        using var fs = File.OpenRead(path);
        return Convert.ToHexString(md5.ComputeHash(fs));
    }

    static int RepackForge(string forge)
    {
        var folder = Path.Combine(Path.GetDirectoryName(forge), "Extracted", Path.GetFileName(forge));
        if (!Directory.Exists(folder)) { Console.Error.WriteLine($"not unpacked: {folder}"); return 2; }
        var before = new FileInfo(forge).Length;
        var beforeHash = Hash(forge);

        // Write to a sibling temp name and only swap it in on success. A repack
        // against a forge held open by the game or AnvilToolkit fails silently -
        // no error, no log line - so writing in place risks leaving a 500 MB
        // file half-written. This way the original is untouched unless the new
        // one is complete and different.
        var tmp = forge + ".new";
        if (File.Exists(tmp)) File.Delete(tmp);
        Console.WriteLine($"repacking {Path.GetFileName(forge)} from {folder}");
        Console.WriteLine($"  {before:N0} bytes before; large forges take several minutes");
        try
        {
            var ffT = types.First(t => t.FullName == "AnvilToolkit.FileTypes.AnvilNext.Containers.ForgeFile");
            var ff = Activator.CreateInstance(ffT);
            var ser = ffT.GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)
                         .First(m => m.Name == "Serialize" && m.GetParameters().Length == 3);
            var task = ser.Invoke(ff, new object[] { folder, tmp, game });
            if (task is System.Threading.Tasks.Task t) t.GetAwaiter().GetResult();

            if (!File.Exists(tmp)) { Console.WriteLine("  FAILED: nothing was written"); return 1; }
            var written = new FileInfo(tmp).Length;
            if (written < before / 2)
            {
                Console.WriteLine($"  FAILED: wrote only {written:N0} bytes against {before:N0}; leaving the original alone");
                File.Delete(tmp);
                return 1;
            }
            File.Replace(tmp, forge, forge + ".bak", true);
            var after = new FileInfo(forge).Length;
            if (Hash(forge) == beforeHash)
            {
                Console.WriteLine("  UNCHANGED: the repack did not take");
                return 1;
            }
            Console.WriteLine($"  done: {before:N0} -> {after:N0} bytes (previous kept as {Path.GetFileName(forge)}.bak)");
            return 0;
        }
        catch (Exception ex)
        {
            if (File.Exists(tmp)) File.Delete(tmp);
            Console.WriteLine($"  FAILED: {ex.InnerException?.Message ?? ex.Message}");
            return 1;
        }
    }

}
