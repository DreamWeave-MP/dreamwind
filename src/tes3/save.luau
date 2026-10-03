--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The OpenMW save format over the TES3 record stream (jess-plugin's `openmw_save`): format versions
and what each changed, the SAVE metadata record, the screenshot, typed `RefId`s as saves write them
(`ESM::RefId` in `components/esm3/esmwriter.cpp`), and the Lua data `LUAD` subrecords hold
(`LuaUtil::serialize` in `components/lua/serialization.cpp`).
]]

local Plugin = require './plugin'
local Tags = require './tags'

type Plugin = Plugin.Plugin

--- `CurrentSaveGameFormatVersion` in OpenMW's `components/esm3/formatversion.hpp`. When OpenMW
--- bumps it, check what the new version changed, record it in `FormatHistory`, then raise this.
local CurrentFormatVersion = 40

--- The oldest save format whose layout save editing has been checked against: format 34 and older
--- store actor references as actor ids instead of RefNums, and 36 and older store Lua script paths.
local MinMutationFormatVersion = 37

--- The oldest save format the OpenMW sources jess follows load.
local MinEngineSupportedFormatVersion = 5

--- The oldest save format whose SAVE metadata reads in this layout.
local MinMetadataFormatVersion = 25

export type FormatChange = {
  version: number,
  openmwCommit: string,
  change: string,
  affectsSaveEditing: boolean,
}

--- Every save format from `MinMutationFormatVersion` to `CurrentFormatVersion`.
local FormatHistory: { FormatChange } = {
  {
    version = 37,
    openmwCommit = 'fdc2e63152',
    change = 'Lua scripts saved by id instead of path (LUAS)',
    affectsSaveEditing = false,
  },

  {
    version = 38,
    openmwCommit = '4f53438082',
    change = 'ingredient effect indices in dynamic INGR records',
    affectsSaveEditing = false,
  },

  {
    version = 39,
    openmwCommit = '021234fa35',
    change = 'projectile wind-up (PROJ WIND float)',
    affectsSaveEditing = false,
  },

  {
    version = 40,
    openmwCommit = 'a4091dd052',
    change = 'skills and attributes saved by RefId (SKIL, ATTR, INCR); ESM3 content cannot add skills',
    affectsSaveEditing = false,
  },
}

local function fail(offset: number, message: string): never error(`{message} at offset {offset}`, 0) end

--[[ Compatibility ]]

export type Compatibility =
  { kind: 'supported' }
  | { kind: 'tooOld', version: number, minimum: number }
  | { kind: 'tooNew', version: number, maximum: number }

--- Whether OpenMW loads a save of this plugin's format version.
local function compatibility(plugin: Plugin): Compatibility
  local version = plugin:formatVersion()
  if version < MinEngineSupportedFormatVersion then
    return { kind = 'tooOld', version = version, minimum = MinEngineSupportedFormatVersion }
  end

  if version > CurrentFormatVersion then
    return { kind = 'tooNew', version = version, maximum = CurrentFormatVersion }
  end

  return { kind = 'supported' }
end

--[[ Text ]]

--- A save string: UTF-8 up to the first NUL, invalid bytes replaced.
local function saveString(source: buffer, offset: number, length: number): string
  local text = buffer.readstring(source, offset, length)
  local nul = string.find(text, '\0', 1, true)
  if nul then text = string.sub(text, 1, nul - 1) end

  return Plugin.lossyUtf8(text)
end

--[[ RefId ]]

export type RefId =
  { kind: 'empty' }
  | { kind: 'string', value: string }
  | { kind: 'formId', index: number, contentFile: number }
  | { kind: 'generated', high: number, low: number }
  | { kind: 'index', recordType: string, value: number }
  | { kind: 'exteriorCell', x: number, y: number }

--- A whole subrecord payload as one RefId, or nil unless it's exactly one.
local function decodeRefId(source: buffer, offset: number, length: number): RefId?
  if length < 1 then return nil end

  local kind = buffer.readu8(source, offset)
  local at, rest = offset + 1, length - 1
  if kind == 0 and rest == 0 then return { kind = 'empty' } end

  if kind == 1 then
    if rest < 4 then return nil end

    local size = buffer.readu32(source, at)
    if rest ~= 4 + size then return nil end

    return { kind = 'string', value = Plugin.lossyUtf8(buffer.readstring(source, at + 4, size)) }
  end

  if kind == 2 then
    return { kind = 'string', value = Plugin.lossyUtf8(buffer.readstring(source, at, rest)) }
  end

  if rest ~= 8 then return nil end

  if kind == 3 then
    return {
      kind = 'formId',
      index = buffer.readu32(source, at),
      contentFile = buffer.readi32(source, at + 4),
    }
  elseif kind == 4 then
    return {
      kind = 'generated',
      low = buffer.readu32(source, at),
      high = buffer.readu32(source, at + 4),
    }
  elseif kind == 5 then
    return {
      kind = 'index',
      recordType = Tags.display(buffer.readu32(source, at)),
      value = buffer.readu32(source, at + 4),
    }
  elseif kind == 6 then
    return {
      kind = 'exteriorCell',
      x = buffer.readi32(source, at),
      y = buffer.readi32(source, at + 4),
    }
  end

  return nil
end

--- A 64-bit value given as two 32-bit halves, in lowercase hex without leading zeros.
local function hex64(high: number, low: number): string
  if high == 0 then return string.format('%x', low) end

  return string.format('%x%08x', high, low)
end

--- OpenMW's `RefId::toString` spelling: the string itself, `#x y` for an exterior cell, hex for
--- numeric ids.
local function refIdText(id: RefId): string
  if id.kind == 'empty' then return '' end

  if id.kind == 'string' then return id.value end

  if id.kind == 'formId' then
    if id.contentFile >= 0 then
      -- index | content_file << 24, in 64 bits: the low byte of the file overlaps the index.
      local low = bit32.bor(id.index, bit32.lshift(bit32.band(id.contentFile, 0xff), 24))
      return '0x' .. hex64(id.contentFile // 256, low)
    end

    -- index | (|content_file + 1|) << 32.
    return '@0x' .. hex64(math.abs(id.contentFile + 1), id.index)
  end

  if id.kind == 'generated' then return '0x' .. hex64(id.high, id.low) end

  if id.kind == 'index' then return `{id.recordType}:0x{string.format('%x', id.value)}` end

  return `#{id.x} {id.y}`
end

--[[ Lua data ]]

export type LuaRef = { index: number, contentFile: number }

--- A Lua value: `kind` says which fields it has. `value` holds a number's, a boolean's, or a
--- string's value; `entries` a table's; `ref` an object's and `refs` an object list's; `typeName` and
--- `data` other userdata's; `values` a vector's, transform's, or color's components.
export type LuaValue = {
  kind: string,
  value: (number | boolean | string)?,
  entries: { { key: LuaValue, value: LuaValue } }?,
  ref: LuaRef?,
  refs: { LuaRef }?,
  typeName: string?,
  data: string?,
  values: { number }?,
}

local FormatVersion = 0
local ShortStringFlag = 0x20
local CustomFullFlag = 0x40
local CustomCompactFlag = 0x80

type Cursor = { b: buffer, p: number, e: number, base: number }

local function need(c: Cursor, n: number): number
  local at = c.p
  if at + n > c.e then fail(at - c.base, 'unexpected end of serialized Lua data') end

  c.p = at + n
  return at
end

local function f64s(c: Cursor, n: number): { number }
  local values = table.create(n, 0)
  for k = 1, n do
    values[k] = buffer.readf64(c.b, need(c, 8))
  end

  return values
end

local function ref(c: Cursor, at: number, length: number, what: string): LuaRef
  if length ~= 8 then fail(at - c.base, what) end

  return { index = buffer.readu32(c.b, at), contentFile = buffer.readi32(c.b, at + 4) }
end

local decodeValue: (c: Cursor) -> LuaValue

local function decodeUserdata(c: Cursor, tag: number): LuaValue
  local compact = bit32.btest(tag, CustomCompactFlag)
  local dataLength: number = if compact
    then bit32.band(bit32.rshift(tag, 3), 15)
    else buffer.readu32(c.b, need(c, 4))
  local nameLength: number = if compact then bit32.band(tag, 7) + 1 else bit32.band(tag, 63) + 1

  local nameAt = need(c, nameLength)
  local typeName = buffer.readstring(c.b, nameAt, nameLength)
  if not utf8.len(typeName) then fail(nameAt - c.base, 'Lua userdata type name is not UTF-8') end

  local dataAt = need(c, dataLength)
  if typeName == 'o' then
    return {
      kind = 'object',
      ref = ref(c, dataAt, dataLength, 'Lua object userdata payload is not 8 bytes'),
    }
  end

  if typeName == 'objlist' then
    if dataLength % 8 ~= 0 then
      fail(dataAt - c.base, 'Lua object-list userdata payload length is not a multiple of 8')
    end

    local refs = {}
    for k = 0, dataLength // 8 - 1 do
      table.insert(refs, ref(c, dataAt + k * 8, 8, ''))
    end

    return { kind = 'objectList', refs = refs }
  end

  return {
    kind = 'userdata',
    typeName = typeName,
    data = buffer.readstring(c.b, dataAt, dataLength),
  }
end

decodeValue = function(c: Cursor): LuaValue
  local tag = buffer.readu8(c.b, need(c, 1))
  if bit32.btest(tag, CustomCompactFlag + CustomFullFlag) then return decodeUserdata(c, tag) end

  if bit32.btest(tag, ShortStringFlag) then
    local length = bit32.band(tag, 0x1f)
    return { kind = 'string', value = buffer.readstring(c.b, need(c, length), length) }
  end

  if tag == 0x0 then return { kind = 'number', value = buffer.readf64(c.b, need(c, 8)) } end

  if tag == 0x1 then
    local length = buffer.readu32(c.b, need(c, 4))
    return { kind = 'string', value = buffer.readstring(c.b, need(c, length), length) }
  end

  if tag == 0x2 then return { kind = 'boolean', value = buffer.readu8(c.b, need(c, 1)) ~= 0 } end

  if tag == 0x3 then
    local entries = {}
    while true do
      if c.p >= c.e then fail(c.p - c.base, 'unexpected end of serialized Lua table') end

      if buffer.readu8(c.b, c.p) == 0x4 then
        c.p += 1
        return { kind = 'table', entries = entries }
      end

      local key = decodeValue(c)
      table.insert(entries, { key = key, value = decodeValue(c) })
    end
  end

  if tag == 0x4 then fail(c.p - 1 - c.base, 'unexpected Lua table end marker') end

  if tag == 0x10 then return { kind = 'vec2', values = f64s(c, 2) } end

  if tag == 0x11 then return { kind = 'vec3', values = f64s(c, 3) } end

  if tag == 0x12 then return { kind = 'transformM', values = f64s(c, 16) } end

  if tag == 0x13 then return { kind = 'transformQ', values = f64s(c, 4) } end

  if tag == 0x14 then return { kind = 'vec4', values = f64s(c, 4) } end

  if tag == 0x15 then
    local values = table.create(4, 0)
    for k = 1, 4 do
      values[k] = buffer.readf32(c.b, need(c, 4))
    end

    return { kind = 'color', values = values }
  end

  return fail(c.p - 1 - c.base, `unknown Lua serialization tag {tag}`)
end

--- A LUAD payload (`length` bytes of `source` at `offset`) decoded; an empty one is Lua nil, as
--- `LuaUtil::deserialize` takes it. Error offsets are relative to the payload.
local function decodeLuaData(source: buffer, offset: number, length: number): LuaValue
  if length == 0 then return { kind = 'nil' } end

  local c: Cursor = { b = source, p = offset, e = offset + length, base = offset }
  local version = buffer.readu8(source, need(c, 1))
  if version ~= FormatVersion then
    fail(0, `unsupported Lua serialization format version {version}`)
  end

  local value = decodeValue(c)
  if c.p ~= c.e then fail(c.p - offset, 'unexpected data after serialized Lua object') end

  return value
end

local VectorTags: { [string]: number } =
  { vec2 = 0x10, vec3 = 0x11, transformM = 0x12, transformQ = 0x13, vec4 = 0x14 }

local function encodeValue(value: LuaValue, out: { string })
  local kind = value.kind
  if kind == 'nil' then
    error('serialized Lua nil can only be represented as an empty LUAD payload', 0)
  elseif kind == 'number' then
    table.insert(out, string.pack('<Bd', 0, value.value :: number))
  elseif kind == 'boolean' then
    table.insert(out, string.pack('<BB', 2, if value.value then 1 else 0))
  elseif kind == 'string' then
    local text = value.value :: string
    if #text <= 31 then
      table.insert(out, string.char(0x20 + #text))
    else
      table.insert(out, string.pack('<BI4', 1, #text))
    end

    table.insert(out, text)
  elseif kind == 'table' then
    table.insert(out, '\3')
    for _, entry in value.entries or {} do
      encodeValue(entry.key, out)
      encodeValue(entry.value, out)
    end

    table.insert(out, '\4')
  elseif kind == 'object' or kind == 'objectList' or kind == 'userdata' then
    local refs: { LuaRef } = value.refs or {}
    if value.ref then refs = { value.ref } end

    local parts: { string } = {}
    for _, r in refs do
      table.insert(parts, string.pack('<I4i4', r.index, r.contentFile))
    end

    local typeName = if kind == 'object'
      then 'o'
      elseif kind == 'objectList' then 'objlist'
      else value.typeName or ''
    local data = if kind == 'userdata' then value.data or '' else table.concat(parts)
    if #typeName == 0 or #typeName > 64 then
      error('serialized Lua userdata type name length must be 1..=64 bytes', 0)
    end

    table.insert(out, string.pack('<BI4', 0x40 + #typeName - 1, #data))
    table.insert(out, typeName)
    table.insert(out, data)
  elseif kind == 'color' then
    table.insert(out, '\21')
    for _, v in value.values or {} do
      table.insert(out, string.pack('<f', v))
    end
  else
    local tag = VectorTags[kind] or error(`unknown Lua value kind '{kind}'`, 0)
    table.insert(out, string.char(tag))
    for _, v in value.values or {} do
      table.insert(out, string.pack('<d', v))
    end
  end
end

--- A value as a LUAD payload: nil as an empty one, anything else after the format byte.
local function encodeLuaData(value: LuaValue): string
  if value.kind == 'nil' then return '' end

  local out = { string.char(FormatVersion) }
  encodeValue(value, out)
  return table.concat(out)
end

--- Every object reference in a Lua value, in order.
local function luaRefs(value: LuaValue, out: { LuaRef }?): { LuaRef }
  local refs = out or {}
  for _, entry in value.entries or {} do
    luaRefs(entry.key, refs)
    luaRefs(entry.value, refs)
  end

  if value.ref then table.insert(refs, value.ref) end

  for _, r in value.refs or {} do
    table.insert(refs, r)
  end

  return refs
end

--[[ The SAVE record ]]

export type SaveTime = { gameHour: number, day: number, month: number, year: number }

export type Profile = {
  formatVersion: number,
  playerName: string,
  playerLevel: number,
  playerClassId: string?,
  playerClassName: string?,
  playerCellName: string,
  inGameTime: SaveTime,
  timePlayed: number,
  description: string,
  dependencies: { string },
  screenshotLength: number,
  currentDay: number?,
  currentHealth: number?,
  maximumHealth: number?,
}

local SAVE = Tags.code 'SAVE'
local SCRN = Tags.code 'SCRN'

--- The SAVE record's index.
local function saveRecord(plugin: Plugin): number
  for i = 0, plugin:count() - 1 do
    if plugin:code(i) == SAVE then return i end
  end

  return fail(0, 'OpenMW save has no SAVE record')
end

local function sized(sub: Plugin.Subrecord, size: number, name: string)
  if sub.size ~= size then fail(sub.payload, `{name} payload is not {size} bytes`) end
end

--- A PLCL RefId: nil for an empty one, the string of a string one.
local function classId(source: buffer, sub: Plugin.Subrecord): string?
  if sub.size == 0 then fail(sub.payload, 'PLCL RefId payload is empty') end

  local kind = buffer.readu8(source, sub.payload)
  if kind == 0 then return nil end

  if kind == 2 then return saveString(source, sub.payload + 1, sub.size - 1) end

  if kind ~= 1 then fail(sub.payload, `PLCL RefId payload is not a string RefId (type {kind})`) end

  local at = sub.payload + 1
  if sub.size - 1 < 4 then fail(at, 'PLCL sized RefId has no length') end

  local size = buffer.readu32(source, at)
  if 4 + size > sub.size - 1 then fail(at, 'PLCL sized RefId string does not fit payload') end

  return saveString(source, at + 4, size)
end

--- The SAVE record's metadata.
local function profile(plugin: Plugin): Profile
  local formatVersion = plugin:formatVersion()
  if formatVersion < MinMetadataFormatVersion then
    fail(
      0,
      `OpenMW save format {formatVersion} stores metadata in an older layout; load and resave in OpenMW first`
    )
  end

  local index = saveRecord(plugin)
  local source = plugin:span(index)
  local found: { [string]: unknown } = {}
  local dependencies: { string } = {}
  for _, sub in plugin:subrecords(index) do
    local tag, at, size = sub.tag, sub.payload, sub.size
    if tag == 'PLNA' then
      found.playerName = saveString(source, at, size)
    elseif tag == 'PLLE' then
      sized(sub, 4, 'PLLE')
      found.playerLevel = buffer.readi32(source, at)
    elseif tag == 'PLCL' then
      found.playerClassId = classId(source, sub)
    elseif tag == 'PLCN' then
      found.playerClassName = saveString(source, at, size)
    elseif tag == 'PLCE' then
      found.playerCellName = saveString(source, at, size)
    elseif tag == 'TSTM' then
      sized(sub, 16, 'TSTM')
      found.inGameTime = {
        gameHour = buffer.readf32(source, at),
        day = buffer.readi32(source, at + 4),
        month = buffer.readi32(source, at + 8),
        year = buffer.readi32(source, at + 12),
      }
    elseif tag == 'TIME' then
      sized(sub, 8, 'TIME')
      found.timePlayed = buffer.readf64(source, at)
    elseif tag == 'DESC' then
      found.description = saveString(source, at, size)
    elseif tag == 'DEPE' then
      table.insert(dependencies, saveString(source, at, size))
    elseif tag == 'SCRN' then
      found.screenshotLength = size
    elseif tag == 'CDAY' then
      sized(sub, 4, 'CDAY')
      found.currentDay = buffer.readi32(source, at)
    elseif tag == 'CHLT' then
      sized(sub, 4, 'CHLT')
      found.currentHealth = buffer.readf32(source, at)
    elseif tag == 'MHLT' then
      sized(sub, 4, 'MHLT')
      found.maximumHealth = buffer.readf32(source, at)
    end
  end

  local start = plugin:range(index)
  local function required(key: string, tag: string): unknown
    local value = found[key]
    if value == nil then fail(start, `SAVE has no {tag} subrecord`) end

    return value
  end

  return {
    formatVersion = formatVersion,
    playerName = required('playerName', 'PLNA') :: string,
    playerLevel = required('playerLevel', 'PLLE') :: number,
    playerClassId = found.playerClassId :: string?,
    playerClassName = found.playerClassName :: string?,
    playerCellName = required('playerCellName', 'PLCE') :: string,
    inGameTime = required('inGameTime', 'TSTM') :: SaveTime,
    timePlayed = required('timePlayed', 'TIME') :: number,
    description = required('description', 'DESC') :: string,
    dependencies = dependencies,
    screenshotLength = required('screenshotLength', 'SCRN') :: number,
    currentDay = found.currentDay :: number?,
    currentHealth = found.currentHealth :: number?,
    maximumHealth = found.maximumHealth :: number?,
  }
end

--- The screenshot's bytes (a JPEG), from SAVE's SCRN.
local function screenshot(plugin: Plugin): buffer
  local index = saveRecord(plugin)
  local source, at, size = plugin:findSubrecord(index, SCRN)
  if not source then fail(plugin:range(index), 'SAVE has no SCRN subrecord') end

  local out = buffer.create(size)
  buffer.copy(out, 0, source :: buffer, at, size)
  return out
end

return table.freeze {
  CurrentFormatVersion = CurrentFormatVersion,
  FormatHistory = FormatHistory,
  MinEngineSupportedFormatVersion = MinEngineSupportedFormatVersion,
  MinMetadataFormatVersion = MinMetadataFormatVersion,
  MinMutationFormatVersion = MinMutationFormatVersion,
  compatibility = compatibility,
  decodeLuaData = decodeLuaData,
  decodeRefId = decodeRefId,
  encodeLuaData = encodeLuaData,
  luaRefs = luaRefs,
  profile = profile,
  refIdText = refIdText,
  saveString = saveString,
  screenshot = screenshot,
}
