--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The load order a save is checked or stripped against: the active content files (and where each is
on disk), how a content file name resolves through the data folders, and the code page content is
read in. `fromOpenMw` makes one from an `@dreamwind/openmw` Context; scripts that hold the files
some other way build one themselves.
]]

local intern = require '@dream/intern'
local openmw = require '@dreamwind/openmw'
local tes3 = require '@dreamwind/tes3'

export type Content = { name: string, path: string? }

export type LoadOrder = {
  --- The active content files, in load order.
  content: { Content },
  --- The file a content name resolves to through the data folders, or nil.
  resolve: (name: string) -> string?,
  --- A resolved file's bytes; `jess.fs.readBuffer` when missing.
  read: ((path: string) -> (string | buffer)?)?,
  --- The code page content is read in (the config's `encoding=`); the save's when nil.
  encoding: string?,
}

--- The load order an `@dreamwind/openmw` Context describes.
local function fromOpenMw(context: openmw.Context): LoadOrder
  local content = context:content()
  local names: { [string]: string } = {}
  for _, entry in content do
    if entry.path then names[entry.path] = entry.name end
  end

  return {
    content = content,
    resolve = function(name: string): string?
      local path = context:resolve(name)
      if path then names[path] = name end

      return path
    end,
    -- Context reads VFS-relative names; LoadOrder readers receive resolved physical paths.
    read = function(path: string): buffer?
      local name = names[path]
      if name then return context:readFile(name) end

      return jess.fs.readBuffer(path)
    end,
    encoding = context.encoding,
  }
end

--- Content files already opened, by path and code page, and why the ones that didn't open didn't.
export type Cache = { [string]: { plugin: tes3.Plugin?, problem: string? } }

local openContent: (order: LoadOrder, path: string, encoding: string, cache: Cache?) -> (tes3.Plugin?, string?)

--- Opens the content file at `path` in `encoding` (no cache), or says why it couldn't.
local function openUncached(
  order: LoadOrder,
  path: string,
  encoding: string
): (tes3.Plugin?, string?)
  local reader = order.read
  local bytes = if reader then reader(path) else jess.fs.readBuffer(path)
  if not bytes then
    return nil, `failed to read '{path}': No such file or directory (os error 2)`
  end

  -- tes3.open throws on a file that doesn't frame; that's the reason.
  local ok, opened = pcall(
    function(): tes3.Plugin return tes3.open(bytes, { encoding = encoding }) end
  )
  if not ok then return nil, `failed to parse '{path}': {opened}` end

  return opened :: tes3.Plugin, nil
end

--- Reads and opens the content file at `path` in `encoding`, or says why it couldn't, as
--- jess-save's `read_content_file` does; with a cache, each path and code page once.
openContent = function(
  order: LoadOrder,
  path: string,
  encoding: string,
  cache: Cache?
): (tes3.Plugin?, string?)
  if not cache then return openUncached(order, path, encoding) end

  local key = `{encoding}\0{path}`
  local found = cache[key]
  if not found then
    local plugin, problem = openUncached(order, path, encoding)
    found = { plugin = plugin, problem = problem }
    cache[key] = found
  end

  return found.plugin, found.problem
end

export type Pool = dream_intern_Pool

--- A pool for one check or strip: ids compare as jess-save compares them, ASCII case ignored and
--- every other byte exact, in the content files' code page.
local function pool(): Pool return intern.new 'ascii-nocase' end

export type Ids = {
  --- Each record's id as a token of the pool, or false for one without (record `k` at `k + 1`).
  tokens: { number | false },
  --- Each record's type, as a number.
  codes: { number },
}

local IdCache: { [tes3.Plugin]: { pool: Pool, ids: Ids } } = setmetatable({}, { __mode = 'k' }) :: any

--- Every record's id (interned in `ids`, straight from the file's bytes: no string is made) and
--- type in a content file, read once however many scans ask: a strip's target scan, provenance,
--- and check all walk the same files.
local function ids(plugin: tes3.Plugin, ids: Pool): Ids
  local found = IdCache[plugin]
  if found and found.pool == ids then return found.ids end

  local count = plugin:count()
  local tokens: { number | false }, codes: { number } = {}, {}
  for k = 0, count - 1 do
    local source, at, length = tes3.records.idSpan(plugin, k)
    tokens[k + 1] = if source then ids:intern(source, at, length) else false
    codes[k + 1] = plugin:code(k)
  end

  local result = { tokens = tokens, codes = codes }
  IdCache[plugin] = { pool = ids, ids = result }
  return result
end

--- The token of an id a save holds (UTF-8) among content ids read in `encoding`, or nil when no
--- content id is spelled that way; `add` interns it. An id the code page can't spell is no content
--- file's, and a NUL before it keeps it apart from every id one can (no content id holds a NUL).
local function token(ids: Pool, id: string, encoding: string, add: boolean?): number?
  local encoded = tes3.text.encode(id, encoding)
  local key = encoded or '\0' .. id
  if add then return ids:intern(key) end

  return ids:find(key)
end

return table.freeze {
  fromOpenMw = fromOpenMw,
  ids = ids,
  openContent = openContent,
  pool = pool,
  token = token,
}
