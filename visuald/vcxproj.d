// Convert a Visual D ".visualdproj" into a native MSBuild ".vcxproj".
//
// The conversion is driven by three sources of truth:
//
//   visuald/config.d                 the option model and the command lines Visual D builds
//   msbuild/dmd.xml, msbuild/ldc.xml the DCompile property vocabulary of the MSBuild rules
//   msbuild/dcompile_defaults.props  the defaults a vcxproj inherits for DCompile
//
// This file is part of Visual D.
//
// Copyright (c) 2024 by Rainer Schuetze, All Rights Reserved
//
// Distributed under the Boost Software License, Version 1.0.
// See accompanying file LICENSE.txt or copy at http://www.boost.org/LICENSE_1_0.txt
module visuald.vcxproj;

import std.algorithm : canFind, endsWith, equal, filter, map, max, sort, startsWith, uniq;
import std.array : appender, array, join, replace, split;
import std.ascii : isAlpha, isAlphaNum, isDigit, isWhite;
import std.conv : ConvException, text, to;
import std.file : DirEntry, dirEntries, exists, getcwd, mkdirRecurse, read, SpanMode, write;
import std.format : format;
import std.path : baseName;
import std.range : only, walkLength;
import std.regex : matchFirst, Regex, regex, replaceAll, replaceFirst, splitter;
import std.stdio : writeln;
import std.string : indexOf, lastIndexOf, leftJustify, splitLines, startsWith, strip, toLower, toUpper;
import std.uuid : sha1UUID, urlNamespace;

import stdext.path : canonicalPath, normalizePath;

import xml = visuald.xmlwrap;


// --------------------------------------------------------------------- small helpers

/// The XML escaping of an attribute or text value; the apostrophe is left alone
/// because MSBuild writes its conditions with them.
string esc(string s)
{
	auto app = appender!string();
	foreach (char c; s)
		switch (c)
		{
			case '&': app.put("&amp;"); break;
			case '<': app.put("&lt;"); break;
			case '>': app.put("&gt;"); break;
			case '"': app.put("&quot;"); break;
			default: app.put(c); break;
		}
	return app.data;
}

/// Visual D stores booleans as 0/1 (and sometimes as an empty string).
bool flag(string v)
{
	string s = strip(v is null ? "" : v);
	return s.length != 0 && s != "0";
}

int asInt(string v, int default_ = 0)
{
	try
		return strip(v is null ? "" : v).to!int;
	catch (ConvException)
		return default_;
}

/// Split a whitespace separated option list, honouring "quoted" entries.
string[] words(string s)
{
	string[] res;
	if (s is null)
		return res;
	string cur;
	bool quoted = false;
	foreach (dchar ch; s)
	{
		if (ch == '"')
			quoted = !quoted;
		else if ((ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') && !quoted)
		{
			if (cur.length)
			{
				res ~= cur;
				cur = null;
			}
		}
		else
			cur ~= ch;
	}
	if (cur.length)
		res ~= cur;
	return res;
}

// --------------------------------------------------------------------- string scanning

dchar lowerAscii(dchar c)
{
	return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c;
}

/// The option names, macro names and paths of a .visualdproj are compared without
/// regard to case.
bool ciChar(dchar a, dchar b)
{
	return lowerAscii(a) == lowerAscii(b);
}

bool ciEqual(string a, string b)
{
	return equal!ciChar(a, b);
}

bool ciHas(const string[] set, string name)
{
	return canFind!ciEqual(set, name);
}

bool startsWithCiAt(string s, size_t i, string pat)
{
	return i + pat.length <= s.length && startsWith!ciChar(s[i .. $], pat);
}

bool endsWithCi(string s, string suffix)
{
	return s.length >= suffix.length && endsWith!ciChar(s, suffix);
}

private bool isIdentStart(char c)
{
	return c == '_' || isAlpha(cast(dchar)c);
}

private bool isIdentChar(char c)
{
	return c == '_' || isAlphaNum(cast(dchar)c);
}

// re.sub(r"(^|\\)\.($|\\)", r"\1", p)
private auto dotComponentPattern()
{
	static immutable Regex!char re = regex(`(^|\\)\.(?:$|\\)`);
	return re;
}

private string dropDotComponents(string s)
{
	return replaceAll(s, dotComponentPattern(), "$1");
}

// re.sub(r"\\{2,}", r"\\", p)
private auto backslashRunPattern()
{
	static immutable Regex!char re = regex(`\\{2,}`);
	return re;
}

private string collapseBackslashes(string s)
{
	return replaceAll(s, backslashRunPattern(), "\\");
}

/// Normalize a Windows path that may still contain $(Macros).
string macroNormpath(string p)
{
	p = normalizePath(p is null ? "" : p);
	p = dropDotComponents(p);
	p = collapseBackslashes(p);
	return p;
}

// re.sub(r"(\$\((?:outdir|intdir|...)\))\\", r"\1", p, flags=re.I)
private string dropSepAfterMacro(string s)
{
	return rewriteMacros(s, (ref MacroRef m) {
		if (m.end >= m.text.length || m.text[m.end] != '\\' || !ciHas(TRAILING_SEP_MACROS, m.name))
			return null;
		m.end += 1;
		return "$(" ~ m.name ~ ")";
	});
}

/// Collapse "." and redundant separators in a path that may contain macros.
//
/// A ".." is only folded away when the component before it is a plain folder
/// name, so "$(ProjectDir)..\\..\\bin" survives.
string normalizeMacroPath(string p)
{
	p = normalizePath(p is null ? "" : p);
	p = dropSepAfterMacro(p);
	string[] parts;
	foreach (string part; split(p, '\\'))
	{
		if (!part.length || part == ".")
			continue;
		if (part == ".." && parts.length && parts[$ - 1] != ".." &&
			!startsWith(parts[$ - 1], "$(") && indexOf(parts[$ - 1], ':') < 0)
			parts.length -= 1;
		else
			parts ~= part;
	}
	return join(parts, "\\");
}

/// An ordered string[string] map: Python dicts keep their insertion order and
/// substitute() depends on it.
final class Env
{
	string[] keys;
	string[string] vals;

	void set(string k, string v)
	{
		if (k !in vals)
			keys ~= k;
		vals[k] = v;
	}

	string get(string k, string dflt = null)
	{
		return vals.get(k, dflt);
	}

	bool has(string k)
	{
		return (k in vals) !is null;
	}

	Env dupEnv()
	{
		Env e = new Env;
		e.keys = keys.dup;
		e.vals = vals.dup;
		return e;
	}
}

/// Replace $(Macro) occurrences by their value in env (case insensitive).
string substitute(string s, Env env)
{
	// MSBuild expands a macro whose value is itself an expression of macros, so
	// repeat until nothing changes.
	foreach (pass; 0 .. 6)
	{
		string prev = s;
		s = rewriteMacros(s, (ref MacroRef m) => env.get(toLower(m.name), null));
		if (s == prev)
			break;
	}
	return s;
}

// --------------------------------------------------------------------- $(Macro) scanning

// \$\(([A-Za-z_][A-Za-z0-9_]*)\)
struct MacroRef
{
	string text;  // the string the reference was found in
	size_t begin; // the '$' of "$("
	size_t end;   // one past the ')'
	string name;  // the identifier as written
}

/// The macro references in s, in the order they appear. With spaces set, the
/// "$(\s*Name\s*)" spelling that the macro alias table uses is matched as well.
private MacroRef[] macroRefs(string s, bool spaces = false)
{
	MacroRef[] res;
	for (size_t i = 0; i < s.length; ++i)
	{
		if (s[i] != '$' || i + 1 >= s.length || s[i + 1] != '(')
			continue;
		size_t j = i + 2;
		if (spaces)
			while (j < s.length && isWhite(cast(dchar)s[j]))
				++j;
		if (j >= s.length || !isIdentStart(s[j]))
			continue;
		size_t start = j;
		while (j < s.length && isIdentChar(s[j]))
			++j;
		size_t k = j;
		if (spaces)
			while (k < s.length && isWhite(cast(dchar)s[k]))
				++k;
		if (k >= s.length || s[k] != ')')
			continue;
		res ~= MacroRef(s, i, k + 1, s[start .. j]);
		i = k;
	}
	return res;
}

/// Rewrite the macro references of s. fg returns the replacement for a reference,
/// or null to keep it as written; it may extend m.end to swallow what follows the
/// reference, and a null result then drops what it swallowed as well.
private string rewriteMacros(string s, scope string delegate(ref MacroRef m) fg, bool spaces = false)
{
	auto app = appender!string();
	size_t pos = 0;
	foreach (ref m; macroRefs(s, spaces))
	{
		if (m.begin < pos)
			continue; // an earlier rewrite already reached this reference
		string r = fg(m);
		if (r is null)
		{
			app.put(s[pos .. m.end]);
			pos = m.end;
			continue;
		}
		app.put(s[pos .. m.begin]);
		app.put(r);
		pos = m.end;
	}
	app.put(s[pos .. $]);
	return app.data;
}

// re.sub(r"\$\(\s*<name>\s*\)", "$(" + target + ")", s, flags=re.I)
private string replaceMacroAlias(string s, string name, string target)
{
	return rewriteMacros(s, (ref MacroRef m) => ciEqual(m.name, name) ? "$(" ~ target ~ ")" : null, true);
}

// re.sub(r"\$\(([A-Za-z_][A-Za-z0-9_]*)\)(\\\\|\\)", ...)
private string dropTrailingSepBackslashes(string s)
{
	return rewriteMacros(s, (ref MacroRef m) {
		size_t nsep = 0;
		if (m.end < m.text.length && m.text[m.end] == '\\')
			nsep = m.end + 1 < m.text.length && m.text[m.end + 1] == '\\' ? 2 : 1;
		if (!nsep || !ciHas(TRAILING_SEP_MACROS, m.name))
			return null;
		m.end += nsep;
		return "$(" ~ m.name ~ ")";
	});
}

// --------------------------------------------------------------------- report

final class Report
{
	string[] lossyMsgs;
	string[] unsupportedMsgs;
	string[] ignoredMsgs;
	string[] noteMsgs;

	private void add(ref string[] bucket, string msg)
	{
		if (!canFind(bucket, msg))
			bucket ~= msg;
	}

	void lossy(string msg) { add(lossyMsgs, msg); }
	void unsupported(string msg) { add(unsupportedMsgs, msg); }
	void ignored(string msg) { add(ignoredMsgs, msg); }
	void note(string msg) { add(noteMsgs, msg); }

	string text()
	{
		auto app = appender!string();
		void dump(string title, const string[] items)
		{
			if (!items.length)
				return;
			app.put(title);
			app.put(":\n");
			foreach (m; items)
			{
				app.put("  - ");
				app.put(m);
				app.put('\n');
			}
			app.put('\n');
		}
		dump("UNSUPPORTED", unsupportedMsgs);
		dump("LOSSY", lossyMsgs);
		dump("IGNORED", ignoredMsgs);
		dump("NOTES", noteMsgs);
		return app.data;
	}
}

// --------------------------------------------------------------------- msbuild defaults

/// Evaluate the subset of MSBuild conditions used by dcompile_defaults.props.
bool msbuildCondition(string cond, string[string] env)
{
	if (cond is null || cond.length == 0)
		return true;

	string expand(string text)
	{
		text = strip(text);
		if (text.length && text[0] == '\'' && text[$ - 1] == '\'')
			text = text.length > 1 ? text[1 .. $ - 1] : "";
		if (indexOf(text, '$') >= 0)
			text = expandMacroRefs(text, env);
		return text;
	}

	foreach (part; splitAnd(cond))
	{
		part = strip(part);
		if (!part.length)
			continue;
		string lhs, rhs, op;
		if (!matchConditionPart(part, lhs, op, rhs))
			return false;
		lhs = expand(lhs);
		rhs = expand(rhs);
		bool eq = ciEqual(lhs, rhs);
		if ((op == "==") != eq)
			return false;
	}
	return true;
}

// re.split(r"\s+and\s+", cond)
private auto andPattern()
{
	static immutable Regex!char re = regex(`\s+and\s+`);
	return re;
}

private string[] splitAnd(string cond)
{
	return splitter(cond, andPattern()).array;
}

// re.match(r"^(.+?)\s*(==|!=)\s*(.+)$", part)
private auto conditionPartPattern()
{
	static immutable Regex!char re = regex(`^(.+?)\s*(==|!=)\s*(.+)$`);
	return re;
}

private bool matchConditionPart(string part, out string lhs, out string op, out string rhs)
{
	lhs = op = rhs = null;
	if (auto m = matchFirst(part, conditionPartPattern()))
	{
		lhs = m.captures[1];
		op = m.captures[2];
		rhs = m.captures[3];
		return true;
	}
	return false;
}

// \$\(([A-Za-z_][A-Za-z0-9_]*)\) with env.get(name.lower(), "")
private string expandMacroRefs(string s, string[string] env)
{
	return rewriteMacros(s, (ref MacroRef m) {
		string v = env.get(toLower(m.name), null);
		return v is null ? "" : v;
	});
}

/// XML attribute values are normalized by a conforming parser: every literal
/// line break (CR, LF or a CRLF pair) and every tab in an attribute value turns
/// into a single space. stdext.xml hands out the raw text instead, and the
/// .visualdproj files the IDE writes do have multi line attributes (the custom
/// build commands of build/build.visualdproj for instance), so normalize here.
/// Character references are decoded by the reader and stay untouched, exactly
/// like they do in Python's ElementTree.
string normalizeAttr(string s)
{
	static immutable Regex!char re = regex(`\r\n|[\r\n\t]`);
	return replaceAll(s, re, " ");
}

/// xml.getAttribute with the normalization of a real XML parser applied.
string attrValue(xml.Element e, string name)
{
	string v = xml.getAttribute(e, name);
	return v is null ? null : normalizeAttr(v);
}

// --------------------------------------------------------------------- msbuild files

struct DefaultProp
{
	string name;
	string value;
	string cond; // null when the property has no Condition attribute
}

DefaultProp[] loadDcompileDefaults(string msbuildDir)
{
	string path = pathJoin(msbuildDir, "dcompile_defaults.props");
	auto doc = xml.readDocument(readText(path));
	auto root = xml.getRoot(doc);
	DefaultProp[] res;
	foreach (group; childElements(root, "ItemDefinitionGroup"))
		foreach (item; group.elements)
			foreach (prop; item.elements)
			{
				DefaultProp d;
				d.name = prop.tag.name;
				d.value = strip(elemText(prop));
				d.cond = attrValue(prop, "Condition");
				res ~= d;
			}
	return res;
}

/// {property name: rule element} the MSBuild rules define for DCompile.
string[string] loadRuleProperties(string msbuildDir)
{
	string[string] names;
	foreach (rule; only("dmd.xml", "ldc.xml"))
	{
		string path = pathJoin(msbuildDir, rule);
		if (!fileExists(path))
			continue;
		auto doc = xml.readDocument(readText(path));
		auto root = xml.getRoot(doc);
		foreach (node; iterElements(root))
		{
			if (!endsWithProp(node.tag.name))
				continue;
			string name = attrValue(node, "Name");
			if (name is null || !name.length)
				continue;
			if (!(name in names))
				names[name] = node.tag.name;
		}
	}
	return names;
}

private bool endsWithProp(string tag)
{
	return tag.length >= 8 && tag[$ - 8 .. $] == "Property";
}

// --------------------------------------------------------------------- visualdproj

final class VdConfig
{
	string name;
	string platform;
	string[string] v; // exact case option name -> value
	Meta[] dcompile; // the DCompile item of the default item definition group
	Meta[] link; // the Link item (or Lib, for a static library)
	Meta[] lib; // extra metadata for the Lib item
	Meta[] props; // UserDefined properties
	Meta[] dirs; // properties of the NMake item
	FileEvent[] events; // PreBuildEvent/PostBuildEvent/...

	this(xml.Element elem)
	{
		name = attrValue(elem, "name");
		platform = attrValue(elem, "platform");
		if (platform is null || !platform.length)
			platform = "Win32";
		foreach (ch; elem.elements)
		{
			if (ch.tag.name != "Config")
				v[ch.tag.name] = strip(elemText(ch));
		}
	}

	string get(string key, string dflt = "")
	{
		auto p = key in v;
		return p is null ? dflt : *p;
	}

	bool has(string key)
	{
		return (key in v) !is null;
	}

	string key()
	{
		return (name is null ? "None" : name) ~ "|" ~ platform;
	}

	string compiler()
	{
		switch (asInt(get("compiler")))
		{
			case 0: return "DMD";
			case 1: return "GDC";
			case 2: return "LDC";
			case 3: return "SDC";
			default: return "DMD";
		}
	}

	bool is64() { return flag(get("isX86_64")); }
	bool mscoff() { return flag(get("mscoff")); }
	int outputType() { return asInt(get("lib")); } // 0 exe, 1 static lib, 2 dll
	int model() { return asInt(get("singleFileCompilation")); }
}

final class VdProject
{
	string path;
	string dir;
	string name;
	xml.Element root;
	string guid;
	VdConfig[] configs;

	this(string projPath, string name_ = null)
	{
		path = pathAbspath(projPath);
		dir = pathDirname(path) ~ "\\";
		name = name_ is null ? pathSplitext(pathBasename(path))[0] : name_;
		root = xml.getRoot(xml.readDocument(readText(path)));
		auto e = xml.getElement(root, "ProjectGuid");
		guid = e is null ? "" : strip(elemText(e)).toUpper();
		foreach (c; childElements(root, "Config"))
			configs ~= new VdConfig(c);
	}

	VdConfig config(string key)
	{
		foreach (c; configs)
			if (c.key() == key)
				return c;
		return null;
	}
}

// --------------------------------------------------------------------- finding files

private string walkUpFor(string start, string delegate(string) test)
{
	string d = pathAbspath(start);
	while (true)
	{
		string found = test(d);
		if (found.length)
			return found;
		string parent = pathDirname(d);
		if (!parent.length || parent == d)
			return null;
		d = parent;
	}
}

string findSolution(string projectDir)
{
	string test(string d)
	{
		foreach (string f; listDirSorted(d))
			if (endsWithCi(f, ".sln") || endsWithCi(f, ".slnx"))
				return pathJoin(d, f);
		return null;
	}
	return walkUpFor(projectDir, &test);
}

// --------------------------------------------------------------------- reading files

/// Read a file the way the Python tool does: UTF-16 for a BOM, UTF-8 otherwise,
/// with invalid bytes replaced.
string readText(string path)
{
	ubyte[] data;
	try
		data = cast(ubyte[])read(path);
	catch (Exception e)
		throw new Exception("cannot read " ~ path ~ " (" ~ e.msg ~ ")");
	if (data.length >= 2 && ((data[0] == 0xFF && data[1] == 0xFE) ||
							 (data[0] == 0xFE && data[1] == 0xFF)))
		return decodeUtf16(data);
	size_t i = 0;
	if (data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF)
		i = 3;
	return utf8Replace(data[i .. $]);
}

private string decodeUtf16(ubyte[] data)
{
	bool le = data[0] == 0xFF;
	auto app = appender!string();
	size_t i = 2; // skip the BOM
	while (i + 1 < data.length)
	{
		ushort a = cast(ushort)(le ? (data[i] | (data[i + 1] << 8)) : (data[i + 1] | (data[i] << 8)));
		i += 2;
		dchar cp = a;
		if (a >= 0xD800 && a < 0xDC00 && i + 1 < data.length)
		{
			ushort b = cast(ushort)(le ? (data[i] | (data[i + 1] << 8)) : (data[i + 1] | (data[i] << 8)));
			if (b >= 0xDC00 && b < 0xE000)
			{
				cp = 0x10000 + ((cast(dchar)(a - 0xD800)) << 10) + (b - 0xDC00);
				i += 2;
			}
		}
		app.put(cp);
	}
	return app.data;
}

/// UTF-8 decode with U+FFFD for invalid bytes (Python's errors="replace").
private string utf8Replace(ubyte[] data)
{
	auto app = appender!string();
	size_t i = 0;
	while (i < data.length)
	{
		ubyte b = data[i];
		size_t n = 0;
		dchar cp = 0xFFFD;
		if (b < 0x80)
			n = 1, cp = b;
		else if ((b & 0xE0) == 0xC0 && i + 1 < data.length && isCont(data[i + 1]))
			n = 2, cp = cast(dchar)((b & 0x1F) << 6 | (data[i + 1] & 0x3F));
		else if ((b & 0xF0) == 0xE0 && i + 2 < data.length && isCont(data[i + 1]) && isCont(data[i + 2]))
			n = 3, cp = cast(dchar)((b & 0x0F) << 12 | (data[i + 1] & 0x3F) << 6 | (data[i + 2] & 0x3F));
		else if ((b & 0xF8) == 0xF0 && i + 3 < data.length && isCont(data[i + 1]) &&
				 isCont(data[i + 2]) && isCont(data[i + 3]))
			n = 4, cp = cast(dchar)((b & 0x07) << 18 | (data[i + 1] & 0x3F) << 12 |
									(data[i + 2] & 0x3F) << 6 | (data[i + 3] & 0x3F));
		else
			n = 1;
		if (cp >= 0xD800 && cp <= 0xDFFF)
			cp = 0xFFFD;
		app.put(cp);
		i += n;
	}
	return app.data;
}

private bool isCont(ubyte b)
{
	return (b & 0xC0) == 0x80;
}

// --------------------------------------------------------------------- solution files

// ^Project\("\{[^}]*\}"\)\s*=\s*"[^"]*",\s*"([^"]*)"
private bool slnProjectMatch(string line, out string path)
{
	path = null;
	static immutable Regex!char re = regex(`^Project\("\{[^}]*\}"\)\s*=\s*"[^"]*",\s*"([^"]*)"`);
	if (auto m = matchFirst(line, re))
	{
		path = m.captures[1];
		return true;
	}
	return false;
}

// re.search(r"(\{[0-9A-Fa-f-]+\})\"?\s*$", line)
private bool slnGuidSearch(string line, out string guid)
{
	guid = null;
	static immutable Regex!char re = regex(`(\{[0-9A-Fa-f-]+\})\"?\s*$`);
	if (auto m = matchFirst(line, re))
	{
		guid = m.captures[1];
		return true;
	}
	return false;
}

// re.match(r"\{([0-9A-Fa-f-]+)\}", stripped)
private bool slnGuidMatch(string line, out string guid)
{
	guid = null;
	static immutable Regex!char re = regex(`^\{[0-9A-Fa-f-]+\}`);
	if (auto m = matchFirst(line, re))
	{
		guid = m.captures[0];
		return true;
	}
	return false;
}

struct Solution
{
	string[string] projects; // guid -> path
	string[][string] deps;   // guid -> [referenced guid, ...]
}

/// Return (project guid -> path, project guid -> [referenced guid, ...]).
Solution parseSolution(string slnPath)
{
	slnPath = pathAbspath(slnPath);
	Solution sol;
	string current;
	bool inDeps = false;
	foreach (string line; splitLines(readText(slnPath)))
	{
		string p;
		if (slnProjectMatch(line, p))
		{
			string gm;
			if (slnGuidSearch(line, gm))
			{
				string full = pathAbspath(pathJoin(pathDirname(slnPath), p));
				string key = gm.toUpper();
				sol.projects[key] = full;
				current = key;
			}
			inDeps = false;
			continue;
		}
		string stripped = strip(line);
		if (startsWith(stripped, "ProjectSection(ProjectDependencies)"))
		{
			inDeps = true;
			if (current.length)
				sol.depsOfAdd(current);
			continue;
		}
		if (inDeps && stripped == "EndProjectSection")
		{
			inDeps = false;
			current = null;
			continue;
		}
		if (inDeps && current.length)
		{
			// "<dependency guid> = <project guid>"
			string dm;
			if (slnGuidMatch(stripped, dm))
				sol.depsOfAdd(current, dm.toUpper());
		}
	}
	return sol;
}

private void depsOfAdd(ref Solution sol, string guid, string dep = null)
{
	if (dep.length)
		sol.deps[guid] ~= dep;
}

// --------------------------------------------------------------------- solution references

// The project type a .sln uses for a .visualdproj, and the one it uses for a .vcxproj.
enum string slnTypeGuidVisualD = "{002A2DE9-8BB6-484D-9802-7E4AD4084715}";
enum string slnTypeGuidVcxproj = "{8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942}";

/// The quoted fields of a `Project("{type}") = "name", "path", "{guid}"` line, as
/// offsets into the whole solution text; `end` is one past the closing quote.
struct SlnProjectLine
{
	size_t typeBegin, typeEnd;
	size_t nameBegin, nameEnd;
	size_t pathBegin, pathEnd;
	size_t guidBegin, guidEnd;
	bool valid = false;
}

struct SlnRelink
{
	bool found;
	bool changed;
	string text;   // the solution text with the entry rewritten
	string name;   // the project's name in the solution
	string oldPath, newPath;
	string oldType, newType;
}

/// Point the solution entry carrying projGuid (or, failing that, the one naming
/// projPath) at newPath with the given project type. Everything else in the file
/// is left exactly as it was, including the entry's own project GUID, which is
/// what keeps its configurations, dependencies and folder nesting intact.
SlnRelink slnRelinkProject(string text, string projGuid, string projPath,
	string slnDir, string newPath, string newTypeGuid)
{
	SlnRelink res;
	string guid = projGuid.toUpper();
	SlnProjectLine hit = findProjectLine(text, (ref SlnProjectLine ln) {
		return guid.length && text[ln.guidBegin + 1 .. ln.guidEnd - 1].toUpper() == guid;
	});
	if (!hit.valid)
		hit = findProjectLine(text, (ref SlnProjectLine ln) {
			return pathNormcase(pathAbspath(pathJoin(slnDir, text[ln.pathBegin + 1 .. ln.pathEnd - 1])))
				== pathNormcase(pathAbspath(projPath));
		});
	if (!hit.valid)
		return res;
	res.found = true;

	res.name = text[hit.nameBegin + 1 .. hit.nameEnd - 1];
	res.oldPath = text[hit.pathBegin + 1 .. hit.pathEnd - 1];
	res.oldType = text[hit.typeBegin + 1 .. hit.typeEnd - 1];
	res.newPath = newPath;
	res.newType = newTypeGuid;
	if (res.oldPath == newPath && res.oldType == newTypeGuid)
	{
		res.text = text;
		return res;
	}
	res.changed = true;
	res.text = text[0 .. hit.typeBegin] ~ '"' ~ newTypeGuid ~ '"'
		~ text[hit.typeEnd .. hit.pathBegin] ~ '"' ~ newPath ~ '"'
		~ text[hit.pathEnd .. $];
	return res;
}

/// The first project header line of the solution that accept() likes.
private SlnProjectLine findProjectLine(string text, scope bool delegate(ref SlnProjectLine ln) accept)
{
	for (size_t pos = 0; pos < text.length;)
	{
		size_t nl = indexOf(text, '\n', pos);
		SlnProjectLine ln = slnProjectLineAt(text, pos, nl == size_t.max ? text.length : nl);
		if (ln.valid && accept(ln))
			return ln;
		if (nl == size_t.max)
			break;
		pos = nl + 1;
	}
	return SlnProjectLine.init;
}

/// Pick out the quoted tokens of a solution project header line, or return an
/// invalid result for any other line.
private SlnProjectLine slnProjectLineAt(string text, size_t lineStart, size_t lineEnd)
{
	SlnProjectLine r;
	size_t i = lineStart;
	while (i < lineEnd && (text[i] == ' ' || text[i] == '\t'))
		++i;
	if (i + 8 > lineEnd || text[i .. i + 8] != "Project(")
		return r;
	i += 8;
	if (!slnQuotedToken(text, i, lineEnd, r.typeBegin, r.typeEnd))
		return r;
	if (!slnQuotedToken(text, i, lineEnd, r.nameBegin, r.nameEnd))
		return r;
	if (!slnQuotedToken(text, i, lineEnd, r.pathBegin, r.pathEnd))
		return r;
	if (!slnQuotedToken(text, i, lineEnd, r.guidBegin, r.guidEnd))
		return r;
	r.valid = true;
	return r;
}

private bool slnQuotedToken(string text, ref size_t i, size_t lineEnd, out size_t begin, out size_t end)
{
	while (i < lineEnd && text[i] != '"')
		++i;
	if (i >= lineEnd)
		return false;
	begin = i;
	++i;
	while (i < lineEnd && text[i] != '"')
		++i;
	if (i >= lineEnd)
		return false;
	end = i + 1;
	++i;
	return true;
}

/// True when the solution has a project entry pointing at path1 (or at path2).
bool solutionHasEntry(string slnPath, string path1, string path2 = null)
{
	if (!slnPath.length)
		return false;
	string want = pathNormcase(pathAbspath(path1));
	string alt = path2.length ? pathNormcase(pathAbspath(path2)) : null;
	Solution sol = parseSolution(slnPath);
	foreach (p; sol.projects)
	{
		string q = pathNormcase(p);
		if (q == want || (alt.length && q == alt))
			return true;
	}
	return false;
}

// --------------------------------------------------------------------- option tables

immutable string[] TRAILING_SEP_MACROS = [ // MSBuild macros whose value already ends in a backslash
	"outdir", "intdir", "projectdir", "solutiondir", "inputdir", "targetdir",
	"vcinstalldir", "vctoolsinstalldir", "vsinstalldir", "devenvdir", "windowsdkdir",
	"dmdbindir", "ldcbindir", "userrootdir", "vctargetspath", "extensiondir", "projectpath",
];
// Macros a visualdproj uses that a vcxproj spells differently (insertion order matters).
immutable string[2][] MACRO_ALIASES = [
	["safeprojectname", "ProjectName"],
	["fulloutdir", "OutDir"],
	["fullintdir", "IntDir"],
	["universalcrtsdkdir", "WindowsSdkDir"],
	["windowsdkversion", "WindowsTargetPlatformVersion"],
	// The C++ toolset defines $(Configuration) and $(Platform); the "...Name" spellings
	// the visualdproj uses are only defined by the Visual D rules inside the IDE.
	["configurationname", "Configuration"],
	["platformname", "Platform"],
];
// Macros that have no counterpart in a vcxproj.
immutable string[string] MACRO_LOSSY = [
	"visualdinstalldir": "the Visual D installation folder is not an MSBuild property",
	"cc": "the C++ compiler of the Visual D options is not an MSBuild property",
];
// Macros the custom build step understands; everywhere else they have to be spelled out.
immutable string[] INPUT_MACROS = [
	"inputpath", "inputname", "inputdir", "inputfilename", "inputext",
	"rootname", "ext", "filename", "filedir"];
// The same macros spelled as the MSBuild item metadata a custom build step expands.
immutable string[string] INPUT_MACRO_METADATA = [
	"inputpath": "%(Identity)",
	"inputfilename": "%(Filename)%(Extension)",
	"inputname": "%(Filename)",
	"rootname": "%(Filename)",
	"filename": "%(Filename)",
	"inputext": "%(Extension)",
	"ext": "%(Extension)",
	"inputdir": "%(RelativeDir)",
	"filedir": "%(RelativeDir)",
];
// The DCompile boolean options and the MSBuild metadata property each one sets.
immutable string[2][] BOOL_META = [
	["optimize", "Optimizer"],
	["useInline", "Inliner"],
	["genStackFrame", "StackFrame"],
	["stackStomp", "StackStomp"],
	["allinst", "AllInst"],
	["useUnitTests", "Unittest"],
	["cov", "Coverage"],
	["trace", "Profile"],
	["vtls", "ShowTLS"],
	["vgc", "ShowGC"],
	["verbose", "Verbose"],
	["ignoreUnsupportedPragmas", "IgnorePragma"],
	["preservePaths", "PreserveSourcePath"],
	["betterC", "BetterC"],
	["dip25", "DIP25"],
	["dip1000", "DIP1000"],
	["dip1008", "DIP1008"],
	["dip1021", "DIP1021"],
	["revert_import", "RevertImport"],
	["transition_field", "TransitionField"],
	["transition_checkimports", "TransitionCheckImports"],
	["transition_complex", "TransitionComplex"],
	["transition_vmarkdown", "TransitionVMarkdown"],
	["preview_dtorfields", "PreviewDtorFields"],
	["preview_intpromote", "PreviewIntPromote"],
	["preview_fixAliasThis", "PreviewFixAliasThis"],
	["preview_rvaluerefparam", "PreviewRvalueRefParam"],
	["preview_nosharedaccess", "PreviewNoSharedAccess"],
	["preview_markdown", "PreviewMarkdown"],
	["preview_in", "PreviewIn"],
	["preview_inclincontracts", "PreviewInclusiveInContracts"],
	["preview_shortenedMethods", "PreviewShortenedMethods"],
];
immutable string[] DEAD_OPTIONS = [
	"obj", "link", "multiobj", "oneobj", "cpu", "scheduler", "pic", "debuglevel",
	"versionlevel", "dump_source", "useassert", "useinvariants", "usein", "useout",
	"usearraybounds", "useswitcherror", "noboundscheck", "libname",
	"islinux", "isosx", "iswindows", "isfreebsd", "issolaris",
];
immutable string[string] UNSUPPORTED_OPTIONS = [
	"run": "Visual D runs the target after building; a vcxproj has no equivalent",
	"runargs": "see the 'run' option",
	"pauseafterrunning": "an option of the Visual D run command",
	"debugstdouttooutputwindow": "an option of the Visual D debugger panel",
	"debugengine": "the debugger engine is selected by Visual Studio, not by the project",
	"debugremote": "no vcxproj property selects a remote debugger for a D target",
	"filestoclean": "Visual D deletes these on clean; MSBuild uses its own .tlog files",
	"modules_ddoc": "Visual D generates a separate ddoc batch for these modules",
	"ddocfiles": "used by the 'modules_ddoc' option only",
	"moduledepsfile": "MSBuild tracks module dependencies in its own .tlog files",
	"usestdlibpath": "the MSBuild rules always add the compiler library search path",
	"runcv2pdb": "cv2pdb is not part of the MSBuild build",
	"pathcv2pdb": "cv2pdb is not part of the MSBuild build",
	"cv2pdbnodemangle": "cv2pdb is not part of the MSBuild build",
	"cv2pdbenumtype": "cv2pdb is not part of the MSBuild build",
	"cv2pdboptions": "cv2pdb is not part of the MSBuild build",
	"cccmd": "only used to translate C++ sources for GDC",
	"cctransopt": "only used to translate C++ sources for GDC",
];
immutable string[string] MAPPED_OPTIONS = [
	"objname": "DCompile ObjectFileName (it names the object file of the whole project)",
	"resfile": "added to the linker inputs",
	"deffile": "Link ModuleDefinitionFile",
	"mapverbosity": "Link GenerateMapFile (the level itself only matters when dmd links)",
	"createimplib": "Link ImportLibrary",
	"adddepimp": "resolved through the solution into explicit import paths and libraries",
	"privatephobos": "-defaultlib=<objdir>privatephobos.lib",
	"doxgeneration": "DCompile JSONFile, or a bare -X when no file is given",
	"dodoccomments": "DCompile DocDir/DocFile, or a bare -D when neither is given",
	"dohdrgeneration": "DCompile HeaderDir/HeaderFile, or a bare -H when neither is given",
	"prebuildcommand": "PreBuildEvent (runs before every target, not only before linking)",
	"postbuildcommand": "PostBuildEvent",
	"debugtarget": "LocalDebuggerCommand",
	"debugarguments": "LocalDebuggerCommandArguments",
	"debugworkingdir": "LocalDebuggerWorkingDirectory",
	"debugattach": "LocalDebuggerAttach",
	"otherdmd": "DCompile CompilerExe",
	"program": "the compiler executable, taken literally",
	"enablemixin": "DCompile EnableDebugMixin and DebugMixin",
	"singlefilecompilation": "DCompile CompilationModel (and DoNotLink for 'compile only')",
	"mscoff": "DCompile CodeGeneration",
	"compiler": "the DCompiler property",
	"isx86_64": "DCompile CodeGeneration",
	"cruntime": "the libraries passed to the linker (Visual D never passes -mscrtlib)",
	"subsystem": "Link SubSystem",
	"lib": "the ConfigurationType property",
	"exefile": "TargetName/TargetExt and Link or Lib OutputFile",
	"additionaloptions": "DCompile AdditionalOptions; -L<switch> goes to the linker",
	"linkswitches": "Link AdditionalOptions",
	"symdebug": "DCompile DebugInfo and Link GenerateDebugInformation",
	"warnings": "DCompile Warnings",
	"infowarnings": "DCompile Warnings",
	"usedeprecated": "DCompile Deprecations",
	"errdeprecated": "DCompile Deprecations",
	"release": "DCompile DebugCode",
	"boundscheck": "DCompile BoundsCheck",
	"imppath": "DCompile ImportPaths",
	"fileimppath": "DCompile StringImportPaths",
	"versionids": "DCompile VersionIdentifiers",
	"debugids": "DCompile DebugIdentifiers",
	"outdir": "the OutDir property",
	"objdir": "the IntDir property",
	"objfiles": "Link AdditionalDependencies",
	"libfiles": "Link AdditionalDependencies",
	"libpaths": "Link AdditionalLibraryDirectories",
	"pdbfile": "Link ProgramDatabaseFile",
	"mapfile": "Link MapFileName",
	"impfile": "Link ImportLibrary",
	"quiet": "DCompile AdditionalOptions",
	"nofloat": "DCompile AdditionalOptions",
	"defaultlibname": "DCompile AdditionalOptions -defaultlib=",
	"debuglibname": "DCompile AdditionalOptions -debuglib=",
	"debuglib": "DCompile AdditionalOptions -link-debuglib (LDC only)",
];
immutable string[] KNOWN_OPTIONS = DEAD_OPTIONS ~ array(UNSUPPORTED_OPTIONS.keys)
	~ array(MAPPED_OPTIONS.keys) ~ array(BOOL_META.map!(m => toLower(m[0]))) ~ [
	"symdebugref",
	"docdir", "docname", "hdrdir", "hdrname", "xfilename",
	"mixinpath", "compiler", "otherdmd",
];

// --------------------------------------------------------------------- ntpath

// The Python tool uses os.path (ntpath), whose semantics differ from std.path in
// details that matter for the generated paths.

private struct SplitRoot
{
	string drive;
	string root;
	string tail;
}

private SplitRoot pathSplitroot(string p)
{
	string normp = normalizePath(p);
	SplitRoot r;
	if (normp.length >= 1 && normp[0] == '\\')
	{
		if (normp.length >= 2 && normp[1] == '\\')
		{
			// UNC drives, e.g. \\server\share or \\?\UNC\server\share
			// Device drives, e.g. \\.\device or \\?\device
			size_t start = (normp.length >= 8 && ciEqual(normp[0 .. 8], `\\?\UNC\`)) ? 8 : 2;
			size_t index = indexOf(normp, '\\', start);
			if (index == size_t.max)
				return SplitRoot(p, null, null);
			size_t index2 = indexOf(normp, '\\', index + 1);
			if (index2 == size_t.max)
				return SplitRoot(p, null, null);
			return SplitRoot(p[0 .. index2], normp[index2 .. index2 + 1], p[index2 + 1 .. $]);
		}
		else
			// Relative path with root, e.g. \Windows
			return SplitRoot(null, p[0 .. 1], p.length > 1 ? p[1 .. $] : null);
	}
	else if (normp.length >= 2 && normp[1] == ':')
	{
		if (normp.length >= 3 && normp[2] == '\\')
			// Absolute drive-letter path, e.g. X:\Windows
			return SplitRoot(p[0 .. 2], p[2 .. 3], p[3 .. $]);
		// Relative path with drive, e.g. X:Windows
		return SplitRoot(p[0 .. 2], null, p[2 .. $]);
	}
	// Relative path, e.g. Windows
	return SplitRoot(null, null, p);
}

bool pathIsabs(string s)
{
	string t = s.length > 3 ? s[0 .. 3] : s;
	t = normalizePath(t);
	if (t.length >= 3 && t[1] == ':' && t[2] == '\\')
		return true;
	return t.length >= 2 && t[0] == '\\' && t[1] == '\\';
}

string pathJoin(string a, string b)
{
	SplitRoot res = pathSplitroot(a);
	SplitRoot pr = pathSplitroot(b);
	if (pr.root.length)
	{
		// Second path is absolute
		if (pr.drive.length || !res.drive.length)
			res.drive = pr.drive;
		res.root = pr.root;
		res.tail = pr.tail;
	}
	else if (pr.drive.length && pr.drive != res.drive)
	{
		if (toLower(pr.drive) != toLower(res.drive))
		{
			// Different drives => ignore the first path entirely
			res.drive = pr.drive;
			res.root = pr.root;
			res.tail = pr.tail;
		}
		else
			// Same drive in different case
			res.drive = pr.drive;
	}
	if (res.tail.length && res.tail[$ - 1] != '\\' && res.tail[$ - 1] != '/')
		res.tail ~= "\\";
	res.tail ~= pr.tail;
	// add separator between UNC and non-absolute path
	if (res.tail.length && !res.root.length && res.drive.length &&
		res.drive[$ - 1] != ':' && res.drive[$ - 1] != '\\' && res.drive[$ - 1] != '/')
		return res.drive ~ "\\" ~ res.tail;
	return res.drive ~ res.root ~ res.tail;
}

string pathNormpath(string path)
{
	path = normalizePath(path);
	SplitRoot sr = pathSplitroot(path);
	string prefix = sr.drive ~ sr.root;
	// Empty and "." components are dropped. ".." cancels the component before it,
	// unless that one is also "..", or unless the path is rooted and there is
	// nothing left to cancel, in which case the ".." is dropped as well.
	string[] comps;
	foreach (c; split(sr.tail, '\\'))
	{
		if (!c.length || c == ".")
			continue;
		if (c == ".." && comps.length && comps[$ - 1] != "..")
			comps.length -= 1;
		else if (c == ".." && !comps.length && sr.root.length)
			continue;
		else
			comps ~= c;
	}
	if (!prefix.length && !comps.length)
		comps ~= ".";
	return prefix ~ join(comps, "\\");
}

private string pathUpperDrive(string p)
{
	return p.length >= 2 && p[1] == ':' && isAlpha(cast(dchar)p[0]) ? p[0 .. 1].toUpper ~ p[1 .. $] : p;
}

string pathAbspath(string path)
{
	string n = pathNormpath(path);
	if (pathIsabs(n))
		return pathUpperDrive(n);
	n = pathJoin(getcwd(), n);
	n = pathNormpath(n);
	return pathUpperDrive(n);
}

private string rstripSeps(string s)
{
	size_t n = s.length;
	while (n && (s[n - 1] == '\\' || s[n - 1] == '/'))
		--n;
	return s[0 .. n];
}

private string[] pathSplit(string p)
{
	SplitRoot sr = pathSplitroot(p);
	string rest = sr.tail;
	size_t sep = max(lastIndexOf(rest, '\\'), lastIndexOf(rest, '/'));
	size_t i = sep == size_t.max ? 0 : sep + 1;
	return [sr.drive ~ sr.root ~ rstripSeps(rest[0 .. i]), rest[i .. $]];
}

string pathDirname(string p)
{
	return pathSplit(p)[0];
}

string pathBasename(string p)
{
	return pathSplit(p)[1];
}

// genericpath._splitext
string[] pathSplitext(string p)
{
	size_t sepIndex = max(lastIndexOf(p, '\\'), lastIndexOf(p, '/'));
	// Start of the file name; lastIndexOf yields size_t.max when there is no separator,
	// which must not take part in the "dot inside the file name" comparison below.
	size_t filenameIndex = sepIndex == size_t.max ? 0 : sepIndex + 1;
	size_t dotIndex = lastIndexOf(p, '.');
	if (dotIndex == size_t.max || dotIndex < filenameIndex)
		return [p, null];
	// skip all leading dots of the file name
	while (filenameIndex < dotIndex)
	{
		if (p[filenameIndex] != '.')
			return [p[0 .. dotIndex], p[dotIndex .. $]];
		++filenameIndex;
	}
	return [p, null];
}

// ntpath.normcase is exactly stdext.path.canonicalPath
alias pathNormcase = canonicalPath;

string pathRelpath(string path, string start)
{
	string startAbs = pathAbspath(start);
	string pathAbs = pathAbspath(path);
	SplitRoot sr = pathSplitroot(startAbs);
	SplitRoot pr = pathSplitroot(pathAbs);
	if (pathNormcase(sr.drive) != pathNormcase(pr.drive))
		throw new Exception("path is on mount " ~ pr.drive ~ ", start on mount " ~ sr.drive);
	string[] startList = sr.tail.length ? split(sr.tail, '\\') : null;
	string[] pathList = pr.tail.length ? split(pr.tail, '\\') : null;
	size_t i = 0;
	size_t n = startList.length < pathList.length ? startList.length : pathList.length;
	while (i < n && pathNormcase(startList[i]) == pathNormcase(pathList[i]))
		++i;
	string[] rel;
	foreach (_; 0 .. startList.length - i)
		rel ~= "..";
	foreach (k; i .. pathList.length)
		rel ~= pathList[k];
	if (!rel.length)
		return ".";
	return join(rel, "\\");
}

// --------------------------------------------------------------------- file system

private bool fileExists(string p)
{
	try
		return exists(p);
	catch (Exception e)
		return false;
}

private string[] listDirSorted(string d)
{
	string[] res;
	try
		foreach (DirEntry de; dirEntries(d, SpanMode.shallow))
			res ~= de.name.baseName;
	catch (Exception e)
	{
	}
	res.sort();
	return res;
}

// --------------------------------------------------------------------- xml helpers

/// The text of an element: Element.text() throws when the element contains comments,
/// so the text items are concatenated here.
string elemText(xml.Element e)
{
	auto app = appender!string();
	foreach (t; e.texts)
		app.put(xml.decode(t.toString()));
	return app.data;
}

private xml.Element[] childElements(xml.Element e, string name)
{
	xml.Element[] res;
	foreach (ch; e.elements)
		if (ch.tag.name == name)
			res ~= ch;
	return res;
}

/// ElementTree's Element.iter(): the element itself and all its descendants, pre-order.
private xml.Element[] iterElements(xml.Element e)
{
	xml.Element[] res;
	void walk(xml.Element el)
	{
		res ~= el;
		foreach (ch; el.elements)
			walk(ch);
	}
	walk(e);
	return res;
}

// --------------------------------------------------------------------- macro translation

// $(InputName) and friends become the metadata MSBuild expands for the file the custom
// build step runs on.
private string rewriteInputMacros(string s)
{
	auto app = appender!string();
	size_t i = 0;
	while (i < s.length)
	{
		if (s[i] == '$' && i + 1 < s.length && s[i + 1] == '(')
		{
			size_t j = i + 2;
			if (j < s.length && isIdentStart(s[j]))
			{
				size_t start = j;
				while (j < s.length && isIdentChar(s[j]))
					++j;
				if (j < s.length && s[j] == ')')
				{
					string v = INPUT_MACRO_METADATA.get(toLower(s[start .. j]), null);
					app.put(v is null ? s[i .. j + 1] : v);
					i = j + 1;
					continue;
				}
			}
		}
		app.put(s[i]);
		++i;
	}
	return app.data;
}

/// Spell the line breaks of a multi line command as the escapes MSBuild turns back into
/// newlines.  An XML parser folds the breaks of the element text into single spaces, so
/// writing them out literally would run all command lines of the step as one.
private string escapeNewlines(string s)
{
	if (indexOf(s, "\r") < 0 && indexOf(s, "\n") < 0)
		return s;
	auto app = appender!string();
	for (size_t i = 0; i < s.length; ++i)
	{
		if (s[i] == '\r')
		{
			if (i + 1 < s.length && s[i + 1] == '\n')
				++i;
			app.put("%0D%0A");
		}
		else if (s[i] == '\n')
			app.put("%0D%0A");
		else
			app.put(s[i]);
	}
	return app.data;
}

/// Rewrite Visual D macros into their MSBuild spelling.
string translateMacros(string s, Report report, string where, bool custom = false)
{
	if (s !is null && s.length && indexOf(s, '$') >= 0)
	{
		foreach (pair; MACRO_ALIASES)
			s = replaceMacroAlias(s, pair[0], pair[1]);
		string[] names = macroRefs(s).map!(m => m.name).array;
		foreach (string name; names.sort.uniq)
		{
			string lossy = MACRO_LOSSY.get(toLower(name), null);
			if (lossy !is null)
				report.lossy(where ~ ": $(" ~ name ~ ") " ~ lossy);
			else if (ciHas(INPUT_MACROS, toLower(name)) && !custom)
				report.lossy(where ~ ": $(" ~ name ~ ") is only expanded by a custom build step");
		}
		// The trailing path separator has to go while the macros are still spelled $(Name).
		s = dropTrailingSepBackslashes(s);
		if (custom)
			s = rewriteInputMacros(s);
	}
	//if (custom)
	//	s = escapeNewlines(s);
	return s;
}

// --------------------------------------------------------------------- option tables

// ci_dict({1:Console,2:Windows,3:Native,4:POSIX}); null for an unknown value
private string subsystemName(int v)
{
	switch (v)
	{
		case 1: return "Console";
		case 2: return "Windows";
		case 3: return "Native";
		case 4: return "POSIX";
		default: return null;
	}
}

// ci_dict({0:"",1:On,2:SafeOnly,3:Off})
private string boundsName(int v)
{
	switch (v)
	{
		case 1: return "On";
		case 2: return "SafeOnly";
		case 3: return "Off";
		default: return "";
	}
}

// ci_dict({0:Application,1:StaticLibrary,2:DynamicLibrary}); null for an output
// type the .visualdproj would not have written.
private string configurationTypeName(int v)
{
	switch (v)
	{
		case 1: return "StaticLibrary";
		case 2: return "DynamicLibrary";
		case 0: return "Application";
		default: return null;
	}
}

// ci_dict({0:.exe,1:.lib,2:.dll})
private string targetExtName(int v)
{
	switch (v)
	{
		case 1: return ".lib";
		case 2: return ".dll";
		default: return ".exe";
	}
}

/// DIR_MACRO
private string dirMacroName(string name) { return name == "outdir" ? "OutDir" : "IntDir"; }

// --------------------------------------------------------------------- converter types

/// One metadata entry; conds is empty for an unconditional entry.
struct Meta
{
	string name;
	string value;
	string[] conds;

	this(string n, string v, string[] c = null)
	{
		name = n;
		value = v;
		conds = c is null ? null : c;
	}
}

struct FileEvent
{
	string group;
	string meta;
	string value;
}

alias AttrMap = string[string];   // element attribute name -> value
alias PerCfgMap = AttrMap[string]; // configuration name -> its attributes

struct Item
{
	string type;
	string path;
	string filter;
	Meta[] meta;
	PerCfgMap percfg;
}

struct DepOutput
{
	VdProject dep;
	string full;
}

struct ToolParsed
{
	string[][string] switches;
	string[] extra;
}

private bool isAlphaAscii(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }

// ^(?:[a-zA-Z]:|[\\$])
private bool startsDriveOrDollar(string s)
{
	if (!s.length)
		return false;
	if (s.length >= 2 && isAlphaAscii(s[0]) && s[1] == ':')
		return true;
	return s[0] == '\\' || s[0] == '$';
}

// ^[a-zA-Z]:[\\/]
private bool startsDriveSep(string s)
{
	return s.length >= 3 && isAlphaAscii(s[0]) && s[1] == ':' && (s[2] == '\\' || s[2] == '/');
}

// ^[\\/]
private bool startsSep(string s)
{
	return s.length != 0 && (s[0] == '\\' || s[0] == '/');
}

// ^\$\((?:OutDir|IntDir|ProjectDir|SolutionDir|TargetDir|TargetPath|TargetName|TargetExt)\)
private bool startsKnownMacro(string s)
{
	static immutable string[] names = [
		"OutDir", "IntDir", "ProjectDir", "SolutionDir",
		"TargetDir", "TargetPath", "TargetName", "TargetExt",
	];
	if (s.length < 4 || s[0] != '$' || s[1] != '(')
		return false;
	foreach (n; names)
	{
		if (s.length >= n.length + 3 && startsWithCiAt(s, 2, n) && s[2 + n.length] == ')')
			return true;
	}
	return false;
}

// --------------------------------------------------------------------- the converter

final class Converter
{
	VdProject p;
	ConvertOptions opts;
	Report report;
	DefaultProp[] defaults;
	string[string] ruleProps;      // property name -> rule type ("BoolProperty" ...)
	string[string] slnProjects;    // project guid -> path
	string[][string] slnDeps;      // project guid -> [referenced guid, ...]
	Item[] items;
	string[] folders;
	string[] defItems;
	string[] resItems;
	string outfile;                // null when the target goes to OutDir
	string[] itemOrder = [
		"DCompile", "Midl", "ResourceCompile", "ClCompile", "ClInclude",
		"CustomBuild", "Library", "Object", "None",
	];

	private struct EnvPair
	{
		Env env;
		Env envAbs;
	}
	private EnvPair[string] envCache;

	this(VdProject project, ConvertOptions opt, Report rep)
	{
		p = project;
		opts = opt;
		report = rep;
		defaults = loadDcompileDefaults(opts.msbuildDir);
		ruleProps = loadRuleProperties(opts.msbuildDir);
		if (opts.slnPath.length)
		{
			Solution sol = parseSolution(opts.slnPath);
			slnProjects = sol.projects;
			slnDeps = sol.deps;
		}
	}

	string[] depsOfProject()
	{
		return slnDeps.get(p.guid, null);
	}

	// ---------------- macros and paths

	/// The (path, config) tuple the Python tool passes as the report location.
	private static string envWhere(VdProject proj, VdConfig cfg)
	{
		return "('" ~ replace(toLower(proj.path), "\\", "\\\\") ~ "', '" ~ cfg.key() ~ "')";
	}

	/// Return (env, env_abs): env keeps the VC macro spelling, env_abs resolves the
	/// same macros to absolute paths so that paths can be relativized.
	EnvPair macroEnv(VdProject proj, VdConfig cfg)
	{
		// Key on the project file, not its directory: two projects can share a
		// directory (vdc\vdserver and vdc\parser do), and their macros then differ.
		string cacheKey = toLower(proj.path) ~ "|" ~ cfg.key();
		auto cached = cacheKey in envCache;
		if (cached !is null)
			return *cached;

		Env base = new Env;
		base.set("projectdir", proj.dir);
		base.set("projectname", proj.name);
		base.set("projectext", ".vcxproj");
		base.set("projectfilename", proj.name ~ ".vcxproj");
		base.set("msbuildprojectname", proj.name);
		base.set("configuration", cfg.name);
		base.set("configurationname", cfg.name);
		base.set("platform", cfg.platform);
		base.set("platformname", cfg.platform);
		base.set("targetname", proj.name);
		base.set("targetext", targetExtName(cfg.outputType()));
		if (opts.slnPath.length)
		{
			base.set("solutiondir", pathDirname(opts.slnPath));
			base.set("solutionname", pathSplitext(pathBasename(opts.slnPath))[0]);
			base.set("solutionext", pathSplitext(opts.slnPath)[1]);
			base.set("solutionfilename", pathBasename(opts.slnPath));
		}
		Env env = base.dupEnv();
		Env envAbs = base.dupEnv();
		envAbs.set("projectdir", proj.dir);
		if (opts.slnPath.length)
			envAbs.set("solutiondir", pathDirname(opts.slnPath));

		string where = envWhere(proj, cfg);
		// OutDir and IntDir first: IntDir is usually written as $(OutDir)$(Platform)...
		string[2][2] dirs = [["outdir", cfg.get("outdir")], ["intdir", cfg.get("objdir")]];
		foreach (pr; dirs)
		{
			string name = pr[0];
			string raw = pr[1];
			if (raw is null || !raw.length)
				continue;
			string expr = normalizeMacroPath(translateMacros(raw, report, where));
			if (!startsDriveOrDollar(expr))
				expr = "$(ProjectDir)" ~ expr;
			string resolved = substitute(expr, envAbs);
			if (!startsDriveSep(resolved) && !startsSep(resolved))
				resolved = pathJoin(proj.dir, resolved);
			envAbs.set(name, pathNormpath(resolved) ~ "\\");
			env.set(name, expr ~ "\\");
		}
		if (envAbs.get("outdir") !is null && envAbs.get("outdir").length)
		{
			envAbs.set("targetdir", envAbs.get("outdir"));
			envAbs.set("targetpath", envAbs.get("outdir") ~ envAbs.get("targetname") ~ envAbs.get("targetext"));
		}
		EnvPair pair = { env, envAbs };
		envCache[cacheKey] = pair;
		return pair;
	}

	/// Translate macros to their MSBuild spelling, expanding the fixed ones.
	string expand(string s, VdProject proj, VdConfig cfg)
	{
		s = translateMacros(s, report, cfg.key());
		EnvPair me = macroEnv(proj, cfg);
		return substitute(s, me.env);
	}

	/// Spell a path as $(OutDir)..., $(IntDir)... or project relative.
	string macroPath(string s, VdProject proj, VdConfig cfg)
	{
		Env envAbs = macroEnv(proj, cfg).envAbs;
		string translated = normalizeMacroPath(translateMacros(s, report, cfg.key()));
		if (startsKnownMacro(translated))
			return translated;
		string full = substitute(translated, envAbs);
		if (indexOf(full, '$') >= 0)
			return translated;
		string norm = pathNormpath(full);
		foreach (string name; ["intdir", "outdir"]) // IntDir first: it is the more specific base
		{
			string base = envAbs.get(name);
			if (base is null || !base.length)
				continue;
			base = pathNormpath(base);
			if (pathNormcase(norm).length >= pathNormcase(base).length + 1 &&
				pathNormcase(norm)[0 .. pathNormcase(base).length + 1] == pathNormcase(base) ~ "\\")
				return "$(" ~ dirMacroName(name) ~ ")" ~ norm[base.length + 1 .. $];
		}
		string rel = pathRelpath(norm, rstripSeps(proj.dir));
		return (rel.length >= 2 && rel[0] == '.' && rel[1] == '.') ? rel : ".\\" ~ rel;
	}

	// ---------------- referenced projects

	VdProject[] dependencyProjects(VdProject proj, ref bool[string] seen)
	{
		VdProject[] res;
		foreach (guid; slnDeps.get(guidKey(proj), null))
		{
			string path = slnProjects.get(guid, null);
			if (path is null || !path.length)
				continue;
			if (!endsWithCi(path, ".visualdproj"))
			{
				// a project that has been converted already: fall back to its visualdproj
				string alt = pathSplitext(path)[0] ~ ".visualdproj";
				if (!fileExists(alt))
				{
					report.lossy("referenced project " ~ pathBasename(path) ~ " is not a .visualdproj; its "
						~ "outputs are not added to this project");
					continue;
				}
				path = alt;
			}
			if (path in seen)
				continue;
			seen[path] = true;
			try
				res ~= new VdProject(path);
			catch (Exception e)
				report.lossy("cannot read referenced project " ~ path ~ " (" ~ e.msg ~ ")");
		}
		return res;
	}

	private static string guidKey(VdProject proj) { return proj.guid; }

	/// getImportsFromDependentProjects(): the directory of every referenced project plus
	/// its own import paths resolved relative to that project, recursively.
	string[] dependencyImportDirs(VdProject proj, VdConfig cfg, ref bool[string] seen)
	{
		string[] imports;
		void add(string path)
		{
			if (path is null || !path.length)
				return;
			foreach (e; imports)
				if (e == path)
					return;
			imports ~= path;
		}

		string baseDir = rstripSeps(p.dir);
		foreach (dep; dependencyProjects(proj, seen))
		{
			VdConfig dcfg = dep.config(cfg.key());
			if (dcfg is null && dep.configs.length)
				dcfg = dep.configs[0];
			if (dcfg is null)
			{
				report.lossy(cfg.key() ~ ": referenced project " ~ dep.name ~ " has no configuration");
				continue;
			}
			string depDir = rstripSeps(dep.dir);
			add(pathRelpath(depDir, baseDir));
			foreach (imp; words(dcfg.get("imppath")))
				add(pathRelpath(pathNormpath(pathJoin(depDir, imp)), baseDir));
			foreach (rel; dependencyImportDirs(dep, dcfg, seen))
				add(rel);
		}
		return imports;
	}

	/// getLibsFromDependentProjects(): the file every referenced project produces.
	DepOutput[] dependencyOutputs(VdProject proj, VdConfig cfg, ref bool[string] seen)
	{
		DepOutput[] res;
		foreach (dep; dependencyProjects(proj, seen))
		{
			VdConfig dcfg = dep.config(cfg.key());
			if (dcfg is null && dep.configs.length)
				dcfg = dep.configs[0];
			if (dcfg is null)
				continue;
			string target = dcfg.get("exefile");
			Env depAbs = macroEnv(dep, dcfg).envAbs;
			if (!target.length)
				target = (depAbs.get("outdir") !is null && depAbs.get("outdir").length
						  ? depAbs.get("outdir") : dep.dir) ~ dep.name ~ targetExtName(dcfg.outputType());
			string full = substitute(translateMacros(target, report, dcfg.key()), depAbs);
			if (indexOf(full, '$') >= 0)
			{
				report.lossy(cfg.key() ~ ": the target of referenced project " ~ dep.name
					~ " keeps macros (" ~ target ~ ")");
				continue;
			}
			if (!startsDriveSep(full) && !startsSep(full))
				full = pathJoin(dep.dir, full);
			report.note("the file referenced project " ~ dep.name ~ " contributes is taken from its "
				~ "'exefile' setting; the IDE asks the project for its build outputs");
			res ~= DepOutput(dep, pathNormpath(full));
		}
		return res;
	}

	// ---------------- per-config groups

	string codeGeneration(VdConfig cfg)
	{
		string compiler = cfg.compiler();
		if (compiler != "DMD" && compiler != "LDC")
			report.unsupported(cfg.key() ~ ": compiler '" ~ compiler ~ "' has no MSBuild rule; the DCompiler "
				~ "property only offers DMD and LDC");
		if (toLower(cfg.platform) == "arm64")
			return "ARM64";
		if (cfg.is64())
			return "64Bits";
		if (compiler == "LDC")
			return "32Bits";
		if (!cfg.mscoff())
			report.unsupported(cfg.key() ~ ": DMD for Win32 without mscoff links with optlink, "
				~ "which the MSBuild rules cannot drive; the config is converted as 32-bit MS-COFF");
		return "32BitsMS-COFF";
	}

	Meta[] configProperties(VdConfig cfg)
	{
		string compiler = cfg.compiler();
		string ct = configurationTypeName(cfg.outputType());
		return [
			Meta("ConfigurationType", ct is null ? "Application" : ct),
			Meta("PlatformToolset", "$(DefaultPlatformToolset)"),
			Meta("CharacterSet", "Unicode"),
			Meta("DCompiler", (compiler == "DMD" || compiler == "LDC") ? compiler : "DMD"),
		];
	}

	Meta[] debuggerProperties(VdConfig cfg)
	{
		Meta[] res;
		string[2][3] map = [
			["debugtarget", "LocalDebuggerCommand"],
			["debugarguments", "LocalDebuggerCommandArguments"],
			["debugworkingdir", "LocalDebuggerWorkingDirectory"],
		];
		foreach (m; map)
		{
			string v = cfg.get(m[0]);
			if (v.length)
				res ~= Meta(m[1], translateMacros(v, report, cfg.key()));
		}
		if (cfg.has("debugattach"))
			res ~= Meta("LocalDebuggerAttach", flag(cfg.get("debugattach")) ? "true" : "false");
		return res;
	}

	/// Split 'exefile' into TargetName/TargetExt, plus an OutputFile if needed.
	void targetNameExt(VdConfig cfg, out string name, out string ext, out string outfile_)
	{
		name = null;
		ext = null;
		outfile_ = null;
		string exefile = cfg.get("exefile");
		if (!exefile.length)
			return;
		Env envAbs = macroEnv(p, cfg).envAbs;
		string full = substitute(translateMacros(exefile, report, cfg.key()), envAbs);
		if (indexOf(full, '$') >= 0)
		{
			outfile_ = macroPath(exefile, p, cfg);
			return;
		}
		string norm = pathNormpath(full);
		string[] be = pathSplitext(pathBasename(norm));
		string b = be[0], e = be[1];
		// Only spell TargetName/TargetExt out when they differ from what the
		// configuration type gives a vcxproj by default.
		name = toLower(b) == toLower(p.name) ? null : b;
		string defaultExt = targetExtName(cfg.outputType());
		ext = toLower(e) == toLower(defaultExt) ? null : e;
		string outdir = envAbs.get("outdir");
		if (outdir !is null && outdir.length &&
			pathNormcase(pathDirname(norm)) != pathNormcase(pathNormpath(outdir)))
			outfile_ = macroPath(exefile, p, cfg);
	}

	Meta[] userProperties(VdConfig cfg)
	{
		Env env = macroEnv(p, cfg).env;
		Meta[] props;
		if (cfg.get("outdir").length)
			props ~= Meta("OutDir", env.get("outdir"));
		if (cfg.get("objdir").length)
			props ~= Meta("IntDir", env.get("intdir"));
		props ~= Meta("LinkIncremental", "false"); // Visual D links with /INCREMENTAL:NO
		string name, ext, out_;
		targetNameExt(cfg, name, ext, out_);
		outfile = out_;
		if (name !is null)
			props ~= Meta("TargetName", name);
		if (ext !is null)
			props ~= Meta("TargetExt", ext);
		props ~= debuggerProperties(cfg);
		return props;
	}

	Meta[] dcompileMetadata(VdConfig cfg, out string[] linkopts)
	{
		Meta[] d;
		string key = cfg.key();
		string compiler = cfg.compiler();
		d ~= Meta("CodeGeneration", codeGeneration(cfg));

		if (flag(cfg.get("warnings")))
			d ~= Meta("Warnings", "Error");
		else if (flag(cfg.get("infowarnings")))
			d ~= Meta("Warnings", "Info");
		else
			d ~= Meta("Warnings", "None");

		if (flag(cfg.get("useDeprecated")))
			d ~= Meta("Deprecations", "Allow");
		else if (flag(cfg.get("errDeprecated")))
			d ~= Meta("Deprecations", "Error");
		else
			d ~= Meta("Deprecations", "Info");

		d ~= Meta("DebugCode", debugCodeName(asInt(cfg.get("release"))));
		bool symdebug = flag(cfg.get("symdebug"));
		d ~= Meta("DebugInfo", symdebug ? "Mago" : "None");
		// dmd only accepts -gf together with -g
		d ~= Meta("DebugFull", (symdebug && flag(cfg.get("symdebugref"))) ? "true" : "false");
		d ~= Meta("BoundsCheck", boundsName(asInt(cfg.get("boundscheck"))));

		int model = cfg.model();
		if (model == 4)
			report.unsupported(key ~ ": the compilation model 'compile through dub' has no "
				~ "MSBuild equivalent");
		string compileModel = (model == 0 || model == 4) ? "Project" : "File";
		// Compiling a whole static library into one object file makes the library a single
		// archive member, so linking it pulls in every module's external references.
		// Visual D's own build hands all modules to "dmd -lib", which archives one member
		// per module; keep the project's model and let the compiler do the archiving.
		bool libArchive = compileModel == "Project" && cfg.outputType() == 1;
		d ~= Meta("CompilationModel", compileModel);
		if (model == 3)
		{
			d ~= Meta("DoNotLink", "true");
			report.note(key ~ ": compilation model 'separate compile only' -> DoNotLink=true");
		}

		foreach (m; BOOL_META)
			if (cfg.has(m[0]))
				d ~= Meta(m[1], flag(cfg.get(m[0])) ? "true" : "false");

		string[] imps = words(cfg.get("imppath"));
		if (flag(cfg.get("addDepImp")))
		{
			string[] slnDepsOfThis = depsOfProject();
			if (slnDepsOfThis is null || !slnDepsOfThis.length)
				report.lossy(key ~ ": addDepImp=1 but the solution does not list any project "
					~ "reference of this project");
			else if (!opts.projectRefs)
			{
				bool[string] seen;
				foreach (imp; dependencyImportDirs(p, cfg, seen))
				{
					bool found = false;
					foreach (e; imps)
						if (e == imp)
							{ found = true; break; }
					if (!found)
						imps ~= imp;
				}
			}
		}
		if (imps.length)
		{
			string[] t;
			foreach (i; imps)
				t ~= translateMacros(i, report, key);
			d ~= Meta("ImportPaths", join(t, ";"));
		}
		string[] fimps = words(cfg.get("fileImppath"));
		if (fimps.length)
		{
			string[] t;
			foreach (i; fimps)
				t ~= translateMacros(i, report, key);
			d ~= Meta("StringImportPaths", join(t, ";"));
		}
		string[] vids = words(cfg.get("versionids"));
		if (vids.length)
		{
			string[] t;
			foreach (i; vids)
				t ~= translateMacros(i, report, key);
			d ~= Meta("VersionIdentifiers", join(t, ";"));
		}
		string[] dids = words(cfg.get("debugids"));
		if (dids.length)
		{
			string[] t;
			foreach (i; dids)
				t ~= translateMacros(i, report, key);
			d ~= Meta("DebugIdentifiers", join(t, ";"));
		}

		// The rules have no on/off switch for -D, -H and -X, only the -Dd/-Df, -Hd/-Hf and
		// -Xf forms, so a bare switch has to go into AdditionalOptions.
		string[] extra;
		if (flag(cfg.get("doDocComments")))
		{
			if (cfg.get("docdir").length)
				d ~= Meta("DocDir", translateMacros(cfg.get("docdir"), report, key));
			if (cfg.get("docname").length)
				d ~= Meta("DocFile", translateMacros(cfg.get("docname"), report, key));
			if (!cfg.get("docdir").length && !cfg.get("docname").length)
				extra ~= "-D";
		}
		if (flag(cfg.get("doHdrGeneration")))
		{
			if (cfg.get("hdrdir").length)
				d ~= Meta("HeaderDir", translateMacros(cfg.get("hdrdir"), report, key));
			if (cfg.get("hdrname").length)
				d ~= Meta("HeaderFile", translateMacros(cfg.get("hdrname"), report, key));
			if (!cfg.get("hdrdir").length && !cfg.get("hdrname").length)
				extra ~= "-H";
		}
		if (flag(cfg.get("doXGeneration")))
		{
			if (cfg.get("xfilename").length)
				d ~= Meta("JSONFile", translateMacros(cfg.get("xfilename"), report, key));
			else
				extra ~= "-X";
		}
		if (flag(cfg.get("enableMixin")))
		{
			d ~= Meta("EnableDebugMixin", "true");
			if (cfg.get("mixinPath").length)
				d ~= Meta("DebugMixin", translateMacros(cfg.get("mixinPath"), report, key));
		}
		if (cfg.get("objname").length)
			d ~= Meta("ObjectFileName", translateMacros(cfg.get("objname"), report, key));

		if (libArchive)
		{
			// The compiler archives one object per module rather than the Lib tool
			// collecting the single object file the combined model produces.
			extra ~= "-lib";
			report.note(key ~ ": the static library is archived by the compiler ('-lib') "
				~ "rather than by the Lib tool, so that the library holds one object per "
				~ "module as Visual D's own build does");
		}

		linkopts = null;
		foreach (tok; words(cfg.get("additionalOptions")))
		{
			if (tok.length >= 2 && tok[0] == '-' && tok[1] == 'L')
				linkopts ~= tok[2 .. $];
			else
				extra ~= tok;
		}
		if (flag(cfg.get("quiet")))
			extra ~= "-quiet";
		if (flag(cfg.get("nofloat")))
			extra ~= "-nofloat";
		if (flag(cfg.get("privatePhobos")))
			extra ~= "-defaultlib=" ~ macroNormpath(cfg.get("objdir")) ~ "\\privatephobos.lib";
		if (cfg.get("defaultlibname").length)
			extra ~= "-defaultlib=" ~ cfg.get("defaultlibname");
		if (cfg.get("debuglibname").length)
			extra ~= "-debuglib=" ~ cfg.get("debuglibname");
		if (flag(cfg.get("debuglib")))
		{
			if (compiler == "LDC")
				extra ~= "-link-debuglib";
			else
				report.ignored(key ~ ": <debuglib> is an LDC switch and has no effect for " ~ compiler);
		}
		if (extra.length)
		{
			string[] t;
			foreach (e; extra)
				t ~= translateMacros(e, report, key);
			d ~= Meta("AdditionalOptions", join(t, " "));
		}

		if (flag(cfg.get("otherDMD")) && cfg.get("program").length)
			d ~= Meta("CompilerExe", translateMacros(cfg.get("program"), report, key));
		return d;
	}

	/// Resolve a path setting; null when macros keep it from resolving.
	string settingPath(string raw, VdConfig cfg)
	{
		Env envAbs = macroEnv(p, cfg).envAbs;
		string full = substitute(translateMacros(raw, report, cfg.key()), envAbs);
		if (indexOf(full, '$') >= 0)
			return null;
		if (!startsDriveSep(full) && !startsSep(full))
			full = pathJoin(p.dir, full);
		return pathNormpath(full);
	}

	/// The file the linker produces when the corresponding setting is left out.
	string defaultPath(VdConfig cfg, string ext)
	{
		string name, extOverride, out_;
		targetNameExt(cfg, name, extOverride, out_);
		Env envAbs = macroEnv(p, cfg).envAbs;
		string outdir = envAbs.get("outdir");
		if (outdir is null || !outdir.length)
			return null;
		string tname = (name !is null && name.length) ? name : p.name;
		return pathNormpath(pathJoin(outdir, tname ~ ext));
	}

	Meta[] linkMetadata(VdConfig cfg, string[] linkopts, out Meta[] lib)
	{
		Meta[] link;
		lib = null;
		int otype = cfg.outputType();
		string compiler = cfg.compiler();
		int cruntime = asInt(cfg.get("cRuntime"), 1);
		bool symdebug = flag(cfg.get("symdebug"));
		string key = cfg.key();

		string[] deps;
		if (!opts.projectRefs)
		{
			bool[string] seen;
			foreach (do_ ; dependencyOutputs(p, cfg, seen))
				deps ~= macroPath(do_.full, p, cfg);
		}
		string[] files = words(cfg.get("objfiles"));
		files ~= words(cfg.get("libfiles"));
		foreach (w; files)
		{
			if (w.length >= 2 && w[0] == '-' && w[1] == 'l')
			{
				// a gcc style library name
				report.lossy(key ~ ": '" ~ w ~ "' rewritten to the MSVC library name " ~ w[2 .. $] ~ ".lib");
				w = w[2 .. $] ~ ".lib";
			}
			deps ~= translateMacros(w, report, key);
		}
		foreach (res; resItems)
			deps ~= translateMacros(res, report, key);
		if (cfg.get("resfile").length)
			deps ~= translateMacros(cfg.get("resfile"), report, key);
		// config.d appends these two to every link command line
		deps ~= "user32.lib";
		deps ~= "kernel32.lib";
		if (compiler == "LDC" || (compiler == "DMD" && (cfg.is64() || cfg.mscoff())))
			deps ~= "legacy_stdio_definitions.lib";
		string crtlib = crtLibName(cruntime);
		if (crtlib !is null)
			deps ~= crtlib;
		if (cruntime == 0 || cruntime == 2 || cruntime == 3 || cruntime == 4)
			link ~= Meta("IgnoreSpecificDefaultLibraries", "libcmt.lib");

		if (otype == 1) // a static library is built by the Lib tool
		{
			if (outfile !is null && outfile.length)
				lib ~= Meta("OutputFile", outfile);
			foreach (opt; linkopts)
				lib ~= Meta("AdditionalOptions", translateMacros(opt, report, key));
			return link;
		}

		string sub = subsystemName(asInt(cfg.get("subsystem")));
		if (sub !is null)
			link ~= Meta("SubSystem", sub);
		link ~= Meta("GenerateDebugInformation", symdebug ? "true" : "false");
		if (!cfg.is64())
			link ~= Meta("ImageHasSafeExceptionHandlers", "false");
		if (symdebug && cfg.get("pdbfile").length)
		{
			string got = settingPath(cfg.get("pdbfile"), cfg);
			string default_ = defaultPath(cfg, ".pdb");
			if (got is null || default_ is null || pathNormcase(got) != pathNormcase(default_))
				link ~= Meta("ProgramDatabaseFile", macroPath(cfg.get("pdbfile"), p, cfg));
		}

		int mapv = asInt(cfg.get("mapverbosity"));
		if (mapv > 0)
		{
			// The mapverbosity level only selects /MAPINFO or optlink's /MAP:ADDRESS when
			// dmd drives the linker; the MSVC linker just gets the map file itself.
			link ~= Meta("GenerateMapFile", "true");
			if (cfg.get("mapfile").length)
			{
				string got = settingPath(cfg.get("mapfile"), cfg);
				string default_ = defaultPath(cfg, ".map");
				if (got is null || default_ is null || pathNormcase(got) != pathNormcase(default_))
					link ~= Meta("MapFileName", macroPath(cfg.get("mapfile"), p, cfg));
			}
			if (mapv == 1 || mapv == 3 || mapv == 4)
				report.note(key ~ ": mapverbosity=" ~ text(mapv) ~ " also asks for the export listing in "
					~ "the map file, which the MSVC linker is not given by Visual D");
		}
		if (flag(cfg.get("createImplib")) && cfg.get("impfile").length)
		{
			string got = settingPath(cfg.get("impfile"), cfg);
			string default_ = defaultPath(cfg, ".lib");
			if (got is null || default_ is null || pathNormcase(got) != pathNormcase(default_))
				link ~= Meta("ImportLibrary", macroPath(cfg.get("impfile"), p, cfg));
		}

		string[] libpaths = words(cfg.get("libpaths"));
		if (libpaths.length)
		{
			string[] t;
			foreach (pp; libpaths)
				t ~= translateMacros(pp, report, key);
			link ~= Meta("AdditionalLibraryDirectories", join(t, ";"));
		}
		if (deps.length)
			link ~= Meta("AdditionalDependencies", join(deps, ";"));

		string[] extra;
		string deffile = cfg.get("deffile");
		if (deffile.length)
			link ~= Meta("ModuleDefinitionFile", translateMacros(deffile, report, key));
		else if (defItems.length)
		{
			link ~= Meta("ModuleDefinitionFile", defItems[0]);
			foreach (dd; defItems[1 .. $])
				extra ~= "/DEF:\"" ~ dd ~ "\"";
		}

		foreach (opt; linkopts)
		{
			string o = stripChars(opt, '"');
			string up = toUpper(o);
			if (up.length >= 7 && up[0 .. 7] == "/STACK:")
			{
				string val = o[7 .. $];
				int comma = cast(int)indexOf(val, ',');
				if (comma >= 0)
				{
					link ~= Meta("StackReserveSize", val[0 .. comma]);
					link ~= Meta("StackCommitSize", val[comma + 1 .. $]);
				}
				else
					link ~= Meta("StackReserveSize", val);
			}
			else if (up.length >= 11 && up[0 .. 11] == "/SUBSYSTEM:")
			{
				size_t colon = indexOf(o, ':');
				string rest = colon == size_t.max ? "" : o[colon + 1 .. $];
				size_t cm = indexOf(rest, ',');
				string val = cm == size_t.max ? rest : rest[0 .. cm];
				string vv = toUpper(val);
				if (vv == "CONSOLE" || vv == "WINDOWS" || vv == "NATIVE" || vv == "POSIX")
					link ~= Meta("SubSystem", vv);
				else
					extra ~= o;
			}
			else
				extra ~= o;
		}
		foreach (opt; words(cfg.get("linkswitches")))
			extra ~= translateMacros(opt, report, key);
		if (extra.length)
			link ~= Meta("AdditionalOptions", join(extra, " "));
		if (outfile !is null && outfile.length)
			link ~= Meta("OutputFile", outfile);
		return link;
	}

	FileEvent[] events(VdConfig cfg)
	{
		FileEvent[] res;
		if (strip(cfg.get("preBuildCommand")).length)
			res ~= FileEvent("PreBuildEvent", "Command",
				translateMacros(cfg.get("preBuildCommand"), report, cfg.key()));
		if (strip(cfg.get("postBuildCommand")).length)
			res ~= FileEvent("PostBuildEvent", "Command",
				translateMacros(cfg.get("postBuildCommand"), report, cfg.key()));
		return res;
	}

	// ---------------- items

	string itemType(string path, string tool)
	{
		string ext = toLower(pathSplitext(path)[1]);
		if (tool == "DMD" || tool == "DMDsingle" || tool == "RDMD")
			return "DCompile";
		if (tool == "Resource Compiler")
			return "ResourceCompile";
		if (tool == "C/C++")
			return "ClCompile";
		if (ext == ".d" || ext == ".ddoc")
			return "DCompile";
		if (ext == ".rc")
			return "ResourceCompile";
		if (ext == ".idl")
			return "Midl";
		if (ext == ".h" || ext == ".hpp" || ext == ".hxx" || ext == ".inl" || ext == ".r" || ext == ".di")
			return "ClInclude";
		if (ext == ".c" || ext == ".cpp" || ext == ".cxx" || ext == ".cc")
			return "ClCompile";
		if (ext == ".lib")
			return "Library";
		if (ext == ".obj" || ext == ".o")
			return "Object";
		if (ext == ".def")
			return "Def";
		return "None";
	}

	// The <Folder> directly below <Project> is the project node itself rather than a
	// filter folder: dproject.d hands its children straight to the CProjectNode and
	// uses its name as the project name. It must not become a top level filter.
	void walk(xml.Element node, string filterpath, bool root = false)
	{
		foreach (ch; node.elements)
		{
			if (ch.tag.name == "Folder")
			{
				if (root)
				{
					walk(ch, filterpath);
					continue;
				}
				string sub = attrValue(ch, "name");
				if (sub is null)
					sub = "";
				string fp = !filterpath.length ? sub : filterpath ~ "\\" ~ sub;
				if (fp.length)
					folders ~= fp;
				walk(ch, fp);
			}
			else if (ch.tag.name == "File")
				addFile(ch, filterpath);
			else if (ch.tag.name == "Config" || root)
				continue;
			else
				throw new Exception("unexpected <" ~ ch.tag.name ~ "> element in " ~ p.path);
		}
	}

	private static string attrOr(xml.Element e, string name)
	{
		string v = attrValue(e, name);
		return v is null ? "" : v;
	}

	/// The attribute text as the .visualdproj writes it, without the line breaks being
	/// folded into spaces.  A custom build command needs them: they are its command lines.
	private static string rawAttrOr(xml.Element e, string name)
	{
		string v = xml.getAttribute(e, name);
		return v is null ? "" : v;
	}

	void addFile(xml.Element elem, string filterpath)
	{
		string path = attrOr(elem, "path");
		string tool = attrOr(elem, "tool");
		string base = itemType(path, tool);
		PerCfgMap percfg;
		foreach (s; childElements(elem, "Config"))
		{
			string cname = attrValue(s, "name");
			if (cname is null)
				cname = "";
			AttrMap attrs;
			foreach (string k, string v; s.tag.attr)
				attrs[k] = k == "customcmd" ? v : normalizeAttr(v);
			percfg[cname] = attrs;
		}

		if (tool == "Custom")
		{
			addCustomBuild(elem, percfg, filterpath, path);
			return;
		}
		if (base == "Def")
		{
			defItems ~= translateMacros(path, report, path);
			report.note(path ~ ": handed to the linker as ModuleDefinitionFile");
			items ~= Item("None", path, filterpath, null, percfg);
			return;
		}
		if (toLower(pathSplitext(path)[1]) == ".res")
			resItems ~= path;
		Meta[] meta;
		if (attrOr(elem, "addopt").length)
			meta ~= Meta("AdditionalOptions", translateMacros(attrOr(elem, "addopt"), report, path));
		if (attrOr(elem, "outfile").length && base == "DCompile")
		{
			meta ~= Meta("ObjectFileName", translateMacros(attrOr(elem, "outfile"), report, path));
			report.lossy(path ~ ": 'outfile' names the object file of this module");
		}
		if (attrOr(elem, "dependencies").length && base == "DCompile")
			report.lossy(path ~ ": per-file dependencies are tracked by MSBuild itself");
		if (tool == "None")
			meta ~= Meta("ExcludedFromBuild", "true");
		items ~= Item(base, path, filterpath, meta, percfg);
	}

	void addCustomBuild(xml.Element elem, ref PerCfgMap percfg, string filterpath, string path)
	{
		string cmd = rawAttrOr(elem, "customcmd");
		string ext = toLower(pathSplitext(path)[1]);
		if (cmd.length && opts.nativeTools && (ext == ".idl" || ext == ".rc"))
		{
			string kind = ext == ".idl" ? "midl" : "rc";
			ToolParsed parsed;
			if (parseToolCmd(cmd, kind, path, parsed))
			{
				addNativeTool(kind, path, parsed, elem, percfg, filterpath);
				return;
			}
			report.lossy(path ~ ": the custom command is not a plain " ~ kind ~ " invocation; it is "
				~ "kept as a CustomBuild step");
		}
		if (!cmd.length)
		{
			items ~= Item(itemType(path, ""), path, filterpath, null, percfg);
			return;
		}
		Meta[] meta;
		meta ~= Meta("Command", translateMacros(cmd, report, path, true));
		if (attrOr(elem, "outfile").length)
			meta ~= Meta("Outputs", translateMacros(attrOr(elem, "outfile"), report, path, true));
		if (attrOr(elem, "dependencies").length)
		{
			string[] t;
			foreach (dd; words(attrOr(elem, "dependencies")))
				t ~= translateMacros(dd, report, path, true);
			meta ~= Meta("AdditionalDependencies", join(t, ";"));
		}
		if (attrOr(elem, "linkoutput") == "true")
		{
			meta ~= Meta("LinkObjects", "true");
			report.note(path ~ ": the output of the custom build step is linked "
				~ "(CustomBuild LinkObjects=true)");
		}
		if (attrOr(elem, "uptodateWithSameTime") == "true")
			report.lossy(path ~ ": 'uptodateWithSameTime' has no CustomBuild equivalent");
		items ~= Item("CustomBuild", path, filterpath, meta, percfg);
	}

	// The tables the midl/rc custom steps are mapped onto.
	// (SKIP_LINE_PREFIX in the Python tool is never used, so it is not ported.)

	string expandInputMacros(string s, string path)
	{
		string full = pathNormpath(p.dir ~ pathNormpath(path));
		string base = pathSplitext(pathBasename(path))[0];
		string ext = pathSplitext(path)[1];
		string[string] rep;
		rep["inputpath"] = full;
		rep["inputfilename"] = pathBasename(path);
		rep["inputname"] = base;
		rep["rootname"] = base;
		rep["filename"] = base;
		rep["inputdir"] = pathDirname(full) ~ "\\";
		rep["inputext"] = ext;
		rep["ext"] = ext;
		// MACRO_RE.sub(lambda m: rep.get(m.group(1).lower(), m.group(0)), s)
		auto app = appender!string();
		size_t i = 0;
		while (i < s.length)
		{
			if (s[i] == '$' && i + 1 < s.length && s[i + 1] == '(')
			{
				size_t j = i + 2;
				if (j < s.length && isIdentStart(s[j]))
				{
					size_t start = j;
					while (j < s.length && isIdentChar(s[j]))
						++j;
					if (j < s.length && s[j] == ')')
					{
						string name = s[start .. j];
						string v = rep.get(toLower(name), null);
						app.put(v is null ? s[i .. j + 1] : v);
						i = j + 1;
						continue;
					}
				}
			}
			app.put(s[i]);
			++i;
		}
		return app.data;
	}

	string toolValue(string path, string value)
	{
		return translateMacros(macroNormpath(expandInputMacros(value, path)), report, path);
	}

	/// Is this token a command position for midl/rc (bare, %var% or a full path)?
	bool isToolToken(string tok, string kind)
	{
		if (indexOf(tok, '=') >= 0)
			return false;
		string t = stripChars(tok, '"');
		if (t.length && t[0] == '%' && t[$ - 1] == '%')
			t = t.length >= 2 ? t[1 .. $ - 1] : "";
		t = replace(t, "\\", "/");
		while (t.length && t[$ - 1] == '/')
			t = t[0 .. $ - 1];
		t = toLower(t);
		if (t.length >= 4 && t[$ - 4 .. $] == ".exe")
			t = t[0 .. $ - 4];
		string suffix = "/" ~ kind;
		return t == kind || (t.length >= suffix.length && t[$ - suffix.length .. $] == suffix);
	}

	/// Recognize a plain midl/rc invocation behind the usual environment preamble.
	///
	/// The XML parser folds the newlines of the multi-line command into spaces, so the
	/// invocation is found by scanning the tokens: it is the last command of the step.
	bool parseToolCmd(string cmd, string kind, string path, out ToolParsed parsed)
	{
		string[] toks = words(cmd);
		int start = -1;
		foreach (size_t i, tok; toks)
		{
			if (tok == "&&" || tok == "|" || tok == "(" || tok == ")")
				continue;
			if (isToolToken(tok, kind))
				start = cast(int)i;
		}
		if (start < 0)
			return false;
		string[] args;
		foreach (tok; toks[cast(size_t)start + 1 .. $])
		{
			if (tok == "&&" || tok == "|" || tok == ")")
				break;
			args ~= tok;
		}
		if (start)
			report.note(path ~ ": the environment setup of the custom step is dropped, a C++ "
				~ "project already has it");

		string[] extra;
		string[] positional;
		size_t i = 0;
		while (i < args.length)
		{
			string a = args[i];
			if (!a.length || (a[0] != '/' && a[0] != '-'))
			{
				positional ~= stripChars(a, '"');
				++i;
				continue;
			}
			string sw = a[1 .. $];
			string name = sw;
			string val = "";
			size_t colon = indexOf(sw, ':');
			size_t eq = indexOf(sw, '=');
			if (colon != size_t.max)
			{
				name = sw[0 .. colon];
				val = sw[colon + 1 .. $];
			}
			else if (eq != size_t.max)
			{
				name = sw[0 .. eq];
				val = sw[eq + 1 .. $];
			}
			if (!val.length)
			{
				string low = toLower(sw);
				foreach (prefix; SWITCH_PREFIXES)
				{
					if (low.length >= prefix.length && low[0 .. prefix.length] == prefix)
					{
						name = prefix;
						val = sw[prefix.length .. $];
						break;
					}
				}
			}
			name = toLower(name);
			if (!stripChars(val, '"').length && valueSwitchHas(kind, name) && i + 1 < args.length)
			{
				val = args[i + 1];
				++i;
			}
			addSwitch(parsed.switches, name, stripChars(val, '"'));
			++i;
		}

		// the source file the step is run for is implied by the item
		string[] inputs = ["$(inputpath)", "$(inputdir)$(inputfilename)", toLower(pathNormpath(path))];
		foreach (pp; positional)
		{
			bool found = false;
			string low = toLower(pp);
			foreach (in2; inputs)
				if (low == in2)
					{ found = true; break; }
			if (!found)
				extra ~= pp;
		}
		parsed.extra = extra;
		return true;
	}

	void addNativeTool(string kind, string path, ref ToolParsed parsed, xml.Element elem,
					   ref PerCfgMap percfg, string filterpath)
	{
		Meta[] meta;
		string deps = attrOr(elem, "dependencies");
		if (deps.length)
		{
			string[] t;
			foreach (dd; words(deps))
				t ~= translateMacros(dd, report, path, true);
			meta ~= Meta("AdditionalDependenciesMetadata", join(t, ";"));
		}
		string[] extra = parsed.extra;
		if (kind == "midl")
		{
			report.note(path ~ ": custom build step converted to the Midl tool");
			string[] v;
			v = swGet(parsed, "d");
			if (v.length)
				meta ~= Meta("PreprocessorDefinitions", join(v, ";") ~ ";%(PreprocessorDefinitions)");
			v = swGet(parsed, "i");
			if (v.length)
			{
				string[] t;
				foreach (ii; v)
					t ~= toolValue(path, ii);
				meta ~= Meta("AdditionalIncludeDirectories", join(t, ";") ~ ";%(AdditionalIncludeDirectories)");
			}
			v = swGet(parsed, "out");
			if (v.length)
				meta ~= Meta("OutputDirectory", toolValue(path, v[$ - 1]));
			v = swGet(parsed, "tlb");
			if (v.length)
			{
				string tlb = toolValue(path, v[$ - 1]);
				if (toLower(pathSplitext(pathBasename(tlb))[0]) != toLower(p.name))
					meta ~= Meta("TypeLibraryName", tlb);
				else
					report.note(path ~ ": the type library keeps the default name");
			}
			if (swHas(parsed, "oicf"))
				meta ~= Meta("GenerateStublessProxies", "true");
			foreach (err; swGet(parsed, "error"))
			{
				foreach (word; words(err))
				{
					string prop = MIDL_ERRORCHECK.get(toLower(word), null);
					if (prop !is null && prop.length)
						meta ~= Meta(prop, "true");
					else
						extra ~= "error " ~ word;
				}
			}
			v = swGet(parsed, "env");
			if (v.length)
			{
				string e2 = MIDL_ENV.get(toLower(v[$ - 1]), v[$ - 1]);
				meta ~= Meta("TargetEnvironment", e2);
			}
			v = swGet(parsed, "char");
			if (v.length)
			{
				string c2 = MIDL_CHAR.get(toLower(v[$ - 1]), v[$ - 1]);
				meta ~= Meta("DefaultCharType", c2);
			}
			if (!swHas(parsed, "nologo"))
				meta ~= Meta("SuppressStartupBanner", "false");
			v = swGet(parsed, "w");
			meta ~= Meta("WarningLevel", v.length ? v[$ - 1] : "");
			v = swGet(parsed, "h");
			meta ~= Meta("HeaderFileName", v.length ? toolValue(path, v[$ - 1]) : "");
			v = swGet(parsed, "target");
			meta ~= Meta("MinimumTargetSystem", v.length ? v[$ - 1] : "");
			immutable string[] known = [
				"d", "i", "u", "out", "tlb", "oicf", "error", "env", "char", "h", "w",
				"target", "nologo", "errorchecknone", "wmf", "app_config", "prefix",
			];
			foreach (name; sortedUnknown(parsed.switches, known))
				foreach (val; parsed.switches[name])
					extra ~= name ~ (val.length ? " " ~ val : "");
		}
		else
		{
			report.note(path ~ ": custom build step converted to the ResourceCompile tool");
			string[] v;
			v = swGet(parsed, "fo");
			if (v.length)
				meta ~= Meta("ResourceOutputFileName", toolValue(path, v[$ - 1]));
			v = swGet(parsed, "i");
			if (v.length)
			{
				string[] t;
				foreach (ii; v)
					t ~= toolValue(path, ii);
				meta ~= Meta("AdditionalIncludeDirectories", join(t, ";") ~ ";%(AdditionalIncludeDirectories)");
			}
			v = swGet(parsed, "d");
			if (v.length)
				meta ~= Meta("PreprocessorDefinitions", join(v, ";") ~ ";%(PreprocessorDefinitions)");
			v = swGet(parsed, "l");
			if (v.length)
				meta ~= Meta("Culture", v[$ - 1]);
			if (!swHas(parsed, "nologo"))
				meta ~= Meta("SuppressStartupBanner", "false");
			immutable string[] known = ["fo", "i", "d", "u", "l", "c", "r", "nologo", "language", "t"];
			foreach (name; sortedUnknown(parsed.switches, known))
				foreach (val; parsed.switches[name])
					extra ~= name ~ (val.length ? " " ~ val : "");
			if (attrOr(elem, "linkoutput") == "true")
				report.note(path ~ ": the .res produced by ResourceCompile is linked by the "
					~ "C++ build");
		}
		string[] uv = swGet(parsed, "u");
		if (uv.length)
		{
			string[] t;
			foreach (u; uv)
				t ~= "/U " ~ u;
			meta ~= Meta("AdditionalOptions", join(t, " "));
		}
		if (extra.length)
		{
			string joined = join(extra, ", ");
			string opts2 = joinSlash(extra);
			report.lossy(path ~ ": " ~ joined ~ " cannot be expressed as "
				~ (kind == "midl" ? "Midl" : "ResourceCompile")
				~ " metadata and is passed as AdditionalOptions: " ~ opts2);
			if (meta.length && meta[$ - 1].name == "AdditionalOptions")
				meta[$ - 1] = Meta("AdditionalOptions", meta[$ - 1].value ~ " " ~ opts2);
			else
				meta ~= Meta("AdditionalOptions", opts2);
		}
		const string[string] toolDefaults = kind == "midl" ? MIDL_DEFAULTS : RC_DEFAULTS;
		Meta[] kept;
		foreach (m; meta)
		{
			string dv = toolDefaults.get(toLower(m.name), null);
			if (dv == m.value)
				continue;
			kept ~= m;
		}
		items ~= Item(kind == "midl" ? "Midl" : "ResourceCompile", path, filterpath, kept, percfg);
	}

	/// Per-configuration file overrides become conditioned metadata.
	Meta[] perConfigMetadata(ref PerCfgMap percfg, bool custom = false)
	{
		Meta[] out_;
		string[] names;
		foreach (k; percfg.keys)
			names ~= k;
		sort(names);
		foreach (name; names)
		{
			string cond = "'$(Configuration)|$(Platform)'=='" ~ name ~ "'";
			AttrMap attrs = percfg[name];
			string[] keys;
			foreach (k; attrs.keys)
				keys ~= k;
			sort(keys);
			foreach (key; keys)
			{
				string val = attrs[key];
				if (key == "name")
					continue;
				if (key == "tool")
				{
					if (val == "None")
						out_ ~= Meta("ExcludedFromBuild", "true", [cond]);
					else
						report.lossy("per-config file tool '" ~ val ~ "' is not converted (" ~ name ~ ")");
					continue;
				}
				if (key == "linkoutput")
				{
					if (val == "true")
						out_ ~= Meta("LinkObjects", "true", [cond]);
					continue;
				}
				if (key == "dependencies")
				{
					string[] t;
					foreach (dd; words(val))
						t ~= translateMacros(dd, report, name, custom);
					out_ ~= Meta("AdditionalDependencies", join(t, ";"), [cond]);
					continue;
				}
				string metaName = PERCFG_META.get(key, null);
				if (metaName is null || !metaName.length)
				{
					report.lossy("per-config file attribute '" ~ key ~ "' is not converted (" ~ name ~ ")");
					continue;
				}
				out_ ~= Meta(metaName, translateMacros(val, report, name, custom), [cond]);
			}
		}
		Meta[] merged;
		foreach (m; out_)
		{
			bool found = false;
			foreach (ref e; merged)
			{
				if (e.name == m.name && e.value == m.value)
				{
					e.conds ~= m.conds;
					found = true;
					break;
				}
			}
			if (!found)
				merged ~= m;
		}
		Meta[] result;
		foreach (m; merged)
		{
			if (m.conds.length >= p.configs.length)
				result ~= Meta(m.name, m.value);
			else
				result ~= m;
		}
		return result;
	}

	// ---------------- driver

	void convert()
	{
		bool[string] seen;
		string[] names;
		foreach (cfg; p.configs)
			foreach (k; cfg.v.keys)
				if (!(k in seen))
				{
					seen[k] = true;
					names ~= k;
				}
		sort(names);
		foreach (key; names)
		{
			if (ciHas(DEAD_OPTIONS, key))
				report.ignored("<" ~ key ~ "> has no effect in Visual D either");
			else if (ciHas(UNSUPPORTED_OPTIONS.keys, key))
			{
				bool any = false;
				foreach (cfg; p.configs)
				{
					string g = cfg.get(key);
					if (g != "" && g != "0")
						{ any = true; break; }
				}
				if (any)
					report.unsupported("<" ~ key ~ ">: " ~ UNSUPPORTED_OPTIONS.get(toLower(key), null));
			}
			else if (ciHas(MAPPED_OPTIONS.keys, key))
				report.note("<" ~ key ~ ">: " ~ MAPPED_OPTIONS.get(toLower(key), null));
			else if (!ciHas(KNOWN_OPTIONS, key))
				report.unsupported("option <" ~ key ~ "> is not known to the converter");
		}

		walk(p.root, "", true);
		foreach (cfg; p.configs)
		{
			string[] linkopts;
			Meta[] d = dcompileMetadata(cfg, linkopts);
			Meta[] props = userProperties(cfg); // also computes outfile
			Meta[] lib;
			Meta[] link = linkMetadata(cfg, linkopts, lib);
			cfg.dcompile = stripDefaults(cfg, d);
			cfg.link = link;
			cfg.lib = lib;
			cfg.props = configProperties(cfg);
			cfg.dirs = props;
			cfg.events = events(cfg);
		}
		checkMetadataNames();
	}

	void checkMetadataNames()
	{
		foreach (cfg; p.configs)
			foreach (m; cfg.dcompile)
				if ((m.name in ruleProps) is null)
					report.unsupported(cfg.key() ~ ": the DCompile property '" ~ m.name
						~ "' is not defined by the MSBuild rules");
	}

	Meta[] stripDefaults(VdConfig cfg, Meta[] d)
	{
		if (opts.keepDefaults)
		{
			Meta[] res;
			foreach (m; d)
				if (m.value !is null)
					res ~= Meta(m.name, m.value);
			return res;
		}
		string[string] env;
		env["dcompiler"] = cfg.compiler();
		env["platform"] = cfg.platform;
		env["configuration"] = cfg.name;
		string[string] defs;
		foreach (dp; defaults)
			if (msbuildCondition(dp.cond, env))
				defs[dp.name] = dp.value;
		Meta[] res;
		foreach (m; d)
		{
			if (m.value is null)
				continue;
			auto q = m.name in defs;
			if (q !is null && *q == m.value)
				continue;
			// A rule boolean without SwitchFalse emits nothing for "false".
			auto r = m.name in ruleProps;
			if (m.value == "false" && r !is null && *r == "BoolProperty")
			{
				auto q2 = m.name in defs;
				string dv = q2 is null ? "false" : *q2;
				if (dv == "false")
					continue;
			}
			res ~= m;
		}
		return res;
	}

	// ---------------- emit

	void emitMetadata(ref string[] L, Meta[] items_)
	{
		foreach (m; items_)
		{
			string[] conds = m.conds;
			if (!conds.length)
				conds = [cast(string) null];
			foreach (cond; conds)
			{
				string attr = cond is null ? "" : " Condition=\"" ~ esc(cond) ~ "\"";
				if (m.value == "")
					L ~= "      <" ~ m.name ~ attr ~ "></" ~ m.name ~ ">";
				else
					L ~= "      <" ~ m.name ~ attr ~ ">" ~ esc(m.value) ~ "</" ~ m.name ~ ">";
			}
		}
	}

	string emit()
	{
		string[] L;
		L ~= `<?xml version="1.0" encoding="utf-8"?>`;
		L ~= `<Project DefaultTargets="Build" ToolsVersion="Current" `
			~ `xmlns="http://schemas.microsoft.com/developer/msbuild/2003">`;
		L ~= `  <ItemGroup Label="ProjectConfigurations">`;
		foreach (cfg; p.configs)
		{
			L ~= `    <ProjectConfiguration Include="` ~ esc(cfg.name) ~ "|" ~ esc(cfg.platform) ~ `">`;
			L ~= `      <Configuration>` ~ esc(cfg.name) ~ `</Configuration>`;
			L ~= `      <Platform>` ~ esc(cfg.platform) ~ `</Platform>`;
			L ~= `    </ProjectConfiguration>`;
		}
		L ~= `  </ItemGroup>`;
		L ~= `  <PropertyGroup Label="Globals">`;
		L ~= `    <ProjectGuid>` ~ esc(p.guid) ~ `</ProjectGuid>`;
		L ~= `    <Keyword>Win32Proj</Keyword>`;
		L ~= `    <RootNamespace>` ~ esc(p.name) ~ `</RootNamespace>`;
		L ~= `    <WindowsTargetPlatformVersion>10.0</WindowsTargetPlatformVersion>`;
		L ~= `  </PropertyGroup>`;
		L ~= `  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.Default.props" />`;
		foreach (cfg; p.configs)
		{
			L ~= `  <PropertyGroup Condition="'$(Configuration)|$(Platform)'=='`
				~ esc(cfg.name) ~ "|" ~ esc(cfg.platform) ~ `'" Label="Configuration">`;
			foreach (m; cfg.props)
				L ~= `    <` ~ m.name ~ `>` ~ esc(m.value) ~ `</` ~ m.name ~ `>`;
			L ~= `  </PropertyGroup>`;
		}
		L ~= `  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.props" />`;
		L ~= `  <ImportGroup Label="ExtensionSettings">`;
		L ~= `  </ImportGroup>`;
		L ~= `  <ImportGroup Label="PropertySheets">`;
		L ~= `    <Import Project="$(UserRootDir)\Microsoft.Cpp.$(Platform).user.props" `
			~ `Condition="exists('$(UserRootDir)\Microsoft.Cpp.$(Platform).user.props')" `
			~ `Label="LocalAppDataPlatform" />`;
		L ~= `  </ImportGroup>`;
		L ~= `  <PropertyGroup Label="UserMacros" />`;
		foreach (cfg; p.configs)
		{
			L ~= `  <PropertyGroup Condition="'$(Configuration)|$(Platform)'=='`
				~ esc(cfg.name) ~ "|" ~ esc(cfg.platform) ~ `'">`;
			foreach (m; cfg.dirs)
				L ~= `    <` ~ m.name ~ `>` ~ esc(m.value) ~ `</` ~ m.name ~ `>`;
			L ~= `  </PropertyGroup>`;
		}

		foreach (cfg; p.configs)
		{
			if (!(cfg.dcompile.length || cfg.link.length || cfg.lib.length || cfg.events.length))
				continue;
			L ~= `  <ItemDefinitionGroup Condition="'$(Configuration)|$(Platform)'=='`
				~ esc(cfg.name) ~ "|" ~ esc(cfg.platform) ~ `'">`;
			if (cfg.dcompile.length)
			{
				L ~= `    <DCompile>`;
				emitMetadata(L, cfg.dcompile);
				L ~= `    </DCompile>`;
			}
			static immutable string[2] tags = ["Link", "Lib"];
			Meta[][2] groups = [cfg.link, cfg.lib];
			foreach (gi; 0 .. 2)
			{
				if (!groups[gi].length)
					continue;
				L ~= `    <` ~ tags[gi] ~ `>`;
				emitMetadata(L, groups[gi]);
				L ~= `    </` ~ tags[gi] ~ `>`;
			}
			foreach (ev; cfg.events)
			{
				L ~= `    <` ~ ev.group ~ `>`;
				L ~= `      <` ~ ev.meta ~ `>` ~ esc(ev.value) ~ `</` ~ ev.meta ~ `>`;
				L ~= `    </` ~ ev.group ~ `>`;
			}
			L ~= `  </ItemDefinitionGroup>`;
		}

		if (opts.projectRefs)
		{
			string[2][] refs;
			foreach (cfg; p.configs)
				foreach (guid; depsOfProject())
				{
					// MSBuild cannot load a .visualdproj, so a project that is
					// converted along with this one is referenced through the
					// .vcxproj generated for it instead of its solution entry.
					string path = opts.refVcxproj.get(guid, null);
					if (path is null || !path.length)
						path = slnProjects.get(guid, null);
					if (path is null || !path.length)
						continue;
					string rel = pathRelpath(path, rstripSeps(p.dir));
					bool dup = false;
					foreach (r; refs)
						if (r[0] == rel && r[1] == guid)
							{ dup = true; break; }
					if (!dup)
						refs ~= [rel, guid];
				}
			if (refs.length)
			{
				L ~= `  <ItemGroup>`;
				foreach (r; refs)
				{
					L ~= `    <ProjectReference Include="` ~ esc(r[0]) ~ `">`;
					L ~= `      <Project>` ~ esc(r[1]) ~ `</Project>`;
					L ~= `    </ProjectReference>`;
				}
				L ~= `  </ItemGroup>`;
			}
		}

		L ~= `  <ItemGroup>`;
		foreach (it; itemOrder)
			foreach (ref item; items)
			{
				if (item.type != it)
					continue;
				Meta[] allmeta = item.meta.dup;
				allmeta ~= perConfigMetadata(item.percfg, item.type == "CustomBuild");
				if (!allmeta.length)
				{
					L ~= `    <` ~ item.type ~ ` Include="` ~ esc(item.path) ~ `" />`;
					continue;
				}
				L ~= `    <` ~ item.type ~ ` Include="` ~ esc(item.path) ~ `">`;
				emitMetadata(L, allmeta);
				L ~= `    </` ~ item.type ~ `>`;
			}
		L ~= `  </ItemGroup>`;
		L ~= `  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.targets" />`;
		L ~= `  <ImportGroup Label="ExtensionTargets">`;
		L ~= `  </ImportGroup>`;
		L ~= `</Project>`;
		return join(L, "\n") ~ "\n";
	}

	string emitFilters()
	{
		string[] L;
		L ~= `<?xml version="1.0" encoding="utf-8"?>`;
		L ~= `<Project ToolsVersion="Current" `
			~ `xmlns="http://schemas.microsoft.com/developer/msbuild/2003">`;
		L ~= `  <ItemGroup>`;
		string[] unique;
		foreach (fp; folders)
		{
			bool dup = false;
			foreach (e; unique)
				if (e == fp)
					{ dup = true; break; }
			if (!dup)
				unique ~= fp;
		}
		foreach (fp; unique)
		{
			L ~= `    <Filter Include="` ~ esc(fp) ~ `">`;
			string id = sha1UUID("visuald/" ~ p.name ~ "/" ~ fp, urlNamespace).toString();
			L ~= `      <UniqueIdentifier>{` ~ toUpper(id) ~ `}</UniqueIdentifier>`;
			L ~= `    </Filter>`;
		}
		L ~= `  </ItemGroup>`;
		foreach (it; itemOrder)
		{
			Item[] group;
			foreach (ref item; items)
				if (item.type == it && item.filter.length)
					group ~= item;
			if (!group.length)
				continue;
			L ~= `  <ItemGroup>`;
			foreach (ref item; group)
			{
				L ~= `    <` ~ item.type ~ ` Include="` ~ esc(item.path) ~ `">`;
				L ~= `      <Filter>` ~ esc(item.filter) ~ `</Filter>`;
				L ~= `    </` ~ item.type ~ `>`;
			}
			L ~= `  </ItemGroup>`;
		}
		L ~= `</Project>`;
		return join(L, "\n") ~ "\n";
	}
}

// --------------------------------------------------------------------- converter helpers

/// Python's str.strip('"').
private string stripChars(string s, char c)
{
	if (s is null)
		return null;
	size_t i = 0;
	size_t j = s.length;
	while (i < j && s[i] == c)
		++i;
	while (j > i && s[j - 1] == c)
		--j;
	return s[i .. j];
}

/// {0: "Debug", 1: "Release", 2: "Default"}.get(v, "Default")
private string debugCodeName(int v)
{
	switch (v)
	{
		case 0: return "Debug";
		case 1: return "Release";
		case 2: return "Default";
		default: return "Default";
	}
}

/// {2: "libcmtd.lib", 3: "msvcrt.lib", 4: "msvcrtd.lib"}.get(v)
private string crtLibName(int v)
{
	switch (v)
	{
		case 2: return "libcmtd.lib";
		case 3: return "msvcrt.lib";
		case 4: return "msvcrtd.lib";
		default: return null;
	}
}

private void addSwitch(ref string[][string] switches, string name, string val)
{
	auto p = name in switches;
	if (p is null)
		switches[name] = [val];
	else
		*p ~= val;
}

private string[] swGet(ref ToolParsed pr, string name)
{
	auto p = name in pr.switches;
	return p is null ? null : *p;
}

private bool swHas(ref ToolParsed pr, string name)
{
	return (name in pr.switches) !is null;
}

private bool valueSwitchHas(string kind, string name)
{
	return ciHas(kind == "midl" ? MIDL_VALUE_SWITCHES : RC_VALUE_SWITCHES, name);
}

/// sorted(set(switches) - known)
private string[] sortedUnknown(ref string[][string] switches, const string[] known)
{
	string[] res;
	foreach (name; switches.keys)
	{
		bool skip = false;
		foreach (k; known)
			if (k == name)
				{ skip = true; break; }
		if (!skip)
			res ~= name;
	}
	sort(res);
	return res;
}

/// " ".join("/" + e for e in extra)
private string joinSlash(const string[] extra)
{
	string[] t;
	foreach (e; extra)
		t ~= "/" ~ e;
	return join(t, " ");
}

immutable string[] SWITCH_PREFIXES = [
	"errorchecknone", "app_config", "oicf", "nologo", "env", "char",
	"error", "target", "wmf", "fo", "out", "tlb", "h", "i", "d", "w",
	"r", "m", "c", "u", "l", "t", "x",
];
immutable string[] MIDL_VALUE_SWITCHES = [
	"d", "u", "i", "out", "tlb", "h", "env", "char", "error",
	"target", "wmf", "prefix", "server", "x"
];
immutable string[] RC_VALUE_SWITCHES = ["fo", "i", "d", "u", "l", "c", "t"];
immutable string[string] MIDL_DEFAULTS = [    // the values Microsoft.Cpp.Common.props inherits
	"typelibraryname": "$(IntDir)$(ProjectName).tlb",
	"warninglevel": "1",
	"defaultchartype": "Signed",
	"suppressstartupbanner": "true",
	"headerfilename": "%(Filename)_h.h",
	"minimumtargetsystem": "NT60",
];
immutable string[string] RC_DEFAULTS = [
	"resourceoutputfilename": "$(IntDir)%(Filename).res",
	"suppressstartupbanner": "true",
	"culture": "0x0409",
];
immutable string[string] MIDL_ENV = [
	"win32": "Win32", "x64": "X64", "arm32": "ARM32",
	"arm64": "ARM64", "ia64": "Itanium", "x86": "Win32"
];
immutable string[string] MIDL_CHAR = [
	"signed": "Signed", "unsigned": "Unsigned", "ascii7": "Ascii",
	"ascii": "Ascii"
];
immutable string[string] MIDL_ERRORCHECK = [
	"stub_data": "ErrorCheckStubData",
	"allocations": "ErrorCheckAllocations",
	"bounds": "ErrorCheckBounds",
	"enumrange": "ErrorCheckEnumRange",
	"refpointers": "ErrorCheckRefPointers"
];
immutable string[string] PERCFG_META = [
	"customcmd": "Command", "outfile": "Outputs", "addopt": "AdditionalOptions"
];

// --------------------------------------------------------------------- filters uuid5



// --------------------------------------------------------------------- writing files

/// Python's os.makedirs(outdir, exist_ok=True).
private void ensureDir(string path)
{
	if (path.length && !exists(path))
		mkdirRecurse(path);
}
/// Python's open(path, "w", encoding="utf-8-sig", newline="\r\n").
private void writeTextFile(string path, string content)
{
	string t = replace(content, "\n", "\r\n");
	ubyte[] data = cast(ubyte[])"\xEF\xBB\xBF" ~ cast(ubyte[])t;
	write(path, data);
}

enum TextEncoding { utf8, utf8Bom, utf16Le, utf16Be }

/// Like readText, but also reports the encoding the file was stored in, so a
/// rewritten file can be handed back to Visual Studio exactly as it wrote it.
private string readTextEnc(string path, out TextEncoding enc)
{
	ubyte[] data;
	try
		data = cast(ubyte[])read(path);
	catch (Exception e)
		throw new Exception("cannot read " ~ path ~ " (" ~ e.msg ~ ")");
	if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xFE)
	{
		enc = TextEncoding.utf16Le;
		return decodeUtf16(data);
	}
	if (data.length >= 2 && data[0] == 0xFE && data[1] == 0xFF)
	{
		enc = TextEncoding.utf16Be;
		return decodeUtf16(data);
	}
	size_t i = 0;
	if (data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF)
	{
		enc = TextEncoding.utf8Bom;
		i = 3;
	}
	else
		enc = TextEncoding.utf8;
	return utf8Replace(data[i .. $]);
}

/// Write text back in the encoding it was read in, without touching line endings.
private void writeTextFileEnc(string path, string content, TextEncoding enc)
{
	ubyte[] data;
	final switch (enc)
	{
		case TextEncoding.utf8:
			data = cast(ubyte[])content.dup;
			break;
		case TextEncoding.utf8Bom:
			data = cast(ubyte[])"\xEF\xBB\xBF" ~ cast(ubyte[])content;
			break;
		case TextEncoding.utf16Le:
			data = cast(ubyte[])"\xFF\xFE" ~ encodeUtf16(content, true);
			break;
		case TextEncoding.utf16Be:
			data = cast(ubyte[])"\xFE\xFF" ~ encodeUtf16(content, false);
			break;
	}
	try
		write(path, data);
	catch (Exception e)
		throw new Exception("cannot write " ~ path ~ " (" ~ e.msg ~ ")");
}

private ubyte[] encodeUtf16(string s, bool le)
{
	ubyte[] res;
	res.reserve(s.length * 2 + 2);
	foreach (dchar cp; s)
	{
		if (cp >= 0x10000)
		{
			dchar v = cp - 0x10000;
			putUtf16(res, cast(ushort)(0xD800 + (v >> 10)), le);
			putUtf16(res, cast(ushort)(0xDC00 + (v & 0x3FF)), le);
		}
		else
			putUtf16(res, cast(ushort)cp, le);
	}
	return res;
}

private void putUtf16(ref ubyte[] res, ushort u, bool le)
{
	res ~= le ? cast(ubyte)(u & 0xFF) : cast(ubyte)(u >> 8);
	res ~= le ? cast(ubyte)(u >> 8) : cast(ubyte)(u & 0xFF);
}

// --------------------------------------------------------------------- the public API

struct ConvertOptions
{
	string outDir;        // output directory; empty => same dir as the project file
	string name;          // override project/file name; empty => derived from the project file
	string slnPath;       // explicit .sln to use; empty => search parent directories
	string msbuildDir;    // explicit dir with dmd.xml/dcompile_defaults.props; empty => search upward
	bool projectRefs;
	bool keepDefaults;
	bool writeFilters = true;
	bool nativeTools = true;
	bool updateSolution;  // point the .sln entry at the generated .vcxproj
	bool dryRun;
	string[string] refVcxproj;  // project guid -> .vcxproj to emit as a ProjectReference
}

struct ConvertResult
{
	string report;        // the human readable text the Python tool prints (summary + report)
	string vcxprojPath;   // file written (or that would be written for dryRun)
	string filtersPath;   // "" when not written
	string reportOnly;    // just the UNSUPPORTED/LOSSY/IGNORED/NOTES buckets (--report writes this)
	string slnPath;       // the solution that was (or would be) updated
	bool slnUpdated;      // the solution really did change
	size_t vcxprojChars;  // len() of the emitted text, as Python counts characters
	size_t filtersChars;
	bool dryRun;
}

/// The "  %-24s %-6s %-5s %s" summary line of one configuration.
private string configSummaryLine(VdConfig cfg)
{
	string name = cfg.name is null ? "None" : cfg.name;
	string platform = cfg.platform is null ? "None" : cfg.platform;
	string ct = configurationTypeName(cfg.outputType());
	return format("  %-24s %-6s %-5s %s\n", name, platform, cfg.compiler(),
		ct is null ? "None" : ct);
}

ConvertResult convertVisualDProject(string projPath, ConvertOptions opt)
{
	VdProject project = new VdProject(projPath, opt.name.length ? opt.name : null);

	string sln = opt.slnPath;
	if (!sln.length)
		sln = findSolution(project.dir);
	if (sln.length)
		sln = pathAbspath(sln);
	string msbuildDir = opt.msbuildDir;
	if (msbuildDir.length)
		msbuildDir = pathAbspath(msbuildDir);
	if (!msbuildDir.length || !fileExists(pathJoin(msbuildDir, "dmd.xml")))
		throw new Exception("cannot find the MSBuild rules (msbuild/dmd.xml); pass --msbuild-dir");

	ConvertOptions resolved = opt;
	resolved.slnPath = sln;
	resolved.msbuildDir = msbuildDir;

	Report rep = new Report;
	Converter conv = new Converter(project, resolved, rep);
	conv.convert();

	string summary;
	summary ~= "project : " ~ project.path ~ "\n";
	if (sln.length)
		summary ~= "solution: " ~ sln ~ "\n";
	summary ~= "rules   : " ~ msbuildDir ~ "\n";
	summary ~= "configs : " ~ text(project.configs.length) ~ ", items: " ~ text(conv.items.length) ~ "\n";
	foreach (cfg; project.configs)
		summary ~= configSummaryLine(cfg);
	summary ~= "\n";

	ConvertResult res;
	res.reportOnly = rep.text();
	res.report = summary ~ res.reportOnly;
	res.dryRun = opt.dryRun;

	string outdir = opt.outDir.length ? opt.outDir : project.dir;
	string projFile = pathJoin(outdir, project.name ~ ".vcxproj");
	res.vcxprojPath = projFile;
	if (!opt.dryRun)
	{
		ensureDir(outdir);
		string text_ = conv.emit();
		writeTextFile(projFile, text_);
		res.vcxprojChars = text_.walkLength;
		if (resolved.writeFilters)
		{
			string ftext = conv.emitFilters();
			writeTextFile(projFile ~ ".filters", ftext);
			res.filtersPath = projFile ~ ".filters";
			res.filtersChars = ftext.walkLength;
		}
	}
	if (resolved.updateSolution)
	{
		res.slnPath = resolved.slnPath;
		string msg = updateSolutionReference(resolved.slnPath, project, projFile, opt.dryRun, res.slnUpdated);
		res.reportOnly ~= msg;
		res.report ~= msg;
	}
	return res;
}

/// Swap the solution's entry for the converted project over to the .vcxproj.
/// Returns the text to append to the report, "" when there is nothing to say.
private string updateSolutionReference(string slnPath, VdProject project,
	string vcxprojPath, bool dryRun, out bool updated)
{
	updated = false;
	if (!slnPath.length)
		return "\nSolution: no .sln found above " ~ project.dir ~ "\n";
	string text_;
	TextEncoding enc;
	try
		text_ = readTextEnc(slnPath, enc);
	catch (Exception e)
		return "\nSolution: " ~ e.msg ~ "\n";

	string newPath = pathRelpath(vcxprojPath, pathDirname(slnPath));
	SlnRelink r = slnRelinkProject(text_, project.guid, project.path, pathDirname(slnPath),
		newPath, slnTypeGuidVcxproj);
	if (!r.found)
		return "\nSolution: " ~ slnPath ~ " does not contain " ~ pathBasename(project.path) ~ "\n";
	if (!r.changed)
		return "\nSolution: " ~ slnPath ~ " already links " ~ newPath ~ "\n";
	if (!dryRun)
	{
		try
			writeTextFileEnc(slnPath, r.text, enc);
		catch (Exception e)
			return "\nSolution: " ~ e.msg ~ "\n";
	}
	updated = true;
	return "\nSolution: " ~ (dryRun ? "would update " : "updated ") ~ slnPath ~ "\n"
		~ "  " ~ r.name ~ ": " ~ r.oldType ~ " " ~ r.oldPath ~ "\n"
		~ "                    -> " ~ r.newType ~ " " ~ r.newPath ~ "\n";
}

version(MAIN)
void main(string[] args)
{
	ConvertOptions opt;
	//opt.dryRun = true;
	opt.msbuildDir = r"c:\Program Files (x86)\VisualD\msbuild";
	string projPath = r"c:\Users\raine\source\repos\WindowsApplication1\VisualDApp1\VisualDApp1.visualdproj";
	auto res = convertVisualDProject(projPath, opt);
	import std.stdio;
	writeln(res.report);
}
