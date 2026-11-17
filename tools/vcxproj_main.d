// -*- D -*-
// Command line front end for visuald.vcxproj, mirroring tools/visuald2vcxproj.py.
//
//   dmd -m64 -I. -o- -of=vcxproj_conv.exe tools/vcxproj_main.d
//
// The library does the work; this file only parses the arguments and prints what the
// Python tool prints.
module vcxproj_main;

import std.conv : text;
import std.stdio : stderr, stdout;
import std.string : indexOf;

import visuald.vcxproj;

private enum string USAGE =
	"usage: vcxproj_main [-h] [--out OUT] [--name NAME] [--sln SLN] [--msbuild-dir DIR]"
	~ " [--project-refs] [--keep-defaults] [--no-filters] [--no-native-tools]"
	~ " [--update-solution] [--dry-run] [--report REPORT] project";

private int usageError(string msg)
{
	stderr.writeln(USAGE);
	stderr.writeln("vcxproj_main: error: " ~ msg);
	return 2;
}

private int helpText()
{
	stdout.writeln(USAGE);
	stdout.writeln("");
	stdout.writeln("Convert a Visual D project (.visualdproj) into a native MSBuild project (.vcxproj).");
	stdout.writeln("");
	stdout.writeln("positional arguments:");
	stdout.writeln("  project         the .visualdproj file to convert");
	stdout.writeln("");
	stdout.writeln("options:");
	stdout.writeln("  -h, --help      show this help message and exit");
	stdout.writeln("  --out OUT       output directory (default: next to the project)");
	stdout.writeln("  --name NAME     project/file name to use (default: the project file's name)");
	stdout.writeln("  --sln SLN       solution to resolve $(SolutionDir) and the project references");
	stdout.writeln("  --msbuild-dir DIR");
	stdout.writeln("                  directory with dmd.xml/dcompile_defaults.props");
	stdout.writeln("  --project-refs  emit ProjectReference items instead of linking the built libraries");
	stdout.writeln("  --keep-defaults keep every property, also the ones a vcxproj inherits");
	stdout.writeln("  --no-filters    do not write the .vcxproj.filters file");
	stdout.writeln("  --no-native-tools");
	stdout.writeln("                  do not generate Midl/ResourceCompile items for .idl and .rc files");
	stdout.writeln("  --update-solution");
	stdout.writeln("                  point the solution's project entry at the generated .vcxproj");
	stdout.writeln("  --dry-run       report what would be written, write nothing");
	stdout.writeln("  --report REPORT");
	stdout.writeln("                  also write the report to this file");
	return 0;
}

int main(string[] argv)
{
	string project, outDir, name, sln, msbuildDir, reportFile;
	bool projectRefs, keepDefaults, noFilters, noNativeTools, updateSolution, dryRun;

	for (size_t i = 1; i < argv.length; ++i)
	{
		string arg = argv[i];
		string opt = arg, val;
		bool hasVal = false;
		if (arg.length > 2 && arg[0 .. 2] == "--")
		{
			size_t eq = indexOf(arg, '=');
			if (eq != size_t.max)
			{
				opt = arg[0 .. eq];
				val = arg[eq + 1 .. $];
				hasVal = true;
			}
		}

		string take()
		{
			if (hasVal)
				return val;
			if (i + 1 >= argv.length)
				return null;
			++i;
			return argv[i];
		}

		switch (opt)
		{
			case "-h":
			case "--help":
				return helpText();
			case "--out":
				outDir = take();
				if (outDir is null)
					return usageError("argument --out: expected one argument");
				break;
			case "--name":
				name = take();
				if (name is null)
					return usageError("argument --name: expected one argument");
				break;
			case "--sln":
				sln = take();
				if (sln is null)
					return usageError("argument --sln: expected one argument");
				break;
			case "--msbuild-dir":
				msbuildDir = take();
				if (msbuildDir is null)
					return usageError("argument --msbuild-dir: expected one argument");
				break;
			case "--report":
				reportFile = take();
				if (reportFile is null)
					return usageError("argument --report: expected one argument");
				break;
			case "--project-refs":
				projectRefs = true;
				break;
			case "--keep-defaults":
				keepDefaults = true;
				break;
			case "--no-filters":
				noFilters = true;
				break;
			case "--no-native-tools":
				noNativeTools = true;
				break;
			case "--update-solution":
				updateSolution = true;
				break;
			case "--dry-run":
				dryRun = true;
				break;
			default:
				if (arg.length > 1 && arg[0] == '-')
					return usageError("unrecognized arguments: " ~ arg);
				if (project.length)
					return usageError("unrecognized arguments: " ~ arg);
				project = arg;
				break;
		}
	}

	if (!project.length)
		return usageError("the following arguments are required: project");

	ConvertOptions opt;
	opt.outDir = outDir;
	opt.name = name;
	opt.slnPath = sln;
	opt.msbuildDir = msbuildDir;
	opt.projectRefs = projectRefs;
	opt.keepDefaults = keepDefaults;
	opt.writeFilters = !noFilters;
	opt.nativeTools = !noNativeTools;
	opt.updateSolution = updateSolution;
	opt.dryRun = dryRun;

	try
	{
		ConvertResult res = convertVisualDProject(project, opt);

		// Python writes the console text through TextIOWrapper, which translates
		// "\n" into "\r\n" on Windows.
		stdout.write(crlf(res.report));

		if (!res.dryRun)
		{
			stdout.writeln("wrote   : " ~ res.vcxprojPath ~ " ("
				~ text(res.vcxprojChars) ~ " bytes)");
			if (res.filtersPath.length)
				stdout.writeln("wrote   : " ~ res.filtersPath ~ " ("
					~ text(res.filtersChars) ~ " bytes)");
		}
		if (reportFile.length)
		{
			writeReportFile(reportFile, res.reportOnly);
			stdout.writeln("report  : " ~ reportFile);
		}
		return 0;
	}
	catch (Exception e)
	{
		stderr.writeln(e.msg);
		return 1;
	}
}

/// Python's open(path, "w", encoding="utf-8", newline="\r\n").
private void writeReportFile(string path, string content)
{
	import std.file : write;
	write(path, cast(ubyte[])crlf(content));
}

/// Translate the "\n" line endings of a UTF-8 string the way Python's text mode does.
/// Scanning bytes is safe: 0x0A never occurs inside a multi byte UTF-8 sequence.
private string crlf(string s)
{
	enum char LF = '\n';
	if (indexOf(s, "\r") >= 0)
		return s;
	char[] res;
	res.length = s.length + 64;
	size_t n = 0;
	foreach (ubyte b; cast(ubyte[])s)
	{
		if (n + 2 > res.length)
			res.length = res.length * 2;
		if (b == LF)
		{
			res[n++] = '\r';
			res[n++] = '\n';
		}
		else
			res[n++] = cast(char)b;
	}
	return cast(string)res[0 .. n];
}
