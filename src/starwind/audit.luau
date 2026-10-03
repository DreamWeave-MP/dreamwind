--!strict
--!native
-- build_starwind.assert_main_quest and motherjungle_audit.audit: the main quest's anchors at
-- every checkpoint, and the masterless plugin's hard references, all resolved.

local dependencies = require './dependencies'
local report = require './report'
local sources = require './sources'
local tes3 = require '../lib/tes3'
local tes3conv = require '@dreamwind/tools/tes3conv'

type Record = tes3.Record
type Records = tes3.Records
type Table = tes3.Table
type Json = report.Json

local audit = {}

export type Staged = { name: string, records: Records }

local function anchors(): { string }
  local list = {}

  for _, anchor in sources.MainQuestAnchors do
    table.insert(list, `{anchor[1]}:{anchor[2]}`)
  end

  table.sort(list)
  return list
end

local function referenceAnchors(): { string }
  local list = table.clone(sources.MainQuestCellReferenceAnchors)
  table.sort(list)
  return list
end

local function scan(
  records: Records,
  found: { [string]: boolean },
  references: { [string]: boolean },
  realize: boolean
)
  for index = 2, #records do
    local record = records[index]

    if tes3conv.isLazy(record) then
      if not realize then continue end

      tes3conv.realize(record)
    end

    local id = tes3.auditId(record)

    if id ~= '' then found[`{tes3.string(record.type)}\0{string.lower(id)}`] = true end

    if record.type == 'Cell' then
      for _, value in (record.references or {}) :: { tes3.Value } do
        local reference = value :: Table

        if tes3.string(reference.id) ~= '' and not reference.deleted then
          references[tes3.lower(reference.id)] = true
        end
      end
    end
  end
end

local function missing(
  found: { [string]: boolean },
  references: { [string]: boolean }
): ({ string }, { string })
  local records, cells = {}, {}

  for _, anchor in sources.MainQuestAnchors do
    if not found[`{anchor[1]}\0{string.lower(anchor[2])}`] then
      table.insert(records, `{anchor[1]}:{anchor[2]}`)
    end
  end

  for _, anchor in sources.MainQuestCellReferenceAnchors do
    if not references[string.lower(anchor)] then table.insert(cells, anchor) end
  end

  table.sort(records)
  table.sort(cells)
  return records, cells
end

-- One checkpoint of the main-quest guard over the staged plugins, recorded in `checks` and
-- written to `path`. Raises when an anchor is gone. Records read lazily are read only when the
-- rest leave an anchor missing: Morrowind's cells can't hold Starwind's quest giver.
function audit.mainQuest(stage: string, staged: { Staged }, checks: { Json }, path: string)
  local found, references = {}, {}

  for _, plugin in staged do
    scan(plugin.records, found, references, false)
  end

  local records, cells = missing(found, references)

  if #records > 0 or #cells > 0 then
    for _, plugin in staged do
      scan(plugin.records, found, references, true)
    end

    records, cells = missing(found, references)
  end

  local names = {}

  for _, plugin in staged do
    table.insert(names, plugin.name)
  end

  table.insert(
    checks,
    report.object {
      'stage',
      stage,
      'paths',
      report.array(names),
      'missing',
      report.array(records),
      'missing_cell_references',
      report.array(cells),
    }
  )

  report.write(
    path,
    report.object {
      'anchors',
      report.array(anchors()),
      'cell_reference_anchors',
      report.array(referenceAnchors()),
      'checks',
      report.array(checks),
    }
  )

  if #records > 0 or #cells > 0 then
    error(
      `main-quest preservation failed at {stage}: records=[{table.concat(records, ', ')}], cell_references=[{table.concat(
        cells,
        ', '
      )}]`
    )
  end
end

local function dependencyJson(dependency: dependencies.Dependency, provenance: string?): Json
  local pairs: { Json? } = {
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

  if provenance then
    table.insert(pairs, 'source_provenance')
    table.insert(pairs, provenance)
  end

  return report.object(pairs)
end

export type Closure = { counts: { [string]: Json }, report: Json, hard: number }

-- motherjungle_audit.audit: `records` is the masterless plugin as written and read back.
-- `knownSources` is called only when something is unresolved, for the records of every source,
-- to tell inherited references from imported ones.
function audit.closure(records: Records, path: string, knownSources: () -> { Records }): Closure
  local header = if records[1] and records[1].type == 'Header' then records[1] else nil
  local ids: { [string]: boolean } = {}

  for _, record in records do
    local id = tes3.auditId(record)

    if id ~= '' then ids[string.lower(id)] = true end
  end

  local hard: { dependencies.Dependency } = {}

  for index, record in records do
    for _, dependency in dependencies.of(record, index - 1) do
      if dependencies.HardKinds[dependency.kind] and not ids[dependency.target] then
        table.insert(hard, dependency)
      end
    end
  end

  local known: { [string]: boolean } = {}

  if #hard > 0 then
    for _, source in knownSources() do
      for _, record in source do
        local id = tes3.auditId(record)

        if id ~= '' then known[`{tes3.string(record.type)}\0{string.lower(id)}`] = true end
      end
    end
  end

  local provenance: { string } = {}
  local uniqueIds, sourceRecords, imported = {}, {}, {}
  local byKind: { [string]: number } = {}
  local kindOrder = {}

  for index, dependency in hard do
    local sourceKey = `{dependency.source_type}\0{string.lower(dependency.source_id)}`
    provenance[index] = if known[sourceKey] then 'KNOWN_INPUT' else 'FINAL_ONLY_LIKELY_IMPORTED'
    uniqueIds[dependency.target] = true
    local recordKey = `{dependency.source_type}\0{dependency.source_id}`
    sourceRecords[recordKey] = true

    if provenance[index] == 'FINAL_ONLY_LIKELY_IMPORTED' then imported[recordKey] = true end

    if byKind[dependency.kind] == nil then
      table.insert(kindOrder, dependency.kind)
      byKind[dependency.kind] = 0
    end

    byKind[dependency.kind] += 1
  end

  local function count(set: { [string]: boolean }): number
    local total = 0

    for _ in set do
      total += 1
    end

    return total
  end

  local masters = header and #((header.masters or {}) :: { tes3.Value }) or 0
  local counts = report.object {
    'records_including_header',
    #records,
    'masters',
    masters,
    'hard_unresolved_occurrences',
    #hard,
    'hard_unresolved_unique_ids',
    count(uniqueIds),
    'hard_unresolved_source_records',
    count(sourceRecords),
    'hard_unresolved_sources_likely_imported',
    count(imported),
  }

  -- Counter.most_common(): by count, ties in first-seen order.
  local positions = {}

  for position, kind in kindOrder do
    positions[kind] = position
  end

  table.sort(kindOrder, function(left, right)
    if byKind[left] ~= byKind[right] then return byKind[left] > byKind[right] end

    return positions[left] < positions[right]
  end)

  local kindPairs = {}

  for _, kind in kindOrder do
    table.insert(kindPairs, kind)
    table.insert(kindPairs, byKind[kind])
  end

  local unresolved = report.array()

  for index, dependency in hard do
    table.insert(unresolved, dependencyJson(dependency, provenance[index]))
  end

  local missingIds = {}

  for id in uniqueIds do
    table.insert(missingIds, id)
  end

  table.sort(missingIds)

  local result = report.object {
    'header',
    if header then report.snake(header :: Json) else report.dict(),
    'counts',
    counts,
    'hard_by_kind',
    report.object(kindPairs),
    'hard_unresolved',
    unresolved,
    'hard_missing_ids',
    report.array(missingIds),
  }

  report.write(path, result, false)
  return { counts = counts, report = result, hard = #hard }
end

return audit
