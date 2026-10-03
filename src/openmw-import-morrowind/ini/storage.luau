--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
-- The filesystem questions the import asks, each one host call.
local fs = require '@dream/fs'
local bytes = require '@dream/bytes'

local function stat(path: string) return jess.fs.stat(path) end

--- The canonical path, or `path` itself when it can't be resolved, as dream-ini keeps it. A path
--- that isn't there is answered without asking; `exists` says so when the caller already knows.
local function canonical(path: string, exists: boolean?): string
  if exists == false or (exists == nil and not jess.fs.exists(path)) then return path end

  local resolved = fs.canonicalize(path)
  return resolved or path
end

local function resolve(path: string, base: string?): string
  if not base then return path end

  return jess.fs.join(base, path)
end

--- Whether `path` is relative under the host's rules: joining it to a folder changes it.
local function isRelative(path: string): boolean return jess.fs.join('.', path) ~= path end

local function ioMessage(path: string, message: string): string
  local displayPath = if utf8.len(path) then path else bytes.decode(path, 'utf-8')
  local operation = string.match(message, '^dream%.fs%.[^:]+: ')
  local prefix = if operation then operation .. displayPath .. ': ' else nil
  local reason = if prefix and string.sub(message, 1, #prefix) == prefix
    then string.sub(message, #prefix + 1)
    else message
  return `dream.ini: {displayPath}: {reason}`
end

return table.freeze {
  canonical = canonical,
  stat = stat,
  resolve = resolve,
  isRelative = isRelative,
  ioMessage = ioMessage,
}
