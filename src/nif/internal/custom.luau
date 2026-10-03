--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The fields whose layout the schema can't say: keyframe unions, bounding volumes, texture maps
and sources, sequence targets, shared normals, and UV sets. Each codec comes as `read`
(`(b, p, ...) -> (value, p)`), `write` (`(w, value, map, ...)`), and, when it holds links,
`links` (`(value, links, n) -> n`), the shapes the record modules have for the rest; their
scanners are `custom_scan.luau`.
]]

local Array = require './array'
local Enums = require './enums'
local Text = require './text'
local Types = require './types'
local Writer = require './writer'

type Writer = Writer.Writer
type Map = { [number]: number }
type Links = { number }
type Array = Array.Array

local Names, Values = Enums.names, Enums.values
local Spellings: dream_intern_Pool = Text.pool
local Strings = Text.decoded

local function enumName(names: { [number]: string }, value: number): string | number
  return names[value] or value
end

local function enumValue(values: { [string]: number }, value: string | number): number
  if type(value) == 'number' then return value end

  local number = values[value]
  if not number then error(`unknown enum value '{value}'`, 0) end

  return number
end

--- A u32 length and the bytes, cut at the first NUL the way OpenMW reads names. The whole field
--- is interned (in native code), and cut and decoded once per spelling.
local function readString(b: buffer, p: number): (string, number)
  local length = buffer.readu32(b, p)
  if length == 0 then return '', p + 4 end

  local token = Spellings:intern(b, p + 4, length)
  local text = Strings[token]
  if not text then
    text = Text.cut(b, p + 4, length)
    Strings[token] = text
  end

  return text, p + 4 + length
end

local function readLink(b: buffer, p: number): number?
  local value = buffer.readi32(b, p)
  if value < 0 then return nil end

  return value
end

local function readVec3(b: buffer, p: number): vector
  return vector.create(buffer.readf32(b, p), buffer.readf32(b, p + 4), buffer.readf32(b, p + 8))
end

--- Writes a float, flagging the writer when it is NaN (see `restoreNans` in `init.luau`).
local function writeF32(w: Writer, p: number, value: number)
  buffer.writef32(w.b, p, value)
  if value ~= value then w.nan = true end
end

local function writeVec3(w: Writer, p: number, value: vector)
  writeF32(w, p, value.x)
  writeF32(w, p + 4, value.y)
  writeF32(w, p + 8, value.z)
end

--- The identity rotation, shared by every record that stores exactly it (the record modules test
--- the bits): most do. Frozen, so edit a record's rotation by giving it a new table.
local Identity =
  table.freeze { vector.create(1, 0, 0), vector.create(0, 1, 0), vector.create(0, 0, 1) }

--- An array, as far as these codecs need: its bytes and where they are.
type View = Array.ArrayFields

--- A key union: one array under the name of its interpolation. `types.luau` names each union's
--- array kinds (`FloatKeys`, `PosKeys`, ...); the codecs only need that it is an array.
type KeyUnion = { LinKey: View?, BezKey: View?, TCBKey: View? }

--- Euler rotation keys: three float curves and the order they apply in (a name, or the number
--- when the file holds one no name has).
type Euler = { axisOrder: string | number, axes: { { keys: KeyUnion } } }

type RotUnion = { LinKey: View?, BezKey: View?, TCBKey: View?, EulerKey: Euler? }

--- The keys of a union, as its key type and array.
local function keysOf(value: KeyUnion | RotUnion): (number, View)
  if value.LinKey then return 1, value.LinKey end

  if value.BezKey then return 2, value.BezKey end

  if value.TCBKey then return 3, value.TCBKey end

  return 1, Array.empty.floatLin
end

--- The union holding `keys` under key type `kind`'s name.
local function unionOf(kind: number, keys: View): KeyUnion
  if kind == 2 then return { BezKey = keys } end

  if kind == 3 then return { TCBKey = keys } end

  return { LinKey = keys }
end

local function invalidKeyType(kind: number): never
  local name = Names.KeyType[kind] or 'NoInterp'
  error(`Invalid KeyType: {name}`, 0)
end

--- Writes a key array: its count, its kind unless it is empty (or `always`), and its bytes.
local function writeKeys(w: Writer, kind: number, keys: View, always: boolean?)
  local count = keys.count
  Writer.reserve(w, 8)
  buffer.writeu32(w.b, w.p, count)
  if count == 0 and not always then
    w.p += 4
    return
  end

  buffer.writeu32(w.b, w.p + 4, kind)
  w.p += 8
  Array.write(w, keys)
end

type KeyCodec = {
  read: (b: buffer, p: number) -> (KeyUnion, number),
  write: (w: Writer, value: KeyUnion, map: Map) -> (),
}

--- One key union's codec: `kinds` maps a key type to its array kind.
local function keyUnion(kinds: { Array.Kind }, always: boolean?): KeyCodec
  local function read(b: buffer, p: number): (KeyUnion, number)
    local count = buffer.readu32(b, p)
    local kind = if count == 0 and not always then 1 else buffer.readu32(b, p + 4)
    local start = if always or count > 0 then p + 8 else p + 4
    local arrayKind = kinds[kind]
    if not arrayKind then
      if count == 0 then return { LinKey = Array.empty[kinds[1]] }, start end

      invalidKeyType(kind)
    end

    return unionOf(kind, Array.view(b, start, count, arrayKind)),
      start + count * Array.strides[arrayKind]
  end

  local function write(w: Writer, value: KeyUnion, _map: Map)
    local kind, keys = keysOf(value)
    writeKeys(w, kind, keys, always)
  end

  return { read = read, write = write }
end

-- Float keys: time and value, then tangents (bez) or tension, continuity, bias (tcb).
local floatKeys = keyUnion { 'floatLin', 'floatBez', 'floatTcb' }

-- Morph target keys always carry their kind, even with no keys.
local morphKeys = keyUnion({ 'floatLin', 'floatBez', 'floatTcb' }, true)

-- Position keys: a vector value, with vector tangents (bez) or tension, continuity, bias (tcb).
local posKeys = keyUnion { 'posLin', 'posBez', 'posTcb' }

-- Color keys: linear only, time and r, g, b, a.
local colorKeys = keyUnion { 'colorLin' }

-- Rotation keys: a quaternion (stored w first; read x, y, z, w), or Euler angles as three float
-- curves. Bezier rotation keys carry no tangents.
local quaternionKeys = keyUnion { 'rotLin', 'rotLin', 'rotTcb' }
local rotKeys = {}

function rotKeys.read(b: buffer, p: number): (RotUnion, number)
  if buffer.readu32(b, p) == 0 or buffer.readu32(b, p + 4) ~= 4 then
    local keys, after = quaternionKeys.read(b, p)
    return { LinKey = keys.LinKey, BezKey = keys.BezKey, TCBKey = keys.TCBKey }, after
  end

  local axisOrder = enumName(Names.AxisOrder, buffer.readi32(b, p + 8))
  local x, y, z
  x, p = floatKeys.read(b, p + 12)
  y, p = floatKeys.read(b, p)
  z, p = floatKeys.read(b, p)
  return {
    EulerKey = { axisOrder = axisOrder, axes = { { keys = x }, { keys = y }, { keys = z } } },
  },
    p
end

--- Euler keys save a count of one when any axis has keys, else none.
local function eulerCount(euler: Euler): number
  for _, axis in euler.axes do
    local _, keys = keysOf(axis.keys)
    if keys.count > 0 then return 1 end
  end

  return 0
end

function rotKeys.write(w: Writer, value: RotUnion, map: Map)
  local euler = value.EulerKey
  if not euler then
    local kind, keys = keysOf(value)
    writeKeys(w, kind, keys)
    return
  end

  local count = eulerCount(euler)
  Writer.reserve(w, 12)
  buffer.writeu32(w.b, w.p, count)
  if count == 0 then
    w.p += 4
    return
  end

  buffer.writeu32(w.b, w.p + 4, 4)
  buffer.writei32(w.b, w.p + 8, enumValue(Values.AxisOrder, euler.axisOrder))
  w.p += 12
  for _, axis in euler.axes do
    floatKeys.write(w, axis.keys, map)
  end
end

-- Bounding volumes: a sphere, an oriented box, or a union of volumes.
local boundingVolume = {}

function boundingVolume.read(b: buffer, p: number): (Types.BoundingVolume, number)
  local kind = buffer.readi32(b, p)
  p += 4
  if kind == 0 then
    local bound = { center = readVec3(b, p), radius = buffer.readf32(b, p + 12) }
    return { boundData = { NiSphereBV = { bound = bound } } }, p + 16
  elseif kind == 1 then
    local box = {
      center = readVec3(b, p),
      axis = { readVec3(b, p + 12), readVec3(b, p + 24), readVec3(b, p + 36) },
      extents = readVec3(b, p + 48),
    }
    return { boundData = { NiBoxBV = box } }, p + 60
  elseif kind == 4 then
    local count = buffer.readu32(b, p)
    p += 4
    local volumes = table.create(count) :: { Types.BoundingVolume }
    for i = 1, count do
      volumes[i], p = boundingVolume.read(b, p)
    end

    return { boundData = { NiUnionBV = { boundingVolumes = volumes } } }, p
  end

  error(`Invalid BoundType: {Names.BoundType[kind] or 'Sphere'}`, 0)
end

function boundingVolume.write(w: Writer, value: Types.BoundingVolume, map: Map)
  local data = value.boundData
  Writer.reserve(w, 64)
  local b, p = w.b, w.p
  local sphere, box, union = data.NiSphereBV, data.NiBoxBV, data.NiUnionBV
  if sphere then
    local bound = sphere.bound
    buffer.writei32(b, p, 0)
    writeVec3(w, p + 4, bound.center)
    writeF32(w, p + 16, bound.radius)
    w.p = p + 20
  elseif box then
    buffer.writei32(b, p, 1)
    writeVec3(w, p + 4, box.center)
    writeVec3(w, p + 16, box.axis[1])
    writeVec3(w, p + 28, box.axis[2])
    writeVec3(w, p + 40, box.axis[3])
    writeVec3(w, p + 52, box.extents)
    w.p = p + 64
  elseif union then
    local volumes = union.boundingVolumes
    buffer.writei32(b, p, 4)
    buffer.writeu32(b, p + 4, #volumes)
    w.p = p + 8
    for _, volume in volumes do
      boundingVolume.write(w, volume, map)
    end
  end
end

-- Texture maps: a count of slots, each a flag and a map. Slot 5 is the bump map; the rest are
-- named base, dark, detail, gloss, glow, and decals from 6 on.
--- A slot's map; enums are their names, or numbers no name has. `types.luau` has the names.
type TextureMap = {
  texture: number?,
  clampMode: string | number,
  filterMode: string | number,
  textureIndex: number,
  ps2L: number,
  ps2K: number,
  unknownFlag1: number,
  unknownFlag2: number,
  lumaScale: number?,
  lumaOffset: number?,
  displacement: { number }?,
}

type TextureMaps = {
  slots: number,
  base: TextureMap?,
  dark: TextureMap?,
  detail: TextureMap?,
  gloss: TextureMap?,
  glow: TextureMap?,
  bump: TextureMap?,
  decals: { TextureMap | false }?,
}
local BumpSlot = 5

local function readMap(b: buffer, p: number, bump: boolean): (TextureMap, number)
  local map: TextureMap = {
    texture = readLink(b, p),
    clampMode = enumName(Names.ClampMode, buffer.readi32(b, p + 4)),
    filterMode = enumName(Names.FilterMode, buffer.readi32(b, p + 8)),
    textureIndex = buffer.readu32(b, p + 12),
    ps2L = buffer.readi16(b, p + 16),
    ps2K = buffer.readi16(b, p + 18),
    unknownFlag1 = buffer.readu8(b, p + 20),
    unknownFlag2 = buffer.readu8(b, p + 21),
  }

  if not bump then return map, p + 22 end

  map.lumaScale = buffer.readf32(b, p + 22)
  map.lumaOffset = buffer.readf32(b, p + 26)
  map.displacement = {
    buffer.readf32(b, p + 30),
    buffer.readf32(b, p + 34),
    buffer.readf32(b, p + 38),
    buffer.readf32(b, p + 42),
  }
  return map, p + 46
end

local function writeMap(w: Writer, map: TextureMap, links: Map, bump: boolean)
  Writer.reserve(w, 50)
  local b, p = w.b, w.p
  buffer.writeu32(b, p, 1)
  buffer.writei32(b, p + 4, Writer.link(map.texture, links))
  buffer.writei32(b, p + 8, enumValue(Values.ClampMode, map.clampMode or 'WrapSWrapT'))
  buffer.writei32(b, p + 12, enumValue(Values.FilterMode, map.filterMode or 'Trilerp'))
  buffer.writeu32(b, p + 16, map.textureIndex or 0)
  buffer.writei16(b, p + 20, map.ps2L or 0)
  buffer.writei16(b, p + 22, map.ps2K or -75)
  buffer.writeu8(b, p + 24, map.unknownFlag1 or 0)
  buffer.writeu8(b, p + 25, map.unknownFlag2 or 0)
  if not bump then
    w.p = p + 26
    return
  end

  local displacement = map.displacement or { 1, 0, 0, 1 }
  writeF32(w, p + 26, map.lumaScale or 0)
  writeF32(w, p + 30, map.lumaOffset or 0)
  writeF32(w, p + 34, displacement[1])
  writeF32(w, p + 38, displacement[2])
  writeF32(w, p + 42, displacement[3])
  writeF32(w, p + 46, displacement[4])
  w.p = p + 50
end

local textureMaps = {}

function textureMaps.read(b: buffer, p: number): (TextureMaps, number)
  local count = buffer.readu32(b, p)
  p += 4
  local maps: TextureMaps = { slots = count }
  local decals: { TextureMap | false } = {}
  for slot = 0, count - 1 do
    local present = buffer.readu32(b, p) ~= 0
    p += 4
    local map
    if present then
      map, p = readMap(b, p, slot == BumpSlot)
    end

    if slot == 0 then
      maps.base = map
    elseif slot == 1 then
      maps.dark = map
    elseif slot == 2 then
      maps.detail = map
    elseif slot == 3 then
      maps.gloss = map
    elseif slot == 4 then
      maps.glow = map
    elseif slot == BumpSlot then
      maps.bump = map
    else
      decals[slot - BumpSlot] = map or false
    end
  end

  while #decals > 0 and not decals[#decals] do
    decals[#decals] = nil
  end

  if #decals > 0 then maps.decals = decals end

  return maps, p
end

--- The map in a slot: 0 to 4 by name, 5 the bump map, the decals after.
local function slotMap(maps: TextureMaps, slot: number): TextureMap?
  if slot == 0 then return maps.base end

  if slot == 1 then return maps.dark end

  if slot == 2 then return maps.detail end

  if slot == 3 then return maps.gloss end

  if slot == 4 then return maps.glow end

  if slot == BumpSlot then return maps.bump end

  local decals = maps.decals
  return decals and decals[slot - BumpSlot] or nil
end

--- How many slots to write: at least the file's count, and enough for every map.
local function slotCount(maps: TextureMaps): number
  local used = 0
  local decals = maps.decals
  if decals then
    for index = #decals, 1, -1 do
      if decals[index] then
        used = BumpSlot + index + 1
        break
      end
    end
  end

  if used == 0 then
    for slot = BumpSlot, 0, -1 do
      if slotMap(maps, slot) then
        used = slot + 1
        break
      end
    end
  end

  return math.max(maps.slots or 0, used)
end

function textureMaps.write(w: Writer, value: TextureMaps, map: Map)
  local count = slotCount(value)
  Writer.reserve(w, 4)
  buffer.writeu32(w.b, w.p, count)
  w.p += 4
  for slot = 0, count - 1 do
    local entry = slotMap(value, slot)
    if entry then
      writeMap(w, entry, map, slot == BumpSlot)
    else
      Writer.reserve(w, 4)
      buffer.writeu32(w.b, w.p, 0)
      w.p += 4
    end
  end
end

function textureMaps.links(value: TextureMaps, links: Links, n: number): number
  for slot = 0, slotCount(value) - 1 do
    local entry = slotMap(value, slot)
    local texture = entry and entry.texture
    if texture then
      n += 1
      links[n] = texture
    end
  end

  return n
end

-- A texture's source: an external file name, or an internal NiPixelData link.
local textureSource = {}

function textureSource.read(b: buffer, p: number): (Types.TextureSource, number)
  if buffer.readu8(b, p) ~= 0 then
    local name
    name, p = readString(b, p + 1)
    return { external = name }, p
  end

  if buffer.readu8(b, p + 1) ~= 0 then return { internal = readLink(b, p + 2) }, p + 6 end

  return {}, p + 2
end

function textureSource.write(w: Writer, value: Types.TextureSource, map: Map)
  Writer.reserve(w, 6)
  local external = value.external
  if external then
    buffer.writeu8(w.b, w.p, 1)
    w.p += 1
    Writer.string(w, external)
    return
  end

  buffer.writeu8(w.b, w.p, 0)
  local internal = value.internal
  if internal == nil then
    buffer.writeu8(w.b, w.p + 1, 0)
    w.p += 2
    return
  end

  buffer.writeu8(w.b, w.p + 1, 1)
  buffer.writei32(w.b, w.p + 2, Writer.link(internal, map))
  w.p += 6
end

function textureSource.links(value: Types.TextureSource, links: Links, n: number): number
  local internal = value.internal
  if internal == nil then return n end

  n += 1
  links[n] = internal
  return n
end

-- A sequence's target: an external file name, or two numbers.
local sequenceTarget = {}

function sequenceTarget.read(b: buffer, p: number): (Types.SequenceTarget, number)
  if buffer.readu8(b, p) ~= 0 then
    local name
    name, p = readString(b, p + 1)
    return { External = name }, p
  end

  return { Internal = { buffer.readi32(b, p + 1), buffer.readi32(b, p + 5) } }, p + 9
end

function sequenceTarget.write(w: Writer, value: Types.SequenceTarget, _map: Map)
  Writer.reserve(w, 9)
  local external = value.External
  if external then
    buffer.writeu8(w.b, w.p, 1)
    w.p += 1
    Writer.string(w, external)
    return
  end

  local internal = value.Internal :: { number }
  buffer.writeu8(w.b, w.p, 0)
  buffer.writei32(w.b, w.p + 1, internal[1])
  buffer.writei32(w.b, w.p + 5, internal[2])
  w.p += 9
end

-- A sequence's controllers: { name, controller index } pairs.
local nameControllerPairs = {}

--- A name and a controller index.
type Pair = { string | number }

function nameControllerPairs.read(b: buffer, p: number): ({ Pair }, number)
  local count = buffer.readu32(b, p)
  p += 4
  local pairs = table.create(count) :: { Pair }
  for i = 1, count do
    local name
    name, p = readString(b, p)
    pairs[i] = { name, buffer.readi32(b, p) }
    p += 4
  end

  return pairs, p
end

function nameControllerPairs.write(w: Writer, value: { Pair }, _map: Map)
  Writer.reserve(w, 4)
  buffer.writeu32(w.b, w.p, #value)
  w.p += 4
  for _, pair in value do
    Writer.string(w, pair[1] :: string)
    Writer.reserve(w, 4)
    buffer.writei32(w.b, w.p, pair[2] :: number)
    w.p += 4
  end
end

--- The one empty list of arrays, frozen, for the many records with no UV sets or shared normals.
local NoViews: { View } = table.freeze({} :: { View })

-- Shared normals: a u16 count of lists, each a u16 count of u16 vertex indices.
local sharedNormals = {}

function sharedNormals.read(b: buffer, p: number): ({ View }, number)
  local count = buffer.readu16(b, p)
  p += 2
  if count == 0 then return NoViews, p end

  local lists = table.create(count) :: { View }
  for i = 1, count do
    local length = buffer.readu16(b, p)
    lists[i] = Array.view(b, p + 2, length, 'u16')
    p += 2 + length * 2
  end

  return lists, p
end

function sharedNormals.write(w: Writer, value: { View }, _map: Map)
  Writer.reserve(w, 2)
  buffer.writeu16(w.b, w.p, #value)
  w.p += 2
  for _, indices in value do
    Writer.reserve(w, 2)
    buffer.writeu16(w.b, w.p, indices.count)
    w.p += 2
    Array.write(w, indices)
  end
end

-- UV sets: `sets` arrays of `vertices` coordinates, stored one set after another.
local uvSets = {}

function uvSets.read(b: buffer, p: number, sets: number, vertices: number): ({ View }, number)
  if sets * vertices == 0 then return NoViews, p end

  local lists = table.create(sets) :: { View }
  for set = 1, sets do
    lists[set] = Array.view(b, p, vertices, 'vec2')
    p += vertices * 8
  end

  return lists, p
end

function uvSets.write(w: Writer, value: { View }, _map: Map)
  for _, coordinates in value do
    Array.write(w, coordinates)
  end
end

--- The parts of a geometry record its UV set count is worked out from.
type Geometry = { vertices: View, uvSets: { View } }

local function uvSetTotal(r: Geometry): number
  local total = 0
  for _, coordinates in r.uvSets do
    total += coordinates.count
  end

  return total
end

--- How many sets the saved record says it has: the coordinates over the vertices.
local function uvSetCount(r: Geometry): number
  local vertices = r.vertices.count
  if vertices == 0 then return 0 end

  return uvSetTotal(r) // vertices
end

return table.freeze {
  identity = Identity,
  enumValue = enumValue,
  uvSetTotal = uvSetTotal,
  uvSetCount = uvSetCount,
  floatKeys = floatKeys,
  morphKeys = morphKeys,
  posKeys = posKeys,
  rotKeys = rotKeys,
  colorKeys = colorKeys,
  boundingVolume = boundingVolume,
  textureMaps = textureMaps,
  textureSource = textureSource,
  sequenceTarget = sequenceTarget,
  nameControllerPairs = nameControllerPairs,
  sharedNormals = sharedNormals,
  uvSets = uvSets,
}
