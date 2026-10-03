--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
-- The filesystem questions the import asks, each one host call.
local host = require('@dream/vfs').host

local function stat(path: string) return jess.fs.stat(path) end

--- The canonical path, or `path` itself when it can't be resolved, as dream-ini keeps it. A path
--- that isn't there is answered without asking, since `host.canonicalize` would throw for it;
--- `exists` says so when the caller already knows.
local function canonical(path: string, exists: boolean?): string
  if exists == false or (exists == nil and not jess.fs.exists(path)) then return path end

  -- `host.canonicalize` still throws for a path that exists but can't be read, or that vanished
  -- since the check; dream-ini keeps the path as given then.
  local success, resolved = pcall(host.canonicalize, path)
  return if success then resolved else path
end

local function resolve(path: string, base: string?): string
  if not base then return path end

  return jess.fs.join(base, path)
end

--- Whether `path` is relative under the host's rules: joining it to a folder changes it.
local function isRelative(path: string): boolean return jess.fs.join('.', path) ~= path end

return table.freeze { canonical = canonical, stat = stat, resolve = resolve, isRelative = isRelative }
