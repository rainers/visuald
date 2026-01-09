// replacement module to disable stack traces and avoid the dll code
// to be linked in

module core.sys.windows.dll;
version (Windows):

import core.sys.windows.windows;

int dll_getRefCount( HINSTANCE hInstance ) nothrow @nogc
{
	return 1;
}
