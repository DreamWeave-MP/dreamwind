--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
NIF headers of every version, from Morrowind's NetImmerse 4.0.0.2 to Starfield: the header half
of OpenMW's `Nif::Reader::parse` (`components/nif/niffile.cpp`). The version line, versions,
and, where the version has them, the record type table, record sizes, string table, and groups.
Records aren't read here.
]]

local Text = require './text'

local Spellings: dream_intern_Pool = Text.pool

--- Each spelling's text as the header holds it, by its token in the shared pool: cut at the
--- first NUL, as UTF-8, invalid bytes replaced (jess-nif reads header strings lossily).
local Texts: { string } = {}

--- A version as one comparable number, `major.minor.patch.revision` big end first.
local function version(major: number, minor: number, patch: number, revision: number): number
  return major * 0x1000000 + minor * 0x10000 + patch * 0x100 + revision
end

local Versions = table.freeze {
  --- Morrowind's NIF version.
  morrowind = version(4, 0, 0, 2),
  --- The older Oblivion NIF version.
  oblivionOld = version(10, 0, 1, 2),
  --- The main Oblivion NIF version.
  oblivion = version(20, 0, 0, 5),
  --- Fallout 3/New Vegas/4/76, Skyrim, and Skyrim SE.
  bethesda = version(20, 2, 0, 7),
}

--- `NIFFile::BETHVER_*`: Bethesda stream versions that change what records hold.
local BethVersions = table.freeze {
  fo3 = 34,
  skyrim = 83,
  sse = 100,
  fo4 = 130,
  f76 = 155,
  starfield = 172,
}

export type Header = {
  --- The first line, such as `NetImmerse File Format, Version 4.0.0.2`.
  versionLine: string,
  version: number,
  userVersion: number,
  --- The Bethesda stream version, when the file has a Bethesda stream header.
  bethVersion: number?,
  author: string?,
  recordCount: number,
  --- The record type table (5.0.0.1 and later); record `i`'s type is
  --- `recordTypes[recordTypeIndices[i] + 1]`.
  recordTypes: { string },
  recordTypeIndices: { number },
  --- Each record's size in bytes (20.2.0.5 and later).
  recordSizes: { number },
  --- The shared string table (20.1.0.1 and later).
  strings: { string },
  --- Where the records start.
  size: number,
}

--- The bytes of a header field the file ends before, as jess-nif words it.
local function truncated(offset: number, what: string): never
  error(`truncated {what} at offset {offset}`, 0)
end

--- `String::from_utf8_lossy`: each maximal run of bytes that isn't UTF-8 becomes U+FFFD.
local function lossy(text: string): string
  if utf8.len(text) then return text end

  local out: { string }, i, n = {}, 1, #text
  while i <= n do
    local valid, bad = utf8.len(text, i)
    if valid then
      table.insert(out, string.sub(text, i))
      break
    end

    local at = bad :: number
    table.insert(out, string.sub(text, i, at - 1))
    -- A lead byte and the continuation bytes after it that fit count as one bad sequence.
    local first = string.byte(text, at)
    local width = if first >= 0xF0 then 4 elseif first >= 0xE0 then 3 else 2
    local stop = at + 1
    if first >= 0xC2 and first <= 0xF4 then
      while stop < at + width and stop <= n do
        local byte = string.byte(text, stop)
        if byte < 0x80 or byte > 0xBF then break end

        stop += 1
      end
    end

    table.insert(out, '\u{FFFD}')
    i = stop
  end

  return table.concat(out)
end

--- Parses the header at the start of `b`. Errors name what OpenMW rejects (a bad signature,
--- big-endian data, hashed record types) and where the header is truncated.
local function parse(b: buffer): Header
  local n = buffer.len(b)
  local p = 0

  local function take(length: number, what: string): number
    if p + length > n then truncated(p, what) end

    local at = p
    p += length
    return at
  end

  local function u8(what: string): number return buffer.readu8(b, take(1, what)) end

  local function u16(what: string): number return buffer.readu16(b, take(2, what)) end

  local function u32(what: string): number return buffer.readu32(b, take(4, what)) end

  -- The whole field is interned (in native code), and cut and made valid once per spelling.
  local function sized(length: number, what: string): string
    local at = take(length, what)
    local token = Spellings:intern(b, at, length)
    local text = Texts[token]
    if text then return text end

    text = buffer.readstring(b, at, length)
    local nul = string.find(text, '\0', 1, true)
    if nul then text = string.sub(text, 1, nul - 1) end

    text = lossy(text)
    Texts[token] = text
    return text
  end

  local lineEnd = -1
  for i = 0, n - 1 do
    if buffer.readu8(b, i) == 10 then
      lineEnd = i
      break
    end
  end

  if lineEnd < 0 then truncated(0, 'version line') end

  local versionLine = lossy(buffer.readstring(b, 0, lineEnd))
  p = lineEnd + 1
  local signed = string.find(versionLine, 'NetImmerse File Format', 1, true) == 1
    or string.find(versionLine, 'Gamebryo File Format', 1, true) == 1
  if not signed then error(`Invalid NIF header: {versionLine}`, 0) end

  local fileVersion = u32 'version'
  if fileVersion >= version(20, 0, 0, 4) and u8 'endianness' == 0 then
    error('Big endian NIF files are unsupported', 0)
  end

  local userVersion = if fileVersion >= version(10, 0, 1, 8) then u32 'user version' else 0
  local count = u32 'record count'
  local bethesdaStream = fileVersion == Versions.oblivionOld
    or (
      userVersion >= 3
      and fileVersion >= version(10, 1, 0, 0)
      and (fileVersion <= Versions.oblivion or fileVersion == Versions.bethesda)
      and (userVersion <= 11 or fileVersion >= Versions.oblivion)
    )

  local bethVersion, author
  if bethesdaStream then
    bethVersion = u32 'Bethesda version'
    author = sized(u8 'author', 'author')
    if bethVersion >= 131 then
      u32 'Bethesda header'
    else
      sized(u8 'process script', 'process script')
    end

    sized(u8 'export script', 'export script')
    if bethVersion >= 103 then sized(u8 'max file path', 'max file path') end
  end

  local recordTypes: { string }, recordTypeIndices: { number }, recordSizes: { number }, strings: { string } =
    {}, {}, {}, {}
  if fileVersion >= version(5, 0, 0, 1) then
    if fileVersion == version(20, 3, 1, 2) then error('Hashed record types are unsupported', 0) end

    for i = 1, u16 'record type count' do
      recordTypes[i] = sized(u32 'record type', 'record type')
    end

    -- All at once when they fit; one at a time otherwise, so a short file names where it ends.
    if p + count * 2 <= n then
      local at = take(count * 2, 'record type index')
      for i = 1, count do
        recordTypeIndices[i] = buffer.readu16(b, at + (i - 1) * 2)
      end
    else
      for i = 1, count do
        recordTypeIndices[i] = u16 'record type index'
      end
    end
  end

  if fileVersion >= version(20, 2, 0, 5) then
    if p + count * 4 <= n then
      local at = take(count * 4, 'record size')
      for i = 1, count do
        recordSizes[i] = buffer.readu32(b, at + (i - 1) * 4)
      end
    else
      for i = 1, count do
        recordSizes[i] = u32 'record size'
      end
    end
  end

  if fileVersion >= version(20, 1, 0, 1) then
    local total = u32 'string count'
    u32 'longest string'
    for i = 1, total do
      strings[i] = sized(u32 'string', 'string')
    end
  end

  if fileVersion >= version(5, 0, 0, 6) then
    for _ = 1, u32 'group count' do
      u32 'group'
    end
  end

  for i, typeIndex in recordTypeIndices do
    local name = recordTypes[typeIndex + 1]
    if not name or name == '' then error(`Record type is blank (index {i - 1})`, 0) end
  end

  return {
    versionLine = versionLine,
    version = fileVersion,
    userVersion = userVersion,
    bethVersion = bethVersion,
    author = author,
    recordCount = count,
    recordTypes = recordTypes,
    recordTypeIndices = recordTypeIndices,
    recordSizes = recordSizes,
    strings = strings,
    size = p,
  }
end

--- The type of record `index` (0-based), when the header lists record types.
local function recordType(header: Header, index: number): string?
  local typeIndex = header.recordTypeIndices[index + 1]
  return if typeIndex then header.recordTypes[typeIndex + 1] else nil
end

--- The game a file was made for, by its versions: `Morrowind`, `Oblivion`, `Fallout 3/New
--- Vegas`, `Skyrim`, `Skyrim Special Edition`, `Fallout 4`, `Fallout 76`, `Starfield`, or
--- `other`.
local function game(header: Header): string
  local fileVersion, beth = header.version, header.bethVersion
  if fileVersion == Versions.morrowind then return 'Morrowind' end

  if fileVersion >= Versions.oblivionOld and fileVersion <= Versions.oblivion then
    return 'Oblivion'
  end

  if fileVersion ~= Versions.bethesda or not beth then return 'other' end

  if beth <= 82 then return 'Fallout 3/New Vegas' end

  if beth <= 99 then return 'Skyrim' end

  if beth <= 129 then return 'Skyrim Special Edition' end

  if beth <= 154 then return 'Fallout 4' end

  if beth <= 171 then return 'Fallout 76' end

  return 'Starfield'
end

--- `major.minor.patch.revision`.
local function versionString(value: number): string
  return `{value // 0x1000000}.{value // 0x10000 % 0x100}.{value // 0x100 % 0x100}.{value % 0x100}`
end

--- The root record indices, read after the records when the header gives record sizes; nil when
--- the sizes aren't known or the roots are truncated.
local function roots(header: Header, b: buffer): { number }?
  if #header.recordSizes == 0 and header.recordCount > 0 then return nil end

  local p = header.size
  for _, size in header.recordSizes do
    p += size
  end

  local n = buffer.len(b)
  if p + 4 > n then return nil end

  local count = buffer.readu32(b, p)
  if p + 4 + count * 4 > n then return nil end

  local list = table.create(count) :: { number }
  for i = 1, count do
    list[i] = buffer.readi32(b, p + i * 4)
  end

  return list
end

return table.freeze {
  parse = parse,
  recordType = recordType,
  game = game,
  roots = roots,
  version = version,
  versionString = versionString,
  versions = Versions,
  bethVersions = BethVersions,
  lossy = lossy,
}
