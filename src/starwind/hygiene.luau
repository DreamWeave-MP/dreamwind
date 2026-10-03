--!strict
--!native
-- dialogue_source_hygiene.py (v3): each Starwind source's physical INFOs classified against the
-- dialogue state they actually inherit, from the canonical JSON sources.
--
--   NEW_INFO                  no live inherited INFO with this topic and id
--   MODIFIED_PARENT           the inherited INFO exists, and this one changes its payload
--   REDUNDANT_EXACT_COPY      identical to the inherited INFO
--   PROBABLE_TESCS_LINK_DIRT  identical but for its previous/next links
--   DELETED_PARENT_OVERRIDE   deletes a live inherited INFO
--   REDUNDANT_DELETE          deletes one already deleted
--   ORPHAN_DELETE             deletes one never inherited

local report = require './report'
local tes3 = require '../lib/tes3'

type Record = tes3.Record
type Records = tes3.Records
type Table = tes3.Table
type Value = tes3.Value
type Json = report.Json

local hygiene = {}

export type Source = { path: string, records: Records, binary: string?, label: string }

type Item = { topic: string, id: string, recordIndex: number, record: Record }
type StateEntry = { record: Record, source: string, recordIndex: number }
export type State = { active: { [string]: StateEntry }, tombstones: { [string]: StateEntry } }

local function norm(value: Value?): string return string.lower(tes3.string(value)) end

function hygiene.physicalInfos(records: Records): { Item }
  local items = {}
  local topic: string? = nil

  for position, record in records do
    if record.type == 'Dialogue' then
      topic = norm(record.id)
    elseif record.type == 'DialogueInfo' and topic then
      table.insert(items, {
        topic = topic :: string,
        id = norm(record.id),
        recordIndex = position - 1,
        record = record,
      })
    else
      topic = nil
    end
  end

  return items
end

function hygiene.newState(): State return { active = {}, tombstones = {} } end

function hygiene.apply(state: State, records: Records, label: string)
  for _, item in hygiene.physicalInfos(records) do
    local key = `{item.topic}\0{item.id}`
    local entry = { record = item.record, source = label, recordIndex = item.recordIndex }

    if tes3.isDeleted(item.record) then
      state.active[key] = nil
      state.tombstones[key] = entry
    else
      state.active[key] = entry
      state.tombstones[key] = nil
    end
  end
end

function hygiene.vanillaState(vanilla: { Source }): State
  local state = hygiene.newState()

  for _, source in vanilla do
    hygiene.apply(state, source.records, source.label)
  end

  return state
end

local function withoutLinks(record: Record): Record
  local copy = table.clone(record)
  copy.prevId = nil
  copy.nextId = nil
  return copy
end

local function category(record: Record, active: StateEntry?, tombstone: StateEntry?): string
  if tes3.isDeleted(record) then
    if active then
      return 'DELETED_PARENT_OVERRIDE'
    elseif tombstone then
      return 'REDUNDANT_DELETE'
    end

    return 'ORPHAN_DELETE'
  end

  if not active then
    return 'NEW_INFO'
  elseif tes3.equal(record, active.record) then
    return 'REDUNDANT_EXACT_COPY'
  elseif tes3.equal(withoutLinks(record), withoutLinks(active.record)) then
    return 'PROBABLE_TESCS_LINK_DIRT'
  end

  return 'MODIFIED_PARENT'
end

function hygiene.compact(record: Record?): Json
  if not record then return nil end

  local info = record :: Record
  local data = (info.data or {}) :: Table

  return report.object {
    'id',
    info.id :: Json,
    'prev_id',
    info.prevId :: Json,
    'next_id',
    info.nextId :: Json,
    'speaker_id',
    info.speakerId :: Json,
    'speaker_race',
    info.speakerRace :: Json,
    'speaker_class',
    info.speakerClass :: Json,
    'speaker_faction',
    info.speakerFaction :: Json,
    'speaker_cell',
    info.speakerCell :: Json,
    'speaker_sex',
    data.speakerSex :: Json,
    'speaker_rank',
    data.speakerRank :: Json,
    'text',
    info.text :: Json,
    'result',
    nil,
    'filters',
    report.snake((info.filters or report.array()) :: Json),
  }
end

local function changedLinks(child: Record, parent: Record?): Json
  local result = report.object {}

  if not parent then return result end

  for _, pair in { { 'prevId', 'prev_id' }, { 'nextId', 'next_id' } } do
    local c, p = norm(child[pair[1]]), norm((parent :: Record)[pair[1]])

    if c ~= p then report.set(result, pair[2], report.object { 'parent', p, 'child', c }) end
  end

  return result
end

local function ordered(counts: { [string]: number }, order: { string }): Json
  local pairs = {}

  for _, key in order do
    table.insert(pairs, key)
    table.insert(pairs, counts[key])
  end

  return report.object(pairs)
end

type Counter = { counts: { [string]: number }, order: { string } }

local function counter(): Counter return { counts = {}, order = {} } end

local function bump(tally: Counter, key: string)
  if tally.counts[key] == nil then
    table.insert(tally.order, key)
    tally.counts[key] = 0
  end

  tally.counts[key] += 1
end

-- `classify_source`.
function hygiene.classify(source: Source, parent: State, parentModel: string?): { [string]: Json }
  local items = hygiene.physicalInfos(source.records)
  local groups: { [string]: { number } } = {}
  local groupOrder = {}

  for position, item in items do
    local key = `{item.topic}\0{item.id}`

    if not groups[key] then
      groups[key] = {}
      table.insert(groupOrder, key)
    end

    table.insert(groups[key], position - 1)
  end

  local duplicates: { [string]: Json } = {}

  for key, positions in groups do
    if #positions > 1 then
      duplicates[key] = report.object {
        'count',
        #positions,
        'physical_occurrence_numbers',
        report.array(positions :: { Json }),
      }
    end
  end

  local rows: { { [string]: Json } } = {}
  local changedByTopic: { [string]: { [string]: boolean } } = {}

  for _, item in items do
    local key = `{item.topic}\0{item.id}`
    local active, tombstone = parent.active[key], parent.tombstones[key]
    local kind = category(item.record, active, tombstone)

    if kind == 'NEW_INFO' or kind == 'MODIFIED_PARENT' then
      changedByTopic[item.topic] = changedByTopic[item.topic] or {}
      changedByTopic[item.topic][item.id] = true
    end

    local entry = active or tombstone
    table.insert(
      rows,
      report.object {
        'topic',
        item.topic,
        'info_id',
        item.id,
        'record_index',
        item.recordIndex,
        'category',
        kind,
        'parent_source',
        if entry then entry.source else nil,
        'parent_record_index',
        if entry then entry.recordIndex else nil,
        'starwind',
        hygiene.compact(item.record),
        'parent',
        hygiene.compact(if entry then entry.record else nil),
        'changed_links',
        changedLinks(item.record, if active then active.record else nil),
        'duplicate_in_source',
        duplicates[key],
      }
    )
  end

  for _, row in rows do
    if row.category ~= 'PROBABLE_TESCS_LINK_DIRT' then continue end

    local owned = changedByTopic[row.topic :: string] or {}
    local touched = {}

    for _, side in row.changed_links :: { [string]: Json } do
      local child = (side :: { [string]: Json }).child :: string

      if child ~= '' and owned[child] then table.insert(touched, child) end
    end

    table.sort(touched)
    report.set(row, 'tescs_dirt_confidence', if #touched > 0 then 'HIGH' else 'MEDIUM')
    report.set(row, 'changed_link_targets_owned_by_source', report.array(touched))
  end

  local counts, confidence = counter(), counter()
  local topics: { [string]: Counter } = {}

  for _, row in rows do
    bump(counts, row.category :: string)

    if row.category == 'PROBABLE_TESCS_LINK_DIRT' then
      bump(confidence, row.tescs_dirt_confidence :: string)
    end

    local topic = row.topic :: string
    topics[topic] = topics[topic] or counter()
    bump(topics[topic], row.category :: string)
  end

  local cleanup = {}

  for topic, tally in topics do
    local exact = tally.counts.REDUNDANT_EXACT_COPY or 0
    local dirt = tally.counts.PROBABLE_TESCS_LINK_DIRT or 0

    if exact + dirt > 0 then
      table.insert(cleanup, { topic = topic, total = exact + dirt, exact = exact, dirt = dirt })
    end
  end

  table.sort(cleanup, function(left, right)
    if left.total ~= right.total then return left.total > right.total end

    return left.topic < right.topic
  end)

  local topCleanup = report.array()

  for index = 1, math.min(100, #cleanup) do
    local entry = cleanup[index]
    table.insert(
      topCleanup,
      report.object {
        'topic',
        entry.topic,
        'cleanup_candidates',
        entry.total,
        'redundant_exact',
        entry.exact,
        'link_dirt',
        entry.dirt,
      }
    )
  end

  local duplicateKeys = {}

  for key in duplicates do
    table.insert(duplicateKeys, key)
  end

  table.sort(duplicateKeys)
  local duplicateList = report.array()

  for _, key in duplicateKeys do
    local topic, id = string.match(key, '^(.-)%z(.*)$')
    local meta = duplicates[key] :: { [string]: Json }
    table.insert(
      duplicateList,
      report.object {
        'topic',
        topic,
        'info_id',
        id,
        'count',
        meta.count,
        'physical_occurrence_numbers',
        meta.physical_occurrence_numbers,
      }
    )
  end

  local topicNames = {}

  for topic in topics do
    table.insert(topicNames, topic)
  end

  table.sort(topicNames)
  local topicPairs = {}

  for _, topic in topicNames do
    table.insert(topicPairs, topic)
    table.insert(topicPairs, ordered(topics[topic].counts, topics[topic].order))
  end

  local rowList = report.array()

  for _, row in rows do
    table.insert(rowList, row)
  end

  return report.object {
    'source_json',
    source.path,
    'binary_name',
    source.binary :: Json,
    'source_label',
    source.label,
    'parent_model',
    parentModel or (if source.label == 'V1.15'
      then 'Morrowind -> Tribunal -> Bloodmoon'
      else 'Morrowind -> Tribunal -> Bloodmoon -> V1.15'),
    'counts',
    ordered(counts.counts, counts.order),
    'tescs_dirt_confidence',
    ordered(confidence.counts, confidence.order),
    'duplicate_info_groups',
    #duplicateList,
    'duplicates',
    duplicateList,
    'topic_counts',
    report.object(topicPairs),
    'top_cleanup_topics',
    topCleanup,
    'records',
    rowList,
  }
end

-- The report `dialogue_source_hygiene.py --report` writes: each Definitive source against the
-- vanilla baseline, then V1.15 and the Patch layered over it. Writes it and returns it.
function hygiene.audit(
  vanilla: { Source },
  corpus: { Source },
  layered: { Source },
  path: string
): { [string]: Json }
  local reports = report.array()
  -- Classifying reads the state and never changes it, so one baseline serves every source.
  local baseline = hygiene.vanillaState(vanilla)

  for _, source in corpus do
    table.insert(
      reports,
      hygiene.classify(source, baseline, 'Morrowind -> Tribunal -> Bloodmoon (vanilla baseline)')
    )
  end

  local state = hygiene.vanillaState(vanilla)
  local layeredReports = report.array()

  for _, source in layered do
    table.insert(layeredReports, hygiene.classify(source, state))
    hygiene.apply(state, source.records, source.label)
  end

  local paths = report.array()

  for _, source in vanilla do
    table.insert(paths, source.path)
  end

  local result = report.object {
    'version',
    3,
    'vanilla_load_order',
    paths,
    'topic_filter',
    nil,
    'sources',
    reports,
    'layered_v115_patch_sources',
    layeredReports,
  }

  report.write(path, result, false)
  return result
end

return hygiene
