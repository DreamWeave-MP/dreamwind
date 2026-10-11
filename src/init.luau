--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
--[[
@dreamwind: DreamWind's command line, one command over the tools its packages bring.

  run(argv) -> exit status

  dreamwind vfstool <arguments...>
  dreamwind starwind <arguments...>
  dreamwind s3lightfixes <arguments...>
  dreamwind merged-lands <arguments...>
  dreamwind tes3merge <arguments...>
  dreamwind doctor <arguments...>
  dreamwind help

The first argument names a tool. Everything after it is that tool's own command line, handed
over unread, and the tool's exit status comes back unchanged.

Exit statuses: 0 for `help`, 8 when no tool or an unknown tool is named, and otherwise the
tool's. Messages go to standard error as `dreamwind: <message>`.
]]

local process = require '@dream/process'

local Exit = table.freeze { ok = 0, invalidInput = 8 }

local Usage = [[
dreamwind: DreamWind's tools under one command

  dreamwind vfstool <arguments...>
  dreamwind starwind <arguments...>
  dreamwind s3lightfixes <arguments...>
  dreamwind merged-lands <arguments...>
  dreamwind tes3merge <arguments...>
  dreamwind doctor <arguments...>
  dreamwind help

Everything after a tool's name is that tool's own command line, and its exit status is the
command's: `dreamwind starwind help` is `starwind help`.

  vfstool       OpenMW's virtual file system: a load order's files and where they come from
  starwind      the Starwind Merged Plugin Project's Definitive build
  s3lightfixes  S3LightFixes: a load order's lights and ambient values adjusted in one plugin
  merged-lands  Merged Lands: a load order's landscape edits merged into one plugin
  tes3merge     TES3Merge: a load order's conflicting records merged into one plugin
  doctor        a load order's problems: masters, content, assets, meshes, dirt, and conflicts

Exit status: 0 for help, 8 when no tool or an unknown tool is named, otherwise the tool's.]]

-- A tool's command line, by the name it is called under. Each is required where it is named, so
-- naming one loads nothing of the others.
local Tools: { [string]: (arguments: { string }) -> number } = {
  vfstool = function(arguments) return require('@vfstool').run(arguments) end,
  starwind = function(arguments) return require('@starwind/cli').run(arguments) end,
  s3lightfixes = function(arguments) return require('@s3lightfixes/cli').run(arguments) end,
  ['merged-lands'] = function(arguments) return require('@merged-lands/cli').run(arguments) end,
  tes3merge = function(arguments) return require('@tes3merge/cli').run(arguments) end,
  doctor = function(arguments) return require('@doctor/cli').run(arguments) end,
}

local function out(text: string) process.write('stdout', `{text}\n`) end

local function err(text: string) process.write('stderr', `{text}\n`) end

local function usage(message: string): number
  err(`dreamwind: {message}`)
  return Exit.invalidInput
end

local function run(argv: { string }): number
  local tool = argv[1]

  if not tool then return usage('a tool is required') end

  if tool == 'help' or tool == '--help' or tool == '-h' then
    out(Usage)
    return Exit.ok
  end

  local command = Tools[tool]

  if not command then return usage(`unknown tool '{tool}'`) end

  -- A list of the tool's own: vfstool takes the one it is given apart as it reads it.
  return command(table.move(argv, 2, #argv, 1, {}))
end

return table.freeze { run = run }
