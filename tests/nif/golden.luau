--!nonstrict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Holds the NIF modules to their frozen answers. For each file, each suite observes what the port
makes of it (the Morrowind model's records and saves, the multi-version reader's records, check,
info, the scene, and fix) as one canonical text, and keeps its xxh3 digest. A fixture's case is
`fixture/<file>/<suite>`; each building and editing scenario's save (`edit_differential.luau`)
is `edit/<scenario>`; a real archive's is `real/<archive>#<size>/<suite>`, one digest over
every file in it in order, named by file name and size so the same archive is the same case
wherever it is, plus its `assets/check` and `assets/info` reports over the archive as an input.

The answers were frozen while jess linked jess-nif: blessing a case (`bless`) first holds every
file in it to jess-nif through the differential suites, and records nothing a difference was
found in. A case with no golden fails unless blessing; blessing never changes one that's there.

Settings come in as globals: `goldenPath`, `fixtures` (a folder of `.nif` files), `archives`
(paths, one per line, optional), and `bless`.
]]

local Array = require '../../src/nif/internal/array'
local Assets = require '../../src/nif/internal/assets'
local Check = require '../../src/nif/internal/check'
local Fix = require '../../src/nif/internal/fix'
local Header = require '../../src/nif/internal/header'
local Info = require '../../src/nif/internal/info'
local Nif = require '../../src/nif/init'
local Reader = require '../../src/nif/internal/gamebryo/reader'
local Scene = require '../../src/nif/internal/scene'
local bytes = require '@dream/bytes'

local settings = _G :: any

--- What a canonical text replaces the archive's own path with, so a report doesn't depend on
--- where the archive is.
local Place = { path = nil :: string?, name = '' }

--- A canonical text fed in pieces to an xxh3 hasher.
type Sink = { hasher: any, parts: { string } }

local function newSink(): Sink return { hasher = bytes.hasher 'xxh3', parts = {} } end

local function put(sink: Sink, text: string)
  local parts = sink.parts
  parts[#parts + 1] = text
  if #parts >= 4096 then
    sink.hasher:update(table.concat(parts))
    table.clear(parts)
  end
end

local function finish(sink: Sink): string
  sink.hasher:update(table.concat(sink.parts))
  table.clear(sink.parts)
  return sink.hasher:finish()
end

local function number(value: number): string
  if value ~= value then return 'nan' end

  if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
    return string.format('%d', value)
  end

  return string.format('%.17g', value)
end

local function keyText(key: unknown): string
  return if type(key) == 'number' then `#{number(key)}` else tostring(key)
end

--- Feeds `value` to `sink` canonically: tables by sorted key, sequences that build elements on
--- demand by element, array views by their bytes, functions not at all.
local function feed(sink: Sink, value: unknown)
  local kind = type(value)
  if kind == 'nil' then
    put(sink, 'n;')
  elseif kind == 'boolean' then
    put(sink, if value then 't;' else 'f;')
  elseif kind == 'number' then
    put(sink, number(value :: number) .. ';')
  elseif kind == 'string' then
    local text = value :: string
    if Place.path and text == Place.path then text = Place.name end

    put(sink, `s{#text}:`)
    put(sink, text)
  elseif kind == 'vector' then
    local v = value :: vector
    put(sink, `v{number(v.x)},{number(v.y)},{number(v.z)};`)
  elseif kind == 'buffer' then
    local b = value :: buffer
    put(sink, `b{buffer.len(b)}:`)
    put(sink, buffer.tostring(b))
  elseif kind == 'table' then
    local t = value :: any
    if Array.isArray(t) then
      local length = t.count * t.stride
      put(sink, `a{t.count}x{t.stride}:`)
      put(sink, buffer.readstring(t.buffer, t.offset, length))
      return
    end

    local meta = getmetatable(t)
    if meta and meta.__len then
      local count = #t
      put(sink, `l{count}[`)
      for i = 1, count do
        feed(sink, t[i])
      end

      put(sink, ']')
      return
    end

    local keys = {}
    for key, entry in t do
      if type(entry) ~= 'function' then table.insert(keys, key) end
    end

    table.sort(
      keys,
      function(left: unknown, right: unknown): boolean return keyText(left) < keyText(right) end
    )
    put(sink, '{')
    for _, key in keys do
      put(sink, keyText(key) .. '=')
      feed(sink, t[key])
    end

    put(sink, '}')
  end
end

local function digest(value: unknown): string
  local sink = newSink()
  feed(sink, value)
  return finish(sink)
end

--- A call's answer, or what it threw, as a value to digest.
local function attempt(f: () -> unknown): unknown
  local ok, result = pcall(f)
  if ok then return result end

  return {
    error = if type(result) == 'table'
      then result.message or tostring(result)
      else tostring(result),
  }
end

--- Each suite's digest of what the port makes of one file.
local function observe(data: buffer, path: string): { [string]: string }
  local found = {}
  found.check = digest(attempt(function() return Check.check(path, data) end))

  found.gamebryo = digest(attempt(function()
    local file = Reader.open(data)
    return {
      records = file.records,
      names = file.names,
      classes = file.classes,
      recordTypes = file.recordTypes,
      roots = file.roots,
    }
  end))

  local parsed, header = pcall(Header.parse, data)
  local morrowind = parsed and header.version == Header.versions.morrowind
  if not morrowind then
    found.info = digest(attempt(function()
      local file = Reader.open(data)
      return { counts = Info.fileTypeCounts(file), tree = Info.fileSceneTree(file) }
    end))
    return found
  end

  found.info = digest(attempt(function()
    local nif = Nif.open(data)
    return { counts = Info.recordTypeCounts(nif), tree = Info.sceneTree(nif) }
  end))

  found.morrowind = digest(attempt(function()
    local nif = Nif.open(data)
    local untouched = bytes.xxh3(nif:save())
    local records = {}
    for i = 0, nif.count - 1 do
      records[i + 1] = nif:record(i)
    end

    return { roots = nif.roots, records = records, untouched = untouched, saved = nif:save() }
  end))

  found.scene = digest(attempt(function() return Scene.build(Nif.open(data)) end))

  found.fix = digest(attempt(function()
    local nif = Nif.open(data)
    local fixed = Fix.fix(nif)
    return { fixed = fixed, saved = nif:save() }
  end))
  return found
end

local Suites = table.freeze { 'morrowind', 'gamebryo', 'check', 'info', 'scene', 'fix' }

--- What jess-nif says differs from the port on one file, through every differential suite; for
--- blessing only.
local function verify(data: buffer, path: string): { string }
  local problems = {}
  local function add(suite: string, list: { string })
    for _, problem in list do
      table.insert(problems, `{suite}: {problem}`)
    end
  end

  add('gamebryo', (require './gamebryo_differential').check(data, path))
  add('check', (require './check_differential').check(data, path))
  add('info', (require './info_differential').check(data, path))
  if pcall(jess.nif.openBytes, data) then
    add('morrowind', (require './differential').check(data))
    add('scene', (require './scene_differential').check(data, path))
  end

  return problems
end

local function run(): { failures: { string }, cases: number, recorded: number }
  local goldenPath = settings.goldenPath :: string
  local bless = settings.bless == true
  local golden: { [string]: string } = {}
  local text = jess.fs.read(goldenPath)
  if text then
    for name, value in string.gmatch(text, '([^\t\n]+)\t([^\n]+)') do
      golden[name] = value
    end
  end

  local failures, added, cases = {}, {}, 0
  local function case(name: string, value: string, check: (() -> { string })?)
    cases += 1
    local expected = golden[name]
    if expected then
      if expected ~= value then
        table.insert(failures, `{name}: {value} where the golden is {expected}`)
      end

      return
    end

    if not bless then
      table.insert(failures, `{name}: no golden; JESS_BLESS=1 records it once jess-nif agrees`)
      return
    end

    local problems = if check then check() else {}
    if #problems > 0 then
      table.insert(
        failures,
        `{name}: jess-nif disagrees, not blessed:\n  {table.concat(problems, '\n  ')}`
      )
      return
    end

    golden[name] = value
    table.insert(added, name)
  end

  for _, file in jess.fs.list(settings.fixtures) do
    if not string.find(string.lower(file), '%.nif$') then continue end

    local data = buffer.fromstring(jess.fs.read(jess.fs.join(settings.fixtures, file)) :: string)
    for suite, value in observe(data, file) do
      case(`fixture/{file}/{suite}`, value, function() return verify(data, file) end)
    end
  end

  -- Building and editing: each scenario's save.
  local Edits = require './edit_differential'
  for _, name in Edits.scenarios do
    local saved = Edits.build[name].port(settings.fixtures)
    case(`edit/{name}`, digest(saved), function() return Edits.run(name, settings.fixtures) end)
  end

  local Archive = require '@dreamwind/archive'
  for path in string.gmatch(settings.archives or '', '[^\n]+') do
    local name = `{string.match(path, '[^/\\]+$')}#{jess.fs.size(path)}`
    local opened = Archive.openPath(path)
    local sinks: { [string]: Sink } = {}
    for _, suite in Suites do
      sinks[suite] = newSink()
    end

    local problems = {}
    for index, entry in opened:entries() do
      local entryPath = entry.path
      if not entryPath or not string.find(string.lower(entryPath), '%.nif$') then continue end

      local data = buffer.fromstring(opened:readEntry(index))
      for _, suite in Suites do
        put(sinks[suite], `{entryPath}\t`)
      end

      for suite, value in observe(data, entryPath) do
        put(sinks[suite], value)
      end

      for _, suite in Suites do
        put(sinks[suite], '\n')
      end

      if bless then
        for _, problem in verify(data, entryPath) do
          table.insert(problems, `{entryPath}: {problem}`)
        end
      end
    end

    local function verified(): { string } return problems end

    for _, suite in Suites do
      case(`real/{name}/{suite}`, finish(sinks[suite]), verified)
    end

    Place.path, Place.name = path, name
    local reports = {
      check = Assets.check(Assets.sources(nil, nil, { path })),
      info = Assets.info(Assets.sources(nil, nil, { path })),
    }

    for kind, report in reports do
      case(
        `real/{name}/assets/{kind}`,
        digest(report),
        function() return if bless then (require './assets_differential').check { path } else {} end
      )
    end

    Place.path = nil
  end

  if #added > 0 then
    local names = {}
    for key in golden do
      table.insert(names, key)
    end

    table.sort(names)
    local lines = {}
    for _, key in names do
      table.insert(lines, `{key}\t{golden[key]}`)
    end

    jess.fs.write(goldenPath, table.concat(lines, '\n') .. '\n')
  end

  return { failures = failures, cases = cases, recorded = #added }
end

return table.freeze { run = run, observe = observe, digest = digest }
