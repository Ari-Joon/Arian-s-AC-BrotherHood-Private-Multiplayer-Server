// Dump AnvilToolkit type members matching a filter.
//
// Reading a container is solved; WRITING one needs a compressor, and the only
// way to find its real signature is to ask the assembly. The toolkit's
// metadata mentions lzo1x_1_compress and lzo1x_999_compress, so one exists -
// this prints how to call it rather than guessing at argument order, which
// with LZO means an access violation rather than an exception.
//
//   dotnet run --project tools/anvil-reflect -- Compress
//   dotnet run --project tools/anvil-reflect -- CompressedFileData --members
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

    static string Sig(MethodInfo m) =>
        $"{(m.IsStatic ? "static " : "")}{m.ReturnType.Name} {m.Name}(" +
        string.Join(", ", m.GetParameters().Select(p => $"{p.ParameterType.Name} {p.Name}")) + ")";

    static int Main(string[] argv)
    {
        if (argv.Length < 1) { Console.WriteLine("usage: anvil-reflect <filter> [--members]"); return 2; }
        string filter = argv[0];
        bool members = argv.Contains("--members");

        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
        Directory.SetCurrentDirectory(KIT);
        var asm = Assembly.LoadFrom(Path.Combine(KIT, "AnvilToolkit.dll"));

        Type[] types;
        // A partial type-load is normal here: the toolkit pulls in WPF and
        // native interop pieces that are irrelevant to compression. Keep what
        // loaded rather than failing on what did not.
        try { types = asm.GetTypes(); }
        catch (ReflectionTypeLoadException ex) { types = ex.Types.Where(t => t != null).ToArray(); }

        int shown = 0;
        foreach (var t in types)
        {
            bool typeHit = t.FullName != null &&
                           t.FullName.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0;
            var hits = t.GetMethods(BindingFlags.Public | BindingFlags.NonPublic |
                                    BindingFlags.Static | BindingFlags.Instance |
                                    BindingFlags.DeclaredOnly)
                        .Where(m => typeHit || m.Name.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0)
                        .ToArray();
            if (!hits.Any() && !(typeHit && members)) continue;

            Console.WriteLine($"TYPE {t.FullName}");
            foreach (var m in hits.Take(40)) { Console.WriteLine("   " + Sig(m)); shown++; }
            if (members)
            {
                foreach (var f in t.GetFields(BindingFlags.Public | BindingFlags.NonPublic |
                                              BindingFlags.Instance | BindingFlags.Static |
                                              BindingFlags.DeclaredOnly).Take(30))
                    Console.WriteLine($"   field {f.FieldType.Name} {f.Name}");
            }
            Console.WriteLine();
        }
        Console.WriteLine($"{shown} method(s) matched \"{filter}\"");
        return 0;
    }
}
