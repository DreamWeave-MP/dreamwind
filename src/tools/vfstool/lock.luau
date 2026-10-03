--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
-- Reads the lock formats accepted by the native vfstool CLI.
local fs = require '@dream/fs'
local json = require '@jess/json'
local yaml = require '@jess/yaml'

type Entry = {
  key: string,
  winner_source: string,
  winner_kind: string,
  winner_hash_blake3: string?,
  winner_size: number?,
  provider_count: number,
}

type Lock = { schema_version: number, entries: { Entry } }

local function decode(path: string, source: string): (unknown?, string?)
  local extension = string.lower(string.match(path, '%.([^.]+)$') or '')
  if extension == 'json' then
    -- @jess/json.decode raises when the file is not JSON.
    local ok, value = pcall(json.decode, source)
    if ok then return value end
    return nil, tostring(value)
  end

  if extension == 'toml' then
    -- jess.toml.decode raises when the file is not TOML.
    local ok, value = pcall(jess.toml.decode, source)
    if ok then return value end
    return nil, tostring(value)
  end

  if extension == 'yaml' or extension == 'yml' then
    -- @jess/yaml.decode raises when the file is not YAML.
    local ok, value = pcall(yaml.decode, source)
    if ok then return value end
    return nil, tostring(value)
  end

  return nil, `unsupported lock file extension '.{extension}'`
end

local function read(path: string): (Lock?, string?)
  local source, problem = fs.readFileString(path)
  if not source then return nil, problem end

  local decoded, decodeProblem = decode(path, source)
  if not decoded then return nil, decodeProblem end

  if type(decoded) ~= 'table' then return nil, 'lock file must contain a table' end

  local value = decoded :: { [string]: unknown }
  local version, rawEntries = value.schema_version, value.entries
  if type(version) ~= 'number' or type(rawEntries) ~= 'table' then
    return nil, 'lock file must contain schema_version and entries'
  end

  if version ~= 1 then return nil, `unsupported VFS lock schema version {version}` end

  local entries = rawEntries :: { unknown }
  for index, rawEntry in entries do
    if type(rawEntry) ~= 'table' then return nil, `invalid VFS lock entry {index}` end
    local entry = rawEntry :: { [string]: unknown }
    if
      type(entry.key) ~= 'string'
      or type(entry.winner_source) ~= 'string'
      or (entry.winner_kind ~= 'loose_dir' and entry.winner_kind ~= 'archive')
      or (entry.winner_hash_blake3 ~= nil and type(entry.winner_hash_blake3) ~= 'string')
      or (entry.winner_size ~= nil and type(entry.winner_size) ~= 'number')
      or type(entry.provider_count) ~= 'number'
    then
      return nil, `invalid VFS lock entry {index}`
    end
  end

  return value :: Lock
end

return table.freeze { read = read }
