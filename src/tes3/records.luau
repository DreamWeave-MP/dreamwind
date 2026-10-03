--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Record identity and small record queries tools share (jess-omwaddon's `records`), read straight
from the identifying subrecord without decoding the record.
]]

local Plugin = require './plugin'
local Save = require './save'
local Tags = require './tags'
local Text = require './text'

type Plugin = Plugin.Plugin

local TES3 = Tags.code 'TES3'
local SCPT = Tags.code 'SCPT'
local SCHD = Tags.code 'SCHD'
local INFO = Tags.code 'INFO'
local INAM = Tags.code 'INAM'
local NAME = Tags.code 'NAME'
local CELL = Tags.code 'CELL'
local DIAL = Tags.code 'DIAL'
local DATA = Tags.code 'DATA'
local AMBI = Tags.code 'AMBI'
local SCTX = Tags.code 'SCTX'

--- A record's id: INAM for dialogue responses, the SCHD name for scripts, NAME otherwise; nil for
--- the TES3 header, a CELL opened without its header, and a record without its id subrecord.
local function id(plugin: Plugin, index: number): string?
  local code = plugin:code(index)
  if code == TES3 then return nil end

  if code == CELL then
    local parts = plugin:keptParts(index)
    if parts and not parts.header then return nil end
  end

  if code == SCPT then
    local source, at, size = plugin:findSubrecord(index, SCHD)
    if not source or size < 32 then return nil end

    return Text.decode(source, at, 32, plugin.encoding)
  end

  local source, at, size = plugin:findSubrecord(index, if code == INFO then INAM else NAME)
  if not source then return nil end

  -- In an OpenMW save, typed RefIds read as OpenMW spells them (`#-2 -9` for an exterior cell).
  if plugin.profile == 'omwsave' then
    local refId = Save.decodeRefId(source, at, size)
    if refId then return Save.refIdText(refId) end
  end

  return Text.decode(source, at, size, plugin.encoding)
end

--- Where record `index`'s id is in its bytes, cut where `id` cuts its text (a final NUL dropped,
--- then at the first NUL): the buffer, the offset, and the length, or nil for a record without
--- one. The bytes are in the plugin's code page, so a script can intern or compare ids without
--- decoding them; for content files, not saves, whose ids are typed.
local function idSpan(plugin: Plugin, index: number): (buffer?, number, number)
  local code = plugin:code(index)
  if code == TES3 then return nil, 0, 0 end

  if code == CELL then
    local parts = plugin:keptParts(index)
    if parts and not parts.header then return nil, 0, 0 end
  end

  local source, at, size
  if code == SCPT then
    source, at, size = plugin:findSubrecord(index, SCHD)
    if not source or size < 32 then return nil, 0, 0 end

    size = 32
  else
    source, at, size = plugin:findSubrecord(index, if code == INFO then INAM else NAME)
    if not source then return nil, 0, 0 end
  end

  local bytes = source :: buffer
  local finish = at + size
  if size > 0 and buffer.readu8(bytes, finish - 1) == 0 then
    finish -= 1
  end

  for i = at, finish - 1 do
    if buffer.readu8(bytes, i) == 0 then return bytes, at, i - at end
  end

  return bytes, at, finish - at
end

export type Key = { type: string, id: string }

--- Every identified record's `{ type, id }`, sorted by type then id, each once.
local function objectKeys(plugin: Plugin): { Key }
  local seen: { [string]: boolean } = {}
  local keys: { Key } = {}
  for i = 0, plugin:count() - 1 do
    local recordId = id(plugin, i)
    if not recordId then continue end

    local tag = Tags.display(plugin:code(i))
    local key = tag .. '\0' .. recordId
    if seen[key] then continue end

    seen[key] = true
    table.insert(keys, { type = tag, id = recordId })
  end

  table.sort(keys, function(a: Key, b: Key)
    if a.type ~= b.type then return a.type < b.type end

    return a.id < b.id
  end)
  return keys
end

--- The first record of type `tag` whose id is `recordId`, as a 0-based index, or nil.
local function find(plugin: Plugin, tag: string, recordId: string): number?
  local code = Tags.code(tag)
  for i = 0, plugin:count() - 1 do
    if plugin:code(i) == code and id(plugin, i) == recordId then return i end
  end

  return nil
end

--- Every DIAL topic's id, in plugin order.
local function dialogueTopics(plugin: Plugin): { string }
  local topics = {}
  for i = 0, plugin:count() - 1 do
    if plugin:code(i) ~= DIAL then continue end

    local topic = id(plugin, i)
    if topic then table.insert(topics, topic) end
  end

  return topics
end

--- Whether a CELL is an interior (its DATA flag bit 0); false for other records.
local function cellIsInterior(plugin: Plugin, index: number): boolean
  if plugin:code(index) ~= CELL then return false end

  local source, at, size = plugin:findSubrecord(index, DATA)
  return source ~= nil and size >= 4 and bit32.btest(buffer.readu32(source, at), 1)
end

--- Whether a CELL is an exterior; false for other records.
local function cellIsExterior(plugin: Plugin, index: number): boolean
  return plugin:code(index) == CELL and not cellIsInterior(plugin, index)
end

--- A cell's AMBI fog density, if present.
local function cellAmbientFogDensity(plugin: Plugin, index: number): number?
  local source, at, size = plugin:findSubrecord(index, AMBI)
  if not source or size < 16 then return nil end

  return buffer.readf32(source, at + 12)
end

--- The legacy fog density in a cell's DATA, if present.
local function cellDataFogDensity(plugin: Plugin, index: number): number?
  local source, at, size = plugin:findSubrecord(index, DATA)
  if not source or size < 8 then return nil end

  return buffer.readf32(source, at + 4)
end

--[[ String fields ]]

local RGNN, PNAM, NNAM = Tags.code 'RGNN', Tags.code 'PNAM', Tags.code 'NNAM'

--- The typed string field names subrecords carry in any record (jess-omwaddon's
--- `string_field_name`), by subrecord tag.
local FieldNamesByTag: { [string]: string } = {
  NAME = 'id',
  MODL = 'mesh',
  FNAM = 'name',
  ITEX = 'icon',
  SCRI = 'script',
  TEXT = 'text',
  SCTX = 'script-text',
  DESC = 'description',
  BNAM = 'body',
  CNAM = 'class',
  ANAM = 'animation',
  SNAM = 'sound',
  TNAM = 'topic',
  RNAM = 'race',
  ONAM = 'object',
  DNAM = 'data-name',
}

local FieldNames: { [number]: string } = {}
for tag, field in FieldNamesByTag do
  FieldNames[Tags.code(tag)] = field
end

--- The string field a subrecord of a record of tag `record` is, by name, or nil.
local function fieldName(record: number, sub: number): string?
  if record == CELL and sub == RGNN then return 'region' end

  if record == INFO then
    if sub == PNAM then return 'previous' end

    if sub == NNAM then return 'next' end

    if sub == INAM then return 'info-id' end

    if sub == NAME then return 'text' end
  end

  return FieldNames[sub]
end

export type StringField = {
  name: string,
  value: string,
  --- The subrecord's tag and its position in the record (0-based).
  tag: string,
  subrecord: number,
  start: number,
  finish: number,
}

--- Record `index`'s typed string fields, in subrecord order.
local function stringFields(plugin: Plugin, index: number): { StringField }
  local code = plugin:code(index)
  local source = plugin:span(index)
  local out = {}
  for i, sub in plugin:subrecords(index) do
    local name = fieldName(code, sub.code)
    if not name then continue end

    table.insert(out, {
      name = name,
      value = Text.decode(source, sub.payload, sub.size, plugin.encoding),
      tag = sub.tag,
      subrecord = i - 1,
      start = sub.start,
      finish = sub.finish,
    })
  end

  return out
end

--- What a record view names a record by (jess-omwaddon's `RecordView::id`): its first `id` or
--- `info-id` string field (so a SCPT without SCHD has its NAME), a save record's typed id, and
--- nil for a CELL read without its header.
local function fieldId(plugin: Plugin, index: number): string?
  if plugin.profile == 'omwsave' then return id(plugin, index) end

  local code = plugin:code(index)
  if code == CELL then
    local parts = plugin:keptParts(index)
    if parts and not parts.header then return nil end
  end

  local source = plugin:span(index)
  for _, sub in plugin:subrecords(index) do
    local name = fieldName(code, sub.code)
    if name == 'id' or name == 'info-id' then
      return Text.decode(source, sub.payload, sub.size, plugin.encoding)
    end
  end

  return nil
end

--- The text selectors match a subrecord against: `name: value` for a typed string field, else
--- its tag and its payload decoded in the plugin's code page.
local function subrecordText(plugin: Plugin, index: number, sub: Plugin.Subrecord): string
  local source = plugin:span(index)
  local name = fieldName(plugin:code(index), sub.code)
  if name then return `{name}: {Text.decode(source, sub.payload, sub.size, plugin.encoding)}` end

  return `{Tags.display(sub.code)}: {Text.decodeExact(
    source,
    sub.payload,
    sub.size,
    plugin.encoding
  )}`
end

--- A script record's source text (SCTX), if present.
local function scriptText(plugin: Plugin, index: number): string?
  local source, at, size = plugin:findSubrecord(index, SCTX)
  if not source then return nil end

  return Text.decode(source, at, size, plugin.encoding)
end

return table.freeze {
  cellAmbientFogDensity = cellAmbientFogDensity,
  cellDataFogDensity = cellDataFogDensity,
  cellIsExterior = cellIsExterior,
  cellIsInterior = cellIsInterior,
  dialogueTopics = dialogueTopics,
  fieldId = fieldId,
  fieldName = fieldName,
  find = find,
  id = id,
  idSpan = idSpan,
  objectKeys = objectKeys,
  scriptText = scriptText,
  stringFields = stringFields,
  subrecordText = subrecordText,
}
