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
// interprets a CTFE function, and the interpreter's call stack and local
// variables can be inspected. The names the instances a frame belongs to give
// to their arguments, to the values they hold and to the types they define are
// reported with the locals of that frame. The global constants are not offered
// as a scope of their own, they would only clutter the Locals window, but the
// expression evaluator still resolves their names for the watch and hover
// windows.

// Each template instance is reported as a frame of its own, placed below the
// call that runs the code it generated, and located where the instance was
// created. Its arguments and the values and types it defines are the locals of
// that frame.

// Leaving a call is a step of its own: the value the returning frame hands back
// to its caller is reported with the locals of that frame, and the evaluator
// resolves its name for the watch, hover and immediate windows.  Stepping out
// of a call leaves the stop in the frame that is leaving behind and ends at the
// call site, where the value is reported with the locals of the frame the call
// is written in.

module vdc.dmdserver.ctfedebug;

import vdc.dmdserver.dapio;
import vdc.dmdserver.dmdinit : Options, dmdInit, dmdSetupParams;
import vdc.dmdserver.semanalysis : runModuleSemantic;
import vdc.dmdserver.semvisitor : createModuleFromText;

import dmd.console : Color;
import dmd.dinterpret : InterState, ctfeDebugHooks, ctfeGlobals;
import dmd.dmodule : Module;
import dmd.dclass : ClassDeclaration;
import dmd.declaration : Declaration, VarDeclaration;
import dmd.dsymbol : Dsymbol, ScopeDsymbol;
import dmd.dtemplate : TemplateInstance, TemplateDeclaration, Tuple, isExpression, isType, isTuple, isDsymbol;
import dmd.astenums : STC;
import dmd.errors : diagnosticHandler;
import dmd.expression : CTFEExp, Expression, IntegerExp, NullExp, RealExp, StringExp,
	StructLiteralExp;
import dmd.root.ctfloat : real_t;
import dmd.rootobject : RootObject;
import dmd.globals : dinteger_t;
import dmd.location : Loc, SourceLoc;
import dmd.statement : Statement;
import dmd.mtype : Type;
import dmd.typesem : toBasetype, isUnsigned;

import core.stdc.stdarg : va_list;
import core.stdc.stdio : vsnprintf, FILE, stdout, stderr, fileno, fflush, setvbuf,
	_IONBF, _O_WRONLY, _O_BINARY, _open_osfhandle, _close;
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


/// Number of CTFE function calls currently active.
public int ctfeCallDepth()
{
    return ctfeGlobals.callDepth;
}

/// Current top of the CTFE value stack.
public size_t ctfeStackPointer()
{
    return ctfeGlobals.stack.stackPointer();
}

/// Stack address of the first variable of the innermost CTFE frame.
public size_t ctfeCurrentFrameBase()
{
    return ctfeGlobals.stack.framepointer;
}

/// For debuggers: the variables stored at the stack addresses [start, end)
public VarDeclaration[] ctfeVariablesInRange(size_t start, size_t end)
{
	if (start >= ctfeGlobals.stack.vars.length)
		return null;
	if (end > ctfeGlobals.stack.vars.length)
		end = ctfeGlobals.stack.vars.length;
	return ctfeGlobals.stack.vars[start .. end];
}

/// For debuggers: the values of the variables stored at [start, end)
public Expression[] ctfeValuesInRange(size_t start, size_t end)
{
	if (start >= ctfeGlobals.stack.values.length)
		return null;
	if (end > ctfeGlobals.stack.values.length)
		end = ctfeGlobals.stack.values.length;
	return ctfeGlobals.stack.values[start .. end];
}

/// For debuggers: values of the global constants evaluated so far
public Expression[] ctfeGlobalValues()
{
    return ctfeGlobals.stack.globalValues[];
}

/// For debuggers: the declarations the values from ctfeGlobalValues() belong to
public VarDeclaration[] ctfeGlobalDeclarations()
{
    return ctfeGlobals.stack.globalDecls[];
}

/// For debuggers: the value of 'this' in the innermost CTFE frame
public Expression ctfeThisValue()
{
    return ctfeGlobals.stack.getThis();
}

/// The session the interpreter hook reports to (null if no session is active).
__gshared CtfeDebugSession g_session;


/// Installed into the CTFE interpreter; forwards to the current session.
void ctfeStatementHook(InterState* istate, Statement s)
{
	if (auto ses = g_session)
		ses.onStatement(istate, s);
}

/// Installed into the CTFE interpreter for the constants it evaluates at global
/// scope; forwards to the current session.
void ctfeConstantHook(Expression e, bool end)
{
	if (auto ses = g_session)
		ses.onConstant(e, end);
}

/// Installed into the CTFE interpreter when a call is about to hand its result
/// back to its caller; forwards to the current session.
void ctfeReturnHook(InterState* istate, Expression result)
{
	if (auto ses = g_session)
		ses.onReturn(istate, result);
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

extern (C)
{
	int _dup(int handle);   // not declared by core.stdc.stdio
	int _dup2(int handle, int to);
}

/// Forwards everything the compiler writes to its own stdout and stderr (pragma(msg),
/// the "error limit reached" notice, the output of -v and -X, ...) as DAP output
/// events, so that it shows up in the Debug pane of the Output window.
///
/// The compiler talks to the CRT, while the debug adapter protocol talks through the
/// handles returned by GetStdHandle, so redirecting the C file descriptors does not
/// affect the protocol channel.
final class ConsoleCapture
{
	private enum pipeSize = 64 * 1024;

	CtfeDebugSession ses;
	HANDLE[2] readHandles = [INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE];
	int[2] savedFds = [-1, -1];  // the original stdout and stderr
	Thread[2] readers;
	bool done;

	this(CtfeDebugSession ses)
	{
		this.ses = ses;
		start(stdout(), 0);
		start(stderr(), 1);
	}

	~this()
	{
		stop();
	}

	/// Point one of the C streams at a pipe and start forwarding what arrives on it.
	private void start(FILE* stream, size_t idx)
	{
		HANDLE hRead, hWrite;
		if (!CreatePipe(&hRead, &hWrite, null, pipeSize))
			return;

		int fd = _open_osfhandle(cast(long) hWrite, _O_WRONLY | _O_BINARY);
		if (fd == -1)
		{
			CloseHandle(hRead);
			CloseHandle(hWrite);
			return;
		}

		int streamFd = fileno(stream);
		int saved = _dup(streamFd);
		if (saved == -1 || _dup2(fd, streamFd) != 0)
		{
			if (saved != -1)
				_close(saved);
			_close(fd);        // also closes hWrite
			CloseHandle(hRead);
			return;
		}

		savedFds[idx] = saved;
		_close(fd);            // the redirected stream keeps the pipe alive
		setvbuf(stream, null, _IONBF, 0);  // deliver output without waiting for a flush

		readHandles[idx] = hRead;
		readers[idx] = new Thread(idx ? &forwardStderr : &forwardStdout);
		readers[idx].name(idx ? "ctfeStderr" : "ctfeStdout");
		readers[idx].start();
	}

	/// Restores the original streams and waits until all pending output is sent.
	void stop()
	{
		if (done)
			return;
		done = true;

		foreach (idx, stream; [stdout(), stderr()])
		{
			if (savedFds[idx] == -1)
				continue;
			fflush(stream);
			_dup2(savedFds[idx], fileno(stream));
			_close(savedFds[idx]);  // the last reference: the reader now sees EOF
			savedFds[idx] = -1;
		}

		foreach (ref reader; readers)
		{
			if (reader is null)
				continue;
			reader.join();
			reader = null;
		}

		foreach (ref h; readHandles)
		{
			if (h == INVALID_HANDLE_VALUE)
				continue;
			CloseHandle(h);
			h = INVALID_HANDLE_VALUE;
		}
	}

	void forwardStdout()
	{
		forward(readHandles[0], "stdout");
	}

	void forwardStderr()
	{
		forward(readHandles[1], "stderr");
	}

	private void forward(HANDLE h, string category)
	{
		if (h == INVALID_HANDLE_VALUE)
			return;

		char[4096] buf;
		for (;;)
		{
			// Blocks until the compiler has written something, and fails once the
			// write end of the pipe is closed.
			DWORD read = 0;
			if (!ReadFile(h, buf.ptr, cast(DWORD) buf.length, &read, null) || !read)
				break;
			ses.outputMessage(category, cast(string) buf[0 .. read].idup);
		}
	}
}

/// Run the DAP server until the client disconnects.
int ctfeDebugRun()
{
	auto conn = new DapConnection;
	if (!conn.isValid)
		return 1;

	auto ses = new CtfeDebugSession(conn);
	g_session = ses;
	ses.capture = new ConsoleCapture(ses);
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
	ses.capture.stop();
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

/// Whether a position of the program ends a step of the kind `m` asks for.
bool isStepping(RunMode m)
{
	return m == RunMode.stepIn || m == RunMode.stepOver || m == RunMode.stepOut;
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
	InterState* istate;         // null for a global initializer and
	                            // for the frame of an instantiation
	TemplateInstance instance;  // set for a frame reporting an instantiation
	string name;
	string path;      // file name as used by the compiler
	string file;      // normalized, lower case, for breakpoint matching
	uint line;
	uint column;
	size_t varStart;  // CTFE stack range of this frame
	size_t varEnd;
	Expression returned;    // the value this frame hands back to its caller at a
	                        // stop on its own return, or the value a call it has
	                        // just made handed back to it at a stop at the call
	                        // site (null at any other stop)
}


/// A source line the debugger stops at, with an optional condition that is
/// evaluated in the context of the stop.
struct Breakpoint
{
	uint line;
	string condition;
	int id;         // DAP breakpoint id, handed out when the breakpoint is set
}


/// The name the value a call hands back is reported under: with the locals of
/// the frame that is leaving at a stop on its return, and with those of the
/// frame that received it at a stop at the call site.  Nothing of the program
/// can carry that name, as a D identifier never starts with a '$', and the
/// evaluator accepts it for the hover, watch and immediate windows.
enum returnValueName = "$returnValue";


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
	Loc lastStopLoc;
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

	// the global constant expressions the front end is currently interpreting,
	// innermost last; they are reported as the bottom of the call stack
	Expression[] globalExprs;

	// only valid while suspended at a stop
	CtfeFrame[] frames;
	RootObject[int] valueHandles;

	// The frame ids of a stop count up from 1, so the references of the expandable
	// values start above the range they can reach: one number must not be both a
	// frame and a value.
	enum firstValueHandle = 0x10000;
	int nextValueHandle = firstValueHandle;

	// keeps the buffers of the strings created while evaluating alive
	string[] evalBuffers;

	Thread worker;
	ConsoleCapture capture;  // the compiler's own console output

	enum threadId = 1;

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

			ctfeDebugHooks.onStatement = &ctfeStatementHook;
			ctfeDebugHooks.onConstant = &ctfeConstantHook;
			ctfeDebugHooks.onReturn = &ctfeReturnHook;
			scope (exit)
			{
				ctfeDebugHooks.onStatement = null;
				ctfeDebugHooks.onConstant = null;
				ctfeDebugHooks.onReturn = null;
			}

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
		if (capture)
			capture.stop();  // send all pending compiler output before exiting
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

		checkAt(istate, s.loc);
	}

	/// The front end is about to interpret a constant expression at global scope,
	/// usually the initializer of a manifest constant.  Stopping here makes the
	/// breakpoint on the declaration itself work, and stepping from it goes into
	/// the function call the initializer contains.
	void onConstant(Expression e, bool end)
	{
		if (e is null)
			return;

		synchronized (lock)
		{
			if (end)
			{
				if (globalExprs.length && globalExprs[$ - 1] is e)
					globalExprs.length = globalExprs.length - 1;
				return;
			}
			globalExprs ~= e;
		}

		checkAt(null, e.loc);
	}

	/// The interpreter has computed the value a call returns and is about to leave
	/// the frame of `istate`.  Stepping into a call ends twice on its way back: at
	/// the return of the function that hands its value back, where the value can be
	/// read together with the locals of the frame that is leaving, and at the
	/// statement of the caller the call is written in, where the value has become a
	/// name of the frame that goes on: the step after that is the one that reaches
	/// the next statement, and the next call, of that frame.  A plain continue runs
	/// through the returns.  Stepping out of a call takes only the second of these
	/// stops: it ends at the call site, which reports the frame the value goes back
	/// to, at the statement the call is written in, and reports the value as a name
	/// of that frame.
	///
	/// A call the compile time evaluation started from has no caller of the program
	/// to go back to.  The declaration of the constant whose evaluation it is takes
	/// the place of that caller: it is the frame the value goes back to, and the
	/// value the call hands back is the value of the constant.  Stepping out ends at
	/// that declaration; the return of the call is a step of its own, and the step
	/// after it ends there too, because the interpreter has no statement of the
	/// program between the return and the declaration.
	///
	/// The user is stopped at the `return` statement of a frame before that frame
	/// returns, so the first of the two stops would report the statement the user is
	/// looking at again: a step that leaves the position where it is is no step.
	/// The return of the frame is reported at the position the value goes back to
	/// then, and the value becomes a name of the frame reported there.
	void onReturn(InterState* istate, Expression result)
	{
		if (istate is null || istate.fd is null)
			return;

		// the positions the return can be reported at: that of the frame that is
		// leaving, that of the frame the value goes back to, which is where stepping
		// out ends, and, for a call that has no caller of the program, the
		// declaration of the constant whose evaluation the call belongs to
		Loc loc = returnLoc(istate);
		Loc callSite = callSiteLoc(istate.caller);

		bool atCallSite, atDeclaration, atReturn, again, over, stop;
		Loc declaration;
		synchronized (lock)
		{
			if (abortRequested)
				throw new CtfeDebugAbort;

			atCallSite = !pauseRequested && mode == RunMode.stepOut &&
				ctfeCallDepth() == stopCallDepth && isReportable(callSite);

			// out of the call the compile time evaluation started from, the constant
			// it computes the value of is the frame left to report, and its
			// declaration is the position the value goes back to
			declaration = declarationLoc();
			atDeclaration = !pauseRequested && mode == RunMode.stepOut &&
				istate.caller is null && ctfeCallDepth() == stopCallDepth &&
				isReportable(declaration);

			// a call with no caller of the program ends the stepping: the front end
			// goes on with code of its own, which is no code to step through either
			over = mode == RunMode.stepOut && istate.caller is null &&
				ctfeCallDepth() == stopCallDepth;

			// the return of the frame whose `return` statement the user is stopped at
			// would report the position the user is looking at: the step ends at the
			// position the value goes back to instead, if there is one to report
			atReturn = isReportable(loc) && returnIsStep();
			again = atReturn && samePosition(loc, lastStopLoc) &&
				(istate.caller is null ? isReportable(declaration) : isReportable(callSite));

			stop = atCallSite || atDeclaration || (atReturn && !again);
			if (stop || over || again)
				mode = RunMode.none;
		}

		if (atCallSite)
			callSiteStop(istate, result, callSite);
		else if (atDeclaration)
			declarationStop(declaration, result);
		else if (again)
			// the step that would have stopped at the return of the frame goes on to
			// the position the value goes back to, where the value is a name of the
			// frame reported there
			if (istate.caller is null)
				declarationStop(declaration, result);
			else
				callSiteStop(istate, result, callSite);
		else if (stop)
		{
			suspend(istate, loc, "step", reportableValue(result));

			// the step that stopped at the return of a call goes on at the position
			// the value goes back to: the statement of the caller the call is
			// written in, or, for the call the evaluation started from, which has
			// no caller of the program, the declaration of the constant.  A
			// continue from the return runs past either.
			if (istate.caller is null)
				stopAtDeclaration(result, declaration);
			else
				stopAtCallSite(istate, result, callSite);
		}
		else if (istate.caller is null)
			// a return with no position of its own to report still ends the step
			// that is running, and for the call the evaluation started from that
			// position is the declaration of the constant
			stopAtDeclaration(result, declaration);
	}

	/// Report the declaration of the constant whose evaluation the frame that is
	/// leaving belongs to, if a step is running to be ended.  Between the return of
	/// the outermost call and that declaration the interpreter has no statement of
	/// the program to report a step at, so the declaration ends the step.  It is
	/// called while the frame is still on the CTFE stack, and the values of that
	/// frame are no names of the constant: the frame reported for the declaration
	/// knows only the value the call hands back.
	void stopAtDeclaration(Expression result, Loc declaration)
	{
		if (!isReportable(declaration))
			return;

		bool stop;
		synchronized (lock)
		{
			if (abortRequested)
				throw new CtfeDebugAbort;
			stop = !pauseRequested && isStepping(mode);
			if (stop)
				mode = RunMode.none;
		}
		if (!stop)
			return;

		declarationStop(declaration, result);
	}

	/// Suspend at the declaration of the constant whose value `result` is.  The
	/// frame of the call that is leaving is still on the CTFE stack, but its values
	/// are no names of the constant: the only name of the frame reported for the
	/// declaration is the value the call hands back.
	void declarationStop(Loc declaration, Expression result)
	{
		suspend(null, declaration, "step", reportableValue(result),
			ctfeCurrentFrameBase(), ctfeCallDepth() - 1);
	}

	/// Report the statement of the caller of the frame that is leaving, if a step
	/// is running to be ended.  Between the return of a call and the statement the
	/// caller goes on with, the interpreter has no position of the program to report
	/// a step at, so the statement the call is written in ends the step: the step
	/// after it is the one that goes into the next call.  It is called while the
	/// frame of the call is still on the CTFE stack.
	void stopAtCallSite(InterState* istate, Expression result, Loc callSite)
	{
		if (!isReportable(callSite))
			return;

		bool stop;
		synchronized (lock)
		{
			if (abortRequested)
				throw new CtfeDebugAbort;

			stop = !pauseRequested && isStepping(mode);
			mode = RunMode.none;
		}

		if (!stop)
			return;

		callSiteStop(istate, result, callSite);
	}

	/// Suspend at the statement of `istate.caller` that the call which is leaving
	/// was written in.  The frame of that call is still on the CTFE stack, but its
	/// values are no locals of the caller: they are kept from the locals of the
	/// frame reported for the stop, and the stepping on from the call site starts
	/// one call shallower than the one the interpreter is at.
	void callSiteStop(InterState* istate, Expression result, Loc callSite)
	{
		suspend(istate.caller, callSite, "step", reportableValue(result),
			istate.stackBase, ctfeCallDepth() - 1);
	}

	/// The position of the return of `istate`: the statement whose value the frame
	/// has computed, or its declaration if it has none of its own.
	static Loc returnLoc(InterState* istate)
	{
		Statement st = istate.stmt;
		if (st !is null && st.loc.isValid)
			return st.loc;
		return istate.fd ? istate.fd.loc : Loc.initial;
	}

	/// The position of the call that `caller` is interpreting: the statement the
	/// call is written in, as the statement hook of that frame recorded it.
	static Loc callSiteLoc(InterState* caller)
	{
		if (caller is null)
			return Loc.initial;

		Statement st = caller.stmt;
		return st !is null ? st.loc : Loc.initial;
	}

	/// The declaration of the constant whose evaluation the interpreter is at: the
	/// position of the innermost global expression being interpreted.  A global
	/// initializer has no statement of the program to return to, so its declaration
	/// is where the value of a call the evaluation started from goes back to.
	Loc declarationLoc()
	{
		return globalExprs.length ? globalExprs[$ - 1].loc : Loc.initial;
	}

	/// Whether `loc` names a place in a source file the debugger can show.
	static bool isReportable(Loc loc)
	{
		return loc.isValid && loc.linnum != 0;
	}

	/// Whether `a` and `b` report the same place of the source.  The same file is
	/// named by a separate string for each `Loc`, so the names are compared after
	/// normalizing them.
	bool samePosition(Loc a, Loc b)
	{
		return isReportable(a) && isReportable(b) && a.linnum == b.linnum &&
			normalizedPathOf(a) == normalizedPathOf(b);
	}

	/// The value to report for the result `e` of a return, or none at all: the
	/// interpreter marks a call that returned void, a call it could not interpret
	/// and the unwinding of a call with pseudo expressions rather than with a value
	/// the debugger could show.
	static Expression reportableValue(Expression e)
	{
		if (e is null || e.isThrownExceptionExp() !is null)
			return null;

		auto op = e.op;
		foreach (Expression mark; [CTFEExp.voidexp, CTFEExp.cantexp, CTFEExp.gotoexp,
			CTFEExp.breakexp, CTFEExp.continueexp])
			if (op == mark.op)
				return null;
		return e;
	}

	/// Whether the return of the frame that is leaving calls for a stop in that
	/// frame; called with lock held.  The frame is still on the CTFE stack, so its
	/// own depth counts: the call the user stepped over returns one deeper than the
	/// frame the user stepped from.  Stepping out answers with a stop of its own
	/// (see onReturn), and a plain continue runs through the returns.
	bool returnIsStep()
	{
		if (pauseRequested)
			return false;   // the statement of the caller reports the pause

		switch (mode)
		{
			case RunMode.stepIn:
				return true;

			case RunMode.stepOver:
				return ctfeCallDepth() == stopCallDepth;

			case RunMode.stepOut:
				return false;   // onReturn ends the step at the call site instead

			default:
				return false;
		}
	}

	/// Suspend the compilation if the position `loc` calls for a stop.
	void checkAt(InterState* istate, Loc loc)
	{
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
			reason = checkStop(istate, loc, fname, line);
			if (reason !is null)
				mode = RunMode.none;
		}

		if (reason !is null)
			suspend(istate, loc, reason);
	}

	/// Decide whether to stop at the given position; called with lock held.
	string checkStop(InterState* istate, Loc loc, const(char)* fname, uint line)
	{
		if (pauseRequested)
		{
			pauseRequested = false;
			return "pause";
		}

		string file = normalizedName(cast(size_t) fname, fname);
		if (auto p = file in breakpoints)
			foreach (ref Breakpoint bp; *p)
				if (bp.line == line && (!bp.condition.length || conditionHolds(istate, loc, bp.condition)))
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
				// onReturn normally ends the step at the call site; a frame whose
				// return has no position to report gets here on its way out
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
	bool conditionHolds(InterState* istate, Loc loc, string condition)
	{
		CtfeFrame[] saved = frames;
		frames = buildFrames(istate, loc);
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

	void suspend(InterState* istate, Loc loc, string reason, Expression returned = null)
	{
		suspend(istate, loc, reason, returned, ctfeStackPointer(), ctfeCallDepth());
	}

	/// Suspend the compilation and report `istate` as the innermost frame of the
	/// stop at `loc`.  `varEnd` is the top of the CTFE stack range of that frame:
	/// the frame below it is still on the stack when a call is on its way out, but
	/// its values are no locals of the frame reported.  `depth` is the call depth
	/// the next step starts from, which for the same reason is not always the one
	/// the interpreter is at.
	void suspend(InterState* istate, Loc loc, string reason, Expression returned,
		size_t varEnd, int depth)
	{
		synchronized (lock)
		{
			frames = buildFrames(istate, loc, returned, varEnd);
			valueHandles = null;
			nextValueHandle = firstValueHandle;
			evalBuffers = null;
			lastStopDepth = depth;
			lastStopLoc = loc;
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

	/// The frames of the stop, innermost first.  `returned` is the value the
	/// innermost frame hands back to its caller at a stop on the return of a call,
	/// or the value the call it has just made handed back to it at a stop at the
	/// call site, and none at any other stop.
	CtfeFrame[] buildFrames(InterState* istate, Loc stopLoc, Expression returned = null)
	{
		return buildFrames(istate, stopLoc, returned, ctfeStackPointer());
	}

	/// `end` is the top of the CTFE stack range of the innermost frame: below the
	/// stack pointer while a frame that is leaving still occupies the top of it.
	CtfeFrame[] buildFrames(InterState* istate, Loc stopLoc, Expression returned,
		size_t end)
	{
		CtfeFrame[] result;
		CtfeFrame[] calls;
		int id = 1;

		if (istate is null)
		{
			// global CTFE initializer (enum or static const initializers)
			CtfeFrame[] globals = globalFrames(id, ctfeCurrentFrameBase(), end);

			// at a stop at the declaration of a constant, the innermost global
			// expression is the one whose value the returning call hands back
			if (returned !is null && globals.length)
				globals[0].returned = returned;

			result ~= globals;
			return result;
		}

		for (InterState* p = istate; p !is null; p = p.caller)
		{
			// the innermost frame is at the position of the stop, the outer ones
			// at the statement that called the function below them
			Loc loc = stopLoc;
			if (p !is istate)
			{
				Statement st = p.stmt;
				loc = st ? st.loc : (p.fd ? p.fd.loc : Loc.initial);
			}

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
			calls ~= fr;

			end = p.stackBase;
			if (calls.length >= 64)
				break;
		}

		// the value a return reports belongs to the innermost call of the stop: to
		// the frame that hands it back at a stop on its return, and to the frame
		// that receives it at a stop at the call site
		if (returned !is null && calls.length)
			calls[0].returned = returned;

		// the template instantiations whose generated code these calls run
		result ~= instantiationFrames(id, calls);
		// the global expression whose interpretation led to these calls
		result ~= globalFrames(id, end, end);
		return result;
	}

	/// The frames of the template instantiations whose generated code the calls of
	/// the stack run, interleaved with the calls themselves: below a call, the
	/// instances whose code that call executes and no call above it executes,
	/// innermost first. An instantiation frame is located where the instance was
	/// created, so it sits between the code of the instance and the call that
	/// brought it about.
	CtfeFrame[] instantiationFrames(ref int id, CtfeFrame[] calls)
	{
		CtfeFrame[] result;
		if (!calls.length)
			return result;

		// the instances each call runs code of, innermost first
		TemplateInstance[][] nests;
		foreach (ref CtfeFrame fr; calls)
			nests ~= frameInstances(fr);

		TemplateInstance[] reported;
		for (size_t i = 0; i < calls.length; i++)
		{
			result ~= calls[i];
			// an instance is reported once, below the outermost call that runs
			// its code: if the caller of a call is nested in the instance as
			// well, the frame of that caller shows it
			TemplateInstance[] next = i + 1 < calls.length ? nests[i + 1] : null;
			foreach (TemplateInstance ti; nests[i])
			{
				if (containsInstance(reported, ti) || containsInstance(next, ti))
					continue;
				if (reported.length >= 64)
					break;
				reported ~= ti;
				result ~= instanceFrame(id, ti);
			}
		}
		return result;
	}

	/// The template instances the code of `fr` was generated from, innermost
	/// first. The interpreter state does not track the instantiation trail, but
	/// every symbol knows the scope it was declared in.
	TemplateInstance[] frameInstances(ref CtfeFrame fr)
	{
		TemplateInstance[] result;
		Dsymbol s = fr.istate !is null ? fr.istate.fd : null;

		for (s = s ? s.parent : null; s !is null; s = s.parent)
		{
			if (auto ti = s.isTemplateInstance())
				result ~= ti;
			else if (s.isTemplateMixin())
				continue;   // the enclosing template owns the trail
			if (result.length >= 32)
				break;
		}
		return result;
	}

	/// The frame reporting an instantiation, located where the instance was
	/// created. It has no variables of its own; its locals are the arguments the
	/// template was given and the values and types it defines.
	CtfeFrame instanceFrame(ref int id, TemplateInstance ti)
	{
		CtfeFrame fr;
		fr.id = id++;
		fr.instance = ti;
		fr.name = "instantiating " ~ instanceName(ti);
		Loc loc = ti.loc;
		fr.path = pathOf(loc);
		fr.file = normalizedPathOf(loc);
		fr.line = loc.linnum;
		fr.column = loc.charnum;
		return fr;
	}

	/// How an instance reads in the name of its frame.
	static string instanceName(TemplateInstance ti)
	{
		if (ti is null)
			return "template instance";
		try
		{
			string s = zstring(ti.toPrettyChars());
			return s && s.length ? s : "template instance";
		}
		catch (Throwable e)
		{
			return "template instance";
		}
	}

	static bool containsInstance(TemplateInstance[] list, TemplateInstance ti)
	{
		foreach (TemplateInstance other; list)
			if (other is ti)
				return true;
		return false;
	}

	/// The global constant expressions currently being interpreted, innermost first.
	/// A global initializer has no function to return to, so the expression itself is
	/// reported as the bottom of the call stack, at its own location. `start` and `end`
	/// are the CTFE stack range of the temporaries of the innermost one.
	CtfeFrame[] globalFrames(ref int id, size_t start, size_t end)
	{
		CtfeFrame[] result;
		for (size_t i = globalExprs.length; i-- > 0;)
		{
			Expression e = globalExprs[i];
			Loc loc = e.loc;

			CtfeFrame fr;
			fr.id = id++;
			fr.name = expressionText(e);
			if (!fr.name.length)
				fr.name = "static initialization";
			else
				fr.name = "evaluating " ~ fr.name;
			fr.path = pathOf(loc);
			fr.file = normalizedPathOf(loc);
			fr.line = loc.linnum;
			fr.column = loc.charnum;
			if (!result.length)
			{
				fr.varStart = start;
				fr.varEnd = end;
			}
			result ~= fr;

			if (result.length >= 64)
				break;
		}
		return result;
	}

	/// The expression as it is written in the source, used as the name of the frame
	/// of a global initializer.
	static string expressionText(Expression e)
	{
		if (e is null)
			return null;

		try
		{
			string s = zstring(e.toChars());
			return s ? s : null;
		}
		catch (Throwable e)
		{
			return null;
		}
	}

	// ------------------------------------------------------------- variables

	JSONValue[] frameVariables(ref CtfeFrame fr)
	{
		JSONValue[] result;

		// the value a call hands back belongs to the frame the stop is reported in,
		// and is read like the other names of its scope
		if (fr.returned !is null)
			result ~= namedValue(returnValueName, fr.returned);

		// the names of the instances of the frame are not stored on the CTFE stack,
		// but they are constants of the frame just like its parameters are
		foreach (ref InstanceName n; frameInstanceNames(fr))
			result ~= namedValue(n.name, n.value);

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

	/// A name the instantiation of a template puts into its scope: a template
	/// parameter with the argument it was given, or a value or type the instance
	/// itself defines.
	struct InstanceName
	{
		string name;
		RootObject value;   // an Expression, a Type, a Dsymbol, or a Tuple
	}

	/// The names of the instances `fr` belongs to, innermost instance first.  None
	/// of them is stored on the CTFE stack: an argument is fixed when the instance is
	/// created, and a definition only exists in the symbol table of the instance, so
	/// both are read back from the instances the frame's function is nested in.  For
	/// a frame reporting an instantiation, they are the names of that instance.  The
	/// innermost instance wins a name, an outer one cannot use it as well.
	InstanceName[] frameInstanceNames(ref CtfeFrame fr)
	{
		InstanceName[] result;
		if (fr.instance !is null)
			return instanceNames(fr.instance);

		Dsymbol s = fr.istate !is null ? fr.istate.fd : null;

		for (s = s ? s.parent : null; s !is null; s = s.parent)
		{
			TemplateInstance ti = s.isTemplateInstance();
			if (ti is null || s.isTemplateMixin())
				continue;

			foreach (ref InstanceName n; instanceNames(ti))
				if (!containsName(result, n.name))
					result ~= n;
			if (result.length >= 32)
				break;
		}
		return result;
	}

	/// Everything `ti` gives its scope a name for: first the arguments it was
	/// instantiated with, then the values and types it defines.
	InstanceName[] instanceNames(TemplateInstance ti)
	{
		return instanceArguments(ti) ~ instanceDefinitions(ti);
	}

	/// The arguments `ti` was instantiated with, in the order of the template's
	/// formal parameters.
	InstanceName[] instanceArguments(TemplateInstance ti)
	{
		InstanceName[] result;
		if (ti is null || !ti.tdtypes.length)
			return result;

		TemplateDeclaration td = ti.tempdecl ? ti.tempdecl.isTemplateDeclaration() : null;
		auto params = td && td.parameters ? (*td.parameters)[] : null;
		foreach (size_t i, RootObject o; ti.tdtypes[])
		{
			if (o is null || i >= params.length || params[i] is null || params[i].ident is null)
				continue;
			result ~= InstanceName(idup(params[i].ident.toString()), o);
		}
		return result;
	}

	/// The values and types `ti` defines for its scope beside the declarations it
	/// generates: its manifest constants, its aliases, and the types its enum and
	/// aggregate declarations introduce.  They are fixed by the instantiation
	/// rather than interpreted, so the CTFE stack has nothing to report for them.
	InstanceName[] instanceDefinitions(TemplateInstance ti)
	{
		InstanceName[] result;
		if (ti is null)
			return result;

		// A template that declares an aggregate of its own name becomes that
		// aggregate: `Stats!int` *is* the struct it generates, so the names of its
		// scope are the members of the struct rather than the struct itself.
		Dsymbol sole = ti.aliasdecl;
		if (sole !is null && sole.isStructDeclaration() is null &&
			sole.isClassDeclaration() is null)    // a union or an interface as well
			sole = null;

		ScopeDsymbol sds = sole !is null ? sole.isScopeDsymbol() : ti;
		addDefinitions(result, sds.members ? (*sds.members)[] : null);
		return result;
	}

	/// The names the members of an instance scope give to a value or a type, in the
	/// order in which the template body declares them.
	void addDefinitions(ref InstanceName[] result, Dsymbol[] members)
	{
		foreach (Dsymbol s; members)
		{
			// a template that names a great many things should not fill the Locals
			// window with all of them
			if (result.length >= 16)
				break;
			if (s is null || s.ident is null)
				continue;
			string name = idup(s.ident.toString());
			// the names the compiler gives itself are just noise
			if (name.length >= 2 && name[0 .. 2] == "__")
				continue;

			RootObject o = definitionValue(s);
			if (o is null)
				continue;
			result ~= InstanceName(name, o);
		}
	}

	/// What the member `s` of an instance stands for in the scope of that instance,
	/// or null if the debugger does not show it: the value of a manifest constant,
	/// the type an alias names, the symbol an alias stands for, the type an enum or
	/// an aggregate declaration introduces.  The functions, the fields and the
	/// nested templates an instance also generates are neither a value nor a type.
	static RootObject definitionValue(Dsymbol s)
	{
		// the parameters of the template are reported with their arguments
		Declaration d = s.isDeclaration();
		if (d !is null && d.storage_class & (STC.temp | STC.templateparameter))
			return null;

		if (auto v = s.isVarDeclaration())
		{
			if (!(v.storage_class & STC.manifest))
				return null;
			// what the interpreter has computed for it, and the initializer of the
			// declaration for as long as the constant is not folded yet
			Expression e = foldedConstant(v);
			return e !is null ? cast(RootObject) e : cast(RootObject) foldedInitializer(v);
		}

		if (auto a = s.isAliasDeclaration())
			return a.type ? cast(RootObject) a.type : cast(RootObject) a.aliassym;

		if (auto e = s.isEnumDeclaration())
			return cast(RootObject) e.type;
		if (auto sd = s.isStructDeclaration())
			return cast(RootObject) sd.type;
		if (auto cd = s.isClassDeclaration())
			return cast(RootObject) cd.type;
		return null;
	}

	/// The value the interpreter has for the manifest constant `v`, or null if it
	/// has computed none.  It keeps those values in its table of folded constants
	/// instead of on the CTFE stack and points the declaration at the entry it got
	/// (see CTFE.getValue).
	static Expression foldedConstant(VarDeclaration v)
	{
		if (!(v.storage_class & STC.manifest) || v.isCTFE())
			return null;

		size_t adr = v.ctfeAdrOnStack;
		if (adr == VarDeclaration.AdrOnStackNone)
			return null;

		auto vals = ctfeGlobalValues();
		auto decls = ctfeGlobalDeclarations();
		if (adr >= vals.length || adr >= decls.length || decls[adr] !is v)
			return null;   // the entry belongs to another constant
		return vals[adr];
	}

	static bool containsName(InstanceName[] list, string name)
	{
		foreach (ref InstanceName other; list)
			if (other.name == name)
				return true;
		return false;
	}

	/// What a name resolves to in a single frame.
	struct FrameValue
	{
		bool found;
		VarDeclaration v;        // a local or parameter of the frame ...
		Expression value;        // ... and the value the interpreter has for it
		InstanceName inst;       // or: a name of one of the instances of the frame
	}

	/// The name `name` of the frame `fr`, and only of that frame.  The locals of the
	/// calling functions are not in scope at the position of the stop, so the frames
	/// above it are not searched.
	FrameValue frameLookup(ref CtfeFrame fr, string name)
	{
		FrameValue fv;

		// the value the frame hands back to its caller names a value of the frame
		// just like its locals do
		if (fr.returned !is null && name == returnValueName)
		{
			fv.found = true;
			fv.inst = InstanceName(returnValueName, fr.returned);
			return fv;
		}

		auto vars = ctfeVariablesInRange(fr.varStart, fr.varEnd);
		auto vals = ctfeValuesInRange(fr.varStart, fr.varEnd);
		foreach (size_t j, VarDeclaration v; vars)
			if (v !is null && v.ident && v.ident.toString() == name)
			{
				fv.found = true;
				fv.v = v;
				fv.value = j < vals.length ? vals[j] : null;
				return fv;
			}

		foreach (ref InstanceName n; frameInstanceNames(fr))
			if (n.name == name)
			{
				fv.found = true;
				fv.inst = n;
				return fv;
			}

		return fv;
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

	/// Look a global constant up by name, for the names an evaluated expression
	/// mentions; the constants are not reported as a scope of their own.
	/// Called with lock held.
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

	JSONValue[] valueChildren(RootObject e)
	{
		JSONValue[] result;

		if (auto tp = isTuple(e))
		{
			foreach (size_t i, RootObject o; tp.objects[])
				result ~= namedValue("[" ~ to!string(i) ~ "]", o);
			return result;
		}

		Expression value = isExpression(e);
		if (value is null)
			return result;

		if (auto sl = aggregateLiteral(value))
		{
			if (sl.elements is null)
				return result;
			auto elems = (*sl.elements)[];
			VarDeclaration[] fields = aggregateFields(value);
			foreach (size_t i, Expression ex; elems)
			{
				string name = i < fields.length && fields[i] && fields[i].ident
					? idup(fields[i].ident.toString())
					: "[" ~ to!string(i) ~ "]";
				result ~= makeVariable(name, ex ? ex.type : null, ex);
			}
		}
		else if (auto al = value.isArrayLiteralExp())
		{
			if (al.elements is null)
				return result;
			foreach (size_t i, Expression ex; (*al.elements)[])
			{
				Expression v = ex ? ex : al.basis;
				result ~= makeVariable("[" ~ to!string(i) ~ "]", v ? v.type : null, v);
			}
		}
		else if (auto aa = value.isAssocArrayLiteralExp())
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

	/// The literal that holds the values of an aggregate: the literal of a struct
	/// or union, and the literal of the instance that a reference to a class
	/// points at.  Null for a value that is not one of an aggregate.
	static StructLiteralExp aggregateLiteral(Expression e)
	{
		if (e is null)
			return null;
		if (auto sl = e.isStructLiteralExp())
			return sl;
		if (auto cr = e.isClassReferenceExp())
			return cr.value;
		return null;
	}

	/// The fields whose values the literal of an aggregate holds, in the order the
	/// values are stored in it: the fields of a struct, and for an instance of a
	/// class the fields of its base classes first and those of the class itself
	/// last.  The `__monitor` of the root class is left out, because the values of
	/// an instance never hold it.
	static VarDeclaration[] aggregateFields(Expression e)
	{
		if (auto sl = e.isStructLiteralExp())
			return sl.sd ? sl.sd.fields[] : null;

		auto cr = e.isClassReferenceExp();
		ClassDeclaration cd = cr is null ? null : cr.originalClass();
		if (cd is null)
			return null;

		ClassDeclaration[] chain;
		for (ClassDeclaration c = cd; c; c = c.baseClass)
			chain ~= c;

		VarDeclaration[] fields;
		for (size_t i = chain.length; i-- > 0; )
			foreach (VarDeclaration v; chain[i].fields)
				if (v !is null && (v.ident is null || v.ident.toString() != "__monitor"))
					fields ~= v;
		return fields;
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

	/// A name of an instance, or an element of a tuple argument, as a variable of
	/// the Locals scope.
	JSONValue namedValue(string name, RootObject value)
	{
		JSONValue[string] o;
		o["name"] = JSONValue(name);
		o["value"] = JSONValue(constantText(value));
		o["type"] = JSONValue(constantTypeText(value));
		o["variablesReference"] = JSONValue(childHandle(value));
		return JSONValue(o);
	}

	/// How a name of an instance reads: the value of a value parameter or of a
	/// manifest constant, and the type, symbol, or tuple itself for the names that
	/// stand for one of those.
	static string constantText(RootObject o)
	{
		if (auto e = isExpression(o))
			return valueText(e);
		if (auto t = isType(o))
			return typeText(t);
		if (o is null)
			return "";
		return compilerText(o);
	}

	/// What the type column says about a name of an instance.
	static string constantTypeText(RootObject o)
	{
		if (auto e = isExpression(o))
			return typeText(e.type);
		if (isType(o))
			return "type";
		if (isTuple(o))
			return "tuple";
		if (isDsymbol(o))
			return "alias";
		return "";
	}

	int childHandle(RootObject e)
	{
		if (e is null)
			return 0;

		if (auto tp = isTuple(e))
			return tp.objects.length ? newHandle(e) : 0;

		Expression value = isExpression(e);
		if (value is null)
			return 0;

		if (auto sl = aggregateLiteral(value))
			return sl.elements && (*sl.elements).length ? newHandle(e) : 0;
		if (auto al = value.isArrayLiteralExp())
			return al.elements && (*al.elements).length ? newHandle(e) : 0;
		if (auto aa = value.isAssocArrayLiteralExp())
			return aa.keys && aa.values && (*aa.keys).length ? newHandle(e) : 0;
		return 0;
	}

	int newHandle(RootObject e)
	{
		int id = nextValueHandle++;
		valueHandles[id] = e;
		return id;
	}

	/// What the type column says about `t`: the way the compiler spells the type.
	/// Its printers name the arguments of the instance an aggregate was generated
	/// from (`Box!int`, `Pair!(int, string)`, `Node!(Node!Leaf)`) and qualify a
	/// class with the module it belongs to.
	static string typeText(Type t)
	{
		if (t is null)
			return "";

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
		return valueText(e, 0);
	}

	/// The value as the Locals, watch and hover windows show it.  The compiler
	/// prints a literal of an aggregate as `Box(3)`: it names the aggregate, but
	/// not the instance the literal is a literal of, which is the part a debugger
	/// has to add.  The name it adds is the type as the compiler spells it, so the
	/// `Box!int` a call is made on reads `Box!int(3)`.  `depth` counts the literals
	/// the one being written is inside.
	static string valueText(Expression e, int depth)
	{
		if (e is null)
			return "";

		try
		{
			if (string s = integerText(e))
				return s;

			if (depth < maxLiteralDepth)
				if (string s = aggregateLiteralText(e, depth))
					return s;

			if (string s = instanceAddressText(e))
				return s;

			string s = zstring(e.toChars());
			return s ? s : "";
		}
		catch (Throwable err)
		{
			return "<unavailable>";
		}
	}

	/// How many literals inside one another are written out before the text falls
	/// back to the compiler's, so that a value containing itself stays short.
	enum int maxLiteralDepth = 4;

	/// The value of an integer as the windows show it: a `bool` as `true` or
	/// `false`, an unsigned as an unsigned.  Empty text for the values the compiler
	/// prints as they are.
	static string integerText(Expression e)
	{
		auto ie = e.isIntegerExp();
		if (ie is null)
			return null;

		Type t = ie.type ? ie.type.toBasetype() : null;
		if (t is Type.tbool)
			return ie.value ? "true" : "false";
		if (t && t.isUnsigned())
			return to!string(cast(ulong) ie.value);
		return null;
	}

	/// The text the compiler itself gives for `o`, or `<unavailable>` when it
	/// cannot be had.
	static string compilerText(RootObject o)
	{
		if (o is null)
			return "";

		try
		{
			string s = zstring(o.toChars());
			return s ? s : "";
		}
		catch (Throwable err)
		{
			return "<unavailable>";
		}
	}

	/// The literal `e` of an aggregate: its type as the compiler spells it, and the
	/// values of its fields written out one level below `depth`.  Empty text when
	/// the type has no name to write.
	static string aggregateLiteralText(Expression e, int depth)
	{
		Expression[] elems;
		Type ty = e.type;

		if (auto sl = e.isStructLiteralExp())
		{
			elems = sl.elements ? (*sl.elements)[] : null;
			if (ty is null)
				ty = sl.stype;
		}
		else if (auto cr = e.isClassReferenceExp())
			elems = cr.value && cr.value.elements ? (*cr.value.elements)[] : null;
		else
			return null;

		string name = typeText(ty);
		if (!name.length)
			return null;

		string result = name ~ "(";
		foreach (size_t i, Expression el; elems)
		{
			if (i)
				result ~= ", ";
			result ~= el is null ? "" : valueText(el, depth + 1);
			if (result.length >= 400)
				return result ~ "...";
		}
		return result ~ ")";
	}

	/// The address of the function an instance generates, named the way the
	/// compiler names the instance: `& fn!int` rather than the `& fn` it prints for
	/// the function.  Empty text for the address of anything else, and for a member
	/// of an instance, which the compiler names through the instance.
	static string instanceAddressText(Expression e)
	{
		auto so = e.isSymOffExp();
		if (so is null || so.var is null)
			return null;

		// The eponymous member is what the instance stands for, which is what makes
		// the name of the instance the name of the function.
		Dsymbol s = so.var;
		TemplateInstance ti = s.parent ? s.parent.isTemplateInstance() : null;
		if (ti is null || ti.aliasdecl !is s)
			return null;

		string name;
		try
			name = zstring(ti.toChars());
		catch (Throwable err)
			return null;
		if (!name.length)
			return null;

		return so.offset ? "(& " ~ name ~ " + " ~ to!string(cast(ulong) so.offset) ~ ")"
			: "& " ~ name;
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

	/// The frame at index `idx` of the current stop, or null if there is none.
	CtfeFrame* frameAt(int idx)
	{
		return idx >= 0 && idx < cast(int) frames.length ? &frames[idx] : null;
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
				// Only the locals. Visual Studio shows every scope of a frame in
				// the Locals window, and the global constants are reachable by
				// name from the watch, immediate and hover windows anyway.
				int frameId = getInteger(a, "frameId", 1);
				JSONValue[] list;
				synchronized (lock)
					if (findFrame(frameId))
					{
						JSONValue[string] sc;
						sc["name"] = JSONValue("Locals");
						sc["presentationHint"] = JSONValue("locals");
						sc["variablesReference"] = JSONValue(frameId);
						sc["expensive"] = JSONValue(false);
						list = [JSONValue(sc)];
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

			// the frame the request names is the context it is evaluated in: the
			// locals of the calling functions are not in scope at its position
			if (CtfeFrame* fr = frameAt(idx))
			{
				FrameValue fv = frameLookup(*fr, expr);
				if (fv.v !is null)
					result = evaluateBody(expr, fv.v, fv.value);
				else if (fv.found)
					result = evaluateName(fv.inst);
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
		return variableBody(makeVariable(name, t, e));
	}

	/// The "evaluate" body reporting a name of one of the instances of the frame;
	/// called with lock held.
	JSONValue evaluateName(InstanceName n)
	{
		return variableBody(namedValue(n.name, n.value));
	}

	static JSONValue variableBody(JSONValue var)
	{
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
			bool found;
			Expression e = evalLookup(id, st.frameIdx, v, found);
			if (!found)
				st.error = "'" ~ id ~ "' not found in scope";
			else if (e is null && v is null)
				st.error = "'" ~ id ~ "' is not a value";
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
		// the '$' of the return value the debugger reports makes a name of its own
		return c == '_' || c == '$' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
	}

	static bool isIdentChar(char c) { return isIdentStart(c) || isDigitChar(c); }

	/// The value of `name` in the frame the expression is evaluated in, or a global
	/// constant.  The frames of the calling functions are not searched: their locals
	/// are not in scope where the expression is read.
	/// `found` says whether the name exists at all: a type does, but only a value
	/// has an Expression to hand out.
	Expression evalLookup(string name, int frameIdx, out VarDeclaration pv, out bool found)
	{
		pv = null;
		found = false;

		if (CtfeFrame* fr = frameAt(frameIdx))
		{
			FrameValue fv = frameLookup(*fr, name);
			if (fv.found)
			{
				pv = fv.v;
				found = true;
				return fv.v !is null ? fv.value : isExpression(fv.inst.value);
			}
		}

		Expression e = findGlobalConstant(name, pv);
		found = pv !is null;
		return e;
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

		if (auto sl = aggregateLiteral(e))
		{
			if (sl.elements !is null)
			{
				VarDeclaration[] fields = aggregateFields(e);
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
