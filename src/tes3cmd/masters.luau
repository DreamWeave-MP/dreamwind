--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Where a plugin's masters are (jess-plugin's `MasterSource`): checks that compare a plugin with its
masters find them through one of these, so the caller decides how names resolve.
]]

export type Source = {
  --- The master file's path, or nil when this source can't find it.
  locate: (name: string) -> string?,
  --- A located file's bytes, or nil when it's gone; `jess.fs.readBuffer` when missing.
  read: ((path: string) -> (string | buffer)?)?,
  --- A located file's size, or nil when it's gone; `jess.fs.size` when missing.
  size: ((path: string) -> number?)?,
}

--- The bytes of the master `path` names, read through `source`.
local function read(source: Source, path: string): (string | buffer)?
  local reader = source.read
  if reader then return reader(path) end

  return jess.fs.readBuffer(path)
end

--- The size of the master `path` names, through `source`.
local function size(source: Source, path: string): number?
  local sizer = source.size
  if sizer then return sizer(path) end

  local reader = source.read
  if reader then
    local bytes = reader(path)
    if not bytes then return nil end

    return if type(bytes) == 'string' then #bytes else buffer.len(bytes)
  end

  return jess.fs.size(path)
end

--- Masters held in memory, by file name (matched ignoring ASCII case), for scripts that already
--- have their bytes.
local function memory(files: { [string]: string | buffer }): Source
  local byName: { [string]: string } = {}
  for name in files do
    byName[string.lower(name)] = name
  end

  return {
    locate = function(name: string): string? return byName[string.lower(name)] end,
    read = function(path: string): (string | buffer)? return files[path] end,
  }
end

--- Finds nothing.
local function none(): Source
  return { locate = function(_name: string): string? return nil end }
end

--- A name that is a path to a file.
local function paths(): Source
  return {
    locate = function(name: string): string? return if jess.fs.isFile(name) then name else nil end,
  }
end

--- `source` first, then the folder `pluginPath` is in: the exact name, else one that differs
--- only in ASCII case. A name with a path separator only resolves through `source`.
local function beside(source: Source, pluginPath: string): Source
  local folder = jess.fs.parent(pluginPath) or '.'
  if folder == '' then folder = '.' end

  -- Paths `source` found read through it; the ones found beside the plugin are files.
  local inner: { [string]: boolean } = {}
  return {
    locate = function(name: string): string?
      local found = source.locate(name)
      if found then
        inner[found] = true
        return found
      end

      if string.find(name, '[/\\]') then return nil end

      local exact = jess.fs.join(folder, name)
      if jess.fs.isFile(exact) then return exact end

      if not jess.fs.isDir(folder) then return nil end

      local lower = string.lower(name)
      for _, entry in jess.fs.list(folder) do
        local path = jess.fs.join(folder, entry)
        if string.lower(entry) == lower and jess.fs.isFile(path) then return path end
      end

      return nil
    end,

    read = function(path: string): (string | buffer)?
      return if inner[path] then read(source, path) else jess.fs.readBuffer(path)
    end,

    size = function(path: string): number?
      return if inner[path] then size(source, path) else jess.fs.size(path)
    end,
  }
end

return table.freeze {
  beside = beside,
  memory = memory,
  none = none,
  paths = paths,
  read = read,
  size = size,
}
