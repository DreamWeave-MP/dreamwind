--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Writing edited plugins back (jess-plugin's `files`): an output that isn't the input, a backup of
whatever a write replaces, and converting between `.esp` and `.esm` the way tes3cmd's `esp` and
`esm` do.
]]

local tes3 = require '@dreamwind/tes3'

export type Written = { path: string, backup: string? }

--- Refuses an edit's `output` when it's its `input`: writing over the input is what leaving the
--- output out is for, and that makes a backup.
local function checkOutput(input: string, output: string?)
  if output and output == input then error('output must differ from resolved input', 0) end
end

--- Writes `bytes` to `output`, or over `input`, backing up what it replaces unless `backup` is
--- false: the first of `<path>.bak`, `<path>.bak1`, ... that doesn't exist. Missing folders are
--- created.
local function writeUpdate(
  input: string,
  output: string?,
  bytes: buffer,
  backup: boolean?
): Written
  return jess.fs.write(output or input, bytes, { backup = backup ~= false })
end

local Extensions: { [tes3.FileType]: string } = { master = 'esm', plugin = 'esp', save = 'ess' }

--- `path` with the extension `fileType` calls for: `.esm`, `.esp`, or `.ess`.
local function convertedPath(path: string, fileType: tes3.FileType): string
  local name = string.match(path, '[^/\\]*$') :: string
  local stem = string.match(name, '^(.+)%.[^.]*$')
  local base = string.sub(path, 1, #path - #name)
  return `{base}{stem or name}.{Extensions[fileType]}`
end

export type ConvertOptions = {
  --- Where to write; next to the input with the new extension by default.
  output: string?,
  --- Replace a file already at the output.
  overwrite: boolean?,
  --- Back up a replaced file first (the default).
  backup: boolean?,
  --- Convert in memory, but write nothing.
  dryRun: boolean?,
}

export type Converted =
  { input: string, fileType: tes3.FileType, output: string, written: Written? }

--- Converts the plugin at `input` to a master (`fileType = 'master'`) or back. The input must have
--- the other type's extension, and only the header's file type changes.
local function convert(input: string, fileType: tes3.FileType, options: ConvertOptions?): Converted
  local given: ConvertOptions = options or {}
  if fileType == 'save' then error('can\'t convert to a save', 0) end

  local expected = if fileType == 'master' then 'esp' else 'esm'
  local extension = string.match(input, '%.([^./\\]*)$')
  if not extension or string.lower(extension) ~= expected then
    error(`input must be a .{expected} file`, 0)
  end

  local output = given.output or convertedPath(input, fileType)
  checkOutput(input, output)
  if jess.fs.exists(output) and not given.overwrite then error(`{output} already exists`, 0) end

  local bytes = jess.fs.readBuffer(input)
  if not bytes then error(`failed to read '{input}': no such file`, 0) end

  -- tes3.open throws on a file that doesn't frame; that's the error to report.
  local ok, opened = pcall(function(): tes3.Plugin return tes3.open(bytes) end)
  if not ok then error(`failed to parse '{input}': {opened}`, 0) end

  local plugin = opened :: tes3.Plugin
  plugin:setFileType(fileType)
  local written = if given.dryRun
    then nil
    else writeUpdate(output, nil, plugin:save(), given.backup)
  return { input = input, fileType = fileType, output = output, written = written }
end

return table.freeze {
  checkOutput = checkOutput,
  convert = convert,
  convertedPath = convertedPath,
  writeUpdate = writeUpdate,
}
