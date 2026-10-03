--!strict
--!native
-- What dream.saves and jess-save answer for one save, operation by operation, one canonical JSON
-- line each: metadata, screenshot, readable records, Lua data, validation, and checks and strips
-- against a load order.
local bytes = require '@dream/bytes'
local canonical = require './../tes3/canonical'
local fixtures = require './fixtures'
local saves = require '@dreamwind/saves'

export type Lines = { string }

export type Operation = fixtures.Operation

local native = (_G :: any).jess

--- A value, or the error raising it gave, as one line.
local function attempt(label: string, f: () -> unknown): string
  local ok, value = pcall(f)
  if ok then return canonical { op = label, value = value } end

  return canonical { op = label, error = tostring(value) }
end

local function describe(operation: Operation): string
  local parts: { string } = { operation.kind }
  if operation.dependencies then table.insert(parts, table.concat(operation.dependencies, '+')) end

  if operation.mode then table.insert(parts, operation.mode) end

  if operation.sampleLimit then table.insert(parts, `limit {operation.sampleLimit}`) end

  if operation.noConfig then table.insert(parts, 'no config') end

  return table.concat(parts, ' ')
end

--- The port's lines for a save; `config` is the openmw.cfg its checks and strips use.
local function portLines(source: buffer, config: string?, operations: { Operation }): Lines
  local out: Lines = {}
  local function add(label: string, f: () -> unknown) table.insert(out, attempt(label, f)) end

  local function fresh(): saves.Save return saves.parse(source) end

  add('info', function() return saves.info(fresh()) end)
  add('screenshot', function()
    local image, format = saves.screenshot(fresh())
    return { bytes.md5(image), format }
  end)

  add('values', function() return saves.values(fresh()) end)
  add('validate', function() return saves.validate(fresh().plugin) end)
  add('lua data', function()
    local rows = {}
    for _, row in saves.luaData(fresh()) do
      table.insert(rows, { row.record, row.type, row.error })
    end

    return rows
  end)

  for _, operation in operations do
    local function loadOrder(): saves.LoadOrder?
      if operation.noConfig or not config then return nil end

      return saves.loadOrder.fromOpenMw(jess.openmw.load(config))
    end

    if operation.kind == 'check' then
      add(
        describe(operation),
        function() return saves.check(fresh(), { loadOrder = loadOrder() }) end
      )
      continue
    end

    add(describe(operation), function()
      local save = fresh()
      local report = saves.strip(save, operation.dependencies :: { string }, {
        loadOrder = loadOrder(),
        mode = operation.mode :: saves.Mode,
        sampleLimit = operation.sampleLimit,
      })
      return { report, bytes.md5(save.plugin:save()) }
    end)
  end

  return out
end

--- jess-save's lines for the same save, through the native binding.
local function nativeLines(source: buffer, config: string?, operations: { Operation }): Lines
  local out: Lines = {}
  local function add(label: string, f: () -> unknown) table.insert(out, attempt(label, f)) end

  local function fresh(): any return native.save.parse(source) end

  add('info', function() return fresh().header end)
  add('screenshot', function()
    local image, format = fresh():screenshot()
    return { bytes.md5(image), format }
  end)

  add('values', function() return fresh():values() end)
  add('validate', function()
    local validation = fresh().plugin:validate 'omwsave'
    return { checks = validation.checks, diagnostics = validation.diagnostics }
  end)

  add('lua data', function()
    local rows = {}
    for _, row in fresh():luaData() do
      table.insert(rows, { row.record, row.type, row.error })
    end

    return rows
  end)

  for _, operation in operations do
    local options: { [string]: any } = if operation.noConfig or not config
      then { openmw = false }
      else { config = config }
    if operation.kind == 'check' then
      add(describe(operation), function() return native.save.check(fresh(), options) end)
      continue
    end

    add(describe(operation), function()
      local save = fresh()
      options.sampleLimit = operation.sampleLimit
      if operation.mode == 'dryRun' then
        options.dryRun = true
      else
        options.inMemory = true
      end

      local report = native.save.strip(save, operation.dependencies, options)
      return { report, bytes.md5(save.plugin:bytes()) }
    end)
  end

  return out
end

--- Throws naming the first few lines that differ.
local function compare(name: string, got: Lines, want: Lines)
  local problems = {}
  for i = 1, math.max(#got, #want) do
    if got[i] ~= want[i] then
      table.insert(problems, `  want {want[i]}\n  got  {got[i]}`)
      if #problems >= 3 then break end
    end
  end

  if #problems > 0 then error(`{name}: lines differ\n{table.concat(problems, '\n')}`, 0) end
end

return table.freeze { compare = compare, native = nativeLines, port = portLines }
