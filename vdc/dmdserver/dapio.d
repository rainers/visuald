// This file is part of Visual D, released under the MIT license.

// Minimal transport for the Debug Adapter Protocol: "Content-Length" framed
// JSON messages exchanged over the standard input and output handles.

module vdc.dmdserver.dapio;

import std.conv : to;
import std.json;
import std.string : indexOf, strip;

import core.sys.windows.windows;

/// A single DAP message stream.
final class DapConnection
{
private:
	HANDLE hIn;
	HANDLE hOut;
	ubyte[] pending;        // bytes read but not consumed yet
	Object writeLock;
	int outSeq;

public:
	this()
	{
		writeLock = new Object;
		hIn = GetStdHandle(STD_INPUT_HANDLE);
		hOut = GetStdHandle(STD_OUTPUT_HANDLE);

		// Keep references of our own: redirecting the C standard streams, as the
		// console capture does, closes the handles GetStdHandle hands out.
		HANDLE self = GetCurrentProcess();
		ownHandle(self, &hIn);
		ownHandle(self, &hOut);
	}

	private static void ownHandle(HANDLE self, HANDLE* h)
	{
		if (*h is null || *h is INVALID_HANDLE_VALUE)
			return;
		HANDLE dup;
		if (DuplicateHandle(self, *h, self, &dup, 0, false, DUPLICATE_SAME_ACCESS))
			*h = dup;
	}

public:

	bool isValid() const nothrow
	{
		return hIn !is INVALID_HANDLE_VALUE && hOut !is INVALID_HANDLE_VALUE;
	}

	/// Blocks until the next message has been received.
	/// Returns a `null` JSONValue once the client closes the stream.
	JSONValue readMessage()
	{
		size_t contentLength = 0;
		bool haveLength = false;

		for (;;)
		{
			string line = readLine();
			if (line is null)
				return JSONValue();   // end of stream

			if (line.length == 0)
				break;                // end of header block

			size_t colon = indexOf(line, ':');
			if (colon == size_t.max)
				continue;

			string name = asciiLower(strip(line[0 .. colon]));
			string value = strip(line[colon + 1 .. $]);
			if (name == "content-length")
			{
				try
					contentLength = to!size_t(value);
				catch (Exception e)
					return JSONValue();
				haveLength = true;
			}
		}

		if (!haveLength)
			return JSONValue();

		string text = readText(contentLength);
		if (text is null)
			return JSONValue();

		try
			return parseJSON(text);
		catch (JSONException e)
			return JSONValue();
	}

	/// Send a message.  The sequence number is handed out inside the write lock,
	/// so messages from different threads (the compile worker and the console
	/// capture) can neither interleave nor share a sequence number.
	void send(JSONValue[string] msg)
	{
		synchronized (writeLock)
		{
			msg["seq"] = JSONValue(++outSeq);
			string text = JSONValue(msg).toString();
			string header = "Content-Length: " ~ to!string(text.length) ~ "\r\n\r\n";
			DWORD written;
			WriteFile(hOut, header.ptr, cast(DWORD) header.length, &written, null);
			WriteFile(hOut, text.ptr, cast(DWORD) text.length, &written, null);
		}
	}

	void sendEvent(string event, JSONValue body = JSONValue())
	{
		JSONValue[string] msg;
		msg["type"] = JSONValue("event");
		msg["event"] = JSONValue(event);
		if (body.type != JSONType.null_)
			msg["body"] = body;
		send(msg);
	}

	void sendResponse(int requestSeq, string command, bool success,
					  JSONValue body = JSONValue(), string message = null)
	{
		JSONValue[string] msg;
		msg["type"] = JSONValue("response");
		msg["request_seq"] = JSONValue(requestSeq);
		msg["command"] = JSONValue(command);
		msg["success"] = JSONValue(success);
		if (body.type != JSONType.null_)
			msg["body"] = body;
		if (message.length)
			msg["message"] = JSONValue(message);
		send(msg);
	}

	void sendError(int requestSeq, string command, string message)
	{
		sendResponse(requestSeq, command, false, JSONValue(), message);
	}

private:
	bool fill()
	{
		enum chunk = 4096;
		ubyte[chunk] buffer;
		DWORD got = 0;
		if (!ReadFile(hIn, buffer.ptr, chunk, &got, null) || got == 0)
			return false;
		pending ~= buffer[0 .. got];
		return true;
	}

	string readLine()
	{
		for (;;)
		{
			foreach (size_t i, ubyte c; pending)
				if (c == '\n')
				{
					string line = cast(string) pending[0 .. i];
					pending = pending[i + 1 .. $];
					if (line.length && line[$ - 1] == '\r')
						line = line[0 .. $ - 1];
					return line;
				}
			if (!fill())
			{
				if (pending.length == 0)
					return null;
				string line = cast(string) pending;
				pending = null;
				return line;
			}
		}
	}

	string readText(size_t length)
	{
		while (pending.length < length)
			if (!fill())
				return null;
		string text = cast(string) pending[0 .. length];
		pending = pending[length .. $];
		return text;
	}
}


/// JSON helpers shared by the DAP command handlers.

JSONValue getField(JSONValue obj, string name)
{
	if (obj.type != JSONType.object)
		return JSONValue();
	auto p = name in obj.object;
	return p is null ? JSONValue() : *p;
}

bool hasField(JSONValue obj, string name)
{
	return obj.type == JSONType.object && (name in obj.object) !is null;
}

string getString(JSONValue obj, string name, string dflt = null)
{
	auto v = getField(obj, name);
	return v.type == JSONType.string ? v.str : dflt;
}

int getInteger(JSONValue obj, string name, int dflt = 0)
{
	auto v = getField(obj, name);
	if (v.type == JSONType.integer)
		return cast(int) v.integer;
	if (v.type == JSONType.uinteger)
		return cast(int) v.uinteger;
	if (v.type == JSONType.float_)
		return cast(int) v.floating;
	return dflt;
}

bool getBool(JSONValue obj, string name, bool dflt = false)
{
	auto v = getField(obj, name);
	return (v.type == JSONType.true_ || v.type == JSONType.false_) ? v.boolean : dflt;
}

string[] getStringArray(JSONValue obj, string name)
{
	auto v = getField(obj, name);
	if (v.type != JSONType.array)
		return null;
	string[] result;
	foreach (ref e; v.array)
		if (e.type == JSONType.string)
			result ~= e.str;
	return result;
}

JSONValue[] jsonArray(JSONValue obj, string name)
{
	auto v = getField(obj, name);
	return v.type == JSONType.array ? v.array : null;
}

JSONValue jsonObject(JSONValue[string] members)
{
	return JSONValue(members);
}

JSONValue emptyArray()
{
	return JSONValue(new JSONValue[0]);
}

/// Fold ASCII case, used to compare file names case insensitively.
string asciiLower(string s)
{
	char[] r = s.dup;
	foreach (ref char c; r)
		if (c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
	return cast(string) r;
}
