--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
A NIF's shape at a glance: record type counts and the scene graph as a tree of nodes, with each
node's controllers, properties, effects, extra data, and geometry. A port of jess-nif's `info`,
for the Morrowind model (`open`) and the multi-version reader's records alike.
]]

local Classes = require './classes'
local L = require './gamebryo/links'
local Reader = require './gamebryo/reader'

--- A record by index and type.
export type RecordRef = { index: number, type: string }

--- A controller on a node or property; an inactive one (flag 0x8 clear) doesn't run.
export type ControllerRef = { index: number, type: string, active: boolean }

--- Extra data on a node; string data (`MRK`, `NCC`, `RCN`, ...) shows its value.
export type ExtraDataRef = { index: number, type: string, value: string? }

--- A shape's geometry; `skin` is the skin instance when the shape is skinned.
export type ShapeInfo = { data: RecordRef?, vertices: number, triangles: number, skin: number? }

--- A node or shape in the scene graph, with its children. Lists with nothing in them, and
--- `hidden` when false, are left out.
export type TreeNode = {
  index: number,
  type: string,
  name: string,
  --- Flag 0x1: the node and everything under it are hidden.
  hidden: boolean?,
  controllers: { ControllerRef }?,
  properties: { RecordRef }?,
  effects: { RecordRef }?,
  extraData: { ExtraDataRef }?,
  --- The Havok collision object, in games after Morrowind.
  collision: RecordRef?,
  shape: ShapeInfo?,
  children: { TreeNode }?,
}

--- How many levels a tree lists. A record deeper than this is listed without its children, the
--- way a record seen before is: Morrowind's deepest NIFs have about 20 levels, and the limit
--- keeps a malformed chain of thousands from overflowing the stack.
local MaxTreeDepth = 256

local function nonEmpty<T>(list: { T }): { T }? return if #list > 0 then list else nil end

--- How many records of each type a Morrowind model holds.
local function recordTypeCounts(nif: any): { [string]: number }
  local counts = {}
  for i = 0, nif.count - 1 do
    local name = nif:typeOf(i)
    counts[name] = (counts[name] or 0) + 1
  end

  return counts
end

--- The scene graph under each root of a Morrowind model, `MaxTreeDepth` levels at most. Roots
--- that aren't scene objects (a KF's `NiSequenceStreamHelper`) are listed without children.
local function sceneTree(nif: any): { TreeNode }
  local seen: { [number]: boolean } = {}

  local function typeOf(index: number?): string?
    if not index or index < 0 then return nil end

    return nif:typeOf(index)
  end

  local function is(index: number, class: string): boolean
    local name = typeOf(index)
    return name ~= nil and Classes.is(name, class)
  end

  local function recordRef(index: number?): RecordRef?
    local name = typeOf(index)
    return if name then { index = index :: number, type = name } else nil
  end

  local function controllers(first: number?): { ControllerRef }
    local found, visited = {}, {}
    local index = first
    while index and index >= 0 and not visited[index] do
      visited[index] = true
      if not is(index, 'NiTimeController') then break end

      local controller = nif:record(index)
      table.insert(found, {
        index = index,
        type = typeOf(index) :: string,
        active = bit32.btest(controller.flags, 0x8),
      })
      index = controller.next
    end

    return found
  end

  local function extraData(first: number?): { ExtraDataRef }
    local found, visited = {}, {}
    local index = first
    while index and index >= 0 and not visited[index] do
      visited[index] = true
      if not is(index, 'NiExtraData') then break end

      local extra = nif:record(index)
      local value = if is(index, 'NiStringExtraData') then extra.value else nil
      table.insert(found, { index = index, type = typeOf(index) :: string, value = value })
      index = extra.next
    end

    return found
  end

  local function refs(list: any): { RecordRef }
    local found = {}
    for i = 1, list.count do
      local ref = recordRef(list:get(i))
      if ref then table.insert(found, ref) end
    end

    return found
  end

  local function triangleCount(data: number?): number
    if is(data or -1, 'NiTriShapeData') then return nif:record(data).triangles.count end

    if not is(data or -1, 'NiTriStripsData') then return 0 end

    local total = 0
    local lengths = nif:record(data).stripLengths
    for i = 1, lengths.count do
      total += math.max(lengths:get(i) - 2, 0)
    end

    return total
  end

  local function node(index: number, depth: number): TreeNode?
    local name = typeOf(index)
    if not name then return nil end

    local tree: TreeNode = { index = index, type = name, name = '' }
    -- A link cycle would recurse forever; list the record again without descending.
    if depth > MaxTreeDepth or seen[index] then return tree end

    seen[index] = true
    local record = nif:record(index)
    if is(index, 'NiObjectNET') then
      tree.name = record.name
      tree.controllers = nonEmpty(controllers(record.controller))
      tree.extraData = nonEmpty(extraData(record.extraData))
    end

    if is(index, 'NiAVObject') then
      if bit32.btest(record.flags, 1) then tree.hidden = true end

      tree.properties = nonEmpty(refs(record.properties))
    end

    if is(index, 'NiNode') then
      tree.effects = nonEmpty(refs(record.effects))
      local children: { TreeNode } = {}
      for i = 1, record.children.count do
        local child = node(record.children:get(i), depth + 1)
        if child then table.insert(children, child) end
      end

      tree.children = nonEmpty(children)
    end

    if is(index, 'NiGeometry') then
      local data = record.geometryData
      local vertices = if is(data or -1, 'NiGeometryData')
        then nif:record(data).vertices.count
        else 0
      tree.shape = {
        data = recordRef(data),
        vertices = vertices,
        triangles = triangleCount(data),
        -- A link to a record the file doesn't have is no skin.
        skin = if typeOf(record.skinInstance) then record.skinInstance else nil,
      }
    end

    return tree
  end

  local trees = {}
  for _, root in nif.roots do
    local tree = node(root, 1)
    if tree then table.insert(trees, tree) end
  end

  return trees
end

--- How many records of each type a file read by the multi-version reader holds.
local function fileTypeCounts(file: Reader.File): { [string]: number }
  local counts = {}
  for _, name in file.names do
    counts[name] = (counts[name] or 0) + 1
  end

  return counts
end

--- The scene graph under each root of a file read by the multi-version reader.
local function fileSceneTree(file: Reader.File): { TreeNode }
  local records, classes, names = file.records, file.classes, file.names
  local seen: { [number]: boolean } = {}

  local function get(index: number, class: string): any
    if index < 0 then return nil end

    local record = records[index + 1]
    if not record or not L.is[classes[index + 1]][class] then return nil end

    return record
  end

  local function recordRef(index: number): RecordRef?
    if index < 0 or not records[index + 1] then return nil end

    return { index = index, type = names[index + 1] }
  end

  local function refs(list: any): { RecordRef }
    local found = {}
    for _, index in list do
      local ref = recordRef(index)
      if ref then table.insert(found, ref) end
    end

    return found
  end

  local function controllers(first: number): { ControllerRef }
    local found, visited = {}, {}
    local index = first
    while index >= 0 do
      local controller = get(index, 'NiTimeController')
      if not controller or visited[index] then break end

      visited[index] = true
      table.insert(found, {
        index = index,
        type = names[index + 1] or '',
        active = bit32.btest(controller.flags, 0x8),
      })
      index = controller.next
    end

    return found
  end

  local function extraData(net: any): { ExtraDataRef }
    local function describe(index: number): ExtraDataRef
      local text = get(index, 'NiStringExtraData')
      return {
        index = index,
        type = names[index + 1] or '',
        value = if text then text.data else nil,
      }
    end

    local found = {}
    for _, index in net.extraList do
      if index >= 0 then table.insert(found, describe(index)) end
    end

    local visited = {}
    local index = net.extra
    while index >= 0 do
      local extra = get(index, 'Extra')
      if not extra or visited[index] then break end

      visited[index] = true
      table.insert(found, describe(index))
      index = extra.next
    end

    return found
  end

  local function triangleCount(data: number): number
    local shape = get(data, 'NiTriShapeData')
    if shape then return #shape.triangles // 3 end

    local strips = get(data, 'NiTriStripsData')
    if not strips then return 0 end

    local total = 0
    for _, strip in strips.strips do
      total += math.max(#strip - 2, 0)
    end

    return total
  end

  local function node(index: number, depth: number): TreeNode?
    if not records[index + 1] then return nil end

    local tree: TreeNode = { index = index, type = names[index + 1], name = '' }
    -- A link cycle would recurse forever; list the record again without descending.
    if depth > MaxTreeDepth or seen[index] then return tree end

    seen[index] = true
    local net = get(index, 'NiObjectNET')
    if net then
      tree.name = net.name
      tree.controllers = nonEmpty(controllers(net.controller))
      tree.extraData = nonEmpty(extraData(net))
    end

    local av = get(index, 'NiAVObject')
    if av then
      if bit32.btest(av.flags, 1) then tree.hidden = true end

      tree.properties = nonEmpty(refs(av.properties))
      tree.collision = recordRef(av.collision)
    end

    local parent = get(index, 'NiNode')
    if parent then
      tree.effects = nonEmpty(refs(parent.effects))
      local children: { TreeNode } = {}
      for _, child in parent.children do
        if child < 0 then continue end

        local inner = node(child, depth + 1)
        if inner then table.insert(children, inner) end
      end

      tree.children = nonEmpty(children)
    end

    local geometry = get(index, 'NiGeometry')
    local triShape: any = if geometry then nil else get(index, 'BSTriShape')
    if geometry then
      local data = get(geometry.data, 'NiGeometryData')
      tree.shape = {
        data = recordRef(geometry.data),
        vertices = if data then #data.vertices else 0,
        triangles = if geometry.data >= 0 then triangleCount(geometry.data) else 0,
        skin = if geometry.skin >= 0 then geometry.skin else nil,
      }
    elseif triShape then
      tree.shape = {
        data = nil :: RecordRef?,
        vertices = triShape.numVertices :: number,
        triangles = #triShape.triangles // 3,
        skin = if triShape.skin >= 0 then triShape.skin else nil,
      }
    end

    return tree
  end

  local trees = {}
  for _, root in file.roots do
    if root < 0 or root >= #records then continue end

    local tree = node(root, 1)
    if tree then table.insert(trees, tree) end
  end

  return trees
end

return table.freeze {
  recordTypeCounts = recordTypeCounts,
  sceneTree = sceneTree,
  fileTypeCounts = fileTypeCounts,
  fileSceneTree = fileSceneTree,
  maxTreeDepth = MaxTreeDepth,
}
