--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Repairs for problems `check` finds that have one clear fix: a port of jess-nif's `fix`. They
apply to a Morrowind NIF's records (the model `open` returns). Every fix keeps what the model
looks like in Morrowind, and makes OpenMW behave the same way.

- `rcn`: add `RCN` string data to a root whose `RootCollisionNode` isn't one of its children, so
  OpenMW searches for it instead of colliding with the render geometry.
- `ncc`: uppercase `ncc` string data: OpenMW only keeps camera collision for `NCC`.
- `markers`: add `MRK` string data to a root with `Tri EditorMarker` shapes, so they don't draw.
- `skinWeights`: drop skin weights for vertices the shape doesn't have; OpenMW refuses the file
  otherwise.
- `unreachable`: drop records nothing links to (a save keeps only reachable records; this
  reports how many it drops).
]]

local Array = require './array'
local Classes = require './classes'

export type Kind = 'rcn' | 'ncc' | 'markers' | 'skinWeights' | 'unreachable'

--- One repair made: its kind, what changed, and the record fixed, by index before the fix.
export type Fixed = { fix: Kind, message: string, record: number? }

--- Every kind of fix, in the order they apply.
local Kinds: { Kind } =
  table.freeze { 'rcn', 'ncc', 'markers', 'skinWeights', 'unreachable' } :: any

local function typeOf(nif: any, index: number?): string?
  if not index or index < 0 then return nil end

  return nif:typeOf(index)
end

local function is(nif: any, index: number?, class: string): boolean
  local name = typeOf(nif, index)
  return name ~= nil and Classes.is(name, class)
end

--- The indices of `root`'s extra data chain.
local function extraDataChain(nif: any, root: number): { number }
  local chain = {}
  if not is(nif, root, 'NiObjectNET') then return chain end

  local seen = {}
  local index = nif:record(root).extraData
  while index and not seen[index] do
    seen[index] = true
    if not is(nif, index, 'NiExtraData') then break end

    table.insert(chain, index)
    index = nif:record(index).next
  end

  return chain
end

local function hasString(nif: any, root: number, value: string): boolean
  for _, index in extraDataChain(nif, root) do
    if is(nif, index, 'NiStringExtraData') and nif:record(index).value == value then return true end
  end

  return false
end

--- Puts string data first in `root`'s extra data chain.
local function addString(nif: any, root: number, value: string)
  local net = if is(nif, root, 'NiObjectNET') then nif:record(root) else nil
  local index = nif:insert {
    type = 'NiStringExtraData',
    next = if net then net.extraData else nil,
    -- Morrowind's exporter stores the string's length plus its 4-byte length prefix.
    bytesRemaining = #value + 4,
    value = value,
  }

  if net then net.extraData = index end
end

--- A link list's records, -1 and links to nothing left out.
local function children(list: any): { number }
  local found = {}
  for i = 1, list.count do
    local index = list:get(i)
    if index >= 0 then table.insert(found, index) end
  end

  return found
end

local function fixNcc(nif: any, root: number, fixed: { Fixed })
  for _, index in extraDataChain(nif, root) do
    if not is(nif, index, 'NiStringExtraData') then continue end

    local extra = nif:record(index)
    local value = extra.value
    if
      #value >= 3
      and string.upper(string.sub(value, 1, 2)) == 'NC'
      and string.sub(value, 3, 3) == 'c'
    then
      extra.value = 'NCC' .. string.sub(value, 4)
      table.insert(fixed, {
        fix = 'ncc' :: Kind,
        message = `"{value}" is now "{extra.value}", so the camera still collides`,
        record = index,
      })
    end
  end
end

local function fixRcn(nif: any, root: number, fixed: { Fixed })
  if not is(nif, root, 'NiNode') then return end

  local direct = children(nif:record(root).children)
  if hasString(nif, root, 'RCN') then return end

  for _, child in direct do
    if is(nif, child, 'RootCollisionNode') then return end
  end

  -- Is there a RootCollisionNode deeper down?
  local stack, seen = table.clone(direct), {}
  local nested: number? = nil
  while #stack > 0 do
    local index = table.remove(stack) :: number
    if seen[index] then continue end

    seen[index] = true
    if is(nif, index, 'RootCollisionNode') then
      nested = index
      break
    end

    if is(nif, index, 'NiNode') then
      for _, child in children(nif:record(index).children) do
        table.insert(stack, child)
      end
    end
  end

  if not nested then return end

  addString(nif, root, 'RCN')
  table.insert(fixed, {
    fix = 'rcn' :: Kind,
    message = `added "RCN" string data, so OpenMW finds the RootCollisionNode (record {nested}) under a child node`,
    record = root,
  })
end

local function fixMarkers(nif: any, root: number, fixed: { Fixed })
  if hasString(nif, root, 'MRK') then return end

  local stack, seen, markers = { root }, {}, 0
  while #stack > 0 do
    local index = table.remove(stack) :: number
    if seen[index] then continue end

    seen[index] = true
    if is(nif, index, 'NiGeometry') then
      local name = nif:record(index).name
      if #name >= 16 and string.lower(string.sub(name, 1, 16)) == 'tri editormarker' then
        markers += 1
      end
    end

    if is(nif, index, 'NiNode') then
      for _, child in children(nif:record(index).children) do
        table.insert(stack, child)
      end
    end
  end

  if markers == 0 then return end

  addString(nif, root, 'MRK')
  table.insert(fixed, {
    fix = 'markers' :: Kind,
    message = if markers == 1
      then 'added "MRK" string data, so 1 editor marker shape doesn\'t draw in game'
      else `added "MRK" string data, so {markers} editor marker shapes don't draw in game`,
    record = root,
  })
end

local function fixSkinWeights(nif: any, fixed: { Fixed })
  local shapes = {}
  for index = 0, nif.count - 1 do
    if not is(nif, index, 'NiGeometry') then continue end

    local geometry = nif:record(index)
    if
      not is(nif, geometry.geometryData, 'NiGeometryData')
      or not is(nif, geometry.skinInstance, 'NiSkinInstance')
    then
      continue
    end

    local vertices = nif:record(geometry.geometryData).vertices.count
    table.insert(shapes, { index, nif:record(geometry.skinInstance).data, vertices })
  end

  for _, shape in shapes do
    local index, data, vertices = shape[1], shape[2], shape[3]
    if not is(nif, data, 'NiSkinData') then continue end

    local dropped = 0
    for _, bone in nif:record(data).boneData do
      local weights = bone.vertexWeights
      local kept = {}
      for i = 0, weights.count - 1 do
        if buffer.readu16(weights.buffer, weights.offset + i * 6) < vertices then
          table.insert(kept, i)
        end
      end

      if #kept == weights.count then continue end

      dropped += weights.count - #kept
      -- The kept weights' bytes as they were: every float keeps its bits.
      local filtered = Array.new('u16f32', #kept)
      for position, i in kept do
        buffer.copy(filtered.buffer, (position - 1) * 6, weights.buffer, weights.offset + i * 6, 6)
      end

      bone.vertexWeights = filtered
    end

    if dropped > 0 then
      table.insert(fixed, {
        fix = 'skinWeights' :: Kind,
        message = `dropped {dropped} skin {if dropped == 1 then 'weight' else 'weights'} for vertices past the shape's {vertices}`,
        record = index,
      })
    end
  end
end

--- Applies the `kinds` of fixes (every kind by default) that `nif` needs, returning what
--- changed.
local function fix(nif: any, kinds: { Kind }?): { Fixed }
  local wanted = {}
  for _, kind in kinds or Kinds do
    wanted[kind] = true
  end

  local fixed: { Fixed } = {}
  local roots = {}
  for _, root in nif.roots do
    if is(nif, root, 'NiNode') then table.insert(roots, root) end
  end

  for _, root in roots do
    if wanted.ncc then fixNcc(nif, root, fixed) end

    if wanted.rcn then fixRcn(nif, root, fixed) end

    if wanted.markers then fixMarkers(nif, root, fixed) end
  end

  if wanted.skinWeights then fixSkinWeights(nif, fixed) end

  if wanted.unreachable then
    local dropped = nif.count - nif:reachableCount()
    if dropped > 0 then
      table.insert(fixed, {
        fix = 'unreachable' :: Kind,
        message = if dropped == 1
          then 'dropped 1 record nothing links to'
          else `dropped {dropped} records nothing links to`,
        record = nil,
      })
    end
  end

  return fixed
end

return table.freeze { fix = fix, kinds = Kinds }
