--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
-- An openmw.cfg kept as its lines, updated the way dream-ini's `load_cfg_document`,
-- `apply_preserved_cfg_update`, `serialize_preserved_cfg_document`, and
-- `save_preserved_cfg_document_to_path` update and write one: comments, blank lines, and the
-- order of untouched lines survive; a replaced list gives up its old lines' places and goes at the
-- end; a replaced singleton keeps its place. The openmw-config document is loaded beside the
-- lines and receives the same edits, so a resolved save of it agrees with the lines.
local types, parser, storage = require './types', require './parser', require './storage'
local openmw = require '@dream/openmw-config'
type MultiMap = types.MultiMap
type Update = types.Update

--- One `key=value` line with the comment and blank lines above it, or, without a key, the lines
--- that ended the file with no setting after them.
export type Entry = { comment: string, key: string?, value: string? }

export type Document = {
  --- The openmw-config document of the same file, edited in step with the lines.
  config: typeof(openmw.loadOptional ''),
  --- The file the lines came from, or would have come from.
  path: string,
  entries: { Entry },
}

--- The keys openmw-config types on load; every other key is a generic setting, and only a
--- generic setting answers to `set_generic_settings` for its key.
local Typed: { [string]: boolean } = {
  content = true,
  groundcover = true,
  ['fallback-archive'] = true,
  fallback = true,
  encoding = true,
  config = true,
  data = true,
  resources = true,
  ['user-data'] = true,
  ['data-local'] = true,
  replace = true,
}
table.freeze(Typed)

local Stamp = '# OpenMW-Config Serializer Version:'

--- An openmw-config error as dream-ini reports it (`ImportError::OpenMwConfig`).
local function configError(problem: unknown): string
  local message = tostring(problem)
  return `dream.ini: OpenMW config error: {string.match(message, '^dream%.openmw: (.*)$') or message}`
end

--- The lines of `text` as openmw-config's loader reads them (`str::lines`): split at `\n`, with a
--- `\r` before the `\n` dropped and a final line without a `\n` kept whole.
local function lines(text: string): { string }
  local result: { string } = {}
  local start, length = 1, #text

  while start <= length do
    local newline = string.find(text, '\n', start, true)

    if not newline then
      table.insert(result, string.sub(text, start))
      break
    end

    local finish = newline - 1
    if finish >= start and string.byte(text, finish) == 13 then
      finish -= 1
    end

    table.insert(result, string.sub(text, start, finish))
    start = newline + 1
  end

  return result
end

--- `text` split into entries the way openmw-config's loader attaches comments to settings: a
--- second `encoding=` takes the first's place, `config=` lines move behind the settings, and the
--- comments that ended the file follow them, minus a serializer stamp.
local function parse(text: string): { Entry }
  local entries: { Entry }, subConfigs: { Entry } = {}, {}
  local comment: { string } = {}
  local encodingAt: number?

  for _, line in lines(text) do
    local trimmed = parser.trim(line)

    if trimmed == '' then
      table.insert(comment, '\n')
      continue
    end

    if string.sub(trimmed, 1, 1) == '#' then
      table.insert(comment, line .. '\n')
      continue
    end

    local equals = string.find(trimmed, '=', 1, true)
      or error(`dream.ini: OpenMW config error: invalid line: {trimmed}`, 0)
    local entry: Entry = {
      comment = table.concat(comment),
      key = parser.trim(string.sub(trimmed, 1, equals - 1)),
      value = parser.trim(string.sub(trimmed, equals + 1)),
    }
    table.clear(comment)

    if entry.key == 'config' then
      table.insert(subConfigs, entry)
    elseif entry.key == 'encoding' and encodingAt then
      entries[encodingAt] = entry
    else
      table.insert(entries, entry)
      if entry.key == 'encoding' then encodingAt = #entries end
    end
  end

  table.move(subConfigs, 1, #subConfigs, #entries + 1, entries)
  local trailing: { string } = {}

  for _, line in comment do
    if string.sub(line, 1, #Stamp) ~= Stamp then table.insert(trailing, line) end
  end

  if #trailing > 0 then table.insert(entries, { comment = table.concat(trailing) }) end

  return entries
end

--- The openmw.cfg at `path` (a file, or a folder holding one) as a document: its openmw-config
--- chain and its own lines. A missing file is an empty document at that path.
local function load(path: string): Document
  -- `loadOptional` throws for a malformed cfg: a line without `=`, a bad `encoding=` or
  -- `fallback=` value, a `config=` chain that can't be read.
  local ok, config = pcall(openmw.loadOptional, path)
  if not ok then error(configError(config), 0) end

  local file = if jess.fs.isDir(path) then jess.fs.join(path, 'openmw.cfg') else path
  return { config = config, path = file, entries = parse(jess.fs.read(file) or '') }
end

local function remove(document: Document, matches: (Entry) -> boolean)
  local kept: { Entry } = {}

  for _, entry in document.entries do
    if not (entry.key and matches(entry)) then table.insert(kept, entry) end
  end

  document.entries = kept
end

local function append(document: Document, key: string, values: { string }?)
  for _, value in values or {} do
    table.insert(document.entries, { comment = '', key = key, value = value })
  end
end

--- Every line of `key` goes, and `values` follow the last line (`replace_list`).
local function replaceList(document: Document, key: string, values: { string }?)
  remove(document, function(entry) return entry.key == key end)
  append(document, key, values)
end

--- Every generic line of `key` goes (`set_generic_settings`): a typed key's lines aren't generic.
local function replaceGeneric(document: Document, key: string, values: { string }?)
  document.config:setGenericSettings(key, values)
  if Typed[key] then return end

  replaceList(document, key, values)
end

--- The document's `key=` lines, whatever file they came from, cleared the way
--- `clear_preserved_key` clears them: the singleton is removed until none is left.
local function clearSingleton(
  document: Document,
  key: string,
  present: () -> boolean,
  clear: () -> ()
)
  while present() do
    clear()
  end

  remove(document, function(entry) return entry.key == key end)
end

--- `result`'s changed keys applied to `document`, as `apply_preserved_cfg_update` applies them:
--- the encoding, `no-sound`, and the `fallback=` list when they changed; each imported `data=`
--- folder the chain doesn't have; the content and archive lists when they changed and `update`
--- imported them; and the folder overrides, each replacing every line of its key.
local function apply(
  document: Document,
  result: { cfg: MultiMap, changedKeys: { string } },
  update: Update
)
  local cfg, config = result.cfg, document.config
  local changed: { [string]: boolean } = {}

  for _, key in result.changedKeys do
    changed[key] = true
  end

  local encoding = cfg.encoding

  if changed.encoding and encoding and #encoding > 0 then
    local value = encoding[#encoding]
    clearSingleton(
      document,
      'encoding',
      function() return config:encoding() ~= nil end,
      function() config:setEncoding(nil) end
    )
    -- `setEncoding` throws for a label that isn't win1250, win1251, or win1252.
    local ok, problem = pcall(config.setEncoding, config, value)
    if not ok then error(configError(problem), 0) end

    append(document, 'encoding', { value })
  end

  if changed['no-sound'] then replaceGeneric(document, 'no-sound', cfg['no-sound']) end

  if changed.fallback then
    -- `setGameSettings` throws for a value without a comma; the list is cleared first, as
    -- openmw-config clears it, and nothing is written after an error.
    local ok, problem = pcall(config.setGameSettings, config, cfg.fallback)
    if not ok then error(configError(problem), 0) end

    replaceList(document, 'fallback', cfg.fallback)
  end

  if changed.data then
    for _, directory in cfg.data or {} do
      if config:hasDataDir(directory) then continue end

      config:addDataDirectory(directory)
      append(document, 'data', { directory })
    end
  end

  if update.gameFiles and changed.content then
    config:setContentFiles(cfg.content)
    replaceList(document, 'content', cfg.content)
  end

  if update.archives ~= false and changed['fallback-archive'] then
    config:setFallbackArchives(cfg['fallback-archive'])
    replaceList(document, 'fallback-archive', cfg['fallback-archive'])
  end

  type Override = { key: string, path: string?, present: () -> boolean, set: (string?) -> () }
  local dataLocal: Override = {
    key = 'data-local',
    path = update.dataLocal,
    present = function() return config:dataLocal() ~= nil end,
    set = function(path) config:setDataLocal(path) end,
  }

  local resources: Override = {
    key = 'resources',
    path = update.resources,
    present = function() return config:resources() ~= nil end,
    set = function(path) config:setResources(path) end,
  }

  local userData: Override = {
    key = 'user-data',
    path = update.userData,
    present = function() return config:userData() ~= nil end,
    set = function(path) config:setUserData(path) end,
  }

  for _, override in { dataLocal, resources, userData } do
    local path = override.path
    if not path then continue end

    clearSingleton(document, override.key, override.present, function() override.set(nil) end)
    override.set(path)
    append(document, override.key, { path })
  end
end

--- The document's text: each line with its comment, as the file would read.
local function render(document: Document): string
  local output: { string } = {}

  for _, entry in document.entries do
    table.insert(output, entry.comment)

    if entry.key then table.insert(output, `{entry.key}={entry.value}\n`) end
  end

  return table.concat(output)
end

--- `text` written over `path` through a temporary file beside it and a rename, so a failure
--- leaves the old file whole, with dream-ini's error wording.
local function replaceFile(path: string, text: string)
  -- `replace` throws when the folder can't take a temporary file or the rename fails.
  local ok, problem = pcall(jess.fs.replace, path, text)
  if ok then return end

  local message = tostring(problem)
  error(
    `dream.ini: {path}: {string.match(message, '^failed to write \'.-\': (.*)$') or message}`,
    0
  )
end

--- The document written to `path`, resolved through symbolic links first so a linked openmw.cfg's
--- target is what's replaced (`save_preserved_cfg_document_to_path`).
local function save(document: Document, path: string)
  replaceFile(storage.canonical(path), render(document))
end

return table.freeze {
  load = load,
  apply = apply,
  render = render,
  save = save,
  replaceFile = replaceFile,
  parse = parse,
}
