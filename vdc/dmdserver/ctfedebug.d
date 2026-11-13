// This file is part of Visual D
//
// Visual D integrates the D programming language into Visual Studio
// Copyright (c) 2025 by Rainer Schuetze, All Rights Reserved
//
// Distributed under the Boost Software License, Version 1.0.
// See accompanying file LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt

// Debug Adapter Protocol server for the CTFE interpreter of the embedded DMD
// front end.
//
//      dmdserver.exe -ctfeDebug [options] [file.d]
//
// Instead of registering the COM language server, the process then speaks DAP on
// its standard input and output handles. This lets Visual Studio debug compile
// time function execution: breakpoints in D source are hit while the front end
// interprets a CTFE function, and the interpreter's call stack, local variables
// and global constants can be inspected.

module vdc.dmdserver.ctfedebug;

import vdc.dmdserver.dapio;
import vdc.dmdserver.dmdinit : Options, dmdInit, dmdSetupParams;
import vdc.dmdserver.semanalysis : runModuleSemantic;
import vdc.dmdserver.semvisitor : createModuleFromText;

import dmd.console : Color;
import dmd.dinterpret : InterState, ctfeCallDepth, ctfeCurrentFrameBase, ctfeGlobalDeclarations,
	ctfeGlobalValues, ctfeStackPointer, ctfeThisValue, ctfeValuesInRange, ctfeVariablesInRange,
	setCtfeStatementHook;
import dmd.dmodule : Module;
import dmd.declaration : VarDeclaration;
import dmd.dsymbol : Dsymbol;
import dmd.astenums : STC;
import dmd.errors : diagnosticHandler;
import dmd.expression : Expression, IntegerExp, NullExp, RealExp, StringExp;
import dmd.root.ctfloat : real_t;
import dmd.globals : dinteger_t;
import dmd.location : Loc, SourceLoc;
import dmd.statement : Statement;
import dmd.mtype : Type;
import dmd.typesem : toBasetype, isUnsigned;

import core.stdc.stdarg : va_list;
import core.stdc.stdio : vsnprintf;
import core.sys.windows.windows;
import core.thread : Thread;
import std.functional : toDelegate;

import std.algorithm : canFind, sort, startsWith;
import std.conv : to;
import std.file : read;
import std.json;
import std.path : absolutePath, buildNormalizedPath, extension;
import core.runtime : Runtime;
import std.string : fromStringz;


/// The session the interpreter hook reports to (null if no session is active).
__gshared CtfeDebugSession g_session;


/// Installed into the CTFE interpreter; forwards to the current session.
void ctfeStatementHook(InterState* istate, Statement s)
{
	if (auto ses = g_session)
		ses.onStatement(istate, s);
}


/// The arguments the process was started with.
///
/// dmdserver supplies its own `WinMain` and initializes the runtime through `rt_init()`,
/// so druntime never populates `Runtime.args`.
string[] commandLineArgs()
{
	string[] args;

	const(wchar)* p = GetCommandLineW();
	if (p is null)
		return args;

	while (*p)
	{
		while (*p == ' ' || *p == '\t')
			++p;
		if (!*p)
			break;

		string arg;
		bool inQuotes = false;
		while (*p && (inQuotes || (*p != ' ' && *p != '\t')))
		{
			const(wchar)* s = p;
			size_t slashes = 0;
			while (*s == '\\')
				++s, ++slashes;

			if (*s == '"')
			{
				foreach (_; 0 .. slashes / 2)
					arg ~= '\\';
				p = s + 1;
				if ((slashes & 1) == 0)
					inQuotes = !inQuotes; // the quote delimits the argument
				else
					arg ~= '"';          // it is escaped by the backslashes
				continue;
			}

			foreach (_; 0 .. slashes)
				arg ~= '\\';
			if (!*p)
				break;
			arg ~= cast(dchar) *p++;
		}
		args ~= arg;
	}
	return args;
}


/// Check the command line of dmdserver for the "-ctfeDebug" switch.
bool ctfeDebugRequested()
{
	foreach (arg; commandLineArgs())
		if (arg == "-ctfeDebug" || arg == "-ctfe-debug")
			return true;
	return false;
}

/// Run the DAP server until the client disconnects.
int ctfeDebugRun()
{
	auto conn = new DapConnection;
	if (!conn.isValid)
		return 1;

	auto ses = new CtfeDebugSession(conn);
	g_session = ses;
	ses.readCommandLine();

	while (!ses.quit)
	{
		JSONValue msg = conn.readMessage();
		if (msg.type != JSONType.object)
			break;
		ses.handleRequest(msg);
	}

	// The client is gone: wake up a suspended compilation and have it abandon the rest.
	synchronized (ses.lock)
		ses.abortRequested = true;
	SetEvent(ses.evResume);

	if (auto worker = ses.worker)
	{
		try
			worker.join();
		catch (Throwable e)
		{
		}
	}
	g_session = null;
	return 0;
}


enum RunMode
{
	none,
	running,
	stepIn,
	stepOver,
	stepOut,
}


/// Thrown into the compilation to give it up when the debug session ends.
class CtfeDebugAbort : Exception
{
	this() @safe { super("CTFE debug session ended"); }
}


/// One CTFE call stack frame as reported to the debugger.
struct CtfeFrame
{
	int id;
	InterState* istate;
	string name;
	string path;      // file name as used by the compiler
	string file;      // normalized, lower case, for breakpoint matching
	uint line;
	uint column;
	size_t varStart;  // CTFE stack range of this frame
	size_t varEnd;
}


/// A source line the debugger stops at, with an optional condition that is
/// evaluated in the context of the stop.
struct Breakpoint
{
	uint line;
	string condition;
	int id;         // DAP breakpoint id, handed out when the breakpoint is set
}


final class CtfeDebugSession
{
	DapConnection conn;

	Object lock;
	HANDLE evResume;

	// launch configuration
	string program;
	string source;            // in memory source, overrides program
	string[] importPaths;
	string[] stringImportPaths;
	string[] versionIds;
	string[] debugIds;
	string cmdline;
	bool stopOnEntry;

	// execution state, guarded by lock
	RunMode mode = RunMode.none;
	int stopCallDepth;
	int lastStopDepth;
	bool compileStarted;
	bool compileDone;
	bool atStop;
	bool abortRequested;
	bool pauseRequested;
	bool entryDone;
	bool quit;
	bool initializedSent;
	bool clientDisconnected;  // the DAP spec forbids events after a disconnect

	Breakpoint[][string] breakpoints;
	int nextBreakpointId = 1;  // normalized file name -> breakpoints
	string[size_t] fileNames;     // interned compiler file name -> normalized path

	// only valid while suspended at a stop
	CtfeFrame[] frames;
	Expression[int] valueHandles;
	int nextValueHandle = 1;

	// keeps the buffers of the strings created while evaluating alive
	string[] evalBuffers;

	Thread worker;

	enum threadId = 1;

	/// Pseudo variablesReference for the global constants (frame ids start at 1)
	enum globalsReference = 0x10000;

	this(DapConnection conn)
	{
		this.conn = conn;
		this.lock = new Object;
		this.evResume = CreateEventW(null, TRUE, FALSE, null);
	}

	// ---------------------------------------------------------------- launch

	void readCommandLine()
	{
		foreach (arg; commandLineArgs())
		{
			if (arg.length < 2)
				continue;

			if (arg[0] != '-')
			{
				string ext = extension(arg);
				if (program is null && (ext == ".d" || ext == ".di"))
					program = arg;
				continue;
			}

			if (arg == "-ctfeDebug" || arg == "-ctfe-debug")
				continue;
			else if (arg[1] == 'I' && arg.length > 2)
				importPaths ~= arg[2 .. $];
			else if (arg[1] == 'J' && arg.length > 2)
				stringImportPaths ~= arg[2 .. $];
			else if (arg.startsWith("-version="))
				versionIds ~= arg[9 .. $];
			else if (arg.startsWith("-d-version="))
				debugIds ~= arg[11 .. $];
			else
				cmdline ~= arg ~ " ";
		}
	}

	bool applyLaunch(JSONValue a)
	{
		string prog = getString(a, "program");
		if (prog is null)
			prog = getString(a, "targetArgument");
		if (prog is null)
			prog = getString(a, "sourceFile");
		if (prog !is null)
			program = prog;

		string src = getString(a, "source");
		if (src !is null)
			source = src;

		string[] dirs = getStringArray(a, "importPaths");
		if (dirs !is null)
			importPaths = dirs;

		dirs = getStringArray(a, "stringImportPaths");
		if (dirs !is null)
			stringImportPaths = dirs;

		string[] ids = getStringArray(a, "versionIds");
		if (ids !is null)
			versionIds = ids;

		ids = getStringArray(a, "debugIds");
		if (ids !is null)
			debugIds = ids;

		string options = getString(a, "options");
		if (options !is null)
			cmdline = options;

		stopOnEntry = getBool(a, "stopOnEntry", stopOnEntry);

		if (program is null)
			return false;

		try
			program = program.absolutePath;
		catch (Exception e)
		{
		}
		return true;
	}

	// ------------------------------------------------------------ compilation

	void startCompilation()
	{
		synchronized (lock)
		{
			if (compileStarted)
				return;
			compileStarted = true;
		}

		worker = new Thread(&compileWorker, 8 * 1024 * 1024);
		worker.name("ctfe");
		worker.start();
	}

	void compileWorker()
	{
		// The client waits for the exited/terminated events, whatever the outcome.
		scope (exit) finishCompilation();
		try
		{
			dmdInit();
			diagnosticHandler = toDelegate(&ctfeDiagnostic);

			Options opts;
			opts.importDirs = importPaths;
			opts.stringImportDirs = stringImportPaths;
			opts.versionIds = versionIds;
			opts.debugIds = debugIds;
			opts.cmdline = cmdline;
			opts.x64 = size_t.sizeof == 8;
			opts.debugOn = true;
			dmdSetupParams(opts);

			string text = source;
			if (text is null)
			{
				try
					text = cast(string) read(program);
				catch (Exception e)
				{
					outputMessage("stderr", program ~ ": cannot read file: " ~ e.msg ~ "\n");
					return;
				}
			}

			setCtfeStatementHook(&ctfeStatementHook);
			scope (exit) setCtfeStatementHook(null);

			runModuleSemantic(createModuleFromText(program, text));
		}
		catch (CtfeDebugAbort e)
		{
			outputMessage("console", "debug session ended\n");
		}
		catch (Throwable e)
		{
			outputMessage("stderr", "error: " ~ e.toString() ~ "\n");
		}
	}

	void finishCompilation()
	{
		bool disconnected;
		synchronized (lock)
		{
			if (compileDone)
				return;
			compileDone = true;
			disconnected = clientDisconnected;
		}
		if (disconnected)
			return;

		JSONValue[string] exited;
		exited["exitCode"] = JSONValue(0);
		conn.sendEvent("exited", JSONValue(exited));
		conn.sendEvent("terminated");
	}

	// ------------------------------------------------------ interpreter hook

	void onStatement(InterState* istate, Statement s)
	{
		if (s is null)
			return;

		if (istate !is null)
			istate.stmt = s;

		Loc loc = s.loc;
		if (!loc.isValid)
			return;

		uint line = loc.linnum;
		if (line == 0)
			return;

		const(char)* fname = loc.filename;
		if (fname is null)
			return;

		string reason;
		synchronized (lock)
		{
			if (abortRequested)
				throw new CtfeDebugAbort;
			reason = checkStop(istate, s, fname, line);
			if (reason !is null)
				mode = RunMode.none;
		}

		if (reason !is null)
			suspend(istate, s, reason);
	}

	/// Decide whether to stop at the given position; called with lock held.
	string checkStop(InterState* istate, Statement s, const(char)* fname, uint line)
	{
		if (pauseRequested)
		{
			pauseRequested = false;
			return "pause";
		}

		string file = normalizedName(cast(size_t) fname, fname);
		if (auto p = file in breakpoints)
			foreach (ref Breakpoint bp; *p)
				if (bp.line == line && (!bp.condition.length || conditionHolds(istate, s, bp.condition)))
					return "breakpoint";

		if (stopOnEntry && !entryDone)
		{
			entryDone = true;
			return "entry";
		}

		int depth = ctfeCallDepth();
		switch (mode)
		{
			case RunMode.stepIn:
				return "step";

			case RunMode.stepOver:
				if (depth <= stopCallDepth)
					return "step";
				break;

			case RunMode.stepOut:
				if (depth < stopCallDepth)
					return "step";
				break;

			default:
				break;
		}
		return null;
	}

	/// Whether the condition of a breakpoint holds at this position; called with
	/// lock held.  The frames of the stop are not built yet, so build them just
	/// for evaluating the condition.
	bool conditionHolds(InterState* istate, Statement s, string condition)
	{
		CtfeFrame[] saved = frames;
		frames = buildFrames(istate, s);
		scope (exit) frames = saved;

		string error;
		Expression e = evalExpression(condition, 0, error);
		if (e is null)
		{
			outputMessage("stderr", "breakpoint condition '" ~ condition ~ "': " ~ error ~ "\n");
			return false;
		}

		bool b;
		return evalBool(e, b) && b;
	}

	void suspend(InterState* istate, Statement s, string reason)
	{
		synchronized (lock)
		{
			frames = buildFrames(istate, s);
			valueHandles = null;
			nextValueHandle = 1;
			evalBuffers = null;
			lastStopDepth = ctfeCallDepth();
			atStop = true;
		}

		JSONValue[string] ev;
		ev["reason"] = JSONValue(reason);
		ev["threadId"] = JSONValue(threadId);
		ev["allThreadsStopped"] = JSONValue(true);
		conn.sendEvent("stopped", JSONValue(ev));

		WaitForSingleObject(evResume, INFINITE);
		ResetEvent(evResume);

		synchronized (lock)
		{
			atStop = false;
			frames = null;
			valueHandles = null;
		}
	}

	void requestResume(RunMode m)
	{
		synchronized (lock)
		{
			mode = m;
			if (m == RunMode.stepOver || m == RunMode.stepOut)
				stopCallDepth = lastStopDepth;
		}
		SetEvent(evResume);
	}

	CtfeFrame[] buildFrames(InterState* istate, Statement s)
	{
		CtfeFrame[] result;
		size_t end = ctfeStackPointer();
		int id = 1;

		if (istate is null)
		{
			// global CTFE initializer (enum or static const initializers)
			CtfeFrame fr;
			fr.id = id++;
			fr.name = "static initialization";
			fr.path = pathOf(s.loc);
			fr.file = normalizedPathOf(s.loc);
			fr.line = s.loc.linnum;
			fr.column = s.loc.charnum;
			fr.varStart = ctfeCurrentFrameBase();
			fr.varEnd = end;
			result ~= fr;
			return result;
		}

		for (InterState* p = istate; p !is null; p = p.caller)
		{
			Statement st = p is istate ? s : p.stmt;
			Loc loc = st ? st.loc : (p.fd ? p.fd.loc : Loc.initial);

			CtfeFrame fr;
			fr.id = id++;
			fr.istate = p;
			fr.name = p.fd ? zstring(p.fd.toPrettyChars()) : "static initialization";
			fr.path = pathOf(loc);
			fr.file = normalizedPathOf(loc);
			fr.line = loc.linnum;
			fr.column = loc.charnum;
			fr.varStart = p.stackBase;
			fr.varEnd = end;
			result ~= fr;

			end = p.stackBase;
			if (result.length >= 64)
				break;
		}
		return result;
	}

	// ------------------------------------------------------------- variables

	JSONValue[] frameVariables(ref CtfeFrame fr)
	{
		JSONValue[] result;
		auto vars = ctfeVariablesInRange(fr.varStart, fr.varEnd);
		auto vals = ctfeValuesInRange(fr.varStart, fr.varEnd);

		foreach (size_t i, VarDeclaration v; vars)
		{
			// the hidden temporaries of foreach loops are just noise
			if (v is null || (v.storage_class & STC.temp))
				continue;
			Expression e = i < vals.length ? vals[i] : null;
			result ~= makeVariable(variableName(v), v.type, e);
		}
		return result;
	}

	/// A global constant and the value known for it.
	struct GlobalConstant
	{
		VarDeclaration v;
		Expression value;
	}

	/// The constants of the module being compiled. Manifest constants are folded
	/// by the semantic pass and never reach the interpreter, so their initializers
	/// are read from the declarations; the interpreter reports the globals whose
	/// value it computed itself. Called with lock held.
	GlobalConstant[] globalConstants()
	{
		GlobalConstant[] result;
		bool[VarDeclaration] seen;

		auto vals = ctfeGlobalValues();
		auto decls = ctfeGlobalDeclarations();
		foreach (size_t i, VarDeclaration v; decls)
		{
			if (v is null || (v in seen))
				continue;
			seen[v] = true;
			result ~= GlobalConstant(v, i < vals.length ? vals[i] : null);
		}

		Module m = Module.rootModule;
		if (m is null || m.members is null)
			return result;

		foreach (Dsymbol s; *m.members)
		{
			VarDeclaration v = s ? s.isVarDeclaration() : null;
			if (v is null || (v in seen))
				continue;
			if (!(v.isConst() || v.isImmutable() || (v.storage_class & STC.manifest)))
				continue;
			Expression e = foldedInitializer(v);
			if (e is null)
				continue;
			seen[v] = true;
			result ~= GlobalConstant(v, e);
		}
		return result;
	}

	static Expression foldedInitializer(VarDeclaration v)
	{
		if (v._init is null)
			return null;
		auto ei = v._init.isExpInitializer();
		return ei ? ei.exp : null;
	}

	/// Look a global constant up by name; called with lock held.
	Expression findGlobalConstant(string name, out VarDeclaration pv)
	{
		pv = null;
		foreach (ref gc; globalConstants())
			if (gc.v.ident && gc.v.ident.toString() == name)
			{
				pv = gc.v;
				return gc.value;
			}
		return null;
	}

	JSONValue[] globalVariables()
	{
		JSONValue[] result;
		foreach (ref gc; globalConstants())
			result ~= makeVariable(variableName(gc.v), gc.v.type, gc.value);
		return result;
	}

	JSONValue[] valueChildren(Expression e)
	{
		JSONValue[] result;

		if (auto sl = e.isStructLiteralExp())
		{
			if (sl.elements is null)
				return result;
			auto elems = (*sl.elements)[];
			auto fields = sl.sd ? sl.sd.fields[] : null;
			foreach (size_t i, Expression ex; elems)
			{
				string name = i < fields.length && fields[i] && fields[i].ident
					? idup(fields[i].ident.toString())
					: "[" ~ to!string(i) ~ "]";
				result ~= makeVariable(name, ex ? ex.type : null, ex);
			}
		}
		else if (auto al = e.isArrayLiteralExp())
		{
			if (al.elements is null)
				return result;
			foreach (size_t i, Expression ex; (*al.elements)[])
			{
				Expression v = ex ? ex : al.basis;
				result ~= makeVariable("[" ~ to!string(i) ~ "]", v ? v.type : null, v);
			}
		}
		else if (auto aa = e.isAssocArrayLiteralExp())
		{
			if (aa.keys is null || aa.values is null)
				return result;
			auto keys = (*aa.keys)[];
			auto values = (*aa.values)[];
			foreach (size_t i, Expression k; keys)
			{
				Expression v = i < values.length ? values[i] : null;
				result ~= makeVariable(valueText(k), v ? v.type : null, v);
			}
		}
		return result;
	}

	static string variableName(VarDeclaration v)
	{
		return v.ident ? idup(v.ident.toString()) : zstring(v.toChars());
	}

	JSONValue makeVariable(string name, Type t, Expression e)
	{
		JSONValue[string] o;
		o["name"] = JSONValue(name);
		o["value"] = JSONValue(valueText(e));
		o["type"] = JSONValue(t ? typeText(t) : "");
		o["variablesReference"] = JSONValue(childHandle(e));
		return JSONValue(o);
	}

	int childHandle(Expression e)
	{
		if (e is null)
			return 0;

		if (auto sl = e.isStructLiteralExp())
			return sl.elements && (*sl.elements).length ? newHandle(e) : 0;
		if (auto al = e.isArrayLiteralExp())
			return al.elements && (*al.elements).length ? newHandle(e) : 0;
		if (auto aa = e.isAssocArrayLiteralExp())
			return aa.keys && aa.values && (*aa.keys).length ? newHandle(e) : 0;
		return 0;
	}

	int newHandle(Expression e)
	{
		int id = nextValueHandle++;
		valueHandles[id] = e;
		return id;
	}

	static string typeText(Type t)
	{
		try
		{
			string s = zstring(t.toChars());
			return s ? s : "";
		}
		catch (Throwable e)
		{
			return "";
		}
	}

	static string valueText(Expression e)
	{
		if (e is null)
			return "";

		try
		{
			if (auto ie = e.isIntegerExp())
			{
				Type t = ie.type ? ie.type.toBasetype() : null;
				if (t is Type.tbool)
					return ie.value ? "true" : "false";
				if (t && t.isUnsigned())
					return to!string(cast(ulong) ie.value);
			}
			string s = zstring(e.toChars());
			return s ? s : "";
		}
		catch (Throwable e)
		{
			return "<unavailable>";
		}
	}

	// ------------------------------------------------------------- lookups

	CtfeFrame* findFrame(int id)
	{
		for (size_t i = 0; i < frames.length; i++)
			if (frames[i].id == id)
				return &frames[i];
		return null;
	}

	int frameIndex(int id)
	{
		for (size_t i = 0; i < frames.length; i++)
			if (frames[i].id == id)
				return cast(int) i;
		return -1;
	}

	string normalizedName(size_t key, const(char)* fname)
	{
		if (auto p = key in fileNames)
			return *p;
		string s = normalizePath(idup(fromStringz(fname)));
		fileNames[key] = s;
		return s;
	}

	string normalizedPathOf(Loc loc)
	{
		const(char)* f = loc.filename;
		return f ? normalizedName(cast(size_t) f, f) : null;
	}

	static string pathOf(Loc loc)
	{
		const(char)* f = loc.filename;
		return f ? idup(fromStringz(f)) : null;
	}

	void outputMessage(string category, string text)
	{
		if (clientDisconnected)
			return;
		JSONValue[string] ev;
		ev["category"] = JSONValue(category);
		ev["output"] = JSONValue(text);
		conn.sendEvent("output", JSONValue(ev));
	}

	// ------------------------------------------------------------- requests

	void handleRequest(JSONValue msg)
	{
		if (getString(msg, "type") != "request")
			return;

		string command = getString(msg, "command");
		int seq = getInteger(msg, "seq");
		JSONValue a = getField(msg, "arguments");

		switch (command)
		{
			case "initialize":
			{
				JSONValue[string] caps;
				caps["supportsConfigurationDoneRequest"] = JSONValue(true);
				caps["supportsEvaluateForHovers"] = JSONValue(true);
				caps["supportsTerminateRequest"] = JSONValue(true);
				caps["supportsConditionalBreakpoints"] = JSONValue(true);
				caps["supportsExceptionInfoRequest"] = JSONValue(false);
				caps["supportsDataBreakpoints"] = JSONValue(false);
				caps["exceptionBreakpointFilters"] = emptyArray();
				conn.sendResponse(seq, command, true, JSONValue(caps));
				break;
			}

			case "launch":
			case "attach":
				if (!applyLaunch(a))
				{
					conn.sendError(seq, command, "no source file specified");
					break;
				}
				conn.sendResponse(seq, command, true);
				if (!initializedSent)
				{
					initializedSent = true;
					conn.sendEvent("initialized");
				}
				break;

			case "setBreakpoints":
			case "setBreakPoints":
				handleSetBreakpoints(seq, command, a);
				break;

			case "setExceptionBreakpoints":
				conn.sendResponse(seq, command, true, JSONValue(["breakpoints": emptyArray()]));
				break;

			case "configurationDone":
				startCompilation();
				conn.sendResponse(seq, command, true);
				break;

			case "threads":
			{
				JSONValue[string] t;
				t["id"] = JSONValue(threadId);
				t["name"] = JSONValue("CTFE");
				JSONValue[] list = [JSONValue(t)];
				JSONValue[string] body;
				body["threads"] = JSONValue(list);
				conn.sendResponse(seq, command, true, JSONValue(body));
				break;
			}

			case "stackTrace":
			{
				JSONValue[] list;
				synchronized (lock)
					foreach (ref fr; frames)
						list ~= frameJson(fr);
				JSONValue[string] body;
				body["stackFrames"] = JSONValue(list);
				body["totalFrames"] = JSONValue(cast(int) list.length);
				conn.sendResponse(seq, command, true, JSONValue(body));
				break;
			}

			case "scopes":
			{
				int frameId = getInteger(a, "frameId", 1);
				JSONValue[] list;
				synchronized (lock)
					if (findFrame(frameId))
					{
						JSONValue[string] sc;
						sc["name"] = JSONValue("Locals");
						sc["variablesReference"] = JSONValue(frameId);
						sc["expensive"] = JSONValue(false);
						list = [JSONValue(sc)];

						JSONValue[string] gl;
						gl["name"] = JSONValue("Constants");
						gl["variablesReference"] = JSONValue(globalsReference);
						gl["expensive"] = JSONValue(false);
						list ~= JSONValue(gl);
					}
				conn.sendResponse(seq, command, true, JSONValue(["scopes": JSONValue(list)]));
				break;
			}

			case "variables":
			{
				int reference = getInteger(a, "variablesReference");
				JSONValue[] list;
				synchronized (lock)
				{
					if (auto fr = findFrame(reference))
						list = frameVariables(*fr);
					else if (reference == globalsReference)
						list = globalVariables();
					else if (auto p = reference in valueHandles)
						list = valueChildren(*p);
				}
				conn.sendResponse(seq, command, true, JSONValue(["variables": JSONValue(list)]));
				break;
			}

			case "continue":
				requestResume(RunMode.running);
				conn.sendResponse(seq, command, true, JSONValue(["allThreadsContinued": JSONValue(true)]));
				break;

			case "next":
				requestResume(RunMode.stepOver);
				conn.sendResponse(seq, command, true);
				break;

			case "stepIn":
				requestResume(RunMode.stepIn);
				conn.sendResponse(seq, command, true);
				break;

			case "stepOut":
				requestResume(RunMode.stepOut);
				conn.sendResponse(seq, command, true);
				break;

			case "pause":
				// Requesting a pause while suspended takes effect on the next statement.
				synchronized (lock)
					pauseRequested = true;
				conn.sendResponse(seq, command, true);
				break;

			case "evaluate":
				handleEvaluate(seq, command, a);
				break;

			case "terminate":
				synchronized (lock)
					abortRequested = true;
				SetEvent(evResume);
				conn.sendResponse(seq, command, true);
				break;

			case "disconnect":
				synchronized (lock)
				{
					abortRequested = true;
					quit = true;
					clientDisconnected = true;
				}
				SetEvent(evResume);
				conn.sendResponse(seq, command, true);
				break;

			default:
				conn.sendError(seq, command, "unsupported request: " ~ command);
				break;
		}
	}

	void handleSetBreakpoints(int seq, string command, JSONValue a)
	{
		JSONValue src = getField(a, "source");
		string path = getString(src, "path");
		if (path is null)
			path = getString(src, "source");
		if (path is null)
		{
			conn.sendError(seq, command, "no source file");
			return;
		}

		Breakpoint[] bps;
		foreach (ref bp; jsonArray(a, "breakpoints"))
		{
			int line = getInteger(bp, "line");
			if (line > 0)
			{
				Breakpoint b;
				b.line = cast(uint) line;
				b.condition = getString(bp, "condition");
				bps ~= b;
			}
		}
		bps.sort!((x, y) => x.line < y.line)();

		string key = normalizePath(path);
		synchronized (lock)
		{
			foreach (ref b; bps)
				b.id = nextBreakpointId++;
			breakpoints[key] = bps;
		}

		JSONValue[] list;
		foreach (ref Breakpoint b; bps)
		{
			JSONValue[string] bp;
			bp["id"] = JSONValue(cast(long) b.id);
			bp["verified"] = JSONValue(true);
			bp["line"] = JSONValue(cast(long) b.line);
			bp["source"] = JSONValue(["path": JSONValue(path)]);
			list ~= JSONValue(bp);
		}
		conn.sendResponse(seq, command, true, JSONValue(["breakpoints": JSONValue(list)]));
	}

	void handleEvaluate(int seq, string command, JSONValue a)
	{
		string expr = getString(a, "expression");
		if (expr is null)
		{
			conn.sendError(seq, command, "no expression");
			return;
		}

		JSONValue result;
		string message;
		synchronized (lock)
		{
			int idx = frameIndex(getInteger(a, "frameId", 1));
			if (idx < 0)
				idx = 0;

			for (int i = idx; i < cast(int) frames.length && result.type == JSONType.null_; i++)
			{
				auto vars = ctfeVariablesInRange(frames[i].varStart, frames[i].varEnd);
				auto vals = ctfeValuesInRange(frames[i].varStart, frames[i].varEnd);
				foreach (size_t j, VarDeclaration v; vars)
				{
					if (v is null || !v.ident || v.ident.toString() != expr)
						continue;
					result = evaluateBody(expr, v, j < vals.length ? vals[j] : null);
					break;
				}
			}

			// fall back to the global constants
			if (result.type == JSONType.null_)
			{
				VarDeclaration gv;
				Expression e = findGlobalConstant(expr, gv);
				if (gv !is null)
					result = evaluateBody(expr, gv, e);
			}

			// and finally try to evaluate the text as an expression
			if (result.type == JSONType.null_)
			{
				string error;
				Expression e = evalExpression(expr, idx, error);
				if (e !is null)
					result = evaluateBody(expr, e.type, e);
				else
					message = error;
			}
		}

		if (result.type == JSONType.null_)
			conn.sendResponse(seq, command, false, JSONValue(),
				message.length ? message : "no variable named '" ~ expr ~ "' in scope");
		else
			conn.sendResponse(seq, command, true, result);
	}

	/// The "evaluate" body reporting a variable; called with lock held.
	JSONValue evaluateBody(string name, VarDeclaration v, Expression e)
	{
		return evaluateBody(name, v.type, e);
	}

	JSONValue evaluateBody(string name, Type t, Expression e)
	{
		JSONValue var = makeVariable(name, t, e);
		JSONValue[string] body;
		body["result"] = var.object["value"];
		body["type"] = var.object["type"];
		body["variablesReference"] = var.object["variablesReference"];
		return JSONValue(body);
	}

	JSONValue frameJson(ref CtfeFrame fr)
	{
		JSONValue[string] f;
		f["id"] = JSONValue(fr.id);
		f["name"] = JSONValue(fr.name);
		f["line"] = JSONValue(fr.line);
		f["column"] = JSONValue(fr.column);
		if (fr.path !is null)
			f["source"] = JSONValue(["path": JSONValue(fr.path)]);
		return JSONValue(f);
	}

	// --------------------------------------------------- expression evaluation

	/// Parser state of a debugger expression.
	struct EvalState
	{
		string src;
		size_t pos;
		int frameIdx;
		string error;
	}

	/// Evaluates a simple D expression against the values of the current stop,
	/// used for the hover and watch windows and for breakpoint conditions.
	/// Returns null and reports the reason in `error`.  Called with lock held.
	Expression evalExpression(string text, int frameIdx, out string error)
	{
		EvalState st;
		st.src = text;
		st.frameIdx = frameIdx;

		Expression e = evalTernary(st);
		evalSpace(st);
		if (!st.error.length && st.pos < st.src.length)
			st.error = "unexpected '" ~ st.src[st.pos .. $] ~ "'";

		error = st.error;
		return error.length ? null : e;
	}

	Expression evalTernary(ref EvalState st)
	{
		Expression cond = evalBinary(st, 1);
		if (st.error.length || !evalEat(st, "?"))
			return cond;

		Expression yes = evalTernary(st);
		if (st.error.length)
			return null;
		if (!evalEat(st, ":"))
		{
			st.error = "'?' without ':'";
			return null;
		}
		Expression no = evalTernary(st);
		if (st.error.length)
			return null;

		bool b;
		if (!evalBool(cond, b))
			st.error = "'?' needs a condition";
		return st.error.length ? null : (b ? yes : no);
	}

	static int binaryPrec(string op)
	{
		switch (op)
		{
			case "||": return 1;
			case "&&": return 2;
			case "|": return 3;
			case "^": return 4;
			case "&": return 5;
			case "==": case "!=": return 6;
			case "<": case "<=": case ">": case ">=": return 7;
			case "<<": case ">>": case ">>>": return 8;
			case "+": case "-": case "~": return 9;
			case "*": case "/": case "%": return 10;
			default: return 0;
		}
	}

	/// The binary operator at the current position, or null if there is none.
	string evalPeekOp(ref EvalState st)
	{
		static immutable string[] ops = [">>>", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>",
			"<", ">", "+", "-", "*", "/", "%", "~", "&", "|", "^"];

		evalSpace(st);
		foreach (string op; ops)
			if (st.src.length - st.pos >= op.length && st.src[st.pos .. st.pos + op.length] == op)
				return op;
		return null;
	}

	Expression evalBinary(ref EvalState st, int minPrec)
	{
		Expression left = evalUnary(st);

		for (;;)
		{
			if (st.error.length)
				return null;

			string op = evalPeekOp(st);
			if (op is null)
				break;

			int prec = binaryPrec(op);
			if (prec < minPrec)
				break;

			st.pos += op.length;

			if (op == "&&" || op == "||")
			{
				bool lb;
				if (!evalBool(left, lb))
				{
					st.error = "'" ~ op ~ "' needs a condition";
					return null;
				}

				Expression right = evalBinary(st, prec + 1);
				bool rb = false;
				if (right is null || !evalBool(right, rb))
				{
					// the left hand side may already decide the result
					if (op == "&&" ? lb : !lb)
						return null;
					st.error = null;
					rb = false;
				}
				left = evalBoolExp(op == "&&" ? lb && rb : lb || rb);
				continue;
			}

			Expression right = evalBinary(st, prec + 1);
			if (st.error.length)
				return null;

			left = evalOperation(op, left, right, st);
		}
		return left;
	}

	Expression evalUnary(ref EvalState st)
	{
		static immutable string[] unaryOps = ["-", "+", "!", "~"];

		evalSpace(st);
		foreach (string op; unaryOps)
			if (evalPeek(st, op))
			{
				st.pos += op.length;
				Expression e = evalUnary(st);
				if (st.error.length)
					return null;
				return evalUnaryOperation(op, e, st);
			}
		return evalPostfix(st);
	}

	Expression evalUnaryOperation(string op, Expression e, ref EvalState st)
	{
		if (op == "!")
		{
			bool b;
			if (!evalBool(e, b))
			{
				st.error = "'!' needs a condition";
				return null;
			}
			return evalBoolExp(!b);
		}

		real_t r;
		if (e !is null && e.isRealExp() !is null && evalReal(e, r))
		{
			if (op == "+")
				return e;
			if (op == "-")
				return new RealExp(Loc.initial, -r, Type.tfloat64);
			st.error = "'" ~ op ~ "' is not supported for reals";
			return null;
		}

		long v;
		bool uns;
		if (!evalInt(e, v, uns))
		{
			st.error = "'" ~ op ~ "' needs a number";
			return null;
		}
		return evalIntExp(op == "-" ? -v : op == "~" ? ~v : v, e ? e.type : null);
	}

	Expression evalPostfix(ref EvalState st)
	{
		Expression e = evalPrimary(st);

		for (;;)
		{
			if (st.error.length)
				return null;

			if (evalEat(st, "."))
			{
				string name = evalIdent(st);
				if (name is null)
				{
					st.error = "expected a member name";
					return null;
				}
				e = evalMember(e, name, st);
			}
			else if (evalEat(st, "["))
			{
				Expression index = evalTernary(st);
				if (st.error.length)
					return null;
				if (!evalEat(st, "]"))
				{
					st.error = "missing ']'";
					return null;
				}
				e = evalIndex(e, index, st);
			}
			else
				break;
		}
		return e;
	}

	Expression evalPrimary(ref EvalState st)
	{
		evalSpace(st);
		if (st.pos >= st.src.length)
		{
			st.error = "unexpected end of expression";
			return null;
		}

		char c = st.src[st.pos];
		if (c == '(')
		{
			++st.pos;
			Expression e = evalTernary(st);
			if (!st.error.length && !evalEat(st, ")"))
				st.error = "missing ')'";
			return st.error.length ? null : e;
		}
		if (c == '"')
			return evalStringLiteral(st);
		if (c == '\'')
			return evalCharLiteral(st);
		if (isDigitChar(c) || (c == '.' && st.pos + 1 < st.src.length && isDigitChar(st.src[st.pos + 1])))
			return evalNumberLiteral(st);

		if (isIdentStart(c))
		{
			string id = evalIdent(st);
			if (id == "true")
				return evalBoolExp(true);
			if (id == "false")
				return evalBoolExp(false);
			if (id == "null")
				return new NullExp(Loc.initial);

			VarDeclaration v;
			Expression e = evalLookup(id, st.frameIdx, v);
			if (v is null)
				st.error = "'" ~ id ~ "' not found in scope";
			return e;
		}

		st.error = "unexpected character '" ~ c ~ "'";
		return null;
	}

	string evalIdent(ref EvalState st)
	{
		evalSpace(st);
		if (st.pos >= st.src.length || !isIdentStart(st.src[st.pos]))
			return null;

		size_t start = st.pos;
		while (st.pos < st.src.length && isIdentChar(st.src[st.pos]))
			++st.pos;
		return idup(st.src[start .. st.pos]);
	}

	Expression evalNumberLiteral(ref EvalState st)
	{
		size_t start = st.pos;
		bool hex = st.src[st.pos] == '0' && st.pos + 1 < st.src.length &&
			(st.src[st.pos + 1] == 'x' || st.src[st.pos + 1] == 'X');
		if (hex)
			st.pos += 2;

		bool isReal = false;
		while (st.pos < st.src.length)
		{
			char c = st.src[st.pos];
			if (c == '_')
			{
				++st.pos;
				continue;
			}
			if (hex && isHexChar(c) || !hex && isDigitChar(c))
			{
				++st.pos;
				continue;
			}
			if (!hex && (c == '.' || c == 'e' || c == 'E'))
			{
				isReal = true;
				++st.pos;
				continue;
			}
			if (!hex && (c == '+' || c == '-') && st.pos > start &&
				(st.src[st.pos - 1] == 'e' || st.src[st.pos - 1] == 'E'))
			{
				++st.pos;
				continue;
			}
			break;
		}
		while (st.pos < st.src.length && (st.src[st.pos] == 'u' || st.src[st.pos] == 'U' ||
			st.src[st.pos] == 'l' || st.src[st.pos] == 'L'))
			++st.pos;

		string digits;
		foreach (char c; st.src[start .. st.pos])
			if (c != '_')
				digits ~= c;

		try
		{
			if (isReal)
				return new RealExp(Loc.initial, cast(real_t) to!double(digits), Type.tfloat64);

			ulong v = 0;
			if (hex)
				foreach (char c; digits.length > 2 ? digits[2 .. $] : "")
					v = v * 16 + (c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10);
			else
				v = to!ulong(digits);

			return evalIntExp(cast(long) v, v <= int.max ? Type.tint32 : Type.tint64);
		}
		catch (Exception e)
		{
			st.error = "invalid number '" ~ digits ~ "'";
			return null;
		}
	}

	Expression evalStringLiteral(ref EvalState st)
	{
		string s;
		++st.pos;   // opening quote

		while (st.pos < st.src.length && st.src[st.pos] != '"')
		{
			char c = st.src[st.pos];
			if (c == '\\' && st.pos + 1 < st.src.length)
			{
				++st.pos;
				c = unescape(st.src[st.pos]);
			}
			s ~= c;
			++st.pos;
		}
		if (st.pos >= st.src.length)
		{
			st.error = "unterminated string";
			return null;
		}
		++st.pos;   // closing quote

		return evalStringResult(s, st);
	}

	Expression evalCharLiteral(ref EvalState st)
	{
		++st.pos;   // opening quote
		if (st.pos >= st.src.length)
		{
			st.error = "unterminated character literal";
			return null;
		}

		char c = st.src[st.pos];
		if (c == '\\' && st.pos + 1 < st.src.length)
		{
			++st.pos;
			c = unescape(st.src[st.pos]);
		}
		++st.pos;
		if (st.pos >= st.src.length || st.src[st.pos] != '\'')
		{
			st.error = "unterminated character literal";
			return null;
		}
		++st.pos;   // closing quote

		return evalIntExp(c, Type.tchar);
	}

	static char unescape(char c)
	{
		switch (c)
		{
			case 'n': return '\n';
			case 't': return '\t';
			case 'r': return '\r';
			case '0': return '\0';
			case '\\': return '\\';
			case '"': return '"';
			case '\'': return '\'';
			default: return c;
		}
	}

	static bool isDigitChar(char c) { return c >= '0' && c <= '9'; }

	static bool isHexChar(char c)
	{
		return isDigitChar(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
	}

	static bool isIdentStart(char c)
	{
		return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
	}

	static bool isIdentChar(char c) { return isIdentStart(c) || isDigitChar(c); }

	/// The value of `name` in the frames of the current stop, or a global constant.
	Expression evalLookup(string name, int frameIdx, out VarDeclaration pv)
	{
		pv = null;
		for (int i = frameIdx; i < cast(int) frames.length; ++i)
		{
			auto vars = ctfeVariablesInRange(frames[i].varStart, frames[i].varEnd);
			auto vals = ctfeValuesInRange(frames[i].varStart, frames[i].varEnd);
			foreach (size_t j, VarDeclaration v; vars)
				if (v !is null && v.ident && v.ident.toString() == name)
				{
					pv = v;
					return j < vals.length ? vals[j] : null;
				}
		}
		return findGlobalConstant(name, pv);
	}

	Expression evalMember(Expression e, string name, ref EvalState st)
	{
		if (name == "length" || name == "$")
		{
			if (auto al = e.isArrayLiteralExp())
				return evalIntExp(cast(long) (al.elements ? (*al.elements).length : 0), Type.tint32);
			if (auto se = e.isStringExp())
				return evalIntExp(cast(long) se.peekString().length, Type.tint32);
			if (auto aa = e.isAssocArrayLiteralExp())
				return evalIntExp(cast(long) (aa.keys ? (*aa.keys).length : 0), Type.tint32);
		}

		if (auto sl = e.isStructLiteralExp())
		{
			if (sl.elements !is null && sl.sd !is null)
			{
				auto fields = sl.sd.fields[];
				foreach (size_t i, Expression ex; (*sl.elements)[])
					if (i < fields.length && fields[i] !is null && fields[i].ident &&
						fields[i].ident.toString() == name)
						return ex;
			}
		}

		st.error = "no member '" ~ name ~ "'";
		return null;
	}

	Expression evalIndex(Expression e, Expression index, ref EvalState st)
	{
		long i;
		bool uns;
		if (index is null || !evalInt(index, i, uns))
		{
			st.error = "index must be an integer";
			return null;
		}

		if (auto al = e.isArrayLiteralExp())
		{
			if (al.elements !is null && i >= 0 && i < cast(long) (*al.elements).length)
			{
				Expression ex = (*al.elements)[cast(size_t) i];
				return ex ? ex : al.basis;
			}
			if (al.basis !is null && i >= 0)
				return al.basis;
		}
		else if (auto se = e.isStringExp())
		{
			auto s = se.peekString();
			if (s !is null && i >= 0 && i < cast(long) s.length)
				return evalIntExp(cast(long) s[cast(size_t) i], Type.tchar);
		}
		else if (auto aa = e.isAssocArrayLiteralExp())
		{
			if (aa.keys !is null && aa.values !is null)
			{
				string key = valueText(index);
				foreach (size_t k, Expression ek; (*aa.keys)[])
					if (valueText(ek) == key)
						return k < (*aa.values).length ? (*aa.values)[k] : null;
			}
		}

		st.error = "index out of range";
		return null;
	}

	Expression evalOperation(string op, Expression a, Expression b, ref EvalState st)
	{
		string sa, sb;
		bool astr = evalString(a, sa);
		bool bstr = evalString(b, sb);

		if (op == "~")
		{
			if (astr && bstr)
				return evalStringResult(sa ~ sb, st);
			if (astr || bstr)
				return evalStringResult(valueText(a) ~ valueText(b), st);
		}

		if (astr && bstr)
		{
			if (op == "==")
				return evalBoolExp(sa == sb);
			if (op == "!=")
				return evalBoolExp(sa != sb);
		}

		if ((a !is null && a.isRealExp() !is null) || (b !is null && b.isRealExp() !is null))
			return evalRealOperation(op, a, b, st);

		if ((op == "==" || op == "!=") && isBoolExpr(a) && isBoolExpr(b))
		{
			bool ab, bb;
			if (evalBool(a, ab) && evalBool(b, bb))
				return evalBoolExp((op == "==") == (ab == bb));
		}

		long av, bv;
		bool au, bu;
		if (!evalInt(a, av, au) || !evalInt(b, bv, bu))
		{
			// compare whatever the debugger shows for the two operands
			if (op == "==" || op == "!=")
			{
				bool eq = valueText(a) == valueText(b);
				return evalBoolExp((op == "==") == eq);
			}
			st.error = "cannot apply '" ~ op ~ "'";
			return null;
		}

		long rv = 0;
		bool cmp = false;
		switch (op)
		{
			case "+": rv = av + bv; break;
			case "-": rv = av - bv; break;
			case "*": rv = av * bv; break;
			case "/":
				if (bv == 0)
					st.error = "divide by 0";
				else
					rv = av / bv;
				break;
			case "%":
				if (bv == 0)
					st.error = "divide by 0";
				else
					rv = av % bv;
				break;
			case "&": rv = av & bv; break;
			case "|": rv = av | bv; break;
			case "^": rv = av ^ bv; break;
			case "<<":
				if (bv < 0 || bv >= 64)
					st.error = "bad shift count";
				else
					rv = av << bv;
				break;
			case ">>":
				if (bv < 0 || bv >= 64)
					st.error = "bad shift count";
				else
					rv = av >> bv;
				break;
			case ">>>":
				if (bv < 0 || bv >= 64)
					st.error = "bad shift count";
				else
					rv = cast(long) (cast(ulong) av >> bv);
				break;
			case "<": cmp = av < bv; break;
			case "<=": cmp = av <= bv; break;
			case ">": cmp = av > bv; break;
			case ">=": cmp = av >= bv; break;
			case "==": cmp = av == bv; break;
			case "!=": cmp = av != bv; break;
			default: st.error = "unsupported operator '" ~ op ~ "'"; break;
		}
		if (st.error.length)
			return null;

		if (op == "<" || op == "<=" || op == ">" || op == ">=" || op == "==" || op == "!=")
			return evalBoolExp(cmp);

		return evalIntExp(rv, a ? a.type : null);
	}

	Expression evalRealOperation(string op, Expression a, Expression b, ref EvalState st)
	{
		real_t x, y;
		if (!evalReal(a, x) || !evalReal(b, y))
		{
			st.error = "cannot apply '" ~ op ~ "'";
			return null;
		}

		real_t rv;
		bool cmp = false;
		switch (op)
		{
			case "+": rv = x + y; break;
			case "-": rv = x - y; break;
			case "*": rv = x * y; break;
			case "/":
				if (y == 0)
					st.error = "divide by 0";
				else
					rv = x / y;
				break;
			case "<": cmp = x < y; break;
			case "<=": cmp = x <= y; break;
			case ">": cmp = x > y; break;
			case ">=": cmp = x >= y; break;
			case "==": cmp = x == y; break;
			case "!=": cmp = x != y; break;
			default: st.error = "'" ~ op ~ "' is not supported for reals"; break;
		}
		if (st.error.length)
			return null;

		if (op == "<" || op == "<=" || op == ">" || op == ">=" || op == "==" || op == "!=")
			return evalBoolExp(cmp);
		return new RealExp(Loc.initial, rv, Type.tfloat64);
	}

	static bool evalInt(Expression e, out long value, out bool uns)
	{
		value = 0;
		uns = false;
		if (auto ie = e is null ? null : e.isIntegerExp())
		{
			value = cast(long) ie.value;
			Type t = e.type ? e.type.toBasetype() : null;
			uns = t ? t.isUnsigned() : false;
			return true;
		}
		return false;
	}

	static bool evalReal(Expression e, out real_t value)
	{
		if (auto re = e is null ? null : e.isRealExp())
		{
			value = re.value;
			return true;
		}

		long v;
		bool uns;
		if (evalInt(e, v, uns))
		{
			value = cast(real_t) v;
			return true;
		}
		return false;
	}

	/// True only for expressions whose static type is bool, so that `==`
	/// between two integers is not mistaken for a comparison of two flags.
	static bool isBoolExpr(Expression e)
	{
		Type t = e is null ? null : e.type;
		t = t ? t.toBasetype() : null;
		return t is Type.tbool;
	}

	static bool evalBool(Expression e, out bool b)
	{
		long v;
		bool uns;
		if (evalInt(e, v, uns))
		{
			b = v != 0;
			return true;
		}

		real_t r;
		if (evalReal(e, r))
		{
			b = r != 0;
			return true;
		}

		if (e is null)
			return false;
		if (e.isNullExp())
		{
			b = false;
			return true;
		}
		if (e.isStringExp() || e.isArrayLiteralExp() || e.isStructLiteralExp() ||
			e.isAssocArrayLiteralExp())
		{
			b = true;
			return true;
		}
		return false;
	}

	static bool evalString(Expression e, out string s)
	{
		s = null;
		if (auto se = e is null ? null : e.isStringExp())
		{
			auto p = se.peekString();
			s = p is null ? null : cast(string) p;
			return s !is null;
		}
		return false;
	}

	static Expression evalBoolExp(bool b)
	{
		return new IntegerExp(Loc.initial, b ? 1 : 0, Type.tbool);
	}

	static Expression evalIntExp(long v, Type t)
	{
		return new IntegerExp(Loc.initial, cast(dinteger_t) v, t ? t : Type.tint32);
	}

	/// A StringExp only refers to the buffer it is given, so keep it alive.
	Expression evalStringResult(string s, ref EvalState st)
	{
		evalBuffers ~= s;
		return new StringExp(Loc.initial, cast(const(void)[]) evalBuffers[$ - 1]);
	}

	static void evalSpace(ref EvalState st)
	{
		while (st.pos < st.src.length)
		{
			char c = st.src[st.pos];
			if (c != ' ' && c != '\t' && c != '\n' && c != '\r')
				break;
			++st.pos;
		}
	}

	bool evalPeek(ref EvalState st, string text)
	{
		evalSpace(st);
		return st.src.length - st.pos >= text.length && st.src[st.pos .. st.pos + text.length] == text;
	}

	bool evalEat(ref EvalState st, string text)
	{
		if (!evalPeek(st, text))
			return false;
		st.pos += text.length;
		return true;
	}
}


string normalizePath(string path)
{
	try
		path = path.buildNormalizedPath;
	catch (Exception e)
	{
	}
	return asciiLower(path);
}

private string idup(const(char)[] s)
{
	return s ? cast(string) s.dup : null;
}

/// Copies a NUL terminated string returned by the compiler into a D string.
private string zstring(const(char)* s)
{
	return s ? cast(string) fromStringz(s) : null;
}


// The compiler reports diagnostics through this handler instead of writing them
// to stderr, so that they can be forwarded as DAP "output" events.
bool ctfeDiagnostic(const ref SourceLoc location, Color headerColor, const(char)* header,
	const(char)* messageFormat, va_list ap, const(char)* prefix1, const(char)* prefix2) nothrow
{
	try
	{
		auto ses = g_session;
		if (ses is null)
			return false;

		string s;
		if (prefix1)
			s ~= zstring(prefix1) ~ " ";
		if (prefix2)
			s ~= zstring(prefix2) ~ " ";

		char[4096] buffer;
		int len = vsnprintf(buffer.ptr, buffer.length, messageFormat, ap);
		if (len > 0)
		{
			if (len > buffer.length - 1)
				len = buffer.length - 1;
			s ~= buffer[0 .. len];
		}

		string file = cast(string) location.filename;
		string prefix = file.length ? file ~ "(" ~ to!string(location.linnum) ~ "): " : "";
		ses.outputMessage("stderr", prefix ~ (header ? zstring(header) : "") ~ s ~ "\n");
	}
	catch (Throwable e)
	{
	}
	return true;
}
