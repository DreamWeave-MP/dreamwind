--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Readable values for a save's records (jess-save's `SaveValues`, what `jess save dump` prints).
The SAVE header and dynamic records (player-made spells, the player's NPC_, ...) decode to typed
values. Save-only records (PLAY, CSTA, JOUR, ...) have no typed model, so each subrecord gets its
best-known decoding: ids and object references the classifiers understand, LUAD Lua data (its
keys as they are), strings, and numbers, with hex or a byte count for the rest.
]]

local Read = require './read'
local Records = require './records'
local Scan = require './scan'
local tes3 = require '@dreamwind/tes3'

type Plugin = tes3.Plugin
type Record = Records.Record
type Save = Read.Save

--- Record types OpenMW writes as dynamic records with the regular content-record layout.
local DynamicTagList = {
  'ALCH',
  'ARMO',
  'BOOK',
  'CLAS',
  'CLOT',
  'ENCH',
  'NPC_',
  'MISC',
  'ACTI',
  'SPEL',
  'WEAP',
  'LEVC',
  'LEVI',
  'CREA',
  'CONT',
  'LIGH',
  'STAT',
  'DOOR',
  'PROB',
  'INGR',
}

local DynamicTags: { [string]: boolean } = {}
for _, tag in DynamicTagList do
  DynamicTags[tag] = true
end

--- Whether every byte is printable text (or a tab or line break); a trailing NUL is left out.
local function printable(data: string): string?
  if string.sub(data, -1) == '\0' then data = string.sub(data, 1, -2) end

  if data == '' then return nil end

  for i = 1, #data do
    local byte = string.byte(data, i)
    if
      not ((byte >= 0x20 and byte < 0x7f) or byte >= 0xa0 or byte == 9 or byte == 10 or byte == 13)
    then
      return nil
    end
  end

  return tes3.lossyUtf8(data)
end

--- A typed RefId spelled as OpenMW spells it (`#-2 -9` for an exterior cell); string ids must be
--- printable, since this also guesses whether an unknown subrecord holds one.
local function typedRefIdText(data: string): string?
  local source = buffer.fromstring(data)
  local id = tes3.save.decodeRefId(source, 0, #data)
  if not id or id.kind == 'empty' then return nil end

  if id.kind == 'string' then return printable(id.value) end

  return tes3.save.refIdText(id)
end

local function floatValue(value: number): number?
  if value ~= value or value == math.huge or value == -math.huge then return nil end

  return value
end

--- Four bytes are usually an i32 count or flag, or an f32; a float's bit pattern reads as a huge int.
local function fourByteNumber(data: string): number?
  local int = Records.i32At(data)
  if math.abs(int) < 1000000 then return int end

  local float = Records.f32At(data)
  if float == float and math.abs(float) >= 1e-4 and math.abs(float) < 1e8 then
    return floatValue(float)
  end

  return int
end

--- Best-effort decoding of a subrecord no classifier knows.
local function genericValue(data: string): unknown
  local text = typedRefIdText(data) or printable(data)
  if text then return text end

  if #data == 4 then return fourByteNumber(data) end

  if #data <= 16 then
    local hex = {}
    for i = 1, #data do
      hex[i] = string.format('%02x', string.byte(data, i))
    end

    return `hex {table.concat(hex, ' ')}`
  end

  return `{#data} bytes`
end

--- A placement (CellRef DATA, object POS_, door DODT): three position then three rotation f32s.
local function placement(data: string): unknown
  if #data ~= 24 then return nil end

  local values = {}
  for i = 0, 5 do
    values[i + 1] = Records.f32At(data, 1 + i * 4)
  end

  return {
    position = { floatValue(values[1]), floatValue(values[2]), floatValue(values[3]) },
    rotation = { floatValue(values[4]), floatValue(values[5]), floatValue(values[6]) },
  }
end

--- EQIP: a u32 count, then (u32 inventory item index, u32 equipment slot) pairs.
local function equipment(data: string): unknown
  if #data < 4 then return nil end

  local count = Records.u32At(data)
  if #data - 4 ~= count * 8 then return nil end

  local out = {}
  for i = 0, count - 1 do
    local item, slot = Records.u32At(data, 5 + i * 8), Records.u32At(data, 9 + i * 8)
    table.insert(out, `item {item} in slot {slot}`)
  end

  return out
end

--- NPCO: an i32 count followed by the item id.
local function inventoryEntry(data: string): string?
  if #data < 4 then return nil end

  local count = Records.i32At(data)
  local id = string.sub(data, 5)
  local text = typedRefIdText(id)
  if not text then
    local nul = string.find(id, '\0', 1, true)
    text = printable(if nul then string.sub(id, 1, nul - 1) else id)
  end

  if not text then return nil end

  return `{count} x {text}`
end

local function referenceValue(
  localIndex: number,
  contentFile: number,
  contentFiles: { string }
): string
  local source = contentFiles[contentFile + 1]
  if not source then
    source = if contentFile < 0 then 'generated' else `content file {contentFile}`
  end

  return `{localIndex} ({source})`
end

--- Save records store ids as typed RefIds; typed record decoders read them as plain strings.
local function cleanRefIds(value: unknown): unknown
  if type(value) == 'string' then
    local first = string.byte(value, 1)
    if first == 2 then return string.sub(value, 2) end

    if first == 4 then return '<generated id>' end

    return value
  end

  if type(value) == 'table' then
    local out = {}
    for key, item in value :: { [unknown]: unknown } do
      out[key] = cleanRefIds(item)
    end

    return out
  end

  return value
end

--- The text of a string RefId (type 1 or 2); nil for anything else.
local function plainRefId(data: string): string?
  local kind = string.byte(data, 1)
  if kind ~= 1 and kind ~= 2 then return nil end

  return typedRefIdText(data)
end

local function fixedName(name: string): string?
  if #name > 32 then return nil end

  return name .. string.rep('\0', 32 - #name)
end

--- A save record rewritten into the plugin layout the typed decoders read: typed RefIds become
--- plain strings, and NPCO items and NPCS spells become fixed 32-byte names.
local function pluginLayout(plugin: Plugin, index: number, r: Record): string?
  local parts = {}
  for k = 0, #r.subs - 1 do
    local tag = Records.tagAt(r, k) :: string
    local data = Records.payload(r, k)
    if tag == 'NPCO' then
      if #data < 4 then return nil end

      local id = plainRefId(string.sub(data, 5))
      local name = id and fixedName(id)
      if not name then return nil end

      data = string.sub(data, 1, 4) .. name
    elseif tag == 'NPCS' then
      local id = plainRefId(data)
      local name = id and fixedName(id)
      if not name then return nil end

      data = name
    else
      data = plainRefId(data) or data
    end

    table.insert(parts, tag .. string.pack('<I4', #data) .. data)
  end

  local payload = table.concat(parts)
  local source, start = plugin:span(index)
  local header = buffer.readstring(source, start, 16)
  return string.sub(header, 1, 4)
    .. string.pack('<I4', #payload)
    .. string.sub(header, 9, 16)
    .. payload
end

local function typedContentValue(plugin: Plugin, index: number, r: Record): unknown
  local bytes = pluginLayout(plugin, index, r)
  if not bytes then return nil end

  -- tes3.open throws on bytes that don't frame, and decode on a record that doesn't decode; either
  -- way the record is shown subrecord by subrecord instead.
  local ok, value = pcall(function(): unknown
    local single = tes3.open(bytes :: string, { encoding = plugin.encoding })
    local decoded = single:decode(0)
    if not decoded then return nil end

    local shown = tes3.display.recordValue(single, 0, decoded)
    shown.record = index
    return cleanRefIds(shown)
  end)
  return if ok then value else nil
end

local function isObjectState(r: Record): boolean return r.tag == 'CSTA' or r.tag == 'PLAY' end

type Indexes = { contentFiles: { string }, luaScripts: { string } }

local function subrecordsValue(r: Record, indexes: Indexes): unknown
  local subrecords = {}
  local inventoryItemsRemaining = 0
  for k = 0, #r.subs - 1 do
    local tag = Records.tagAt(r, k) :: string
    local data = Records.payload(r, k)
    if tag == 'ICNT' then inventoryItemsRemaining = Records.inventoryCount(data) end

    local meaning = Scan.refIdField(r, k, inventoryItemsRemaining)
    if meaning == 'inventory_item_base_object' then
      inventoryItemsRemaining = math.max(inventoryItemsRemaining - 1, 0)
    end

    local value: unknown = nil
    local s = r.subs[k + 1]
    if tag == 'LUAD' then
      value = tes3.display.luaPayload(r.source, s.payload, s.size, true)
    elseif tag == 'LUAS' and #data == 4 then
      local id = Records.i32At(data)
      local path = if id >= 0 then indexes.luaScripts[id + 1] else nil
      value = if path then `{id} ({path})` else tostring(id)
    end

    if value == nil and isObjectState(r) and (tag == 'DATA' or tag == 'POS_' or tag == 'DODT') then
      value = placement(data)
    end

    if value == nil and tag == 'EQIP' then value = equipment(data) end

    -- Dynamic records store inventory as a count plus a typed RefId.
    if value == nil and tag == 'NPCO' then value = inventoryEntry(data) end

    if value == nil and Scan.formIdField(r, k) then
      local localIndex, contentFile = Records.wideFormId(data)
      if localIndex then value = referenceValue(localIndex, contentFile, indexes.contentFiles) end
    end

    if value == nil and meaning then value = Records.refId(data) end

    if value == nil then value = genericValue(data) end

    table.insert(subrecords, { [tag] = value })
  end

  return { record = r.index, type = r.tag, subrecords = subrecords }
end

--- Every record's readable value, as `jess save dump` shows it: OpenMW saves give typed values for
--- the SAVE header and dynamic records and a subrecord list otherwise; Morrowind saves give the
--- header's metadata, then typed values for the record types jess models.
local function values(save: Save): { unknown }
  local plugin = save.plugin
  local headerTag = if save.game == 'openmw' then 'SAVE' else 'TES3'
  -- info throws on metadata that doesn't read; the header record is then shown like any other.
  local unnamed: Save = { plugin = plugin, game = save.game, name = '' }
  local ok, header = pcall(Read.info, unnamed)
  local indexes: Indexes = { contentFiles = {}, luaScripts = {} }
  if save.game == 'openmw' then
    -- masters throws on a header that doesn't read; then no content file has a name.
    local read, masters = pcall(plugin.masters, plugin)
    if read then
      for _, master in masters :: { tes3.Master } do
        table.insert(indexes.contentFiles, master.name)
      end
    end
  end

  local records = Records.all(plugin)
  if save.game == 'openmw' then
    for _, r in records do
      if r.tag ~= 'LUAM' then continue end

      for k = 0, #r.subs - 1 do
        if Records.tagAt(r, k) ~= 'LUAP' then continue end

        local data = Records.payload(r, k)
        if string.sub(data, -1) == '\0' then data = string.sub(data, 1, -2) end

        table.insert(indexes.luaScripts, tes3.lossyUtf8(data))
      end
    end
  end

  local out = table.create(#records)
  for i, r in records do
    local index = i - 1
    if r.tag == headerTag and ok then
      local value = table.clone(header :: { [string]: unknown })
      value.record = index
      value.type = 'SaveHeader'
      out[i] = value
      continue
    end

    if save.game == 'morrowind' then
      out[i] = tes3.display.display(plugin, index)
      continue
    end

    if DynamicTags[r.tag] or r.tag == 'GLOB' then
      local typed = typedContentValue(plugin, index, r)
      if typed then
        out[i] = typed
        continue
      end
    end

    out[i] = subrecordsValue(r, indexes)
  end

  return out
end

return table.freeze { values = values }
