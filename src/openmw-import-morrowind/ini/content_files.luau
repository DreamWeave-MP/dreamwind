--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
-- Content files and fallback archives: the INI's sequential entries, resolved through the search
-- folders (explicit, then the cfg's, then the INI's `Data Files`), sorted the way the launcher
-- sorted them, with the folders that resolved something added to the cfg.
local types, parser, storage = require './types', require './parser', require './storage'
type MultiMap = types.MultiMap
type Request = types.Request
type Event = types.Event
type Warning = types.Warning
type Search = {
  path: string,
  value: string,
  origin: string,
  exists: boolean,
  searchable: boolean,
  --- `path` with a separator after it, built on first use, so each candidate is one concatenation.
  prefix: string?,
}

type Resolved = {
  name: string,
  lower: string,
  path: string,
  seconds: number,
  nanoseconds: number,
  search: number,
}
type Directory = { path: string, value: string }

--- The values of `{prefix}{N}` for `N = 0, 1, ...` up to the first missing index, keys compared
--- ASCII case-insensitively; only a canonical decimal is an index (`7`, never `07` or `+7`).
--- Several spellings of one index contribute their values in key order, as dream-ini's sorted
--- map hands them out.
local function sequential(ini: MultiMap, prefix: string): { string }
  local lowerPrefix, length = string.lower(prefix), #prefix
  local lower, upper = string.byte(lowerPrefix, 1), string.byte(string.upper(prefix), 1)
  local matching: { string } = {}

  for key, values in ini do
    local first = string.byte(key, 1)
    if first ~= lower and first ~= upper then continue end
    if #values == 0 or string.lower(string.sub(key, 1, length)) ~= lowerPrefix then continue end

    local tail = string.sub(key, length + 1)
    if tail ~= '0' and not string.match(tail, '^[1-9][0-9]*$') then continue end

    table.insert(matching, key)
  end

  table.sort(matching)
  local indexed: { [string]: { string } } = {}

  for _, key in matching do
    local values, tail = ini[key], string.sub(key, length + 1)
    local found = indexed[tail]

    if found then
      table.move(values, 1, #values, #found + 1, found)
    else
      indexed[tail] = table.clone(values)
    end
  end

  local result: { string } = {}
  local index = 0

  while indexed[tostring(index)] do
    local values = indexed[tostring(index)]
    table.move(values, 1, #values, #result + 1, result)
    index += 1
  end

  return result
end

local function unquote(path: string): string
  return if #path >= 2
      and string.sub(path, 1, 1) == '"'
      and string.sub(path, -1) == '"'
    then string.sub(path, 2, -2)
    else path
end

local function searchPaths(request: Request): { Search }
  local result: { Search } = {}

  local function add(path: string, value: string, origin: string)
    local metadata = storage.stat(path)
    table.insert(result, {
      path = path,
      value = value,
      origin = origin,
      exists = metadata ~= nil,
      searchable = metadata ~= nil and metadata.isDir,
    })
  end

  local base = request.dataDirBase

  for _, directory in request.dataDirs do
    local path = storage.canonical(storage.resolve(directory, base))
    -- With no base, a relative folder is written as resolved, since the cfg can't resolve it.
    local value = if not base and storage.isRelative(directory) then path else directory
    add(path, value, 'explicit')
  end

  for _, directory in request.cfg.data or {} do
    add(storage.resolve(unquote(directory), request.cfgDir), directory, 'config')
  end

  local default =
    storage.canonical(jess.fs.join(jess.fs.parent(request.iniPath) or '', 'Data Files'))
  add(default, default, 'default')
  return result
end

--- The cfg's `data=` folders, canonical: the searches of `config` origin, which resolved them.
local function configured(searches: { Search }): { [string]: boolean }
  local result: { [string]: boolean } = {}

  for _, search in searches do
    if search.origin == 'config' then
      result[storage.canonical(search.path, search.exists)] = true
    end
  end

  return result
end

--- The search folders that resolved a file and are neither the cfg's `data=` folders nor already
--- written, in first-hit order. The cfg's folders are canonicalized once, on first need.
local function usedDirectories(
  request: Request,
  searches: { Search },
  hits: { Resolved }
): { Directory }
  local result: { Directory } = {}
  local decided: { [number]: boolean } = {}
  local existing: { [string]: boolean }?

  for _, hit in hits do
    local search = searches[hit.search]
    if search.origin == 'config' or decided[hit.search] then continue end

    decided[hit.search] = true
    local canonical = storage.canonical(search.path, search.exists)
    local known = existing or configured(searches)
    existing = known
    if known[canonical] then continue end

    known[canonical] = true
    table.insert(result, { path = search.path, value = search.value })
  end

  return result
end

local function resolve(
  file: string,
  searches: { Search },
  events: { Event },
  archives: boolean,
  verbose: boolean
): Resolved?
  for index, search in searches do
    if not search.searchable then continue end

    local prefix = search.prefix or string.sub(jess.fs.join(search.path, 'x'), 1, -2)
    search.prefix = prefix
    local candidate = prefix .. file
    local metadata = storage.stat(candidate)
    if not metadata then continue end

    -- A content file's canonical path is part of its sort key; an archive's only feeds the event.
    local path = if not archives or verbose then storage.canonical(candidate, true) else candidate

    if verbose then
      table.insert(events, {
        kind = if archives then 'archiveResolved' else 'contentFileResolved',
        path = path,
        modified = if archives then nil else metadata.modifiedSeconds or 0,
      })
    end

    return {
      name = file,
      lower = string.lower(file),
      path = path,
      seconds = metadata.modifiedSeconds or 0,
      nanoseconds = metadata.modifiedNanoseconds or 0,
      search = index,
    }
  end

  return nil
end

local function isPluginName(file: string): boolean
  return not string.find(file, '/', 1, true)
    and not string.find(file, '\\', 1, true)
    and jess.fs.isFileName(file)
end

--- Vanilla order: masters first, then by modification time, then by name in reverse, ASCII
--- case-insensitively, then by path.
local function before(left: Resolved, right: Resolved): boolean
  local leftPlugin, rightPlugin =
    string.sub(left.lower, -4) ~= '.esm', string.sub(right.lower, -4) ~= '.esm'

  if leftPlugin ~= rightPlugin then return rightPlugin end
  if left.seconds ~= right.seconds then return left.seconds < right.seconds end
  if left.nanoseconds ~= right.nanoseconds then return left.nanoseconds < right.nanoseconds end
  if left.lower ~= right.lower then return left.lower > right.lower end

  return left.path < right.path
end

local function import(request: Request, archives: boolean)
  local searches = searchPaths(request)
  local events: { Event } = {}
  local warnings: { Warning } = {}
  local hits: { Resolved } = {}
  local missing: { string } = {}
  local files =
    sequential(request.ini, if archives then 'Archives:Archive ' else 'Game Files:GameFile')

  if archives then table.insert(files, 1, 'Morrowind.bsa') end

  for _, value in files do
    local file = parser.trim(value)
    local suffix = string.lower(string.sub(file, -4))

    if archives then
      if suffix ~= '.bsa' then continue end
    elseif suffix ~= '.esm' and suffix ~= '.esp' then
      continue
    end

    if not isPluginName(file) then
      error(
        if archives
          then `dream.ini: invalid fallback archive name: {file}; archive entries must be BSA filenames, not paths`
          else `dream.ini: invalid content file name: {file}; content entries must be plugin filenames, not paths`,
        0
      )
    end

    local hit = resolve(file, searches, events, archives, request.verbose)

    if hit then
      table.insert(hits, hit)
    elseif archives then
      table.insert(missing, file)
    else
      table.insert(warnings, {
        kind = 'missingGameFile',
        file = file,
        message = `GameFile entry not found: {file}. Later GameFile entries were not imported.`,
      })
      break
    end
  end

  if #missing > 0 then
    local paths: { string } = {}

    for _, search in searches do
      table.insert(paths, search.path)
    end

    error(
      `dream.ini: fallback archives not found: {table.concat(missing, ', ')}; searched: {table.concat(
        paths,
        ', '
      )}; pass --data or add data=... to the cfg`,
      0
    )
  end

  if not archives then table.sort(hits, before) end

  local directories = usedDirectories(request, searches, hits)

  for _, directory in directories do
    table.insert(events, {
      kind = if archives then 'dataDirAddedForArchive' else 'dataDirAddedForContent',
      path = directory.path,
    })
  end

  local names: { string } = {}

  for _, hit in hits do
    table.insert(names, hit.name)
  end

  return { names = names, directories = directories, events = events, warnings = warnings }
end

return table.freeze { import = import, sequential = sequential }
