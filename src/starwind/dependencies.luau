--!strict
--!native
-- motherjungle_audit.dependencies: the typed references the closure audit and the split follow,
-- one entry per field occurrence, kinds and all.

local tes3 = require '../lib/tes3'

type Table = tes3.Table
type Value = tes3.Value
type Record = tes3.Record

export type Dependency = {
  target: string,
  target_original: string,
  source_type: string,
  source_id: string,
  kind: string,
}

local dependencies = {}

dependencies.HardKinds = {} :: { [string]: boolean }

local HardKindNames = {
  'race.spells',
  'soundgen.creature',
  'soundgen.sound',
  'magic_effect.bolt_sound',
  'magic_effect.cast_sound',
  'magic_effect.hit_sound',
  'magic_effect.area_sound',
  'magic_effect.cast_visual',
  'magic_effect.bolt_visual',
  'magic_effect.hit_visual',
  'magic_effect.area_visual',
  'region.sleep_creature',
  'region.sounds',
  'birthsign.spells',
  'door.script',
  'door.open_sound',
  'door.close_sound',
  'miscitem.script',
  'weapon.script',
  'weapon.enchanting',
  'container.script',
  'container.inventory',
  'creature.script',
  'creature.inventory',
  'creature.spells',
  'creature.ai.activate',
  'creature.sound',
  'bodypart.race',
  'light.script',
  'light.sound',
  'npc.script',
  'npc.inventory',
  'npc.spells',
  'npc.ai.activate',
  'npc.race',
  'npc.class',
  'npc.faction',
  'npc.head',
  'npc.hair',
  'armor.script',
  'armor.enchanting',
  'armor.male_bodypart',
  'armor.female_bodypart',
  'clothing.script',
  'clothing.enchanting',
  'clothing.male_bodypart',
  'clothing.female_bodypart',
  'repairitem.script',
  'activator.script',
  'apparatus.script',
  'lockpick.script',
  'probe.script',
  'ingredient.script',
  'book.script',
  'book.enchanting',
  'alchemy.script',
  'leveled_item.items',
  'leveled_creature.creatures',
  'cell.region',
  'cell.reference.id',
  'cell.reference.owner',
  'cell.reference.owner_global',
  'cell.reference.owner_faction',
  'cell.reference.key',
  'cell.reference.trap',
  'cell.reference.soul',
  'info.speaker_id',
  'info.speaker_race',
  'info.speaker_class',
  'info.speaker_faction',
  'info.player_faction',
  'faction.reaction',
}

for _, kind in HardKindNames do
  dependencies.HardKinds[kind] = true
end

-- TES3/TESCS's "-NO FACTION-" sentinel in dialogue faction fields.
local NoFaction = 'ffff'

local ScriptOnly: { [string]: boolean } = {
  MiscItem = true,
  RepairItem = true,
  Activator = true,
  Apparatus = true,
  Lockpick = true,
  Probe = true,
  Ingredient = true,
  Alchemy = true,
}

local MagicEffectFields = {
  { 'boltSound', 'bolt_sound' },
  { 'castSound', 'cast_sound' },
  { 'hitSound', 'hit_sound' },
  { 'areaSound', 'area_sound' },
  { 'castVisual', 'cast_visual' },
  { 'boltVisual', 'bolt_visual' },
  { 'hitVisual', 'hit_visual' },
  { 'areaVisual', 'area_visual' },
}

local ReferenceFields = {
  { 'owner', 'owner' },
  { 'ownerGlobal', 'owner_global' },
  { 'ownerFaction', 'owner_faction' },
  { 'key', 'key' },
  { 'trap', 'trap' },
  { 'soul', 'soul' },
}

local function list(value: Value?): { Value } return (value or {}) :: { Value } end

-- The dependencies of `record`, the `ordinal`th record of its plugin.
function dependencies.of(record: Record, ordinal: number): { Dependency }
  local out: { Dependency } = {}
  local kind = tes3.string(record.type)
  local sourceId = tes3.auditId(record)

  if sourceId == '' then sourceId = tes3.string(record.name) end

  if sourceId == '' then sourceId = `#{ordinal}` end

  local function add(value: Value?, dependency: string)
    if type(value) ~= 'string' or value == '' then return end

    table.insert(out, {
      target = string.lower(value),
      target_original = value,
      source_type = kind,
      source_id = sourceId,
      kind = dependency,
    })
  end

  local function inventory(prefix: string)
    for _, pair in list(record.inventory) do
      local item = pair :: Table

      if #item > 1 then add(item[2], `{prefix}.inventory`) end
    end
  end

  local function spells(prefix: string)
    for _, spell in list(record.spells) do
      add(spell, `{prefix}.spells`)
    end
  end

  local function activate(prefix: string)
    for _, package in list(record.aiPackages) do
      local ai = package :: Table

      if ai.type == 'Activate' then add(ai.target, `{prefix}.ai.activate`) end
    end
  end

  if kind == 'Race' then
    spells 'race'
  elseif kind == 'SoundGen' then
    add(record.creature, 'soundgen.creature')
    add(record.sound, 'soundgen.sound')
  elseif kind == 'MagicEffect' then
    for _, field in MagicEffectFields do
      add(record[field[1]], `magic_effect.{field[2]}`)
    end
  elseif kind == 'Region' then
    add(record.sleepCreature, 'region.sleep_creature')

    for _, pair in list(record.sounds) do
      local sound = pair :: Table

      if #sound > 0 then add(sound[1], 'region.sounds') end
    end
  elseif kind == 'Birthsign' then
    spells 'birthsign'
  elseif kind == 'Door' then
    add(record.script, 'door.script')
    add(record.openSound, 'door.open_sound')
    add(record.closeSound, 'door.close_sound')
  elseif ScriptOnly[kind] then
    add(record.script, `{string.lower(kind)}.script`)
  elseif kind == 'Weapon' then
    add(record.script, 'weapon.script')
    add(record.enchanting, 'weapon.enchanting')
  elseif kind == 'Container' then
    add(record.script, 'container.script')
    inventory 'container'
  elseif kind == 'Creature' then
    add(record.script, 'creature.script')
    inventory 'creature'
    spells 'creature'
    activate 'creature'
    add(record.sound, 'creature.sound')
  elseif kind == 'Bodypart' then
    add(record.race, 'bodypart.race')
  elseif kind == 'Light' then
    add(record.script, 'light.script')
    add(record.sound, 'light.sound')
  elseif kind == 'Npc' then
    add(record.script, 'npc.script')
    inventory 'npc'
    spells 'npc'
    activate 'npc'

    for _, field in { 'race', 'class', 'faction', 'head', 'hair' } do
      add(record[field], `npc.{field}`)
    end
  elseif kind == 'Armor' or kind == 'Clothing' then
    local prefix = string.lower(kind)
    add(record.script, `{prefix}.script`)
    add(record.enchanting, `{prefix}.enchanting`)

    for _, part in list(record.bipedObjects) do
      add((part :: Table).maleBodypart, `{prefix}.male_bodypart`)
      add((part :: Table).femaleBodypart, `{prefix}.female_bodypart`)
    end
  elseif kind == 'Book' then
    add(record.script, 'book.script')
    add(record.enchanting, 'book.enchanting')
  elseif kind == 'LeveledItem' then
    for _, pair in list(record.items) do
      local item = pair :: Table

      if #item > 0 then add(item[1], 'leveled_item.items') end
    end
  elseif kind == 'LeveledCreature' then
    for _, pair in list(record.creatures) do
      local creature = pair :: Table

      if #creature > 0 then add(creature[1], 'leveled_creature.creatures') end
    end
  elseif kind == 'Cell' then
    add(record.region, 'cell.region')

    for _, value in list(record.references) do
      local reference = value :: Table
      add(reference.id, 'cell.reference.id')

      for _, field in ReferenceFields do
        add(reference[field[1]], `cell.reference.{field[2]}`)
      end
    end
  elseif kind == 'DialogueInfo' then
    add(record.speakerId, 'info.speaker_id')
    add(record.speakerRace, 'info.speaker_race')
    add(record.speakerClass, 'info.speaker_class')

    local factionFields =
      { { 'speakerFaction', 'speaker_faction' }, { 'playerFaction', 'player_faction' } }

    for _, field in factionFields do
      local value = record[field[1]]

      if tes3.lower(value) ~= NoFaction then add(value, `info.{field[2]}`) end
    end
  elseif kind == 'Faction' then
    for _, reaction in list(record.reactions) do
      add((reaction :: Table).faction, 'faction.reaction')
    end
  end

  return out
end

return dependencies
