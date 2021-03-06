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
 * Portions created by the Initial Developer are Copyright (C) 2009-2011
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

module ae.sys.dataio;

import ae.sys.data;

// ************************************************************************

import std.stream : Stream;

Data readStreamData(Stream s)
{
	auto size = s.size - s.position;
	assert(size < size_t.max);
	auto data = Data(cast(size_t)size);
	s.readExact(data.mptr, data.length);
	return data;
}

Data readData(string filename)
{
	scope file = new std.stream.File(filename);
	scope(exit) file.close();
	return readStreamData(file);
}

// ************************************************************************

import std.stdio;

Data readFileData(ref File f)
{
	Data buf = Data(1024*1024);
	Data result;
	while (!f.eof())
		result ~= f.rawRead(cast(ubyte[])buf.mcontents);
	buf.deleteContents();
	return result;
}
