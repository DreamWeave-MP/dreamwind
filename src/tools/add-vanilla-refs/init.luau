--!strict
--!native
--[[
@dreamwind/tools/add-vanilla-refs: motherJungle's addVanillaRefs, over record lists.

  run(plugin, bases, options?) -> (records, log)

Makes `plugin` (tes3conv-shaped records, header first; see @dreamwind/tools/tes3conv) stand
without its Bethesda masters: it copies in every master record the plugin needs, recursively,
rebuilds its dialogue as OpenMW would see it, keeps the dialogue a plugin actor can still say,
and drops the masters. `bases` are the masters in lookup order (addVanillaRefs uses Bloodmoon,
Tribunal, Morrowind), and `options.names` their file names for the log. The result is the new
record list and addVanillaRefs's stdout, line by line: build_starwind.py keeps that as
decoupleLog.txt, and its validators read it.

The passes, as addVanillaRefs runs them:
  1. copy what the plugin's non-dialogue records need, until nothing new is needed, then the
     masters' game settings, magic effects, races, and classes, and what those need;
  2. point escort and follow packages whose cell isn't defined at "igtestcell";
  3. log the actor population, then rebuild each topic's INFOs in OpenMW's order and keep the
     plugin's own and those some actor of the plugin could say, relinked in that order;
  4. copy what the kept dialogue needs, the same way;
  5. drop deleted records and exact duplicate magic effects, then the masters.

Record ids are looked up without their type, as addVanillaRefs looks them up. Its sets are
hash sets and its cells hash maps, so where it prints a cell's references in map order, this
prints them in the cell's order.
]]

local tes3 = require '../lib/tes3'

type Table = tes3.Table
type Value = tes3.Value
type Record = tes3.Record
type Records = tes3.Records

export type Options = { names: { string }? }

type Cause = { pass: string, sourceType: string, sourceId: string, field: string }
type Pending = { id: string, cause: Cause }
type Log = { string }

local addVanillaRefs = {}

local NeverCopy: { [string]: boolean } = {
  Header = true,
  Skill = true,
  StartScript = true,
  LandscapeTexture = true,
  Landscape = true,
  PathGrid = true,
  Dialogue = true,
  DialogueInfo = true,
  Cell = true,
}

local Engine: { [string]: boolean } = { Greeting = true, Voice = true, Persuasion = true }

local function lower(value: Value?): string return string.lower(tes3.string(value)) end

local function tag(record: Record): string return tes3.Tags[record.type :: string] or '????' end

local function list(value: Value?): { Value } return (value or {}) :: { Value } end

-- `collect_required_ids_from_object`: what a record names, lowercased. Like addVanillaRefs, it
-- prints a few of them as it goes.
local function requiredIds(record: Record, log: Log): { [string]: boolean }
  local ids: { [string]: boolean } = {}
  local kind = record.type

  local function add(value: Value?) ids[lower(value)] = true end

  local function addScript() add(record.script) end

  if kind == 'Race' or kind == 'Birthsign' then
    for _, spell in list(record.spells) do
      add(spell)
    end
  elseif kind == 'SoundGen' then
    add(record.creature)
    add(record.sound)
  elseif kind == 'MagicEffect' then
    local effectFields = {
      'boltSound',
      'castSound',
      'hitSound',
      'areaSound',
      'castVisual',
      'boltVisual',
      'hitVisual',
      'areaVisual',
    }

    for _, field in effectFields do
      add(record[field])
    end
  elseif kind == 'Region' then
    add(record.id)
    add(record.sleepCreature)

    for _, sound in list(record.sounds) do
      add((sound :: Table)[1])
    end
  elseif kind == 'Door' then
    addScript()
    add(record.openSound)
    add(record.closeSound)
  elseif
    kind == 'MiscItem'
    or kind == 'RepairItem'
    or kind == 'Activator'
    or kind == 'Apparatus'
    or kind == 'Lockpick'
    or kind == 'Probe'
    or kind == 'Ingredient'
    or kind == 'Alchemy'
  then
    addScript()
  elseif kind == 'Weapon' or kind == 'Book' then
    addScript()
    add(record.enchanting)
  elseif kind == 'Container' then
    addScript()

    for _, item in list(record.inventory) do
      add((item :: Table)[2])
    end
  elseif kind == 'Creature' or kind == 'Npc' then
    addScript()

    for _, item in list(record.inventory) do
      add((item :: Table)[2])
    end

    for _, spell in list(record.spells) do
      add(spell)
    end

    for _, package in list(record.aiPackages) do
      local ai = package :: Table
      local target = lower(ai.target)

      if ai.type == 'Activate' then
        ids[target] = true

        if kind == 'Npc' then table.insert(log, `{target} added as an activation target`) end
      elseif ai.type == 'Escort' or ai.type == 'Follow' then
        ids[target] = true
      end
    end

    if kind == 'Creature' then
      add(record.sound)
    else
      add(record.race)
      add(record.class)
      add(record.faction)
      add(record.head)
      add(record.hair)
    end
  elseif kind == 'Bodypart' then
    add(record.race)
  elseif kind == 'Light' then
    addScript()
    add(record.sound)
  elseif kind == 'Armor' or kind == 'Clothing' then
    addScript()
    add(record.enchanting)

    for _, part in list(record.bipedObjects) do
      add((part :: Table).maleBodypart)
      add((part :: Table).femaleBodypart)
    end
  elseif kind == 'LeveledItem' then
    for _, item in list(record.items) do
      add((item :: Table)[1])
    end
  elseif kind == 'LeveledCreature' then
    for _, creature in list(record.creatures) do
      add((creature :: Table)[1])
    end
  elseif kind == 'Cell' then
    if record.region ~= nil then add(record.region) end

    local name = tes3.string(record.name)

    for _, value in list(record.references) do
      local reference = value :: Table
      add(reference.id)
      table.insert(
        log,
        `{tes3.string(reference.id)} added to Starwind.esp as a cell reference in {name}`
      )

      for _, field in { 'owner', 'ownerGlobal', 'ownerFaction' } do
        if reference[field] ~= nil then
          add(reference[field])
          table.insert(log, `{lower(reference[field])} added to Starwind.esp as an owner reference`)
        end
      end

      for _, field in { 'key', 'trap', 'soul' } do
        if reference[field] ~= nil then add(reference[field]) end
      end
    end
  elseif kind == 'DialogueInfo' then
    add(record.speakerId)
    table.insert(
      log,
      `{tes3.string(record.id)} imported as a line spoken by {lower(record.speakerId)}`
    )
    add(record.speakerRace)
    add(record.speakerClass)
    add(record.speakerFaction)
    add(record.playerFaction)
  elseif kind == 'Faction' then
    add(record.id)

    for _, reaction in list(record.reactions) do
      add((reaction :: Table).faction)
    end
  elseif kind == 'Sound' then
    add(record.id)
  end

  ids[''] = nil
  return ids
end

local function packageTargets(record: Record, matches: (Value?) -> boolean): boolean
  for _, package in list(record.aiPackages) do
    local ai = package :: Table

    if
      (ai.type == 'Activate' or ai.type == 'Escort' or ai.type == 'Follow') and matches(ai.target)
    then
      return true
    end
  end

  return false
end

local function inventoryHolds(record: Record, matches: (Value?) -> boolean): boolean
  for _, item in list(record.inventory) do
    if matches((item :: Table)[2]) then return true end
  end

  return false
end

local function spellsHold(record: Record, matches: (Value?) -> boolean): boolean
  for _, spell in list(record.spells) do
    if matches(spell) then return true end
  end

  return false
end

-- `dependency_field`: which field of `record` named `target`.
local function dependencyField(record: Record, target: string): string
  local function matches(value: Value?): boolean return lower(value) == target end

  local kind = record.type

  if kind == 'DialogueInfo' then
    if matches(record.speakerId) then
      return 'speaker_id'
    elseif matches(record.speakerRace) then
      return 'speaker_race'
    elseif matches(record.speakerClass) then
      return 'speaker_class'
    elseif matches(record.speakerFaction) then
      return 'speaker_faction'
    end

    return 'player_faction'
  elseif kind == 'Cell' then
    for _, value in list(record.references) do
      local reference = value :: Table

      if matches(reference.id) then return 'reference.id' end

      local referenceFields = {
        { 'owner', 'reference.owner' },
        { 'ownerGlobal', 'reference.owner_global' },
        { 'ownerFaction', 'reference.owner_faction' },
        { 'key', 'reference.key' },
        { 'trap', 'reference.trap' },
        { 'soul', 'reference.soul' },
      }

      for _, pair in referenceFields do
        local field = reference[pair[1]]

        if field ~= nil and matches(field) then return pair[2] end
      end
    end

    return 'region'
  elseif kind == 'Npc' or kind == 'Creature' then
    if matches(record.script) then
      return 'script'
    elseif inventoryHolds(record, matches) then
      return 'inventory'
    elseif spellsHold(record, matches) then
      return 'spells'
    elseif packageTargets(record, matches) then
      return 'ai_package.target'
    end

    if kind == 'Creature' then return 'sound' end

    for _, field in { 'race', 'class', 'faction', 'head', 'hair' } do
      if matches(record[field]) then return field end
    end
  end

  return 'dependency'
end

local function sourceId(record: Record): string
  local id = tes3.editorId(record)

  if id ~= '' then
    return id
  elseif record.type == 'Cell' then
    return tes3.string(record.name)
  end

  return '<anonymous>'
end

type State = {
  plugin: Records,
  bases: { Records },
  names: { string },
  defined: { [string]: boolean },
  effects: { [string]: boolean },
  log: Log,
}

local function enqueue(
  state: State,
  record: Record,
  required: { [string]: boolean },
  pending: { Pending },
  pass: string
)
  local ids = {}

  for id in requiredIds(record, state.log) do
    table.insert(ids, id)
  end

  table.sort(ids)

  for _, id in ids do
    if required[id] then continue end

    required[id] = true
    table.insert(pending, {
      id = id,
      cause = {
        pass = pass,
        sourceType = tag(record),
        sourceId = sourceId(record),
        field = dependencyField(record, id),
      },
    })
  end
end

local function logImport(state: State, record: Record, cause: Cause)
  table.insert(state.log, 'Dependency import:')
  table.insert(state.log, `  pass={cause.pass}`)
  table.insert(state.log, `  target={tag(record)} '{tes3.editorId(record)}'`)
  table.insert(state.log, `  source={cause.sourceType} '{cause.sourceId}'`)
  table.insert(state.log, `  field={cause.field}`)
end

-- `VanillaIndex`: each master's records by lowercased id, the first of each id, leaving out the
-- types addVanillaRefs never copies and deleted records.
local function vanillaIndex(bases: { Records }): { { [string]: Record } }
  local index = {}

  for position, records in bases do
    local byId: { [string]: Record } = {}

    for _, record in records do
      if NeverCopy[record.type :: string] or tes3.isDeleted(record) then continue end

      local id = string.lower(tes3.editorId(record))

      if byId[id] == nil then byId[id] = record end
    end

    index[position] = byId
  end

  return index
end

local function resolve(
  state: State,
  index: { { [string]: Record } },
  required: { [string]: boolean },
  pending: { Pending },
  pass: string
)
  local head = 1

  while head <= #pending do
    local item = pending[head]
    head += 1

    if state.defined[item.id] then continue end

    local found: Record?, from = nil, 0

    for position, byId in index do
      local record = byId[item.id]

      if record then
        found, from = record, position
        break
      end
    end

    if not found then continue end

    local record = found :: Record
    local objectId = string.lower(tes3.editorId(record))

    if state.defined[objectId] then continue end

    state.defined[objectId] = true
    table.insert(
      state.log,
      `Copying '{tes3.editorId(record)}' ({tag(record)}) to 'Starwind.esp' from '{state.names[from] or 'master'}'`
    )
    logImport(state, record, item.cause)
    enqueue(state, record, required, pending, pass)
    table.insert(state.plugin, record)
  end

  table.clear(pending)
end

local Foundations: { [string]: boolean } =
  { GameSetting = true, MagicEffect = true, Race = true, Class = true }

local function importFoundations(
  state: State,
  required: { [string]: boolean },
  pending: { Pending },
  pass: string
)
  for position, records in state.bases do
    for _, record in records do
      if tes3.isDeleted(record) or not Foundations[record.type :: string] then continue end

      local set, id

      if record.type == 'MagicEffect' then
        set, id = state.effects, tes3.string(record.effectId)
      else
        set, id = state.defined, string.lower(tes3.editorId(record))
      end

      if set[id] then continue end

      set[id] = true
      logImport(state, record, {
        pass = pass,
        sourceType = 'FOUNDATION',
        sourceId = state.names[position] or 'master',
        field = 'foundation',
      })
      enqueue(state, record, required, pending, pass)
      table.insert(state.plugin, record)
    end
  end
end

-- `add_vanilla_refs_with_dialogue`.
local function addRefs(state: State, includeDialogue: boolean, pass: string)
  local index = vanillaIndex(state.bases)
  local required: { [string]: boolean } = {}
  local pending: { Pending } = {}

  for _, record in state.plugin do
    if tes3.isDeleted(record) or (not includeDialogue and record.type == 'DialogueInfo') then
      continue
    end

    enqueue(state, record, required, pending, pass)
  end

  table.sort(pending, function(left, right) return left.id < right.id end)

  resolve(state, index, required, pending, pass)
  importFoundations(state, required, pending, pass)
  resolve(state, index, required, pending, pass)
end

-- A topic's INFOs in OpenMW's order (`ESM::InfoOrder::insertInfo`), as addVanillaRefs keeps
-- them: a linked list with an index by lowercased id, so a long topic isn't rescanned per INFO.
type Node = { info: Record, prev: Node?, next: Node? }
type Group = {
  dialogue: Record?,
  dialogueType: string,
  head: Node?,
  tail: Node?,
  byId: { [string]: Node },
}

local function newGroup(): Group
  return { dialogue = nil, dialogueType = '', head = nil, tail = nil, byId = {} }
end

local function unlink(group: Group, node: Node)
  if node.prev then
    (node.prev :: Node).next = node.next
  else
    group.head = node.next
  end

  if node.next then
    (node.next :: Node).prev = node.prev
  else
    group.tail = node.prev
  end

  node.prev, node.next = nil, nil
end

-- Puts `node` before `before`, or last when `before` is nil.
local function linkBefore(group: Group, node: Node, before: Node?)
  if not before then
    node.prev = group.tail

    if group.tail then
      (group.tail :: Node).next = node
    else
      group.head = node
    end

    group.tail = node
    return
  end

  local after = before :: Node
  node.next = after
  node.prev = after.prev

  if after.prev then
    (after.prev :: Node).next = node
  else
    group.head = node
  end

  after.prev = node
end

local function insertInfo(group: Group, info: Record)
  local id = lower(info.id)
  local existing = group.byId[id]

  if existing and lower(existing.info.prevId) == lower(info.prevId) then
    existing.info = info
    return
  end

  -- OpenMW finds the insertion point, the node after the previous INFO, before it moves an
  -- existing node there.
  local prevId = lower(info.prevId)
  local before: Node?

  if prevId == '' then
    before = group.head
  else
    local previous = group.byId[prevId]
    before = if previous then previous.next else nil
  end

  if existing then
    existing.info = info

    if before ~= existing then
      unlink(group, existing)
      linkBefore(group, existing, before)
    end

    return
  end

  local node: Node = { info = info, prev = nil, next = nil }
  group.byId[id] = node
  linkBefore(group, node, before)
end

local function infos(group: Group): { Record }
  local result = {}
  local node = group.head

  while node do
    table.insert(result, node.info)
    node = node.next
  end

  return result
end

local function mergeDialogue(records: Records, groups: { [string]: Group })
  local topic: string? = nil

  for _, record in records do
    if record.type == 'Dialogue' then
      local key = lower(record.id)
      local group = groups[key]

      if not group then
        group = newGroup()
        groups[key] = group
      end

      group.dialogue = record
      group.dialogueType = tes3.string(record.dialogueType)
      topic = key
    elseif record.type == 'DialogueInfo' then
      if not topic or lower(record.id) == '' then continue end

      local group = groups[topic :: string]

      if not group then
        group = newGroup()
        groups[topic :: string] = group
      end

      insertInfo(group, record)
    else
      topic = nil
    end
  end
end

local function dialogueIds(records: Records): { [string]: { [string]: boolean } }
  local ids: { [string]: { [string]: boolean } } = {}
  local topic: string? = nil

  for _, record in records do
    if record.type == 'Dialogue' then
      topic = lower(record.id)
      ids[topic :: string] = ids[topic :: string] or {}
    elseif record.type == 'DialogueInfo' then
      if not topic then continue end

      local id = lower(record.id)

      if id ~= '' and not tes3.isDeleted(record) then
        local set = ids[topic :: string] or {}
        ids[topic :: string] = set
        set[id] = true
      end
    else
      topic = nil
    end
  end

  return ids
end

type Actor = { id: string, race: string, class: string }

local function population(records: Records): { Actor }
  local actors = {}

  for _, record in records do
    if tes3.isDeleted(record) then continue end

    if record.type == 'Npc' then
      table.insert(
        actors,
        { id = lower(record.id), race = lower(record.race), class = lower(record.class) }
      )
    elseif record.type == 'Creature' then
      table.insert(actors, { id = lower(record.id), race = '', class = '' })
    end
  end

  return actors
end

local function printPopulation(records: Records, log: Log)
  table.insert(log, 'Dialogue liveness population begin')

  for _, record in records do
    if tes3.isDeleted(record) then continue end

    if record.type == 'Npc' then
      local sex = if tes3.hasFlag(record.npcFlags, 'FEMALE') then 'female' else 'male'
      table.insert(
        log,
        `Dialogue liveness actor\tNpc\t{tes3.string(record.id)}\t{tes3.string(record.race)}\t{tes3.string(
          record.class
        )}\t{sex}`
      )
    elseif record.type == 'Creature' then
      table.insert(log, `Dialogue liveness actor\tCreature\t{tes3.string(record.id)}\t\t\t`)
    end
  end

  table.insert(log, 'Dialogue liveness population end')
end

-- `add_script_topic_references`: the topics a script's AddTopic lines name.
local function scriptTopics(
  text: string,
  topics: { [string]: string },
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

    local topic = topics[string.lower(operand)]

    if topic then
      live[topic] = live[topic] or {}
      live[topic].Script = true
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

-- `info_can_match_actor`: whether some actor fits the INFO's speaker, race, and class. Faction
-- membership is runtime state, so a faction never rules an INFO out.
local function canMatchActor(info: Record, index: ActorIndex): boolean
  local speaker, race, class =
    lower(info.speakerId), lower(info.speakerRace), lower(info.speakerClass)

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

local ReasonNames = { Starwind = 'StarwindTopic', Engine = 'EngineTopic', Script = 'ScriptTopic' }

-- `decouple_dialogue_infos`.
local function decoupleDialogue(state: State)
  local plugin = state.plugin
  local effective: { [string]: Group } = {}

  for position = #state.bases, 1, -1 do
    mergeDialogue(state.bases[position], effective)
  end

  mergeDialogue(plugin, effective)

  local starwind = dialogueIds(plugin)
  local actors = actorIndex(population(plugin))
  local live: { [string]: { [string]: boolean } } = {}

  for topic in starwind do
    live[topic] = live[topic] or {}
    live[topic].Starwind = true
  end

  local topicIds: { [string]: string } = {}

  for topic, group in effective do
    if Engine[group.dialogueType] then
      live[topic] = live[topic] or {}
      live[topic].Engine = true
    end

    if topic ~= '' then topicIds[topic] = topic end
  end

  for _, record in plugin do
    if record.type == 'Script' then scriptTopics(tes3.string(record.text), topicIds, live) end
  end

  -- `collect_live_dialogue_infos`, with its audit.
  local liveInfos: { [string]: { [string]: boolean } } = {}
  local counts = { effective = 0, owned = 0, retained = 0, pruned = 0 }
  local reasons: { [string]: number } = {}

  local function reason(name: string) reasons[name] = (reasons[name] or 0) + 1 end

  for topic, group in effective do
    local owned = starwind[topic]
    local why = live[topic]

    for _, info in infos(group) do
      if tes3.isDeleted(info) then continue end

      local id = lower(info.id)
      counts.effective += 1
      local mine = owned ~= nil and owned[id] == true

      if mine then
        counts.owned += 1
      end

      if why ~= nil and (mine or canMatchActor(info, actors)) then
        liveInfos[topic] = liveInfos[topic] or {}
        liveInfos[topic][id] = true

        if not mine then
          counts.retained += 1
          local speaker, race, class =
            lower(info.speakerId), lower(info.speakerRace), lower(info.speakerClass)
          local faction = lower(info.speakerFaction)

          if
            speaker == ''
            and race == ''
            and class == ''
            and faction == ''
            and Engine[group.dialogueType]
          then
            reason 'VANILLA_ENGINE_TOPIC_GENERIC'
          end

          if speaker ~= '' then reason 'VANILLA_MATCHING_SPEAKER_ID' end

          if race ~= '' then reason 'VANILLA_MATCHING_RACE' end

          if class ~= '' then reason 'VANILLA_MATCHING_CLASS' end

          if faction ~= '' then reason 'VANILLA_FACTION_UNKNOWN' end

          if why.Script then reason 'VANILLA_SCRIPT_TOPIC' end

          if why.Starwind then reason 'VANILLA_DIALOGUE_TOPIC' end
        end
      elseif not mine then
        counts.pruned += 1
      end
    end
  end

  local function appendLive(rebuilt: Records, group: Group, ids: { [string]: boolean })
    local survivors = {}

    for _, info in infos(group) do
      if not tes3.isDeleted(info) and ids[lower(info.id)] then table.insert(survivors, info) end
    end

    for index, info in survivors do
      local copy = table.clone(info)
      copy.prevId = if index > 1 then tes3.string(survivors[index - 1].id) else ''
      copy.nextId = if index < #survivors then tes3.string(survivors[index + 1].id) else ''
      table.insert(rebuilt, copy)
    end
  end

  local rebuilt: Records = {}
  local emitted: { [string]: boolean } = {}

  for _, record in plugin do
    if record.type == 'Dialogue' then
      local topic = lower(record.id)

      if emitted[topic] or not effective[topic] then continue end

      table.insert(rebuilt, record)

      if liveInfos[topic] then appendLive(rebuilt, effective[topic], liveInfos[topic]) end

      emitted[topic] = true
    elseif record.type ~= 'DialogueInfo' then
      table.insert(rebuilt, record)
    end
  end

  local missing = {}

  for topic in live do
    if not emitted[topic] then table.insert(missing, topic) end
  end

  table.sort(missing)
  local materialized = {}

  for _, topic in missing do
    local group = effective[topic]
    local ids = liveInfos[topic]

    if
      not group
      or not ids
      or not group.dialogue
      or tes3.string((group.dialogue :: Record).id) == ''
    then
      continue
    end

    local count = 0

    for _ in ids do
      count += 1
    end

    local names = {}

    for name in live[topic] do
      table.insert(names, ReasonNames[name])
    end

    table.sort(names)
    table.insert(materialized, { topic = topic, count = count, reasons = names })
    table.insert(rebuilt, group.dialogue :: Record)
    appendLive(rebuilt, group, ids)
  end

  table.clear(plugin)
  table.move(rebuilt, 1, #rebuilt, 1, plugin)

  table.insert(
    state.log,
    `Dialogue INFO audit: effective={counts.effective}, starwind_owned={counts.owned}, retained_vanilla={counts.retained}, pruned_vanilla={counts.pruned}`
  )

  local reasonNames = {}

  for name in reasons do
    table.insert(reasonNames, name)
  end

  table.sort(reasonNames)

  for _, name in reasonNames do
    table.insert(state.log, `Dialogue INFO keep reason: {name}={reasons[name]}`)
  end

  -- addVanillaRefs prints these from a BTreeMap, so in topic order.
  table.sort(materialized, function(left, right) return left.topic < right.topic end)

  for _, entry in materialized do
    local quoted = {}

    for _, name in entry.reasons do
      table.insert(quoted, `"{name}"`)
    end

    table.insert(
      state.log,
      `Dialogue DIAL materialized: topic="{entry.topic}" source=vanilla live_infos={entry.count} topic_reason=[{table.concat(
        quoted,
        ', '
      )}]`
    )
  end
end

local function sanitizePackageCells(state: State)
  for index, record in state.plugin do
    if record.type ~= 'Creature' and record.type ~= 'Npc' then continue end

    local packages = list(record.aiPackages)
    local copied: { Value }? = nil

    for position, package in packages do
      local ai = package :: Table

      if (ai.type == 'Escort' or ai.type == 'Follow') and not state.defined[lower(ai.cell)] then
        copied = copied or table.clone(packages)
        local fixed = table.clone(ai)
        fixed.cell = 'igtestcell'
        (copied :: { Value })[position] = fixed
      end
    end

    if copied then
      local copy = table.clone(record)
      copy.aiPackages = copied
      state.plugin[index] = copy
    end
  end
end

function addVanillaRefs.run(
  plugin: Records,
  bases: { Records },
  options: Options?
): (Records, { string })
  local records: Records = table.clone(plugin)
  local state: State = {
    plugin = records,
    bases = bases,
    names = options and options.names or {},
    defined = {},
    effects = {},
    log = {},
  }

  for _, record in records do
    if not NeverCopy[record.type :: string] then
      state.defined[string.lower(tes3.editorId(record))] = true
    end

    if record.type == 'MagicEffect' then state.effects[tes3.string(record.effectId)] = true end
  end

  -- Dirty vanilla INFOs mustn't bootstrap their speakers into the population dialogue is kept by.
  addRefs(state, false, 'pre-dialogue')
  sanitizePackageCells(state)
  printPopulation(records, state.log)
  decoupleDialogue(state)
  addRefs(state, true, 'post-dialogue')

  local kept: Records = {}
  local effects: { Record } = {}

  for _, record in records do
    if tes3.isDeleted(record) then continue end

    if record.type == 'MagicEffect' then
      local duplicate = false

      for _, other in effects do
        if tes3.equal(other, record) then
          duplicate = true
          break
        end
      end

      if duplicate then continue end

      table.insert(effects, record)
    end

    table.insert(kept, record)
  end

  local header = table.clone(kept[1])
  header.masters = {}
  header.version = 1.3
  kept[1] = header
  return kept, state.log
end

return addVanillaRefs
