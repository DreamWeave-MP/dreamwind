--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Readable dumps and byte layouts (what `jess plugin dump` prints, and `--raw`): every selected
record's readable value (`@dreamwind/tes3`'s `display`), or where it and its subrecords sit in the
plugin's bytes.
]]

local Select = require './select'
local tes3 = require '@dreamwind/tes3'

type Plugin = tes3.Plugin

local display = tes3.display.display

--- The readable values of every record `selector` selects (all of them without one).
local function dump(plugin: Plugin, selector: Select.Selector?): { { [string]: unknown } }
  local out = {}
  for i = 0, plugin:count() - 1 do
    if not selector then
      table.insert(out, display(plugin, i))
      continue
    end

    local picked = Select.selection(selector, plugin, i)
    if picked then table.insert(out, display(plugin, i, picked.references)) end
  end

  return out
end

--[[ Layout ]]

export type SubrecordLayout = {
  index: number,
  type: string,
  size: number,
  range: { start: number, ['end']: number },
  field: string?,
  value: string?,
}

export type RecordLayout = {
  index: number,
  type: string,
  id: string?,
  flags: number,
  size: number,
  range: { start: number, ['end']: number },
  subrecords: { SubrecordLayout }?,
}

--- Where record `index` and (with `subrecords`) its subrecords that pass the selector's
--- subrecord filters sit in the plugin's bytes; `fields` adds their typed string fields.
local function layout(
  plugin: Plugin,
  index: number,
  selector: Select.Selector,
  options: { subrecords: boolean?, fields: boolean? }?
): RecordLayout
  local start, finish = plugin:range(index)
  local id = tes3.records.fieldId(plugin, index) or tes3.records.id(plugin, index)
  local out: RecordLayout = {
    index = index,
    type = tes3.tags.display(plugin:code(index)),
    id = if id and id ~= '' then id else nil,
    flags = plugin:flags(index),
    size = plugin:size(index),
    range = { start = start, ['end'] = finish },
  }

  if not options or not options.subrecords then return out end

  local fields: { [number]: tes3.StringField } = {}
  if options.fields then
    for _, field in tes3.records.stringFields(plugin, index) do
      fields[field.subrecord] = field
    end
  end

  local list = {}
  local dirty = plugin:isDirty(index)
  for k, sub in plugin:subrecords(index) do
    if not Select.matchesSubrecord(selector, plugin, index, sub) then continue end

    local field = fields[k - 1]
    table.insert(list, {
      index = k - 1,
      type = tes3.tags.display(sub.code),
      size = sub.size,
      range = if dirty
        then { start = finish, ['end'] = finish }
        else { start = sub.start, ['end'] = sub.finish },
      field = field and field.name,
      value = field and field.value,
    })
  end

  if #list > 0 then out.subrecords = list end

  return out
end

return table.freeze { dump = dump, layout = layout }
