--!strict
--!native
-- dream.saves' own cases: what jess's CLI save tests (`libs/cli/tests/save.rs`, `save_strip.rs`)
-- and jess-save's unit tests check, on saves built here and load orders held in memory, so the
-- suite needs nothing but the package.
local fixtures = require './fixtures'
local plugins = require './../tes3cmd/fixtures'
local saves = require '@dreamwind/saves'
local tes3 = require '@dreamwind/tes3'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

local record, subrecord, u32 = plugins.record, plugins.subrecord, plugins.u32
local refId, formId = fixtures.refId, fixtures.formId

--- A load order of files held in memory: `active` names the content files in order (all of
--- `files` by default), and every file resolves by name, ignoring case.
local function memory(
  files: { [string]: string },
  active: { string }?,
  encoding: string?
): saves.LoadOrder
  local byName: { [string]: string } = {}
  for name in files do
    byName[string.lower(name)] = name
  end

  local content = {}
  for _, name in active or {} do
    table.insert(content, { name = name, path = byName[string.lower(name)] })
  end

  return {
    content = content,
    resolve = function(name: string): string? return byName[string.lower(name)] end,
    read = function(path: string): (string | buffer)? return files[path] end,
    encoding = encoding,
  }
end

local function scenario(name: string): fixtures.Scenario
  for _, found in fixtures.scenarios() do
    if found.name == name then return found end
  end

  return error(`no scenario {name}`)
end

local function open(name: string): (saves.Save, saves.LoadOrder)
  local found = scenario(name)
  local active = {}
  for line in string.gmatch(found.config or '', 'content=([^\n]+)') do
    table.insert(active, line)
  end

  return saves.parse(found.save), memory(found.files, active)
end

local function step(report: { [string]: unknown }, index: number?): { [string]: any }
  return (report.steps :: { any })[index or 1]
end

local function has(list: { { [string]: any } }, fields: { [string]: unknown }): boolean
  for _, item in list do
    local matches = true
    for key, value in fields do
      if item[key] ~= value then
        matches = false
        break
      end
    end

    if matches then return true end
  end

  return false
end

suite.describe('reading', function()
  suite.it('describes OpenMW saves', function()
    local info = saves.info(saves.parse(fixtures.save()))
    expect(info.format).toBe 'openmw'
    expect(info.formatVersion).toBe(fixtures.CurrentFormatVersion)
    expect(info.player).toEqual {
      name = 'Tester',
      level = 1,
      classId = 'Archer',
      className = 'Pilgrim',
    }
    expect(info.cell).toBe 'Seyda Neen'
    expect(info.inGameTime).toEqual { gameHour = 8.5, day = 18, month = 7, year = 427 }
    expect(info.timePlayed).toBe(12.5)
    expect(info.dependencies).toEqual { 'Morrowind.esm' }
    expect(info.screenshotBytes).toBe(4)
    expect(info.currentDay).toBe(3)
  end)

  suite.it('detects and describes Morrowind saves, keeping every byte', function()
    local save = saves.parse(fixtures.morrowindSave())
    expect(save.game).toBe 'morrowind'
    local info = saves.info(save)
    expect(info.description).toBe 'Quicksave'
    expect(info.player).toEqual { name = 'Nerevar', level = 7, classId = 'Battlemage' }
    expect(info.cell).toBe 'Balmora'
    expect(info.dependencies).toEqual { 'Morrowind.esm' }
    expect(info.inGameTime).toEqual { gameHour = 9.25, day = 3, month = 1, year = 427 }
    expect(info.currentHealth).toBe(30)
    expect(info.screenshotBytes).toBe(128 * 128 * 4)
    expect(buffer.tostring(save.plugin:save()) == fixtures.morrowindSave()).toBe(true)
  end)

  suite.it('names the file in parse errors', function()
    expect(
      function() saves.parse(fixtures.morrowindSave(), { name = 'test.ess', game = 'openmw' }) end
    ).toThrow '\'test.ess\' isn\'t an OpenMW save'
    local plain = record('TES3', subrecord('HEDR', string.rep('\0', 300)))
    expect(function() saves.parse(plain, { name = 'plain.esp' }) end).toThrow '\'plain.esp\' isn\'t an OpenMW or Morrowind save'
    expect(function() saves.parse('nonsense', { name = 'junk.ess' }) end).toThrow 'failed to parse \'junk.ess\': '
  end)

  suite.it('gives the screenshot: a JPEG, or a TGA from Morrowind pixels', function()
    local jpeg, format = saves.screenshot(saves.parse(fixtures.save()))
    expect(format).toBe 'jpeg'
    expect(buffer.tostring(jpeg)).toBe '\255\216\255\217'
    local tga, kind = saves.screenshot(saves.parse(fixtures.morrowindSave()))
    expect(kind).toBe 'tga'
    expect(buffer.len(tga)).toBe(18 + 128 * 128 * 3)
    expect(buffer.readstring(tga, 12, 6)).toBe '\128\0\128\0\24\32'
    expect(buffer.readu8(tga, 18)).toBe(9)
  end)

  suite.it('dumps records and Lua data readably', function()
    local bytes = fixtures.save { 'Morrowind.esm', 'Tribunal.esm' }
      .. record(
        'LUAM',
        subrecord('FRMR', formId(41, 1)) .. subrecord('LUAD', fixtures.luaObject(42, 1))
      )
      .. record('LUAM', subrecord('LUAD', '\1'))
    local save = saves.parse(bytes)
    local values = saves.values(save) :: { any }
    expect(values[2].type).toBe 'SaveHeader'
    expect(values[3].subrecords[1].FRMR).toBe '41 (content file 1)'
    expect(values[3].subrecords[2].LUAD).toEqual { object = { index = 42, content_file = 1 } }
    local rows = saves.luaData(save)
    expect(#rows).toBe(2)
    expect((rows[1].value :: tes3.LuaValue).kind).toBe 'object'
    expect(rows[2].error).toContain 'unsupported Lua serialization format version 1'
    expect(saves.recordId(save, 1)).toBeNil()
  end)
end)

suite.describe('check', function()
  suite.it('reports what breaks with the current load order', function()
    local save, order = open 'check-what-breaks'
    local report = saves.check(save, { loadOrder = order })
    expect(report.verdict).toBe 'willNotLoad'
    expect(report.loads).toBe(false)
    expect(report.missingContent).toEqual {
      { name = 'Gone.esp', strippable = true },
      { name = 'Unticked.esp', strippable = true },
    }
    expect(
      has(
        report.findings,
        { severity = 'willNotLoad', problem = 'missingBirthsign', id = 'gone_sign' }
      )
    ).toBe(true)
    expect(
      has(
        report.findings,
        { severity = 'broken', problem = 'trappedObjectCannotBeOpened', id = 'gone_trap' }
      )
    ).toBe(true)
    local dropped = 0
    for _, count in report.droppedOnLoad do
      dropped += count
    end

    expect(dropped).toBe(1)
  end)

  suite.it('still checks structure without a load order', function()
    local report = saves.check(saves.parse(fixtures.save()))
    expect(report.verdict).toBe 'structureValid'
    expect(report.loadOrderChecked).toBe(false)
  end)

  suite.it('reports broken CSTA layouts', function()
    local dangling = saves.check((open 'dangling-mvrf'))
    expect(dangling.verdict).toBe 'invalidStructure'
    expect(dangling.structureProblems[1]).toContain '#2 CSTA MVRF #0 is not followed by NAME'
    local incomplete = saves.validate((open 'incomplete-csta').plugin)
    expect(incomplete.checks).toEqual { 'structure', 'saveMetadata', 'saveFormat', 'cellState' }
    expect(incomplete.diagnostics[1].message).toContain 'CSTA OBJE #0 FRMR #1 is not followed by NAME'
  end)

  suite.it('refuses Morrowind saves', function()
    expect(function() saves.check(saves.parse(fixtures.morrowindSave())) end).toThrow 'save check isn\'t supported for Morrowind saves'
  end)
end)

suite.describe('strip', function()
  suite.it('plans and verifies removing a dependency', function()
    local save, order = open 'plain'
    local report = saves.strip(save, { 'Morrowind.esm' }, { loadOrder = order, mode = 'dryRun' })
    local first = step(report)
    expect(first.mode).toBe 'dryRun'
    expect(first.blockers.status).toBe 'noKnownBlockers'
    expect(first.plannedEdits).toEqual {
      {
        operation = 'removeSaveDependency',
        status = 'planned',
        recordIndex = 1,
        recordType = 'SAVE',
        subrecordIndex = 8,
        subrecordType = 'DEPE',
        oldContentFileIndex = 0,
        reason = 'requestedDependencyEntryWouldBeRemovedFrom_SAVE_DEPE',
      },
    }
    expect(#first.referenceCoverage.knownScans).toBe(18)
    expect(first.dryRun.status).toBe 'verified'
    expect(first.mutation).toBe 'dryRunOnly'
    expect(report.blocked).toBe(false)
  end)

  suite.it('deletes save state only the removed content defined', function()
    local save, order = open 'typed-refids'
    local first =
      step(saves.strip(save, { 'Tribunal.esm' }, { loadOrder = order, mode = 'inMemory' }))
    local meanings = {}
    for _, edit in first.plannedEdits do
      if edit.operation == 'deleteTargetSaveRecord' then table.insert(meanings, edit.meaning) end
    end

    expect(meanings).toEqual { 'savedRecordId', 'globalScript', 'globalVariable' }
    expect(saves.info(save).dependencies).toEqual { 'Morrowind.esm' }
    expect(save.plugin:count()).toBe(2)
    expect(save.plugin:header().recordCount).toBe(1)
  end)

  suite.it('refuses what it can not fix, and leaves the save alone', function()
    local save, order = open 'player-record'
    local before = buffer.tostring(save.plugin:save())
    local report = saves.strip(save, { 'Races.esp' }, { loadOrder = order, mode = 'inMemory' })
    local first = step(report)
    expect(first.mutationReadiness.canAttemptDryRun).toBe(false)
    expect(has(first.blockers.hard, { kind = 'targetIntroducedRefIds', count = 2 })).toBe(true)
    expect(report.blocked).toBe(true)
    expect(buffer.tostring(save.plugin:save()) == before).toBe(true)
  end)

  suite.it('removes dependents before their masters', function()
    local save, order = open 'several'
    local report = saves.strip(
      save,
      { 'Library.esm', 'Patch.esp' },
      { loadOrder = order, mode = 'inMemory' }
    )
    expect(report.dependencies).toEqual { 'Patch.esp', 'Library.esm' }
    expect(saves.info(save).dependencies).toEqual { 'Morrowind.esm', 'Other.esp' }
    local masters = {}
    for _, master in save.plugin:masters() do
      table.insert(masters, master.name)
    end

    expect(masters).toEqual { 'Morrowind.esm', 'Other.esp' }
    local blocked = saves.strip(
      saves.parse(scenario('several').save),
      { 'Library.esm' },
      { loadOrder = order, mode = 'dryRun' }
    )
    expect(has(step(blocked).blockers.hard, { kind = 'dependentsRequireRemovedMaster', count = 1 })).toBe(
      true
    )
  end)

  suite.it('renumbers equipment after removing inventory items', function()
    local save, order = open 'equipment'
    saves.strip(save, { 'Tribunal.esm' }, { loadOrder = order, mode = 'inMemory' })
    local plugin = save.plugin
    local play = tes3.records.find(plugin, 'PLAY', '') or plugin:count() - 1
    local function payload(tag: string): string
      local source, at, size = plugin:findSubrecord(play, tes3.tags.code(tag))
      return buffer.readstring(source :: buffer, at, size)
    end

    local function words(data: string): { number }
      local out = {}
      for at = 1, #data, 4 do
        table.insert(out, string.unpack('<i4', data, at) :: number)
      end

      return out
    end

    expect(words(payload 'ICNT')).toEqual { 2 }
    -- The ring's equipment is gone and the boots move from item 2 to item 1, keeping their slot.
    expect(words(payload 'EQIP')).toEqual { 2, 0, 1, 1, 5 }
    expect(words(payload 'SELE')).toEqual { 1 }
  end)

  suite.it('remaps serialized Lua RefNums after the removed dependency', function()
    local save, order = open 'lua-refnums'
    local report = saves.strip(save, { 'Bloodmoon.esm' }, { loadOrder = order, mode = 'dryRun' })
    expect(step(report).dryRun.status).toBe 'blocked'
    saves.strip(save, { 'Tribunal.esm' }, { loadOrder = order, mode = 'inMemory' })
    expect(#saves.info(save).dependencies).toBe(3)
  end)

  suite.it('strips content that is no longer installed', function()
    local save, order = open 'uninstalled'
    local report = saves.strip(
      save,
      { 'Tribunal.esm' },
      { loadOrder = order, mode = 'inMemory', sampleLimit = 20 }
    )
    local first = step(report)
    expect(first.warnings[1]).toContain '\'Tribunal.esm\' isn\'t installed'
    expect(first.dryRun.status).toBe 'verified'
    expect(#saves.info(save).dependencies).toBe(1)
  end)

  suite.it('names a dependency the save does not have', function()
    expect(
      function() saves.strip(saves.parse(fixtures.save()), { 'Nope.esp' }, { mode = 'dryRun' }) end
    ).toThrow 'save dependency \'Nope.esp\' was not found'
  end)

  suite.it('checks the format window', function()
    local statuses = {
      [36] = 'unsupported',
      [37] = 'supported',
      [fixtures.CurrentFormatVersion + 1] = 'unsupported',
    }

    for version, status in statuses do
      local report = saves.strip(
        saves.parse(fixtures.save(nil, version)),
        { 'Morrowind.esm' },
        { mode = 'dryRun' }
      )
      expect(step(report).saveFormat.mutationStatus).toBe(status)
    end
  end)
end)

return suite
