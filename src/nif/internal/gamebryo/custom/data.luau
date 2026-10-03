--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
OpenMW's `components/nif/data.hpp` values and checks the schema can't state as steps, and the
key groups (`nifkey.hpp`) records read their animations from.
]]

local Array = require '../../array'
local G = require '../stream'
local Lists = require '../lists'

type Stream = G.Stream
type ReadValue = (s: Stream, p: number) -> (any, number)

--- One key: its time and value, tangents for quadratic keys, and tension, continuity, and bias
--- for TCB keys.
export type Key = { time: number, value: any, inTan: any?, outTan: any?, tcb: { number }? }

--- `KeyMapT`: a key group, its keys in file order.
export type KeyMap = {
  frameName: string,
  legacyWeight: number,
  interpolationType: number,
  keys: { Key },
}

local custom = {}

local function vec3(b: buffer, p: number): vector
  return vector.create(buffer.readf32(b, p), buffer.readf32(b, p + 4), buffer.readf32(b, p + 8))
end

local function readFloat(s: Stream, p: number): (number, number)
  return buffer.readf32(s.b, p), p + 4
end

local function readVec3(s: Stream, p: number): (vector, number) return vec3(s.b, p), p + 12 end

local function readVec4(s: Stream, p: number): ({ number }, number)
  local b = s.b
  return {
    buffer.readf32(b, p),
    buffer.readf32(b, p + 4),
    buffer.readf32(b, p + 8),
    buffer.readf32(b, p + 12),
  },
    p + 16
end

--- Stored `w, x, y, z`; kept `x, y, z, w`.
local function readQuat(s: Stream, p: number): ({ number }, number)
  local b = s.b
  return {
    buffer.readf32(b, p + 4),
    buffer.readf32(b, p + 8),
    buffer.readf32(b, p + 12),
    buffer.readf32(b, p),
  },
    p + 16
end

--- Booleans are 4 bytes before 4.1.0.0 and 1 byte after.
local function readBool(s: Stream, p: number): (boolean, number)
  if s.version < 0x04010000 then return buffer.readi32(s.b, p) ~= 0, p + 4 end

  return buffer.readi8(s.b, p) ~= 0, p + 1
end

--- `KeyMapT::read`. Morph key groups start with a frame name, and after 10.1.0.0 have no keys
--- at all. Quaternion keys never carry tangents; XYZ rotations are read by their owner.
local function keyMap(
  s: Stream,
  p: number,
  value: ReadValue,
  tangents: boolean,
  morph: boolean?
): (KeyMap, number)
  local b, version = s.b, s.version
  local map: KeyMap =
    { frameName = '', legacyWeight = 0, interpolationType = 0, keys = G.empty :: any }
  if morph then
    if version >= 0x0A01006A then
      map.frameName, p = G.string(s, p)
    end

    if version > 0x0A010000 then
      if version >= 0x0A010068 and version <= 0x14010002 and s.bethVersion < 10 then
        map.legacyWeight = buffer.readf32(b, p)
        p += 4
      end

      return map, p
    end
  end

  local count = buffer.readu32(b, p)
  p += 4
  if count == 0 and not morph then return map, p end

  local interpolation = buffer.readu32(b, p)
  p += 4
  map.interpolationType = interpolation
  local withTangents, tcb = false, false
  if interpolation == 2 then
    withTangents = tangents
  elseif interpolation == 3 then
    tcb = true
  elseif interpolation ~= 1 and interpolation ~= 5 then
    -- XYZ rotations are read by their owner as three float key groups.
    if interpolation ~= 4 and count ~= 0 then
      G.fail(`Unhandled interpolation type: {interpolation}`)
    end

    return map, p
  end

  G.checkSize(s, count)
  if count == 0 then return map, p end

  -- One key, read when asked for: every key of a map is the same size, so the keys are rows.
  local function key(_: buffer, at: number): Key
    local read: Key = { time = buffer.readf32(b, at), value = nil }
    read.value, at = value(s, at + 4)
    if withTangents then
      read.inTan, at = value(s, at)
      read.outTan, at = value(s, at)
    end

    if tcb then
      read.tcb = { buffer.readf32(b, at), buffer.readf32(b, at + 4), buffer.readf32(b, at + 8) }
    end

    return read
  end

  local stride = 4 + if tcb then 12 else 0
  local _, afterValue = value(s, p + 4)
  stride += (afterValue - p - 4) * if withTangents then 3 else 1
  map.keys, p = G.rows(s, p, count, stride, key)
  return map, p
end

function custom.floatKeys(s: Stream, p: number, morph: boolean?): (KeyMap, number)
  return keyMap(s, p, readFloat, true, morph)
end

function custom.vec3Keys(s: Stream, p: number): (KeyMap, number) return keyMap(s, p, readVec3, true) end

function custom.vec4Keys(s: Stream, p: number): (KeyMap, number) return keyMap(s, p, readVec4, true) end

function custom.quatKeys(s: Stream, p: number): (KeyMap, number)
  return keyMap(s, p, readQuat, false)
end

function custom.boolKeys(s: Stream, p: number): (KeyMap, number) return keyMap(s, p, readBool, true) end

--- `count` UV sets of `vertices` coordinates each.
function custom.vec2Lists(s: Stream, p: number, count: number, vertices: number): ({ any }, number)
  local lists = table.create(count) :: { any }
  for i = 1, count do
    G.checkSize(s, vertices * 8)
    lists[i], p = G.view(s, p, vertices, 'vec2', 8)
  end

  return lists, p
end

--- A `u16` count of lists, each a `u16` count of `u16`s: walked to its end, its lists indexed
--- only when one is asked for.
function custom.u16Lists(s: Stream, p: number): (any, number)
  local b, n = s.b, s.n
  local count = buffer.readu16(b, p)
  p += 2
  if count == 0 then return G.empty, p end

  local start = p
  for _ = 1, count do
    local size = buffer.readu16(b, p) * 2
    p += 2
    if size > n then G.fail(`Trying to read more than stream size: {size} max={n}`) end

    if p + size > n then G.fail(`Failed to read u16: 2 bytes at offset {n} of {n}`) end

    p += size
  end

  return Lists.prefixed(b, start, count), p
end

--- One list of `u16`s for each of `lengths`, back to back.
function custom.strips(s: Stream, p: number, lengths: any): (any, number)
  local count = lengths.count
  if count == 0 then return G.empty, p end

  local n, start = s.n, p
  local from, at = lengths.buffer, lengths.offset
  for i = 0, count - 1 do
    local size = buffer.readu16(from, at + i * 2) * 2
    if size > n then G.fail(`Trying to read more than stream size: {size} max={n}`) end

    if p + size > n then G.fail(`Failed to read u16: 2 bytes at offset {n} of {n}`) end

    p += size
  end

  return Lists.sized(s.b, start, lengths), p
end

--- `readVector` of `length` bytes.
local function byteVector(s: Stream, p: number, length: number): number
  G.checkSize(s, length)
  if p + length > s.n then
    G.fail(`Failed to read byte vector: {length} bytes at offset {p} of {s.n}`)
  end

  return p + length
end

--- Bytes jess-nif keeps but doesn't report.
function custom.bytes(s: Stream, p: number, length: number): (nil, number)
  return nil, byteVector(s, p, length)
end

--- `NiLinesData`'s lines, as pairs of vertex indices, from a connectivity flag per vertex; the
--- last vertex connects back to the first.
function custom.lines(s: Stream, p: number, count: number): ({ number }, number)
  local b = s.b
  local stop = byteVector(s, p, count)
  local lines = {} :: { number }
  -- Can't construct a line from a single vertex.
  if count >= 2 then
    for i = 0, count - 2 do
      if bit32.btest(buffer.readu8(b, p + i), 1) then
        table.insert(lines, i)
        table.insert(lines, i + 1)
      end
    end

    if bit32.btest(buffer.readu8(b, p + count - 1), 1) then
      table.insert(lines, count - 1)
      table.insert(lines, 0)
    end
  end

  return lines, stop
end

--- `NiVisData`'s keys, as time and whether visible.
function custom.visKeys(s: Stream, p: number): ({ { any } }, number)
  local b = s.b
  local count = buffer.readu32(b, p)
  p += 4
  local keys = table.create(count) :: { { any } }
  for i = 1, count do
    keys[i] = { buffer.readf32(b, p), buffer.readu8(b, p + 4) ~= 0 }
    p += 5
  end

  return keys, p
end

--- `NiSkinData::BoneInfo` for each of `count` bones: a transform, bounds, and the vertices it
--- weighs on as `(vertex, weight)`.
function custom.skinBones(s: Stream, p: number, count: number, weighted: boolean): ({ any }, number)
  local b = s.b
  local bones = table.create(count) :: { any }
  for i = 1, count do
    local bone = {
      transform = {
        rotation = G.mat3(b, p),
        translation = vec3(b, p + 36),
        scale = buffer.readf32(b, p + 48),
      },
      boundSphere = { center = vec3(b, p + 52), radius = buffer.readf32(b, p + 64) },
      weights = Array.empty.u16f32,
    }

    local vertices = buffer.readu16(b, p + 68)
    p += 70
    if weighted then
      bone.weights, p = G.view(s, p, vertices, 'u16f32', 6)
    end

    bones[i] = bone
  end

  return bones, p
end

--- `NiMorphData::MorphData` for each of `count` morph targets: keys and `vertices` vertices.
function custom.morphs(s: Stream, p: number, count: number, vertices: number): ({ any }, number)
  local morphs = table.create(count) :: { any }
  for i = 1, count do
    local keyFrames, list
    keyFrames, p = keyMap(s, p, readFloat, true, true)
    G.checkSize(s, vertices * 12)
    list, p = G.view(s, p, vertices, 'vec3', 12)
    morphs[i] = { keyFrames = keyFrames, vertices = list }
  end

  return morphs, p
end

--- `NiPalette`'s 256 colors; indices past 255 are unused, and without alpha every color is
--- opaque.
function custom.paletteColors(s: Stream, p: number, alpha: boolean): ({ number }, number)
  local b = s.b
  local mask = if alpha then 0 else 0xFF000000
  local count = buffer.readu32(b, p)
  p += 4
  local colors = table.create(256, 0) :: { number }
  for i = 1, count do
    if i <= 256 then colors[i] = bit32.bor(buffer.readu32(b, p), mask) end

    p += 4
  end

  return colors, p
end

local function u32List(s: Stream, p: number): ({ number }, number)
  local b = s.b
  local count = buffer.readu32(b, p)
  p += 4
  G.checkSize(s, count * 4)
  local list = table.create(count) :: { number }
  for i = 1, count do
    list[i] = buffer.readu32(b, p)
    p += 4
  end

  return list, p
end

--- `NiAdditionalGeometryData::DataBlock`s; only `BSPackedAdditionalGeometryData`'s (`packed`)
--- have a shader index and total size.
function custom.geometryBlocks(s: Stream, p: number, packed: boolean): ({ any }, number)
  local b = s.b
  local count = buffer.readu32(b, p)
  p += 4
  local blocks = table.create(count) :: { any }
  for i = 1, count do
    local valid
    valid, p = readBool(s, p)
    local block = {
      valid = valid,
      blockSize = 0,
      blockOffsets = {} :: { number },
      dataSizes = {} :: { number },
      shaderIndex = 0,
      totalSize = 0,
    }

    blocks[i] = block
    if not valid then continue end

    block.blockSize = buffer.readu32(b, p)
    block.blockOffsets, p = u32List(s, p + 4)
    block.dataSizes, p = u32List(s, p)
    p = byteVector(s, p, #block.dataSizes * block.blockSize)
    if packed then
      block.shaderIndex, block.totalSize = buffer.readu32(b, p), buffer.readu32(b, p + 4)
      p += 8
    end
  end

  return blocks, p
end

--- `BSVertexDesc` as a record holds it when the file has none.
function custom.noVertexDesc(): any
  return {
    vertexDataSize = 0,
    dynamicVertexSize = 0,
    uv1Offset = 0,
    uv2Offset = 0,
    normalOffset = 0,
    tangentOffset = 0,
    colorOffset = 0,
    skinningDataOffset = 0,
    landscapeDataOffset = 0,
    eyeDataOffset = 0,
    flags = 0,
  }
end

--- `list`'s indices through `map` (both `u16` views), an index past the map kept as it is, as a
--- new `u16` array, worked out the first time it is read.
function custom.remap(list: any, map: any): any
  local count = list.count
  return Array.lazy('u16', count, function(to: buffer)
    local size, from, at, mapBuffer, mapAt =
      map.count, list.buffer, list.offset, map.buffer, map.offset
    for i = 0, count - 1 do
      local index = buffer.readu16(from, at + i * 2)
      if index < size then index = buffer.readu16(mapBuffer, mapAt + index * 2) end

      buffer.writeu16(to, i * 2, index)
    end
  end)
end

function custom.remapStrips(strips: { any }, map: any): { any }
  local remapped = table.create(#strips) :: { any }
  for i, strip in strips do
    remapped[i] = custom.remap(strip, map)
  end

  return remapped
end

--- `NiSkinInstance::post` and `BSSkinInstance::post`.
local function checkSkin(r: any, records: { any }, kind: string, dataName: string)
  local data = if r.data >= 0 then records[r.data + 1] else nil
  if not data or r.root < 0 then G.fail(`{kind} missing root or data`) end

  if #data.bones ~= #r.bones then G.fail(`Mismatch in {dataName} bone count`) end

  for _, bone in r.bones do
    if bone < 0 then G.fail 'Oops: Missing bone! Don\'t know how to handle this.' end
  end
end

function custom.skinInstance(r: any, records: { any }, _classes: { string }, _index: number)
  checkSkin(r, records, 'NiSkinInstance', 'NiSkinData')
end

function custom.bsSkinInstance(r: any, records: { any }, _classes: { string }, _index: number)
  checkSkin(r, records, 'BSSkin::Instance', 'BSSkin::BoneData')
end

return custom
