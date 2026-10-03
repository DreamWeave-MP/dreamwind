--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Comparing plugins (jess-omwaddon's `compare`, tes3cmd's `common`, `diff`, and `overdial`): byte
comparisons, records in common, record-level diffs with typed field changes, overlapping dialogue
topics, and the records a load order overrides.
]]

local tes3 = require '@dreamwind/tes3'

type Plugin = tes3.Plugin

export type Key = { type: string, id: string }

export type ByteComparison = {
  identical: boolean,
  leftBytes: number,
  rightBytes: number,
  --- The first offset where they differ: the shorter one's length when one is a prefix.
  firstDifference: number?,
}

--- Whether two byte strings are the same, and where they first differ.
local function compareBytes(left: buffer, right: buffer): ByteComparison
  local a, b = buffer.len(left), buffer.len(right)
  local n = math.min(a, b)
  local first: number? = nil
  local i = 0
  while i + 8 <= n do
    if
      buffer.readu32(left, i) ~= buffer.readu32(right, i)
      or buffer.readu32(left, i + 4) ~= buffer.readu32(right, i + 4)
    then
      break
    end

    i += 8
  end

  while i < n do
    if buffer.readu8(left, i) ~= buffer.readu8(right, i) then
      first = i
      break
    end

    i += 1
  end

  if not first and a ~= b then first = n end

  return { identical = first == nil, leftBytes = a, rightBytes = b, firstDifference = first }
end

local function keyOf(tag: string, id: string): string return tag .. '\0' .. id end

local function sortKeys(keys: { Key })
  table.sort(keys, function(x: Key, y: Key)
    if x.type ~= y.type then return x.type < y.type end

    return x.id < y.id
  end)
end

--- The records both plugins have, by type and id, without their TES3 headers; sorted.
local function common(left: Plugin, right: Plugin): { Key }
  local inLeft: { [string]: boolean } = {}
  for _, key in tes3.records.objectKeys(left) do
    inLeft[keyOf(key.type, key.id)] = true
  end

  local out = {}
  for _, key in tes3.records.objectKeys(right) do
    if key.type ~= 'TES3' and inLeft[keyOf(key.type, key.id)] then table.insert(out, key) end
  end

  return out
end

--- Every identified record's bytes by key (the last copy of a repeated key), skipping `ignored`.
local function objectMap(
  plugin: Plugin,
  ignored: { [string]: boolean }
): ({ [string]: string }, { [string]: Key })
  local bytes: { [string]: string } = {}
  local keys: { [string]: Key } = {}
  for i = 0, plugin:count() - 1 do
    local tag = tes3.tags.display(plugin:code(i))
    if ignored[tag] then continue end

    local id = tes3.records.id(plugin, i)
    if not id then continue end

    local key = keyOf(tag, id)
    bytes[key] = buffer.tostring(plugin:bytes(i))
    keys[key] = { type = tag, id = id }
  end

  return bytes, keys
end

export type FieldChange = { field: string, left: string, right: string }
export type ChangedRecord =
  { type: string, id: string, rawChanged: boolean, fields: { FieldChange } }
export type DiffReport = {
  leftOnly: { Key },
  rightOnly: { Key },
  equal: { Key }?,
  changed: { ChangedRecord },
}

--- A record's typed string fields as `name[subrecord]` to value.
local function fieldMap(plugin: Plugin, key: Key): { [string]: string }
  local fields: { [string]: string } = {}
  local index = tes3.records.find(plugin, key.type, key.id)
  if not index or not tes3.typeName(plugin:tag(index)) then return fields end

  for _, field in tes3.records.stringFields(plugin, index) do
    fields[`{field.name}[{field.subrecord}]`] = field.value
  end

  return fields
end

--- The typed string fields that differ between `key`'s record in each plugin; fields on only one
--- side aren't reported. Sorted by field.
local function fieldChanges(left: Plugin, right: Plugin, key: Key): { FieldChange }
  local a, b = fieldMap(left, key), fieldMap(right, key)
  local names = {}
  for name, value in a do
    if b[name] ~= nil and b[name] ~= value then table.insert(names, name) end
  end

  table.sort(names)
  local out = {}
  for _, name in names do
    table.insert(out, { field = name, left = a[name], right = b[name] })
  end

  return out
end

--- Two plugins' identified records compared by type, id, and bytes, skipping the `ignore` types
--- (tags or type names); `equal` also lists the identical ones.
local function diff(left: Plugin, right: Plugin, ignore: { string }?, equal: boolean?): DiffReport
  local ignored: { [string]: boolean } = {}
  for _, value in ignore or {} do
    local tag = string.lower(value) == 'npc' and 'NPC_'
      or tes3.tagNamed(value)
      or string.upper(value)
    ignored[tag] = true
  end

  local leftBytes, leftKeys = objectMap(left, ignored)
  local rightBytes, rightKeys = objectMap(right, ignored)
  local report: DiffReport = { leftOnly = {}, rightOnly = {}, changed = {} }
  local same = {}
  local changedKeys = {}
  for key, bytes in leftBytes do
    local other = rightBytes[key]
    if other == nil then
      table.insert(report.leftOnly, leftKeys[key])
    elseif other == bytes then
      table.insert(same, leftKeys[key])
    else
      table.insert(changedKeys, leftKeys[key])
    end
  end

  for key in rightBytes do
    if leftBytes[key] == nil then table.insert(report.rightOnly, rightKeys[key]) end
  end

  sortKeys(report.leftOnly)
  sortKeys(report.rightOnly)
  sortKeys(same)
  sortKeys(changedKeys)
  for _, key in changedKeys do
    table.insert(
      report.changed,
      { type = key.type, id = key.id, rawChanged = true, fields = fieldChanges(left, right, key) }
    )
  end

  if equal then report.equal = same end

  return report
end

export type TopicOverlap = {
  earlierPlugin: string,
  laterPlugin: string,
  outerTopic: string,
  innerTopic: string,
}

--- Topics in one plugin that contain a different topic from a later plugin, ignoring case. With
--- `single`, only the first plugin's topics are compared with the rest. `plugins` is a list of
--- `{ name, topics }`.
local function overlaps(
  plugins: { { name: string, topics: { string } } },
  single: boolean?
): { TopicOverlap }
  local out = {}
  local earlier = if single then math.min(#plugins, 1) else #plugins
  for l = 1, earlier do
    for r = l + 1, #plugins do
      local left, right = plugins[l], plugins[r]
      for _, leftTopic in left.topics do
        local leftLower = string.lower(leftTopic)
        for _, rightTopic in right.topics do
          local rightLower = string.lower(rightTopic)
          if leftLower == rightLower then continue end

          local outer, inner
          if string.find(leftLower, rightLower, 1, true) then
            outer, inner = leftTopic, rightTopic
          elseif not single and string.find(rightLower, leftLower, 1, true) then
            outer, inner = rightTopic, leftTopic
          else
            continue
          end

          table.insert(out, {
            earlierPlugin = left.name,
            laterPlugin = right.name,
            outerTopic = outer,
            innerTopic = inner,
          })
        end
      end
    end
  end

  return out
end

export type Override = {
  type: string,
  id: string,
  --- Every plugin that defines the record, by position (1-based), first to last.
  plugins: { number },
  --- Copies byte for byte the same as an earlier plugin's.
  identical: { { plugin: number, sameAs: number } },
  --- Plugins whose changes the last copy throws away.
  overridden: { number },
}

--- The records several of `plugins` (a load order, first to last) define that are worth a look:
--- copies unchanged from an earlier plugin, and plugins whose changes a later copy drops. Records
--- match by type and id ignoring ASCII case; records without an id, TES3 headers, and the
--- `ignore` types are skipped. A plugin defining a record twice counts once, with its last copy.
local function overrides(plugins: { Plugin }, ignore: { string }?): { Override }
  local ignored: { [string]: boolean } = {}
  for _, value in ignore or {} do
    ignored[string.lower(value) == 'npc' and 'NPC_' or tes3.tagNamed(value) or string.upper(value)] =
      true
  end

  local slots: { [string]: number } = {}
  local records: { { key: Key, copies: { { plugin: number, bytes: string } } } } = {}
  for position, plugin in plugins do
    for i = 0, plugin:count() - 1 do
      local tag = tes3.tags.display(plugin:code(i))
      if tag == 'TES3' or ignored[tag] then continue end

      local id = tes3.records.id(plugin, i)
      if not id then continue end

      local bytes = buffer.tostring(plugin:bytes(i))
      local lookup = tag .. '\0' .. string.lower(id)
      local slot = slots[lookup]
      if not slot then
        table.insert(
          records,
          { key = { type = tag, id = id }, copies = { { plugin = position, bytes = bytes } } }
        )
        slots[lookup] = #records
        continue
      end

      local copies = records[slot].copies
      local last = copies[#copies]
      if last.plugin == position then
        last.bytes = bytes
      else
        table.insert(copies, { plugin = position, bytes = bytes })
      end
    end
  end

  local out = {}
  for _, record in records do
    local copies = record.copies
    if #copies < 2 then continue end

    local identical = {}
    for index, copy in copies do
      for k = 1, index - 1 do
        if copies[k].bytes == copy.bytes then
          table.insert(identical, { plugin = copy.plugin, sameAs = copies[k].plugin })
          break
        end
      end
    end

    local winner = copies[#copies].bytes
    local overridden = {}
    for index = 2, #copies - 1 do
      local bytes = copies[index].bytes
      if bytes == winner then continue end

      local new = true
      for k = 1, index - 1 do
        if copies[k].bytes == bytes then
          new = false
          break
        end
      end

      if new then table.insert(overridden, copies[index].plugin) end
    end

    if #identical > 0 or #overridden > 0 then
      local plugins = {}
      for _, copy in copies do
        table.insert(plugins, copy.plugin)
      end

      table.insert(out, {
        type = record.key.type,
        id = record.key.id,
        plugins = plugins,
        identical = identical,
        overridden = overridden,
      })
    end
  end

  return out
end

return table.freeze {
  common = common,
  compareBytes = compareBytes,
  diff = diff,
  fieldChanges = fieldChanges,
  overlaps = overlaps,
  overrides = overrides,
}
