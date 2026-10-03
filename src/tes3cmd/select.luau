--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Record, subrecord, and CELL reference selection (jess-omwaddon's `select`), shared by dump, delete,
and modify. Every pattern is a case-insensitive Rust regex (`jess.regex`) except `exactIds`.
Record filters test types, flags, ids, raw bytes, and cell kind; subrecord and instance filters
test a subrecord's text: `name: value` for a typed string field, `TAG: raw` otherwise.
]]

local tes3 = require '@dreamwind/tes3'

type Plugin = tes3.Plugin

--- What a selector selects, spelled as `jess.select` takes it. A list may be one string.
export type Spec = {
  --- Record types: tags (`LIGH`, `npc` for `NPC_`) or type names (`Light`), in any case.
  type: (string | { string })?,
  --- Flags by name (`deleted`, `persistent`, `ignored`, `blocked`) or number; any may match.
  flags: (string | { string })?,
  --- Patterns every record id must match.
  id: (string | { string })?,
  --- Ids, any of which must equal the record id, ignoring case.
  exactId: (string | { string })?,
  --- Patterns every record's raw bytes must match, and none may.
  match: (string | { string })?,
  notMatch: (string | { string })?,
  --- A pattern some subrecord's text must match, and none may.
  sub: string?,
  notSub: string?,
  --- A pattern some CELL reference's text must match, and none may.
  instance: string?,
  notInstance: string?,
  interior: boolean?,
  exterior: boolean?,
}

export type Selector = {
  types: { [number]: boolean }?,
  flags: { number },
  ids: { Regex },
  exactIds: { string },
  matches: { Regex },
  noMatches: { Regex },
  subMatch: Regex?,
  subNoMatch: Regex?,
  instanceMatch: Regex?,
  instanceNoMatch: Regex?,
  interior: boolean,
  exterior: boolean,
}

local function compile(pattern: string, bytes: boolean): Regex
  -- jess.regex.new throws on a pattern that isn't a regex.
  local ok, regex = pcall(
    function(): Regex
      return jess.regex.new(if bytes then `(?-u){pattern}` else pattern, { caseInsensitive = true })
    end
  )
  if not ok then error(`invalid regex '{pattern}': {regex}`, 0) end

  return regex :: Regex
end

--- A record type: a tag (`LIGH`, `npc` for `NPC_`) or type name (`Light`) in any case; any other
--- four characters are taken as a tag, for types jess doesn't model.
local function parseType(value: string): string
  if string.lower(value) == 'npc' then return 'NPC_' end

  local tag = tes3.tagNamed(value)
  if tag then return tag end

  if #value == 4 then return string.upper(value) end

  return error(
    `invalid record type '{value}': expected a tag like LIGH or a type name like Light`,
    0
  )
end

local FlagNames: { [string]: number } =
  { deleted = 0x20, persistent = 0x400, ignored = 0x1000, blocked = 0x2000 }

--- A record flag by name or as a decimal or `0x` hex number.
local function parseFlag(value: string): number
  local lower = string.lower(value)
  local named = FlagNames[lower]
  if named then return named end

  local hex = string.match(lower, '^0x(%x+)$')
  local number = if hex
    then tonumber(hex, 16)
    elseif string.match(lower, '^%d+$') then tonumber(lower)
    else nil
  if not number or number > 4294967295 then error(`invalid record flag '{value}'`, 0) end

  return number
end

local SpecKeys = {
  type = true,
  flags = true,
  id = true,
  exactId = true,
  match = true,
  notMatch = true,
  sub = true,
  notSub = true,
  instance = true,
  notInstance = true,
  interior = true,
  exterior = true,
}

local function list(value: (string | { string })?): { string }
  if not value then return {} end

  if type(value) == 'string' then return { value } end

  return value
end

local function new(spec: Spec?): Selector
  local given: Spec = spec or {}
  for key in given :: { [string]: unknown } do
    if not SpecKeys[key] then error(`unknown selector option '{key}'`, 0) end
  end

  local types: { [number]: boolean }? = nil
  if #list(given.type) > 0 then
    local set: { [number]: boolean } = {}
    for _, value in list(given.type) do
      set[tes3.tags.code(parseType(value))] = true
    end

    types = set
  end

  local function regexes(patterns: (string | { string })?, bytes: boolean): { Regex }
    local out = {}
    for _, pattern in list(patterns) do
      table.insert(out, compile(pattern, bytes))
    end

    return out
  end

  local function optional(pattern: string?): Regex?
    return if pattern then compile(pattern, false) else nil
  end

  local flags = {}
  for _, value in list(given.flags) do
    table.insert(flags, parseFlag(value))
  end

  return {
    types = types,
    flags = flags,
    ids = regexes(given.id, false),
    exactIds = list(given.exactId),
    matches = regexes(given.match, true),
    noMatches = regexes(given.notMatch, true),
    subMatch = optional(given.sub),
    subNoMatch = optional(given.notSub),
    instanceMatch = optional(given.instance),
    instanceNoMatch = optional(given.notInstance),
    interior = given.interior == true,
    exterior = given.exterior == true,
  }
end

local function hasSubrecordFilters(selector: Selector): boolean
  return selector.subMatch ~= nil or selector.subNoMatch ~= nil
end

local function hasInstanceFilters(selector: Selector): boolean
  return selector.instanceMatch ~= nil or selector.instanceNoMatch ~= nil
end

--- Whether record `index` passes the record filters, cheapest first.
local function matchesRecord(selector: Selector, plugin: Plugin, index: number): boolean
  local types = selector.types
  if types and not types[plugin:code(index)] then return false end

  if #selector.flags > 0 then
    local bits = plugin:flags(index)
    local any = false
    for _, flag in selector.flags do
      if bit32.btest(bits, flag) then
        any = true
        break
      end
    end

    if not any then return false end
  end

  if #selector.ids > 0 or #selector.exactIds > 0 then
    local id = tes3.records.id(plugin, index)
    if #selector.ids > 0 then
      if not id then return false end

      for _, regex in selector.ids do
        if not regex:isMatch(id) then return false end
      end
    end

    if #selector.exactIds > 0 then
      if not id then return false end

      local lower = string.lower(id)
      local found = false
      for _, exact in selector.exactIds do
        if string.lower(exact) == lower then
          found = true
          break
        end
      end

      if not found then return false end
    end
  end

  if #selector.matches > 0 or #selector.noMatches > 0 then
    local raw = buffer.tostring(plugin:bytes(index))
    for _, regex in selector.matches do
      if not regex:isMatch(raw) then return false end
    end

    for _, regex in selector.noMatches do
      if regex:isMatch(raw) then return false end
    end
  end

  if selector.interior and not tes3.records.cellIsInterior(plugin, index) then return false end

  if selector.exterior and not tes3.records.cellIsExterior(plugin, index) then return false end

  return true
end

--- Whether a subrecord passes the subrecord filters; always true without any.
local function matchesSubrecord(
  selector: Selector,
  plugin: Plugin,
  index: number,
  sub: tes3.Subrecord
): boolean
  if not hasSubrecordFilters(selector) then return true end

  local text = tes3.records.subrecordText(plugin, index, sub)
  local subMatch, subNoMatch = selector.subMatch, selector.subNoMatch
  if subMatch and not subMatch:isMatch(text) then return false end

  return not (subNoMatch and subNoMatch:isMatch(text))
end

--- The CELL references (0-based) of record `index` that pass the instance filters.
local function matchingCellReferences(selector: Selector, plugin: Plugin, index: number): { number }
  local groups = plugin:cellGroups(index)
  if not groups then return {} end

  local subs = plugin:subrecords(index)
  local out = {}
  for i, group in groups.references do
    local lines = {}
    for k = group[1] + 1, group[2] + 1 do
      table.insert(lines, tes3.records.subrecordText(plugin, index, subs[k]) .. '\n')
    end

    local text = table.concat(lines)
    local match, noMatch = selector.instanceMatch, selector.instanceNoMatch
    if (not match or match:isMatch(text)) and not (noMatch and noMatch:isMatch(text)) then
      table.insert(out, i - 1)
    end
  end

  return out
end

export type Selection = { whole: boolean, references: { number }? }

--- Whether and how much of record `index` is selected, for showing whole records: it passes the
--- record filters and, with instance filters, is a CELL with a matching reference, or, with
--- subrecord filters, has a matching subrecord.
local function selection(selector: Selector, plugin: Plugin, index: number): Selection?
  if not matchesRecord(selector, plugin, index) then return nil end

  if hasInstanceFilters(selector) then
    if plugin:tag(index) ~= 'CELL' then return nil end

    local references = matchingCellReferences(selector, plugin, index)
    return if #references > 0 then { whole = false, references = references } else nil
  end

  if hasSubrecordFilters(selector) then
    for _, sub in plugin:subrecords(index) do
      if matchesSubrecord(selector, plugin, index, sub) then return { whole = true } end
    end

    return nil
  end

  return { whole = true }
end

export type Picked = { index: number, selection: Selection }

--- Every record `selector` selects, in plugin order (0-based positions).
local function picked(selector: Selector, plugin: Plugin): { Picked }
  local out = {}
  for i = 0, plugin:count() - 1 do
    local chosen = selection(selector, plugin, i)
    if chosen then table.insert(out, { index = i, selection = chosen }) end
  end

  return out
end

--- The ids of the records `selector` selects that have one, in plugin order.
local function ids(selector: Selector, plugin: Plugin): { string }
  local out = {}
  for _, entry in picked(selector, plugin) do
    local id = tes3.records.id(plugin, entry.index)
    if id then table.insert(out, id) end
  end

  return out
end

return table.freeze {
  hasInstanceFilters = hasInstanceFilters,
  hasSubrecordFilters = hasSubrecordFilters,
  matchesRecord = matchesRecord,
  matchesSubrecord = matchesSubrecord,
  matchingCellReferences = matchingCellReferences,
  ids = ids,
  new = new,
  parseFlag = parseFlag,
  parseType = parseType,
  picked = picked,
  selection = selection,
}
