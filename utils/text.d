/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the Team15 library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2007-2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

/// Utility code related to string and text processing.
module ae.utils.text;

import std.exception;
import std.string;
import std.ascii;
import ae.utils.textout;
import core.stdc.string;

// ************************************************************************

bool contains(string str, string what)
{
	return str.indexOf(what)>=0;
}

string fastReplace(string what, string from, string to)
{
	enum RAM = cast(char*)null;

	if (from.length==1)
	{
		auto fromc = from[0];
		if (to.length==1)
		{
			auto p = cast(char*)memchr(what.ptr, fromc, what.length);
			if (!p)
				return what;

			auto result = what.dup;
			auto delta = result.ptr - what.ptr;
			auto toChar = to[0];
			auto end = what.ptr + what.length;
			do
			{
				p[delta] = toChar; // zomg hax lol
				p++;
				p = cast(char*)memchr(p, fromc, end - p);
			} while (p);
			return assumeUnique(result);
		}
		else
		{
			auto p = cast(immutable(char)*)memchr(what.ptr, fromc, what.length);
			if (!p)
				return what;

			auto sb = StringBuilder(what.length);
			do
			{
				sb.put(what[0..p-what.ptr], to);
				what = what[p-what.ptr+1..$];
				p = cast(immutable(char)*)memchr(what.ptr, fromc, what.length);
			}
			while (p);

			sb.put(what);
			return sb.get();
		}
	}

	auto head = from[0];
	auto tail = from[1..$];

	auto p = cast(char*)what.ptr;
	auto end = p + what.length;
	p = cast(char*)memchr(p, head, end-p);
	while (p)
	{
		p++;
		if (p[0..tail.length] == tail)
		{
			if (from.length == to.length)
			{
				auto result = what.dup;
				auto deltaMinusOne = (result.ptr - what.ptr) - 1;

				goto replaceA;
			dummyA: // compiler complains

				do
				{
					p++;
					if (p[0..tail.length] == tail)
					{
					replaceA:
						(p+deltaMinusOne)[0..to.length] = to;
					}
					p = cast(char*)memchr(p, head, end-p);
				}
				while (p);

				return assumeUnique(result);
			}
			else
			{
				auto start = cast(char*)what.ptr;
				auto sb = StringBuilder(what.length);
				goto replaceB;
			dummyB: // compiler complains

				do
				{
					p++;
					if (p[0..tail.length] == tail)
					{
					replaceB:
						sb.put(RAM[cast(size_t)start .. cast(size_t)p-1], to);
						start = p + tail.length;
						what = what[start-what.ptr..$];
					}
					else
					{
						what = what[p-what.ptr..$];
					}
					p = cast(char*)memchr(what.ptr, head, what.length);
				}
				while (p);

				//sb.put(what);
				sb.put(RAM[cast(size_t)start..cast(size_t)(what.ptr+what.length)]);
				return sb.get();
			}

			assert(0);
		}
		p = cast(char*)memchr(p, head, end-p);
	}

	return what;
}

unittest
{
	import std.array;
	void test(string haystack, string from, string to)
	{
		auto description = `("` ~ haystack ~ `", "` ~ from ~ `", "` ~ to ~ `")`;

		auto r1 = fastReplace(haystack, from, to);
		auto r2 =     replace(haystack, from, to);
		assert(r1 == r2, `Bad replace: ` ~ description ~ ` == "` ~ r1 ~ `"`);

		if (r1 == haystack)
			assert(r1 is haystack, `Pointless reallocation: ` ~ description);
	}

	test("Mary had a little lamb", "a", "b");
	test("Mary had a little lamb", "a", "aaa");
	test("Mary had a little lamb", "Mary", "Lucy");
	test("Mary had a little lamb", "Mary", "Jimmy");
	test("Mary had a little lamb", " l", " x");
	test("Mary had a little lamb", " l", " xx");

	test("Mary had a little lamb", "X" , "Y" );
	test("Mary had a little lamb", "XX", "Y" );
	test("Mary had a little lamb", "X" , "YY");
	test("Mary had a little lamb", "XX", "YY");
	test("Mary had a little lamb", "aX", "Y" );
	test("Mary had a little lamb", "aX", "YY");
}

string[] fastSplit(string s, char d)
{
	auto p = cast(immutable(char)*) memchr(s.ptr, d, s.length);
	if (!p)
		return [s];
	size_t n;
	auto end = s.ptr + s.length;
	do
	{
		n++;
		p++;
		p = cast(immutable(char)*) memchr(p, d, end-p);
	}
	while (p);

	auto result = new string[n+1];
	n = 0;
	auto start = s.ptr;
	p = cast(immutable(char)*) memchr(start, d, s.length);
	do
	{
		result[n++] = start[0..p-start];
		start = ++p;
		p = cast(immutable(char)*) memchr(p, d, end-p);
	}
	while (p);
	result[n] = start[0..end-start];

	return result;
}

string[] splitAsciiLines(string text)
{
	auto lines = text.split("\n");
	foreach (ref line; lines)
		if (line.length && line[$-1]=='\r')
			line = line[0..$-1];
	return lines;
}

/// Covering slice-list of s with interleaved whitespace.
string[] segmentByWhitespace(string s)
{
	if (!s.length)
		return null;

	string[] segments;
	bool wasWhite = isWhite(s[0]);
	size_t start = 0;
	foreach (p, char c; s)
	{
		bool isWhite = isWhite(c);
		if (isWhite != wasWhite)
			segments ~= s[start..p],
			start = p;
		wasWhite = isWhite;
	}
	segments ~= s[start..$];

	return segments;
}

import std.utf;

/// Convert any data to a valid UTF-8 bytestream, so D's string functions can
/// properly work on it.
string rawToUTF8(in char[] s)
{
	auto d = new dchar[s.length];
	foreach (i, char c; s)
		d[i] = c;
	return toUTF8(d);
}

/// Undo rawToUTF8.
string UTF8ToRaw(in char[] r)
{
	auto s = new char[r.length];
	size_t i = 0;
	foreach (dchar c; r)
	{
		assert(c < '\u0100');
		s[i++] = cast(char)c;
	}
	return assumeUnique(s[0..i]);
}

unittest
{
	char[1] c;
	for (int i=0; i<256; i++)
	{
		c[0] = cast(char)i;
		assert(UTF8ToRaw(rawToUTF8(c[])) == c[], format("%s -> %s -> %s", cast(ubyte[])c[], cast(ubyte[])rawToUTF8(c[]), cast(ubyte[])UTF8ToRaw(rawToUTF8(c[]))));
	}
}

/// Where a delegate with this signature is required.
string nullStringTransform(in char[] s) { return s.idup; }

string forceValidUTF8(string s)
{
	try
	{
		validate(s);
		return s;
	}
	catch (UtfException)
		return rawToUTF8(s);
}

// ************************************************************************

/// Formats binary data as a hex dump (three-column layout consisting of hex
/// offset, byte values in hex, and printable low-ASCII characters).
string hexDump(const(void)[] b)
{
	auto data = cast(const(ubyte)[]) b;
	int i=0;
	string s;
	while (i<data.length)
	{
		s ~= format("%08X:  ", i);
		for (int x=0;x<16;x++)
		{
			if (i+x<data.length)
				s ~= format("%02X ", data[i+x]);
			else
				s ~= "   ";
			if (x==7)
				s ~= "| ";
		}
		s ~= "  ";
		for (int x=0;x<16;x++)
		{
			if (i+x<data.length)
				if (data[i+x]==0)
					s ~= ' ';
				else
				if (data[i+x]<32 || data[i+x]>=128)
					s ~= '.';
				else
					s ~= cast(char)data[i+x];
			else
				s ~= ' ';
		}
		s ~= "\n";
		i += 16;
	}
	return s;
}

import std.conv;

T fromHex(T : ulong = uint)(string s)
{
	T result = parse!T(s, 16);
	enforce(s.length==0, new ConvException("Could not parse entire string"));
	return result;
}

ubyte[] arrayFromHex(string s)
{
	enforce(s.length % 2 == 0, "Odd length");
	auto result = new ubyte[s.length/2];
	foreach (i, ref b; result)
		b = fromHex!ubyte(s[i*2..i*2+2]);
	return result;
}

// ************************************************************************

import std.random;

string randomString(int length=20, string chars="abcdefghijklmnopqrstuvwxyz")
{
	char[] result = new char[length];
	foreach (ref c; result)
		c = chars[uniform(0, $)];
	return assumeUnique(result);
}
