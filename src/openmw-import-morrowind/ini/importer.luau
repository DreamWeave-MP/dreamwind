--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
local types, parser, config = require './types', require './parser', require './config'
local content, fallbackKeys = require './content_files', require './fallback_keys'
local log = require('@jess/log').new 'morrowind.ini'
local options = require './options'
local fs = require '@dream/fs'
local storage = require './storage'
type MultiMap = types.MultiMap
type Result = types.Result
type Request = types.Request

--- The options both imports take, read and checked: the encoding is the canonical label.
type Import = {
  gameFiles: boolean,
  fonts: boolean,
  archives: boolean,
  verbose: boolean,
  encoding: string?,
  dataDirs: { string },
  dataLocal: string?,
  resources: string?,
  userData: string?,
  cfgDir: string?,
}

local Shared: options.Spec = {
  game = 'string',
  gameFiles = 'boolean',
  fonts = 'boolean',
  archives = 'boolean',
  verbose = 'boolean',
  encoding = 'string',
  dataDirs = 'paths',
  dataLocal = 'string',
  resources = 'string',
  userData = 'string',
  cfgDir = 'string',
}

local function spec(extra: options.Spec): options.Spec
  local result = table.clone(Shared)

  for key, kind in extra do
    result[key] = kind
  end

  return table.freeze(result)
end

local MapsSpec, PathsSpec = spec { iniPath = 'string' }, spec { ini = 'string', cfg = 'string' }

--- Each fallback key as the cfg spells it (`Weather_Sunrise_Time`), and whether it's a font.
local Translated: { [string]: string }, FontKeys: { [string]: boolean } = {}, {}

for _, key in fallbackKeys do
  Translated[key] = (string.gsub(key, '[ :]', '_'))
  FontKeys[key] = string.sub(key, 1, 6) == 'Fonts:'
end

table.freeze(Translated)
table.freeze(FontKeys)

local function readImport(context: string, given: { [string]: unknown }): Import
  local game = given.game :: string?

  if game and string.lower(game) ~= 'morrowind' then
    error(`{context}.game: unsupported game: {game}`, 0)
  end

  local encoding = given.encoding :: string?

  if encoding and not parser.encodingLabel(encoding) then
    error(`{context}.encoding: unsupported encoding: {encoding}`, 0)
  end

  local dataDirs = table.clone((given.dataDirs :: { string }?) or {})

  return {
    gameFiles = (given.gameFiles :: boolean?) or false,
    fonts = (given.fonts :: boolean?) or false,
    -- `archives` is on unless turned off, so `false` has to survive here.
    archives = if given.archives == nil then true else given.archives :: boolean,
    verbose = (given.verbose :: boolean?) or false,
    encoding = if encoding then parser.encodingLabel(encoding) else nil,
    dataDirs = dataDirs,
    dataLocal = given.dataLocal :: string?,
    resources = given.resources :: string?,
    userData = given.userData :: string?,
    cfgDir = given.cfgDir :: string?,
  }
end

--- The cfg's last `encoding`, or the default, as dream-ini reads it: a bad label is an error.
local function cfgEncoding(cfg: MultiMap, override: string?): string
  if override then return override end

  local values = cfg.encoding
  local label = if values and #values > 0 then values[#values] else 'win1252'
  return parser.encodingLabel(label) or error(`dream.ini: unsupported encoding: {label}`, 0)
end

local function copy(map: MultiMap): MultiMap
  local result: MultiMap = {}

  for key, values in map do
    result[key] = table.move(values, 1, #values, 1, {})
  end

  return result
end

--- One import over parsed maps: the shared body of `importMaps` and `importPaths`.
local function run(
  cfg: MultiMap,
  ini: MultiMap,
  import: Import,
  iniPath: string,
  cfgDir: string?,
  dataDirBase: string?
): Result
  local encoding = cfgEncoding(cfg, import.encoding)
  local changed: { [string]: boolean } = {}

  if import.encoding or not cfg.encoding then changed.encoding = true end

  local search = config.normalize(copy(cfg), cfgDir)
  local imported = copy(cfg)
  local audio = ini['General:Disable Audio']

  if audio and #audio > 0 then
    imported['no-sound'], changed['no-sound'] = { audio[#audio] }, true
  end

  local fallback: { string } = {}
  local count = 0

  for _, key in fallbackKeys do
    local values = ini[key]
    if not values or (FontKeys[key] and not import.fonts) then continue end

    local translated = Translated[key]

    for _, value in values do
      count += 1
      fallback[count] = translated .. ',' .. value
    end
  end

  if #fallback > 0 then
    imported.fallback, changed.fallback = fallback, true
  end

  local result: Result = { cfg = imported, text = '', warnings = {}, events = {}, changedKeys = {} }
  local request: Request = {
    cfg = search,
    ini = ini,
    iniPath = iniPath,
    cfgDir = cfgDir,
    dataDirs = import.dataDirs,
    dataDirBase = dataDirBase,
    verbose = import.verbose,
  }

  for _, archives in { false, true } do
    if (not archives and not import.gameFiles) or (archives and not import.archives) then
      continue
    end

    local resolved = content.import(request, archives)

    for _, directory in resolved.directories do
      imported.data = imported.data or {}
      table.insert(imported.data, directory.value)
      changed.data = true

      if not archives then
        search.data = search.data or {}
        table.insert(search.data, directory.path)
      end
    end

    local key = if archives then 'fallback-archive' else 'content'
    imported[key], changed[key] = resolved.names, true

    for _, event in resolved.events do
      table.insert(result.events, event)
      log.debug(event.kind, { path = event.path })
    end

    for _, warning in resolved.warnings do
      table.insert(result.warnings, warning)
      log.warn(warning.message)
    end
  end

  local overrides = {
    { 'data-local', import.dataLocal },
    { 'resources', import.resources },
    { 'user-data', import.userData },
  }

  for _, override in overrides do
    local key, path = override[1], override[2]

    if key and path then
      imported[key], changed[key] = { path }, true
    end
  end

  imported.encoding = { encoding }

  for key in changed do
    table.insert(result.changedKeys, key)
  end

  table.sort(result.changedKeys)
  result.text = parser.serializeCfg(imported)
  return result
end

local function importMaps(cfg: MultiMap, ini: MultiMap, given: types.MapsOptions?): Result
  local read = options.read('ini.importMaps', given, MapsSpec)
  local import = readImport('ini.importMaps', read)
  local iniPath = (read.iniPath :: string?) or 'Morrowind.ini'
  cfg = options.multimap('ini.importMaps', cfg)
  ini = options.multimap('ini.importMaps', ini)
  local dataDirBase = if #import.dataDirs > 0 then import.cfgDir else nil
  return run(cfg, ini, import, iniPath, import.cfgDir, dataDirBase)
end

local function importPaths(given: types.PathsOptions): Result
  local read = options.read('ini.importPaths', given, PathsSpec, { 'ini' })
  local import = readImport('ini.importPaths', read)
  local iniPath, cfgPath = read.ini :: string, read.cfg :: string?
  local cfgDir = if cfgPath then jess.fs.parent(cfgPath) or '' else nil
  -- Relative data folders resolve from the cfg's folder when there is a cfg.
  local dataDirBase = if #import.dataDirs > 0 then cfgDir or import.cfgDir else nil
  local cfg = if cfgPath then config.load(cfgPath) else {}
  local encoding = cfgEncoding(cfg, import.encoding)
  local text, message = fs.readFileString(iniPath)

  if not text then
    error(storage.ioMessage(iniPath, message :: string), 0)
  end

  local parsed = parser.parseIni(text, { encoding = encoding })
  local result = run(cfg, parsed.entries, import, iniPath, cfgDir, dataDirBase)

  for index = #parsed.warnings, 1, -1 do
    table.insert(result.warnings, 1, parsed.warnings[index])
  end

  return result
end

return table.freeze { importMaps = importMaps, importPaths = importPaths }
