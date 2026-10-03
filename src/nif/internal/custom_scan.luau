--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The scanners for the fields `custom.luau` reads and writes: each walks past its field, collecting
the links it holds (`(b, p, links, n, ...) -> (p, n)`), and decodes nothing. `open` needs only
these, so it never loads the decoders.
]]

local Array = require './array'
local Enums = require './enums'

type Links = { number }

local function scanLink(b: buffer, p: number, links: Links, n: number): number
  local value = buffer.readi32(b, p)
  if value < 0 then return n end

  n += 1
  links[n] = value
  return n
end

local function sumU16(b: buffer, p: number, count: number): number
  local total = 0
  for i = 0, count - 1 do
    total += buffer.readu16(b, p + i * 2)
  end

  return total
end

local function invalidKeyType(kind: number): never
  local name = Enums.names.KeyType[kind] or 'NoInterp'
  error(`Invalid KeyType: {name}`, 0)
end

--- A key union's scanner: `strides` holds each key type's size; `always` says the kind is stored
--- even with no keys.
local function keyUnion(kinds: { Array.Kind }, always: boolean?)
  local strides = {}
  for kind, arrayKind in kinds do
    strides[kind] = Array.strides[arrayKind]
  end

  return function(b: buffer, p: number, _links: Links, n: number): (number, number)
    local count = buffer.readu32(b, p)
    if count == 0 then return if always then p + 8 else p + 4, n end

    local kind = buffer.readu32(b, p + 4)
    local stride = strides[kind]
    if not stride then invalidKeyType(kind) end

    return p + 8 + count * stride, n
  end
end

local FloatKinds: { Array.Kind } = { 'floatLin', 'floatBez', 'floatTcb' }
local floatKeys = keyUnion(FloatKinds)
local quaternionKeys = keyUnion { 'rotLin', 'rotLin', 'rotTcb' }

--- Rotation keys, or Euler angles as three float curves.
local function rotKeys(b: buffer, p: number, links: Links, n: number): (number, number)
  if buffer.readu32(b, p) == 0 or buffer.readu32(b, p + 4) ~= 4 then
    return quaternionKeys(b, p, links, n)
  end

  p, n = floatKeys(b, p + 12, links, n)
  p, n = floatKeys(b, p, links, n)
  return floatKeys(b, p, links, n)
end

--- A sphere, an oriented box, or a union of volumes.
local function boundingVolume(b: buffer, p: number, links: Links, n: number): (number, number)
  local kind = buffer.readi32(b, p)
  p += 4
  if kind == 0 then return p + 16, n end

  if kind == 1 then return p + 60, n end

  if kind ~= 4 then error(`Invalid BoundType: {Enums.names.BoundType[kind] or 'Sphere'}`, 0) end

  local count = buffer.readu32(b, p)
  p += 4
  for _ = 1, count do
    p, n = boundingVolume(b, p, links, n)
  end

  return p, n
end

--- Slot 5 is the bump map, which is longer than the rest.
local function textureMaps(b: buffer, p: number, links: Links, n: number): (number, number)
  local count = buffer.readu32(b, p)
  p += 4
  for slot = 0, count - 1 do
    local present = buffer.readu32(b, p) ~= 0
    p += 4
    if present then
      n = scanLink(b, p, links, n)
      p += if slot == 5 then 46 else 22
    end
  end

  return p, n
end

local function textureSource(b: buffer, p: number, links: Links, n: number): (number, number)
  if buffer.readu8(b, p) ~= 0 then return p + 5 + buffer.readu32(b, p + 1), n end

  if buffer.readu8(b, p + 1) ~= 0 then return p + 6, scanLink(b, p + 2, links, n) end

  return p + 2, n
end

local function sequenceTarget(b: buffer, p: number, _links: Links, n: number): (number, number)
  if buffer.readu8(b, p) ~= 0 then return p + 5 + buffer.readu32(b, p + 1), n end

  return p + 9, n
end

local function nameControllerPairs(b: buffer, p: number, _links: Links, n: number): (number, number)
  local count = buffer.readu32(b, p)
  p += 4
  for _ = 1, count do
    p += 8 + buffer.readu32(b, p)
  end

  return p, n
end

local function sharedNormals(b: buffer, p: number, _links: Links, n: number): (number, number)
  local count = buffer.readu16(b, p)
  p += 2
  for _ = 1, count do
    p += 2 + 2 * buffer.readu16(b, p)
  end

  return p, n
end

local function uvSets(
  _b: buffer,
  p: number,
  _links: Links,
  n: number,
  sets: number,
  vertices: number
): (number, number)
  return p + sets * vertices * 8, n
end

return table.freeze {
  scanLink = scanLink,
  sumU16 = sumU16,
  floatKeys = floatKeys,
  morphKeys = keyUnion(FloatKinds, true),
  posKeys = keyUnion { 'posLin', 'posBez', 'posTcb' },
  rotKeys = rotKeys,
  colorKeys = keyUnion { 'colorLin' },
  boundingVolume = boundingVolume,
  textureMaps = textureMaps,
  textureSource = textureSource,
  sequenceTarget = sequenceTarget,
  nameControllerPairs = nameControllerPairs,
  sharedNormals = sharedNormals,
  uvSets = uvSets,
}
