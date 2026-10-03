--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
OpenMW's `components/nif/node.hpp` values and checks the schema can't state as steps.
]]

local G = require '../stream'
local L = require '../links'

type Stream = G.Stream

local custom = {}

local function vec3(b: buffer, p: number): vector
  return vector.create(buffer.readf32(b, p), buffer.readf32(b, p + 4), buffer.readf32(b, p + 8))
end

--- `BoundingVolume::BASE_BV`: no volume.
--- `BoundingVolume::BASE_BV`: no volume, one frozen table for every record without one.
local NoBounds = table.freeze { type = 0xFFFFFFFF }

function custom.noBounds(): any return NoBounds end

--- `BoundingVolume`: a volume of the shape its type names, only that shape kept.
function custom.boundingVolume(s: Stream, p: number): (any, number)
  local b = s.b
  local kind = buffer.readu32(b, p)
  p += 4
  if kind == 0xFFFFFFFF then return { type = kind }, p end

  if kind == 0 then
    return { type = kind, sphere = { center = vec3(b, p), radius = buffer.readf32(b, p + 12) } },
      p + 16
  end

  if kind == 1 then
    local volume = { center = vec3(b, p), axes = G.mat3(b, p + 12), extents = vec3(b, p + 48) }
    return { type = kind, box = volume }, p + 60
  end

  if kind == 2 then
    local volume = {
      center = vec3(b, p),
      axis = vec3(b, p + 12),
      extent = buffer.readf32(b, p + 24),
      radius = buffer.readf32(b, p + 28),
    }

    return { type = kind, capsule = volume }, p + 32
  end

  if kind == 3 then
    local radius = buffer.readf32(b, p)
    p += 4
    local extent0, extent1 = 0, 0
    if s.version >= 0x04020100 then
      extent0, extent1 = buffer.readf32(b, p), buffer.readf32(b, p + 4)
      p += 8
    end

    local volume = {
      radius = radius,
      extent0 = extent0,
      extent1 = extent1,
      center = vec3(b, p),
      axis0 = vec3(b, p + 12),
      axis1 = vec3(b, p + 24),
    }

    return { type = kind, lozenge = volume }, p + 36
  end

  if kind == 4 then
    local count = buffer.readu32(b, p)
    p += 4
    local children = table.create(count) :: { any }
    for i = 1, count do
      children[i], p = custom.boundingVolume(s, p)
    end

    return { type = kind, children = children }, p
  end

  if kind == 5 then
    local plane = {
      buffer.readf32(b, p),
      buffer.readf32(b, p + 4),
      buffer.readf32(b, p + 8),
      buffer.readf32(b, p + 12),
    }
    p += 16
    local origin = vector.zero
    if s.version >= 0x04020100 then
      origin = vec3(b, p)
      p += 12
    end

    return { type = kind, halfSpace = { plane = plane, origin = origin } }, p
  end

  return G.fail(`Unhandled BoundingVolume type: {kind}`)
end

--- `NiDefaultAVObjectPalette`'s objects: name and link pairs, a repeated name replacing the
--- earlier pair's link.
function custom.avObjectPalette(s: Stream, p: number): ({ { any } }, number)
  local b = s.b
  local count = buffer.readu32(b, p)
  p += 4
  local objects: { { any } }, at: { [string]: number } = {}, {}
  for _ = 1, count do
    local name
    name, p = G.sizedU32(s, p)
    local index = buffer.readi32(b, p)
    p += 4
    if index < -1 then G.invalidLink(index) end

    local existing = at[name]
    if existing then
      objects[existing][2] = index
    else
      table.insert(objects, { name, index })
      at[name] = #objects
    end
  end

  return objects, p
end

function custom.paletteLinks(r: any, records: { any }, classes: { string }, index: number)
  for _, object in r.objects do
    L.link(object[2], 'NiAVObject', records, classes, index)
  end
end

--- `BSVertexDesc`: a `u64` of nibbles; Skyrim SE always stores full-precision vertices.
function custom.vertexDesc(s: Stream, p: number): (any, number)
  local b = s.b
  local low, high = buffer.readu32(b, p), buffer.readu32(b, p + 4)
  local flags = bit32.extract(high, 12, 12)
  if s.bethVersion == 100 then flags = bit32.bor(flags, 0x400) end

  local desc = {
    vertexDataSize = bit32.extract(low, 0, 4),
    dynamicVertexSize = bit32.extract(low, 4, 4),
    uv1Offset = bit32.extract(low, 8, 4),
    uv2Offset = bit32.extract(low, 12, 4),
    normalOffset = bit32.extract(low, 16, 4),
    tangentOffset = bit32.extract(low, 20, 4),
    colorOffset = bit32.extract(low, 24, 4),
    skinningDataOffset = bit32.extract(low, 28, 4),
    landscapeDataOffset = bit32.extract(high, 0, 4),
    eyeDataOffset = bit32.extract(high, 4, 4),
    flags = flags,
  }

  return desc, p + 8
end

local function bytes4(b: buffer, p: number): { number }
  return {
    buffer.readu8(b, p),
    buffer.readu8(b, p + 1),
    buffer.readu8(b, p + 2),
    buffer.readu8(b, p + 3),
  }
end

local function halves(b: buffer, p: number, count: number): { number }
  local list = table.create(count) :: { number }
  for i = 1, count do
    list[i] = buffer.readu16(b, p + (i - 1) * 2)
  end

  return list
end

--- The bytes one `BSVertexData` takes, laid out as `flags` says.
local function vertexSize(flags: number): number
  local size = 0
  if bit32.btest(flags, 0x1) then
    size += if bit32.btest(flags, 0x400) then 16 else 8
  end

  if bit32.btest(flags, 0x2) then
    size += 4
  end

  if bit32.btest(flags, 0x8) then
    size += if bit32.btest(flags, 0x10) then 8 else 4
  end

  if bit32.btest(flags, 0x20) then
    size += 4
  end

  if bit32.btest(flags, 0x40) then
    size += 12
  end

  if bit32.btest(flags, 0x100) then
    size += 4
  end

  return size
end

local Zero2: { number } = table.freeze { 0, 0 }

--- `BSVertexData` for each of `count` vertices, laid out as `flags` says, each read when asked
--- for.
function custom.vertexData(s: Stream, p: number, count: number, flags: number): (any, number)
  local function read(b: buffer, p: number): any
    local zero4 = G.zero4
    local vertex = {
      vertex = zero4,
      halfVertex = zero4,
      uv = Zero2,
      normal = zero4,
      tangent = zero4,
      vertColor = zero4,
      boneWeights = zero4,
      boneIndices = zero4,
      eyeData = 0,
    }

    if bit32.btest(flags, 0x1) then
      if bit32.btest(flags, 0x400) then
        vertex.vertex = {
          buffer.readf32(b, p),
          buffer.readf32(b, p + 4),
          buffer.readf32(b, p + 8),
          buffer.readf32(b, p + 12),
        }
        p += 16
      else
        vertex.halfVertex = halves(b, p, 4)
        p += 8
      end
    end

    if bit32.btest(flags, 0x2) then
      vertex.uv = halves(b, p, 2)
      p += 4
    end

    if bit32.btest(flags, 0x8) then
      vertex.normal = bytes4(b, p)
      p += 4
      if bit32.btest(flags, 0x10) then
        vertex.tangent = bytes4(b, p)
        p += 4
      end
    end

    if bit32.btest(flags, 0x20) then
      vertex.vertColor = bytes4(b, p)
      p += 4
    end

    if bit32.btest(flags, 0x40) then
      vertex.boneWeights = halves(b, p, 4)
      vertex.boneIndices = bytes4(b, p + 8)
      p += 12
    end

    if bit32.btest(flags, 0x100) then
      vertex.eyeData = buffer.readf32(b, p)
      p += 4
    end

    return vertex
  end

  return G.rows(s, p, count, vertexSize(flags), read)
end

--- A string with a `u16` length before it.
function custom.sizedU16(s: Stream, p: number): (string, number)
  return G.sized(s, p + 2, buffer.readu16(s.b, p))
end

--- A `u32` count of rows of `width` floats.
function custom.f32Rows(s: Stream, p: number, width: number): ({ { number } }, number)
  local b = s.b
  local count = buffer.readu32(b, p)
  p += 4
  G.checkSize(s, count * width * 4)
  local rows = table.create(count) :: { { number } }
  for i = 1, count do
    local row = table.create(width) :: { number }
    for k = 1, width do
      row[k] = buffer.readf32(b, p)
      p += 4
    end

    rows[i] = row
  end

  return rows, p
end

--- A `u32` count of lists, each a `u32` count of sized strings.
function custom.stringLists(s: Stream, p: number): ({ { string } }, number)
  local b = s.b
  local count = buffer.readu32(b, p)
  p += 4
  local lists = table.create(count) :: { { string } }
  for i = 1, count do
    local length = buffer.readu32(b, p)
    p += 4
    local list = table.create(length) :: { string }
    for k = 1, length do
      list[k], p = G.sizedU32(s, p)
    end

    lists[i] = list
  end

  return lists, p
end

return custom
