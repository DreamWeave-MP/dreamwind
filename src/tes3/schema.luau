--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The vocabulary record values are spelled in, as jess-omwaddon serializes it: enums by variant
name (a value no variant has reads as the enum's default, as the Rust loader does), flags as their
names joined by ` | ` with any unnamed bits after them in lowercase hex (bitflags' text format),
and byte blobs as standard base64.
]]

local bytes = require '@dream/bytes'

export type Enum = {
  name: string,
  --- The variant each value names.
  names: { [number]: string },
  --- The value each variant name stands for.
  values: { [string]: number },
  --- The variant a value no variant has reads as.
  default: string,
}

local function enum(name: string, default: string, pairs: { [number]: string }): Enum
  local values: { [string]: number } = {}
  for value, variant in pairs do
    values[variant] = value
  end

  return { name = name, names = pairs, values = values, default = default }
end

--- An enum whose variants are consecutive values from `first`.
local function run(name: string, first: number, variants: { string }): Enum
  local pairs = {}
  for i, variant in variants do
    pairs[first + i - 1] = variant
  end

  return enum(name, variants[1], pairs)
end

local Attributes = {
  'None',
  'Strength',
  'Intelligence',
  'Willpower',
  'Agility',
  'Speed',
  'Endurance',
  'Personality',
  'Luck',
}

local Skills = {
  'None',
  'Block',
  'Armorer',
  'MediumArmor',
  'HeavyArmor',
  'BluntWeapon',
  'LongBlade',
  'Axe',
  'Spear',
  'Athletics',
  'Enchant',
  'Destruction',
  'Alteration',
  'Illusion',
  'Conjuration',
  'Mysticism',
  'Restoration',
  'Alchemy',
  'Unarmored',
  'Security',
  'Sneak',
  'Acrobatics',
  'LightArmor',
  'ShortBlade',
  'Marksman',
  'Mercantile',
  'Speechcraft',
  'HandToHand',
}

local Effects = {
  'None',
  'WaterBreathing',
  'SwiftSwim',
  'WaterWalking',
  'Shield',
  'FireShield',
  'LightningShield',
  'FrostShield',
  'Burden',
  'Feather',
  'Jump',
  'Levitate',
  'SlowFall',
  'Lock',
  'Open',
  'FireDamage',
  'ShockDamage',
  'FrostDamage',
  'DrainAttribute',
  'DrainHealth',
  'DrainMagicka',
  'DrainFatigue',
  'DrainSkill',
  'DamageAttribute',
  'DamageHealth',
  'DamageMagicka',
  'DamageFatigue',
  'DamageSkill',
  'Poison',
  'WeaknessToFire',
  'WeaknessToFrost',
  'WeaknessToShock',
  'WeaknessToMagicka',
  'WeaknessToCommonDisease',
  'WeaknessToBlightDisease',
  'WeaknessToCorprus',
  'WeaknessToPoison',
  'WeaknessToNormalWeapons',
  'DisintegrateWeapon',
  'DisintegrateArmor',
  'Invisibility',
  'Chameleon',
  'Light',
  'Sanctuary',
  'NightEye',
  'Charm',
  'Paralyze',
  'Silence',
  'Blind',
  'Sound',
  'CalmHumanoid',
  'CalmCreature',
  'FrenzyHumanoid',
  'FrenzyCreature',
  'DemoralizeHumanoid',
  'DemoralizeCreature',
  'RallyHumanoid',
  'RallyCreature',
  'Dispel',
  'SoulTrap',
  'Telekinesis',
  'Mark',
  'Recall',
  'DivineIntervention',
  'AlmsiviIntervention',
  'DetectAnimal',
  'DetectEnchantment',
  'DetectKey',
  'SpellAbsorption',
  'Reflect',
  'CureCommonDisease',
  'CureBlightDisease',
  'CureCorprus',
  'CurePoison',
  'CureParalyzation',
  'RestoreAttribute',
  'RestoreHealth',
  'RestoreMagicka',
  'RestoreFatigue',
  'RestoreSkill',
  'FortifyAttribute',
  'FortifyHealth',
  'FortifyMagicka',
  'FortifyFatigue',
  'FortifySkill',
  'FortifyMagickaMultiplier',
  'AbsorbAttribute',
  'AbsorbHealth',
  'AbsorbMagicka',
  'AbsorbFatigue',
  'AbsorbSkill',
  'ResistFire',
  'ResistFrost',
  'ResistShock',
  'ResistMagicka',
  'ResistCommonDisease',
  'ResistBlightDisease',
  'ResistCorprus',
  'ResistPoison',
  'ResistNormalWeapons',
  'ResistParalysis',
  'RemoveCurse',
  'TurnUndead',
  'SummonScamp',
  'SummonClannfear',
  'SummonDaedroth',
  'SummonDremora',
  'SummonGhost',
  'SummonSkeleton',
  'SummonLeastBonewalker',
  'SummonGreaterBonewalker',
  'SummonBonelord',
  'SummonTwilight',
  'SummonHunger',
  'SummonGoldenSaint',
  'SummonFlameAtronach',
  'SummonFrostAtronach',
  'SummonStormAtronach',
  'FortifyAttackBonus',
  'CommandCreature',
  'CommandHumanoid',
  'BoundDagger',
  'BoundLongsword',
  'BoundMace',
  'BoundBattleAxe',
  'BoundSpear',
  'BoundLongbow',
  'ExtraSpell',
  'BoundCuirass',
  'BoundHelm',
  'BoundBoots',
  'BoundShield',
  'BoundGloves',
  'Corprus',
  'Vampirism',
  'SummonCenturionSphere',
  'SunDamage',
  'StuntedMagicka',
  'SummonFabricant',
  'SummonWolf',
  'SummonBear',
  'SummonBoneWolf',
  'Summon04',
  'Summon05',
}

local FilterFunctions: { [number]: string } = {}
do
  local named = {
    'ReactionLow',
    'ReactionHigh',
    'RankRequirement',
    'Reputation',
    'HealthPercent',
    'PcReputation',
    'PcLevel',
    'PcHealthPercent',
    'PcMagicka',
    'PcFatigue',
    'PcStrength',
    'PcBlock',
    'PcArmorer',
    'PcMediumArmor',
    'PcHeavyArmor',
    'PcBluntWeapon',
    'PcLongBlade',
    'PcAxe',
    'PcSpear',
    'PcAthletics',
    'PcEnchant',
    'PcDestruction',
    'PcAlteration',
    'PcIllusion',
    'PcConjuration',
    'PcMysticism',
    'PcRestoration',
    'PcAlchemy',
    'PcUnarmored',
    'PcSecurity',
    'PcSneak',
    'PcAcrobatics',
    'PcLightArmor',
    'PcShortBlade',
    'PcMarksman',
    'PcMercantile',
    'PcSpeechcraft',
    'PcHandToHand',
    'PcSex',
    'PcExpelled',
    'PcCommonDisease',
    'PcBlightDisease',
    'PcClothingModifier',
    'PcCrimeLevel',
    'SameSex',
    'SameRace',
    'SameFaction',
    'FactionRankDifference',
    'Detected',
    'Alarmed',
    'Choice',
    'PcIntelligence',
    'PcWillpower',
    'PcAgility',
    'PcSpeed',
    'PcEndurance',
    'PcPersonality',
    'PcLuck',
    'PcCorprus',
    'Weather',
    'PcVampire',
    'Level',
    'Attacked',
    'TalkedToPc',
    'PcHealth',
    'CreatureTarget',
    'FriendHit',
    'Fight',
    'Hello',
    'Alarm',
    'Flee',
    'ShouldAttack',
    'Werewolf',
    'WerewolfKills',
  }
  -- `00` to `73`: two ASCII digits, read as a little-endian u16.

  for i, variant in named do
    local n = i - 1
    FilterFunctions[(48 + n // 10) + (48 + n % 10) * 256] = variant
  end

  for _, pair in
    {
      { 'CX', 'NotClass' },
      { 'DX', 'DeadType' },
      { 'FX', 'NotFaction' },
      { 'IX', 'ItemType' },
      { 'JX', 'JournalType' },
      { 'LX', 'NotCell' },
      { 'RX', 'NotRace' },
      { 'XX', 'NotIdType' },
      { 'fX', 'Global' },
      { 'lX', 'PcGold' },
      { '2X', 'CompareGlobal' },
      { '3X', 'CompareLocal' },
      { 'sX', 'VariableCompare' },
    }

  do
    FilterFunctions[string.byte(pair[1], 1) + string.byte(pair[1], 2) * 256] = pair[2]
  end
end

local Enums = table.freeze {
  FileType = enum('FileType', 'Esp', { [0] = 'Esp', [1] = 'Esm', [32] = 'Ess' }),
  GlobalType = enum('GlobalType', 'Float', { [102] = 'Float', [108] = 'Long', [115] = 'Short' }),
  AttributeId = run('AttributeId', -1, Attributes),
  Specialization = run('Specialization', -1, { 'None', 'Combat', 'Magic', 'Stealth' }),
  SkillId = run('SkillId', -1, Skills),
  EffectId = run('EffectId', -1, Effects),
  EffectRange = run('EffectRange', 0, { 'OnSelf', 'OnTouch', 'OnTarget' }),
  EffectSchool = run(
    'EffectSchool',
    0,
    { 'Alteration', 'Conjuration', 'Destruction', 'Illusion', 'Mysticism', 'Restoration' }
  ),
  ApparatusType = run('ApparatusType', 0, { 'MortarAndPestle', 'Alembic', 'Calcinator', 'Retort' }),
  ArmorType = run('ArmorType', 0, {
    'Helmet',
    'Cuirass',
    'LeftPauldron',
    'RightPauldron',
    'Greaves',
    'Boots',
    'LeftGauntlet',
    'RightGauntlet',
    'Shield',
    'LeftBracer',
    'RightBracer',
  }),
  BookType = run('BookType', 0, { 'Book', 'Scroll' }),
  ClothingType = run('ClothingType', 0, {
    'Pants',
    'Shoes',
    'Shirt',
    'Belt',
    'Robe',
    'RightGlove',
    'LeftGlove',
    'Skirt',
    'Ring',
    'Amulet',
  }),
  CreatureType = run('CreatureType', 0, { 'Normal', 'Daedra', 'Undead', 'Humanoid' }),
  WeaponType = run('WeaponType', 0, {
    'ShortBladeOneHand',
    'LongBladeOneHand',
    'LongBladeTwoClose',
    'BluntOneHand',
    'BluntTwoClose',
    'BluntTwoWide',
    'SpearTwoWide',
    'AxeOneHand',
    'AxeTwoHand',
    'MarksmanBow',
    'MarksmanCrossbow',
    'MarksmanThrown',
    'Arrow',
    'Bolt',
  }),
  SpellType = run('SpellType', 0, { 'Spell', 'Ability', 'Blight', 'Disease', 'Curse', 'Power' }),
  EnchantType = run(
    'EnchantType',
    0,
    { 'CastOnce', 'CastOnStrike', 'CastWhenUsed', 'ConstantEffect' }
  ),
  BodypartId = run('BodypartId', 0, {
    'Head',
    'Hair',
    'Neck',
    'Chest',
    'Groin',
    'Hand',
    'Wrist',
    'Forearm',
    'UpperArm',
    'Foot',
    'Ankle',
    'Knee',
    'UpperLeg',
    'Clavicle',
    'Tail',
  }),
  BodypartType = run('BodypartType', 0, { 'Skin', 'Clothing', 'Armor' }),
  BipedObjectType = run('BipedObjectType', 0, {
    'Head',
    'Hair',
    'Neck',
    'Chest',
    'Groin',
    'Skirt',
    'RightHand',
    'LeftHand',
    'RightWrist',
    'LeftWrist',
    'Shield',
    'RightForearm',
    'LeftForearm',
    'RightUpperArm',
    'LeftUpperArm',
    'RightFoot',
    'LeftFoot',
    'RightAnkle',
    'LeftAnkle',
    'RightKnee',
    'LeftKnee',
    'RightUpperLeg',
    'LeftUpperLeg',
    'RightPauldron',
    'LeftPauldron',
    'Weapon',
    'Tail',
  }),
  Sex = run('Sex', -1, { 'Any', 'Male', 'Female' }),
  DialogueType = run('DialogueType', 0, { 'Topic', 'Voice', 'Greeting', 'Persuasion', 'Journal' }),
  FilterType = enum('FilterType', 'None', {
    [48] = 'None',
    [49] = 'Function',
    [50] = 'Global',
    [51] = 'Local',
    [52] = 'Journal',
    [53] = 'Item',
    [54] = 'Dead',
    [55] = 'NotId',
    [56] = 'NotFaction',
    [57] = 'NotClass',
    [65] = 'NotRace',
    [66] = 'NotCell',
    [67] = 'NotLocal',
  }),
  FilterFunction = enum('FilterFunction', 'ReactionLow', FilterFunctions),
  FilterComparison = enum('FilterComparison', 'Equal', {
    [48] = 'Equal',
    [49] = 'NotEqual',
    [50] = 'Greater',
    [51] = 'GreaterEqual',
    [52] = 'Less',
    [53] = 'LessEqual',
  }),
  SoundGenType = run(
    'SoundGenType',
    0,
    { 'LeftFoot', 'RightFoot', 'SwimLeft', 'SwimRight', 'Moan', 'Roar', 'Scream', 'Land' }
  ),
}

--- `value`'s variant name, or the enum's default for a value no variant has.
local function nameOf(e: Enum, value: number): string return e.names[value] or e.default end

--- The value variant `name` stands for; an error naming the enum for anything else.
local function valueOf(e: Enum, name: unknown, field: string): number
  local value = if type(name) == 'string' then e.values[name] else nil
  if value then return value end

  local variants = {}
  for variant in e.values do
    table.insert(variants, variant)
  end

  table.sort(variants)
  error(
    `{field}: unknown variant '{tostring(name)}', expected one of {table.concat(variants, ', ')}`,
    0
  )
end

export type Flags = { { number | string } }

local function flags(...: { number | string }): Flags return table.freeze { ... } end

local Flags = table.freeze {
  ObjectFlags = flags(
    { 0x2, 'MODIFIED' },
    { 0x20, 'DELETED' },
    { 0x400, 'PERSISTENT' },
    { 0x1000, 'IGNORED' },
    {
      0x2000,
      'BLOCKED',
    }
  ),
  LandscapeFlags = flags(
    { 0x1, 'USES_VERTEX_HEIGHTS_AND_NORMALS' },
    { 0x2, 'USES_VERTEX_COLORS' },
    { 0x4, 'USES_TEXTURES' }
  ),
  CellFlags = flags(
    { 0x1, 'IS_INTERIOR' },
    { 0x2, 'HAS_WATER' },
    { 0x4, 'RESTING_IS_ILLEGAL' },
    { 0x80, 'BEHAVES_LIKE_EXTERIOR' }
  ),
  LightFlags = flags(
    { 0x1, 'DYNAMIC' },
    { 0x2, 'CAN_CARRY' },
    { 0x4, 'NEGATIVE' },
    { 0x8, 'FLICKER' },
    { 0x10, 'FIRE' },
    { 0x20, 'OFF_BY_DEFAULT' },
    { 0x40, 'FLICKER_SLOW' },
    { 0x80, 'PULSE' },
    { 0x100, 'PULSE_SLOW' }
  ),
  MiscItemFlags = flags { 0x1, 'KEY' },
  AlchemyFlags = flags { 0x1, 'AUTO_CALCULATE' },
  EnchantingFlags = flags { 0x1, 'AUTO_CALCULATE' },
  SpellFlags = flags(
    { 0x1, 'AUTO_CALCULATE' },
    { 0x2, 'PC_START_SPELL' },
    { 0x4, 'ALWAYS_SUCCEEDS' }
  ),
  WeaponFlags = flags({ 0x1, 'IGNORES_NORMAL_WEAPON_RESISTANCE' }, { 0x2, 'SILVER' }),
  ClassFlags = flags { 0x1, 'PLAYABLE' },
  FactionFlags = flags { 0x1, 'HIDDEN_FROM_PC' },
  RaceFlags = flags({ 0x1, 'PLAYABLE' }, { 0x2, 'BEAST_RACE' }),
  MagicEffectFlags = flags(
    { 0x1, 'TARGET_SKILL' },
    { 0x2, 'TARGET_ATTRIBUTE' },
    { 0x4, 'NO_DURATION' },
    { 0x8, 'NO_MAGNITUDE' },
    { 0x10, 'HARMFUL' },
    { 0x20, 'CONTINUOUS_VFX' },
    { 0x40, 'CAN_CAST_SELF' },
    { 0x80, 'CAN_CAST_TOUCH' },
    { 0x100, 'CAN_CAST_TARGET' },
    { 0x200, 'ALLOW_SPELLMAKING' },
    { 0x400, 'ALLOW_ENCHANTING' },
    { 0x800, 'NEGATIVE_LIGHTING' },
    { 0x1000, 'APPLIED_ONCE' },
    { 0x2000, 'UNKNOWN_CHAMELEON' },
    { 0x4000, 'NON_RECASTABLE' },
    { 0x8000, 'ILLEGAL_DAEDRA' },
    { 0x10000, 'UNREFLECTABLE' },
    { 0x20000, 'CASTER_LINKED' }
  ),
  ContainerFlags = flags({ 0x1, 'ORGANIC' }, { 0x2, 'RESPAWNS' }, { 0x8, 'IS_BASE' }),
  CreatureFlags = flags(
    { 0x1, 'BIPED' },
    { 0x2, 'RESPAWN' },
    { 0x4, 'WEAPON_AND_SHIELD' },
    { 0x8, 'IS_BASE' },
    { 0x10, 'SWIMS' },
    { 0x20, 'FLIES' },
    { 0x40, 'WALKS' },
    { 0x80, 'ESSENTIAL' }
  ),
  NpcFlags = flags(
    { 0x1, 'FEMALE' },
    { 0x2, 'ESSENTIAL' },
    { 0x4, 'RESPAWN' },
    { 0x8, 'IS_BASE' },
    { 0x10, 'AUTO_CALCULATE' }
  ),
  ServiceFlags = flags(
    { 0x1, 'BARTERS_WEAPONS' },
    { 0x2, 'BARTERS_ARMOR' },
    { 0x4, 'BARTERS_CLOTHING' },
    { 0x8, 'BARTERS_BOOKS' },
    { 0x10, 'BARTERS_INGREDIENTS' },
    { 0x20, 'BARTERS_LOCKPICKS' },
    { 0x40, 'BARTERS_PROBES' },
    { 0x80, 'BARTERS_LIGHTS' },
    { 0x100, 'BARTERS_APPARATUS' },
    { 0x200, 'BARTERS_REPAIR_ITEMS' },
    { 0x400, 'BARTERS_MISC_ITEMS' },
    { 0x800, 'OFFERS_SPELLS' },
    { 0x1000, 'BARTERS_ENCHANTED_ITEMS' },
    { 0x2000, 'BARTERS_ALCHEMY' },
    { 0x4000, 'OFFERS_TRAINING' },
    { 0x8000, 'OFFERS_SPELLMAKING' },
    { 0x10000, 'OFFERS_ENCHANTING' },
    { 0x20000, 'OFFERS_REPAIRS' }
  ),
  LeveledItemFlags = flags(
    { 0x1, 'CALCULATE_FOR_EACH_ITEM' },
    { 0x2, 'CALCULATE_FROM_ALL_LEVELS' }
  ),
  LeveledCreatureFlags = flags { 0x1, 'CALCULATE_FROM_ALL_LEVELS' },
  BodypartFlags = flags({ 0x1, 'FEMALE' }, { 0x2, 'NOT_PLAYABLE' }),
  OMWScriptAttachFlag = flags(
    { 0x01, 'GLOBAL' },
    { 0x02, 'CUSTOM' },
    { 0x04, 'PLAYER' },
    { 0x08, 'MERGE' },
    { 0x10, 'MENU' }
  ),
}

--- Caches each flags value's text, per flags type: a plugin repeats a few values many times.
local FlagTexts: { [Flags]: { [number]: string } } = {}

--- `bits` as bitflags writes them: `A | B | 0x1c0`.
local function flagText(set: Flags, bits: number): string
  local cache = FlagTexts[set]
  if not cache then
    cache = {}
    FlagTexts[set] = cache
  end

  local cached = cache[bits]
  if cached then return cached end

  local parts = {}
  local remaining = bits
  for _, entry in set do
    local bit = entry[1] :: number
    if bit32.btest(remaining, bit) then
      table.insert(parts, entry[2] :: string)
      remaining = bit32.band(remaining, bit32.bnot(bit))
    end
  end

  if remaining ~= 0 then table.insert(parts, string.format('0x%x', remaining)) end

  local text = table.concat(parts, ' | ')
  cache[bits] = text
  return text
end

local FlagValues: { [Flags]: { [string]: number } } = {}

--- The bits a flags text names; names are case-sensitive, `0x` hex is kept as is.
local function flagBits(set: Flags, text: unknown, field: string): number
  if type(text) == 'number' then return text end

  if type(text) ~= 'string' then error(`{field}: expected a flags string, got {type(text)}`, 0) end

  local names = FlagValues[set]
  if not names then
    names = {}
    for _, entry in set do
      names[entry[2] :: string] = entry[1] :: number
    end

    FlagValues[set] = names
  end

  local bits = 0
  if string.match(text, '^%s*$') then return 0 end

  for part in string.gmatch(text .. '|', '([^|]*)|') do
    local flag = string.match(part, '^%s*(.-)%s*$') :: string
    if flag == '' then error(`{field}: encountered empty flag`, 0) end

    local hex = string.match(flag, '^0x(%x+)$')
    local value = if hex then tonumber(hex, 16) else names[flag]
    if not value then error(`{field}: unrecognized named flag \`{flag}\``, 0) end

    bits = bit32.bor(bits, value)
  end

  return bits
end

--[[ Base64 ]]

--- Standard padded base64 of `prefix` (a u32 length, when given) followed by `length` bytes of
--- `source` at `offset`: how jess-omwaddon spells a byte blob, which it writes with its length.
local function base64(source: buffer, offset: number, length: number, prefix: number?): string
  if not prefix then return bytes.toBase64(source, offset, length) end

  local input = buffer.create(length + 4)
  buffer.writeu32(input, 0, prefix)
  buffer.copy(input, 4, source, offset, length)
  return bytes.toBase64(input)
end

--- The bytes standard base64 `text` holds; an error naming `field` for anything else.
local function unbase64(text: string, field: string): buffer
  -- bytes.fromBase64 throws on text that isn't base64.
  local ok, decoded = pcall(bytes.fromBase64, text)
  if ok then return decoded :: buffer end

  return error(`{field}: {decoded}`, 0)
end

return table.freeze {
  Enums = Enums,
  Flags = Flags,
  base64 = base64,
  flagBits = flagBits,
  flagText = flagText,
  nameOf = nameOf,
  unbase64 = unbase64,
  valueOf = valueOf,
}
