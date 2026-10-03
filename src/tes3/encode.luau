--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Typed record encoding: a value in jess-omwaddon's shape (as `decode` gives) written as record
bytes, the way jess-omwaddon's `Save` writes them: the subrecords in its order, optional ones only
when set, strings NUL-terminated, the header's second word zero. Missing fields take the record
type's defaults, nested structs included; a list replaces the default list whole.

Encoding normalizes what vanilla data spells differently (unterminated strings, padding, reference
order), so a decoded record doesn't always encode to its own bytes; `writeback.luau` keeps the
original subrecords an edit didn't change.
]]

local Decode = require './decode'
local Schema = require './schema'
local Tags = require './tags'
local Text = require './text'
local Writer = require './writer'

local Enums = Schema.Enums
local Flags = Schema.Flags

type Value = Decode.Value
type W = Writer.Writer

local function fail(message: string): never error(message, 0) end

local function isList(value: unknown): boolean
  if type(value) ~= 'table' then return false end

  local t = value :: { [unknown]: unknown }
  return next(t) == nil or t[1] ~= nil
end

--- `value` laid over `default`: missing fields take the default's, structs merge field by field.
local function merge(default: unknown, value: unknown): unknown
  if value == nil then return default end

  if type(default) ~= 'table' or type(value) ~= 'table' or isList(default) or isList(value) then
    return value
  end

  local out: Value = {}
  local d = default :: Value
  local v = value :: Value
  for key, fallback in d do
    out[key] = merge(fallback, v[key])
  end

  for key, field in v do
    if d[key] == nil then out[key] = field end
  end

  return out
end

--[[ Field access, checked ]]

local function field(t: Value, key: string, path: string): unknown return t[key] end

local function num(t: Value, key: string, path: string): number
  local value = field(t, key, path)
  if type(value) ~= 'number' then
    return fail(`{path}.{key}: expected number, got {type(value)}`)
  end

  return value
end

local function str(t: Value, key: string, path: string): string
  local value = field(t, key, path)
  if type(value) ~= 'string' then
    return fail(`{path}.{key}: expected string, got {type(value)}`)
  end

  return value
end

local function tab(t: Value, key: string, path: string): Value
  local value = field(t, key, path)
  if type(value) ~= 'table' then fail(`{path}.{key}: expected table, got {type(value)}`) end

  return value :: Value
end

local function list(t: Value, key: string, path: string): { unknown }
  local value = field(t, key, path)
  if type(value) ~= 'table' then fail(`{path}.{key}: expected list, got {type(value)}`) end

  return value :: { unknown }
end

local function numAt(items: { unknown }, i: number, path: string): number
  local value = items[i]
  if type(value) ~= 'number' then return fail(`{path}[{i}]: expected number, got {type(value)}`) end

  return value
end

local function enum(e: Schema.Enum, t: Value, key: string, path: string): number
  return Schema.valueOf(e, t[key], `{path}.{key}`)
end

local function flags(set: Schema.Flags, t: Value, key: string, path: string): number
  return Schema.flagBits(set, t[key], `{path}.{key}`)
end

--[[ Writing ]]

local function tag(w: W, name: string) Writer.u32(w, Tags.code(name)) end

--- Text in the code page, cut at its first NUL (`Writer::encode`).
local function encodeText(value: string, enc: string): string
  local encoded = Text.encode(value, enc) or fail(`encode error: {value}`)

  local nul = string.find(encoded, '\0', 1, true)
  if nul then return string.sub(encoded, 1, nul - 1) end

  return encoded
end

--- A length-prefixed, NUL-terminated string (`save_string`).
local function wString(w: W, value: string, enc: string)
  if value == '' then
    Writer.u32(w, 1)
    Writer.u8(w, 0)
    return
  end

  local encoded = Text.encode(value, enc) or fail(`encode error: {value}`)

  local nul = string.find(encoded, '\0', 1, true)
  if nul then
    Writer.u32(w, nul - 1)
    Writer.string(w, string.sub(encoded, 1, nul - 1))
    return
  end

  Writer.u32(w, #encoded + 1)
  Writer.string(w, encoded)
  Writer.u8(w, 0)
end

--- A length-prefixed string with every byte kept (`save_exact_string`).
local function wExact(w: W, value: string, enc: string)
  local encoded = Text.encode(value, enc) or fail(`encode error: {value}`)

  Writer.u32(w, #encoded)
  Writer.string(w, encoded)
end

--- A NUL-padded string of exactly `n` bytes (`FixedString<N>`).
local function wFixed(w: W, value: string, n: number, enc: string)
  local encoded = encodeText(value, enc)
  if #encoded > n then fail(`Invalid string length ({#value} != {n}): {value}`) end

  Writer.string(w, encoded)
  Writer.zeros(w, n - #encoded)
end

--- A string subrecord: its tag, then the string.
local function sub(w: W, name: string, value: string, enc: string)
  tag(w, name)
  wString(w, value, enc)
end

--- A string subrecord written only when the string isn't empty.
local function opt(w: W, name: string, value: string, enc: string)
  if value ~= '' then sub(w, name, value, enc) end
end

local function header(w: W, name: string, size: number)
  tag(w, name)
  Writer.u32(w, size)
end

local function dele(w: W, bits: number)
  if not bit32.btest(bits, 0x20) then return end

  header(w, 'DELE', 4)
  Writer.u32(w, 0)
end

local function f32s(w: W, items: { unknown }, n: number, path: string)
  for i = 1, n do
    Writer.f32(w, numAt(items, i, path))
  end
end

local function i32s(w: W, items: { unknown }, n: number, path: string)
  for i = 1, n do
    Writer.i32(w, numAt(items, i, path))
  end
end

local function u8s(w: W, items: { unknown }, n: number, path: string)
  for i = 1, n do
    Writer.u8(w, numAt(items, i, path))
  end
end

--- The blob base64 `text` holds, written as is.
local function blob(w: W, text: string, path: string)
  local data = Schema.unbase64(text, path)
  Writer.copy(w, data, 0, buffer.len(data))
end

--- A base64 blob written with its own length prefix (a `Vec<u8>` jess-omwaddon saves whole), its
--- length checked against `width`-byte elements.
local function blobWithLength(w: W, text: string, path: string) blob(w, text, path) end

--[[ Structs ]]

local function effect(w: W, e: Value, path: string)
  Writer.u16(w, Schema.valueOf(Enums.EffectId, e.magicEffect, `{path}.magicEffect`) % 65536)
  Writer.u8(w, Schema.valueOf(Enums.SkillId, e.skill, `{path}.skill`) % 256)
  Writer.u8(w, Schema.valueOf(Enums.AttributeId, e.attribute, `{path}.attribute`) % 256)
  Writer.u32(w, enum(Enums.EffectRange, e, 'range', path))
  Writer.u32(w, num(e, 'area', path))
  Writer.u32(w, num(e, 'duration', path))
  Writer.u32(w, num(e, 'minMagnitude', path))
  Writer.u32(w, num(e, 'maxMagnitude', path))
end

local function effects(w: W, r: Value)
  for i, item in list(r, 'effects', 'value') do
    header(w, 'ENAM', 24)
    effect(w, item :: Value, `effects[{i}]`)
  end
end

local function inventory(w: W, r: Value, enc: string)
  for i, item in list(r, 'inventory', 'value') do
    local pair = item :: { unknown }
    header(w, 'NPCO', 36)
    Writer.i32(w, numAt(pair, 1, `inventory[{i}]`))
    wFixed(w, pair[2] :: string, 32, enc)
  end
end

local function spells(w: W, r: Value, enc: string)
  for _, item in list(r, 'spells', 'value') do
    header(w, 'NPCS', 32)
    wFixed(w, item :: string, 32, enc)
  end
end

local function aiData(w: W, r: Value)
  local a = tab(r, 'aiData', 'value')
  header(w, 'AIDT', 12)
  Writer.u16(w, num(a, 'hello', 'aiData') % 65536)
  Writer.u8(w, num(a, 'fight', 'aiData') % 256)
  Writer.u8(w, num(a, 'flee', 'aiData') % 256)
  Writer.u8(w, num(a, 'alarm', 'aiData') % 256)
  Writer.zeros(w, 3)
  Writer.u32(w, flags(Flags.ServiceFlags, a, 'services', 'aiData'))
end

local function travel(w: W, r: Value, enc: string)
  for i, item in list(r, 'travelDestinations', 'value') do
    local d = item :: Value
    local path = `travelDestinations[{i}]`
    header(w, 'DODT', 24)
    f32s(w, list(d, 'translation', path), 3, `{path}.translation`)
    f32s(w, list(d, 'rotation', path), 3, `{path}.rotation`)
    opt(w, 'DNAM', str(d, 'cell', path), enc)
  end
end

local function packages(w: W, r: Value, enc: string)
  for i, item in list(r, 'aiPackages', 'value') do
    local a = item :: Value
    local path = `aiPackages[{i}]`
    local kind = a.type
    if kind == 'Travel' then
      header(w, 'AI_T', 16)
      f32s(w, list(a, 'location', path), 3, path)
      Writer.u8(w, num(a, 'reset', path))
      Writer.zeros(w, 3)
    elseif kind == 'Wander' then
      header(w, 'AI_W', 14)
      Writer.u16(w, num(a, 'distance', path))
      Writer.u16(w, num(a, 'duration', path))
      Writer.u8(w, num(a, 'gameHour', path))
      for k = 2, 9 do
        Writer.u8(w, num(a, `idle{k}`, path))
      end

      Writer.u8(w, num(a, 'reset', path) % 256)
    elseif kind == 'Escort' or kind == 'Follow' then
      header(w, if kind == 'Escort' then 'AI_E' else 'AI_F', 48)
      f32s(w, list(a, 'location', path), 3, path)
      Writer.u16(w, num(a, 'duration', path))
      wFixed(w, str(a, 'target', path), 32, enc)
      Writer.u8(w, num(a, 'reset', path))
      Writer.zeros(w, 1)
      opt(w, 'CNDT', (a.cell :: string?) or '', enc)
    elseif kind == 'Activate' then
      header(w, 'AI_A', 33)
      wFixed(w, str(a, 'target', path), 32, enc)
      Writer.u8(w, num(a, 'reset', path))
    else
      fail(
        `{path}.type: unknown variant '{tostring(kind)}', expected one of Activate, Escort, Follow, Travel, Wander`
      )
    end
  end
end

local function bipedObjects(w: W, r: Value, enc: string)
  for i, item in list(r, 'bipedObjects', 'value') do
    local o = item :: Value
    local path = `bipedObjects[{i}]`
    header(w, 'INDX', 1)
    Writer.u8(w, enum(Enums.BipedObjectType, o, 'bipedObjectType', path))
    opt(w, 'BNAM', str(o, 'maleBodypart', path), enc)
    opt(w, 'CNAM', str(o, 'femaleBodypart', path), enc)
  end
end

--- `v` clamped to `0.5..2.0`, and whether that's 1 (the default scale, which goes unwritten).
local function clampScale(v: number): (number, boolean)
  local scale = math.clamp(v, 0.5, 2)
  if v ~= v then scale = v end

  return scale, math.abs(scale - 1) < 1e-6
end

--[[ Record types ]]

type Encoder = (w: W, r: Value, enc: string, bits: number) -> ()

local Encoders: { [string]: Encoder } = {}

--- `MODL`, `FNAM`, data, `SCRI`, `ITEX`: the shape most items save in.
local function itemHead(w: W, r: Value, enc: string)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  opt(w, 'MODL', str(r, 'mesh', 'value'), enc)
  opt(w, 'FNAM', str(r, 'name', 'value'), enc)
end

local function itemTail(w: W, r: Value, enc: string)
  opt(w, 'SCRI', str(r, 'script', 'value'), enc)
  opt(w, 'ITEX', str(r, 'icon', 'value'), enc)
end

Encoders.Header = function(w, r, enc)
  header(w, 'HEDR', 300)
  Writer.f32(w, num(r, 'version', 'value'))
  Writer.u32(w, enum(Enums.FileType, r, 'fileType', 'value'))
  wFixed(w, str(r, 'author', 'value'), 32, enc)
  wFixed(w, str(r, 'description', 'value'), 256, enc)
  Writer.u32(w, num(r, 'numObjects', 'value'))
  for i, item in list(r, 'masters', 'value') do
    local pair = item :: { unknown }
    sub(w, 'MAST', pair[1] :: string, enc)
    header(w, 'DATA', 8)
    Writer.u64(w, numAt(pair, 2, `masters[{i}]`))
  end
end

Encoders.GameSetting = function(w, r, enc)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  local value = tab(r, 'value', 'value')
  local kind = value.type
  if kind == 'String' then
    tag(w, 'STRV')
    wExact(w, str(value, 'data', 'value'), enc)
  elseif kind == 'Float' then
    header(w, 'FLTV', 4)
    Writer.f32(w, num(value, 'data', 'value'))
  elseif kind == 'Integer' then
    header(w, 'INTV', 4)
    Writer.i32(w, num(value, 'data', 'value'))
  else
    fail(
      `value.value.type: unknown variant '{tostring(kind)}', expected one of Float, Integer, String`
    )
  end
end

local GlobalTypes = { Float = 102, Long = 108, Short = 115 }

Encoders.GlobalVariable = function(w, r, enc, bits)
  local id = str(r, 'id', 'value')
  sub(w, 'NAME', id, enc)
  local value = tab(r, 'value', 'value')
  local kind = value.type :: string
  local code = GlobalTypes[kind]
  if not code then
    fail(`value.value.type: unknown variant '{tostring(kind)}', expected one of Float, Long, Short`)
  end

  local data = num(value, 'data', 'value')
  header(w, 'FNAM', 1)
  Writer.u8(w, code)
  header(w, 'FLTV', 4)
  Writer.f32(w, data)
  dele(w, bits)
  -- Disallow values with known precision errors.
  if kind ~= 'Float' then
    local scratch = buffer.create(4)
    buffer.writef32(scratch, 0, data)
    if buffer.readf32(scratch, 0) ~= data then fail(`GlobalVariable precision error: {id}`) end
  end
end

Encoders.Class = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  opt(w, 'FNAM', str(r, 'name', 'value'), enc)
  local d = tab(r, 'data', 'value')
  header(w, 'CLDT', 60)
  Writer.i32(w, enum(Enums.AttributeId, d, 'attribute1', 'data'))
  Writer.i32(w, enum(Enums.AttributeId, d, 'attribute2', 'data'))
  Writer.i32(w, enum(Enums.Specialization, d, 'specialization', 'data'))
  for k = 1, 5 do
    Writer.i32(w, enum(Enums.SkillId, d, `minor{k}`, 'data'))
    Writer.i32(w, enum(Enums.SkillId, d, `major{k}`, 'data'))
  end

  Writer.u32(w, flags(Flags.ClassFlags, d, 'flags', 'data'))
  Writer.u32(w, flags(Flags.ServiceFlags, d, 'services', 'data'))
  local description = str(r, 'description', 'value')
  if description ~= '' then
    tag(w, 'DESC')
    wExact(w, description, enc)
  end

  dele(w, bits)
end

Encoders.Faction = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  opt(w, 'FNAM', str(r, 'name', 'value'), enc)
  for _, name in list(r, 'rankNames', 'value') do
    header(w, 'RNAM', 32)
    wFixed(w, name :: string, 32, enc)
  end

  local d = tab(r, 'data', 'value')
  header(w, 'FADT', 240)
  for _, attribute in list(d, 'favoredAttributes', 'data') do
    Writer.i32(w, Schema.valueOf(Enums.AttributeId, attribute, 'data.favoredAttributes'))
  end

  for i, item in list(d, 'requirements', 'data') do
    local q = item :: Value
    local path = `data.requirements[{i}]`
    i32s(w, list(q, 'attributes', path), 2, path)
    Writer.i32(w, num(q, 'primarySkill', path))
    Writer.i32(w, num(q, 'favoredSkill', path))
    Writer.i32(w, num(q, 'reputation', path))
  end

  for _, skill in list(d, 'favoredSkills', 'data') do
    Writer.i32(w, Schema.valueOf(Enums.SkillId, skill, 'data.favoredSkills'))
  end

  Writer.u32(w, flags(Flags.FactionFlags, d, 'flags', 'data'))
  for i, item in list(r, 'reactions', 'value') do
    local reaction = item :: Value
    sub(w, 'ANAM', str(reaction, 'faction', `reactions[{i}]`), enc)
    header(w, 'INTV', 4)
    Writer.i32(w, num(reaction, 'reaction', `reactions[{i}]`))
  end

  dele(w, bits)
end

Encoders.Race = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  opt(w, 'FNAM', str(r, 'name', 'value'), enc)
  local d = tab(r, 'data', 'value')
  header(w, 'RADT', 140)
  local bonuses = tab(d, 'skillBonuses', 'data')
  for k = 0, 6 do
    Writer.i32(w, enum(Enums.SkillId, bonuses, `skill_{k}`, 'data.skillBonuses'))
    Writer.i32(w, num(bonuses, `bonus_{k}`, 'data.skillBonuses'))
  end

  for _, key in
    {
      'strength',
      'intelligence',
      'willpower',
      'agility',
      'speed',
      'endurance',
      'personality',
      'luck',
    }

  do
    i32s(w, list(d, key, 'data'), 2, `data.{key}`)
  end

  f32s(w, list(d, 'height', 'data'), 2, 'data.height')
  f32s(w, list(d, 'weight', 'data'), 2, 'data.weight')
  Writer.u32(w, flags(Flags.RaceFlags, d, 'flags', 'data'))
  spells(w, r, enc)
  local description = str(r, 'description', 'value')
  if description ~= '' then
    tag(w, 'DESC')
    wExact(w, description, enc)
  end

  dele(w, bits)
end

Encoders.Sound = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  opt(w, 'FNAM', str(r, 'soundPath', 'value'), enc)
  local d = tab(r, 'data', 'value')
  header(w, 'DATA', 3)
  Writer.u8(w, num(d, 'volume', 'data'))
  u8s(w, list(d, 'range', 'data'), 2, 'data.range')
  dele(w, bits)
end

Encoders.SoundGen = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  header(w, 'DATA', 4)
  Writer.u32(w, enum(Enums.SoundGenType, r, 'soundGenType', 'value'))
  opt(w, 'CNAM', str(r, 'creature', 'value'), enc)
  opt(w, 'SNAM', str(r, 'sound', 'value'), enc)
  dele(w, bits)
end

Encoders.Skill = function(w, r, enc, bits)
  header(w, 'INDX', 4)
  Writer.i32(w, enum(Enums.SkillId, r, 'skillId', 'value'))
  local d = tab(r, 'data', 'value')
  header(w, 'SKDT', 24)
  Writer.i32(w, num(d, 'governingAttribute', 'data'))
  Writer.i32(w, num(d, 'specialization', 'data'))
  f32s(w, list(d, 'actions', 'data'), 4, 'data.actions')
  local description = str(r, 'description', 'value')
  if description ~= '' then
    tag(w, 'DESC')
    wExact(w, description, enc)
  end

  dele(w, bits)
end

Encoders.MagicEffect = function(w, r, enc, bits)
  header(w, 'INDX', 4)
  Writer.i32(w, enum(Enums.EffectId, r, 'effectId', 'value'))
  local d = tab(r, 'data', 'value')
  header(w, 'MEDT', 36)
  Writer.u32(w, enum(Enums.EffectSchool, d, 'school', 'data'))
  Writer.f32(w, num(d, 'baseCost', 'data'))
  Writer.u32(w, flags(Flags.MagicEffectFlags, d, 'flags', 'data'))
  i32s(w, list(d, 'color', 'data'), 3, 'data.color')
  Writer.f32(w, num(d, 'speed', 'data'))
  Writer.f32(w, num(d, 'size', 'data'))
  Writer.f32(w, num(d, 'sizeCap', 'data'))
  for _, pair in
    {
      { 'ITEX', 'icon' },
      { 'PTEX', 'texture' },
      { 'BSND', 'boltSound' },
      { 'CSND', 'castSound' },
      { 'HSND', 'hitSound' },
      { 'ASND', 'areaSound' },
      { 'CVFX', 'castVisual' },
      { 'BVFX', 'boltVisual' },
      { 'HVFX', 'hitVisual' },
      { 'AVFX', 'areaVisual' },
    }

  do
    opt(w, pair[1], str(r, pair[2], 'value'), enc)
  end

  local description = str(r, 'description', 'value')
  if description ~= '' then
    tag(w, 'DESC')
    wExact(w, description, enc)
  end

  dele(w, bits)
end

--- A `Vec<u8>` or `Vec<u32>` blob as jess-omwaddon writes it, with its length first; whether the
--- vector it holds is empty.
local function isEmptyBlob(text: string): boolean return text == 'AAAAAA==' end

Encoders.Script = function(w, r, enc, bits)
  local h = tab(r, 'header', 'value')
  header(w, 'SCHD', 52)
  wFixed(w, str(r, 'id', 'value'), 32, enc)
  for _, key in { 'numShorts', 'numLongs', 'numFloats', 'bytecodeLength', 'variablesLength' } do
    Writer.u32(w, num(h, key, 'header'))
  end

  local variables = str(r, 'variables', 'value')
  if not isEmptyBlob(variables) then
    tag(w, 'SCVR')
    blobWithLength(w, variables, 'variables')
  end

  local bytecode = str(r, 'bytecode', 'value')
  if not isEmptyBlob(bytecode) then
    tag(w, 'SCDT')
    blobWithLength(w, bytecode, 'bytecode')
  end

  local text = str(r, 'text', 'value')
  if text ~= '' then
    tag(w, 'SCTX')
    wExact(w, text, enc)
  end

  dele(w, bits)
end

Encoders.Region = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  opt(w, 'FNAM', str(r, 'name', 'value'), enc)
  local c = tab(r, 'weatherChances', 'value')
  tag(w, 'WEAT')
  Writer.u32(w, 10)
  for _, key in
    {
      'clear',
      'cloudy',
      'foggy',
      'overcast',
      'rain',
      'thunder',
      'ash',
      'blight',
      'snow',
      'blizzard',
    }

  do
    Writer.u8(w, num(c, key, 'weatherChances'))
  end

  opt(w, 'BNAM', str(r, 'sleepCreature', 'value'), enc)
  header(w, 'CNAM', 4)
  u8s(w, list(r, 'mapColor', 'value'), 4, 'mapColor')
  for i, item in list(r, 'sounds', 'value') do
    local pair = item :: { unknown }
    header(w, 'SNAM', 33)
    wFixed(w, pair[1] :: string, 32, enc)
    Writer.u8(w, numAt(pair, 2, `sounds[{i}]`))
  end

  dele(w, bits)
end

Encoders.Birthsign = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  opt(w, 'FNAM', str(r, 'name', 'value'), enc)
  opt(w, 'TNAM', str(r, 'texture', 'value'), enc)
  opt(w, 'DESC', str(r, 'description', 'value'), enc)
  spells(w, r, enc)
  dele(w, bits)
end

Encoders.StartScript = function(w, r, enc, bits)
  sub(w, 'DATA', str(r, 'id', 'value'), enc)
  opt(w, 'NAME', str(r, 'script', 'value'), enc)
  dele(w, bits)
end

Encoders.LandscapeTexture = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  header(w, 'INTV', 4)
  Writer.u32(w, num(r, 'index', 'value'))
  opt(w, 'DATA', str(r, 'fileName', 'value'), enc)
  dele(w, bits)
end

Encoders.Spell = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  opt(w, 'FNAM', str(r, 'name', 'value'), enc)
  local d = tab(r, 'data', 'value')
  header(w, 'SPDT', 12)
  Writer.u32(w, enum(Enums.SpellType, d, 'spellType', 'data'))
  Writer.u32(w, num(d, 'cost', 'data'))
  Writer.u32(w, flags(Flags.SpellFlags, d, 'flags', 'data'))
  effects(w, r)
  dele(w, bits)
end

Encoders.Static = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  opt(w, 'MODL', str(r, 'mesh', 'value'), enc)
  dele(w, bits)
end

Encoders.Door = function(w, r, enc, bits)
  itemHead(w, r, enc)
  opt(w, 'SCRI', str(r, 'script', 'value'), enc)
  opt(w, 'SNAM', str(r, 'openSound', 'value'), enc)
  opt(w, 'ANAM', str(r, 'closeSound', 'value'), enc)
  dele(w, bits)
end

Encoders.MiscItem = function(w, r, enc, bits)
  itemHead(w, r, enc)
  local d = tab(r, 'data', 'value')
  header(w, 'MCDT', 12)
  Writer.f32(w, num(d, 'weight', 'data'))
  Writer.u32(w, num(d, 'value', 'data'))
  Writer.u32(w, flags(Flags.MiscItemFlags, d, 'flags', 'data'))
  itemTail(w, r, enc)
  dele(w, bits)
end

Encoders.Weapon = function(w, r, enc, bits)
  itemHead(w, r, enc)
  local d = tab(r, 'data', 'value')
  header(w, 'WPDT', 32)
  Writer.f32(w, num(d, 'weight', 'data'))
  Writer.u32(w, num(d, 'value', 'data'))
  Writer.u16(w, enum(Enums.WeaponType, d, 'weaponType', 'data'))
  Writer.u16(w, num(d, 'health', 'data'))
  Writer.f32(w, num(d, 'speed', 'data'))
  Writer.f32(w, num(d, 'reach', 'data'))
  Writer.u16(w, num(d, 'enchantment', 'data'))
  for _, key in { 'chopMin', 'chopMax', 'slashMin', 'slashMax', 'thrustMin', 'thrustMax' } do
    Writer.u8(w, num(d, key, 'data'))
  end

  Writer.u32(w, flags(Flags.WeaponFlags, d, 'flags', 'data'))
  itemTail(w, r, enc)
  opt(w, 'ENAM', str(r, 'enchanting', 'value'), enc)
  dele(w, bits)
end

Encoders.Container = function(w, r, enc, bits)
  itemHead(w, r, enc)
  header(w, 'CNDT', 4)
  Writer.f32(w, num(r, 'encumbrance', 'value'))
  header(w, 'FLAG', 4)
  Writer.u32(w, flags(Flags.ContainerFlags, r, 'containerFlags', 'value'))
  opt(w, 'SCRI', str(r, 'script', 'value'), enc)
  inventory(w, r, enc)
  dele(w, bits)
end

--- An actor's FLAG: its flags with the blood type in bits 10 to 12.
local function actorFlag(w: W, set: Schema.Flags, r: Value, key: string)
  local bits = bit32.band(flags(set, r, key, 'value'), bit32.bnot(0x1c00))
  header(w, 'FLAG', 4)
  Writer.u32(w, bit32.bor(bits, bit32.lshift(bit32.band(num(r, 'bloodType', 'value'), 7), 10)))
end

Encoders.Creature = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  opt(w, 'MODL', str(r, 'mesh', 'value'), enc)
  opt(w, 'CNAM', str(r, 'sound', 'value'), enc)
  opt(w, 'FNAM', str(r, 'name', 'value'), enc)
  opt(w, 'SCRI', str(r, 'script', 'value'), enc)
  local d = tab(r, 'data', 'value')
  header(w, 'NPDT', 96)
  Writer.u32(w, enum(Enums.CreatureType, d, 'creatureType', 'data'))
  for _, key in
    {
      'level',
      'strength',
      'intelligence',
      'willpower',
      'agility',
      'speed',
      'endurance',
      'personality',
      'luck',
      'health',
      'magicka',
      'fatigue',
      'soul',
      'combat',
      'magic',
      'stealth',
    }

  do
    Writer.u32(w, num(d, key, 'data'))
  end

  for _, key in { 'attack1', 'attack2', 'attack3' } do
    local pair = list(d, key, 'data')
    Writer.u32(w, numAt(pair, 1, `data.{key}`))
    Writer.u32(w, numAt(pair, 2, `data.{key}`))
  end

  Writer.u32(w, num(d, 'gold', 'data'))
  actorFlag(w, Flags.CreatureFlags, r, 'creatureFlags')
  local scale = r.scale :: number?
  if scale then
    local clamped, default = clampScale(scale)
    if not default then
      header(w, 'XSCL', 4)
      Writer.f32(w, clamped)
    end
  end

  inventory(w, r, enc)
  spells(w, r, enc)
  aiData(w, r)
  travel(w, r, enc)
  packages(w, r, enc)
  dele(w, bits)
end

Encoders.Npc = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  for _, pair in
    {
      { 'MODL', 'mesh' },
      { 'FNAM', 'name' },
      { 'RNAM', 'race' },
      { 'CNAM', 'class' },
      { 'ANAM', 'faction' },
      { 'BNAM', 'head' },
      { 'KNAM', 'hair' },
      { 'SCRI', 'script' },
    }

  do
    opt(w, pair[1], str(r, pair[2], 'value'), enc)
  end

  local d = tab(r, 'data', 'value')
  tag(w, 'NPDT')
  local stats = d.stats :: Value?
  if stats then
    Writer.u32(w, 52)
    Writer.u16(w, num(d, 'level', 'data') % 65536)
    u8s(w, list(stats, 'attributes', 'data.stats'), 8, 'data.stats.attributes')
    u8s(w, list(stats, 'skills', 'data.stats'), 27, 'data.stats.skills')
    Writer.zeros(w, 1)
    Writer.u16(w, num(stats, 'health', 'data.stats'))
    Writer.u16(w, num(stats, 'magicka', 'data.stats'))
    Writer.u16(w, num(stats, 'fatigue', 'data.stats'))
    Writer.u8(w, num(d, 'disposition', 'data') % 256)
    Writer.u8(w, num(d, 'reputation', 'data') % 256)
    Writer.u8(w, num(d, 'rank', 'data') % 256)
  else
    Writer.u32(w, 12)
    Writer.u16(w, num(d, 'level', 'data') % 65536)
    Writer.u8(w, num(d, 'disposition', 'data') % 256)
    Writer.u8(w, num(d, 'reputation', 'data') % 256)
    Writer.u8(w, num(d, 'rank', 'data') % 256)
    Writer.zeros(w, 2)
  end

  Writer.zeros(w, 1)
  Writer.u32(w, num(d, 'gold', 'data'))
  actorFlag(w, Flags.NpcFlags, r, 'npcFlags')
  inventory(w, r, enc)
  spells(w, r, enc)
  aiData(w, r)
  travel(w, r, enc)
  packages(w, r, enc)
  dele(w, bits)
end

Encoders.Bodypart = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  opt(w, 'MODL', str(r, 'mesh', 'value'), enc)
  opt(w, 'FNAM', str(r, 'race', 'value'), enc)
  local d = tab(r, 'data', 'value')
  header(w, 'BYDT', 4)
  Writer.u8(w, enum(Enums.BodypartId, d, 'part', 'data'))
  Writer.u8(w, if d.vampire then 1 else 0)
  Writer.u8(w, flags(Flags.BodypartFlags, d, 'flags', 'data'))
  Writer.u8(w, enum(Enums.BodypartType, d, 'bodypartType', 'data'))
  dele(w, bits)
end

Encoders.Light = function(w, r, enc, bits)
  itemHead(w, r, enc)
  opt(w, 'ITEX', str(r, 'icon', 'value'), enc)
  local d = tab(r, 'data', 'value')
  header(w, 'LHDT', 24)
  Writer.f32(w, num(d, 'weight', 'data'))
  Writer.u32(w, num(d, 'value', 'data'))
  Writer.i32(w, num(d, 'time', 'data'))
  Writer.u32(w, num(d, 'radius', 'data'))
  u8s(w, list(d, 'color', 'data'), 4, 'data.color')
  Writer.u32(w, flags(Flags.LightFlags, d, 'flags', 'data'))
  opt(w, 'SCRI', str(r, 'script', 'value'), enc)
  opt(w, 'SNAM', str(r, 'sound', 'value'), enc)
  dele(w, bits)
end

Encoders.Enchanting = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  local d = tab(r, 'data', 'value')
  header(w, 'ENDT', 16)
  Writer.u32(w, enum(Enums.EnchantType, d, 'enchantType', 'data'))
  Writer.u32(w, num(d, 'cost', 'data'))
  Writer.u32(w, num(d, 'maxCharge', 'data'))
  Writer.u32(w, flags(Flags.EnchantingFlags, d, 'flags', 'data'))
  effects(w, r)
  dele(w, bits)
end

Encoders.Armor = function(w, r, enc, bits)
  itemHead(w, r, enc)
  opt(w, 'SCRI', str(r, 'script', 'value'), enc)
  local d = tab(r, 'data', 'value')
  header(w, 'AODT', 24)
  Writer.u32(w, enum(Enums.ArmorType, d, 'armorType', 'data'))
  Writer.f32(w, num(d, 'weight', 'data'))
  for _, key in { 'value', 'health', 'enchantment', 'armorRating' } do
    Writer.u32(w, num(d, key, 'data'))
  end

  opt(w, 'ITEX', str(r, 'icon', 'value'), enc)
  bipedObjects(w, r, enc)
  opt(w, 'ENAM', str(r, 'enchanting', 'value'), enc)
  dele(w, bits)
end

Encoders.Clothing = function(w, r, enc, bits)
  itemHead(w, r, enc)
  local d = tab(r, 'data', 'value')
  header(w, 'CTDT', 12)
  Writer.u32(w, enum(Enums.ClothingType, d, 'clothingType', 'data'))
  Writer.f32(w, num(d, 'weight', 'data'))
  Writer.u16(w, num(d, 'value', 'data'))
  Writer.u16(w, num(d, 'enchantment', 'data'))
  itemTail(w, r, enc)
  bipedObjects(w, r, enc)
  opt(w, 'ENAM', str(r, 'enchanting', 'value'), enc)
  dele(w, bits)
end

Encoders.RepairItem = function(w, r, enc, bits)
  itemHead(w, r, enc)
  local d = tab(r, 'data', 'value')
  header(w, 'RIDT', 16)
  Writer.f32(w, num(d, 'weight', 'data'))
  Writer.u32(w, num(d, 'value', 'data'))
  Writer.u32(w, num(d, 'uses', 'data'))
  Writer.f32(w, num(d, 'quality', 'data'))
  itemTail(w, r, enc)
  dele(w, bits)
end

Encoders.Activator = function(w, r, enc, bits)
  itemHead(w, r, enc)
  opt(w, 'SCRI', str(r, 'script', 'value'), enc)
  dele(w, bits)
end

Encoders.Apparatus = function(w, r, enc, bits)
  itemHead(w, r, enc)
  opt(w, 'SCRI', str(r, 'script', 'value'), enc)
  local d = tab(r, 'data', 'value')
  header(w, 'AADT', 16)
  Writer.u32(w, enum(Enums.ApparatusType, d, 'apparatusType', 'data'))
  Writer.f32(w, num(d, 'quality', 'data'))
  Writer.f32(w, num(d, 'weight', 'data'))
  Writer.u32(w, num(d, 'value', 'data'))
  opt(w, 'ITEX', str(r, 'icon', 'value'), enc)
  dele(w, bits)
end

local function tool(dataTag: string): Encoder
  return function(w, r, enc, bits)
    itemHead(w, r, enc)
    local d = tab(r, 'data', 'value')
    header(w, dataTag, 16)
    Writer.f32(w, num(d, 'weight', 'data'))
    Writer.u32(w, num(d, 'value', 'data'))
    Writer.f32(w, num(d, 'quality', 'data'))
    Writer.u32(w, num(d, 'uses', 'data'))
    itemTail(w, r, enc)
    dele(w, bits)
  end
end

Encoders.Lockpick = tool 'LKDT'
Encoders.Probe = tool 'PBDT'

Encoders.Ingredient = function(w, r, enc, bits)
  itemHead(w, r, enc)
  local d = tab(r, 'data', 'value')
  header(w, 'IRDT', 56)
  Writer.f32(w, num(d, 'weight', 'data'))
  Writer.u32(w, num(d, 'value', 'data'))
  for _, pair in
    {
      { 'effects', Enums.EffectId },
      { 'skills', Enums.SkillId },
      { 'attributes', Enums.AttributeId },
    }

  do
    local key = pair[1] :: string
    for _, item in list(d, key, 'data') do
      Writer.i32(w, Schema.valueOf(pair[2] :: Schema.Enum, item, `data.{key}`))
    end
  end

  itemTail(w, r, enc)
  dele(w, bits)
end

Encoders.Book = function(w, r, enc, bits)
  itemHead(w, r, enc)
  local d = tab(r, 'data', 'value')
  header(w, 'BKDT', 20)
  Writer.f32(w, num(d, 'weight', 'data'))
  Writer.u32(w, num(d, 'value', 'data'))
  Writer.u32(w, enum(Enums.BookType, d, 'bookType', 'data'))
  Writer.i32(w, enum(Enums.SkillId, d, 'skill', 'data'))
  Writer.u32(w, num(d, 'enchantment', 'data'))
  itemTail(w, r, enc)
  local text = str(r, 'text', 'value')
  if text ~= '' then
    tag(w, 'TEXT')
    wExact(w, text, enc)
  end

  opt(w, 'ENAM', str(r, 'enchanting', 'value'), enc)
  dele(w, bits)
end

Encoders.Alchemy = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  opt(w, 'MODL', str(r, 'mesh', 'value'), enc)
  opt(w, 'TEXT', str(r, 'icon', 'value'), enc)
  opt(w, 'SCRI', str(r, 'script', 'value'), enc)
  opt(w, 'FNAM', str(r, 'name', 'value'), enc)
  local d = tab(r, 'data', 'value')
  header(w, 'ALDT', 12)
  Writer.f32(w, num(d, 'weight', 'data'))
  Writer.u32(w, num(d, 'value', 'data'))
  Writer.u32(w, flags(Flags.AlchemyFlags, d, 'flags', 'data'))
  effects(w, r)
  dele(w, bits)
end

local function leveled(
  flagField: string,
  set: Schema.Flags,
  listField: string,
  entryTag: string
): Encoder
  return function(w, r, enc, bits)
    sub(w, 'NAME', str(r, 'id', 'value'), enc)
    header(w, 'DATA', 4)
    Writer.u32(w, flags(set, r, flagField, 'value'))
    header(w, 'NNAM', 1)
    Writer.u8(w, num(r, 'chanceNone', 'value'))
    local entries = list(r, listField, 'value')
    if #entries > 0 then
      header(w, 'INDX', 4)
      Writer.u32(w, #entries)
      for i, item in entries do
        local pair = item :: { unknown }
        sub(w, entryTag, pair[1] :: string, enc)
        header(w, 'INTV', 2)
        Writer.u16(w, numAt(pair, 2, `{listField}[{i}]`))
      end
    end

    dele(w, bits)
  end
end

Encoders.LeveledItem = leveled('leveledItemFlags', Flags.LeveledItemFlags, 'items', 'INAM')
Encoders.LeveledCreature =
  leveled('leveledCreatureFlags', Flags.LeveledCreatureFlags, 'creatures', 'CNAM')

--[[ CELL ]]

local function persistent(ref: Value): boolean
  return ref.movedCell ~= nil or ref.destination ~= nil or not ref.temporary
end

local function reference(w: W, ref: Value, enc: string, path: string)
  sub(w, 'NAME', str(ref, 'id', path), enc)
  local blocked = ref.blocked :: number?
  if blocked then
    header(w, 'UNAM', 1)
    Writer.u8(w, blocked)
  end

  local scale = ref.scale :: number?
  if scale then
    local clamped, default = clampScale(scale)
    if not default or num(ref, 'mastIndex', path) ~= 0 then
      header(w, 'XSCL', 4)
      Writer.f32(w, clamped)
    end
  end

  for _, pair in { { 'ANAM', 'owner' }, { 'BNAM', 'ownerGlobal' }, { 'CNAM', 'ownerFaction' } } do
    local value = ref[pair[2]] :: string?
    if value then sub(w, pair[1], value, enc) end
  end

  local rank = ref.ownerFactionRank :: number?
  if rank then
    header(w, 'INDX', 4)
    Writer.u32(w, rank)
  end

  local soul = ref.soul :: string?
  if soul then sub(w, 'XSOL', soul, enc) end

  local charge = ref.chargeLeft :: number?
  if charge then
    header(w, 'XCHG', 4)
    Writer.u32(w, charge)
  end

  local health = ref.healthLeft :: number?
  if health then
    header(w, 'INTV', 4)
    Writer.i32(w, health)
  end

  local count = ref.objectCount :: number?
  if count then
    header(w, 'NAM9', 4)
    Writer.u32(w, count)
  end

  local destination = ref.destination :: Value?
  if destination then
    header(w, 'DODT', 24)
    f32s(w, list(destination, 'translation', path), 3, `{path}.destination.translation`)
    f32s(w, list(destination, 'rotation', path), 3, `{path}.destination.rotation`)
    opt(w, 'DNAM', str(destination, 'cell', path), enc)
  end

  local lock = ref.lockLevel :: number?
  if lock then
    header(w, 'FLTV', 4)
    Writer.i32(w, lock)
  end

  for _, pair in { { 'KNAM', 'key' }, { 'TNAM', 'trap' } } do
    local value = ref[pair[2]] :: string?
    if value then sub(w, pair[1], value, enc) end
  end

  if ref.deleted ~= nil then
    header(w, 'DELE', 4)
    Writer.u32(w, 0)
  else
    header(w, 'DATA', 24)
    f32s(w, list(ref, 'translation', path), 3, `{path}.translation`)
    f32s(w, list(ref, 'rotation', path), 3, `{path}.rotation`)
  end
end

Encoders.Cell = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'name', 'value'), enc)
  local d = tab(r, 'data', 'value')
  header(w, 'DATA', 12)
  Writer.u32(w, flags(Flags.CellFlags, d, 'flags', 'data'))
  i32s(w, list(d, 'grid', 'data'), 2, 'data.grid')
  local region = r.region :: string?
  if region then sub(w, 'RGNN', region, enc) end

  local color = r.mapColor :: { unknown }?
  if color then
    header(w, 'NAM5', 4)
    u8s(w, color, 4, 'mapColor')
  end

  local water = r.waterHeight :: number?
  if water then
    header(w, 'WHGT', 4)
    Writer.f32(w, water)
  end

  local atmosphere = r.atmosphereData :: Value?
  if atmosphere then
    header(w, 'AMBI', 16)
    u8s(w, list(atmosphere, 'ambientColor', 'atmosphereData'), 4, 'atmosphereData.ambientColor')
    u8s(w, list(atmosphere, 'sunlightColor', 'atmosphereData'), 4, 'atmosphereData.sunlightColor')
    u8s(w, list(atmosphere, 'fogColor', 'atmosphereData'), 4, 'atmosphereData.fogColor')
    Writer.f32(w, num(atmosphere, 'fogDensity', 'atmosphereData'))
  end

  dele(w, bits)
  -- Keyed by (master, index) as the Rust HashMap is: a later duplicate replaces an earlier one.
  local byKey: { [number]: Value } = {}
  for i, item in list(r, 'references', 'value') do
    local ref = item :: Value
    local path = `references[{i}]`
    byKey[num(ref, 'mastIndex', path) * 16777216 + num(ref, 'refrIndex', path)] = ref
  end

  local sorted: { Value } = {}
  for _, ref in byKey do
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

  local temporary = 0
  for i, ref in sorted do
    local path = `references[{i}]`
    local packed =
      bit32.bor(num(ref, 'refrIndex', path), bit32.lshift(num(ref, 'mastIndex', path), 24))
    if temporary == 0 and not persistent(ref) then
      temporary = #sorted - i + 1
      header(w, 'NAM0', 4)
      Writer.u32(w, temporary)
    end

    local moved = ref.movedCell :: { unknown }?
    if moved then
      header(w, 'MVRF', 4)
      Writer.u32(w, packed)
      header(w, 'CNDT', 8)
      i32s(w, moved, 2, `{path}.movedCell`)
    end

    header(w, 'FRMR', 4)
    Writer.u32(w, packed)
    reference(w, ref, enc, path)
  end
end

--[[ LAND ]]

local function landBlob(w: W, t: Value, path: string, size: number)
  local data = Schema.unbase64(str(t, 'data', path), `{path}.data`)
  if buffer.len(data) ~= size then
    fail(`{path}.data: expected {size} bytes, got {buffer.len(data)}`)
  end

  Writer.copy(w, data, 0, size)
end

Encoders.Landscape = function(w, r, _enc, bits)
  header(w, 'INTV', 8)
  i32s(w, list(r, 'grid', 'value'), 2, 'grid')
  local land = flags(Flags.LandscapeFlags, r, 'landscapeFlags', 'value')
  header(w, 'DATA', 4)
  Writer.u32(w, land)
  if bit32.btest(land, 1) then
    header(w, 'VNML', 12675)
    landBlob(w, tab(r, 'vertexNormals', 'value'), 'vertexNormals', 12675)
    local heights = tab(r, 'vertexHeights', 'value')
    header(w, 'VHGT', 4232)
    Writer.f32(w, num(heights, 'offset', 'vertexHeights'))
    landBlob(w, heights, 'vertexHeights', 4225)
    Writer.zeros(w, 3)
  end

  if bit32.btest(land, 7) then
    header(w, 'WNAM', 81)
    landBlob(w, tab(r, 'worldMapData', 'value'), 'worldMapData', 81)
  end

  if bit32.btest(land, 2) then
    header(w, 'VCLR', 12675)
    landBlob(w, tab(r, 'vertexColors', 'value'), 'vertexColors', 12675)
  end

  if bit32.btest(land, 4) then
    header(w, 'VTEX', 512)
    landBlob(w, tab(r, 'textureIndices', 'value'), 'textureIndices', 512)
  end

  dele(w, bits)
end

--[[ PGRD ]]

Encoders.PathGrid = function(w, r, enc, bits)
  local d = tab(r, 'data', 'value')
  header(w, 'DATA', 12)
  i32s(w, list(d, 'grid', 'data'), 2, 'data.grid')
  Writer.u16(w, num(d, 'granularity', 'data'))
  Writer.u16(w, num(d, 'pointCount', 'data'))
  sub(w, 'NAME', str(r, 'cell', 'value'), enc)
  local points = list(r, 'points', 'value')
  if #points > 0 then
    header(w, 'PGRP', #points * 16)
    for i, item in points do
      local point = item :: Value
      local path = `points[{i}]`
      i32s(w, list(point, 'location', path), 3, `{path}.location`)
      Writer.u8(w, num(point, 'autoGenerated', path))
      Writer.u8(w, num(point, 'connectionCount', path))
      Writer.zeros(w, 2)
    end
  end

  local connections = Schema.unbase64(str(r, 'connections', 'value'), 'connections')
  local count = if buffer.len(connections) >= 4 then buffer.readu32(connections, 0) else 0
  if count > 0 then
    header(w, 'PGRC', count * 4)
    Writer.copy(w, connections, 4, count * 4)
  end

  dele(w, bits)
end

--[[ DIAL and INFO ]]

Encoders.Dialogue = function(w, r, enc, bits)
  sub(w, 'NAME', str(r, 'id', 'value'), enc)
  header(w, 'DATA', 1)
  Writer.u8(w, enum(Enums.DialogueType, r, 'dialogueType', 'value'))
  dele(w, bits)
end

local QuestTags = { Name = 'QSTN', Finished = 'QSTF', Restart = 'QSTR' }

Encoders.DialogueInfo = function(w, r, enc, bits)
  sub(w, 'INAM', str(r, 'id', 'value'), enc)
  sub(w, 'PNAM', str(r, 'prevId', 'value'), enc)
  sub(w, 'NNAM', str(r, 'nextId', 'value'), enc)
  local d = tab(r, 'data', 'value')
  header(w, 'DATA', 12)
  Writer.u32(w, enum(Enums.DialogueType, d, 'dialogueType', 'data'))
  Writer.i32(w, num(d, 'disposition', 'data'))
  Writer.u8(w, num(d, 'speakerRank', 'data') % 256)
  Writer.u8(w, enum(Enums.Sex, d, 'speakerSex', 'data') % 256)
  Writer.u8(w, num(d, 'playerRank', 'data') % 256)
  Writer.zeros(w, 1)
  for _, pair in
    {
      { 'ONAM', 'speakerId' },
      { 'RNAM', 'speakerRace' },
      { 'CNAM', 'speakerClass' },
      { 'FNAM', 'speakerFaction' },
      { 'ANAM', 'speakerCell' },
      { 'DNAM', 'playerFaction' },
      { 'SNAM', 'soundPath' },
    }

  do
    opt(w, pair[1], str(r, pair[2], 'value'), enc)
  end

  local text = str(r, 'text', 'value')
  if text ~= '' then
    tag(w, 'NAME')
    wExact(w, text, enc)
  end

  local state = r.questState :: string?
  if state then
    local name = QuestTags[state]
    if not name then
      fail(`value.questState: unknown variant '{state}', expected one of Finished, Name, Restart`)
    end

    header(w, name, 1)
    Writer.u8(w, 1)
  end

  for i, item in list(r, 'filters', 'value') do
    local filter = item :: Value
    local path = `filters[{i}]`
    local index = num(filter, 'index', path)
    if index + 48 > 255 then fail 'DialogueInfo: Invalid filter index' end

    local id = encodeText(str(filter, 'id', path), enc)
    tag(w, 'SCVR')
    Writer.u32(w, #id + 5)
    Writer.u8(w, index + 48)
    Writer.u8(w, enum(Enums.FilterType, filter, 'filterType', path))
    Writer.u16(w, enum(Enums.FilterFunction, filter, 'function', path))
    Writer.u8(w, enum(Enums.FilterComparison, filter, 'comparison', path))
    Writer.string(w, id)
    local value = tab(filter, 'value', path)
    if value.type == 'Integer' then
      header(w, 'INTV', 4)
      Writer.i32(w, num(value, 'data', path))
    elseif value.type == 'Float' then
      header(w, 'FLTV', 4)
      Writer.f32(w, num(value, 'data', path))
    else
      fail(
        `{path}.value.type: unknown variant '{tostring(value.type)}', expected one of Float, Integer`
      )
    end
  end

  local script = str(r, 'scriptText', 'value')
  if script ~= '' then
    tag(w, 'BNAM')
    wExact(w, script, enc)
  end

  dele(w, bits)
end

--[[ LUAL ]]

--- A LUAD blob: the bytes after its length, given the base64 of both.
local function luaData(w: W, text: string, path: string)
  local data = Schema.unbase64(text, path)
  local length = if buffer.len(data) >= 4 then buffer.readu32(data, 0) else 0
  if length == 0 then return end

  tag(w, 'LUAD')
  Writer.u32(w, length)
  Writer.copy(w, data, 4, length)
end

Encoders.ScriptConfigList = function(w, r, enc)
  for i, item in list(r, 'scripts', 'value') do
    local config = item :: Value
    local path = `scripts[{i}]`
    local scriptPath = encodeText(str(config, 'path', path), enc)
    tag(w, 'LUAS')
    Writer.u32(w, #scriptPath)
    Writer.string(w, scriptPath)
    local types = list(config, 'types', path)
    tag(w, 'LUAF')
    Writer.u32(w, 4 + 4 * #types)
    Writer.u32(w, flags(Flags.OMWScriptAttachFlag, config, 'flags', path))
    for _, kind in types do
      Writer.string(w, kind :: string)
    end

    luaData(w, str(config, 'initData', path), `{path}.initData`)
    for k, entry in list(config, 'records', path) do
      local record = entry :: Value
      local id = str(record, 'id', `{path}.records[{k}]`)
      tag(w, 'LUAR')
      Writer.u32(w, #id + 1)
      Writer.u8(w, if record.attach then 1 else 0)
      Writer.string(w, id)
      luaData(w, str(record, 'data', `{path}.records[{k}]`), `{path}.records[{k}].data`)
    end

    for k, entry in list(config, 'instances', path) do
      local instance = entry :: Value
      local at = `{path}.instances[{k}]`
      tag(w, 'LUAI')
      Writer.u32(w, 9)
      Writer.u8(w, if instance.attach then 1 else 0)
      Writer.u32(w, num(instance, 'refIdx', at))
      Writer.i32(w, num(instance, 'mastIdx', at))
      luaData(w, str(instance, 'data', at), `{at}.data`)
    end
  end
end

--[[ Records ]]

local TagsByName: { [string]: string } = {}
for _, entry in Decode.specs do
  TagsByName[entry.name] = entry.tag
end

--- A record value's bytes, header included, text in `enc`. `value.type` names its record type.
local function encode(value: Value, enc: string?): buffer
  local encoding = enc or 'win1252'
  local name = value.type
  if type(name) ~= 'string' then
    return fail(`value.type: expected a record type name, got {type(name)}`)
  end

  local recordTag = TagsByName[name]
  local encoder = Encoders[name]
  if not recordTag or not encoder then return fail(`unknown record type '{name}'`) end

  local record = merge(Decode.default(name), value) :: Value
  local bits = Schema.flagBits(Flags.ObjectFlags, record.flags, 'value.flags')
  local w = Writer.new(256)
  tag(w, recordTag)
  Writer.u32(w, 0)
  Writer.u32(w, 0)
  Writer.u32(w, bits)
  encoder(w, record, encoding, bits)
  local out = Writer.finish(w)
  buffer.writeu32(out, 4, buffer.len(out) - 16)
  return out
end

return table.freeze { encode = encode, merge = merge }
