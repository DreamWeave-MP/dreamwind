--!nonstrict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Holds the package's `check` to jess-nif's, file by file: every finding (severity, code, message,
and record, in order), the stats, the texture paths, and how the model collides, against
`jess.nif.checkBytes` and `jess.nif.infoBytes` with no VFS to resolve textures against.
]]

local Check = require '../../src/nif/internal/check'

--- `snake_case` as jess's Luau API spells report symbols, `camelCase`.
local function camel(text: string): string return (string.gsub(text, '_(%l)', string.upper)) end

local function same(left: any, right: any): boolean
  if left == right then return true end

  if type(left) == 'string' and type(right) == 'string' then return camel(left) == camel(right) end

  return (left == nil or left == jess.null) and (right == nil or right == jess.null)
end

--- What differs between the port's report and jess-nif's on one file, as readable lines.
local function check(bytes: buffer, path: string): { string }
  local problems = {}
  local rust = jess.nif.checkBytes(bytes, path)
  local info = jess.nif.infoBytes(bytes, path)
  local mine = Check.check(path, bytes)
  if rust.deeplyChecked ~= mine.deep then
    table.insert(problems, `deep: {mine.deep} where jess-nif has {rust.deeplyChecked}`)
  end

  -- Texture lookups are the assets layer's, which `checkBytes` adds on top of the check.
  local theirsCore = {}
  for _, finding in rust.findings do
    if finding.code ~= 'missingTexture' and finding.code ~= 'uncompressedTexture' then
      table.insert(theirsCore, finding)
    end
  end

  rust = table.clone(rust)
  rust.findings = theirsCore
  local count = math.max(#rust.findings, #mine.findings)
  for i = 1, count do
    local theirs, ours = rust.findings[i], mine.findings[i]
    if not theirs or not ours then
      local extra = theirs or ours
      table.insert(
        problems,
        `finding {i}: only {if theirs then 'jess-nif' else 'the port'} has [{extra.severity}] {extra.code}: {extra.message}`
      )
      continue
    end

    for _, key in { 'severity', 'code', 'message', 'record' } do
      if not same(theirs[key], ours[key]) then
        table.insert(
          problems,
          `finding {i} {key}: {tostring(ours[key])} where jess-nif has {tostring(theirs[key])}`
        )
      end
    end
  end

  if rust.stats or mine.stats then
    for key, value in rust.stats or {} do
      if not same(value, (mine.stats or {})[key]) then
        table.insert(
          problems,
          `stats.{key}: {tostring((mine.stats or {})[key])} where jess-nif has {tostring(value)}`
        )
      end
    end
  end

  for i = 1, math.max(#rust.textures, #mine.textures) do
    local theirs, ours = rust.textures[i], mine.textures[i]
    if not theirs or not ours or theirs.path ~= ours then
      table.insert(
        problems,
        `texture {i}: {tostring(ours)} where jess-nif has {tostring(theirs and theirs.path)}`
      )
    end
  end

  local collision, ours = info.collision, mine.collision
  if (collision ~= nil and collision ~= jess.null) ~= (ours ~= nil) then
    table.insert(problems, `collision: {if ours then 'the port' else 'jess-nif'} alone has one`)
  elseif ours then
    local fields = {
      source = ours.source,
      node = ours.node,
      hidesMarkers = ours.hidesMarkers,
      bsxFlags = ours.bsxFlags,
    }

    for key, value in fields do
      if not same(collision[key], value) then
        table.insert(
          problems,
          `collision.{key}: {tostring(value)} where jess-nif has {tostring(collision[key])}`
        )
      end
    end
  end

  return problems
end

return table.freeze { check = check }
