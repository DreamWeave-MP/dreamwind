--!strict
--!native
--[[
@dreamwind/tools/merge-to-master: Greatness7's merge_to_master, over record lists.

  merge(plugin, master, options) -> records

Merges `plugin` into `master`, both lists of tes3conv-shaped records with the header first (see
@dreamwind/tools/tes3conv), and returns the merged master. `options.masterName` is the master's
file name, as `merge_to_master <plugin> <master>` would see it. `options.masters` maps each other
file the plugin names as a master (lowercased) to its records: merge_to_master reads only their
dialogue, to place the plugin's INFOs in the chain they continue, and drops it afterwards.
`options.removeDeleted` is `--remove-deleted`.

What it does, as merge_to_master 0.9.5 does it:
  * objects are keyed by type and lowercased id, except that the item, actor, spell, and static
    families share one key space: a plugin's NPC replaces the master's creature of the same id;
  * a merged CELL takes the plugin's flags, name, and data, its region, map color, water height,
    and atmosphere when it has them, and both sets of references, the plugin's replacing the
    master's at the same indices;
  * a DIAL takes the plugin's record, and its INFOs are inserted after their previous INFO
    (replaced in place when that is unchanged, at the front with none, at the end when it's
    missing), then every link but the chain's ends is repaired;
  * the plugin's masters are appended to the master's, and its references renumbered to follow
    the master's highest own index; texture indices are remapped the same way;
  * records come out sorted by type, then id.

merge_to_master renumbers references and textures in hash-map order, so two runs of it number
the same merge differently. This port walks cells and textures in the order the plugin has them,
which gives every run the same numbers. Cells and path grids come out sorted by name, each path
grid after its cell, and journals before the other topics, the others by dialogue type and id:
the order merge_to_master writes them in.
]]

local tes3 = require '../lib/tes3'

type Table = tes3.Table
type Value = tes3.Value
type Record = tes3.Record
type Records = tes3.Records

export type Options = {
  masterName: string,
  masters: { [string]: Records }?,
  removeDeleted: boolean?,
}

-- An INFO in a topic's chain: merge_to_master's VecDeque, as a linked list with an index by id.
type Node = { info: Record, prev: Node?, next: Node? }
type Group = { dialogue: Record?, head: Node?, tail: Node?, byId: { [string]: Node } }

type PluginData = {
  header: Record,
  objects: { [string]: Record },
  order: { string },
  dialogues: { [string]: Group },
  dialogueOrder: { string },
  ignored: { [Record]: boolean },
}

local mergeToMaster = {}

-- The families merge_to_master keys under one tag, so their ids share a space.
local SharedKeys: { [string]: boolean } = {
  Activator = true,
  Alchemy = true,
  Apparatus = true,
  Armor = true,
  Bodypart = true,
  Book = true,
  Clothing = true,
  Container = true,
  Creature = true,
  Door = true,
  Enchanting = true,
  Ingredient = true,
  LeveledCreature = true,
  LeveledItem = true,
  Light = true,
  Lockpick = true,
  MiscItem = true,
  Npc = true,
  Probe = true,
  RepairItem = true,
  Spell = true,
  Static = true,
  Weapon = true,
}

local function objectKey(record: Record): string?
  local id = string.lower(tes3.editorId(record))

  if id == '' then return nil end

  if SharedKeys[record.type :: string] then return '\0' .. id end

  return tes3.Tags[record.type :: string] .. id
end

local function newGroup(): Group return { dialogue = nil, head = nil, tail = nil, byId = {} } end

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

local function pushFront(group: Group, node: Node)
  node.next = group.head

  if group.head then
    (group.head :: Node).prev = node
  else
    group.tail = node
  end

  group.head = node
end

local function pushBack(group: Group, node: Node)
  node.prev = group.tail

  if group.tail then
    (group.tail :: Node).next = node
  else
    group.head = node
  end

  group.tail = node
end

local function insertAfter(group: Group, after: Node, node: Node)
  node.prev = after
  node.next = after.next

  if after.next then
    (after.next :: Node).prev = node
  else
    group.tail = node
  end

  after.next = node
end

-- merge_to_master's `DialogueGroup::insert_info`. Ids compare exactly, as it compares them.
local function insertInfo(group: Group, info: Record)
  local id = tes3.string(info.id)
  local prevId = tes3.string(info.prevId)
  local existing = group.byId[id]

  if existing then
    if tes3.string(existing.info.prevId) == prevId then
      existing.info = info
      return
    end

    unlink(group, existing)
    group.byId[id] = nil
  end

  local node: Node = { info = info, prev = nil, next = nil }
  group.byId[id] = node

  if prevId == '' then
    pushFront(group, node)
    return
  end

  local previous = group.byId[prevId]

  if previous then
    insertAfter(group, previous, node)
  else
    pushBack(group, node)
  end
end

-- merge_to_master's `repair_links`: each INFO's links name its neighbours, except the first's
-- previous and the last's next, which stay as they were. A changed INFO is copied, so lists
-- that still hold the original see it unchanged.
local function repairLinks(group: Group, ignored: { [Record]: boolean })
  local node = group.head

  -- It walks windows of three, so a topic of one or two INFOs keeps its links as they are.
  if not (node and node.next and (node.next :: Node).next) then return end

  while node do
    local info = node.info
    local wantPrev = node.prev and tes3.string((node.prev :: Node).info.id)
    local wantNext = node.next and tes3.string((node.next :: Node).info.id)
    local fixPrev = wantPrev ~= nil and tes3.string(info.prevId) ~= wantPrev
    local fixNext = wantNext ~= nil and tes3.string(info.nextId) ~= wantNext

    if fixPrev or fixNext then
      local copy = table.clone(info)

      if fixPrev then copy.prevId = wantPrev :: string end

      if fixNext then copy.nextId = wantNext :: string end

      if ignored[info] then ignored[copy] = true end

      node.info = copy
    end

    node = node.next
  end
end

local function newData(): PluginData
  return { header = {}, objects = {}, order = {}, dialogues = {}, dialogueOrder = {}, ignored = {} }
end

local function addDialogue(data: PluginData, key: string): Group
  local group = data.dialogues[key]

  if not group then
    group = newGroup()
    data.dialogues[key] = group
    table.insert(data.dialogueOrder, key)
  end

  return group
end

local function setObject(data: PluginData, key: string, record: Record)
  if data.objects[key] == nil then table.insert(data.order, key) end

  data.objects[key] = record
end

-- merge_to_master's `collect_objects`. With `dialogueOnly`, only DIAL and INFO, as
-- `from_path_dialogue_only` loads them.
local function collect(records: Records, dialogueOnly: boolean?): PluginData
  local data = newData()
  local current: Group? = nil

  for _, record in records do
    local kind = record.type

    if kind == 'Header' then
      data.header = record
    elseif kind == 'Dialogue' then
      current = addDialogue(data, tes3.lower(record.id));
      (current :: Group).dialogue = record
    elseif kind == 'DialogueInfo' then
      if not current then error(`Orphan DialogueInfo {tes3.string(record.id)}`) end

      insertInfo(current :: Group, record)
    elseif not dialogueOnly then
      local key = objectKey(record)

      if key then setObject(data, key, record) end
    end
  end

  return data
end

local function setAllIgnored(data: PluginData)
  for _, record in data.objects do
    data.ignored[record] = true
  end

  for _, group in data.dialogues do
    if group.dialogue then data.ignored[group.dialogue :: Record] = true end

    local node = group.head

    while node do
      data.ignored[node.info] = true
      node = node.next
    end
  end
end

local function mergeCell(plugin: Record, master: Record): Record
  local merged = table.clone(master)
  merged.flags = plugin.flags
  merged.name = plugin.name
  merged.data = plugin.data

  for _, field in { 'region', 'mapColor', 'waterHeight', 'atmosphereData' } do
    if plugin[field] ~= nil then merged[field] = plugin[field] end
  end

  local references: { Table } = table.clone((master.references or {}) :: { Table })
  local at: { [string]: number } = {}

  for index, reference in references do
    at[`{reference.mastIndex}:{reference.refrIndex}`] = index
  end

  for _, reference in (plugin.references or {}) :: { Table } do
    local key = `{reference.mastIndex}:{reference.refrIndex}`
    local index = at[key]

    if index then
      references[index] = reference
    else
      table.insert(references, reference)
      at[key] = #references
    end
  end

  merged.references = references
  return merged
end

-- `impl MergeInto for PluginData`: `self` into `target`.
local function mergeInto(source: PluginData, target: PluginData)
  target.header = source.header

  for key, ignored in source.ignored do
    target.ignored[key] = ignored
  end

  for _, key in source.order do
    local object = source.objects[key]
    local existing = target.objects[key]

    if existing and object.type == 'Cell' then
      local merged = mergeCell(object, existing)

      if source.ignored[object] then target.ignored[merged] = true end

      target.objects[key] = merged
    else
      setObject(target, key, object)
    end
  end

  for _, key in source.dialogueOrder do
    local group = source.dialogues[key]
    local existing = target.dialogues[key]

    if not existing then
      -- A topic the target doesn't have is moved over whole, chain and all.
      local copy = addDialogue(target, key)
      copy.dialogue = group.dialogue
      local node = group.head

      while node do
        local moved: Node = { info = node.info, prev = nil, next = nil }
        pushBack(copy, moved)
        copy.byId[tes3.string(node.info.id)] = moved
        node = node.next
      end

      continue
    end

    (existing :: Group).dialogue = group.dialogue
    local node = group.head

    while node do
      insertInfo(existing :: Group, node.info)
      node = node.next
    end

    repairLinks(existing :: Group, target.ignored)
  end
end

local function sameName(left: string, right: string): boolean
  return string.lower(left) == string.lower(right)
end

type Master = { string | number }

local function masterName(master: Value): string return tes3.string((master :: Table)[1]) end

-- merge_to_master's `get_index_remap`.
local function indexRemap(
  pluginMasters: { Master },
  masterMasters: { Master },
  target: string
): ({ Master }, { number })
  local newMasters: { Master } = table.clone(masterMasters)
  local remap = { [0] = 0 }

  for index, master in pluginMasters do
    local name = masterName(master)

    if sameName(name, target) then
      remap[index] = 0
      continue
    end

    local found: number? = nil

    for position, existing in newMasters do
      if sameName(masterName(existing), name) then
        found = position
        break
      end
    end

    if not found then
      table.insert(newMasters, master)
      found = #newMasters
    end

    remap[index] = found :: number
  end

  return newMasters, remap
end

local function nextReferenceIndex(master: PluginData): number
  local highest: number? = nil

  for _, key in master.order do
    local object = master.objects[key]

    if object.type ~= 'Cell' then continue end

    for _, reference in (object.references or {}) :: { Table } do
      if reference.mastIndex == 0 then
        local index = reference.refrIndex :: number

        if highest == nil or index > highest then highest = index end
      end
    end
  end

  return if highest then highest + 1 else 1
end

local function remapMasters(plugin: PluginData, master: PluginData, target: string)
  local pluginMasters = (plugin.header.masters or {}) :: { Master }
  local masterMasters = (master.header.masters or {}) :: { Master }
  local newMasters, remap = indexRemap(pluginMasters, masterMasters, target)
  local header = table.clone(master.header)
  header.masters = newMasters :: { Value }
  plugin.header = header

  local identity = true

  for index = 0, #pluginMasters do
    if remap[index] ~= index then
      identity = false
      break
    end
  end

  if identity then return end

  local nextIndex = nextReferenceIndex(master)

  for _, key in plugin.order do
    local object = plugin.objects[key]

    if object.type ~= 'Cell' then continue end

    local references = {}

    for _, reference in (object.references or {}) :: { Table } do
      local copy = table.clone(reference)

      if copy.mastIndex == 0 then
        copy.refrIndex = nextIndex
        nextIndex += 1
      else
        copy.mastIndex = remap[copy.mastIndex :: number]
      end

      table.insert(references, copy)
    end

    local cell = table.clone(object)
    cell.references = references
    plugin.objects[key] = cell
  end
end

local function remapTextures(plugin: PluginData, master: PluginData)
  local highest: number? = nil

  for _, object in master.objects do
    if object.type == 'LandscapeTexture' then
      local index = object.index :: number

      if highest == nil or index > highest then highest = index end
    end
  end

  if highest == nil then return end

  local nextIndex = (highest :: number) + 1
  local remap: { [number]: number } = {}

  for _, key in plugin.order do
    local texture = plugin.objects[key]

    if texture.type ~= 'LandscapeTexture' then continue end

    local existing = master.objects[key]
    local old = texture.index :: number
    local new: number

    if existing and existing.type == 'LandscapeTexture' then
      new = existing.index :: number
    else
      new = nextIndex
      nextIndex += 1
    end

    if old ~= new then
      local copy = table.clone(texture)
      copy.index = new
      plugin.objects[key] = copy
      remap[old + 1] = new + 1
    end
  end

  if next(remap) == nil then return end

  for _, key in plugin.order do
    local land = plugin.objects[key]

    if land.type ~= 'Landscape' then continue end

    local indices = land.textureIndices :: Table?

    if not indices then continue end

    local data = indices.data :: { { number } }
    local rows = {}

    for row, values in data do
      local copied = table.clone(values)

      for column, value in copied do
        local new = remap[value]

        if new then copied[column] = new end
      end

      rows[row] = copied
    end

    local copy = table.clone(land)
    local textures = table.clone(indices)
    textures.data = rows
    copy.textureIndices = textures
    plugin.objects[key] = copy
  end
end

local function removeIgnored(data: PluginData)
  for key, object in data.objects do
    if data.ignored[object] then data.objects[key] = nil end
  end

  for key, group in data.dialogues do
    if group.dialogue == nil or data.ignored[group.dialogue :: Record] then
      data.dialogues[key] = nil
      continue
    end

    local node = group.head

    while node do
      local following = node.next

      if data.ignored[node.info] then
        unlink(group, node)
        group.byId[tes3.string(node.info.id)] = nil
      end

      node = following
    end
  end
end

local function removeDeleted(data: PluginData)
  local deleted: { [string]: boolean } = {}

  for key, object in data.objects do
    if tes3.isDeleted(object) then
      data.objects[key] = nil
      deleted[string.lower(tes3.editorId(object))] = true
    end
  end

  for key, object in data.objects do
    if object.type ~= 'Cell' then continue end

    local kept = {}

    for _, reference in (object.references or {}) :: { Table } do
      local local_ = reference.mastIndex == 0
      local gone = local_
        and (reference.deleted == true or deleted[tes3.lower(reference.id)] == true)

      if not gone then table.insert(kept, reference) end
    end

    local copy = table.clone(object)
    copy.references = kept
    data.objects[key] = copy
  end
end

local DialogueTypeOrder: { [string]: number } =
  { Topic = 0, Voice = 1, Greeting = 2, Persuasion = 3, Journal = 4 }

local function bytesLess(left: string, right: string): boolean return left < right end

-- The order merge_to_master writes records in: tes3's type order, then each record's sort hint
-- and id; cells and path grids by name, each path grid after its cell; journals first among
-- topics, the rest by dialogue type and id.
local function intoRecords(data: PluginData): Records
  type Entry = {
    record: Record,
    order: number,
    hint: number,
    id: string,
    rank: number,
    position: number,
  }
  local entries: { Entry } = {}

  for position, key in data.order do
    local record = data.objects[key]

    if record == nil then continue end

    local kind = record.type :: string
    local hint, id, rank = 0, tes3.string(record.id), 0

    if kind == 'LandscapeTexture' then
      hint = record.index :: number
      id = ''
    elseif kind == 'MagicEffect' then
      hint = tes3.EffectIndex[tes3.string(record.effectId)] or -1
      id = ''
    elseif kind == 'Skill' then
      hint = tes3.SkillIndex[tes3.string(record.skillId)] or -1
      id = ''
    elseif kind == 'Cell' then
      id = tes3.string(record.name)
    elseif kind == 'PathGrid' then
      id, rank = tes3.string(record.cell), 1
    elseif kind == 'Landscape' then
      id = ''
    end

    table.insert(entries, {
      record = record,
      order = tes3.SortOrder[kind],
      hint = hint,
      id = id,
      rank = rank,
      position = position,
    })
  end

  table.sort(entries, function(left, right)
    if left.order ~= right.order then
      return left.order < right.order
    elseif left.hint ~= right.hint then
      return left.hint < right.hint
    elseif left.id ~= right.id then
      return bytesLess(left.id, right.id)
    elseif left.rank ~= right.rank then
      return left.rank < right.rank
    end

    return left.position < right.position
  end)

  local records: Records = { data.header }

  for _, entry in entries do
    table.insert(records, entry.record)
  end

  local groups = {}

  for _, key in data.dialogueOrder do
    local group = data.dialogues[key]

    if group and group.dialogue then table.insert(groups, group) end
  end

  local function journal(group: Group): number
    local kind = tes3.string((group.dialogue :: Record).dialogueType)
    return if kind == 'Journal' then -1 else DialogueTypeOrder[kind] or 5
  end

  table.sort(groups, function(left, right)
    local a, b = journal(left), journal(right)

    if a ~= b then return a < b end

    return bytesLess(
      tes3.string((left.dialogue :: Record).id),
      tes3.string((right.dialogue :: Record).id)
    )
  end)

  -- SNDG (38) sorts after cells and before dialogue; it was placed with the objects above.
  for _, group in groups do
    table.insert(records, group.dialogue :: Record)
    local node = group.head

    while node do
      table.insert(records, node.info)
      node = node.next
    end
  end

  return records
end

function mergeToMaster.merge(plugin: Records, master: Records, options: Options): Records
  local target = options.masterName
  local pluginData = collect(plugin)
  local pluginMasters = (pluginData.header.masters or {}) :: { Master }
  local present = false

  for _, entry in pluginMasters do
    if sameName(masterName(entry), target) then
      present = true
      break
    end
  end

  if not present then
    local header = table.clone(pluginData.header)
    local masters = table.clone(pluginMasters)
    table.insert(masters, { target, 0 })
    header.masters = masters :: { Value }
    pluginData.header = header
    pluginMasters = masters
  end

  -- merge_masters: the target whole, every other master's dialogue as ignored context.
  local merged = newData()
  local header: Record? = nil

  for _, entry in pluginMasters do
    local name = masterName(entry)
    local data: PluginData

    if sameName(name, target) then
      data = collect(master)
      header = data.header
    else
      local records = options.masters and options.masters[string.lower(name)]

      if not records then error(`merge_to_master needs the master '{name}'`) end

      data = collect(records, true)
      setAllIgnored(data)
    end

    mergeInto(data, merged)
  end

  merged.header = header or {}
  remapMasters(pluginData, merged, target)
  remapTextures(pluginData, merged)
  mergeInto(pluginData, merged)
  removeIgnored(merged)

  if options.removeDeleted then removeDeleted(merged) end

  return intoRecords(merged)
end

return mergeToMaster
