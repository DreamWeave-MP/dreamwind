--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Saves in Luau: what `jess save` does, over `@dreamwind/tes3`. OpenMW and Morrowind saves open and
describe themselves (metadata, screenshot, readable records, Lua data); OpenMW saves can be
validated, checked against a load order, and have content files stripped from them, with every
rule jess-save applies. A load order is a `loadOrder` value: `loadOrder.fromOpenMw(context)` for
a `jess.openmw` context.
]]

local Check = require '@self/check'
local LoadOrder = require '@self/loadorder'
local Read = require '@self/read'
local Strip = require '@self/strip'
local Values = require '@self/values'
local tes3 = require '@dreamwind/tes3'

export type Save = Read.Save
export type Game = Read.Game
export type Options = Read.Options
export type Info = Read.Info
export type LuaDataRow = Read.LuaDataRow
export type LoadOrder = LoadOrder.LoadOrder
export type Content = LoadOrder.Content
export type Check = Check.Check
export type CheckOptions = Check.CheckOptions
export type Finding = Check.Finding
export type MissingContent = Check.MissingContent
export type Validation = Check.Validation
export type StripOptions = Strip.StripOptions
export type Mode = Strip.Mode

--- Removes `dependencies` (content file names, any order) from an OpenMW save, as `jess save
--- strip` does: planned, applied, and verified in memory before anything is written. Unless it's a
--- dry run or written to `output`, `save.plugin` becomes the stripped save when nothing blocked.
local function strip(
  save: Save,
  dependencies: { string },
  options: StripOptions?
): { [string]: unknown }
  local report, stripped = Strip.strip(save, dependencies, options)
  local mode = options and options.mode
  local replaces = mode == 'inPlace'
    or mode == 'inMemory'
    or (not mode and not (options and options.output))
  if stripped and replaces then save.plugin = stripped end

  return report
end

--- A save record's id, as `jess save dump --list` names it: typed RefIds spelled as OpenMW spells
--- them, nil for records without one.
local function recordId(save: Save, index: number): string?
  local id = tes3.records.id(save.plugin, index)
  return if id and id ~= '' then id else nil
end

return table.freeze {
  check = Check.check,
  info = Read.info,
  loadOrder = LoadOrder,
  luaData = Read.luaData,
  open = Read.open,
  parse = Read.parse,
  recordId = recordId,
  screenshot = Read.screenshot,
  strip = strip,
  validate = Check.validate,
  values = Values.values,
}
