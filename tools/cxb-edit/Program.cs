// Read and WRITE the gamesettings .cxb the server hands to clients.
//
// WHY THIS MATTERS
// QuazalWV's PersistentStoreService serves this exact file:
//
//     const string fileName = "gamesettings_c1380_d873_s6285.cxb";
//     Content = File.ReadAllBytes(fileName);
//
// Every client asks for it on connect and plays by what it contains - ability
// cooldowns, ranges, durations, and per-mode rules including match timers. So
// this is SERVER-AUTHORITATIVE: edit it once on the host and everyone who
// joins inherits the change. No client-side forge patching, and no game asset
// has to be handed to anyone.
//
// CONTAINER LAYOUT (verified against the live file, 58,484 bytes)
//   0        28 records x 40 bytes: name[32] NUL-padded, size[8] ASCII decimal
//   1120     1 trailer record, 40 bytes, "781866825" - preserved verbatim
//   1160     payloads, in record order, each exactly its declared size
//   payload  u32 uncompressed size, then a chunk (magic 33 AA FB 57 99 FA 04 10)
// Declared sizes total 57,324, and 58,484 - 1120 - 40 = 57,324 exactly.
//
// THE TRAILER IS THE ONE UNKNOWN. "781866825" may be a checksum over the
// payloads, in which case an edit needs it recomputed and the game will reject
// files until that is worked out. It is preserved untouched here. If the game
// accepts an edited file the question is settled; if it rejects one, this is
// the first thing to suspect.
//
// SAFETY. Every write backs up the original first, then VERIFIES by re-parsing
// its own output and inflating the section it just wrote. If that does not
// match the input byte for byte, nothing is written - a silently corrupt
// settings file would be served to every client that connects.
//
// USAGE
//   cxb-edit list    <file.cxb>
//   cxb-edit extract <file.cxb> <section> <out.xml>
//   cxb-edit replace <file.cxb> <section> <in.xml> [--out <file>]
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;

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

    const int REC = 40;

    class Section { public string Name; public int Size; public int Offset; }

    static Type cfdT, gameT;
    static object game;

    static List<Section> Parse(byte[] d, out int headerEnd, out byte[] trailer)
    {
        var secs = new List<Section>();
        int off = 0;
        while (off + REC <= d.Length)
        {
            string name = Encoding.ASCII.GetString(d, off, 32).TrimEnd('\0');
            string size = Encoding.ASCII.GetString(d, off + 32, 8).TrimEnd('\0');
            bool nameOk = name.Length > 0 &&
                          name.All(c => (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_');
            bool sizeOk = size.Length > 0 && size.All(char.IsDigit);
            if (!nameOk || !sizeOk) break;
            secs.Add(new Section { Name = name, Size = int.Parse(size) });
            off += REC;
        }
        headerEnd = off;
        // One trailer record follows the section records; keep it byte for byte.
        trailer = d.Skip(off).Take(REC).ToArray();
        int payload = off + REC;
        foreach (var s in secs) { s.Offset = payload; payload += s.Size; }
        return secs;
    }

    // A payload is [u32 uncompressed size][chunk]. Inflate the chunk part.
    static byte[] Inflate(byte[] d, Section s)
    {
        using (var ms = new MemoryStream(d, s.Offset + 4, s.Size - 4))
        using (var br = new BinaryReader(ms))
        {
            var ctor = cfdT.GetConstructor(new[] { typeof(BinaryReader), gameT, typeof(bool) });
            var cfd = ctor.Invoke(new object[] { br, game, false });
            return cfdT.GetProperty("Data").GetValue(cfd) as byte[];
        }
    }

    // Build a payload from raw bytes. AlgorithmOverride and TOCMode are not
    // documented anywhere, so try the plausible combinations and keep the first
    // that reads back as exactly what went in.
    static byte[] Deflate(byte[] raw, out string how)
    {
        foreach (int algo in new[] { -1, 1 })
        {
            foreach (bool toc in new[] { false, true })
            {
                try
                {
                    var cfd = Activator.CreateInstance(cfdT);
                    cfdT.GetMethod("Create").Invoke(cfd, new object[] { raw, game, algo, 0, toc, false });

                    byte[] chunk;
                    using (var ms = new MemoryStream())
                    {
                        using (var bw = new BinaryWriter(ms, Encoding.UTF8, true))
                            cfdT.GetMethod("Write").Invoke(cfd, new object[] { bw, game, algo, toc, false });
                        chunk = ms.ToArray();
                    }
                    if (chunk.Length == 0) continue;

                    var payload = new byte[4 + chunk.Length];
                    BitConverter.GetBytes(raw.Length).CopyTo(payload, 0);
                    chunk.CopyTo(payload, 4);

                    using (var vs = new MemoryStream(payload, 4, chunk.Length))
                    using (var vbr = new BinaryReader(vs))
                    {
                        var back = cfdT.GetConstructor(new[] { typeof(BinaryReader), gameT, typeof(bool) })
                                       .Invoke(new object[] { vbr, game, false });
                        var got = cfdT.GetProperty("Data").GetValue(back) as byte[];
                        if (got != null && got.Length == raw.Length && got.SequenceEqual(raw))
                        {
                            how = "algo=" + algo + " toc=" + toc;
                            return payload;
                        }
                    }
                }
                catch { }
            }
        }
        how = null;
        return null;
    }

    static int Main(string[] argv)
    {
        if (argv.Length < 2)
        {
            Console.WriteLine("usage: cxb-edit list    <file.cxb>");
            Console.WriteLine("       cxb-edit extract <file.cxb> <section> <out.xml>");
            Console.WriteLine("       cxb-edit replace <file.cxb> <section> <in.xml> [--out <file>]");
            return 2;
        }
        string cmd = argv[0];
        string file = Path.GetFullPath(argv[1]);
        if (!File.Exists(file)) { Console.Error.WriteLine("no such file: " + file); return 2; }

        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
        var data = File.ReadAllBytes(file);
        Directory.SetCurrentDirectory(KIT);
        var asm = Assembly.LoadFrom(Path.Combine(KIT, "AnvilToolkit.dll"));
        cfdT = asm.GetType("AnvilToolkit.FileTypes.AnvilNext.Containers.CompressedFileData");
        gameT = asm.GetType("AnvilToolkit.Utils.Game");
        game = Enum.Parse(gameT, "Brotherhood");

        int headerEnd;
        byte[] trailer;
        var secs = Parse(data, out headerEnd, out trailer);
        if (secs.Count == 0) { Console.Error.WriteLine("no section records - not a .cxb?"); return 1; }

        if (cmd == "list")
        {
            Console.WriteLine("  " + secs.Count + " sections, header " + headerEnd +
                              " bytes, trailer \"" + Encoding.ASCII.GetString(trailer).TrimEnd('\0') + "\"");
            Console.WriteLine(string.Format("  {0,-30}{1,9}{2,11}", "section", "packed", "unpacked"));
            foreach (var s in secs)
            {
                int usz = BitConverter.ToInt32(data, s.Offset);
                Console.WriteLine(string.Format("  {0,-30}{1,9}{2,11}", s.Name, s.Size, usz));
            }
            return 0;
        }

        if (argv.Length < 4) { Console.Error.WriteLine("section and file required"); return 2; }
        string want = argv[2];
        string path = Path.GetFullPath(argv[3]);
        var sec = secs.FirstOrDefault(x => string.Equals(x.Name, want, StringComparison.OrdinalIgnoreCase));
        if (sec == null) { Console.Error.WriteLine("no section \"" + want + "\""); return 1; }

        if (cmd == "extract")
        {
            var raw = Inflate(data, sec);
            if (raw == null || raw.Length == 0) { Console.Error.WriteLine("inflate produced nothing"); return 1; }
            File.WriteAllBytes(path, raw);
            Console.WriteLine("  " + sec.Name + ": " + sec.Size + " packed -> " + raw.Length + " bytes  ->  " + path);
            return 0;
        }

        if (cmd == "replace")
        {
            var raw = File.ReadAllBytes(path);
            string how;
            var payload = Deflate(raw, out how);
            if (payload == null)
            {
                Console.Error.WriteLine("could not produce a chunk that reads back identically - nothing written");
                return 1;
            }
            Console.WriteLine("  " + sec.Name + ": " + raw.Length + " bytes -> " + payload.Length + " packed (" + how + ")");

            var args = argv.ToList();
            int idx = args.IndexOf("--out");
            string outPath = (idx > 0 && idx + 1 < args.Count) ? Path.GetFullPath(args[idx + 1]) : file;

            byte[] built;
            using (var ms = new MemoryStream())
            {
                foreach (var s in secs)
                {
                    int size = ReferenceEquals(s, sec) ? payload.Length : s.Size;
                    var nameBytes = new byte[32];
                    Encoding.ASCII.GetBytes(s.Name).CopyTo(nameBytes, 0);
                    var sizeBytes = new byte[8];
                    Encoding.ASCII.GetBytes(size.ToString()).CopyTo(sizeBytes, 0);
                    ms.Write(nameBytes, 0, 32);
                    ms.Write(sizeBytes, 0, 8);
                }
                ms.Write(trailer, 0, trailer.Length);
                foreach (var s in secs)
                {
                    if (ReferenceEquals(s, sec)) ms.Write(payload, 0, payload.Length);
                    else ms.Write(data, s.Offset, s.Size);
                }
                built = ms.ToArray();
            }

            // Re-parse what we built and inflate the edited section back out of
            // it. This file is served to every client that connects, so a
            // silent corruption here would break all of them at once.
            int he2;
            byte[] tr2;
            var check = Parse(built, out he2, out tr2);
            var csec = check.FirstOrDefault(x => x.Name == sec.Name);
            if (csec == null) { Console.Error.WriteLine("verify: section missing from rebuilt file"); return 1; }
            var backRaw = Inflate(built, csec);
            if (backRaw == null || !backRaw.SequenceEqual(raw))
            {
                Console.Error.WriteLine("verify FAILED - nothing written");
                return 1;
            }

            if (outPath == file)
            {
                string bak = file + ".bak";
                if (!File.Exists(bak)) { File.Copy(file, bak); Console.WriteLine("  backed up to " + Path.GetFileName(bak)); }
            }
            File.WriteAllBytes(outPath, built);
            Console.WriteLine("  verified, wrote " + outPath + " (" + built.Length + " bytes, was " + data.Length + ")");
            return 0;
        }

        Console.Error.WriteLine("unknown command " + cmd);
        return 2;
    }
}
