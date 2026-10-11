--!strict
--!native
--[[
@dreamwind/tools/tes3merge: TES3Merge's object merging, as a function of (state, openmw), openmw
being the load order's config from `jess.openmw.load`.

Options, from `state.tes3merge`:
  recordTypes    { string }            [RecordTypes]
  records        { string }            --records
  ignoreRecords  { string }            --ignore-records
  fileFilters    { [string]: boolean } [FileFilters]; false skips a file
  objectFilters  { { string | boolean } }  [ObjectFilters]; { pattern, allow }, last match wins
  inclusive      boolean               --inclusive
  noMasters      boolean               --no-masters
  patches        { string }            --patches; fogbug, summons, cellnames, all, none; default { "all" }
  encoding       Encoding | number     [General] TextEncodingCode; default openmw.cfg's encoding=
  fileName       string                default "Merged Objects.esp"
  outputDir      string                default data-local, else the first data folder
  activate       boolean               enable the result in openmw.cfg; skipped when outputDir isn't a data folder
  verbose        boolean

Afterwards `state.tes3merge.report` holds { path, masters, files, candidates, merged, failed, activated }.

Ported from TES3Merge (https://github.com/NullCascade/TES3Merge):

The MIT License

Copyright (c) 2019 NullCascade

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

type Key = string | number
type Value = boolean | number | string | Table
type Table = { [Key]: Value }
type Set = { [string]: boolean }
type Merger = (current: Table, first: Table, later: Table, key: string) -> boolean
type Definition = { file: string, record: Record }

type Report = {
  path: string?,
  masters: { string },
  files: number,
  candidates: number,
  merged: { [string]: number },
  failed: { string },
  activated: boolean?,
}

type Options = {
  recordTypes: { string }?,
  records: { string }?,
  ignoreRecords: { string }?,
  fileFilters: { [string]: boolean }?,
  objectFilters: { { string | boolean } }?,
  inclusive: boolean?,
  noMasters: boolean?,
  patches: { string }?,
  encoding: (Encoding | number)?,
  fileName: string?,
  outputDir: string?,
  activate: boolean?,
  verbose: boolean?,
  report: Report?,
}

return function(state: { [string]: unknown }?, openmw: OpenMwContext?)
  local shared: { [string]: unknown } = state or {}
  local options: Options = (shared.tes3merge :: Options?) or {}
  shared.tes3merge = options

  local function set(list: { string }?): Set
    local result: Set = {}
    for _, value in list or {} do
      result[value] = true
    end

    return result
  end

  local DefaultRecordTypes: { string } = {
    'ACTI',
    'ALCH',
    'APPA',
    'ARMO',
    'BODY',
    'BOOK',
    'BSGN',
    'CELL',
    'CLAS',
    'CLOT',
    'CONT',
    'CREA',
    'DOOR',
    'ENCH',
    'GMST',
    'INGR',
    'LEVC',
    'LEVI',
    'LIGH',
    'LOCK',
    'MGEF',
    'MISC',
    'NPC_',
    'PROB',
    'RACE',
    'REPA',
    'SKIL',
    'SNDG',
    'SOUN',
    'SPEL',
    'STAT',
    'WEAP',
  }

  local SummonedCreatures = set {
    'centurion_fire_dead',
    'wraith_sul_senipul',
    'ancestor_ghost_summon',
    'atronach_flame_summon',
    'atronach_frost_summon',
    'atronach_storm_summon',
    'bonelord_summon',
    'bonewalker_summon',
    'bonewalker_greater_summ',
    'centurion_sphere_summon',
    'clannfear_summon',
    'daedroth_summon',
    'dremora_summon',
    'golden saint_summon',
    'hunger_summon',
    'scamp_summon',
    'skeleton_summon',
    'ancestor_ghost_variner',
    'fabricant_summon',
    'bm_bear_black_summon',
    'bm_wolf_grey_summon',
    'bm_wolf_bone_summon',
  }

  -- Cell renames always merge, so cellnames needs nothing of its own.
  local PatchNames: { [string]: { string } } = {
    all = { 'fogbug', 'summons' },
    none = {},
    fogbug = { 'fogbug' },
    summons = { 'summons' },
    cellnames = {},
  }

  local mergeTypes: Set, patches: Set = {}, {}
  local onlyTypes: Set? = if options.records then set(options.records) else nil
  local ignoredTypes = set(options.ignoreRecords)

  for _, tag in options.recordTypes or DefaultRecordTypes do
    if (onlyTypes and not onlyTypes[tag]) or ignoredTypes[tag] then continue end

    mergeTypes[tag] = true
  end

  if not next(mergeTypes) then error 'tes3merge: no record types left to merge' end

  for _, name in options.patches or { 'all' } do
    local enabled = PatchNames[string.lower(name)]
      or error(
        `tes3merge: unknown patch "{name}"; expected fogbug, summons, cellnames, all, or none`
      )

    for _, patchName in enabled do
      patches[patchName] = true
    end
  end

  local fileName: string = options.fileName or 'Merged Objects.esp'

  local function asTable(value: Value?): Table? return if type(value) == 'table' then value else nil end

  local function asString(value: Value?): string?
    return if type(value) == 'string' then value else nil
  end

  local function isArray(value: Value?): boolean
    return type(value) == 'table' and (getmetatable(value) ~= nil or #value > 0)
  end

  -- NaN equals NaN, as it does for .NET's float Equals. A field set to false differs from one that's
  -- missing.
  local function equal(left: Value?, right: Value?): boolean
    if left == right then return true end

    if type(left) == 'number' and type(right) == 'number' then
      return left ~= left and right ~= right
    end

    if type(left) ~= 'table' or type(right) ~= 'table' then return false end

    for key, value in left do
      if not equal(value, right[key]) then return false end
    end

    for key in right do
      if left[key] == nil then return false end
    end

    return true
  end

  -- Keeps jess's array marker, so empty lists stay lists.
  local function likeTable(result: Table, source: Value?): Table
    if type(source) ~= 'table' then return result end

    local metatable = getmetatable(source)
    if type(metatable) == 'table' then setmetatable(result, metatable) end

    return result
  end

  local function copyTable(value: Table): Table
    local result: Table = {}
    for key, item in value do
      result[key] = if type(item) == 'table' then copyTable(item) else item
    end

    return likeTable(result, value)
  end

  local function copy(value: Value?): Value?
    return if type(value) == 'table' then copyTable(value) else value
  end

  local function hasFlag(flags: Value?, flag: string): boolean
    if type(flags) ~= 'string' then return false end

    for name in string.gmatch(flags, '[^|%s]+') do
      if name == flag then return true end
    end

    return false
  end

  local function contains(list: Table, value: Value): boolean
    for _, item in list do
      if equal(item, value) then return true end
    end

    return false
  end

  -- Takes `later`'s value when `current` still has the first definition's.
  local function mergeBase(current: Table, first: Table, later: Table, key: Key): boolean
    if not equal(current[key], first[key]) or equal(later[key], first[key]) then return false end

    current[key] = copy(later[key]) :: Value
    return true
  end

  local mergeAll: (
    current: Table?,
    first: Table?,
    later: Table?,
    special: { [string]: Merger }?,
    skip: Set?
  ) -> boolean

  local function mergeField(
    current: Table,
    first: Table,
    later: Table,
    key: string,
    special: { [string]: Merger }?
  ): boolean
    local merger = special and special[key]
    if merger then return merger(current, first, later, key) end

    local value, firstValue, laterValue =
      asTable(current[key]), asTable(first[key]), asTable(later[key])
    if not value or not firstValue or not laterValue then
      return mergeBase(current, first, later, key)
    end

    if isArray(value) or isArray(firstValue) or isArray(laterValue) then
      return mergeBase(current, first, later, key)
    end

    -- TES3Merge counts a nested structure as changed whenever it merges one.
    mergeAll(value, firstValue, laterValue)
    return true
  end

  -- A field set to false is a value, so only a missing field counts as absent, except that a
  -- record's own string fields are empty when it doesn't have their subrecord. TES3Merge sees those
  -- as missing (null) subrecords, so the top level (`skip` is only passed there) treats '' as absent.
  function mergeAll(
    current: Table?,
    first: Table?,
    later: Table?,
    special: { [string]: Merger }?,
    skip: Set?
  ): boolean
    if not later or not current then return false end

    local empty: string? = if skip then '' else nil

    local base: Table, keys: Set = first or {}, {}

    for key in later do
      if type(key) == 'string' then keys[key] = true end
    end

    for key in base do
      if type(key) == 'string' then keys[key] = true end
    end

    local modified = false
    for key in keys do
      if key == 'type' or (skip and skip[key]) then continue end

      local value, firstValue, laterValue = current[key], base[key], later[key]
      if firstValue == nil and value == nil and laterValue ~= nil then
        current[key] = copy(laterValue) :: Value
        modified = true
      elseif
        (firstValue ~= nil and firstValue ~= empty) and (laterValue == nil or laterValue == empty)
      then
        -- A later plugin clearing a value keeps the latest one.
        modified = true
      elseif mergeField(current, base, later, key, special) then
        modified = true
      end
    end

    return modified
  end

  local function effectList(current: Table, first: Table, later: Table, key: string): boolean
    local list = asTable(current[key]) or asTable(copy(first[key] or later[key]))
    if not list then return false end

    current[key] = list

    local firstList: Table, laterList: Table = asTable(first[key]) or {}, asTable(later[key]) or {}
    local modified = false

    for index = 1, 8 do
      local value, firstValue, laterValue =
        asTable(list[index]), asTable(firstList[index]), asTable(laterList[index])

      if value and firstValue and laterValue then
        if not equal(laterValue.magicEffect, firstValue.magicEffect) then
          list[index] = copyTable(laterValue)
          modified = true
        elseif mergeAll(value, firstValue, laterValue) then
          modified = true
        end
      elseif not firstValue and laterValue then
        list[#list + 1] = copyTable(laterValue)
        modified = true
      end
    end

    return modified
  end

  local function itemsList(current: Table, first: Table, later: Table, key: string): boolean
    local firstList, laterList, list =
      asTable(first[key]), asTable(later[key]), asTable(current[key])
    if not firstList or not laterList or not list then return false end

    local union: Table = {}
    for _, source in { firstList, list, laterList } do
      for _, item in source do
        if not contains(union, item) then union[#union + 1] = copy(item) :: Value end
      end
    end

    if equal(union, firstList) then return false end

    current[key] = likeTable(union, firstList)
    return true
  end

  local function wanderPackage(list: Value?): Table?
    for _, package in asTable(list) or {} do
      local fields = asTable(package)
      if fields and fields.type == 'Wander' then return fields end
    end

    return nil
  end

  local function aiPackages(current: Table, first: Table, later: Table, key: string): boolean
    local value, firstValue, laterValue =
      wanderPackage(current[key]), wanderPackage(first[key]), wanderPackage(later[key])

    -- TES3Merge reports a change here without making one.
    if not firstValue and laterValue then return true end
    if not value or not firstValue or not laterValue then return false end

    return mergeAll(value, firstValue, laterValue)
  end

  local function npcData(current: Table, first: Table, later: Table, key: string): boolean
    local data, firstData, laterData =
      asTable(current[key]), asTable(first[key]), asTable(later[key])
    if not data or not firstData or not laterData then
      return mergeBase(current, first, later, key)
    end

    local modified = false
    for _, field in { 'level', 'disposition', 'reputation', 'rank', 'gold' } do
      if mergeBase(data, firstData, laterData, field) then modified = true end
    end

    local laterStats = asTable(laterData.stats)
    if data.stats == nil and laterStats then
      data.stats = copyTable(laterStats)
      return true
    end

    local stats, firstStats = asTable(data.stats), asTable(firstData.stats) or laterStats
    if not stats or not firstStats or not laterStats then return modified end

    for _, field in { 'health', 'magicka', 'fatigue' } do
      if mergeBase(stats, firstStats, laterStats, field) then modified = true end
    end

    for _, listName in { 'attributes', 'skills' } do
      local values, firstValues, laterValues =
        asTable(stats[listName]), asTable(firstStats[listName]), asTable(laterStats[listName])

      if not values or not firstValues or not laterValues or equal(values, laterValues) then
        continue
      end

      for index = 1, #values do
        if values[index] ~= firstValues[index] or laterValues[index] == firstValues[index] then
          continue
        end

        values[index] = laterValues[index]
        modified = true
      end
    end

    return modified
  end

  local function entryId(entry: Table): string return tostring(entry[1]) end

  local function entryLevel(entry: Table): number
    local level = entry[2]
    return if type(level) == 'number' then level else 0
  end

  -- Each { id, level } entry appears as many times as the list with the most of it has it.
  local function leveledList(current: Table, first: Table, later: Table, key: string): boolean
    local firstList, laterList = asTable(first[key]), asTable(later[key])
    local list = asTable(current[key]) or firstList or laterList
    if not list then return false end

    local counts: { [string]: { entry: Table, count: number } }, order: { string } = {}, {}

    for _, source in { firstList or {}, list, laterList or {} } do
      local seen: { [string]: number } = {}

      for _, item in source do
        local entry = asTable(item)
        if not entry then continue end

        local entryKey = entryId(entry) .. '\0' .. tostring(entry[2])
        seen[entryKey] = (seen[entryKey] or 0) + 1
        if counts[entryKey] then continue end

        counts[entryKey] = { entry = entry, count = 0 }
        table.insert(order, entryKey)
      end

      for entryKey, count in seen do
        counts[entryKey].count = math.max(counts[entryKey].count, count)
      end
    end

    local union: { Table } = {}
    for _, entryKey in order do
      for _ = 1, counts[entryKey].count do
        table.insert(union, copyTable(counts[entryKey].entry))
      end
    end

    table.sort(union, function(left: Table, right: Table): boolean
      if entryLevel(left) ~= entryLevel(right) then return entryLevel(left) < entryLevel(right) end

      return entryId(left) < entryId(right)
    end)

    local merged: Table = {}
    for index, entry in union do
      merged[index] = entry
    end

    if equal(merged, firstList) then return false end

    current[key] = likeTable(merged, firstList or list)
    return true
  end

  local function namedFields(fields: { string }): Merger
    return function(current: Table, first: Table, later: Table, key: string): boolean
      local value, firstValue, laterValue =
        asTable(current[key]), asTable(first[key]), asTable(later[key])
      if not value or not firstValue or not laterValue then
        return mergeBase(current, first, later, key)
      end

      local modified = false
      for _, field in fields do
        if mergeBase(value, firstValue, laterValue, field) then modified = true end
      end

      return modified
    end
  end

  local SpecialMergers: { [string]: { [string]: Merger } } = {
    Spell = { effects = effectList },
    Enchanting = { effects = effectList },
    Alchemy = { effects = effectList },
    Npc = { aiPackages = aiPackages, data = npcData },
    Creature = { aiPackages = aiPackages },
    LeveledItem = { items = leveledList },
    LeveledCreature = { creatures = leveledList },
    Class = { data = namedFields { 'specialization', 'flags' } },
    Faction = { data = namedFields { 'flags' } },
  }

  if options.inclusive then
    for _, recordType in { 'Npc', 'Creature', 'Container' } do
      local special = SpecialMergers[recordType] or {}
      special.inventory = itemsList
      SpecialMergers[recordType] = special
    end
  end

  local function mergeFlags(current: Table, first: Table, later: Table): boolean
    if not equal(current.flags, first.flags) or equal(later.flags, first.flags) then
      return false
    end

    current.flags = later.flags
    return true
  end

  -- Only a cell's flags merge, plus an exterior cell's name (the cellnames fix).
  local function mergeCell(current: Table, first: Table, later: Table): boolean
    local modified = mergeFlags(current, first, later)

    local data = asTable(current.data)
    local name, firstName, laterName =
      asString(current.name), asString(first.name), asString(later.name)
    if hasFlag(data and data.flags, 'IS_INTERIOR') or not laterName then return modified end

    if not firstName and not name then
      current.name = laterName
      return true
    end

    if name ~= firstName or laterName == firstName or laterName == '' then return modified end

    current.name = laterName
    return true
  end

  local TopLevelSkip: Set = { flags = true }

  local function mergeRecord(current: Table, first: Table, later: Table): boolean
    if current.type == 'Cell' then return mergeCell(current, first, later) end

    local modified = mergeFlags(current, first, later)
    local recordType = current.type
    local special = if type(recordType) == 'string' then SpecialMergers[recordType] else nil
    if mergeAll(current, first, later, special, TopLevelSkip) then modified = true end

    return modified
  end

  local function patchSummon(record: Table): boolean
    local id = record.id
    if type(id) ~= 'string' or not SummonedCreatures[string.lower(id)] then return false end
    if hasFlag(record.flags, 'PERSISTENT') then return false end

    local flags = record.flags
    record.flags = if type(flags) == 'string' and flags ~= ''
      then flags .. ' | PERSISTENT'
      else 'PERSISTENT'
    return true
  end

  local function patchFog(record: Table): boolean
    local data = asTable(record.data)
    local flags = data and data.flags
    if not hasFlag(flags, 'IS_INTERIOR') or hasFlag(flags, 'BEHAVES_LIKE_EXTERIOR') then
      return false
    end

    local atmosphere = asTable(record.atmosphereData)
    if not atmosphere or atmosphere.fogDensity ~= 0 then return false end

    atmosphere.fogDensity = 0.01
    return true
  end

  local function patch(record: Table): boolean
    if patches.summons and record.type == 'Creature' and patchSummon(record) then return true end
    if patches.fogbug and record.type == 'Cell' and patchFog(record) then return true end

    return false
  end

  -- Whether `patch` would change the record, read through its view.
  local function wouldPatch(record: Record): boolean
    local tag = jess.meta(record).tag
    if patches.summons and tag == 'CREA' then
      local creature = record :: CreatureRecord
      if not SummonedCreatures[string.lower(creature.id)] then return false end

      return not hasFlag(creature.flags, 'PERSISTENT')
    end

    if not patches.fogbug or tag ~= 'CELL' then return false end

    local cell = record :: CellRecord
    local flags, atmosphere = cell.data.flags, cell.atmosphereData
    if not hasFlag(flags, 'IS_INTERIOR') or hasFlag(flags, 'BEHAVES_LIKE_EXTERIOR') then
      return false
    end

    if not atmosphere then return false end

    return atmosphere.fogDensity == 0
  end

  -- `Record:decode` throws when a record's bytes don't parse as its type. TES3Merge reports that
  -- group as failed and merges the rest, so this is the one place a decoding error is caught.
  local function decode(record: Record): (Table?, string?)
    local decoded, value = pcall(record.decode, record)
    if not decoded then return nil, tostring(value) end

    return if value then value :: Table else nil, nil
  end

  assert(openmw, 'tes3merge needs an OpenMW config')
  local context: OpenMwContext = openmw

  local CodePages: { [number]: Encoding } =
    { [1250] = 'win1250', [1251] = 'win1251', [1252] = 'win1252' }

  local function textEncoding(): Encoding
    local option = options.encoding
    if type(option) ~= 'number' then return option or context.encoding or 'win1252' end

    return CodePages[option]
      or error(`tes3merge: encoding code {option} isn't supported; expected 1250, 1251, or 1252`)
  end

  local encoding = textEncoding()

  local ignoredFiles: Set = { [string.lower(fileName)] = true }
  for name, allow in options.fileFilters or {} do
    if allow == false then ignoredFiles[string.lower(name)] = true end
  end

  local loadOrder: { string }, plugins: { [string]: Plugin }, unreadable: { string } = {}, {}, {}
  local sizes: { [string]: number } = {}
  local names: { string }, paths: { string }, mergeTags: { string } = {}, {}, {}

  for _, content in context:content() do
    local name, path = string.lower(content.name), content.path
    if ignoredFiles[name] or not path or string.find(name, '%.omwscripts$') then continue end

    table.insert(names, content.name)
    table.insert(paths, path)
  end

  for tag in mergeTypes do
    table.insert(mergeTags, tag)
  end

  -- Plugins come back in order, without the ones that failed.
  local opened, failures = jess.plugin.openAll(paths, {
    types = mergeTags,
    decode = true,
    cell = { references = false },
    openmw = false,
    encoding = encoding,
  })

  local nextPlugin = 1
  for index, path in paths do
    local failure = failures[path]
    if failure then
      table.insert(unreadable, `{names[index]}: {failure}`)
      continue
    end

    table.insert(loadOrder, names[index])
    plugins[names[index]] = opened[nextPlugin]
    sizes[names[index]] = jess.fs.size(path) :: number
    nextPlugin += 1
  end

  -- Groups go by type, in the order each type first appears, then by id, in the order each id first
  -- appears: TES3Merge's dictionaries iterate in insertion order, and its output follows them.
  local groups: { [string]: { Definition } }, groupOrder: { [string]: { string } } = {}, {}
  local typeOrder: { string } = {}
  local objectFilters: { { string | boolean } } = options.objectFilters or {}

  -- Skills, magic effects, and exterior cells are identified by index or grid, not by id.
  local function identity(record: Record, meta: RecordMeta): string?
    local tag = meta.tag
    if tag == 'SKIL' then return tostring((record :: SkillRecord).skillId) end
    if tag == 'MGEF' then return tostring((record :: MagicEffectRecord).effectId) end
    if tag ~= 'CELL' then return meta.id end

    local data = (record :: CellRecord).data
    if hasFlag(data.flags, 'IS_INTERIOR') then return meta.id end

    return `#{tostring(data.grid[1])},{tostring(data.grid[2])}`
  end

  local function filterMatches(plugin: Plugin): { { [number]: boolean } }
    local matchesByFilter: { { [number]: boolean } } = {}

    for index, filter in objectFilters do
      local matches: { [number]: boolean } = {}
      local pattern = filter[1]

      if type(pattern) == 'string' then
        for record in plugin:select({ id = pattern }):records() do
          matches[jess.meta(record).index] = true
        end
      end

      matchesByFilter[index] = matches
    end

    return matchesByFilter
  end

  for _, name in loadOrder do
    local plugin = plugins[name]
    local matchesByFilter = filterMatches(plugin)

    for record in plugin:records() do
      local meta = jess.meta(record)
      local tag = meta.tag
      if not mergeTypes[tag] then continue end

      local allow = true
      for index, filter in objectFilters do
        if matchesByFilter[index][meta.index] then allow = filter[2] ~= false end
      end

      if not allow then continue end

      local id = identity(record, meta)
      if not id or id == '' then continue end

      local key = tag .. ':' .. string.lower(id)
      local group = groups[key]
      if not group then
        group = {}
        groups[key] = group

        local keys = groupOrder[tag]
        if not keys then
          keys = {}
          groupOrder[tag] = keys
          table.insert(typeOrder, tag)
        end

        table.insert(keys, key)
      end

      table.insert(group, { file = name, record = record })
    end
  end

  local report: Report = {
    path = nil,
    masters = {},
    files = #loadOrder,
    candidates = 0,
    merged = {},
    failed = unreadable,
  }

  options.report = report

  local merged: { Table }, usedMasters: Set = {}, {}

  local function mergeGroup(key: string, definitions: { Definition }): string?
    local count, tag = #definitions, string.sub(key, 1, 4)

    local last, lastFailure = decode(definitions[count].record)
    if lastFailure then return lastFailure end
    if not last then return nil end

    local current = copyTable(last)
    local used: Set = { [definitions[1].file] = true, [definitions[count].file] = true }
    local changed = false

    -- TES3Merge's merge reports a change for every record three or more plugins define, cells aside.
    local merging = count >= 3 and tag ~= 'CELL'

    if count >= 3 then
      local first, firstFailure = decode(definitions[1].record)
      if firstFailure then return firstFailure end

      for index = count - 1, 2, -1 do
        local later, laterFailure = decode(definitions[index].record)
        if laterFailure then return laterFailure end
        if first and later and mergeRecord(current, first, later) then changed = true end

        -- TES3Merge uses a plugin as a master once its merge has reported a change, its own or a
        -- later plugin's.
        if changed or merging then used[definitions[index].file] = true end
      end
    end

    -- TES3Merge only patches what its merge left alone (`isAnythingChanged || Patch(...)`).
    if not changed and not merging and patch(current) then changed = true end

    if current.type == 'Cell' then current.references = {} end
    if not changed or equal(current, last) then return nil end

    table.insert(merged, current)
    report.merged[tag] = (report.merged[tag] or 0) + 1

    for file in used do
      usedMasters[file] = true
    end

    if options.verbose then print(`Merged {tag} record: {string.sub(key, 6)}`) end

    return nil
  end

  for _, tag in typeOrder do
    for _, key in groupOrder[tag] do
      local definitions = groups[key]
      if #definitions >= 3 then
        report.candidates += 1
      elseif not wouldPatch(definitions[#definitions].record) then
        continue
      end

      local failure = mergeGroup(key, definitions)
      if failure then table.insert(report.failed, `{key}: {failure}`) end
    end
  end

  if #merged == 0 then
    print 'tes3merge: no merges were deemed necessary'
    return
  end

  local output = jess.plugin.new {
    author = 'TES3Merge',
    description = `Automatic merge generated at {os.date '!%Y-%m-%dT%H:%M:%SZ'}.`,
    encoding = encoding,
  }

  if not options.noMasters then
    local masters: { string | Master } = {}

    for _, name in loadOrder do
      if not usedMasters[name] then continue end

      table.insert(report.masters, name)
      table.insert(masters, { name = name, size = sizes[name] })
    end

    output:setMasters(masters)
  end

  for _, record in merged do
    output:insert(record :: RecordFields)
  end

  local outputDir = options.outputDir or context.writableDataDir
  assert(
    outputDir,
    'tes3merge: openmw.cfg has no data-local= or data= folder to write to; add one or set outputDir'
  )
  if not jess.fs.isDir(outputDir) then jess.fs.createDir(outputDir) end

  local path = `{outputDir}/{fileName}`
  output:save(path, { backup = false })
  report.path = path

  -- OpenMW only loads content files from its data folders, and `activate` throws for one anywhere
  -- else. A merge written outside them is left inactive rather than failing the run.
  if options.activate then
    local activated, problem = pcall(function() return context:activate(fileName) end)

    if activated then
      context:save()
    else
      print(
        `tes3merge: wrote {path} but didn't activate it, as OpenMW can't load it from there: {problem}`
      )
    end

    report.activated = activated
  end

  print(`tes3merge: wrote {#merged} merged records to {path}`)
end
