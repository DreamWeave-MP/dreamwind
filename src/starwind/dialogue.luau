--!strict
--!native
-- dialogue_chain_audit.py (v12): an independent replay of OpenMW's dialogue loading over the
-- staged masters and the pre-decoupling plugin, the liveness slice the decoupler should have
-- kept, and a comparison against the masterless plugin as written.
--
-- OpenMW's rules (`ESM::InfoOrder::insertInfo`, `ESMStore::load`, `Dialogue::setUp`):
--   * a DIAL merges by id, a later one replacing the data; a deleted DIAL erases the topic;
--   * an INFO belongs to the DIAL before it; an INFO with the id and previous INFO of one
--     already there replaces it in place, any other goes after its previous INFO (the front for
--     none, the end for one not found), an existing one moving there;
--   * deleted INFOs stay while loading, so later INFOs can follow them, and go at the end.
-- The masterless plugin is read back from disk, so its numbers are f32s; the staged plugins'
-- come from tes3conv's JSON. Numbers compare at f32 precision.

local report = require './report'
local tes3 = require '../lib/tes3'

type Record = tes3.Record
type Records = tes3.Records
type Table = tes3.Table
type Value = tes3.Value
type Json = report.Json

local dialogue = {}

export type Source = { name: string, records: Records }

type Entry = { record: Record, deleted: boolean, source: string, sourceIndex: number }
type Node = { id: string, prev: Node?, next: Node? }

type State = {
  record: Record,
  source: string,
  head: Node?,
  tail: Node?,
  nodes: { [string]: Node },
  infos: { [string]: Entry },
}

type Replay = { dialogues: { [string]: State }, orphans: { Json }, duplicates: { Json } }

local function norm(value: Value?): string return string.lower(tes3.string(value)) end

local function unlink(state: State, node: Node)
  if node.prev then
    (node.prev :: Node).next = node.next
  else
    state.head = node.next
  end

  if node.next then
    (node.next :: Node).prev = node.prev
  else
    state.tail = node.prev
  end

  node.prev, node.next = nil, nil
end

local function linkBefore(state: State, node: Node, before: Node?)
  if not before then
    node.prev = state.tail

    if state.tail then
      (state.tail :: Node).next = node
    else
      state.head = node
    end

    state.tail = node
    return
  end

  local after = before :: Node
  node.next = after
  node.prev = after.prev

  if after.prev then
    (after.prev :: Node).next = node
  else
    state.head = node
  end

  after.prev = node
end

-- `DialogueState.insert_info`.
local function insertInfo(state: State, record: Record, source: string, sourceIndex: number)
  local id = norm(record.id)
  local prev = norm(record.prevId)

  if id == '' then id = `__empty_info_id__:{source}:{sourceIndex}` end

  local entry: Entry = {
    record = record,
    deleted = tes3.isDeleted(record),
    source = source,
    sourceIndex = sourceIndex,
  }
  local existing = state.infos[id]

  if existing and norm(existing.record.prevId) == prev then
    state.infos[id] = entry
    return
  end

  local before: Node?

  if prev == '' then
    before = state.head
  else
    local previous = state.nodes[prev]
    before = if previous then previous.next else nil
  end

  state.infos[id] = entry
  local node = state.nodes[id]

  if node then
    if before ~= node then
      unlink(state, node)
      linkBefore(state, node, before)
    end

    return
  end

  node = { id = id, prev = nil, next = nil }
  state.nodes[id] = node
  linkBefore(state, node, before)
end

local function finalizedOrder(state: State): { string }
  local order = {}
  local node = state.head

  while node do
    local entry = state.infos[node.id]

    if entry and not entry.deleted then table.insert(order, node.id) end

    node = node.next
  end

  return order
end

dialogue.finalizedOrder = finalizedOrder

-- `replay_openmw`.
function dialogue.replay(stack: { Source }): Replay
  local dialogues: { [string]: State } = {}
  local orphans, duplicates = report.array(), report.array()

  for _, source in stack do
    local current: State? = nil
    local seen: { [string]: boolean } = {}

    for position, record in source.records do
      local index = position - 1
      local kind = record.type

      if kind == 'Dialogue' then
        local id = norm(record.id)

        if seen[id] then
          table.insert(
            duplicates,
            report.object { 'source', source.name, 'record_index', index, 'dialogue_id', id }
          )
        end

        seen[id] = true

        -- ESMStore::load erases a deleted DIAL and leaves the current topic as it was.
        if tes3.isDeleted(record) then
          dialogues[id] = nil
          continue
        end

        local state = dialogues[id]

        if state then
          state.record = record
          state.source = source.name
        else
          state = {
            record = record,
            source = source.name,
            head = nil,
            tail = nil,
            nodes = {},
            infos = {},
          }
          dialogues[id] = state
        end

        current = state
      elseif kind == 'DialogueInfo' then
        if current then
          insertInfo(current :: State, record, source.name, index)
        else
          table.insert(
            orphans,
            report.object {
              'source',
              source.name,
              'record_index',
              index,
              'info_id',
              tes3.string(record.id),
            }
          )
        end
      else
        current = nil
      end
    end
  end

  return { dialogues = dialogues, orphans = orphans, duplicates = duplicates }
end

type RawChain = { record: Record, physical: { string }, infos: { [string]: Record } }

-- `extract_raw_standalone_chains`: each topic's INFOs as they sit in the file.
function dialogue.rawChains(records: Records): ({ [string]: RawChain }, { Json })
  local chains: { [string]: RawChain } = {}
  local orphans = report.array()
  local current: RawChain? = nil

  for position, record in records do
    if record.type == 'Dialogue' then
      current = { record = record, physical = {}, infos = {} }
      chains[norm(record.id)] = current :: RawChain
    elseif record.type == 'DialogueInfo' then
      if current then
        local id = norm(record.id)
        table.insert((current :: RawChain).physical, id);
        (current :: RawChain).infos[id] = record
      else
        table.insert(
          orphans,
          report.object { 'record_index', position - 1, 'info_id', tes3.string(record.id) }
        )
      end
    else
      current = nil
    end
  end

  return chains, orphans
end

-- `collect_physical_dialogue_ids`: each topic's INFO ids, deleted ones too.
function dialogue.physicalIds(records: Records): { [string]: { [string]: boolean } }
  local ids: { [string]: { [string]: boolean } } = {}
  local current: string? = nil

  for _, record in records do
    if record.type == 'Dialogue' then
      current = norm(record.id)
      ids[current :: string] = ids[current :: string] or {}
    elseif record.type == 'DialogueInfo' and current then
      ids[current :: string][norm(record.id)] = true
    else
      current = nil
    end
  end

  return ids
end

export type Actor = { id: string, race: string, class: string, sex: string }

function dialogue.actorPopulation(records: Records): { Actor }
  local actors = {}

  for _, record in records do
    if record.type == 'Npc' then
      local sex = if tes3.hasFlag(string.upper(tes3.string(record.npcFlags)), 'FEMALE')
        then 'female'
        else 'male'
      table.insert(
        actors,
        { id = norm(record.id), race = norm(record.race), class = norm(record.class), sex = sex }
      )
    elseif record.type == 'Creature' then
      table.insert(actors, { id = norm(record.id), race = '', class = '', sex = '' })
    end
  end

  return actors
end

-- `parse_liveness_actor_population`: the actors addVanillaRefs logged before it pruned dialogue,
-- or nil when its log has no complete snapshot.
function dialogue.livenessActors(log: { string }): { Actor }?
  local actors: { Actor } = {}
  local inside, complete = false, false

  for _, line in log do
    if line == 'Dialogue liveness population begin' then
      actors, inside, complete = {}, true, false
    elseif line == 'Dialogue liveness population end' then
      complete = inside
      inside = false
    elseif inside and string.sub(line, 1, 24) == 'Dialogue liveness actor\t' then
      local fields = string.split(line, '\t')

      if #fields == 6 then
        table.insert(actors, {
          id = string.lower(fields[3]),
          race = string.lower(fields[4]),
          class = string.lower(fields[5]),
          sex = string.lower(fields[6]),
        })
      end
    end
  end

  return if complete then actors else nil
end

-- `parse_materialization_log`.
function dialogue.materialized(log: { string }): { [string]: Json }
  local result: { [string]: Json } = {}

  for _, line in log do
    local topic, source, count, reasons = string.match(
      line,
      '^Dialogue DIAL materialized: topic="(.*)" source=(%S+) live_infos=(%d+) topic_reason=(%[.*%])$'
    )

    if not topic then continue end

    local names = report.array()

    for name in string.gmatch(reasons :: string, '"([^"]*)"') do
      table.insert(names, name)
    end

    result[string.lower(topic :: string)] = report.object {
      'topic',
      topic,
      'source',
      source,
      'live_infos',
      tonumber(count),
      'topic_reason',
      names,
    }
  end

  return result
end

local EngineTypes = { greeting = true, voice = true, persuasion = true }

local function dialogueType(record: Record): string
  local text = string.gsub(norm(record.dialogueType), '_', ' ')
  return string.match(text, '^%s*(.-)%s*$') :: string
end

local function scriptTopics(
  text: string,
  lookup: { [string]: string },
  live: { [string]: { [string]: boolean } }
)
  for line in string.gmatch(text .. '\n', '([^\n]*)\n') do
    line = string.gsub(line, '\r$', '')
    local stripped = string.match(line, '^%s*(.*)$') :: string

    if string.sub(stripped, 1, 1) == ';' or #stripped < 8 then continue end

    if
      string.lower(string.sub(stripped, 1, 8)) ~= 'addtopic'
      or not string.find(string.sub(stripped, 9, 9), '^%s')
    then
      continue
    end

    local operand = string.match(string.sub(stripped, 9), '^%s*(.*)$') :: string

    if string.sub(operand, 1, 1) == '"' then
      operand = string.match(operand, '^"([^"]*)') :: string
    else
      operand = string.match(operand, '^(%S*)') :: string
    end

    local topic = lookup[string.lower(operand)]

    if topic then
      live[topic] = live[topic] or {}
      live[topic].SCRIPT_TOPIC = true
    end
  end
end

type ActorIndex = {
  byId: { [string]: { Actor } },
  races: { [string]: boolean },
  classes: { [string]: boolean },
  pairs: { [string]: boolean },
}

local function actorIndex(actors: { Actor }): ActorIndex
  local index: ActorIndex = { byId = {}, races = {}, classes = {}, pairs = {} }

  for _, actor in actors do
    local same = index.byId[actor.id] or {}
    index.byId[actor.id] = same
    table.insert(same, actor)
    index.races[actor.race] = true
    index.classes[actor.class] = true
    index.pairs[`{actor.race}\0{actor.class}`] = true
  end

  return index
end

local function canMatchActor(record: Record, index: ActorIndex): boolean
  local speaker, race, class =
    norm(record.speakerId), norm(record.speakerRace), norm(record.speakerClass)

  if speaker ~= '' then
    for _, actor in index.byId[speaker] or {} do
      if (race == '' or actor.race == race) and (class == '' or actor.class == class) then
        return true
      end
    end

    return false
  elseif race ~= '' and class ~= '' then
    return index.pairs[`{race}\0{class}`] == true
  elseif race ~= '' then
    return index.races[race] == true
  elseif class ~= '' then
    return index.classes[class] == true
  end

  return true
end

export type Projected = {
  record: Record,
  order: { string },
  infos: { [string]: Entry },
  links: { [string]: { string } },
  reasons: { string },
}

-- `build_liveness_projection`.
function dialogue.project(
  effective: Replay,
  starwind: { [string]: { [string]: boolean } },
  scripts: { string },
  actors: { Actor }
): ({ [string]: Projected }, { [string]: Json })
  local live: { [string]: { [string]: boolean } } = {}

  for topic in starwind do
    live[topic] = live[topic] or {}
    live[topic].STARWIND_TOPIC = true
  end

  for topic, state in effective.dialogues do
    if EngineTypes[dialogueType(state.record)] then
      live[topic] = live[topic] or {}
      live[topic].ENGINE_TOPIC = true
    end
  end

  local lookup: { [string]: string } = {}

  for topic in effective.dialogues do
    if topic ~= '' then lookup[string.lower(topic)] = topic end
  end

  for _, text in scripts do
    scriptTopics(text, lookup, live)
  end

  local liveCount, effectiveInfos = 0, 0

  for _ in live do
    liveCount += 1
  end

  local finalized: { [string]: { string } } = {}

  for topic, state in effective.dialogues do
    finalized[topic] = finalizedOrder(state)
    effectiveInfos += #finalized[topic]
  end

  local counts = { live = 0, owned = 0, retained = 0, pruned = 0 }
  local reasons: { [string]: number } = {}
  local index = actorIndex(actors)
  local projection: { [string]: Projected } = {}

  local function reason(name: string) reasons[name] = (reasons[name] or 0) + 1 end

  for topic, state in effective.dialogues do
    if not live[topic] then continue end

    local order, infos = {}, {}
    local owned = starwind[topic] or {}

    for _, id in finalized[topic] do
      local entry = state.infos[id]
      counts.live += 1
      local mine = owned[id] == true

      if mine then
        counts.owned += 1
      end

      if not (mine or canMatchActor(entry.record, index)) then
        if not mine then
          counts.pruned += 1
        end

        continue
      end

      table.insert(order, id)
      infos[id] = entry

      if mine then continue end

      counts.retained += 1
      local record = entry.record
      local speaker, race, class =
        norm(record.speakerId), norm(record.speakerRace), norm(record.speakerClass)
      local faction = norm(record.speakerFaction)

      if
        speaker == ''
        and race == ''
        and class == ''
        and faction == ''
        and EngineTypes[dialogueType(state.record)]
      then
        reason 'VANILLA_ENGINE_TOPIC_GENERIC'
      end

      if speaker ~= '' then reason 'VANILLA_MATCHING_SPEAKER_ID' end

      if race ~= '' then reason 'VANILLA_MATCHING_RACE' end

      if class ~= '' then reason 'VANILLA_MATCHING_CLASS' end

      if faction ~= '' then reason 'VANILLA_FACTION_UNKNOWN' end

      if live[topic].SCRIPT_TOPIC then reason 'VANILLA_SCRIPT_TOPIC' end

      if live[topic].STARWIND_TOPIC then reason 'VANILLA_DIALOGUE_TOPIC' end
    end

    -- Starwind's own topics stay as shells; a vanilla one only with an INFO that survived.
    if #order == 0 and not starwind[topic] then continue end

    local links = {}

    for position, id in order do
      links[id] = { order[position - 1] or '', order[position + 1] or '' }
    end

    local names = {}

    for name in live[topic] do
      table.insert(names, name)
    end

    table.sort(names)
    projection[topic] =
      { record = state.record, order = order, infos = infos, links = links, reasons = names }
  end

  local reasonDict = report.dict()

  for name, count in reasons do
    reasonDict[name] = count
  end

  local audit = report.object {
    'effective_infos',
    effectiveInfos,
    'live_topic_effective_infos',
    counts.live,
    'starwind_owned_infos',
    counts.owned,
    'retained_vanilla_infos',
    counts.retained,
    'pruned_vanilla_infos',
    counts.pruned,
    'keep_reasons',
    reasonDict,
    'live_topics',
    liveCount,
  }

  return projection, audit
end

-- Numbers as tes3 stores them: whole numbers exactly, the rest as f32s.
local function sameNumber(left: number, right: number): boolean
  if left == right then return true end

  if left == math.floor(left) and right == math.floor(right) then return false end

  return string.pack('<f', left) == string.pack('<f', right)
end

local function snakeKey(key: Value): string
  return (
    string.gsub(
      tostring(key),
      '(%u)',
      function(letter: string) return '_' .. string.lower(letter) end
    )
  )
end

-- `diff_paths`: the dotted paths at which two values differ, keys spelled as tes3conv spells them.
local function diffPaths(expected: Value?, actual: Value?, prefix: string, out: { string })
  if type(expected) == 'number' and type(actual) == 'number' then
    if not sameNumber(expected :: number, actual :: number) then
      table.insert(out, if prefix == '' then '<root>' else prefix)
    end

    return
  end

  if type(expected) ~= type(actual) then
    table.insert(out, if prefix == '' then '<root>' else prefix)
    return
  end

  if type(expected) ~= 'table' then
    if expected ~= actual then table.insert(out, if prefix == '' then '<root>' else prefix) end

    return
  end

  local left, right = expected :: Table, actual :: Table

  if #left > 0 or #right > 0 then
    local common = math.min(#left, #right)

    for index = 1, common do
      diffPaths(left[index], right[index], `{prefix}[{index - 1}]`, out)
    end

    if #left ~= #right then
      table.insert(out, if prefix == '' then '<root>.length' else `{prefix}.length`)
    end

    return
  end

  local keys: { string } = {}
  local seen: { [string]: boolean } = {}

  for key in left do
    seen[tostring(key)] = true
  end

  for key in right do
    seen[tostring(key)] = true
  end

  for key in seen do
    table.insert(keys, key)
  end

  table.sort(keys, function(a, b) return snakeKey(a) < snakeKey(b) end)

  for _, key in keys do
    local path = if prefix == '' then snakeKey(key) else `{prefix}.{snakeKey(key)}`

    if left[key] == nil or right[key] == nil then
      table.insert(out, path)
    else
      diffPaths(left[key], right[key], path, out)
    end
  end
end

local function without(record: Record, fields: { string }): Record
  local copy = table.clone(record)

  for _, field in fields do
    copy[field] = nil
  end

  return copy
end

local function differences(expected: Record, actual: Record): { string }
  local out = {}
  diffPaths(expected, actual, '', out)
  return out
end

-- `filter_value`, `comparable_number`, `numeric_constraints_disjoint`: whether two conditions on
-- the same scalar can't both hold. Only the comparisons that can be proven algebraically count.
local function filterValue(filter: Table): Value?
  local value = filter.value

  if type(value) == 'table' then return (value :: Table).data end

  return value
end

local function comparable(value: Value?): number?
  if type(value) == 'boolean' then
    return if value then 1 else 0
  elseif type(value) == 'number' then
    return value
  end

  return tonumber(tostring(value))
end

local Known = {
  equal = true,
  notequal = true,
  less = true,
  lessequal = true,
  greater = true,
  greaterequal = true,
}

local function allows(comparison: string, target: number, value: number): boolean
  if comparison == 'equal' then
    return target == value
  elseif comparison == 'notequal' then
    return target ~= value
  elseif comparison == 'less' then
    return target < value
  elseif comparison == 'lessequal' then
    return target <= value
  elseif comparison == 'greater' then
    return target > value
  elseif comparison == 'greaterequal' then
    return target >= value
  end

  return true
end

local function disjoint(a: Table, b: Table): boolean
  local av, bv = comparable(filterValue(a)), comparable(filterValue(b))

  if av == nil or bv == nil then return false end

  local ac, bc = norm(a.comparison), norm(b.comparison)

  if not Known[ac] or not Known[bc] then return false end

  if ac == 'equal' then
    return not allows(bc, av :: number, bv :: number)
  elseif bc == 'equal' then
    return not allows(ac, bv :: number, av :: number)
  elseif ac == 'notequal' or bc == 'notequal' then
    return false
  end

  local function bounds(comparison: string, value: number): (number?, boolean, number?, boolean)
    if comparison == 'greater' then
      return value, false, nil, false
    elseif comparison == 'greaterequal' then
      return value, true, nil, false
    elseif comparison == 'less' then
      return nil, false, value, false
    end

    return nil, false, value, true
  end

  local alo, aloinc, ahi, ahiinc = bounds(ac, av :: number)
  local blo, bloinc, bhi, bhiinc = bounds(bc, bv :: number)
  local lo, loinc = alo, aloinc

  if blo ~= nil and (lo == nil or blo > lo or (blo == lo and not bloinc)) then
    lo, loinc = blo, bloinc
  elseif blo ~= nil and blo == lo then
    loinc = loinc and bloinc
  end

  local hi, hiinc = ahi, ahiinc

  if bhi ~= nil and (hi == nil or bhi < hi or (bhi == hi and not bhiinc)) then
    hi, hiinc = bhi, bhiinc
  elseif bhi ~= nil and bhi == hi then
    hiinc = hiinc and bhiinc
  end

  if lo == nil or hi == nil then return false end

  return (lo :: number) > (hi :: number) or (lo == hi and not (loinc and hiinc))
end

local function speakerSex(record: Record): string
  local sex = norm(((record.data or {}) :: Table).speakerSex)
  return if sex == 'male' or sex == 'female' then sex else ''
end

local function actorFits(actor: Actor, record: Record): boolean
  local speaker, race, class =
    norm(record.speakerId), norm(record.speakerRace), norm(record.speakerClass)
  local sex = speakerSex(record)

  if speaker ~= '' and actor.id ~= speaker then
    return false
  elseif race ~= '' and actor.race ~= race then
    return false
  elseif class ~= '' and actor.class ~= class then
    return false
  elseif sex ~= '' and actor.sex ~= '' and actor.sex ~= sex then
    return false
  end

  return true
end

local function sharedActors(a: Record, b: Record, actors: { Actor }): (number, { Json })
  local count, sample = 0, report.array()

  for _, actor in actors do
    if actorFits(actor, a) and actorFits(actor, b) then
      count += 1

      if #sample < 12 then table.insert(sample, actor.id) end
    end
  end

  return count, sample
end

-- `mutually_exclusive_info`: whether two INFOs provably can't answer the same event.
local function mutuallyExclusive(a: Record, b: Record, actors: { Actor }): (boolean, { Json })
  local reasons = report.array()

  local comparedFields = {
    { 'speakerId', 'speaker_id' },
    { 'speakerRace', 'speaker_race' },
    { 'speakerClass', 'speaker_class' },
    { 'speakerCell', 'speaker_cell' },
  }

  for _, pair in comparedFields do
    local av, bv = norm(a[pair[1]]), norm(b[pair[1]])

    if av ~= '' and bv ~= '' and av ~= bv then
      table.insert(reasons, `different_{pair[2]}`)
      return true, reasons
    end
  end

  local adata, bdata = (a.data or {}) :: Table, (b.data or {}) :: Table
  local asex, bsex = norm(adata.speakerSex), norm(bdata.speakerSex)

  if asex ~= '' and bsex ~= '' and asex ~= 'any' and bsex ~= 'any' and asex ~= bsex then
    table.insert(reasons, 'different_speaker_sex')
    return true, reasons
  end

  local afac, bfac = norm(a.speakerFaction), norm(b.speakerFaction)
  local arank, brank = adata.speakerRank, bdata.speakerRank

  if
    afac ~= ''
    and afac == bfac
    and arank ~= nil
    and arank ~= -1
    and brank ~= nil
    and brank ~= -1
    and arank ~= brank
  then
    table.insert(reasons, 'different_exact_speaker_rank')
    return true, reasons
  end

  local bySubject: { [string]: { Table } } = {}

  local function subject(filter: Table): string
    return `{norm(filter.filterType)}\0{norm(filter['function'])}\0{norm(filter.id)}`
  end

  for _, value in (b.filters or {}) :: { Value } do
    if type(value) == 'table' then
      local key = subject(value :: Table)
      bySubject[key] = bySubject[key] or {}
      table.insert(bySubject[key], value :: Table)
    end
  end

  for _, value in (a.filters or {}) :: { Value } do
    if type(value) ~= 'table' then continue end

    local filter = value :: Table
    local key = subject(filter)

    for _, other in bySubject[key] or {} do
      if disjoint(filter, other) then
        local parts = {}

        for part in string.gmatch(key .. '\0', '([^%z]*)%z') do
          if part ~= '' then table.insert(parts, part) end
        end

        table.insert(reasons, `contradictory_filter:{table.concat(parts, ':')}`)
        return true, reasons
      end
    end
  end

  local count = sharedActors(a, b, actors)

  if count == 0 then
    table.insert(reasons, 'no_shared_actor_candidate')
    return true, reasons
  end

  return false, reasons
end

local function constraints(record: Record): Json
  return report.object {
    'speaker_id',
    tes3.string(record.speakerId),
    'speaker_race',
    tes3.string(record.speakerRace),
    'speaker_class',
    tes3.string(record.speakerClass),
    'speaker_faction',
    tes3.string(record.speakerFaction),
    'speaker_cell',
    tes3.string(record.speakerCell),
    'data',
    report.snake((record.data or report.dict()) :: Json),
    'filters',
    report.snake((record.filters or report.array()) :: Json),
  }
end

-- `order_blocks`: the common ids in actual order, cut into runs contiguous in expected order.
local function orderBlocks(expected: { string }, actual: { string }): { Json }
  local position: { [string]: number } = {}

  for index, id in expected do
    position[id] = index - 1
  end

  local common = {}

  for _, id in actual do
    if position[id] ~= nil then table.insert(common, id) end
  end

  local blocks = report.array()

  if #common == 0 then return blocks end

  local function emit(first: number, last: number)
    local ids = {}

    for index = first, last do
      table.insert(ids, common[index])
    end

    if #ids == 0 then return end

    local shown = {}

    for index = 1, math.min(40, #ids) do
      shown[index] = ids[index]
    end

    table.insert(
      blocks,
      report.object {
        'actual_start',
        first - 1,
        'actual_end',
        last - 1,
        'expected_start',
        position[ids[1]],
        'expected_end',
        position[ids[#ids]],
        'length',
        #ids,
        'first_id',
        ids[1],
        'last_id',
        ids[#ids],
        'ids',
        report.array(shown),
        'truncated',
        #ids > 40,
      }
    )
  end

  local start = 1
  local previous = position[common[1]]

  for index = 2, #common do
    local current = position[common[index]]

    if current ~= previous + 1 then
      emit(start, index - 1)
      start = index
    end

    previous = current
  end

  emit(start, #common)
  return blocks
end

local function inversions(expected: { string }, actual: { string }): { { string } }
  local position: { [string]: number } = {}

  for index, id in actual do
    position[id] = index
  end

  local common = {}

  for _, id in expected do
    if position[id] then table.insert(common, id) end
  end

  local out = {}

  for index, left in common do
    for following = index + 1, #common do
      if position[left] > position[common[following]] then
        table.insert(out, { left, common[following] })
      end
    end
  end

  return out
end

-- `analyze_order_semantics`.
local function orderSemantics(
  topic: string,
  expected: { string },
  actual: { string },
  expectedInfos: { [string]: Entry },
  actors: { Actor }
): { [string]: Json }
  local pairs = inversions(expected, actual)
  local proven, unproven = report.array(), report.array()

  for _, pair in pairs do
    local a, b = expectedInfos[pair[1]], expectedInfos[pair[2]]

    if not a or not b then
      table.insert(
        unproven,
        report.object { 'first', pair[1], 'second', pair[2], 'reason', 'missing_expected_payload' }
      )
      continue
    end

    local exclusive, reasons = mutuallyExclusive(a.record, b.record, actors)
    local item = report.object {
      'first',
      pair[1],
      'second',
      pair[2],
      'proof',
      reasons,
      'first_source',
      a.source,
      'second_source',
      b.source,
    }

    if exclusive then
      table.insert(proven, item)
    else
      local count, sample = sharedActors(a.record, b.record, actors)
      report.set(item :: { [string]: Json }, 'shared_actor_candidate_count', count)
      report.set(item :: { [string]: Json }, 'shared_actor_candidate_ids', sample)
      report.set(item :: { [string]: Json }, 'first_constraints', constraints(a.record))
      report.set(item :: { [string]: Json }, 'second_constraints', constraints(b.record))
      table.insert(unproven, item)
    end
  end

  local blocks = orderBlocks(expected, actual)

  local function first(list: { Json }): { Json }
    local out = report.array()

    for index = 1, math.min(50, #list) do
      out[index] = list[index]
    end

    return out
  end

  return report.object {
    'dialogue_id',
    topic,
    'inversions',
    #pairs,
    'proven_mutually_exclusive',
    #proven,
    'potentially_competing',
    #unproven,
    'order_blocks',
    blocks,
    'order_block_count',
    #blocks,
    'proven_samples',
    first(proven),
    'potentially_competing_pairs',
    first(unproven),
  }
end

local function compactInfo(record: Record): Json
  local data = (record.data or {}) :: Table
  local filters = report.array()

  for _, value in (record.filters or {}) :: { Value } do
    if type(value) == 'table' then
      local filter = value :: Table
      table.insert(
        filters,
        report.object {
          'filter_type',
          filter.filterType :: Json,
          'function',
          filter['function'] :: Json,
          'id',
          filter.id :: Json,
          'comparison',
          filter.comparison :: Json,
          'value',
          report.snake(filter.value :: Json),
        }
      )
    end
  end

  return report.object {
    'id',
    record.id :: Json,
    'prev_id',
    record.prevId :: Json,
    'next_id',
    record.nextId :: Json,
    'speaker_id',
    record.speakerId :: Json,
    'speaker_race',
    record.speakerRace :: Json,
    'speaker_class',
    record.speakerClass :: Json,
    'speaker_faction',
    record.speakerFaction :: Json,
    'speaker_cell',
    record.speakerCell :: Json,
    'speaker_sex',
    data.speakerSex :: Json,
    'speaker_rank',
    data.speakerRank :: Json,
    'text',
    record.text :: Json,
    'result',
    nil,
    'filters',
    filters,
  }
end

dialogue.compactInfo = compactInfo

type Occurrence = { source: string, recordIndex: number, deleted: boolean, record: Record }

-- `build_provenance_index`: every physical INFO occurrence by topic and id.
function dialogue.provenanceIndex(stack: { Source }): { [string]: { Occurrence } }
  local index: { [string]: { Occurrence } } = {}

  for _, source in stack do
    local topic: string? = nil

    for position, record in source.records do
      if record.type == 'Dialogue' then
        topic = norm(record.id)
      elseif record.type == 'DialogueInfo' and topic then
        local key = `{topic}\0{norm(record.id)}`
        index[key] = index[key] or {}
        table.insert(index[key], {
          source = source.name,
          recordIndex = position - 1,
          deleted = tes3.isDeleted(record),
          record = record,
        })
      else
        topic = nil
      end
    end
  end

  return index
end

local function provenanceFor(
  topic: string,
  id: string,
  index: { [string]: { Occurrence } },
  entry: Entry?
): Json
  local occurrences = index[`{topic}\0{id}`] or {}
  local compact = report.array()
  local physical: { [string]: boolean } = {}

  for _, occurrence in occurrences do
    physical[occurrence.source] = true
    table.insert(
      compact,
      report.object {
        'source',
        occurrence.source,
        'record_index',
        occurrence.recordIndex,
        'deleted',
        occurrence.deleted,
        'payload',
        compactInfo(occurrence.record),
      }
    )
  end

  local sources = {}

  for name in physical do
    table.insert(sources, name)
  end

  table.sort(sources)

  return report.object {
    'dialogue_id',
    topic,
    'info_id',
    id,
    'effective_winner_source',
    if entry then entry.source else nil,
    'effective_winner_source_index',
    if entry then entry.sourceIndex else nil,
    'physical_sources',
    report.array(sources),
    'occurrence_count',
    #occurrences,
    'occurrences',
    compact,
    'effective_payload',
    if entry then compactInfo(entry.record) else nil,
  }
end

-- `attach_corruption_triage`.
local function triage(
  semantics: { { [string]: Json } },
  projected: { [string]: Projected },
  provenance: () -> { [string]: { Occurrence } }
): ({ Json }, Json)
  local detailed = report.array()
  type Candidate = {
    entry: { [string]: Json },
    count: number,
    roles: { [string]: number },
    competes: { [string]: boolean },
  }
  local candidates: { [string]: Candidate } = {}
  local index: { [string]: { Occurrence } }? = nil

  for _, result in semantics do
    local topic = result.dialogue_id :: string
    local expected = projected[topic]

    if not expected then continue end

    for _, value in result.potentially_competing_pairs :: { Json } do
      local pair = value :: { [string]: Json }
      index = index or provenance()
      local firstId, secondId = pair.first :: string, pair.second :: string
      local firstProvenance = provenanceFor(
        topic,
        firstId,
        index :: { [string]: { Occurrence } },
        expected.infos[firstId]
      )
      local secondProvenance = provenanceFor(
        topic,
        secondId,
        index :: { [string]: { Occurrence } },
        expected.infos[secondId]
      )
      local copy = report.object {}

      for _, key in { 'first', 'second', 'reason', 'proof', 'first_source', 'second_source' } do
        if pair[key] ~= nil then report.set(copy, key, pair[key]) end
      end

      local detailKeys = {
        'shared_actor_candidate_count',
        'shared_actor_candidate_ids',
        'first_constraints',
        'second_constraints',
      }

      for _, key in detailKeys do
        if pair[key] ~= nil then report.set(copy, key, pair[key]) end
      end

      report.set(copy, 'dialogue_id', topic)
      report.set(copy, 'first_provenance', firstProvenance)
      report.set(copy, 'second_provenance', secondProvenance)
      table.insert(detailed, copy)

      local roles = {
        { firstId, firstProvenance, 'first', secondId },
        { secondId, secondProvenance, 'second', firstId },
      }

      for _, role in roles do
        local id, prov, name, other =
          role[1] :: string, role[2] :: { [string]: Json }, role[3] :: string, role[4] :: string
        local key = `{topic}::{id}`
        local candidate = candidates[key]

        if not candidate then
          candidate = {
            entry = report.object {
              'dialogue_id',
              topic,
              'info_id',
              id,
              'effective_winner_source',
              prov.effective_winner_source,
              'physical_sources',
              prov.physical_sources,
              'effective_payload',
              prov.effective_payload,
            },
            count = 0,
            roles = { first = 0, second = 0 },
            competes = {},
          }
          candidates[key] = candidate
        end

        local found = candidate :: Candidate
        found.count += 1
        found.roles[name] += 1
        found.competes[other] = true
      end
    end
  end

  local keys = {}

  for key in candidates do
    table.insert(keys, key)
  end

  table.sort(keys, function(left, right)
    local a, b = candidates[left], candidates[right]

    if a.count ~= b.count then return a.count > b.count end

    local at, bt = a.entry.dialogue_id :: string, b.entry.dialogue_id :: string

    if at ~= bt then return at < bt end

    return (a.entry.info_id :: string) < (b.entry.info_id :: string)
  end)

  local pairs = {}

  for _, key in keys do
    local candidate = candidates[key]
    local competes = {}

    for id in candidate.competes do
      table.insert(competes, id)
    end

    table.sort(competes)
    report.set(candidate.entry, 'pair_count', candidate.count)
    report.set(
      candidate.entry,
      'roles',
      report.object { 'first', candidate.roles.first, 'second', candidate.roles.second }
    )
    report.set(candidate.entry, 'competes_with', report.array(competes))
    table.insert(pairs, key)
    table.insert(pairs, candidate.entry)
  end

  return detailed, report.object(pairs)
end

export type Options = {
  final: Source,
  starwind: Source,
  bases: { Source },
  log: { string },
  logPath: string,
  provenance: () -> { Source },
  provenanceNames: { string },
  reportPath: string,
}

local Notes = {
  'Expected dialogue is a liveness slice, not a Starwind-provenance-only slice.',
  'Starwind response-text words do not create DIAL dependencies.',
  'Same-named typed dependencies such as RACE \'Argonian\' remain independent of DIAL \'argonian\'.',
  'When staged standalone vanilla masters exist, v11 reconstructs against those exact build-local masters so intentional pre-addVanillaRefs pruning is reflected in expected dialogue.',
  'Vanilla INFOs are retained when the current pruning policy says they can still match.',
  'Dialogue INFO text is not used for DIAL topic discovery; vanilla topics do not expand the topic graph.',
  'Actor population is read from the addVanillaRefs pre-dialogue-liveness snapshot; final Standalone is only a fallback for older logs.',
  'speaker_cell and dialogue filters are preserved and compared verbatim.',
  'OpenMW-effective order differences are classified by whether inverted INFO pairs can statically compete.',
  'Mutual-exclusion proofs are deliberately conservative; unproven does not mean definitely harmful.',
  'v9 additionally intersects INFO speaker constraints against the actual Standalone actor population.',
  'Order mismatches include compact contiguous block decomposition to avoid interpreting Cartesian inversion counts as bug counts.',
  'If decoupleLog telemetry is available, extra vanilla DIALs are correlated directly with Rust materialization reasons.',
  'Every unresolved precedence pair is cross-indexed against raw vanilla/V1.15/Patch physical INFO occurrences for source-corruption triage.',
  'Physical INFO order and prev/next links remain audited but are diagnostic unless --strict-structure is used.',
}

local function sorted(set: { [string]: unknown }): { string }
  local list = {}

  for key in set do
    table.insert(list, key)
  end

  table.sort(list)
  return list
end

local function firstDifference(expected: { string }, actual: { string }, actualName: string): Json?
  for index = 1, math.max(#expected, #actual) do
    if expected[index] ~= actual[index] then
      return report.object {
        'index',
        index - 1,
        'expected',
        expected[index] :: Json,
        actualName,
        actual[index] :: Json,
      }
    end
  end

  return nil
end

-- The audit as build_starwind.run_dialogue_validation runs it, with the staged masters given as
-- `--base` and `--no-fail`. Writes the report and returns it, with the liveness projection and
-- its audit.
function dialogue.audit(
  options: Options
): ({ [string]: Json }, { [string]: Projected }, { [string]: Json })
  local stack = table.clone(options.bases)
  table.insert(stack, options.starwind)
  local effective = dialogue.replay(stack)
  local starwindIds = dialogue.physicalIds(options.starwind.records)
  local scripts = {}

  for _, record in options.starwind.records do
    if record.type == 'Script' then table.insert(scripts, tes3.string(record.text)) end
  end

  local finalActors = dialogue.actorPopulation(options.final.records)
  local livenessActors = dialogue.livenessActors(options.log)
  local actors = livenessActors or finalActors
  local projected, liveness = dialogue.project(effective, starwindIds, scripts, actors)
  local standalone = dialogue.replay { options.final }
  local raw, rawOrphans = dialogue.rawChains(options.final.records)

  if #rawOrphans > 0 and #standalone.orphans == 0 then
    table.move(rawOrphans, 1, #rawOrphans, 1, standalone.orphans)
  end

  local materialized = dialogue.materialized(options.log)

  -- compare_liveness_projection
  local missingTopics, extraTopics = {}, {}

  for topic in projected do
    if not standalone.dialogues[topic] then table.insert(missingTopics, topic) end
  end

  for topic in standalone.dialogues do
    if not projected[topic] then table.insert(extraTopics, topic) end
  end

  table.sort(missingTopics)
  table.sort(extraTopics)

  local missingInfos, extraInfos, engineOrder, semantics =
    report.array(), report.array(), report.array(), {}
  local physicalOrder, links, dialogueContent, infoContent =
    report.array(), report.array(), report.array(), report.array()

  for _, topic in sorted(projected) do
    local got = standalone.dialogues[topic]

    if not got then continue end

    local expected = projected[topic]
    local gotOrder = finalizedOrder(got)
    local expectedSet, gotSet = {}, {}

    for _, id in expected.order do
      expectedSet[id] = true
    end

    for _, id in gotOrder do
      gotSet[id] = true
    end

    for _, id in sorted(expectedSet) do
      if not gotSet[id] then
        table.insert(missingInfos, report.object { 'dialogue_id', topic, 'info_id', id })
      end
    end

    for _, id in sorted(gotSet) do
      if not expectedSet[id] then
        table.insert(extraInfos, report.object { 'dialogue_id', topic, 'info_id', id })
      end
    end

    if table.concat(expected.order, '\0') ~= table.concat(gotOrder, '\0') then
      table.insert(
        engineOrder,
        report.object {
          'dialogue_id',
          topic,
          'expected_count',
          #expected.order,
          'standalone_count',
          #gotOrder,
          'first_difference',
          firstDifference(expected.order, gotOrder, 'standalone'),
        }
      )
      table.insert(
        semantics,
        orderSemantics(topic, expected.order, gotOrder, expected.infos, actors)
      )
    end

    if
      #differences(without(expected.record, { 'flags' }), without(got.record, { 'flags' })) > 0
    then
      table.insert(dialogueContent, report.object { 'dialogue_id', topic })
    end

    for _, id in sorted(expectedSet) do
      if not gotSet[id] then continue end

      local paths = differences(
        without(expected.infos[id].record, { 'prevId', 'nextId' }),
        without(got.infos[id].record, { 'prevId', 'nextId' })
      )

      if #paths > 0 then
        table.insert(
          infoContent,
          report.object {
            'dialogue_id',
            topic,
            'info_id',
            id,
            'differing_fields',
            report.array(paths),
          }
        )
      end
    end

    local chain = raw[topic]

    if not chain then continue end

    if table.concat(chain.physical, '\0') ~= table.concat(expected.order, '\0') then
      table.insert(
        physicalOrder,
        report.object {
          'dialogue_id',
          topic,
          'expected_count',
          #expected.order,
          'standalone_physical_count',
          #chain.physical,
          'first_difference',
          firstDifference(expected.order, chain.physical, 'standalone_physical'),
        }
      )
    end

    for _, id in expected.order do
      local record = chain.infos[id]

      if not record then
        table.insert(
          links,
          report.object { 'dialogue_id', topic, 'info_id', id, 'problem', 'missing physical INFO' }
        )
        continue
      end

      local want = expected.links[id]

      if norm(record.prevId) ~= want[1] or norm(record.nextId) ~= want[2] then
        table.insert(
          links,
          report.object {
            'dialogue_id',
            topic,
            'info_id',
            id,
            'expected_prev',
            want[1],
            'actual_prev',
            norm(record.prevId),
            'expected_next',
            want[2],
            'actual_next',
            norm(record.nextId),
          }
        )
      end
    end
  end

  local extraDetails = report.array()
  local extraInfoCount = 0

  for _, topic in extraTopics do
    local got = standalone.dialogues[topic]
    local order = finalizedOrder(got)
    extraInfoCount += #order
    local rust = materialized[topic]
    local shown = {}

    for index = 1, math.min(100, #order) do
      shown[index] = order[index]
    end

    table.insert(
      extraDetails,
      report.object {
        'dialogue_id',
        topic,
        'dialogue_type',
        tes3.string(got.record.dialogueType),
        'effective_info_count',
        #order,
        'effective_info_ids',
        report.array(shown),
        'rust_materialization',
        rust,
        'rust_live_info_count_matches',
        rust ~= nil and (rust :: { [string]: Json }).live_infos == #order,
      }
    )
  end

  local notExpected = {}

  for topic in materialized do
    if not projected[topic] then table.insert(notExpected, topic) end
  end

  table.sort(notExpected)
  local withRust, withoutRust = 0, 0

  for _, topic in extraTopics do
    if materialized[topic] then
      withRust += 1
    else
      withoutRust += 1
    end
  end

  local total, proven, risky, safe, riskyTopics = 0, 0, 0, 0, 0

  for _, result in semantics do
    total += result.inversions :: number
    proven += result.proven_mutually_exclusive :: number
    risky += result.potentially_competing :: number

    if (result.inversions :: number) > 0 and result.potentially_competing == 0 then
      safe += 1
    end

    if (result.potentially_competing :: number) > 0 then
      riskyTopics += 1
    end
  end

  local materializedCount = 0

  for _ in materialized do
    materializedCount += 1
  end

  local summary = report.object {
    'expected_live_dialogues',
    #sorted(projected),
    'standalone_dialogues',
    #sorted(standalone.dialogues),
    'missing_dialogues',
    #missingTopics,
    'extra_dialogues',
    #extraTopics,
    'missing_live_infos',
    #missingInfos,
    'extra_dead_infos',
    #extraInfos,
    'engine_order_mismatches',
    #engineOrder,
    'precedence_inversions',
    total,
    'proven_disjoint_inversions',
    proven,
    'potentially_competing_inversions',
    risky,
    'semantically_safe_order_mismatches',
    safe,
    'behaviorally_risky_order_mismatches',
    riskyTopics,
    'extra_topic_infos',
    extraInfoCount,
    'rust_materialized_topics',
    materializedCount,
    'rust_materialized_not_expected',
    #notExpected,
    'extra_dialogues_with_rust_materialization',
    withRust,
    'extra_dialogues_without_rust_materialization',
    withoutRust,
    'standalone_physical_order_mismatches',
    #physicalOrder,
    'serialized_link_mismatches',
    #links,
    'dialogue_content_mismatches',
    #dialogueContent,
    'info_content_mismatches',
    #infoContent,
    'standalone_orphan_infos',
    #standalone.orphans,
  }

  local notExpectedList = report.array()

  for _, topic in notExpected do
    table.insert(notExpectedList, materialized[topic])
  end

  local semanticsList = report.array(semantics :: { Json })
  local pairs, candidates = triage(
    semantics,
    projected,
    function() return dialogue.provenanceIndex(options.provenance()) end
  )

  local stackNames = {}

  for _, source in stack do
    table.insert(stackNames, source.name)
  end

  local result = report.object {
    'summary',
    summary,
    'missing_dialogues',
    report.array(missingTopics),
    'extra_dialogues',
    report.array(extraTopics),
    'extra_dialogue_details',
    extraDetails,
    'rust_materialized_not_expected',
    notExpectedList,
    'missing_live_infos',
    missingInfos,
    'extra_dead_infos',
    extraInfos,
    'engine_order_mismatches',
    engineOrder,
    'order_semantics',
    semanticsList,
    'standalone_physical_order_mismatches',
    physicalOrder,
    'serialized_link_mismatches',
    links,
    'dialogue_content_mismatches',
    dialogueContent,
    'info_content_mismatches',
    infoContent,
    'standalone_orphan_infos',
    standalone.orphans,
    'potential_corruption_pairs',
    pairs,
    'patch_candidates',
    candidates,
    'liveness_audit',
    liveness,
    'expected_base_mode',
    'explicit-cli',
    'reconstruction_stack',
    report.array(stackNames),
    'starwind_ownership_source',
    options.starwind.name,
    'actor_population_source',
    if livenessActors
      then `{options.logPath} (pre-dialogue-liveness snapshot)`
      else `{options.final.name} (fallback; no Rust snapshot found)`,
    'final_actor_population_count',
    #finalActors,
    'liveness_actor_population_count',
    #actors,
    'materialization_log',
    options.logPath,
    'provenance_sources',
    report.array(options.provenanceNames),
    'notes',
    report.array(Notes),
  }

  local candidateCount = 0

  for _ in candidates :: { [string]: Json } do
    candidateCount += 1
  end

  report.set(summary, 'potential_patch_candidate_infos', candidateCount)
  report.write(options.reportPath, result, false)
  return result, projected, liveness
end

return dialogue
