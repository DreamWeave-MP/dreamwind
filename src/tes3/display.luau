--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Readable record values (jess-omwaddon's `display`, what `jess plugin dump` prints and
`record:display()` gives): a decoded record reshaped for reading. Pairs get field names, NPC
attributes and skills get names, empty and unset fields go, the NUL terminators free text keeps
are trimmed, mwscript bytecode collapses to its size and its variables to their names, terrain
arrays collapse to their sizes, and LUAD payloads decode to Lua values. Field names are camelCase.
Non-finite floats, which JSON can't hold, are missing.
]]

local Decode = require './decode'
local Plugin = require './plugin'
local Records = require './records'
local Save = require './save'
local Tags = require './tags'
local Text = require './text'

type Plugin = Plugin.Plugin
type Value = Decode.Value
type LuaValue = Save.LuaValue
type LuaRef = Save.LuaRef

local FltMax = 3.4028234663852886e38

local Attributes = {
  'strength',
  'intelligence',
  'willpower',
  'agility',
  'speed',
  'endurance',
  'personality',
  'luck',
}

local Skills = {
  'block',
  'armorer',
  'mediumArmor',
  'heavyArmor',
  'bluntWeapon',
  'longBlade',
  'axe',
  'spear',
  'athletics',
  'enchant',
  'destruction',
  'alteration',
  'illusion',
  'conjuration',
  'mysticism',
  'restoration',
  'alchemy',
  'unarmored',
  'security',
  'sneak',
  'acrobatics',
  'lightArmor',
  'shortBlade',
  'marksman',
  'mercantile',
  'speechcraft',
  'handToHand',
}

--- Pair lists by field: the names each pair's two halves get, and whether the second comes first.
local Pairs: { [string]: { string } } = {
  masters = { 'name', 'size' },
  inventory = { 'count', 'id' },
  items = { 'id', 'level' },
  creatures = { 'id', 'level' },
  sounds = { 'id', 'chance' },
}

local function isList(value: { [unknown]: unknown }): boolean
  return value[1] ~= nil or next(value) == nil
end

local function unsetFloat(value: unknown): boolean
  return type(value) == 'number' and value >= FltMax
end

--- Whether a value is noise: missing, empty, or the engine's FLT_MAX "unset".
local function emptyOrUnset(value: unknown): boolean
  if value == nil then return true end

  if type(value) == 'string' then return value == '' end

  if type(value) == 'table' then
    local t = value :: { [unknown]: unknown }
    if next(t) == nil then return true end

    if t[1] == nil then return false end

    for _, item in t :: { unknown } do
      if not unsetFloat(item) then return false end
    end

    return true
  end

  return unsetFloat(value)
end

local tidy: (value: unknown) -> unknown

local function tidyField(key: string, value: unknown): unknown
  if type(value) ~= 'table' or not isList(value :: { [unknown]: unknown }) then return value end

  local items = value :: { unknown }
  local names = Pairs[key]
  if names then
    for _, item in items do
      if type(item) ~= 'table' or #(item :: { unknown }) ~= 2 then return items end
    end

    local out = table.create(#items)
    for i, item in items do
      local pair = item :: { unknown }
      out[i] = { [names[1]] = pair[1], [names[2]] = pair[2] }
    end

    return out
  end

  local named = if key == 'attributes' and #items == 8
    then Attributes
    elseif key == 'skills' and #items == 27 then Skills
    else nil
  if not named then return items end

  local out: { [string]: unknown } = {}
  for i, name in named do
    out[name] = items[i]
  end

  return out
end

--- Names pairs and stat arrays, drops empty or unset fields, trims trailing NULs, and turns a
--- non-finite number (JSON's null) into nil. Tables are reshaped in place: `value` is the caller's
--- to give up (a freshly decoded record), and copying every table of it again was most of a dump.
tidy = function(value: unknown): unknown
  if type(value) == 'string' then
    if string.byte(value, -1) ~= 0 then return value end

    return (string.gsub(value, '%z+$', ''))
  end

  if type(value) == 'number' then
    if value ~= value or value == math.huge or value == -math.huge then return nil end

    return value
  end

  if type(value) ~= 'table' then return value end

  local t = value :: { [unknown]: unknown }
  if isList(t) then
    local items = t :: { unknown }
    for i = 1, #items do
      items[i] = tidy(items[i])
    end

    return items
  end

  for key, field in t do
    local tidied = tidyField(key :: string, tidy(field))
    t[key] = if emptyOrUnset(tidied) then nil else tidied
  end

  return t
end

--[[ Lua values ]]

local function luaNumber(value: number): number?
  if value ~= value or value == math.huge or value == -math.huge then return nil end

  return value
end

--- A number as serde_json writes a key: an exact integer without a fraction, else ryu's digits.
local function numberKey(value: number): string
  if value % 1 == 0 and math.abs(value) <= 2 ^ 53 then return string.format('%d', value) end

  for precision = 1, 17 do
    local text = string.format(`%.{precision}g`, value)
    if tonumber(text) == value then return text end
  end

  return tostring(value)
end

local function lossy(text: string): string return Plugin.lossyUtf8(text) end

local luaValue: (value: LuaValue, keepKeys: boolean?) -> unknown

local function refnum(ref: LuaRef, keepKeys: boolean?): { [string]: number }
  if keepKeys then return { index = ref.index, content_file = ref.contentFile } end

  return { index = ref.index, contentFile = ref.contentFile }
end

local Vectors: { [string]: string } = {
  vec2 = 'vec2',
  vec3 = 'vec3',
  vec4 = 'vec4',
  transformM = 'matrix',
  transformQ = 'quat',
  color = 'color',
}

--- A decoded Lua value: tables keyed 1 to n become lists, other tables objects with text keys
--- (camelCase unless `keepKeys`, as a save's dump keeps them), and userdata a one-key table naming
--- its type.
luaValue = function(value: LuaValue, keepKeys: boolean?): unknown
  local kind = value.kind
  if kind == 'nil' then return nil end

  if kind == 'number' then return luaNumber(value.value :: number) end

  if kind == 'boolean' then return value.value end

  if kind == 'string' then return lossy(value.value :: string) end

  if kind == 'table' then
    local entries = value.entries or {}
    local list = #entries > 0
    for position, entry in entries do
      if entry.key.kind ~= 'number' or entry.key.value ~= position then
        list = false
        break
      end
    end

    if list then
      local out = table.create(#entries)
      for i, entry in entries do
        out[i] = luaValue(entry.value, keepKeys)
      end

      return out
    end

    local out: { [string]: unknown } = {}
    for _, entry in entries do
      local key = entry.key
      local text = if key.kind == 'string'
        then lossy(key.value :: string)
        elseif key.kind == 'number' then numberKey(key.value :: number)
        elseif key.kind == 'boolean' then tostring(key.value)
        else key.kind
      out[if keepKeys then text else Text.camelCase(text)] = luaValue(entry.value, keepKeys)
    end

    return out
  end

  if kind == 'object' then return { object = refnum(value.ref :: LuaRef, keepKeys) } end

  if kind == 'objectList' then
    local out = {}
    for _, ref in value.refs or {} do
      table.insert(out, refnum(ref, keepKeys))
    end

    return { objlist = out }
  end

  if kind == 'userdata' then
    local name = value.typeName :: string
    return { [if keepKeys then name else Text.camelCase(name)] = `{#(value.data or '')} bytes` }
  end

  local out = {}
  for i, v in value.values or {} do
    out[i] = luaNumber(v)
  end

  return { [Vectors[kind]] = out }
end

--- A LUAD payload decoded for display, or its size and why it doesn't decode.
local function luaPayload(
  source: buffer,
  offset: number,
  length: number,
  keepKeys: boolean?
): unknown
  -- decodeLuaData throws on a payload that doesn't decode; that's what's shown instead.
  local ok, value = pcall(Save.decodeLuaData, source, offset, length)
  if ok then return luaValue(value :: LuaValue, keepKeys) end

  return `{length} bytes, undecodable: {value}`
end

--[[ Records ]]

local SCVR, SCDT = Tags.code 'SCVR', Tags.code 'SCDT'

--- mwscript's NUL-separated variable names, grouped into shorts, longs, and floats when the
--- header's counts add up, else as a list; nil when there are none.
local function scriptVariables(plugin: Plugin, index: number, counts: { number }): unknown
  local source, at, size = plugin:findSubrecord(index, SCVR)
  if not source then return nil end

  local names = {}
  local text = buffer.readstring(source :: buffer, at, size)
  for name in string.gmatch(text, '[^%z]+') do
    table.insert(names, Text.decodeString(name, plugin.encoding))
  end

  if #names == 0 then return nil end

  if counts[1] + counts[2] + counts[3] ~= #names then return names end

  local grouped: { [string]: { string } } = {}
  local first = 1
  for i, kind in { 'shorts', 'longs', 'floats' } do
    local group = table.move(names, first, first + counts[i] - 1, 1, {})
    first += counts[i]
    if #group > 0 then grouped[kind] = group end
  end

  return grouped
end

local LandBlobs = {
  { field = 'vertexNormals', tag = 'VNML', size = 12675 },
  { field = 'vertexHeights', tag = 'VHGT', size = 4225 },
  { field = 'worldMapData', tag = 'WNAM', size = 81 },
  { field = 'vertexColors', tag = 'VCLR', size = 12675 },
  { field = 'textureIndices', tag = 'VTEX', size = 512 },
}

--- The LUAD payloads of a LUAL record, in order, keyed by what they belong to: the script config
--- (by position) and its `initData`, `records[k].data`, or `instances[k].data`.
local function lualPayloads(plugin: Plugin, index: number): { [string]: { number } }
  local out: { [string]: { number } } = {}
  local script, records, instances = 0, 0, 0
  local last = ''
  for _, sub in plugin:subrecords(index) do
    if sub.tag == 'LUAS' then
      script += 1
      records, instances = 0, 0
    elseif sub.tag == 'LUAR' then
      records += 1
    elseif sub.tag == 'LUAI' then
      instances += 1
    elseif sub.tag == 'LUAD' then
      local key = if last == 'LUAF'
        then `{script}.initData`
        elseif last == 'LUAR' then `{script}.records.{records}`
        elseif last == 'LUAI' then `{script}.instances.{instances}`
        else nil
      if key then out[key] = { sub.payload, sub.size } end
    end

    last = sub.tag
  end

  return out
end

--- A decoded record's readable value, numbered `index`.
local function recordValue(plugin: Plugin, index: number, decoded: Value): { [string]: unknown }
  -- Read before tidying, which reshapes `decoded` in place.
  local kind = decoded.type
  local header = decoded.header :: { [string]: number }?
  local fields = tidy(decoded) :: { [string]: unknown }
  if kind == 'Script' and header then
    fields.header = nil
    fields.variables =
      scriptVariables(plugin, index, { header.numShorts, header.numLongs, header.numFloats })
    local _, _, size = plugin:findSubrecord(index, SCDT)
    fields.bytecode = `{size} bytes`
  elseif kind == 'Landscape' then
    for _, blob in LandBlobs do
      local present = plugin:findSubrecord(index, Tags.code(blob.tag)) ~= nil
      local part = fields[blob.field] :: { [string]: unknown }?
      if not present then
        fields[blob.field] = nil
      elseif part then
        part.data = `{blob.size} bytes`
      end
    end
  elseif kind == 'ScriptConfigList' then
    local payloads = lualPayloads(plugin, index)
    local source = plugin:span(index)
    local function payload(key: string): unknown
      local span = payloads[key]
      if not span or span[2] == 0 then return nil end

      return luaPayload(source, span[1], span[2])
    end

    for s, script in (fields.scripts :: { { [string]: unknown } }?) or {} do
      script.initData = payload(`{s}.initData`)
      for k, record in (script.records :: { { [string]: unknown } }?) or {} do
        record.data = payload(`{s}.records.{k}`)
      end

      for k, instance in (script.instances :: { { [string]: unknown } }?) or {} do
        instance.data = payload(`{s}.instances.{k}`)
      end
    end
  end

  fields.record = index
  return fields
end

--- Record `index`'s readable value; one the typed model can't decode shows its id, why, and its
--- subrecords' tags and sizes. `references` (0-based) keeps only those CELL references.
local function display(
  plugin: Plugin,
  index: number,
  references: { number }?
): { [string]: unknown }
  local ok, decoded = pcall(plugin.decode, plugin, index)
  if ok and decoded then
    local value = decoded :: Value
    if references and value.type == 'Cell' then
      local keep: { [number]: boolean } = {}
      local groups = plugin:cellGroups(index)
      local subs = plugin:subrecords(index)
      local source = plugin:span(index)
      for _, ref in references do
        local group = groups and groups.references[ref + 1]
        if not group then continue end

        for k = group[1] + 1, group[2] + 1 do
          if subs[k].tag == 'FRMR' and subs[k].size == 4 then
            local packed = buffer.readu32(source, subs[k].payload)
            keep[packed] = true
            break
          end
        end
      end

      local kept = {}
      for _, ref in value.references :: { Value } do
        local packed = (ref.mastIndex :: number) * 16777216 + (ref.refrIndex :: number)
        if keep[packed] then table.insert(kept, ref) end
      end

      value.references = kept
    end

    return recordValue(plugin, index, value)
  end

  local subrecords = {}
  for _, sub in plugin:subrecords(index) do
    table.insert(subrecords, `{Tags.display(sub.code)} ({sub.size} bytes)`)
  end

  local id = Records.id(plugin, index)
  return tidy {
    record = index,
    type = Tags.display(plugin:code(index)),
    id = if id ~= '' then id else nil,
    undecoded = if ok then 'unknown record type' else tostring(decoded),
    subrecords = subrecords,
  } :: { [string]: unknown }
end

return table.freeze {
  display = display,
  luaPayload = luaPayload,
  luaValue = luaValue,
  recordValue = recordValue,
  tidy = tidy,
}
