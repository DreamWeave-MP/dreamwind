--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
OpenMW's `components/nif/property.hpp` values and checks the schema can't state as steps.
]]

local G = require '../stream'
local L = require '../links'

type Stream = G.Stream
type ReadTexture = (s: Stream, p: number) -> (any, number)

local custom = {}

--- Every disabled texture reads the same: `enabled` false, every other field its default. One
--- frozen texture stands for them all, made from the first one read.
local disabled: any = nil

--- A texture, or the shared disabled one without reading a table for it.
local function texture(s: Stream, p: number, readTexture: ReadTexture): (any, number)
  local enabled
  if s.version < 0x04010000 then
    enabled = buffer.readi32(s.b, p) ~= 0
  else
    enabled = buffer.readi8(s.b, p) ~= 0
  end

  if enabled or not disabled then
    local read, after = readTexture(s, p)
    if not enabled then disabled = table.freeze(read) end

    return read, after
  end

  return disabled, p + if s.version < 0x04010000 then 4 else 1
end

--- What `texturingMaps` returns, filled again by every call: its reader copies the fields out
--- before the next record is read.
local Maps = {
  textures = G.empty :: { any },
  shaderTextures = G.empty :: { any },
  shaderIds = G.empty :: { number },
  envMapLumaBias = vector.zero,
  bumpMapMatrix = G.zero4,
  parallaxOffset = 0,
}

--- `NiTexturingProperty`'s textures and shader textures with what follows some of them: the
--- environment map's luma bias and bump map matrix after the sixth texture, if enabled, and the
--- parallax offset after the eighth.
function custom.texturingMaps(s: Stream, p: number, readTexture: ReadTexture): (any, number)
  local b, version = s.b, s.version
  local maps = Maps
  maps.envMapLumaBias, maps.bumpMapMatrix, maps.parallaxOffset = vector.zero, G.zero4, 0

  local count = buffer.readu32(b, p)
  p += 4
  local textures = if count == 0 then G.empty else table.create(count)
  for i = 1, count do
    local read
    read, p = texture(s, p, readTexture)
    textures[i] = read
    if i == 6 and read.enabled then
      maps.envMapLumaBias = vector.create(buffer.readf32(b, p), buffer.readf32(b, p + 4), 0)
      maps.bumpMapMatrix = {
        buffer.readf32(b, p + 8),
        buffer.readf32(b, p + 12),
        buffer.readf32(b, p + 16),
        buffer.readf32(b, p + 20),
      }
      p += 24
    elseif i == 8 and read.enabled and version >= 0x14020005 then
      maps.parallaxOffset = buffer.readf32(b, p)
      p += 4
    end
  end

  maps.textures, maps.shaderTextures, maps.shaderIds = textures, G.empty, G.empty
  if version < 0x0A000100 then return maps, p end

  count = buffer.readu32(b, p)
  p += 4
  if count == 0 then return maps, p end

  local shaderTextures, shaderIds =
    table.create(count) :: { any }, table.create(count) :: { number }
  for i = 1, count do
    local read
    read, p = texture(s, p, readTexture)
    local id = 0
    if read.enabled then
      id = buffer.readu32(b, p)
      p += 4
    end

    shaderTextures[i], shaderIds[i] = read, id
  end

  maps.shaderTextures, maps.shaderIds = shaderTextures, shaderIds
  return maps, p
end

function custom.texturingLinks(r: any, records: { any }, classes: { string }, index: number)
  for _, texture in r.textures do
    L.link(texture.sourceTexture, 'NiSourceTexture', records, classes, index)
  end

  for _, texture in r.shaderTextures do
    L.link(texture.sourceTexture, 'NiSourceTexture', records, classes, index)
  end
end

return custom
