--!nonstrict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Holds the package's reports over many files to jess-nif's: `check`, `info`, and a dry-run `fix`
of the same inputs, against `jess.nif.check`, `jess.nif.info`, and `jess.nif.fix`, field by field.
Without a load order (`openmw = false` there, no base VFS here) unless one is given.
]]

local Assets = require '../../src/nif/internal/assets'

local function compare(rust: any, mine: any, path: string, problems: { string })
  if #problems >= 20 then return end

  if rust == jess.null then rust = nil end

  if type(rust) == 'table' then
    if type(mine) ~= 'table' then
      table.insert(problems, `{path}: {tostring(mine)} where jess-nif has a table`)
      return
    end

    for key, value in rust do
      compare(value, mine[key], `{path}.{key}`, problems)
    end

    for key, value in mine do
      local empty = type(value) == 'table' and next(value) == nil
      if rust[key] == nil and not empty then
        table.insert(problems, `{path}.{key}: only the port has {tostring(value)}`)
      end
    end

    return
  end

  if rust ~= mine and not (rust ~= rust and mine ~= mine) then
    table.insert(problems, `{path}: {tostring(mine)} where jess-nif has {tostring(rust)}`)
  end
end

--- What differs between the port's reports on `inputs` and jess-nif's, with `openmw`'s load
--- order under both when given.
local function check(inputs: { string }, openmw: OpenMwContext?): { string }
  local problems = {}
  local options = if openmw then {} else { openmw = false }
  local base = if openmw then openmw:vfs() else nil
  compare(
    jess.nif.check(inputs, options),
    Assets.check(Assets.sources(base, nil, inputs)),
    'check',
    problems
  )
  compare(
    jess.nif.info(inputs, options),
    Assets.info(Assets.sources(base, nil, inputs)),
    'info',
    problems
  )

  local fixOptions = table.clone(options)
  fixOptions.dryRun = true
  compare(
    jess.nif.fix(inputs, fixOptions),
    Assets.fix(Assets.sources(base, nil, inputs), { dryRun = true }),
    'fix',
    problems
  )
  return problems
end

return table.freeze { check = check }
