--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Reading saves (jess-save's `info`): OpenMW (`.omwsave`) and Morrowind (`.ess`) saves, both TES3
files. An OpenMW save has a SAVE record after its TES3 header; a Morrowind save keeps its metadata
in the header itself (GMDT, SCRD, SCRS; `ESM::Header::load` in OpenMW's
`components/esm3/loadtes3.cpp`). Errors read as jess-save's do.
]]

local tes3 = require '@dreamwind/tes3'

type Plugin = tes3.Plugin

export type Game = 'openmw' | 'morrowind'

export type Save = {
  plugin: Plugin,
  game: Game,
  --- What errors and reports call it: its path, or the name it was given.
  name: string,
  path: string?,
}

export type Options = {
  --- Insist on one kind of save; by default it's detected.
  game: Game?,
  --- The save's code page; `win1252` by default.
  encoding: string?,
  --- What errors call the save (a path, usually); `save` by default.
  name: string?,
}

local Articles: { [Game]: string } = { openmw = 'an OpenMW', morrowind = 'a Morrowind' }
local Names: { [Game]: string } = { openmw = 'OpenMW', morrowind = 'Morrowind' }

local SAVE, TES3, GMDT = tes3.tags.code 'SAVE', tes3.tags.code 'TES3', tes3.tags.code 'GMDT'

--- What kind of save `plugin` is, or nil: an OpenMW save has a SAVE record, a Morrowind save a
--- GMDT subrecord in its header.
local function detect(plugin: Plugin): Game?
  for i = 0, plugin:count() - 1 do
    if plugin:code(i) == SAVE then return 'openmw' end
  end

  if plugin:count() > 0 and plugin:code(0) == TES3 and plugin:findSubrecord(0, GMDT) then
    return 'morrowind'
  end

  return nil
end

--- A save from its bytes, as `options.game` or whichever kind it is.
local function parse(bytes: buffer | string, options: Options?): Save
  local given: Options = options or {}
  local name = given.name or 'save'
  -- tes3.open throws on bytes that don't frame; that's the error to report.
  local ok, opened = pcall(
    function(): Plugin return tes3.open(bytes, { encoding = given.encoding }) end
  )
  if not ok then error(`failed to parse '{name}': {opened}`, 0) end

  local plugin = opened :: Plugin
  local detected = detect(plugin)
  if not detected or (given.game and given.game ~= detected) then
    if given.game then error(`'{name}' isn't {Articles[given.game]} save`, 0) end

    error(`'{name}' isn't an OpenMW or Morrowind save`, 0)
  end

  local game = detected :: Game
  plugin.profile = if game == 'openmw' then 'omwsave' else 'raw'
  return { plugin = plugin, game = game, name = name }
end

--- The save at `path`.
local function open(path: string, options: Options?): Save
  local bytes = jess.fs.readBuffer(path)
  if not bytes then error(`failed to read '{path}': No such file or directory (os error 2)`, 0) end

  local given: Options = if options then table.clone(options) else {}
  given.name = path
  local save = parse(bytes, given)
  save.path = path
  return save
end

--- Refuses `operation` on anything but an OpenMW save.
local function requireOpenMw(save: Save, operation: string)
  if save.game ~= 'openmw' then
    error(`save {operation} isn't supported for {Names[save.game]} saves`, 0)
  end
end

export type Info = {
  format: Game,
  formatVersion: number?,
  description: string,
  player: { name: string, level: number?, classId: string?, className: string? },
  cell: string,
  inGameTime: { gameHour: number, day: number, month: number, year: number },
  timePlayed: number?,
  dependencies: { string },
  screenshotBytes: number,
  currentDay: number?,
  currentHealth: number?,
  maximumHealth: number?,
}

local function metadata<T>(save: Save, read: () -> T): T
  -- The readers throw on metadata that doesn't read; that's the error to report.
  local ok, value = pcall(read)
  if not ok then error(`failed to read the save metadata of '{save.name}': {value}`, 0) end

  return value
end

--- GMDT: health, maximum health, and hour as floats, 12 unknown bytes, the cell name (64 bytes),
--- 4 unknown bytes, and the player's name (32 bytes) (`ESM::GMDT`, loadtes3.hpp).
local GmdtLength = 124

local function morrowindInfo(plugin: Plugin): Info
  local header = plugin:header()
  local masters = plugin:masters()
  local source, at, size = plugin:findSubrecord(0, GMDT)
  local gmdt = if source and size >= GmdtLength then source else nil
  local function text(offset: number, length: number): string
    local raw = buffer.readstring(gmdt :: buffer, at + offset, length)
    return tes3.text.decodeString(raw, plugin.encoding)
  end

  local scrs, _, scrsSize = plugin:findSubrecord(0, tes3.tags.code 'SCRS')
  local screenshotBytes = if scrs then scrsSize else 0

  local GLOB, NAME, FLTV = tes3.tags.code 'GLOB', tes3.tags.code 'NAME', tes3.tags.code 'FLTV'
  local function global(name: string): number?
    for i = 0, plugin:count() - 1 do
      if plugin:code(i) ~= GLOB then continue end

      local id, idAt, idSize = plugin:findSubrecord(i, NAME)
      if not id then continue end

      local raw = buffer.readstring(id :: buffer, idAt, idSize)
      local nul = string.find(raw, '\0', 1, true)
      if nul then raw = string.sub(raw, 1, nul - 1) end

      if string.lower(raw) ~= string.lower(name) then continue end

      local value, valueAt, valueSize = plugin:findSubrecord(i, FLTV)
      if not value or valueSize < 4 then return nil end

      return buffer.readf32(value :: buffer, valueAt)
    end

    return nil
  end

  -- Globals hold whole numbers in floats; truncating drops only a fraction there isn't.
  local function globalInt(name: string): number
    local value = global(name)
    if not value or value ~= value then return 0 end

    return if value < 0 then math.ceil(value) else math.floor(value)
  end

  -- The player's level and class are on the `player` NPC_ record, as OpenMW's importer reads
  -- them (apps/essimporter/converter.hpp, ConvertNPC).
  local NPC_ = tes3.tags.code 'NPC_'
  local player: { [string]: any }? = nil
  for i = 0, plugin:count() - 1 do
    if plugin:code(i) ~= NPC_ then continue end

    -- A record that doesn't decode isn't the player's, as far as the header goes.
    local ok, value = pcall(plugin.decode, plugin, i)
    if ok and value and string.lower(value.id :: string) == 'player' then
      player = value :: any
      break
    end
  end

  local class = player and player.class
  local dependencies = {}
  for _, master in masters do
    table.insert(dependencies, master.name)
  end

  return {
    format = 'morrowind',
    description = header.description,
    player = {
      name = if gmdt then text(92, 32) else '',
      level = player and player.data.level,
      classId = if class and class ~= '' then class else nil,
    },
    cell = if gmdt then text(24, 64) else '',
    inGameTime = {
      gameHour = if gmdt then buffer.readf32(gmdt, at + 8) else global 'GameHour' or 0,
      day = globalInt 'Day',
      month = globalInt 'Month',
      year = globalInt 'Year',
    },
    dependencies = dependencies,
    screenshotBytes = screenshotBytes,
    currentHealth = if gmdt then buffer.readf32(gmdt, at) else nil,
    maximumHealth = if gmdt then buffer.readf32(gmdt, at + 4) else nil,
  }
end

--- The save's metadata, whichever game wrote it.
local function info(save: Save): Info
  if save.game == 'morrowind' then
    return metadata(save, function(): Info return morrowindInfo(save.plugin) end)
  end

  local profile = metadata(
    save,
    function(): tes3.SaveProfile return tes3.save.profile(save.plugin) end
  )
  return {
    format = 'openmw',
    formatVersion = profile.formatVersion,
    description = profile.description,
    player = {
      name = profile.playerName,
      level = profile.playerLevel,
      classId = profile.playerClassId,
      className = profile.playerClassName,
    },
    cell = profile.playerCellName,
    inGameTime = profile.inGameTime,
    timePlayed = profile.timePlayed,
    dependencies = profile.dependencies,
    screenshotBytes = profile.screenshotLength,
    currentDay = profile.currentDay,
    currentHealth = profile.currentHealth,
    maximumHealth = profile.maximumHealth,
  }
end

--- Morrowind's screenshot: 128 by 128 BGRA pixels (SCRS; openmw apps/essimporter/importer.cpp).
local MorrowindScreenshotSide = 128

--- An uncompressed 24-bit TGA of BGRA pixels (top row first), dropping the alpha Morrowind
--- doesn't fill in.
local function bgraToTga(source: buffer, at: number, side: number): buffer
  local pixels = side * side
  local out = buffer.create(18 + pixels * 3)
  -- No image id or color map, true color, origin (0, 0), 24 bits per pixel, top-left origin.
  buffer.writeu8(out, 2, 2)
  buffer.writeu16(out, 12, side)
  buffer.writeu16(out, 14, side)
  buffer.writeu8(out, 16, 24)
  buffer.writeu8(out, 17, 0x20)
  for i = 0, pixels - 1 do
    buffer.copy(out, 18 + i * 3, source, at + i * 4, 3)
  end

  return out
end

--- The save's screenshot as an image file and its format: OpenMW saves store a JPEG, Morrowind
--- saves raw pixels, which become a TGA.
local function screenshot(save: Save): (buffer, 'jpeg' | 'tga')
  if save.game == 'openmw' then
    return metadata(save, function(): buffer return tes3.save.screenshot(save.plugin) end), 'jpeg'
  end

  local plugin = save.plugin
  local source: buffer?, at, size = nil, 0, 0
  if plugin:count() > 0 and plugin:code(0) == TES3 then
    source, at, size = plugin:findSubrecord(0, tes3.tags.code 'SCRS')
  end

  if not source then error(`'{save.name}' has no screenshot`, 0) end

  local side = MorrowindScreenshotSide
  if size ~= side * side * 4 then
    error(`'{save.name}' has a {size}-byte screenshot; Morrowind's are {side * side * 4} bytes`, 0)
  end

  return bgraToTga(source :: buffer, at, side), 'tga'
end

export type LuaDataRow = { record: number, type: string, value: tes3.LuaValue?, error: string? }

--- Every LUAD payload decoded, or why it couldn't be.
local function luaData(save: Save): { LuaDataRow }
  local plugin = save.plugin
  local out = {}
  for i = 0, plugin:count() - 1 do
    local source = plugin:span(i)
    for _, sub in plugin:subrecords(i) do
      if sub.tag ~= 'LUAD' then continue end

      -- decodeLuaData throws on a payload that isn't serialized Lua; the row says why.
      local ok, value = pcall(tes3.save.decodeLuaData, source, sub.payload, sub.size)
      if ok then
        table.insert(out, { record = i, type = plugin:tag(i), value = value })
      else
        table.insert(out, { record = i, type = plugin:tag(i), error = tostring(value) })
      end
    end
  end

  return out
end

return table.freeze {
  detect = detect,
  info = info,
  luaData = luaData,
  open = open,
  parse = parse,
  requireOpenMw = requireOpenMw,
  screenshot = screenshot,
}
