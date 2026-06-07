using dnlib.DotNet;
using System;

if (args.Length != 4)
{
    Console.WriteLine("Usage: AssemblyPatcher <in.dll> <reference> <version> <out.dll>");
    return;
}

var inputPath = args[0];
var refname = args[1];
var version = args[2];
var outputPath = args[3];

var module = ModuleDefMD.Load(inputPath);

foreach (var asmRef in module.GetAssemblyRefs())
{
    if (asmRef.Name == refname)
    {
        Console.WriteLine("Patching reference to " + refname + " to " + version + "...");
        asmRef.Version = Version.Parse(version);
    }
}

module.Write(outputPath);

