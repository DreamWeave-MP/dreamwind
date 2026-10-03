--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
-- Multimaps as openmw-config documents, for the normalization every import runs and for the
-- writers: `save_cfg_output_to_path` and `save_resolved_cfg_to_path` build one from the imported
-- map and write it through a temporary file, `save_resolved_configuration_to_path` writes a
-- loaded document the same way.
local types, parser = require './types', require './parser'
local openmw = require '@dream/openmw-config'
type MultiMap = types.MultiMap
type Config = typeof(openmw.loadOptional '')

local function removeComposed(cfg: MultiMap): MultiMap
  local data = cfg.data

  if not data then return cfg end

  for _, key in { 'data-local', 'resources' } do
    local values = cfg[key]

    if not values or #values == 0 then continue end

    local composed = if key == 'resources'
      then jess.fs.join(values[#values], 'vfs')
      else values[#values]
    local kept: { string } = {}

    for _, directory in data do
      if directory ~= composed then table.insert(kept, directory) end
    end

    data = kept
    cfg.data = data
  end

  return cfg
end

--- An openmw-config error as dream-ini reports it (`ImportError::OpenMwConfig`).
local function configError(problem: unknown): string
  local message = tostring(problem)
  return `dream.ini: OpenMW config error: {string.match(message, '^dream%.openmw: (.*)$') or message}`
end

--- `cfg` as an empty document of `directory` (the working directory when it's empty) filled key
--- by key in key order. Resolved, the folder singletons take their last value; preserving, they
--- stay generic lines, every value kept as written.
local function document(cfg: MultiMap, directory: string, preserving: boolean?): Config
  local result = openmw.newEmpty(if directory == '' then jess.fs.cwd() else directory)

  for _, key in parser.keys(cfg) do
    local values = cfg[key]

    if key == 'data' then
      result:setDataDirectories(values)
    elseif key == 'content' then
      result:setContentFiles(values)
    elseif key == 'fallback-archive' then
      result:setFallbackArchives(values)
    elseif key == 'fallback' then
      -- `setGameSettings` throws for a value without a comma.
      local ok, problem = pcall(result.setGameSettings, result, values)
      if not ok then error(configError(problem), 0) end
    elseif preserving or (key ~= 'data-local' and key ~= 'resources' and key ~= 'user-data') then
      result:setGenericSettings(key, values)
    elseif #values > 0 then
      if key == 'data-local' then
        result:setDataLocal(values[#values])
      elseif key == 'resources' then
        result:setResources(values[#values])
      else
        result:setUserData(values[#values])
      end
    end
  end

  return result
end

--- A loaded document's resolved text as dream-ini serializes it: openmw-config's resolved form,
--- reparsed, without the `data=` folders composed from `data-local=` and `resources=`, in key
--- order (`serialize_resolved_configuration`).
local function resolvedText(config: Config): string
  return parser.serializeCfg(removeComposed(parser.parseCfg(config:toResolvedString())))
end

local function normalize(cfg: MultiMap, directory: string?): MultiMap
  if not directory then return cfg end

  return removeComposed(parser.parseCfg(document(cfg, directory):toResolvedString()))
end

local function load(path: string): MultiMap
  return removeComposed(parser.parseCfg(openmw.loadOptional(path):toResolvedString()))
end

return table.freeze {
  document = document,
  resolvedText = resolvedText,
  normalize = normalize,
  load = load,
}
