--!strict
--!native
--[[
@dreamwind/tools/tes3conv: tes3conv's JSON plugins as jess record tables, and record tables
written into a plugin the way tes3conv writes them.

  decode(text, options?)  the records of a tes3conv JSON document, header first
  read(path, options?)    the same, from a file
  realize(record)         a record decode() left unread, read now (in place); returns it
  prepare(record)         the record as tes3conv's encoder would write it, ready for plugin:insert
  plugin(records)         a new jess plugin holding the records, header first
  records(plugin)         a jess plugin's records as the tables tes3conv would have read

Records come out as `record:decode()` spells them: a `type` field holding the type name, and
camelCase field names (`speaker_id` is `speakerId`). Values are left as tes3conv wrote them: flags
are strings ("PERSISTENT | DELETED"), enums their names.

`options.lazy` names record types to leave unread: `{ Cell = true, Landscape = true }` reads only
those records' `type`, and `realize` reads the rest when it's wanted. A Morrowind.json is mostly
cells and landscape, so a tool that only needs its objects and dialogue reads it five times
faster. `options.rawKeys = true` keeps keys as the document spells them, for reading reports.

tes3conv 0.4.1 writes every string NUL-terminated and leaves out an object count of 1 on a
plugin's own references. jess writes the text fields Morrowind.esm leaves unterminated as they
are, and keeps every count, so `prepare` adds the terminators and drops the counts tes3conv
would: what `plugin` builds is byte for byte what tes3conv would compile from the same JSON.
]]

local tes3 = require '../lib/tes3'

type Table = tes3.Table
type Value = tes3.Value
type Records = tes3.Records

export type Options = { lazy: { [string]: boolean }?, rawKeys: boolean? }

local tes3conv = {}

local Escapes: { [string]: string } = {
  n = '\n',
  r = '\r',
  t = '\t',
  b = '\b',
  f = '\f',
  ['/'] = '/',
  ['\\'] = '\\',
  ['"'] = '"',
}

local camelCache: { [string]: string } = {}

-- omwaddon::symbol::camel_case: `_` before a lowercase letter becomes that letter uppercased,
-- except at the start.
local function camel(key: string): string
  local cached = camelCache[key]

  if cached then return cached end

  local spelled = string.sub(key, 1, 1) .. string.gsub(string.sub(key, 2), '_(%l)', string.upper)
  camelCache[key] = spelled
  return spelled
end

local function unescape(escape: string, hex: string): string
  if escape == 'u' then return utf8.char(tonumber(hex, 16) :: number) end

  return (Escapes[escape] or escape) .. hex
end

local pending: { [Table]: { text: string, start: number, rawKeys: boolean } } = {}
setmetatable(pending, { __mode = 'k' })

-- A JSON value starting at `position` of `text`, and the position after it.
local function parse(text: string, position: number, rawKeys: boolean): (Value, number)
  local value: (position: number) -> (Value, number)

  local function readString(position: number): (string, number)
    local first = position + 1
    local stop = string.find(text, '["\\]', first) :: number

    if string.byte(text, stop) == 34 then return string.sub(text, first, stop - 1), stop + 1 end

    while string.byte(text, stop) == 92 do
      stop = string.find(text, '["\\]', stop + 2) :: number
    end

    local raw = string.sub(text, first, stop - 1)
    return (string.gsub(raw, '\\(.)(%x?%x?%x?%x?)', unescape)), stop + 1
  end

  function value(position: number): (Value, number)
    position = string.find(text, '%S', position) :: number
    local byte = string.byte(text, position)

    if byte == 123 then
      local object: Table = {}
      position = string.find(text, '%S', position + 1) :: number

      if string.byte(text, position) == 125 then return object, position + 1 end

      while true do
        local key: string, item: Value
        key, position = readString(position)
        position = string.find(text, ':', position, true) :: number
        item, position = value(position + 1)
        object[if rawKeys then key else camel(key)] = item
        position = string.find(text, '%S', position) :: number

        if string.byte(text, position) ~= 44 then return object, position + 1 end

        position = string.find(text, '%S', position + 1) :: number
      end
    elseif byte == 91 then
      local list: Table = {}
      local count = 0
      position = string.find(text, '%S', position + 1) :: number

      if string.byte(text, position) == 93 then return list, position + 1 end

      while true do
        local item: Value
        item, position = value(position)
        count += 1
        list[count] = item
        position = string.find(text, '%S', position) :: number

        if string.byte(text, position) ~= 44 then return list, position + 1 end

        position += 1
      end
    elseif byte == 34 then
      return readString(position)
    elseif byte == 116 then
      return true, position + 4
    elseif byte == 102 then
      return false, position + 5
    elseif byte == 110 then
      return jess.null, position + 4
    end

    local stop = string.find(text, '[^-+.%deE]', position) :: number
    return tonumber(string.sub(text, position, stop - 1)) :: number, stop
  end

  return value(position)
end

-- A JSON document (any value), with keys camelCase unless `rawKeys`.
function tes3conv.json(text: string, rawKeys: boolean?): Value
  return (parse(text, 1, rawKeys == true))
end

function tes3conv.decode(text: string, options: Options?): Records
  local lazy = options and options.lazy or {}
  local rawKeys = options ~= nil and options.rawKeys == true
  local records: Records = {}
  local position = string.find(text, '[', 1, true)

  if not position then error 'a tes3conv plugin is a JSON array of records' end

  -- tes3conv indents a record's fields four spaces, so "\n  }" closes a top-level record and
  -- nothing inside it. Records of a lazy type are found by that and read later.
  while true do
    local first = string.find(text, '[{%]]', position + 1) :: number

    if string.byte(text, first) == 93 then break end

    local kind = string.match(text, '^{%s*"type":%s*"(%w+)"', first)

    if kind and lazy[kind] then
      local stop = string.find(text, '\n  }', first, true)

      if not stop then
        error 'a lazily read tes3conv record must be indented as tes3conv writes it'
      end

      local stub: Table = { type = kind }
      pending[stub] = { text = text, start = first, rawKeys = rawKeys }
      table.insert(records, stub)
      position = stop + 4
    else
      local record: Value
      record, position = parse(text, first, rawKeys)
      table.insert(records, record :: Table)
    end

    position = string.find(text, '%S', position) :: number

    if string.byte(text, position) ~= 44 then break end
  end

  return records
end

function tes3conv.read(path: string, options: Options?): Records
  local text = jess.fs.read(path)

  if not text then error(`'{path}' doesn't exist`) end

  return tes3conv.decode(text, options)
end

function tes3conv.isLazy(record: Table): boolean return pending[record] ~= nil end

function tes3conv.realize(record: Table): Table
  local source = pending[record]

  if not source then return record end

  pending[record] = nil
  local full = parse(source.text, source.start, source.rawKeys) :: Table

  for key, item in full do
    record[key] = item
  end

  return record
end

-- The fields jess writes exactly as they are and tes3conv terminates with a NUL.
local ExactText: { [string]: string } = {
  Book = 'text',
  Class = 'description',
  DialogueInfo = 'scriptText',
  MagicEffect = 'description',
  Race = 'description',
  Script = 'text',
  Skill = 'description',
}

local function terminated(text: Value?): Value?
  if type(text) == 'string' and text ~= '' and string.byte(text, -1) ~= 0 then
    return text .. '\0'
  end

  return text
end

function tes3conv.prepare(record: Table): Table
  local kind = record.type
  local field = ExactText[kind :: string]

  if field then
    local text = record[field]
    local written = terminated(text)

    if written ~= text then
      record = table.clone(record)
      record[field] = written :: Value
    end
  elseif kind == 'GameSetting' then
    local setting = record.value :: Table

    if setting.type == 'String' then
      local written = terminated(setting.data)

      if written ~= setting.data then
        record = table.clone(record)
        local copy = table.clone(setting)
        copy.data = written :: Value
        record.value = copy
      end
    end
  elseif kind == 'Cell' then
    local references = record.references :: { Table }?

    if references then
      local copied: { Table } = table.clone(references)

      for index, reference in copied do
        if reference.objectCount == 1 and reference.mastIndex == 0 then
          local trimmed = table.clone(reference)
          trimmed.objectCount = nil
          copied[index] = trimmed
        end
      end

      tes3conv.sortReferences(copied)
      record = table.clone(record)
      record.references = copied
    end
  end

  return record
end

-- tes3's `Reference::persistent`: moved references and doors with destinations always are.
local function persistent(reference: Table): boolean
  return reference.movedCell ~= nil or reference.destination ~= nil or reference.temporary ~= true
end

tes3conv.isPersistent = persistent

-- References in the order tes3 writes them: persistent first, then the masters' by master and
-- index, then the plugin's own by index. jess writes them in this order too, and its insert
-- checks a cell's references against what it would write, position by position.
function tes3conv.sortReferences(references: { Table })
  table.sort(references, function(left, right)
    local a, b = persistent(left), persistent(right)

    if a ~= b then return a end

    local leftMaster, rightMaster = left.mastIndex :: number, right.mastIndex :: number
    leftMaster = if leftMaster == 0 then math.huge else leftMaster
    rightMaster = if rightMaster == 0 then math.huge else rightMaster

    if leftMaster ~= rightMaster then return leftMaster < rightMaster end

    return (left.refrIndex :: number) < (right.refrIndex :: number)
  end)
end

-- tes3conv sorts a plugin's records before it writes them (see `sort`).
function tes3conv.sort(records: Records): Records
  local sorted = table.clone(records)
  tes3.sortObjects(sorted)
  return sorted
end

-- A new plugin holding `records`, in their order: pass them through `sort` first for what
-- `tes3conv plugin.json plugin.esp` would write.
function tes3conv.plugin(records: Records): Plugin
  local plugin = jess.plugin.new()
  local header = plugin:record(0) :: Record
  header:set(records[1] :: RecordValue)

  for index = 2, #records do
    local record = records[index]
    -- plugin:insert raises for a field the record type doesn't have, or the wrong shape of one.
    local inserted, problem = pcall(plugin.insert, plugin, tes3conv.prepare(record) :: RecordFields)

    if not inserted then
      error(`record {index - 1} ({tes3.string(record.type)} {tes3.editorId(record)}): {problem}`)
    end
  end

  return plugin
end

-- tes3's string loader stops at the first NUL; jess keeps the exact fields whole.
local function truncated(text: Value?): Value?
  if type(text) == 'string' then
    local nul = string.find(text, '\0', 1, true)

    if nul then return string.sub(text, 1, nul - 1) end
  end

  return text
end

-- A plugin's records as `tes3conv plugin.esp plugin.json` reads them, sorted as it sorts them,
-- and each record's bytes in the same order.
function tes3conv.recordsWithBytes(plugin: Plugin): (Records, { string })
  local records: Records, bytes: { string } = {}, {}

  for record in plugin:records() do
    local value = record:decode() :: Table?

    if not value then error(`{tostring(record)} has a record type tes3conv can't read`) end

    local field = ExactText[value.type :: string]

    if field then
      value[field] = truncated(value[field]) :: Value
    elseif value.type == 'GameSetting' then
      local setting = value.value :: Table

      if setting.type == 'String' then setting.data = truncated(setting.data) :: Value end
    end

    table.insert(records, value)
    table.insert(bytes, buffer.tostring(record:bytes()))
  end

  local sortedRecords: Records, sortedBytes: { string } = {}, {}

  for position, from in tes3.sortPermutation(records) do
    sortedRecords[position] = records[from]
    sortedBytes[position] = bytes[from]
  end

  return sortedRecords, sortedBytes
end

function tes3conv.records(plugin: Plugin): Records return (tes3conv.recordsWithBytes(plugin)) end

return tes3conv
