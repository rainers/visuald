// This file is part of Visual D
//
// Visual D integrates the D programming language into Visual Studio
// Copyright (c) 2026 by Rainer Schuetze, All Rights Reserved
//
// Distributed under the Boost Software License, Version 1.0.
// See accompanying file LICENSE.txt or copy at http://www.boost.org/LICENSE_1_0.txt

module visuald.ctfedebug;

// Starts a debug session for the D source in the active editor.
//
// The session is implemented by the "-ctfeDebug" mode of dmdserver
// (vdc/dmdserver/ctfedebug.d): it runs the DMD front end and stops it at every
// statement it interprets while evaluating a function at compile time. The
// adapter speaks the Debug Adapter Protocol, so VS hosts it through the debug
// adapter engine registered under AD7Metrics\Engine (see visuald/register.d).

import visuald.windows;
import visuald.comutil;
import visuald.config;
import visuald.dpackage;
import visuald.hierutil;
import visuald.pkgutil;
import visuald.vdserverclient;

import stdext.path;
import stdext.string;

import std.array;
import std.conv;
import std.file;
import std.format;
import std.path;
import std.string;
import std.utf;

import sdk.port.vsi;
import sdk.vsi.vsshell;
import sdk.vsi.vsshell100;
import sdk.vsi.vsshell110;

import dte80a = sdk.vsi.dte80a;
import dte80 = sdk.vsi.dte80;

////////////////////////////////////////////////////////////////////////
// The launch configuration of the CTFE debug session. The fields correspond
// to the keys understood by CtfeDebugSession.applyLaunch.
struct CtfeLaunchConfig
{
	string program;
	string adapter;
	string[] importPaths;
	string[] stringImportPaths;
	string[] versionIds;
	string[] debugIds;
	string options;
	string workDir;
	bool stopOnEntry;
}

////////////////////////////////////////////////////////////////////////
// Command handler: debug the D file in the active editor.
HRESULT StartCtfeDebug()
{
	string file = getActiveDSourceFile();
	if (file is null)
	{
		UtilMessageBox("The CTFE debugger starts on the D source file in the active editor,\n"
						   ~ "but the active document is not a .d or .di file.",
						   MB_OK | MB_ICONINFORMATION, "CTFE Debugger");
		return S_FALSE;
	}

	CtfeLaunchConfig cfg = getCtfeLaunchConfig(file);
	if (cfg.adapter is null || !std.file.exists(cfg.adapter))
	{
		UtilMessageBox("A dmdserver supporting the \"-ctfeDebug\" option could not be found.\n"
						   ~ "Reinstall Visual D to get one.",
						   MB_OK | MB_ICONINFORMATION, "CTFE Debugger");
		return S_FALSE;
	}

	string json = ctfeLaunchConfiguration(cfg);

	writeToBuildOutputPane("CTFE debug: " ~ file ~ "\n");

	// The debug adapter host command reads a launch.json file; it is the only
	// documented way to start a session without a project system.
	string launchFile = writeCtfeLaunchFile(cfg, json);
	HRESULT hr = launchDebugAdapterHost(launchFile);
	if (FAILED(hr))
		hr = launchCtfeDebugEngine(cfg, json);
	if (FAILED(hr))
		writeToBuildOutputPane("CTFE debug: cannot start debug session (hr = " ~ format("%08x", hr) ~ ")\n");
	return hr;
}

////////////////////////////////////////////////////////////////////////
// The D file in the active editor, or null if there is none.
string getActiveDSourceFile()
{
	dte80.DTE2 env = GetDTE();
	if (env is null)
		return null;
	scope(exit) release(env);

	dte80a.Document doc;
	if (env.get_ActiveDocument(&doc) != S_OK || doc is null)
		return null;
	scope(exit) release(doc);

	BSTR bstrName;
	if (doc.get_FullName(&bstrName) != S_OK)
		return null;
	string file = detachBSTR(bstrName);

	string ext = extension(file);
	if (ext != ".d" && ext != ".di")
		return null;
	return file;
}

////////////////////////////////////////////////////////////////////////
// dmdserver is built with the CTFE debug adapter, so any of the versioned
// servers will do. Fall back to the one in the installation directory.
string findCtfeDebugAdapter()
{
	if (string exe = findDmdServer())
		return exe;
	return buildPath(Package.GetGlobalOptions().VisualDInstallDir, "dmdserver.exe");
}

////////////////////////////////////////////////////////////////////////
// Collect the compiler settings for the file, following the same rules as the
// language service uses for semantic analysis (see
// DLangService.ConfigureSemanticProject).
CtfeLaunchConfig getCtfeLaunchConfig(string file)
{
	auto globopts = Package.GetGlobalOptions();

	CtfeLaunchConfig cfg;
	cfg.program = file;
	cfg.adapter = findCtfeDebugAdapter();
	cfg.workDir = dirName(file);

	Config config = getProjectConfig(file, true);
	if (config)
	{
		scope(exit) release(config);
		auto cfgopts = config.GetProjectOptions();

		cfg.importPaths = GetImportPaths(config) ~ globopts.getImportPaths(cfgopts.compiler);

		string strimp = cfgopts.replaceEnvironment(cfgopts.fileImppath, config);
		cfg.stringImportPaths = tokenizeArgs(strimp);
		foreach (ref i; cfg.stringImportPaths)
			i = normalizeDir(unquoteArgument(i));
		makeFilenamesAbsolute(cfg.stringImportPaths, config.GetProjectDir());

		cfg.versionIds = tokenizeArgs(config.getCompilerVersionIDs());
		cfg.debugIds = tokenizeArgs(cfgopts.debugids);

		cfg.options = cfgopts.dmdFrontEndOptions();
		string dir = normalizeDir(config.GetProjectDir());
		if (dir.length)
			cfg.workDir = dir;
	}
	else
	{
		// source file loaded into VS without a project
		cfg.importPaths = globopts.getImportPaths(Compiler.DMD);
		cfg.importPaths ~= dirName(file);
		cfg.options = globopts.compileAndRunOpts;
		cfg.versionIds = tokenizeArgs(Config.getCompilerVersionIDs("dmd " ~ cfg.options, ""));
	}

	// The adapter needs the file to be on disk; it reads it itself.
	return cfg;
}

////////////////////////////////////////////////////////////////////////
string ctfeLaunchConfiguration(const CtfeLaunchConfig cfg)
{
	string s = "{";
	s ~= `"name": "CTFE", `;
	s ~= `"type": "dmdserver-ctfe", `;
	s ~= `"request": "launch", `;
	s ~= `"$engineGuid": "` ~ jsonEscape(GUID2string(g_ctfeDebugEngineCLSID)) ~ `", `;
	s ~= `"$adapter": "` ~ jsonEscape(cfg.adapter) ~ `", `;
	s ~= `"$adapterArgs": "-ctfeDebug", `;
	s ~= `"program": "` ~ jsonEscape(cfg.program) ~ `", `;
	s ~= `"importPaths": [` ~ jsonArray(cfg.importPaths) ~ `], `;
	s ~= `"stringImportPaths": [` ~ jsonArray(cfg.stringImportPaths) ~ `], `;
	s ~= `"versionIds": [` ~ jsonArray(cfg.versionIds) ~ `], `;
	s ~= `"debugIds": [` ~ jsonArray(cfg.debugIds) ~ `], `;
	s ~= `"options": "` ~ jsonEscape(cfg.options) ~ `", `;
	s ~= `"stopOnEntry": ` ~ (cfg.stopOnEntry ? "true" : "false");
	s ~= "}";
	return s;
}

// The file the "DebugAdapterHost.Launch" command expects.
string ctfeLaunchFile(const CtfeLaunchConfig cfg, string json)
{
	return "{" ~
		`"version": "0.2.0", ` ~
		`"configurations": [` ~ json ~ "]" ~
	"}";
}

string jsonArray(const string[] strings)
{
	string s;
	foreach (i, str; strings)
	{
		if (i)
			s ~= ", ";
		s ~= `"` ~ jsonEscape(str) ~ `"`;
	}
	return s;
}

string jsonEscape(string s)
{
	string res;
	foreach (dchar c; s)
	{
		switch (c)
		{
			case '"':  res ~= "\\\""; break;
			case '\\': res ~= "\\\\"; break;
			case '\b': res ~= "\\b"; break;
			case '\f': res ~= "\\f"; break;
			case '\n': res ~= "\\n"; break;
			case '\r': res ~= "\\r"; break;
			case '\t': res ~= "\\t"; break;
			default:
				if (c < 0x20)
					res ~= format("\\u%04x", cast(int) c);
				else
					res ~= c;
				break;
		}
	}
	return res;
}

////////////////////////////////////////////////////////////////////////
// Write the launch.json for the session so that it can be inspected and reused.
string writeCtfeLaunchFile(const CtfeLaunchConfig cfg, string json)
{
	string name = baseName(cfg.program);
	name = name[0 .. $ - extension(name).length];
	string fname = buildPath(normalizeDir(tempDir()), "visuald-ctfe-" ~ name ~ ".launch.json");
	string text = ctfeLaunchFile(cfg, json);
	try
		write(fname, text);
	catch (Exception e)
	{
		writeToBuildOutputPane("CTFE debug: cannot write " ~ fname ~ ": " ~ e.msg ~ "\n");
	}
	return fname;
}

////////////////////////////////////////////////////////////////////////
// Start the session through the debug adapter host command. It uses the engine
// registered in the package definition, and the launch file written above.
HRESULT launchDebugAdapterHost(string launchFile)
{
	dte80.DTE2 env = GetDTE();
	if (env is null)
		return E_NOINTERFACE;
	scope(exit) release(env);

	BSTR cmd = allocBSTR("DebugAdapterHost.Launch");
	BSTR args = allocBSTR(`/LaunchJson:"` ~ launchFile ~ `" /ConfigurationName:"CTFE"`);
	scope(exit) { freeBSTR(cmd); freeBSTR(args); }

	return env.ExecuteCommand(cmd, args);
}

////////////////////////////////////////////////////////////////////////
// Ask the debugger to start the registered engine directly.
HRESULT launchCtfeDebugEngine(const CtfeLaunchConfig cfg, string options)
{
	IVsDebugger4 dbg4 = queryService!(IVsDebugger4)();
	if (dbg4 is null)
		return E_NOINTERFACE;
	scope(exit) release(dbg4);

	// if bstr-parameters not passed as BSTR parameters, VS2010 crashes on some systems
	VsDebugTargetInfo4 tgt;
	tgt.dlo = DLO_CreateProcess;
	tgt.bstrExe = allocBSTR(cfg.program);
	tgt.bstrCurDir = allocBSTR(cfg.workDir);
	tgt.guidLaunchDebugEngine = g_ctfeDebugEngineCLSID;
	tgt.bstrOptions = allocBSTR(options);
	tgt.fSendToOutputWindow = false;

	VsDebugTargetProcessInfo info;
	return dbg4.LaunchDebugTargets4(1, &tgt, &info);
}

int test()
{
	int s = 0;
	for(int i = 1; i < 10; i++)
		s += i;
	return s;
}

enum sum = test();
