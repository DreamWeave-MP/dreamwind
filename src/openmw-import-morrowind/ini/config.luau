--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
-- Multimap output is deliberately normalized, unlike a preserved document. Only explicit data
-- entries belong to the map; resources/vfs and data-local are composed by the Context, not here.
local types, parser = require './types', require './parser'
local openmw = require '@dreamwind/openmw-config'
local paths = require '../../openmw-config/paths'
local text = require '../../openmw-config/text'
type MultiMap = types.MultiMap

local Stamp = '# OpenMW-Config Serializer Version: 3.0.0\n'

local function normalize(cfg: MultiMap, directory: string?, tokens: openmw.Tokens?): MultiMap
  if not directory then return cfg end

  local source = jess.fs.join(paths.absolute(if directory == '' then jess.fs.cwd() else directory), 'openmw.cfg')
  local result: MultiMap = {}
  for _, key in parser.keys(cfg) do
    if key == 'config' or string.lower(key) == 'replace' then continue end

    local values: { string } = {}
    local input = cfg[key]
    local first = if text.SingletonKeys[key] then #input else 1
    for index = math.max(first, 1), #input do
      local value = input[index]
      text.validate(key, value, source, index)
      if text.DirectoryKeys[key] then
        value = text.encodeDirectory(paths.resolve(value, source, tokens or {}))
      end

      table.insert(values, value)
    end

    if #values > 0 then result[key] = values end
  end

  return result
end

local function renderMap(cfg: MultiMap, directory: string, preserving: boolean?, tokens: openmw.Tokens?): string
  if not preserving then return parser.serializeCfg(normalize(cfg, directory, tokens)) end

  for _, key in parser.keys(cfg) do
    for index, value in cfg[key] do text.validate(key, value, directory, index) end
  end

  return parser.serializeCfg(cfg) .. Stamp
end

local function resolvedText(config: openmw.Config): string
  return parser.serializeCfg(parser.parseCfg(config:render(true)))
end

local function load(path: string, options: openmw.Options?): MultiMap
  return parser.parseCfg(openmw.loadOptional(path, options):render(true))
end

return table.freeze {
  renderMap = renderMap,
  resolvedText = resolvedText,
  normalize = normalize,
  load = load,
}
