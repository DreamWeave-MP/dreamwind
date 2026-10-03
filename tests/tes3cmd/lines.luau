--!strict
--!native
-- What dream.tes3cmd and jess-omwaddon's application logic answer for one plugin, operation by
-- operation, one canonical JSON line each: lint, clean, stats, readable values, byte layouts,
-- validation, selections and the edits they drive, header edits, and comparisons.
local bytes = require '@dream/bytes'
local canonical = require './../tes3/canonical'
local tes3 = require '@dreamwind/tes3'
local tes3cmd = require '@dreamwind/tes3cmd'

export type Lines = { string }

local native = (_G :: any).jess
local oracle = native and native.plugin

--- The selectors every fixture is put through.
local Specs: { tes3cmd.SelectorSpec } = {
  {},
  { type = 'STAT' },
  { type = { 'CELL', 'Npc' } },
  { id = '^dup' },
  { id = 'test_npc', notMatch = 'autocalc' },
  { exactId = { 'test_npc', '222', 'synthetic_cell' } },
  { match = 'nif' },
  { flags = 'persistent' },
  { flags = { 'deleted', 'blocked' } },
  { sub = 'id:' },
  { notSub = 'NAME' },
  { sub = 'MODL' },
  { instance = 'ref' },
  { notInstance = 'first' },
  { interior = true },
  { exterior = true },
}

--- The replacements every fixture is put through: an expression, and whether only the first match goes.
local Replacements: { { string | boolean } } = {
  { '/^/PC_/', false },
  { '/o/0/', true },
  { '/marker/chair/', false },
  { '/Old/New/', false },
}

local Profiles: { tes3.Profile } = { 'raw', 'tes3', 'omwaddon' }

local function md5(data: buffer): string return bytes.md5(data) end

--- A value, or the error raising it gave, as one line.
local function attempt(label: string, f: () -> unknown): string
  local ok, value = pcall(f)
  if ok then return canonical { op = label, value = value } end

  return canonical { op = label, error = tostring(value) }
end

--- The port's lines for a plugin.
local function portLines(source: buffer, sink: ((line: string) -> ())?): Lines
  local out: Lines = {}
  local function add(label: string, f: () -> unknown)
    local line = attempt(label, f)
    if sink then
      sink(line)
    else
      table.insert(out, line)
    end
  end

  local function fresh(): tes3.Plugin return tes3.open(source) end

  local paths = tes3cmd.masters.paths()
  add('lint', function() return tes3cmd.lint(fresh(), tes3cmd.preset 'all', paths) end)
  add('lint recommended', function() return tes3cmd.lint(fresh(), nil, paths) end)
  add('clean', function()
    local plugin = fresh()
    local report = tes3cmd.clean(plugin, nil, paths, 'update')
    return { report.removedRecords, report.removedSubrecords, md5(plugin:save()) }
  end)

  add('clean evil gmsts', function()
    local plugin = fresh()
    local report = tes3cmd.clean(plugin, { evilGmsts = true }, paths, 'update')
    return { report.removedRecords, report.removedSubrecords, md5(plugin:save()) }
  end)

  add('stats', function()
    local stats = tes3cmd.stats.new()
    tes3cmd.stats.add(stats, fresh())
    return { stats.records, stats.recordTypes, stats.subrecordTypes, stats.listSubrecords }
  end)

  local plugin = fresh()
  for i = 0, plugin:count() - 1 do
    add(`display {i}`, function() return tes3.display.display(plugin, i) end)
  end

  for _, profile in Profiles do
    add(`validate {profile}`, function() return tes3cmd.validate(fresh(), profile) end)
  end

  for k, spec in Specs do
    local selector = tes3cmd.selector(spec)
    add(`ids {k}`, function() return tes3cmd.select.ids(selector, plugin) end)
    -- A whole-plugin dump or layout of a retail master doesn't fit in memory twice over; streamed,
    -- the per-record `display` lines stand in for them.
    if not sink then
      add(`dump {k}`, function() return tes3cmd.dump(plugin, selector) end)
      add(`layout {k}`, function()
        local out = {}
        for _, entry in tes3cmd.select.picked(selector, plugin) do
          table.insert(
            out,
            tes3cmd.layout(plugin, entry.index, selector, { subrecords = true, fields = true })
          )
        end

        return out
      end)
    end

    add(`extract {k}`, function() return md5(tes3cmd.extract(plugin, selector, true)) end)
    add(`delete {k}`, function()
      local edited = fresh()
      local deleted = tes3cmd.delete(edited, selector, 'update')
      return { deleted.records, deleted.subrecords, deleted.references, md5(edited:save()) }
    end)

    for r, replacement in Replacements do
      add(`replace {k} {r}`, function()
        local edited = fresh()
        local parsed = tes3cmd.parseReplacement(replacement[1] :: string, not replacement[2])
        local report = tes3cmd.replace(edited, selector, parsed)
        return { report.records, report.fields, md5(edited:save()) }
      end)
    end
  end

  add('header', function()
    local edited = fresh()
    local changed = tes3cmd.updateHeader(
      edited,
      { author = 'tester', description = '+\\nsecond', fileType = 'master' }
    )
    return { changed, md5(edited:save()) }
  end)

  add('record count', function()
    local edited = fresh()
    return { edited:updateRecordCount(), md5(edited:save()) }
  end)

  add('common', function() return tes3cmd.compare.common(plugin, plugin) end)
  local edited = fresh()
  tes3cmd.replace(edited, tes3cmd.selector(), tes3cmd.parseReplacement('/o/0/', true))
  add('diff', function() return tes3cmd.compare.diff(plugin, edited) end)
  add(
    'diff equal',
    function() return tes3cmd.compare.diff(plugin, edited, { 'STAT', 'Cell' }, true) end
  )
  add('overrides', function() return tes3cmd.compare.overrides { plugin, edited, fresh() } end)
  add(
    'overrides ignore',
    function() return tes3cmd.compare.overrides({ plugin, edited, fresh() }, { 'npc' }) end
  )
  return out
end

--- jess's lines for the same plugin, through the native binding.
local function nativeLines(source: buffer, sink: ((line: string) -> ())?): Lines
  local out: Lines = {}
  local function add(label: string, f: () -> unknown)
    local line = attempt(label, f)
    if sink then
      sink(line)
    else
      table.insert(out, line)
    end
  end

  local function fresh(): any return oracle.parse(source, { encoding = 'win1252' }) end

  add('lint', function() return fresh():lint { preset = 'all', openmw = false } end)
  add('lint recommended', function() return fresh():lint { openmw = false } end)
  add('clean', function()
    local plugin = fresh()
    local report = plugin:clean { openmw = false }
    return { report.removedRecords, report.removedSubrecords, md5(plugin:bytes()) }
  end)

  add('clean evil gmsts', function()
    local plugin = fresh()
    local report = plugin:clean { evilGmsts = true, openmw = false }
    return { report.removedRecords, report.removedSubrecords, md5(plugin:bytes()) }
  end)

  add('stats', function()
    local stats = fresh():stats()
    return { stats.records, stats.recordTypes, stats.subrecordTypes, stats.listSubrecords }
  end)

  local plugin = fresh()
  for i = 0, #plugin - 1 do
    add(`display {i}`, function() return plugin:record(i):display() end)
  end

  for _, profile in Profiles do
    add(`validate {profile}`, function()
      local validation = fresh():validate(profile)
      return { checks = validation.checks, diagnostics = validation.diagnostics }
    end)
  end

  for k, spec in Specs do
    add(`ids {k}`, function() return plugin:select(spec):ids() end)
    if not sink then
      add(`dump {k}`, function() return plugin:select(spec):display() end)
      add(
        `layout {k}`,
        function() return plugin:select(spec):layout { subrecords = true, fields = true } end
      )
    end

    add(
      `extract {k}`,
      function() return md5(plugin:select(spec):extract({ header = true }):bytes()) end
    )
    add(`delete {k}`, function()
      local edited = fresh()
      local deleted = edited:select(spec):delete()
      return { deleted.records, deleted.subrecords, deleted.references, md5(edited:bytes()) }
    end)

    for r, replacement in Replacements do
      add(`replace {k} {r}`, function()
        local edited = fresh()
        local report = edited:select(spec):replace(replacement[1], nil, { first = replacement[2] })
        return { report.records, report.fields, md5(edited:bytes()) }
      end)
    end
  end

  add('header', function()
    local edited = fresh()
    local changed =
      edited:setHeader { author = 'tester', description = '+\\nsecond', fileType = 'master' }
    return { changed, md5(edited:bytes()) }
  end)

  add('record count', function()
    local edited = fresh()
    return { edited:updateRecordCount(), md5(edited:bytes()) }
  end)

  add('common', function() return native.compare.common(plugin, plugin) end)
  local edited = fresh()
  edited:select():replace '/o/0/'
  add('diff', function() return native.compare.diff(plugin, edited) end)
  add(
    'diff equal',
    function()
      return native.compare.diff(plugin, edited, { ignore = { 'STAT', 'Cell' }, equal = true })
    end
  )
  add('overrides', function() return native.compare.overrides { plugin, edited, fresh() } end)
  add(
    'overrides ignore',
    function() return native.compare.overrides({ plugin, edited, fresh() }, { ignore = { 'npc' } }) end
  )
  return out
end

--- Throws naming the first few lines that differ.
local function compare(name: string, got: Lines, want: Lines)
  local problems = {}
  for i = 1, math.max(#got, #want) do
    if got[i] ~= want[i] then
      table.insert(problems, `  want {want[i]}\n  got  {got[i]}`)
      if #problems >= 5 then break end
    end
  end

  if #problems > 0 then error(`{name}: lines differ\n{table.concat(problems, '\n')}`, 0) end
end

--- Compares the port's lines with the binding's as each pair is made, holding one pair at a time:
--- for the retail masters, whose lines don't all fit in memory at once.
local function compareLive(name: string, source: buffer): number
  -- Each side runs in a coroutine that yields a line at a time, and nil when it's done.
  local function stream(lines: (buffer, (string) -> ()) -> Lines): () -> string?
    return coroutine.wrap(function(): string?
      lines(source, function(line: string) coroutine.yield(line) end)
      return nil
    end) :: () -> string?
  end

  local port, native = stream(portLines), stream(nativeLines)
  local count = 0
  while true do
    local got, want = port(), native()
    if got == nil and want == nil then return count end

    count += 1
    if got ~= want then compare(name, { got or '(nothing)' }, { want or '(nothing)' }) end
  end
end

return table.freeze {
  compare = compare,
  compareLive = compareLive,
  native = nativeLines,
  port = portLines,
}
