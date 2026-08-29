// Inflate a chunk of an Anvil container - archive, OPTIONS, or a .SAV.
//
// WHY IT TAKES AN EXPLICIT OFFSET AND DOES NOT SEARCH
// LZO1X here is unbounded: a wrong offset is a fatal access violation
// (0xC0000005) that kills the process, not an exception you can catch. "Wrong
// by 4 bytes" and "wrong by 4000" crash identically, so sweeping for the right
// offset is useless as a search strategy. Read the offset out of the chunk
// header instead - magic 33 aa fb 57 99 fa 04 10, and each chunk header sits
// where the previous chunk's data ends.
//
// WHY CompressedFileData AND NOT Manager.Decompress
// The size fields in a chunk header are **per-block, not per-chunk**. The
// value at M+20 is the FIRST BLOCK's uncompressed size. A chunk is
// multi-block, so slicing the payload by hand and handing it to
// Manager.Decompress feeds LZO a stream that is not one stream, and it dies -
// even when the arithmetic looks right, because chunk boundaries computed that
// way genuinely do line up. CompressedFileData reads the block table
// (BlockInfoData) and does it properly.
//
// Verified on ACBROTHERHOODSAVEGAME0.SAV: chunk 0x0ed declares 32768 (one
// block) and inflates to 252,401 bytes, with the reader ending at 21,124 -
// exactly the file length.
//
// TWO MORE TRAPS
//   * Manager.InitializeAll() HANGS. It does not return. Never call it.
//   * Check any apparent plaintext against the raw bytes before believing it.
//     DataBlock.Read at offset 0 returns bytes identical to raw[12:...] - raw
//     passthrough - containing a readable "Options" that is in the raw file
//     anyway. It looks exactly like a decompression success.
//
// USAGE
//   dotnet run --project tools/anvil-inflate -- <file> <offset> [out] [--meta]
//     offset may be decimal or 0x-prefixed.
//     --meta passes metaData:true to the reader (default false).
//
// No game assets are redistributed; this reads your own installation.
using System;
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

    static int Main(string[] argv)
    {
        if (argv.Length < 2)
        {
            Console.WriteLine("usage: anvil-inflate <file> <offset> [out] [--meta]");
            return 2;
        }
        if (!Directory.Exists(KIT)) { Console.Error.WriteLine($"AnvilKit not found at {KIT}; set ANVILKIT"); return 2; }

        var file = argv[0];
        var offText = argv[1];
        long start = Convert.ToInt64(offText, offText.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? 16 : 10);
        bool meta = argv.Contains("--meta");
        var outPath = argv.Skip(2).FirstOrDefault(x => !x.StartsWith("--"));

        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
        Directory.SetCurrentDirectory(KIT);
        var asm = Assembly.LoadFrom(Path.Combine(KIT, "AnvilToolkit.dll"));
        var cfdT = asm.GetType("AnvilToolkit.FileTypes.AnvilNext.Containers.CompressedFileData");
        var gameT = asm.GetType("AnvilToolkit.Utils.Game");
        var game = Enum.Parse(gameT, "Brotherhood");

        using var fs = File.OpenRead(file);
        using var br = new BinaryReader(fs);
        fs.Position = start;

        var ctor = cfdT.GetConstructor(new[] { typeof(BinaryReader), gameT, typeof(bool) });
        object cfd;
        try { cfd = ctor.Invoke(new object[] { br, game, meta }); }
        catch (TargetInvocationException ex)
        {
            Console.WriteLine($"offset {start}: {ex.InnerException?.GetType().Name}: {ex.InnerException?.Message}");
            return 3;
        }

        byte[] Get(string p) => cfdT.GetProperty(p)?.GetValue(cfd) as byte[];
        var data = Get("Data");
        var usz = (int)cfdT.GetProperty("UncompressedSize").GetValue(cfd);
        Console.WriteLine($"offset {start}  declared {usz}  data {(data?.Length.ToString() ?? "null")}  " +
                          $"blockinfo {(Get("BlockInfoData")?.Length.ToString() ?? "null")}  " +
                          $"compressed {(Get("CompressedData")?.Length.ToString() ?? "null")}  " +
                          $"reader ends {fs.Position} of {fs.Length}");
        if (data == null || data.Length == 0) return 1;
        if (outPath != null)
        {
            File.WriteAllBytes(outPath, data);
            Console.WriteLine($"  wrote {outPath} ({data.Length} bytes)");
        }
        return 0;
    }
}
