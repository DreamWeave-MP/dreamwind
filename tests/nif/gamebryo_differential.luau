--!nonstrict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Holds the multi-version reader (`nif/gamebryo`) to jess-nif's, record by record: every field of
every record `jess.nif.dumpBytes` reports, and the error when it refuses a file. Run by
`libs/lua/tests/nif_experiment.rs`, which hands over the files.
]]

local Array = require '../../src/nif/internal/array'
local Gamebryo = require '../../src/nif/internal/gamebryo/reader'

--- A value as plain data: vectors and views become lists, a missing link -1.
local function plain(value: any, width: number?): any
  if type(value) == 'vector' then
    if width == 2 then return { value.x, value.y } end

    return { value.x, value.y, value.z }
  end

  if Array.isArray(value) then
    local list = table.create(value.count)
    for i = 1, value.count do
      local packed = table.pack(value:get(i))
      list[i] = if packed.n == 1
        then plain(packed[1], width)
        else { table.unpack(packed, 1, packed.n) }
    end

    return list
  end

  return value
end

--- Fields jess-nif keeps but leaves out of its dump, by name and record name.
local Unreported = { data = { NiPixelData = true } }

local function equal(rust: any, mine: any): boolean
  if rust == nil or rust == jess.null then return mine == nil or mine == -1 end

  if type(rust) == 'number' and type(mine) == 'number' then
    return rust == mine or (rust ~= rust and mine ~= mine)
  end

  return rust == mine
end

local function compare(rust: any, mine: any, path: string, problems: { string })
  if #problems >= 20 then return end

  if type(rust) == 'table' and rust ~= jess.null then
    if type(mine) == 'vector' or Array.isArray(mine) then
      local width = if type(rust[1]) == 'table' then #rust[1] else #rust
      mine = plain(mine, width)
    end

    if type(mine) ~= 'table' then
      table.insert(problems, `{path}: a {typeof(mine)} where jess-nif has a table`)
      return
    end

    for key, value in rust do
      compare(value, mine[key], `{path}.{key}`, problems)
    end

    for key, value in mine do
      if Unreported[key] and Unreported[key][rust.type] then continue end

      if
        rust[key] == nil
        and value ~= -1
        and not (type(value) == 'table' and next(value) == nil)
      then
        table.insert(problems, `{path}.{key}: only the port has it ({typeof(value)})`)
      end
    end

    return
  end

  if not equal(rust, mine) then
    table.insert(problems, `{path}: {tostring(mine)} where jess-nif has {tostring(rust)}`)
  end
end

--- What differs between the port and jess-nif on one file, as readable lines; the second result
--- says the port couldn't read a record type it has no schema for yet.
local function check(bytes: buffer, path: string?): ({ string }, string?)
  local problems = {}
  local ok, rust = pcall(jess.nif.dumpBytes, bytes, path or '', { reader = 'gamebryo' })
  local mineOk, mine = pcall(Gamebryo.open, bytes)
  if not mineOk then
    local message = if type(mine) == 'table' then mine.message else tostring(mine)
    if string.find(message, '^No reader for class') then return problems, message end

    if ok then
      table.insert(problems, `the port refuses what jess-nif reads: {message}`)
    elseif not string.find(tostring(rust), message, 1, true) then
      table.insert(problems, `refused as "{message}" where jess-nif says "{tostring(rust)}"`)
    end

    return problems
  end

  if not ok then
    table.insert(problems, `the port reads what jess-nif refuses: {tostring(rust)}`)
    return problems
  end

  for i, record in rust.records do
    local fields = table.clone(record)
    fields.index = nil
    compare(fields, mine.records[i], `#{i - 1} {record.type}`, problems)
  end

  if #rust.records ~= #mine.records then
    table.insert(problems, `{#mine.records} records where jess-nif has {#rust.records}`)
  end

  return problems
end

return table.freeze { check = check, plain = plain }
