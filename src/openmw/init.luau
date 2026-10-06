--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
-- An explicit configuration plus lazy loose-content and asset lookups. There is no process-wide
-- default, script loader, or second VFS here. Configuration generations invalidate cached views.
local configuration = require '@dreamwind/openmw-config'
local fs = require '@dream/fs'
local grammar = require './openmw-config/text'
local paths = require './openmw-config/paths'
local vfs = require '@dreamwind/vfs'

export type ContentEntry = { name: string, path: string? }
export type Context = {
  read dataDirs: { string },
  read fallbackArchives: { string },
  read encoding: string?,
  read userConfigDir: string,
  read dataLocal: string?,
  read writableDataDir: string?,
  read configuration: (self: Context) -> configuration.Config,
  read content: (self: Context) -> { ContentEntry },
  read resolve: (self: Context, path: string) -> string?,
  read readFile: (self: Context, path: string) -> buffer?,
  read vfs: (self: Context) -> vfs.VFS,
  read refresh: (self: Context) -> (),
  read activate: (self: Context, name: string, options: { force: boolean? }?) -> boolean,
  read activateAll: (self: Context, names: { string }, options: { force: boolean? }?) -> { string },
  read deactivate: (self: Context, name: string) -> boolean,
  read save: (self: Context) -> { path: string, backup: string? },
}

type State = {
  config: configuration.Config,
  generation: number,
  topLevel: { [string]: string }?,
  loose: vfs.VFS?,
  full: vfs.VFS?,
}

local states = (setmetatable({}, { __mode = 'k' }) :: unknown) :: { [Context]: State }
local Methods: { [string]: unknown } = {}

local function stateOf(context: Context): State
  local state = states[context]
  assert(state, 'dreamwind.openmw: invalid context receiver')
  local generation = state.config:generation()
  if generation ~= state.generation then
    state.topLevel, state.loose, state.full = nil, nil, nil
    state.generation = generation
  end

  return state
end

local function writable(config: configuration.Config): string?
  local dataLocal = config:path('data-local')
  if dataLocal then return dataLocal end

  -- dataDirectories puts the engine's resource VFS first; it is not an application output folder.
  local resources = config:path('resources')
  local engine = if resources then paths.key(jess.fs.join(resources, 'vfs')) else nil
  for _, directory in config:dataDirectories() do
    if not engine or paths.key(directory) ~= engine then return directory end
  end

  return nil
end

local function property(context: Context, name: string): unknown
  local method = Methods[name]
  if method then return method end

  local config = stateOf(context).config
  if name == 'dataDirs' then return config:dataDirectories() end
  if name == 'fallbackArchives' then return config:values('fallback-archive') end
  if name == 'encoding' then return config:last('encoding') end
  if name == 'userConfigDir' then return jess.fs.parent(config:userFile()) end
  if name == 'dataLocal' then return config:path('data-local') end
  if name == 'writableDataDir' then return writable(config) end

  return nil
end

local Meta = table.freeze { __index = property }

local function fromConfig(config: configuration.Config): Context
  local context = (setmetatable(table.clone(Methods), Meta) :: unknown) :: Context
  states[context] = { config = config, generation = config:generation() }
  table.freeze(context)
  return context
end

local function new(path: string, options: configuration.Options?): Context
  return fromConfig(configuration.new(path, options))
end

local function namesIn(directory: string): { string }
  local names, message, kind = fs.list(directory)
  if not names and kind == 'notFound' then return {} end

  return assert(names, message)
end

local function isFile(path: string): boolean
  local info, message = fs.stat(path)
  if message then error(message, 0) end

  return info ~= nil and info.isFile
end

local function topLevel(state: State): { [string]: string }
  if state.topLevel then return state.topLevel end

  local result: { [string]: string } = {}
  for _, directory in state.config:dataDirectories() do
    for _, name in namesIn(directory) do
      local path = jess.fs.join(directory, name)
      if isFile(path) then result[string.lower(name)] = path end
    end
  end

  state.topLevel = result
  return result
end

local function inDataDirectories(config: configuration.Config, name: string): boolean
  for _, directory in config:dataDirectories() do
    for _, file in namesIn(directory) do
      if string.lower(file) == string.lower(name) and isFile(jess.fs.join(directory, file)) then
        return true
      end
    end
  end

  return false
end

function Methods.configuration(self: Context): configuration.Config return stateOf(self).config end

function Methods.resolve(self: Context, path: string): string?
  local state = stateOf(self)
  if path ~= '' and not string.find(path, '[/\\]') then return topLevel(state)[string.lower(path)] end

  if not state.loose then state.loose = vfs.VFS.fromDirectories(state.config:dataDirectories()) end

  local found = (state.loose :: vfs.VFS):getFile(path)
  return if found then found:path() else nil
end

function Methods.content(self: Context): { ContentEntry }
  local result: { ContentEntry } = {}
  for _, name in stateOf(self).config:values('content') do
    table.insert(result, { name = name, path = self:resolve(name) })
  end

  return result
end

function Methods.vfs(self: Context): vfs.VFS
  local config = stateOf(self).config
  return vfs.VFS.fromDirectories(config:dataDirectories(), { archives = config:values('fallback-archive') })
end

function Methods.readFile(self: Context, path: string): buffer?
  local state = stateOf(self)
  if not state.full then state.full = self:vfs() end

  local file = (state.full :: vfs.VFS):getFile(path)
  return if file then file:readAllBuffer() else nil
end

function Methods.refresh(self: Context)
  local state = stateOf(self)
  state.topLevel, state.loose, state.full = nil, nil, nil
end

local function forced(options: { force: boolean? }?): boolean
  local selected: { force: boolean? } = options or {}
  for name in (selected :: unknown) :: { [string]: unknown } do
    assert(name == 'force', `dreamwind.openmw: unknown activation option '{name}'`)
  end

  assert(selected.force == nil or type(selected.force) == 'boolean', 'dreamwind.openmw: force needs a boolean')
  return selected.force == true
end

function Methods.activateAll(self: Context, names: { string }, options: { force: boolean? }?): { string }
  local config = stateOf(self).config
  local force = forced(options)
  local active: { [string]: boolean } = {}
  for _, name in config:values('content') do active[string.lower(name)] = true end

  local additions: { string } = {}
  for _, name in names do
    grammar.validate('content', name, config:userFile(), 0)
    local key = string.lower(name)
    if active[key] then continue end

    if not force and not inDataDirectories(config, name) then
      error(`dreamwind.openmw: '{name}' isn't in the data folders; check the name, or pass \{ force = true \}`, 0)
    end

    active[key] = true
    table.insert(additions, name)
  end

  for _, name in additions do config:append('content', name) end

  return additions
end

function Methods.activate(self: Context, name: string, options: { force: boolean? }?): boolean
  return #self:activateAll({ name }, options) > 0
end

function Methods.deactivate(self: Context, name: string): boolean
  local config = stateOf(self).config
  local changed = false
  for _, active in config:values('content') do
    if string.lower(active) == string.lower(name) then
      changed = config:remove('content', active) or changed
    end
  end

  return changed
end

function Methods.save(self: Context): { path: string, backup: string? }
  return stateOf(self).config:saveUser({ backup = true })
end

table.freeze(Methods)

return table.freeze { new = new, fromConfig = fromConfig }
