module sdk.port.vsi;

public import sdk.port.base;
public import sdk.win32.unknwn;

// VSI specifics
IUnknown DOCDATAEXISTING_UNKNOWN;

static this() { *cast(int*)&DOCDATAEXISTING_UNKNOWN = -1; }

enum TokenType : int
{
	Unknown,
	Text,
	Keyword,
	Identifier,
	String,
	Literal,
	Operator,
	Delimiter,
	LineComment,
	Comment
}

enum TokenColor : int
{
	Text,
	Keyword,
	Comment,
	Identifier,
	String,
	Literal,
};

GUID GUID_COMPlusNativeEng = { 0x92EF0900, 0x2251, 0x11D2, [ 0xB7, 0x2E, 0x00, 0x00, 0xF8, 0x75, 0x72, 0xEF ] };
