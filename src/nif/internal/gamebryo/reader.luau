--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
NIFs of every version OpenMW reads, from Morrowind to Starfield: a port of jess-nif's
multi-version reader, which ports OpenMW's `components/nif`. Records are read the way OpenMW
reads them, into tables named after its classes with every base class's fields, and every link
is checked after loading: it must point to a record of the class it needs. This reader is for
inspecting and checking; `nif.open` is the editable model of Morrowind NIFs.
]]

local Classes = require './classes'
local G = require './stream'
local Header = require '../header'
-- Generated nonstrict; a codec is the record class's `read` and `check`.
local L = require './links'
local Load: { [string]: any } = require './load' :: any

local Factory = Classes.factory

export type File = {
  header: Header.Header,
  --- Each record, by 1-based index: its fields, and its record name as `type`.
  records: { any },
  --- Each record's class, as OpenMW reads it.
  classes: { string },
  --- Each record's `RecordType`.
  recordTypes: { string },
  --- Each record's name in the file. A record's `type` is its name too, except where the class
  --- has a field of that name (`BSShaderProperty`), as jess-nif's dump has it.
  names: { string },
  --- The root links as written, -1 for none.
  roots: { number },
}

--- Reads a NIF the way OpenMW does: the header, every record through its factory, the roots,
--- and then every link, which must point to a record of the right class. Errors are tables,
--- `{ message, record }`, worded as OpenMW words them.
local function open(data: buffer | string): File
  local b = if type(data) == 'string' then buffer.fromstring(data) else data
  local header = Header.parse(b)
  local fileVersion = header.version
  local s: G.Stream = {
    b = b,
    n = buffer.len(b),
    version = fileVersion,
    userVersion = header.userVersion,
    bethVersion = header.bethVersion or 0,
    strings = header.strings,
    recordName = '',
  }

  local listed = fileVersion >= 0x05000001
  local separators = fileVersion >= 0x0A000000 and fileVersion < 0x0A020000
  local count = header.recordCount
  local reserve = math.min(count, buffer.len(b) // 4)
  local records: { any } = table.create(reserve)
  local names, classes, recordTypes =
    table.create(reserve) :: { string },
    table.create(reserve) :: { string },
    table.create(reserve) :: { string }
  local p = header.size
  for i = 1, count do
    G.at(i - 1)
    local name: string
    if listed then
      name = Header.recordType(header, i - 1) or G.fail(`Record {i - 1} has no type`)
    else
      name, p = G.string(s, p)
    end

    if name == '' then G.fail(`Record type is blank (index {i - 1})`) end

    if separators and string.sub(name, 1, 3) ~= 'bhk' then
      local separator = buffer.readi32(b, p)
      p += 4
      if separator ~= 0 then G.fail(`Non-zero separator precedes {name}, index {i - 1}`) end
    end

    local entry = Factory[name]
    if not entry then G.fail(`Unknown record type {name}`) end

    local codec = Load[entry[1]]
    if not codec then G.fail(`No reader for class {entry[1]} ({name})`) end

    s.recordName = name
    records[i], p = codec.read(s, p)
    names[i], classes[i], recordTypes[i] = name, entry[1], entry[2]
  end

  G.at(nil)
  local rootCount = buffer.readu32(b, p)
  local roots = table.create(math.min(rootCount, buffer.len(b) // 4)) :: { number }
  for i = 1, rootCount do
    roots[i] = buffer.readi32(b, p + i * 4)
  end

  L.setNames(names)
  for i, record in records do
    G.at(i - 1)
    Load[classes[i]].check(record, records, classes, i - 1)
  end

  G.at(nil)
  return {
    header = header,
    records = records,
    names = names,
    classes = classes,
    recordTypes = recordTypes,
    roots = roots,
  }
end

return table.freeze { open = open }
