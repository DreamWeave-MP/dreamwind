--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Typed record decoding: a record's bytes into the table jess-omwaddon's serde shape gives, field
names camelCase. It reads the record as the Rust loader does, one stream from the flags to the
end: a subrecord's size is read where the loader reads it (a string's length, a `stream.expect`),
so a malformed record fails, or reads, exactly where the loader's does. Each record type is a
table from subrecord tag to a handler that reads that subrecord into the value and returns where
the stream is after it.
]]

local Schema = require './schema'
local Tags = require './tags'
local Text = require './text'

local Enums = Schema.Enums
local Flags = Schema.Flags
local nameOf = Schema.nameOf
local flagText = Schema.flagText
local base64 = Schema.base64

export type Value = { [string]: unknown }

type Handler = (b: buffer, p: number, e: number, r: Value, enc: string) -> number

export type Spec = {
  tag: string,
  name: string,
  init: () -> Value,
  handlers: { [number]: Handler },
  --- Turns what the handlers gathered into the value's final shape.
  finish: ((r: Value, start: number) -> ())?,
  --- Decodes the whole record instead of the handler loop.
  custom: ((b: buffer, s: number, e: number, enc: string) -> Value)?,
}

local function fail(message: string): never error(message, 0) end

local function eof(): never error('failed to fill whole buffer', 0) end

local function need(p: number, n: number, e: number)
  if p + n > e then eof() end
end

local function u32(b: buffer, p: number, e: number): number
  need(p, 4, e)
  return buffer.readu32(b, p)
end

--- `stream.expect(value)` for a u32: an error unless the next four bytes are `value`.
local function expect(b: buffer, p: number, e: number, value: number): number
  if u32(b, p, e) ~= value then fail 'Unexpected Value' end

  return p + 4
end

--- A length-prefixed string, cut at its first NUL (`String::load`).
local function str(b: buffer, p: number, e: number, enc: string): (string, number)
  local length = u32(b, p, e)
  p += 4
  if length == 0 then return '', p end

  if p + length > e then fail(`length {length} exceeds the {e - p} bytes remaining`) end

  return Text.decode(b, p, length, enc), p + length
end

--- A length-prefixed string keeping every byte (`load_exact_string`).
local function exact(b: buffer, p: number, e: number, enc: string): (string, number)
  local length = u32(b, p, e)
  p += 4
  if p + length > e then fail(`length {length} exceeds the {e - p} bytes remaining`) end

  return Text.decodeExact(b, p, length, enc), p + length
end

--- `n` bytes of text cut at the first NUL (`FixedString<N>`, `load_string(n)`).
local function fixed(b: buffer, p: number, e: number, n: number, enc: string): string
  if n == 0 then return '' end

  if p + n > e then fail(`length {n} exceeds the {e - p} bytes remaining`) end

  return Text.decode(b, p, n, enc)
end

local function skip(p: number, n: number, e: number): number
  if p + n > e then fail 'Skip out of bounds' end

  return p + n
end

local function enum32(e: Schema.Enum, b: buffer, p: number): string
  return nameOf(e, buffer.readi32(b, p))
end

local function list(...: unknown): { unknown } return { ... } end

local function f32List(b: buffer, p: number, n: number): { number }
  local out = table.create(n, 0)
  for i = 1, n do
    out[i] = buffer.readf32(b, p + (i - 1) * 4)
  end

  return out
end

local function u8List(b: buffer, p: number, n: number): { number }
  local out = table.create(n, 0)
  for i = 1, n do
    out[i] = buffer.readu8(b, p + i - 1)
  end

  return out
end

local function i32List(b: buffer, p: number, n: number): { number }
  local out = table.create(n, 0)
  for i = 1, n do
    out[i] = buffer.readi32(b, p + (i - 1) * 4)
  end

  return out
end

--[[ Handlers ]]

--- A string subrecord into `field`.
local function S(field: string): Handler
  return function(b, p, e, r, enc)
    local value, next = str(b, p, e, enc)
    r[field] = value
    return next
  end
end

--- An exact string subrecord into `field`.
local function X(field: string): Handler
  return function(b, p, e, r, enc)
    local value, next = exact(b, p, e, enc)
    r[field] = value
    return next
  end
end

--- A string subrecord appended to the list in `field`.
local function SP(field: string): Handler
  return function(b, p, e, r, enc)
    local value, next = str(b, p, e, enc)
    table.insert(r[field] :: { unknown }, value)
    return next
  end
end

--- A fixed-size subrecord of `size` bytes, read by `read`, into `field`.
local function T(size: number, field: string, read: (b: buffer, p: number) -> unknown): Handler
  return function(b, p, e, r)
    p = expect(b, p, e, size)
    need(p, size, e)
    r[field] = read(b, p)
    return p + size
  end
end

--- Like `T`, appending to the list in `field`.
local function TP(size: number, field: string, read: (b: buffer, p: number) -> unknown): Handler
  return function(b, p, e, r)
    p = expect(b, p, e, size)
    need(p, size, e)
    table.insert(r[field] :: { unknown }, read(b, p))
    return p + size
  end
end

--- Like `TP`, for a struct with text in it.
local function TPS(
  size: number,
  field: string,
  read: (b: buffer, p: number, enc: string) -> unknown
): Handler
  return function(b, p, e, r, enc)
    p = expect(b, p, e, size)
    need(p, size, e)
    table.insert(r[field] :: { unknown }, read(b, p, enc))
    return p + size
  end
end

--- DELE: skips its payload and sets the DELETED flag.
local function DELE(b: buffer, p: number, e: number, r: Value, _enc: string): number
  local size = u32(b, p, e)
  r.flags = bit32.bor(r.flags :: number, 0x20)
  return skip(p + 4, size, e)
end

local function readU32(b: buffer, p: number): number return buffer.readu32(b, p) end

local function readF32(b: buffer, p: number): number return buffer.readf32(b, p) end

--[[ Structs ]]

local function classData(b: buffer, p: number): Value
  local Skill = Enums.SkillId
  return {
    attribute1 = enum32(Enums.AttributeId, b, p),
    attribute2 = enum32(Enums.AttributeId, b, p + 4),
    specialization = enum32(Enums.Specialization, b, p + 8),
    minor1 = enum32(Skill, b, p + 12),
    major1 = enum32(Skill, b, p + 16),
    minor2 = enum32(Skill, b, p + 20),
    major2 = enum32(Skill, b, p + 24),
    minor3 = enum32(Skill, b, p + 28),
    major3 = enum32(Skill, b, p + 32),
    minor4 = enum32(Skill, b, p + 36),
    major4 = enum32(Skill, b, p + 40),
    minor5 = enum32(Skill, b, p + 44),
    major5 = enum32(Skill, b, p + 48),
    flags = flagText(Flags.ClassFlags, buffer.readu32(b, p + 52)),
    services = flagText(Flags.ServiceFlags, buffer.readu32(b, p + 56)),
  }
end

local function factionData(b: buffer, p: number): Value
  local requirements = table.create(10)
  for i = 0, 9 do
    local q = p + 8 + i * 20
    requirements[i + 1] = {
      attributes = list(buffer.readi32(b, q), buffer.readi32(b, q + 4)),
      primarySkill = buffer.readi32(b, q + 8),
      favoredSkill = buffer.readi32(b, q + 12),
      reputation = buffer.readi32(b, q + 16),
    }
  end

  local skills = table.create(7)
  for i = 0, 6 do
    skills[i + 1] = enum32(Enums.SkillId, b, p + 208 + i * 4)
  end

  return {
    favoredAttributes = list(enum32(Enums.AttributeId, b, p), enum32(Enums.AttributeId, b, p + 4)),
    requirements = requirements,
    favoredSkills = skills,
    flags = flagText(Flags.FactionFlags, buffer.readu32(b, p + 236)),
  }
end

local function raceData(b: buffer, p: number): Value
  local bonuses: Value = {}
  for i = 0, 6 do
    bonuses[`skill_{i}`] = enum32(Enums.SkillId, b, p + i * 8)
    bonuses[`bonus_{i}`] = buffer.readi32(b, p + i * 8 + 4)
  end

  local function pair(at: number): { number }
    return { buffer.readi32(b, p + at), buffer.readi32(b, p + at + 4) }
  end

  return {
    skillBonuses = bonuses,
    strength = pair(56),
    intelligence = pair(64),
    willpower = pair(72),
    agility = pair(80),
    speed = pair(88),
    endurance = pair(96),
    personality = pair(104),
    luck = pair(112),
    height = f32List(b, p + 120, 2),
    weight = f32List(b, p + 128, 2),
    flags = flagText(Flags.RaceFlags, buffer.readu32(b, p + 136)),
  }
end

local function effect(b: buffer, p: number): Value
  return {
    magicEffect = nameOf(Enums.EffectId, buffer.readi16(b, p)),
    skill = nameOf(Enums.SkillId, buffer.readi8(b, p + 2)),
    attribute = nameOf(Enums.AttributeId, buffer.readi8(b, p + 3)),
    range = nameOf(Enums.EffectRange, buffer.readu32(b, p + 4)),
    area = buffer.readu32(b, p + 8),
    duration = buffer.readu32(b, p + 12),
    minMagnitude = buffer.readu32(b, p + 16),
    maxMagnitude = buffer.readu32(b, p + 20),
  }
end

local function inventoryItem(b: buffer, p: number, enc: string): { unknown }
  return { buffer.readi32(b, p), fixed(b, p + 4, p + 36, 32, enc) }
end

local function aiData(b: buffer, p: number): Value
  return {
    hello = buffer.readi16(b, p),
    fight = buffer.readi8(b, p + 2),
    flee = buffer.readi8(b, p + 3),
    alarm = buffer.readi8(b, p + 4),
    services = flagText(Flags.ServiceFlags, buffer.readu32(b, p + 8)),
  }
end

--- An optional subrecord a struct may be followed by, as `stream.expect(tag).and_then(load)`
--- with its error swallowed: the string, and where the stream is afterwards. A failed read still
--- moves the stream where the Rust cursor would be left.
local function trailingString(
  b: buffer,
  p: number,
  e: number,
  tag: number,
  enc: string
): (string, number)
  if e - p < 4 then return '', e end

  if buffer.readu32(b, p) ~= tag then return '', p end

  p += 4
  if e - p < 4 then return '', e end

  local length = buffer.readu32(b, p)
  p += 4
  if length == 0 then return '', p end

  if p + length > e then return '', p end

  return Text.decode(b, p, length, enc), p + length
end

local CNDT = Tags.code 'CNDT'
local DNAM = Tags.code 'DNAM'

--- A travel destination: DODT's 24 bytes, then an optional DNAM.
local function destination(b: buffer, p: number, e: number, enc: string): (Value, number)
  local cell, next = trailingString(b, p + 24, e, DNAM, enc)
  return { translation = f32List(b, p, 3), rotation = f32List(b, p + 12, 3), cell = cell }, next
end

--- AI_E and AI_F: 48 bytes, then an optional CNDT.
local function escort(kind: string, b: buffer, p: number, e: number, enc: string): (Value, number)
  local cell, next = trailingString(b, p + 48, e, CNDT, enc)
  return {
    type = kind,
    location = f32List(b, p, 3),
    duration = buffer.readu16(b, p + 12),
    target = fixed(b, p + 14, e, 32, enc),
    reset = buffer.readu8(b, p + 46),
    cell = cell,
  },
    next
end

--- The handlers NPC_ and CREA share: inventory, spells, AI, travel.
local function actorHandlers(handlers: { [string]: Handler }): { [string]: Handler }
  handlers.NPCO = TPS(36, 'inventory', inventoryItem)
  handlers.NPCS = SP 'spells'
  handlers.AIDT = T(12, 'aiData', aiData)
  handlers.DODT = function(b, p, e, r, enc)
    p = expect(b, p, e, 24)
    need(p, 24, e)
    local value, next = destination(b, p, e, enc)
    table.insert(r.travelDestinations :: { unknown }, value)
    return next
  end
  handlers.AI_T = TP(
    16,
    'aiPackages',
    function(b, p)
      return { type = 'Travel', location = f32List(b, p, 3), reset = buffer.readu8(b, p + 12) }
    end
  )
  handlers.AI_W = TP(
    14,
    'aiPackages',
    function(b, p)
      return {
        type = 'Wander',
        distance = buffer.readu16(b, p),
        duration = buffer.readu16(b, p + 2),
        gameHour = buffer.readu8(b, p + 4),
        idle2 = buffer.readu8(b, p + 5),
        idle3 = buffer.readu8(b, p + 6),
        idle4 = buffer.readu8(b, p + 7),
        idle5 = buffer.readu8(b, p + 8),
        idle6 = buffer.readu8(b, p + 9),
        idle7 = buffer.readu8(b, p + 10),
        idle8 = buffer.readu8(b, p + 11),
        idle9 = buffer.readu8(b, p + 12),
        reset = buffer.readi8(b, p + 13),
      }
    end
  )
  for _, pair in { { 'AI_E', 'Escort' }, { 'AI_F', 'Follow' } } do
    local kind = pair[2]
    handlers[pair[1]] = function(b, p, e, r, enc)
      p = expect(b, p, e, 48)
      need(p, 48, e)
      local value, next = escort(kind, b, p, e, enc)
      table.insert(r.aiPackages :: { unknown }, value)
      return next
    end
  end

  handlers.AI_A = TPS(
    33,
    'aiPackages',
    function(b, p, enc)
      return {
        type = 'Activate',
        target = fixed(b, p, p + 32, 32, enc),
        reset = buffer.readu8(b, p + 32),
      }
    end
  )
  return handlers
end

--- The flags an NPC_ or CREA FLAG holds, without the blood type in bits 10 to 12.
local function actorFlags(field: string): Handler
  return function(b, p, e, value)
    p = expect(b, p, e, 4)
    need(p, 4, e)
    local bits = buffer.readu32(b, p)
    value[field] = bit32.band(bits, bit32.bnot(0x1c00))
    value.bloodType = bit32.extract(bits, 10, 3)
    return p + 4
  end
end

--[[ Defaults ]]

local function f32(value: number): number
  local scratch = buffer.create(4)
  buffer.writef32(scratch, 0, value)
  return buffer.readf32(scratch, 0)
end

local Zeros = buffer.create(12675)
local ZeroBlob = base64(Zeros, 0, 12675)

local function emptyEffect(): Value
  return {
    magicEffect = 'None',
    skill = 'None',
    attribute = 'None',
    range = 'OnSelf',
    area = 0,
    duration = 0,
    minMagnitude = 0,
    maxMagnitude = 0,
  }
end

local function emptyAiData(): Value
  return { hello = 0, fight = 0, flee = 0, alarm = 0, services = '' }
end

--[[ Record types ]]

local Specs: { Spec } = {}

local function spec(
  tag: string,
  name: string,
  init: () -> Value,
  handlers: { [string]: Handler },
  finish: ((r: Value, start: number) -> ())?
)
  local byCode: { [number]: Handler } = {}
  for sub, handler in handlers do
    byCode[Tags.code(sub)] = handler
  end

  table.insert(Specs, { tag = tag, name = name, init = init, handlers = byCode, finish = finish })
end

--- The fields every item-like record has.
local function base(extra: Value?): () -> Value
  -- Plain defaults are cloned from one template; a nested table is made fresh by its factory.
  local template: Value = { flags = 0, id = '' }
  local keys: { string } = {}
  local factories: { () -> unknown } = {}
  for key, default in extra or {} do
    if type(default) == 'function' then
      table.insert(keys, key)
      table.insert(factories, default :: () -> unknown)
    else
      template[key] = default
    end
  end

  return function()
    local value = table.clone(template)
    for i, key in keys do
      value[key] = factories[i]()
    end

    return value
  end
end

local function finishFlags(r: Value) r.flags = flagText(Flags.ObjectFlags, r.flags :: number) end

spec(
  'TES3',
  'Header',
  function()
    return {
      flags = 0,
      version = f32(1.3),
      fileType = 'Esp',
      author = '',
      description = '',
      numObjects = 0,
      masters = {},
    }
  end,

  {
    HEDR = function(b, p, e, r, enc)
      p = expect(b, p, e, 300)
      need(p, 300, e)
      r.version = buffer.readf32(b, p)
      r.fileType = nameOf(Enums.FileType, buffer.readu32(b, p + 4))
      r.author = fixed(b, p + 8, e, 32, enc)
      r.description = fixed(b, p + 40, e, 256, enc)
      r.numObjects = buffer.readu32(b, p + 296)
      return p + 300
    end,

    MAST = function(b, p, e, r, enc)
      local name
      name, p = str(b, p, e, enc)
      p = expect(b, p, e, Tags.code 'DATA')
      p = expect(b, p, e, 8)
      need(p, 8, e)
      local size = buffer.readu32(b, p) + buffer.readu32(b, p + 4) * 4294967296
      table.insert(r.masters :: { unknown }, { name, size })
      return p + 8
    end,
  },
  finishFlags
)

spec(
  'GMST',
  'GameSetting',
  base {
    value = function() return { type = 'Float', data = 0 } end,
  },

  {
    NAME = S 'id',
    STRV = function(b, p, e, r, enc)
      local value, next = exact(b, p, e, enc)
      r.value = { type = 'String', data = value }
      return next
    end,

    FLTV = function(b, p, e, r)
      p = expect(b, p, e, 4)
      need(p, 4, e)
      r.value = { type = 'Float', data = buffer.readf32(b, p) }
      return p + 4
    end,

    INTV = function(b, p, e, r)
      p = expect(b, p, e, 4)
      need(p, 4, e)
      r.value = { type = 'Integer', data = buffer.readi32(b, p) }
      return p + 4
    end,
  },
  finishFlags
)

--- `v as i32` and `v as i16` in Rust: toward zero, saturating, NaN as 0.
local function saturate(v: number, low: number, high: number): number
  if v ~= v then return 0 end

  local truncated = if v >= 0 then math.floor(v) else math.ceil(v)
  return math.clamp(truncated, low, high)
end

spec(
  'GLOB',
  'GlobalVariable',
  base {
    value = function() return { type = 'Float', data = 0 } end,
  },

  {
    NAME = S 'id',
    FNAM = function(b, p, e, r)
      p = expect(b, p, e, 1)
      need(p, 1, e)
      local kind = nameOf(Enums.GlobalType, buffer.readu8(b, p))
      p = expect(b, p + 1, e, Tags.code 'FLTV')
      p = expect(b, p, e, 4)
      need(p, 4, e)
      local value = buffer.readf32(b, p)
      -- NaNs are converted to zero by the engine ("ratskilled" in Morrowind.esm).
      if value ~= value then value = 0 end

      if kind == 'Long' then
        r.value = { type = 'Long', data = saturate(value, -2147483648, 2147483647) }
      elseif kind == 'Short' then
        r.value = { type = 'Short', data = saturate(value, -32768, 32767) }
      else
        r.value = { type = 'Float', data = value }
      end

      return p + 4
    end,
    DELE = DELE,
  },
  finishFlags
)

spec(
  'CLAS',
  'Class',
  base {
    name = '',
    description = '',
    data = function()
      local none = buffer.create(60)
      for at = 0, 48, 4 do
        buffer.writei32(none, at, -1)
      end

      return classData(none, 0)
    end,
  },

  {
    NAME = S 'id',
    FNAM = S 'name',
    CLDT = T(60, 'data', classData),
    DESC = X 'description',
    DELE = DELE,
  },
  finishFlags
)

-- An empty FactionData: zeros, whose enums read as their defaults... except that zero is a valid
-- attribute (Strength) and skill (Block); the Rust default is None for both, so build it by hand.
local function emptyFactionData(): Value
  local requirements = table.create(10)
  for i = 1, 10 do
    requirements[i] = { attributes = { 0, 0 }, primarySkill = 0, favoredSkill = 0, reputation = 0 }
  end

  return {
    favoredAttributes = { 'None', 'None' },
    requirements = requirements,
    favoredSkills = { 'None', 'None', 'None', 'None', 'None', 'None', 'None' },
    flags = '',
  }
end

spec(
  'FACT',
  'Faction',
  base {
    name = '',
    rankNames = function() return {} end,
    reactions = function() return {} end,
    data = emptyFactionData,
  },

  {
    NAME = S 'id',
    FNAM = S 'name',
    RNAM = SP 'rankNames',
    FADT = T(240, 'data', factionData),
    ANAM = function(b, p, e, r, enc)
      local faction
      faction, p = str(b, p, e, enc)
      p = expect(b, p, e, Tags.code 'INTV')
      p = expect(b, p, e, 4)
      need(p, 4, e)
      table.insert(
        r.reactions :: { unknown },
        { faction = faction, reaction = buffer.readi32(b, p) }
      )
      return p + 4
    end,
    DELE = DELE,
  },
  finishFlags
)

local function emptyRaceData(): Value
  local bonuses: Value = {}
  for i = 0, 6 do
    bonuses[`skill_{i}`] = 'None'
    bonuses[`bonus_{i}`] = 0
  end

  return {
    skillBonuses = bonuses,
    strength = { 0, 0 },
    intelligence = { 0, 0 },
    willpower = { 0, 0 },
    agility = { 0, 0 },
    speed = { 0, 0 },
    endurance = { 0, 0 },
    personality = { 0, 0 },
    luck = { 0, 0 },
    height = { 0, 0 },
    weight = { 0, 0 },
    flags = '',
  }
end

spec(
  'RACE',
  'Race',
  base {
    name = '',
    spells = function() return {} end,
    description = '',
    data = emptyRaceData,
  },

  {
    NAME = S 'id',
    FNAM = S 'name',
    RADT = T(140, 'data', raceData),
    NPCS = SP 'spells',
    DESC = X 'description',
    DELE = DELE,
  },
  finishFlags
)

spec(
  'SOUN',
  'Sound',
  base {
    soundPath = '',
    data = function() return { volume = 0, range = { 0, 0 } } end,
  },

  {
    NAME = S 'id',
    FNAM = S 'soundPath',
    DATA = T(
      3,
      'data',
      function(b, p)
        return {
          volume = buffer.readu8(b, p),
          range = { buffer.readu8(b, p + 1), buffer.readu8(b, p + 2) },
        }
      end
    ),
    DELE = DELE,
  },
  finishFlags
)

spec('SNDG', 'SoundGen', base { soundGenType = 'LeftFoot', creature = '', sound = '' }, {
  NAME = S 'id',
  DATA = T(
    4,
    'soundGenType',
    function(b, p) return nameOf(Enums.SoundGenType, buffer.readu32(b, p)) end
  ),
  CNAM = S 'creature',
  SNAM = S 'sound',
  DELE = DELE,
}, finishFlags)

spec(
  'SKIL',
  'Skill',
  function()
    return {
      flags = 0,
      skillId = 'None',
      data = { governingAttribute = 0, specialization = 0, actions = { 0, 0, 0, 0 } },
      description = '',
    }
  end,

  {
    INDX = T(4, 'skillId', function(b, p) return enum32(Enums.SkillId, b, p) end),
    SKDT = T(
      24,
      'data',
      function(b, p)
        return {
          governingAttribute = buffer.readi32(b, p),
          specialization = buffer.readi32(b, p + 4),
          actions = f32List(b, p + 8, 4),
        }
      end
    ),
    DESC = X 'description',
    DELE = DELE,
  },
  finishFlags
)

local MagicEffectStrings: { [string]: string } = {
  ITEX = 'icon',
  PTEX = 'texture',
  BSND = 'boltSound',
  CSND = 'castSound',
  HSND = 'hitSound',
  ASND = 'areaSound',
  CVFX = 'castVisual',
  BVFX = 'boltVisual',
  HVFX = 'hitVisual',
  AVFX = 'areaVisual',
}

do
  local handlers: { [string]: Handler } = {
    INDX = T(4, 'effectId', function(b, p) return enum32(Enums.EffectId, b, p) end),
    MEDT = T(
      36,
      'data',
      function(b, p)
        return {
          school = nameOf(Enums.EffectSchool, buffer.readu32(b, p)),
          baseCost = buffer.readf32(b, p + 4),
          flags = flagText(Flags.MagicEffectFlags, buffer.readu32(b, p + 8)),
          color = i32List(b, p + 12, 3),
          speed = buffer.readf32(b, p + 24),
          size = buffer.readf32(b, p + 28),
          sizeCap = buffer.readf32(b, p + 32),
        }
      end
    ),
    DESC = X 'description',
    DELE = DELE,
  }

  local defaults: Value = {
    flags = 0,
    effectId = 'None',
    description = '',
    data = function()
      return {
        school = 'Alteration',
        baseCost = 0,
        flags = '',
        color = { 0, 0, 0 },
        speed = 0,
        size = 0,
        sizeCap = 0,
      }
    end,
  }

  for sub, field in MagicEffectStrings do
    handlers[sub] = S(field)
    defaults[field] = ''
  end

  spec('MGEF', 'MagicEffect', function()
    local value: Value = {}
    for key, default in defaults do
      value[key] = if type(default) == 'function' then (default :: () -> unknown)() else default
    end

    return value
  end, handlers, finishFlags)
end

spec(
  'SCPT',
  'Script',
  function()
    return {
      flags = 0,
      id = '',
      header = {
        numShorts = 0,
        numLongs = 0,
        numFloats = 0,
        bytecodeLength = 0,
        variablesLength = 0,
      },
      variables = 'AAAAAA==',
      bytecode = 'AAAAAA==',
      text = '',
    }
  end,

  {
    SCHD = function(b, p, e, r, enc)
      p = expect(b, p, e, 52)
      need(p, 52, e)
      r.id = fixed(b, p, e, 32, enc)
      r.header = {
        numShorts = buffer.readu32(b, p + 32),
        numLongs = buffer.readu32(b, p + 36),
        numFloats = buffer.readu32(b, p + 40),
        bytecodeLength = buffer.readu32(b, p + 44),
        variablesLength = buffer.readu32(b, p + 48),
      }
      return p + 52
    end,

    SCVR = function(b, p, e, r)
      local length = u32(b, p, e)
      need(p + 4, length, e)
      r.variables = base64(b, p, length + 4)
      return p + 4 + length
    end,

    SCDT = function(b, p, e, r)
      local length = u32(b, p, e)
      need(p + 4, length, e)
      r.bytecode = base64(b, p, length + 4)
      return p + 4 + length
    end,
    SCTX = X 'text',
    DELE = DELE,
  },
  finishFlags
)

spec(
  'REGN',
  'Region',
  function()
    return {
      flags = 0,
      id = '',
      name = '',
      weatherChances = {
        clear = 0,
        cloudy = 0,
        foggy = 0,
        overcast = 0,
        rain = 0,
        thunder = 0,
        ash = 0,
        blight = 0,
        snow = 0,
        blizzard = 0,
      },
      sleepCreature = '',
      mapColor = { 0, 0, 0, 0 },
      sounds = {},
    }
  end,

  {
    NAME = S 'id',
    FNAM = S 'name',
    WEAT = function(b, p, e, r)
      local length = u32(b, p, e)
      if length ~= 8 and length ~= 10 then fail(`Unexpected size ({length}) for REGN::WEAT`) end

      p += 4
      need(p, length, e)
      r.weatherChances = {
        clear = buffer.readu8(b, p),
        cloudy = buffer.readu8(b, p + 1),
        foggy = buffer.readu8(b, p + 2),
        overcast = buffer.readu8(b, p + 3),
        rain = buffer.readu8(b, p + 4),
        thunder = buffer.readu8(b, p + 5),
        ash = buffer.readu8(b, p + 6),
        blight = buffer.readu8(b, p + 7),
        snow = if length == 10 then buffer.readu8(b, p + 8) else 0,
        blizzard = if length == 10 then buffer.readu8(b, p + 9) else 0,
      }
      return p + length
    end,
    BNAM = S 'sleepCreature',
    CNAM = T(4, 'mapColor', function(b, p) return u8List(b, p, 4) end),
    SNAM = TPS(
      33,
      'sounds',
      function(b, p, enc) return { fixed(b, p, p + 32, 32, enc), buffer.readu8(b, p + 32) } end
    ),
    DELE = DELE,
  },
  finishFlags
)

spec(
  'BSGN',
  'Birthsign',
  base {
    name = '',
    texture = '',
    description = '',
    spells = function() return {} end,
  },

  {
    NAME = S 'id',
    FNAM = S 'name',
    TNAM = S 'texture',
    DESC = S 'description',
    NPCS = SP 'spells',
    DELE = DELE,
  },
  finishFlags
)

spec('SSCR', 'StartScript', base { script = '' }, {
  DATA = S 'id',
  NAME = S 'script',
  DELE = DELE,
}, finishFlags)

spec('LTEX', 'LandscapeTexture', base { index = 0, fileName = '' }, {
  NAME = S 'id',
  INTV = T(4, 'index', readU32),
  DATA = S 'fileName',
  DELE = DELE,
}, finishFlags)

spec(
  'SPEL',
  'Spell',
  base {
    name = '',
    effects = function() return {} end,
    data = function() return { spellType = 'Spell', cost = 0, flags = '' } end,
  },

  {
    NAME = S 'id',
    FNAM = S 'name',
    SPDT = T(
      12,
      'data',
      function(b, p)
        return {
          spellType = nameOf(Enums.SpellType, buffer.readu32(b, p)),
          cost = buffer.readu32(b, p + 4),
          flags = flagText(Flags.SpellFlags, buffer.readu32(b, p + 8)),
        }
      end
    ),
    ENAM = TP(24, 'effects', effect),
    DELE = DELE,
  },
  finishFlags
)

spec(
  'STAT',
  'Static',
  base { mesh = '' },
  { NAME = S 'id', MODL = S 'mesh', DELE = DELE },
  finishFlags
)

spec('DOOR', 'Door', base { name = '', script = '', mesh = '', openSound = '', closeSound = '' }, {
  NAME = S 'id',
  MODL = S 'mesh',
  FNAM = S 'name',
  SCRI = S 'script',
  SNAM = S 'openSound',
  ANAM = S 'closeSound',
  DELE = DELE,
}, finishFlags)

--- An item with name, script, mesh, icon, and a data struct of `size` read by `read`.
local function item(
  tag: string,
  name: string,
  dataTag: string,
  size: number,
  read: (b: buffer, p: number) -> Value,
  extra: { [string]: Handler }?,
  defaults: Value?
)
  local fields: Value = {
    name = '',
    script = '',
    mesh = '',
    icon = '',
    data = function() return read(Zeros, 0) end,
  }

  if defaults then
    for key, value in defaults do
      fields[key] = value
    end
  end

  local handlers: { [string]: Handler } = {
    NAME = S 'id',
    MODL = S 'mesh',
    FNAM = S 'name',
    SCRI = S 'script',
    ITEX = S 'icon',
    DELE = DELE,
  }
  handlers[dataTag] = T(size, 'data', read)
  if extra then
    for sub, handler in extra do
      handlers[sub] = handler
    end
  end

  spec(tag, name, base(fields), handlers, finishFlags)
end

item(
  'MISC',
  'MiscItem',
  'MCDT',
  12,
  function(b, p)
    return {
      weight = buffer.readf32(b, p),
      value = buffer.readu32(b, p + 4),
      flags = flagText(Flags.MiscItemFlags, buffer.readu32(b, p + 8)),
    }
  end
)

item(
  'WEAP',
  'Weapon',
  'WPDT',
  32,
  function(b, p)
    return {
      weight = buffer.readf32(b, p),
      value = buffer.readu32(b, p + 4),
      weaponType = nameOf(Enums.WeaponType, buffer.readu16(b, p + 8)),
      health = buffer.readu16(b, p + 10),
      speed = buffer.readf32(b, p + 12),
      reach = buffer.readf32(b, p + 16),
      enchantment = buffer.readu16(b, p + 20),
      chopMin = buffer.readu8(b, p + 22),
      chopMax = buffer.readu8(b, p + 23),
      slashMin = buffer.readu8(b, p + 24),
      slashMax = buffer.readu8(b, p + 25),
      thrustMin = buffer.readu8(b, p + 26),
      thrustMax = buffer.readu8(b, p + 27),
      flags = flagText(Flags.WeaponFlags, buffer.readu32(b, p + 28)),
    }
  end,
  { ENAM = S 'enchanting' },
  { enchanting = '' }
)

local function bipedObject(b: buffer, p: number, e: number, r: Value, enc: string): number
  p = expect(b, p, e, 1)
  need(p, 1, e)
  local object: Value = {
    bipedObjectType = nameOf(Enums.BipedObjectType, buffer.readu8(b, p)),
    maleBodypart = '',
    femaleBodypart = '',
  }
  p += 1
  for _ = 1, 2 do
    if e - p < 4 then
      p = e
      break
    end

    local tag = buffer.readu32(b, p)
    if tag == Tags.code 'BNAM' then
      object.maleBodypart, p = str(b, p + 4, e, enc)
    elseif tag == Tags.code 'CNAM' then
      object.femaleBodypart, p = str(b, p + 4, e, enc)
    end
  end

  table.insert(r.bipedObjects :: { unknown }, object)
  return p
end

item(
  'ARMO',
  'Armor',
  'AODT',
  24,
  function(b, p)
    return {
      armorType = nameOf(Enums.ArmorType, buffer.readu32(b, p)),
      weight = buffer.readf32(b, p + 4),
      value = buffer.readu32(b, p + 8),
      health = buffer.readu32(b, p + 12),
      enchantment = buffer.readu32(b, p + 16),
      armorRating = buffer.readu32(b, p + 20),
    }
  end,
  { ENAM = S 'enchanting', INDX = bipedObject },
  {
    enchanting = '',
    bipedObjects = function() return {} end,
  }
)

item(
  'CLOT',
  'Clothing',
  'CTDT',
  12,
  function(b, p)
    return {
      clothingType = nameOf(Enums.ClothingType, buffer.readu32(b, p)),
      weight = buffer.readf32(b, p + 4),
      value = buffer.readu16(b, p + 8),
      enchantment = buffer.readu16(b, p + 10),
    }
  end,
  { ENAM = S 'enchanting', INDX = bipedObject },
  {
    enchanting = '',
    bipedObjects = function() return {} end,
  }
)

item(
  'REPA',
  'RepairItem',
  'RIDT',
  16,
  function(b, p)
    return {
      weight = buffer.readf32(b, p),
      value = buffer.readu32(b, p + 4),
      uses = buffer.readu32(b, p + 8),
      quality = buffer.readf32(b, p + 12),
    }
  end
)

item(
  'APPA',
  'Apparatus',
  'AADT',
  16,
  function(b, p)
    return {
      apparatusType = nameOf(Enums.ApparatusType, buffer.readu32(b, p)),
      quality = buffer.readf32(b, p + 4),
      weight = buffer.readf32(b, p + 8),
      value = buffer.readu32(b, p + 12),
    }
  end
)

local function toolData(b: buffer, p: number): Value
  return {
    weight = buffer.readf32(b, p),
    value = buffer.readu32(b, p + 4),
    quality = buffer.readf32(b, p + 8),
    uses = buffer.readu32(b, p + 12),
  }
end

item('LOCK', 'Lockpick', 'LKDT', 16, toolData)
item('PROB', 'Probe', 'PBDT', 16, toolData)

local function ingredientData(b: buffer, p: number): Value
  local effects, skills, attributes = table.create(4), table.create(4), table.create(4)
  for i = 0, 3 do
    effects[i + 1] = enum32(Enums.EffectId, b, p + 8 + i * 4)
    skills[i + 1] = enum32(Enums.SkillId, b, p + 24 + i * 4)
    attributes[i + 1] = enum32(Enums.AttributeId, b, p + 40 + i * 4)
  end

  return {
    weight = buffer.readf32(b, p),
    value = buffer.readu32(b, p + 4),
    effects = effects,
    skills = skills,
    attributes = attributes,
  }
end

item('INGR', 'Ingredient', 'IRDT', 56, ingredientData, nil, {
  data = function()
    return {
      weight = 0,
      value = 0,
      effects = { 'None', 'None', 'None', 'None' },
      skills = { 'None', 'None', 'None', 'None' },
      attributes = { 'None', 'None', 'None', 'None' },
    }
  end,
})

item(
  'BOOK',
  'Book',
  'BKDT',
  20,
  function(b, p)
    return {
      weight = buffer.readf32(b, p),
      value = buffer.readu32(b, p + 4),
      bookType = nameOf(Enums.BookType, buffer.readu32(b, p + 8)),
      skill = enum32(Enums.SkillId, b, p + 12),
      enchantment = buffer.readu32(b, p + 16),
    }
  end,
  { ENAM = S 'enchanting', TEXT = X 'text' },
  {
    enchanting = '',
    text = '',
    data = function()
      return { weight = 0, value = 0, bookType = 'Book', skill = 'None', enchantment = 0 }
    end,
  }
)

spec(
  'ALCH',
  'Alchemy',
  base {
    name = '',
    script = '',
    mesh = '',
    icon = '',
    effects = function() return {} end,
    data = function() return { weight = 0, value = 0, flags = '' } end,
  },

  {
    NAME = S 'id',
    MODL = S 'mesh',
    TEXT = S 'icon',
    SCRI = S 'script',
    FNAM = S 'name',
    ALDT = T(
      12,
      'data',
      function(b, p)
        return {
          weight = buffer.readf32(b, p),
          value = buffer.readu32(b, p + 4),
          flags = flagText(Flags.AlchemyFlags, buffer.readu32(b, p + 8)),
        }
      end
    ),
    ENAM = TP(24, 'effects', effect),
    DELE = DELE,
  },
  finishFlags
)

spec(
  'CONT',
  'Container',
  base {
    name = '',
    script = '',
    mesh = '',
    encumbrance = 0,
    containerFlags = 0,
    inventory = function() return {} end,
  },

  {
    NAME = S 'id',
    MODL = S 'mesh',
    FNAM = S 'name',
    CNDT = T(4, 'encumbrance', readF32),
    FLAG = T(4, 'containerFlags', readU32),
    SCRI = S 'script',
    NPCO = TPS(36, 'inventory', inventoryItem),
    DELE = DELE,
  },

  function(r)
    finishFlags(r)
    r.containerFlags = flagText(Flags.ContainerFlags, r.containerFlags :: number)
  end
)

local function creatureData(b: buffer, p: number): Value
  return {
    creatureType = nameOf(Enums.CreatureType, buffer.readu32(b, p)),
    level = buffer.readu32(b, p + 4),
    strength = buffer.readu32(b, p + 8),
    intelligence = buffer.readu32(b, p + 12),
    willpower = buffer.readu32(b, p + 16),
    agility = buffer.readu32(b, p + 20),
    speed = buffer.readu32(b, p + 24),
    endurance = buffer.readu32(b, p + 28),
    personality = buffer.readu32(b, p + 32),
    luck = buffer.readu32(b, p + 36),
    health = buffer.readu32(b, p + 40),
    magicka = buffer.readu32(b, p + 44),
    fatigue = buffer.readu32(b, p + 48),
    soul = buffer.readu32(b, p + 52),
    combat = buffer.readu32(b, p + 56),
    magic = buffer.readu32(b, p + 60),
    stealth = buffer.readu32(b, p + 64),
    attack1 = { buffer.readu32(b, p + 68), buffer.readu32(b, p + 72) },
    attack2 = { buffer.readu32(b, p + 76), buffer.readu32(b, p + 80) },
    attack3 = { buffer.readu32(b, p + 84), buffer.readu32(b, p + 88) },
    gold = buffer.readu32(b, p + 92),
  }
end

local function actorDefaults(extra: Value): () -> Value
  local fields: Value = {
    name = '',
    script = '',
    mesh = '',
    inventory = function() return {} end,
    spells = function() return {} end,
    aiData = emptyAiData,
    aiPackages = function() return {} end,
    travelDestinations = function() return {} end,
    bloodType = 0,
  }

  for key, value in extra do
    fields[key] = value
  end

  return base(fields)
end

do
  local handlers = actorHandlers {
    NAME = S 'id',
    MODL = S 'mesh',
    CNAM = S 'sound',
    FNAM = S 'name',
    SCRI = S 'script',
    NPDT = T(96, 'data', creatureData),
    XSCL = T(4, 'scale', readF32),
    DELE = DELE,
  }
  handlers.FLAG = actorFlags 'creatureFlags'
  spec(
    'CREA',
    'Creature',
    actorDefaults {
      sound = '',
      creatureFlags = 0,
      data = function() return creatureData(Zeros, 0) end,
    },
    handlers,
    function(r)
      finishFlags(r)
      r.creatureFlags = flagText(Flags.CreatureFlags, r.creatureFlags :: number)
    end
  )
end

local function npcData(b: buffer, p: number, e: number, r: Value): number
  local length = u32(b, p, e)
  p += 4
  if length == 52 then
    need(p, 52, e)
    r.data = {
      level = buffer.readi16(b, p),
      stats = {
        attributes = u8List(b, p + 2, 8),
        skills = u8List(b, p + 10, 27),
        health = buffer.readu16(b, p + 38),
        magicka = buffer.readu16(b, p + 40),
        fatigue = buffer.readu16(b, p + 42),
      },
      disposition = buffer.readi8(b, p + 44),
      reputation = buffer.readi8(b, p + 45),
      rank = buffer.readi8(b, p + 46),
      gold = buffer.readu32(b, p + 48),
    }
    return p + 52
  elseif length == 12 then
    need(p, 12, e)
    r.data = {
      level = buffer.readi16(b, p),
      disposition = buffer.readi8(b, p + 2),
      reputation = buffer.readi8(b, p + 3),
      rank = buffer.readi8(b, p + 4),
      gold = buffer.readu32(b, p + 8),
    }
    return p + 12
  end

  return fail(`Unexpected length ({length}) for NPC_::NPDT`)
end

do
  local handlers = actorHandlers {
    NAME = S 'id',
    MODL = S 'mesh',
    FNAM = S 'name',
    RNAM = S 'race',
    CNAM = S 'class',
    ANAM = S 'faction',
    BNAM = S 'head',
    KNAM = S 'hair',
    SCRI = S 'script',
    NPDT = npcData,
    DELE = DELE,
  }
  handlers.FLAG = actorFlags 'npcFlags'
  spec(
    'NPC_',
    'Npc',
    actorDefaults {
      race = '',
      class = '',
      faction = '',
      head = '',
      hair = '',
      npcFlags = 0,
      data = function() return { level = 0, disposition = 0, reputation = 0, rank = 0, gold = 0 } end,
    },
    handlers,
    function(r)
      finishFlags(r)
      r.npcFlags = flagText(Flags.NpcFlags, r.npcFlags :: number)
    end
  )
end

spec(
  'BODY',
  'Bodypart',
  base {
    race = '',
    mesh = '',
    data = function() return { part = 'Head', vampire = false, flags = '', bodypartType = 'Skin' } end,
  },

  {
    NAME = S 'id',
    MODL = S 'mesh',
    FNAM = S 'race',
    BYDT = T(
      4,
      'data',
      function(b, p)
        return {
          part = nameOf(Enums.BodypartId, buffer.readu8(b, p)),
          vampire = buffer.readu8(b, p + 1) ~= 0,
          flags = flagText(Flags.BodypartFlags, buffer.readu8(b, p + 2)),
          bodypartType = nameOf(Enums.BodypartType, buffer.readu8(b, p + 3)),
        }
      end
    ),
    DELE = DELE,
  },
  finishFlags
)

local function lightData(b: buffer, p: number): Value
  return {
    weight = buffer.readf32(b, p),
    value = buffer.readu32(b, p + 4),
    time = buffer.readi32(b, p + 8),
    radius = buffer.readu32(b, p + 12),
    color = u8List(b, p + 16, 4),
    flags = flagText(Flags.LightFlags, buffer.readu32(b, p + 20)),
  }
end

spec(
  'LIGH',
  'Light',
  base {
    name = '',
    script = '',
    mesh = '',
    icon = '',
    sound = '',
    data = function() return lightData(Zeros, 0) end,
  },

  {
    NAME = S 'id',
    MODL = S 'mesh',
    FNAM = S 'name',
    ITEX = S 'icon',
    LHDT = T(24, 'data', lightData),
    SCRI = S 'script',
    SNAM = S 'sound',
    DELE = DELE,
  },
  finishFlags
)

spec(
  'ENCH',
  'Enchanting',
  base {
    effects = function() return {} end,
    data = function() return { enchantType = 'CastOnce', cost = 0, maxCharge = 0, flags = '' } end,
  },

  {
    NAME = S 'id',
    ENDT = T(
      16,
      'data',
      function(b, p)
        return {
          enchantType = nameOf(Enums.EnchantType, buffer.readu32(b, p)),
          cost = buffer.readu32(b, p + 4),
          maxCharge = buffer.readu32(b, p + 8),
          flags = flagText(Flags.EnchantingFlags, buffer.readu32(b, p + 12)),
        }
      end
    ),
    ENAM = TP(24, 'effects', effect),
    DELE = DELE,
  },
  finishFlags
)

spec('ACTI', 'Activator', base { name = '', script = '', mesh = '' }, {
  NAME = S 'id',
  MODL = S 'mesh',
  FNAM = S 'name',
  SCRI = S 'script',
  DELE = DELE,
}, finishFlags)

local function leveled(
  tag: string,
  name: string,
  flagField: string,
  set: Schema.Flags,
  listField: string,
  entryTag: string,
  kind: string
)
  spec(
    tag,
    name,
    base {
      [flagField] = 0,
      chanceNone = 0,
      [listField] = function() return {} end,
    },

    {
      NAME = S 'id',
      DATA = T(4, flagField, readU32),
      NNAM = T(1, 'chanceNone', function(b, p) return buffer.readu8(b, p) end),
      INDX = function(b, p, e)
        p = expect(b, p, e, 4)
        need(p, 4, e)
        return p + 4
      end,

      [entryTag] = function(b, p, e, r, enc)
        local entry = { '', 0 }
        table.insert(r[listField] :: { unknown }, entry)
        entry[1], p = str(b, p, e, enc)
        return p
      end,

      INTV = function(b, p, e, r)
        p = expect(b, p, e, 2)
        need(p, 2, e)
        local entries = r[listField] :: { { unknown } }
        local last = entries[#entries]
        if not last then fail(`PC Level provided without a corresponding {kind} id`) end

        last[2] = buffer.readu16(b, p)
        return p + 2
      end,
      DELE = DELE,
    },

    function(r)
      finishFlags(r)
      r[flagField] = flagText(set, r[flagField] :: number)
    end
  )
end

leveled('LEVI', 'LeveledItem', 'leveledItemFlags', Flags.LeveledItemFlags, 'items', 'INAM', 'item')
leveled(
  'LEVC',
  'LeveledCreature',
  'leveledCreatureFlags',
  Flags.LeveledCreatureFlags,
  'creatures',
  'CNAM',
  'creature'
)

--[[ CELL ]]

local REFR = 'REFR'

--- The subrecord tags the hand-written decoders below test, as numbers.
local CodedTags = {
  'NAME',
  'UNAM',
  'XSCL',
  'ANAM',
  'BNAM',
  'CNAM',
  'INDX',
  'XSOL',
  'XCHG',
  'INTV',
  'NAM9',
  'DODT',
  'FLTV',
  'KNAM',
  'TNAM',
  'DATA',
  'DELE',
  'RGNN',
  'NAM5',
  'WHGT',
  'AMBI',
  'NAM0',
  'MVRF',
  'FRMR',
  'VNML',
  'VHGT',
  'WNAM',
  'VCLR',
  'VTEX',
  'LUAS',
  'LUAF',
  'LUAI',
  'LUAR',
  'LUAD',
}

local C: { [string]: number } = {}
for _, name in CodedTags do
  C[name] = Tags.code(name)
end

--- Zeroes a vector's non-finite components.
local function finite(vector: { number })
  for i = 1, 3 do
    local v = vector[i]
    if v ~= v or v == math.huge or v == -math.huge then vector[i] = 0 end
  end
end

--- One reference's subrecords after its FRMR, up to its DATA or DELE (`Reference::load`).
local function reference(b: buffer, p: number, e: number, enc: string): (Value, number)
  local ref: Value =
    { id = '', temporary = false, translation = { 0, 0, 0 }, rotation = { 0, 0, 0 } }
  while p < e do
    if e - p < 4 then fail(`partial tag at offset {p}`) end

    local tag = buffer.readu32(b, p)
    p += 4
    if tag == C.NAME then
      ref.id, p = str(b, p, e, enc)
    elseif tag == C.UNAM then
      p = expect(b, p, e, 1)
      need(p, 1, e)
      ref.blocked = buffer.readu8(b, p)
      p += 1
    elseif tag == C.XSCL then
      p = expect(b, p, e, 4)
      need(p, 4, e)
      ref.scale = buffer.readf32(b, p)
      p += 4
    elseif tag == C.ANAM then
      ref.owner, p = str(b, p, e, enc)
    elseif tag == C.BNAM then
      ref.ownerGlobal, p = str(b, p, e, enc)
    elseif tag == C.CNAM then
      ref.ownerFaction, p = str(b, p, e, enc)
    elseif tag == C.INDX then
      p = expect(b, p, e, 4)
      need(p, 4, e)
      ref.ownerFactionRank = buffer.readu32(b, p)
      p += 4
    elseif tag == C.XSOL then
      ref.soul, p = str(b, p, e, enc)
    elseif tag == C.XCHG then
      p = expect(b, p, e, 4)
      need(p, 4, e)
      ref.chargeLeft = buffer.readu32(b, p)
      p += 4
    elseif tag == C.INTV then
      p = expect(b, p, e, 4)
      need(p, 4, e)
      ref.healthLeft = buffer.readi32(b, p)
      p += 4
    elseif tag == C.NAM9 then
      p = expect(b, p, e, 4)
      need(p, 4, e)
      ref.objectCount = buffer.readu32(b, p)
      p += 4
    elseif tag == C.DODT then
      p = expect(b, p, e, 24)
      need(p, 24, e)
      ref.destination, p = destination(b, p, e, enc)
    elseif tag == C.FLTV then
      p = expect(b, p, e, 4)
      need(p, 4, e)
      ref.lockLevel = buffer.readi32(b, p)
      p += 4
    elseif tag == C.KNAM then
      ref.key, p = str(b, p, e, enc)
    elseif tag == C.TNAM then
      ref.trap, p = str(b, p, e, enc)
    elseif tag == C.DATA then
      p = expect(b, p, e, 24)
      need(p, 24, e)
      ref.translation = f32List(b, p, 3)
      ref.rotation = f32List(b, p + 12, 3)
      p += 24
      break
    elseif tag == C.DELE then
      local size = u32(b, p, e)
      p = skip(p + 4, size, e)
      ref.deleted = true
      break
    else
      fail(`Unexpected Tag: {REFR}::{Tags.lossy(tag)}`)
    end
  end

  -- `make_transforms_finite`: a non-finite transform reads as 0, a non-finite scale as none.
  finite(ref.translation :: { number })
  finite(ref.rotation :: { number })

  local scale = ref.scale :: number?
  if scale and (scale ~= scale or scale == math.huge or scale == -math.huge) then
    ref.scale = nil
  end

  return ref, p
end

local function persistent(ref: Value): boolean
  return ref.movedCell ~= nil or ref.destination ~= nil or not ref.temporary
end

local function cell(b: buffer, s: number, e: number, enc: string): Value
  local r: Value = { name = '', data = { flags = '', grid = { 0, 0 } } }
  local flags = buffer.readu32(b, s + 12)
  local references: { [number]: Value } = {}
  local temporary = 0
  local moved: { { number } } = {}
  local p = s + 16
  while p < e do
    if e - p < 4 then fail(`partial tag at offset {p - s}`) end

    local tag = buffer.readu32(b, p)
    p += 4
    if tag == C.NAME then
      r.name, p = str(b, p, e, enc)
    elseif tag == C.DATA then
      p = expect(b, p, e, 12)
      need(p, 12, e)
      r.data = {
        flags = flagText(Flags.CellFlags, buffer.readu32(b, p)),
        grid = { buffer.readi32(b, p + 4), buffer.readi32(b, p + 8) },
      }
      p += 12
    elseif tag == C.RGNN then
      r.region, p = str(b, p, e, enc)
    elseif tag == C.NAM5 then
      p = expect(b, p, e, 4)
      need(p, 4, e)
      r.mapColor = u8List(b, p, 4)
      p += 4
    elseif tag == C.WHGT then
      p = expect(b, p, e, 4)
      need(p, 4, e)
      r.waterHeight = buffer.readf32(b, p)
      p += 4
    elseif tag == C.AMBI then
      local size = u32(b, p, e)
      p += 4
      need(p, 16, e)
      r.atmosphereData = {
        ambientColor = u8List(b, p, 4),
        sunlightColor = u8List(b, p + 4, 4),
        fogColor = u8List(b, p + 8, 4),
        fogDensity = buffer.readf32(b, p + 12),
      }
      p += 16
      if size < 16 then fail(`Invalid AMBI Size: {size}`) end

      p = skip(p, size - 16, e)
    elseif tag == C.NAM0 then
      p = expect(b, p, e, 4)
      need(p, 4, e)
      temporary = buffer.readi32(b, p)
      p += 4
    elseif tag == C.MVRF then
      p = expect(b, p, e, 4)
      need(p, 4, e)
      local packed = buffer.readu32(b, p)
      p = expect(b, p + 4, e, CNDT)
      p = expect(b, p, e, 8)
      need(p, 8, e)
      table.insert(moved, { packed, buffer.readi32(b, p), buffer.readi32(b, p + 4) })
      p += 8
    elseif tag == C.FRMR then
      p = expect(b, p, e, 4)
      need(p, 4, e)
      local packed = buffer.readu32(b, p)
      local ref
      ref, p = reference(b, p + 4, e, enc)
      ref.mastIndex = bit32.rshift(packed, 24)
      ref.refrIndex = bit32.band(packed, 0x00ffffff)
      ref.temporary = temporary > 0
      temporary -= 1
      references[packed] = ref
      local last = moved[#moved]
      if last and bit32.rshift(last[1], 24) == 0 then last[1] = packed end
    elseif tag == C.INTV then
      p = expect(b, p, e, 4)
      need(p, 4, e)
      r.waterHeight = f32(buffer.readi32(b, p))
      p += 4
    elseif tag == C.DELE then
      local size = u32(b, p, e)
      p = skip(p + 4, size, e)
      flags = bit32.bor(flags, 0x20)
    else
      fail(`Unexpected Tag: CELL::{Tags.lossy(tag)}`)
    end
  end

  for _, entry in moved do
    local ref = references[entry[1]]
    if not ref then
      local grid = (r.data :: Value).grid :: { number }
      fail(
        `Unable to resolve moved reference ({bit32.rshift(entry[1], 24)}, {bit32.band(
          entry[1],
          0x00ffffff
        )}) for cell {r.name} ({grid[1]}, {grid[2]})`
      )
    end

    ref.movedCell = { entry[2], entry[3] }
  end

  local sorted: { Value } = {}
  for _, ref in references do
    table.insert(sorted, ref)
  end

  table.sort(sorted, function(a, c)
    local pa, pc = persistent(a), persistent(c)
    if pa ~= pc then return pa end

    local ma, mc = a.mastIndex :: number, c.mastIndex :: number
    if ma == 0 then ma = 4294967296 end

    if mc == 0 then mc = 4294967296 end

    if ma ~= mc then return ma < mc end

    return (a.refrIndex :: number) < (c.refrIndex :: number)
  end)

  r.references = sorted
  r.flags = flagText(Flags.ObjectFlags, flags)
  return r
end

--[[ LAND ]]

local function landscape(b: buffer, s: number, e: number): Value
  local flags = buffer.readu32(b, s + 12)
  local r: Value = {
    grid = { 0, 0 },
    landscapeFlags = '',
    vertexNormals = { data = ZeroBlob },
    vertexHeights = { offset = 0, data = '' },
    worldMapData = { data = '' },
    vertexColors = { data = ZeroBlob },
    textureIndices = { data = '' },
  }
  local heights, worldMap, textures = false, false, false
  local p = s + 16
  while p < e do
    if e - p < 4 then fail(`partial tag at offset {p - s}`) end

    local tag = buffer.readu32(b, p)
    p += 4
    if tag == C.INTV then
      p = expect(b, p, e, 8)
      need(p, 8, e)
      r.grid = { buffer.readi32(b, p), buffer.readi32(b, p + 4) }
      p += 8
    elseif tag == C.DATA then
      p = expect(b, p, e, 4)
      need(p, 4, e)
      r.landscapeFlags = flagText(Flags.LandscapeFlags, buffer.readu32(b, p))
      p += 4
    elseif tag == C.VNML then
      p = expect(b, p, e, 12675)
      need(p, 12675, e)
      r.vertexNormals = { data = base64(b, p, 12675) }
      p += 12675
    elseif tag == C.VHGT then
      p = expect(b, p, e, 4232)
      need(p, 4232, e)
      r.vertexHeights = { offset = buffer.readf32(b, p), data = base64(b, p + 4, 4225) }
      heights = true
      p += 4232
    elseif tag == C.WNAM then
      p = expect(b, p, e, 81)
      need(p, 81, e)
      r.worldMapData = { data = base64(b, p, 81) }
      worldMap = true
      p += 81
    elseif tag == C.VCLR then
      p = expect(b, p, e, 12675)
      need(p, 12675, e)
      r.vertexColors = { data = base64(b, p, 12675) }
      p += 12675
    elseif tag == C.VTEX then
      p = expect(b, p, e, 512)
      need(p, 512, e)
      r.textureIndices = { data = base64(b, p, 512) }
      textures = true
      p += 512
    elseif tag == C.DELE then
      local size = u32(b, p, e)
      p = skip(p + 4, size, e)
      flags = bit32.bor(flags, 0x20)
    else
      fail(`Unexpected Tag: LAND::{Tags.lossy(tag)}`)
    end
  end

  if not heights then (r.vertexHeights :: Value).data = base64(Zeros, 0, 4225) end

  if not worldMap then (r.worldMapData :: Value).data = base64(Zeros, 0, 81) end

  if not textures then (r.textureIndices :: Value).data = base64(Zeros, 0, 512) end

  r.flags = flagText(Flags.ObjectFlags, flags)
  return r
end

--[[ PGRD ]]

spec(
  'PGRD',
  'PathGrid',
  function()
    return {
      flags = 0,
      cell = '',
      data = { grid = { 0, 0 }, granularity = 0, pointCount = 0 },
      points = {},
      connections = 'AAAAAA==',
    }
  end,

  {
    NAME = S 'cell',
    DATA = T(
      12,
      'data',
      function(b, p)
        return {
          grid = { buffer.readi32(b, p), buffer.readi32(b, p + 4) },
          granularity = buffer.readu16(b, p + 8),
          pointCount = buffer.readu16(b, p + 10),
        }
      end
    ),
    PGRP = function(b, p, e, r)
      local length = u32(b, p, e)
      p += 4
      local count = length // 16
      local points = table.create(count)
      for i = 1, count do
        need(p, 16, e)
        points[i] = {
          location = i32List(b, p, 3),
          autoGenerated = buffer.readu8(b, p + 12),
          connectionCount = buffer.readu8(b, p + 13),
        }
        p += 16
      end

      r.points = points
      return p
    end,

    PGRC = function(b, p, e, r)
      local length = u32(b, p, e)
      local count = length // 4
      need(p + 4, count * 4, e)
      r.connections = base64(b, p + 4, count * 4, count)
      return p + 4 + count * 4
    end,
    DELE = DELE,
  },
  finishFlags
)

--[[ DIAL and INFO ]]

spec('DIAL', 'Dialogue', base { dialogueType = 'Topic' }, {
  NAME = S 'id',
  DATA = function(b, p, e, r)
    local size = u32(b, p, e)
    p += 4
    if size == 1 then
      need(p, 1, e)
      r.dialogueType = nameOf(Enums.DialogueType, buffer.readu8(b, p))
      return p + 1
    end

    return skip(p, size, e)
  end,
  DELE = DELE,
}, finishFlags)

local function quest(state: string): Handler
  return function(b, p, e, r)
    local size = u32(b, p, e)
    r.questState = state
    return skip(p + 4, size, e)
  end
end

spec(
  'INFO',
  'DialogueInfo',
  base {
    prevId = '',
    nextId = '',
    data = function()
      return {
        dialogueType = 'Topic',
        disposition = 0,
        speakerRank = 0,
        speakerSex = 'Any',
        playerRank = 0,
      }
    end,
    speakerId = '',
    speakerRace = '',
    speakerClass = '',
    speakerFaction = '',
    speakerCell = '',
    playerFaction = '',
    soundPath = '',
    text = '',
    filters = function() return {} end,
    scriptText = '',
  },

  {
    INAM = S 'id',
    PNAM = S 'prevId',
    NNAM = S 'nextId',
    DATA = T(
      12,
      'data',
      function(b, p)
        return {
          dialogueType = nameOf(Enums.DialogueType, buffer.readu32(b, p)),
          disposition = buffer.readi32(b, p + 4),
          speakerRank = buffer.readi8(b, p + 8),
          speakerSex = nameOf(Enums.Sex, buffer.readi8(b, p + 9)),
          playerRank = buffer.readi8(b, p + 10),
        }
      end
    ),
    ONAM = S 'speakerId',
    RNAM = S 'speakerRace',
    CNAM = S 'speakerClass',
    FNAM = S 'speakerFaction',
    ANAM = S 'speakerCell',
    DNAM = S 'playerFaction',
    SNAM = S 'soundPath',
    NAME = X 'text',
    QSTN = quest 'Name',
    QSTF = quest 'Finished',
    QSTR = quest 'Restart',
    SCVR = function(b, p, e, r, enc)
      local length = u32(b, p, e)
      p += 4
      need(p, 5, e)
      local index = buffer.readu8(b, p)
      local filter: Value = {
        filterType = nameOf(Enums.FilterType, buffer.readu8(b, p + 1)),
        ['function'] = nameOf(Enums.FilterFunction, buffer.readu16(b, p + 2)),
        comparison = nameOf(Enums.FilterComparison, buffer.readu8(b, p + 4)),
      }
      p += 5
      if length < 5 then fail(`DialogueInfo: Invalid filter size: {length}`) end

      filter.id = fixed(b, p, e, length - 5, enc)
      p += length - 5
      if index < 48 then fail 'DialogueInfo: Invalid filter index' end

      filter.index = index - 48
      filter.value = { type = 'Float', data = 0 }
      table.insert(r.filters :: { unknown }, filter)
      return p
    end,

    FLTV = function(b, p, e, r)
      p = expect(b, p, e, 4)
      need(p, 4, e)
      local filters = r.filters :: { Value }
      local last = filters[#filters]
      if not last then
        fail 'Info filter value was provided without a corresponding filter definition.'
      end

      last.value = { type = 'Float', data = buffer.readf32(b, p) }
      return p + 4
    end,

    INTV = function(b, p, e, r)
      p = expect(b, p, e, 4)
      need(p, 4, e)
      local filters = r.filters :: { Value }
      local last = filters[#filters]
      if not last then
        fail 'Info filter value was provided without a corresponding filter definition.'
      end

      last.value = { type = 'Integer', data = buffer.readi32(b, p) }
      return p + 4
    end,
    BNAM = X 'scriptText',
    DELE = DELE,
  },
  finishFlags
)

--[[ LUAL ]]

local function emptyConfig(): Value
  return {
    path = '',
    initData = 'AAAAAA==',
    flags = 0,
    types = {},
    records = {},
    instances = {},
  }
end

local function isEmptyConfig(config: Value): boolean
  return config.path == ''
    and config.initData == 'AAAAAA=='
    and config.flags == 0
    and #(config.types :: { unknown }) == 0
    and #(config.records :: { unknown }) == 0
    and #(config.instances :: { unknown }) == 0
end

local function finishConfig(config: Value): Value
  config.flags = flagText(Flags.OMWScriptAttachFlag, config.flags :: number)
  return config
end

local function scriptConfigList(b: buffer, s: number, e: number, enc: string): Value
  local scripts: { Value } = {}
  local config = emptyConfig()
  local flags = buffer.readu32(b, s + 12)
  local last: number? = nil
  local p = s + 16
  while p < e do
    if e - p < 4 then fail(`partial tag at offset {p - s}`) end

    local tag = buffer.readu32(b, p)
    p += 4
    if tag == C.LUAS then
      if not isEmptyConfig(config) then
        table.insert(scripts, finishConfig(config))
        config = emptyConfig()
      end

      config.path, p = str(b, p, e, enc)
    elseif tag == C.LUAF then
      local size = u32(b, p, e)
      p += 4
      if size < 4 or size % 4 ~= 0 then fail(`Invalid LUAF Size: {size}`) end

      need(p, 4, e)
      config.flags = buffer.readu32(b, p)
      p += 4
      for _ = 1, size // 4 - 1 do
        table.insert(config.types :: { unknown }, fixed(b, p, e, 4, enc))
        p += 4
      end
    elseif tag == C.LUAI then
      p = skip(p, 4, e)
      need(p, 9, e)
      table.insert(config.instances :: { unknown }, {
        attach = buffer.readu8(b, p) ~= 0,
        refIdx = buffer.readu32(b, p + 1),
        mastIdx = buffer.readi32(b, p + 5),
        data = 'AAAAAA==',
      })
      p += 9
    elseif tag == C.LUAR then
      local size = u32(b, p, e)
      p += 4
      need(p, 1, e)
      local attach = buffer.readu8(b, p) ~= 0
      p += 1
      if size == 0 then fail 'Invalid LUAR Size: 0' end

      local id = fixed(b, p, e, size - 1, enc)
      p += size - 1
      table.insert(config.records :: { unknown }, { attach = attach, id = id, data = 'AAAAAA==' })
    elseif tag == C.LUAD then
      local size = u32(b, p, e)
      p += 4
      if p + size > e then fail(`length {size} exceeds the {e - p} bytes remaining`) end

      local data = base64(b, p, size, size)
      p += size
      if last == C.LUAF then
        config.initData = data
      elseif last == C.LUAI then
        local instances = config.instances :: { Value }
        local instance = instances[#instances]
        if not instance then fail 'LUAD without a LUAI' end

        instance.data = data
      elseif last == C.LUAR then
        local records = config.records :: { Value }
        local record = records[#records]
        if not record then fail 'LUAD without a LUAR' end

        record.data = data
      elseif last then
        fail(`Unexpected Data Tag Preceding LUAD: LUAL::{Tags.lossy(last)}`)
      end
    else
      fail(`Unexpected Tag: LUAL::{Tags.lossy(tag)}`)
    end

    last = tag
  end

  if not isEmptyConfig(config) then table.insert(scripts, finishConfig(config)) end

  return { scripts = scripts, flags = flagText(Flags.ObjectFlags, flags) }
end

--[[ Dispatch ]]

local ByCode: { [number]: Spec } = {}
local ByName: { [string]: Spec } = {}

for _, entry in Specs do
  ByCode[Tags.code(entry.tag)] = entry
  ByName[entry.name] = entry
end

local function special(
  tag: string,
  name: string,
  custom: (b: buffer, s: number, e: number, enc: string) -> Value,
  init: () -> Value
)
  local entry: Spec = { tag = tag, name = name, init = init, handlers = {}, custom = custom }
  table.insert(Specs, entry)
  ByCode[Tags.code(tag)] = entry
  ByName[name] = entry
end

special(
  'CELL',
  'Cell',
  cell,
  function()
    return { flags = '', name = '', data = { flags = '', grid = { 0, 0 } }, references = {} }
  end
)

special('LAND', 'Landscape', function(b, s, e) return landscape(b, s, e) end, function()
  local empty = buffer.create(16)
  buffer.writeu32(empty, 0, Tags.code 'LAND')
  return landscape(empty, 0, 16)
end)

special(
  'LUAL',
  'ScriptConfigList',
  scriptConfigList,
  function() return { scripts = {}, flags = '' } end
)

--- Decodes the record whose bytes are `[s, e)` of `b`, its text in `enc`. Nil for a tag no record
--- type has.
local function decode(b: buffer, s: number, e: number, enc: string): Value?
  local entry = ByCode[buffer.readu32(b, s)]
  if not entry then return nil end

  if entry.custom then
    local value = entry.custom(b, s, e, enc)
    value.type = entry.name
    return value
  end

  local r = entry.init()
  r.flags = buffer.readu32(b, s + 12)
  local handlers = entry.handlers
  local p = s + 16
  while p < e do
    if e - p < 4 then fail(`partial tag at offset {p - s}`) end

    local tag = buffer.readu32(b, p)
    local handler = handlers[tag]
    if not handler then fail(`Unexpected Tag: {entry.tag}::{Tags.lossy(tag)}`) end

    p = handler(b, p + 4, e, r, enc)
  end

  local finish = entry.finish
  if finish then finish(r, s) end

  r.type = entry.name
  return r
end

--- A default value of the record type named `name` (`Book`) or tagged `name` (`BOOK`): what a
--- record with no subrecords decodes to.
local function default(name: string): Value?
  local entry = ByName[name] or ByCode[if #name == 4 then Tags.code(name) else -1]
  if not entry then return nil end

  local empty = buffer.create(16)
  buffer.writeu32(empty, 0, Tags.code(entry.tag))
  return decode(empty, 0, 16, 'win1252')
end

--- The record type name of a tag (`Light` for `LIGH`), or nil.
local function typeName(tag: string): string?
  local entry = if #tag == 4 then ByCode[Tags.code(tag)] else nil
  return entry and entry.name
end

--- The tag of the record type named `name` (`Light`) or tagged `name`, ignoring case; or nil.
local function tagNamed(name: string): string?
  local lower = string.lower(name)
  for _, entry in Specs do
    if string.lower(entry.name) == lower or string.lower(entry.tag) == lower then
      return entry.tag
    end
  end

  return nil
end

return table.freeze {
  decode = decode,
  default = default,
  specs = Specs,
  tagNamed = tagNamed,
  typeName = typeName,
}
