--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
OpenMW's `components/nif/controller.hpp` values and checks the schema can't state as steps. The
links read here are checked by the record's post functions, in the order OpenMW resolves them.
]]

local G = require '../stream'
local L = require '../links'

type Stream = G.Stream

local custom = {}

--- `RecordPtrT::read`: one link, -1 or a record index.
function custom.ptr(s: Stream, p: number): (number, number)
  local index = buffer.readi32(s.b, p)
  if index < -1 then G.invalidLink(index) end

  return index, p + 4
end

--- `count` links.
function custom.ptrs(s: Stream, p: number, count: number): ({ number }, number)
  return G.links(s, p, count), p + count * 4
end

--- `RecordListT`: a `u32` count of links.
function custom.ptrList(s: Stream, p: number): ({ number }, number)
  return custom.ptrs(s, p + 4, buffer.readu32(s.b, p))
end

--- `count` link lists.
function custom.ptrLists(s: Stream, p: number, count: number): ({ { number } }, number)
  local lists = table.create(count) :: { { number } }
  for i = 1, count do
    lists[i], p = custom.ptrList(s, p)
  end

  return lists, p
end

--- `NiBoneLODController`'s skinned shape groups: a `u32` count of groups, each a `u32` count of
--- `SkinInfo`s.
function custom.skinInfoGroups(s: Stream, p: number): ({ { any } }, number)
  local b = s.b
  local count = buffer.readu32(b, p)
  p += 4
  local groups = table.create(count) :: { { any } }
  for i = 1, count do
    local length = buffer.readu32(b, p)
    p += 4
    local group = table.create(length) :: { any }
    for k = 1, length do
      local shape, skin
      shape, p = custom.ptr(s, p)
      skin, p = custom.ptr(s, p)
      group[k] = { shape = shape, skin = skin }
    end

    groups[i] = group
  end

  return groups, p
end

--- `NiGeomMorpherController`'s interpolators: a link list up to Oblivion (followed, in
--- Bethesda's 10.2 files, by values OpenMW skips), then interpolator and weight pairs.
function custom.morphInterpolators(s: Stream, p: number): (any, number)
  local b, version = s.b, s.version
  if version <= 0x14000005 then
    local interpolators
    interpolators, p = custom.ptrList(s, p)
    if version >= 0x0A020000 and s.bethVersion >= 10 then
      local unknown = buffer.readu32(b, p)
      p = G.skip(s, p + 4, unknown * 4)
    end

    return { interpolators = interpolators, weights = {} :: { number } }, p
  end

  local count = buffer.readu32(b, p)
  p += 4
  local interpolators, weights = {} :: { number }, {} :: { number }
  for i = 1, count do
    interpolators[i], p = custom.ptr(s, p)
    weights[i] = buffer.readf32(b, p)
    p += 4
  end

  return { interpolators = interpolators, weights = weights }, p
end

function custom.sequenceLinks(r: any, records: { any }, classes: { string }, index: number)
  L.link(r.textKeys, 'Extra', records, classes, index)
  for _, block in r.controlledBlocks do
    L.link(block.interpolator, 'NiInterpolator', records, classes, index)
    L.link(block.controller, 'NiTimeController', records, classes, index)
    L.link(block.blendInterpolator, 'NiBlendInterpolator', records, classes, index)
    L.link(block.stringPalette, 'NiStringPalette', records, classes, index)
  end
end

function custom.controllerSequenceLinks(
  r: any,
  records: { any },
  classes: { string },
  index: number
)
  L.link(r.manager, 'NiControllerManager', records, classes, index)
  L.link(r.stringPalette, 'NiStringPalette', records, classes, index)
end

function custom.morphLinks(r: any, records: { any }, classes: { string }, index: number)
  L.links(r.interpolators, 'NiInterpolator', records, classes, index)
end

function custom.boneLodLinks(r: any, records: { any }, classes: { string }, index: number)
  for _, group in r.nodeGroups do
    L.links(group, 'NiAVObject', records, classes, index)
  end

  for _, group in r.skinnedShapeGroups do
    for _, info in group do
      L.link(info.shape, 'NiTriBasedGeom', records, classes, index)
      L.link(info.skin, 'NiSkinInstance', records, classes, index)
    end
  end

  L.links(r.shapeGroups, 'NiTriBasedGeom', records, classes, index)
end

function custom.blendLinks(r: any, records: { any }, classes: { string }, index: number)
  for _, item in r.items do
    L.link(item.interpolator, 'NiInterpolator', records, classes, index)
  end

  L.link(r.singleInterpolator, 'NiInterpolator', records, classes, index)
end

return custom
