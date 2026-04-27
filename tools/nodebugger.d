module nodebugger;

import core.sys.windows.windows;

extern (Windows) nothrow @nogc
{
	BOOL IsDebuggerPresent()
	{
		return FALSE;
	}
	version (Win64)
		__gshared void* __imp_IsDebuggerPresent = &IsDebuggerPresent;
	else version(LDC)
		pragma(mangle, "_imp__IsDebuggerPresent@0") // LDC prepends another '_'
		__gshared void* __imp__IsDebuggerPresent = &IsDebuggerPresent;
	else
		pragma(mangle, "__imp__IsDebuggerPresent@0")
			__gshared void* __imp__IsDebuggerPresent = &IsDebuggerPresent;
}
