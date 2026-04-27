// replacement module to disable registry write operations

module std.noregistry;

import core.sys.windows.windows;

extern (Windows) nothrow @nogc
{
	alias /+_Return_type_success_(return==ERROR_SUCCESS)+/ LONG LSTATUS;
	LSTATUS RegSetValueW (
					  /*__in*/ HKEY hKey,
					  /*__in_opt*/ LPCWSTR lpSubKey,
					  /*__in*/ DWORD dwType,
					  /+_In_reads_bytes_opt_(cbData)+/ LPCWSTR lpData,
					  /*__in*/ DWORD cbData
					  )
	{
		return -1;
	}
	LSTATUS RegSetValueExW (
						  /*__in*/ HKEY hKey,
						  /*__in_opt*/ LPCWSTR lpSubKey,
						  /*_Reserved_*/ DWORD Reserved,
						  /*__in*/ DWORD dwType,
						  /+_In_reads_bytes_opt_(cbData)+/ LPCWSTR lpData,
						  /*__in*/ DWORD cbData
						  )
	{
		return -1;
	}
	LSTATUS RegDeleteKeyW(
							   /*__in*/ HKEY hKey,
							   /*__in_opt*/ LPCWSTR lpSubKey
							   )
	{
		return -1;
	}
	LSTATUS RegDeleteValueW(
						  /*__in*/ HKEY hKey,
						  /*__in_opt*/ LPCWSTR lpValue
						  )
	{
		return -1;
	}
	LSTATUS RegDeleteKeyValueW(
							   /*__in*/ HKEY hKey,
							   /*__in_opt*/ LPCWSTR lpSubKey,
							   /*__in_opt*/ LPCWSTR lpValueName
							   )
	{
		return -1;
	}

	version (Win64)
	{
		__gshared void* __imp_RegSetValueW = &RegSetValueW;
		__gshared void* __imp_RegSetValueExW = &RegSetValueExW;
		__gshared void* __imp_RegDeleteKeyW = &RegDeleteKeyW;
		__gshared void* __imp_RegDeleteValueW = &RegDeleteValueW;
		__gshared void* __imp_RegDeleteKeyValueW = &RegDeleteKeyValueW;
	}
	else version(LDC)
	{
		// LDC prepends another '_'
		pragma(mangle, "_imp__RegSetValueW@20")
			__gshared void* __imp__RegSetValueW = &RegSetValueW;
		pragma(mangle, "_imp__RegSetValueExW@24")
			__gshared void* __imp__RegSetValueExW = &RegSetValueExW;
		pragma(mangle, "_imp__RegDeleteKeyW@8")
			__gshared void* __imp__RegDeleteKeyW = &RegDeleteKeyW;
		pragma(mangle, "_imp__RegDeleteValueW@8")
			__gshared void* __imp__RegDeleteValueW = &RegDeleteValueW;
		pragma(mangle, "_imp__RegDeleteKeyValueW@12")
			__gshared void* __imp__RegDeleteKeyValueW = &RegDeleteKeyValueW;
	}
	else
	{
		pragma(mangle, "__imp__RegSetValueW@20")
			__gshared void* __imp__RegSetValueW = &RegSetValueW;
		pragma(mangle, "__imp__RegSetValueExW@24")
			__gshared void* __imp__RegSetValueExW = &RegSetValueExW;
		pragma(mangle, "__imp__RegDeleteKeyW@8")
			__gshared void* __imp__RegDeleteKeyW = &RegDeleteKeyW;
		pragma(mangle, "__imp__RegDeleteValueW@8")
			__gshared void* __imp__RegDeleteValueW = &RegDeleteValueW;
		pragma(mangle, "__imp__RegDeleteKeyValueW@20")
			__gshared void* __imp__RegDeleteKeyValueW = &RegDeleteKeyValueW;
	}
}
