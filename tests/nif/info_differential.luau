--!nonstrict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Holds the package's `info` to jess-nif's, file by file: the record type counts and the scene
tree, node for node, against `jess.nif.infoBytes`. Morrowind files are read with the Morrowind
model, every other version with the multi-version reader, as jess-nif reads them. jess-nif only
reads the records of a file its check reads deeply, so only those files are compared; for the
rest, `infoBytes` counts the header's types, which the assets differential holds.
]]

local Check = require '../../src/nif/internal/check'
local Info = require '../../src/nif/internal/info'
local Nif = require '../../src/nif/init'
local Reader = require '../../src/nif/internal/gamebryo/reader'

local function compare(rust: any, mine: any, path: string, problems: { string })
  if #problems >= 12 then return end

  if type(rust) == 'table' and rust ~= jess.null then
    if type(mine) ~= 'table' then
      table.insert(problems, `{path}: {tostring(mine)} where jess-nif has a table`)
      return
    end

    for key, value in rust do
      compare(value, mine[key], `{path}.{key}`, problems)
    end

    for key, value in mine do
      if rust[key] == nil then
        table.insert(problems, `{path}.{key}: only the port has it ({tostring(value)})`)
      end
    end

    return
  end

  local missing = rust == nil or rust == jess.null
  if missing and mine == nil then return end

  if rust ~= mine then
    table.insert(problems, `{path}: {tostring(mine)} where jess-nif has {tostring(rust)}`)
  end
end

--- What differs between the port's counts and tree and jess-nif's on one file.
local function check(bytes: buffer, path: string): { string }
  local problems = {}
  if not Check.check(path, bytes).deep then return problems end

  local rust = jess.nif.infoBytes(bytes, path)
  local counts, tree
  if
    buffer.len(bytes) >= 40
    and buffer.readstring(bytes, 0, 40) == 'NetImmerse File Format, Version 4.0.0.2\n'
  then
    local ok, nif = pcall(Nif.open, bytes)
    if not ok then return problems end

    counts, tree = Info.recordTypeCounts(nif), Info.sceneTree(nif)
  else
    local ok, file = pcall(Reader.open, bytes)
    if not ok then return problems end

    counts, tree = Info.fileTypeCounts(file), Info.fileSceneTree(file)
  end

  compare(rust.recordTypes, counts, 'recordTypes', problems)
  compare(rust.tree, tree, 'tree', problems)
  return problems
end

return table.freeze { check = check }
