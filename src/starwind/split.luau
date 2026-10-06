--!strict
--!native
-- split_starwind.py: the masterless monolith partitioned into Star_Data (stable definitions) and
-- Starwind (world content), and the pair checked, as written, to rebuild the monolith exactly.

local dependencies = require './dependencies'
local report = require './report'
local tes3 = require '../lib/tes3'
local tes3conv = require '@dreamwind/tools/tes3conv'
local core = require '@dreamwind/tes3'

type Table = tes3.Table
type Record = tes3.Record
type Records = tes3.Records
type Dependency = dependencies.Dependency
type Json = report.Json

local split = {}

-- Definition families that default to Data. A record with a content-only dependency stays in
-- Starwind; its type alone doesn't make it reusable.
local AlwaysData = {
  'Alchemy',
  'Apparatus',
  'Birthsign',
  'Bodypart',
  'Class',
  'Enchanting',
  'Faction',
  'GameSetting',
  'Ingredient',
  'Lockpick',
  'MagicEffect',
  'Probe',
  'Race',
  'RepairItem',
  'Skill',
  'Sound',
  'SoundGen',
  'Spell',
  'Static',
}

-- Candidates only when what they depend on can live in Star_Data too. Books aren't: their text
-- is authored world content.
local CandidateData = {
  'Activator',
  'Armor',
  'Clothing',
  'Container',
  'Creature',
  'Door',
  'LeveledCreature',
  'LeveledItem',
  'Light',
  'MiscItem',
  'Weapon',
}

-- An approved stable script must be named before it can cross with its definition. None are.
local ApprovedDataScripts: { [string]: boolean } = {}

local DataTypes: { [string]: boolean } = {}

for _, kind in AlwaysData do
  DataTypes[kind] = true
end

for _, kind in CandidateData do
  DataTypes[kind] = true
end

local function set(names: { string }): { [string]: boolean }
  local result = {}

  for _, name in names do
    result[name] = true
  end

  return result
end

local ItemTypes = set {
  'Activator',
  'Alchemy',
  'Apparatus',
  'Armor',
  'Book',
  'Clothing',
  'Container',
  'Creature',
  'Door',
  'Ingredient',
  'Light',
  'Lockpick',
  'LeveledCreature',
  'LeveledItem',
  'MiscItem',
  'Probe',
  'RepairItem',
  'Weapon',
}

-- Each field resolved against its own record namespace, so BODY race "Droid" can't match DIAL
-- "droid". A creature's sound names the creature whose sound generators it borrows.
local TargetTypes: { [string]: { [string]: boolean } } = {
  ['race.spells'] = set { 'Spell' },
  ['soundgen.creature'] = set { 'Creature' },
  ['soundgen.sound'] = set { 'Sound' },
  ['region.sleep_creature'] = set { 'Creature' },
  ['region.sounds'] = set { 'Sound' },
  ['magic_effect.area_sound'] = set { 'Sound' },
  ['magic_effect.bolt_sound'] = set { 'Sound' },
  ['magic_effect.cast_sound'] = set { 'Sound' },
  ['magic_effect.hit_sound'] = set { 'Sound' },
  ['magic_effect.area_visual'] = set { 'Static' },
  ['magic_effect.bolt_visual'] = set { 'Static', 'Weapon' },
  ['magic_effect.cast_visual'] = set { 'Static' },
  ['magic_effect.hit_visual'] = set { 'Static' },
  ['birthsign.spells'] = set { 'Spell' },
  ['weapon.enchanting'] = set { 'Enchanting' },
  ['book.enchanting'] = set { 'Enchanting' },
  ['armor.enchanting'] = set { 'Enchanting' },
  ['clothing.enchanting'] = set { 'Enchanting' },
  ['armor.male_bodypart'] = set { 'Bodypart' },
  ['armor.female_bodypart'] = set { 'Bodypart' },
  ['clothing.male_bodypart'] = set { 'Bodypart' },
  ['clothing.female_bodypart'] = set { 'Bodypart' },
  ['door.open_sound'] = set { 'Sound' },
  ['door.close_sound'] = set { 'Sound' },
  ['light.sound'] = set { 'Sound' },
  ['creature.sound'] = set { 'Creature' },
  ['creature.spells'] = set { 'Spell', 'MagicEffect' },
  ['creature.ai.activate'] = set { 'Activator' },
  ['bodypart.race'] = set { 'Race' },
  ['npc.race'] = set { 'Race' },
  ['npc.class'] = set { 'Class' },
  ['npc.faction'] = set { 'Faction' },
  ['npc.head'] = set { 'Bodypart' },
  ['npc.hair'] = set { 'Bodypart' },
  ['npc.sound'] = set { 'Sound' },
  ['npc.ai.activate'] = set { 'Activator' },
  ['info.speaker_race'] = set { 'Race' },
  ['info.speaker_class'] = set { 'Class' },
  ['info.speaker_faction'] = set { 'Faction' },
  ['info.player_faction'] = set { 'Faction' },
  ['cell.region'] = set { 'Region' },
  ['faction.reaction'] = set { 'Faction' },
  ['leveled_creature.creatures'] = set { 'Creature', 'Npc', 'LeveledCreature' },
  ['container.inventory'] = ItemTypes,
  ['creature.inventory'] = ItemTypes,
  ['npc.inventory'] = ItemTypes,
  ['leveled_item.items'] = ItemTypes,
}

local ScriptTarget = set { 'Script' }

-- Record keys are "Type\0id", the id lowercased.
type Namespace = { [string]: { [string]: boolean } }

local function key(kind: string, id: string): string return `{kind}\0{id}` end

local function recordKey(record: Record): string?
  local id = tes3.auditId(record)

  if id == '' then return nil end

  return key(tes3.string(record.type), string.lower(id))
end

local function namespace(keys: { [string]: boolean }): Namespace
  local result: Namespace = {}

  for recordKey in keys do
    local kind, id = string.match(recordKey, '^(.-)%z(.*)$')
    local types = result[id :: string] or {}
    result[id :: string] = types
    types[kind :: string] = true
  end

  return result
end

-- `dependency_target_keys`: the typed records a dependency can resolve to.
local function targetKeys(dependency: Dependency, known: Namespace): { string }
  local types = TargetTypes[dependency.kind]

  if types == nil and string.sub(dependency.kind, -7) == '.script' then types = ScriptTarget end

  local present = known[dependency.target] or {}
  local keys = {}

  for kind in present do
    if types == nil or (types :: { [string]: boolean })[kind] then
      table.insert(keys, key(kind, dependency.target))
    end
  end

  return keys
end

local function intersects(keys: { string }, against: { [string]: boolean }): boolean
  for _, recordKey in keys do
    if against[recordKey] then return true end
  end

  return false
end

local function dependencyJson(dependency: Dependency): Json
  return report.object {
    'target',
    dependency.target,
    'target_original',
    dependency.target_original,
    'source_type',
    dependency.source_type,
    'source_id',
    dependency.source_id,
    'kind',
    dependency.kind,
  }
end

-- `choose_data_records`: the indices (0-based, header 0) of the records Star_Data gets, and the
-- candidates demoted to Starwind, to a fixed point.
function split.choose(records: Records): ({ [number]: boolean }, { Json })
  local candidates: { [number]: boolean } = {}

  for index = 2, #records do
    local record = records[index]
    local kind = tes3.string(record.type)
    local eligible = DataTypes[kind]
      or (kind == 'Script' and ApprovedDataScripts[string.lower(tes3.auditId(record))] == true)

    if eligible and tes3.auditId(record) ~= '' then candidates[index - 1] = true end
  end

  local allKeys: { [string]: boolean } = {}
  local keys: { [number]: string } = {}

  for index = 2, #records do
    local recordKey = recordKey(records[index])

    if recordKey then
      allKeys[recordKey] = true
      keys[index] = recordKey
    end
  end

  local known = namespace(allKeys)
  -- Each candidate's dependencies, with the typed records each can resolve to.
  local deps: { [number]: { { dependency: Dependency, targets: { string } } } } = {}
  local demotions: { Json } = {}

  while true do
    local contentKeys: { [string]: boolean } = {}

    for index = 2, #records do
      local recordKey = keys[index]

      if recordKey and not candidates[index - 1] then contentKeys[recordKey] = true end
    end

    local sorted = {}

    for index in candidates do
      table.insert(sorted, index)
    end

    table.sort(sorted)
    local demote: { { index: number, record: Record, dependency: Dependency } } = {}

    for _, index in sorted do
      local record = records[index + 1]
      local list = deps[index]

      if not list then
        list = {}

        for _, dependency in dependencies.of(record, index) do
          table.insert(list, { dependency = dependency, targets = targetKeys(dependency, known) })
        end

        deps[index] = list
      end

      for _, item in list do
        if intersects(item.targets, contentKeys) then
          table.insert(demote, { index = index, record = record, dependency = item.dependency })
          break
        end
      end
    end

    if #demote == 0 then return candidates, demotions end

    for _, item in demote do
      candidates[item.index] = nil
      table.insert(
        demotions,
        report.object {
          'type',
          tes3.string(item.record.type),
          'id',
          tes3.auditId(item.record),
          'dependency',
          dependencyJson(item.dependency),
          'reason',
          'dependency resolves to Starwind content',
        }
      )
    end
  end
end

local function header(source: Record, count: number, masters: { Table }, fileType: string): Record
  local copy = table.clone(source)
  copy.numObjects = count
  copy.masters = masters :: { tes3.Value }
  copy.fileType = fileType
  return copy
end

local function uniqueRecords(
  records: Records,
  bytes: { string }?
): ({ [string]: number }, { string })
  local byKey: { [string]: number } = {}
  local order = {}

  for index, record in records do
    local recordKey = recordKey(record)

    if recordKey then
      if byKey[recordKey] == nil then table.insert(order, recordKey) end

      byKey[recordKey] = index
    end
  end

  return byKey, order
end

local function unresolved(records: Records, known: Namespace): { Dependency }
  local result = {}

  for index, record in records do
    for _, dependency in dependencies.of(record, index) do
      if dependencies.HardKinds[dependency.kind] and #targetKeys(dependency, known) == 0 then
        table.insert(result, dependency)
      end
    end
  end

  return result
end

local function identity(dependency: Dependency): string
  return table.concat({
    dependency.source_type,
    string.lower(dependency.source_id),
    dependency.kind,
    dependency.target,
  }, '\0')
end

local function typeCounts(records: Records): Json
  local counts: { [string]: number } = {}
  local order = {}

  for _, record in records do
    local kind = tes3.string(record.type)

    if counts[kind] == nil then
      table.insert(order, kind)
      counts[kind] = 0
    end

    counts[kind] += 1
  end

  local pairs = {}

  for _, kind in order do
    table.insert(pairs, kind)
    table.insert(pairs, counts[kind])
  end

  return report.object(pairs)
end

local ForbiddenInData = set {
  'Cell',
  'PathGrid',
  'Dialogue',
  'DialogueInfo',
  'Npc',
  'StartScript',
  'GlobalVariable',
  'Region',
  'Book',
}

-- A written plugin's header, and its records after it, decoded, with each one's bytes.
export type Written = { header: Record, records: Records, bytes: { string } }

local function readBack(plugin: core.Plugin): (Records, { string })
  local records, bytes = tes3conv.recordsWithBytes(plugin)
  table.remove(records, 1)
  table.remove(bytes, 1)
  return records, bytes
end

local function sortedNames(names: { string }): { Json }
  local copy = table.clone(names)
  table.sort(copy)
  return report.array(copy :: { Json })
end

export type Result = { report: { [string]: Json }, data: core.Plugin, content: core.Plugin }

-- `validate_partition` over the plugins as written and read back. Records compare by their
-- bytes, which is what tes3conv's JSON signatures stood for.
-- A written half of the pair, read back. A record whose bytes the monolith holds decodes to what
-- the monolith's copy decoded to, so it takes that; any other is decoded from its own bytes.
local function readBackLike(plugin: core.Plugin, known: { [string]: Record }): (Records, { string })
  local records: Records, bytes: { string } = {}, {}

  for index = 0, plugin:count() - 1 do
    if plugin:tag(index) == 'TES3' then continue end

    local raw = buffer.tostring(plugin:bytes(index))
    local decoded = known[raw]

    if not decoded then return readBack(plugin) end

    table.insert(records, decoded)
    table.insert(bytes, raw)
  end

  -- What tes3conv writes it reads back in the same order: the pair was written sorted.
  return records, bytes
end

local function validate(source: Written, data: core.Plugin, content: core.Plugin): { [string]: Json }
  local sourceRecords, sourceBytes = source.records, source.bytes
  local known: { [string]: Record } = {}

  for index, raw in sourceBytes do
    known[raw] = sourceRecords[index]
  end

  local dataRecords, dataBytes = readBackLike(data, known)
  local contentRecords, contentBytes = readBackLike(content, known)
  local pairRecords = table.clone(dataRecords)
  table.move(contentRecords, 1, #contentRecords, #pairRecords + 1, pairRecords)
  local pairBytes = table.clone(dataBytes)
  table.move(contentBytes, 1, #contentBytes, #pairBytes + 1, pairBytes)

  local counter: { [string]: number } = {}

  for _, bytes in sourceBytes do
    counter[bytes] = (counter[bytes] or 0) + 1
  end

  local exact = #sourceBytes == #pairBytes

  for _, bytes in pairBytes do
    local count = counter[bytes]

    if not count or count == 0 then
      exact = false
      break
    end

    counter[bytes] = count - 1
  end

  local dataKeys, contentKeys = {}, {}

  for _, record in dataRecords do
    local recordKey = recordKey(record)

    if recordKey then dataKeys[recordKey] = true end
  end

  for _, record in contentRecords do
    local recordKey = recordKey(record)

    if recordKey then
      if dataKeys[recordKey] then error 'split produced duplicate type/ID records' end

      contentKeys[recordKey] = true
    end
  end

  local allKeys = table.clone(dataKeys)

  for recordKey in contentKeys do
    allKeys[recordKey] = true
  end

  local known = namespace(allKeys)
  local sourceEffective, sourceOrder = uniqueRecords(sourceRecords)
  local pairEffective = uniqueRecords(pairRecords)
  local union: { [string]: boolean } = {}

  for _, recordKey in sourceOrder do
    union[recordKey] = true
  end

  for recordKey in pairEffective do
    union[recordKey] = true
  end

  local mismatchKeys = {}

  for recordKey in union do
    local expected, actual = sourceEffective[recordKey], pairEffective[recordKey]

    if expected == nil or actual == nil or sourceBytes[expected] ~= pairBytes[actual] then
      table.insert(mismatchKeys, recordKey)
    end
  end

  table.sort(mismatchKeys)
  local mismatches = report.array()

  for _, recordKey in mismatchKeys do
    local kind, id = string.match(recordKey, '^(.-)%z(.*)$')
    table.insert(
      mismatches,
      report.object {
        'type',
        kind,
        'id',
        id,
        'source_present',
        sourceEffective[recordKey] ~= nil,
        'pair_present',
        pairEffective[recordKey] ~= nil,
      }
    )
  end

  local dataToContent, contentToData = report.array(), report.array()

  for index, record in dataRecords do
    for _, dependency in dependencies.of(record, index) do
      local targets = targetKeys(dependency, known)

      if intersects(targets, contentKeys) and not intersects(targets, dataKeys) then
        table.insert(dataToContent, dependencyJson(dependency))
      end
    end
  end

  for index, record in contentRecords do
    for _, dependency in dependencies.of(record, index) do
      local targets = targetKeys(dependency, known)

      if intersects(targets, dataKeys) and not intersects(targets, contentKeys) then
        table.insert(contentToData, dependencyJson(dependency))
      end
    end
  end

  local sourceKeys: { [string]: boolean } = {}

  for recordKey in sourceEffective do
    sourceKeys[recordKey] = true
  end

  local sourceUnresolved = unresolved(sourceRecords, namespace(sourceKeys))
  local pairUnresolved = unresolved(pairRecords, known)
  local sourceIdentities: { [string]: boolean } = {}

  for _, dependency in sourceUnresolved do
    sourceIdentities[identity(dependency)] = true
  end

  local newUnresolved = report.array()
  local pairUnresolvedJson = report.array()

  for _, dependency in pairUnresolved do
    table.insert(pairUnresolvedJson, dependencyJson(dependency))

    if not sourceIdentities[identity(dependency)] then
      table.insert(newUnresolved, dependencyJson(dependency))
    end
  end

  local forbidden: { [string]: boolean } = {}

  for _, record in dataRecords do
    local kind = tes3.string(record.type)

    if
      ForbiddenInData[kind]
      or (kind == 'Script' and not ApprovedDataScripts[string.lower(tes3.auditId(record))])
    then
      forbidden[kind] = true
    end
  end

  local forbiddenList = {}

  for kind in forbidden do
    table.insert(forbiddenList, kind)
  end

  local dataHeader = (data:decode(0) :: unknown) :: Table
  local contentHeader = (content:decode(0) :: unknown) :: Table

  local result = report.object {
    'source_records',
    #sourceRecords,
    'data_records',
    #dataRecords,
    'content_records',
    #contentRecords,
    'reconstruction_exact',
    exact,
    'effective_record_mismatch_count',
    #mismatches,
    'effective_record_mismatches',
    mismatches,
    'data_to_content_dependency_count',
    #dataToContent,
    'data_to_content_dependencies',
    dataToContent,
    'content_to_data_dependency_count',
    #contentToData,
    'content_to_data_dependencies',
    contentToData,
    'source_unresolved_dependency_count',
    #sourceUnresolved,
    'unresolved_dependency_count',
    #pairUnresolved,
    'unresolved_dependencies',
    pairUnresolvedJson,
    'new_unresolved_dependency_count',
    #newUnresolved,
    'new_unresolved_dependencies',
    newUnresolved,
    'data_header_masters',
    report.snake(dataHeader.masters :: Json),
    'content_header_masters',
    report.snake(contentHeader.masters :: Json),
    'data_header_file_type',
    dataHeader.fileType :: Json,
    'content_header_file_type',
    contentHeader.fileType :: Json,
    'forbidden_content_types_in_data',
    sortedNames(forbiddenList),
  }

  if not exact then
    error 'Star_Data + Starwind does not reconstruct the source records'
  elseif #dataToContent > 0 then
    error 'Star_Data contains a dependency on Starwind content'
  elseif #newUnresolved > 0 then
    error 'Star_Data + Starwind introduces unresolved dependencies'
  elseif #mismatches > 0 then
    error 'Star_Data + Starwind changes effective records'
  elseif #forbiddenList > 0 then
    error 'content record family leaked into Star_Data'
  end

  return result
end

-- The records after a written plugin's header, decoded as tes3conv reads them, and their bytes.
function split.readBack(plugin: core.Plugin): Written
  local records, bytes = readBack(plugin)
  return {
    header = (plugin:decode(0) :: unknown) :: tes3.Record,
    records = records,
    bytes = bytes,
  }
end

-- Splits `source` (the monolith's records, header first) into the two plugins, writes them,
-- and checks them as written. `paths` are where: `source` (the monolith as written), `data`,
-- `content`, and `report`. `written` is the monolith as written and read back, when the caller
-- has it already.
function split.split(
  source: Records,
  paths: { source: string, data: string, content: string, report: string },
  written: Written?
): Result
  -- split_starwind.py reads the monolith through tes3conv, which sorts it.
  source = tes3conv.sort(source)
  local dataIndices, demotions = split.choose(source)
  local dataRecords: Records = { source[1] }
  local contentRecords: Records = { source[1] }

  for index = 2, #source do
    table.insert(if dataIndices[index - 1] then dataRecords else contentRecords, source[index])
  end

  local writtenSource = written
  if not writtenSource then
    local sourceBytes = assert(jess.fs.readBuffer(paths.source), `failed to read '{paths.source}'`)
    writtenSource = split.readBack(core.open(sourceBytes))
  end

  assert(
    #writtenSource.records == #source - 1 and #writtenSource.bytes == #source - 1,
    'Starwind split: source records and written records have different counts'
  )
  for index = 2, #source do
    local expected, actual = source[index], writtenSource.records[index - 1]
    assert(
      expected.type == actual.type and tes3.auditId(expected) == tes3.auditId(actual),
      `Starwind split: written record {index - 1} does not match the sorted source`
    )
  end

  -- Only the headers change. Copy the sorted monolith's original body bytes into each half,
  -- rather than normalizing records through a decode/encode round trip.
  dataRecords[1] = header(source[1], #dataRecords - 1, {}, 'Esm')
  local data = tes3conv.plugin { dataRecords[1] }
  for index = 2, #source do
    if dataIndices[index - 1] then data:insert(data:count(), writtenSource.bytes[index - 1]) end
  end

  local dataBytes = data:save()
  jess.fs.replace(paths.data, dataBytes)
  local dataName = jess.fs.fileName(paths.data) :: string
  local dataSize = buffer.len(dataBytes)
  contentRecords[1] = header(source[1], #contentRecords - 1, { { dataName, dataSize } }, 'Esp')
  local content = tes3conv.plugin { contentRecords[1] }
  for index = 2, #source do
    if not dataIndices[index - 1] then content:insert(content:count(), writtenSource.bytes[index - 1]) end
  end

  jess.fs.replace(paths.content, content:save())
  local writtenDataBytes = assert(jess.fs.readBuffer(paths.data), `failed to read '{paths.data}'`)
  local writtenContentBytes = assert(jess.fs.readBuffer(paths.content), `failed to read '{paths.content}'`)
  local writtenData = core.open(writtenDataBytes)
  local writtenContent = core.open(writtenContentBytes)
  local result = validate(writtenSource, writtenData, writtenContent)

  local dataTypes: { [string]: boolean } = {}

  for index = 2, #dataRecords do
    dataTypes[tes3.string(dataRecords[index].type)] = true
  end

  local dataTypeList = {}

  for kind in dataTypes do
    table.insert(dataTypeList, kind)
  end

  local approved = {}

  for id in ApprovedDataScripts do
    table.insert(approved, id)
  end

  local dataBody = table.clone(dataRecords)
  table.remove(dataBody, 1)
  local contentBody = table.clone(contentRecords)
  table.remove(contentBody, 1)

  report.set(result, 'source', paths.source)
  report.set(result, 'data_output', paths.data)
  report.set(result, 'content_output', paths.content)
  report.set(result, 'always_data_types', sortedNames(AlwaysData))
  report.set(result, 'candidate_data_types', sortedNames(CandidateData))
  report.set(result, 'approved_data_script_ids', sortedNames(approved))
  report.set(result, 'data_types', sortedNames(dataTypeList))
  report.set(result, 'data_type_counts', typeCounts(dataBody))
  report.set(result, 'content_type_counts', typeCounts(contentBody))
  report.set(result, 'demoted_candidates', report.array(demotions))
  report.write(paths.report, result)

  return { report = result, data = writtenData, content = writtenContent }
end

return split
