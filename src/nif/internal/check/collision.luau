--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
How OpenMW's collision loader (`components/nifbullet/bulletnifloader.cpp`) builds a model's
collision, and where that differs from what the file looks like it asks for.
]]

local Base = require './base'
local Scene = require './scene'

type Checker = Base.Checker
type CollisionState = Base.CollisionState

local get, recordType, typeName, nameOf, push =
  Base.get, Base.recordType, Base.typeName, Base.nameOf, Base.push
local startsWithIgnoreCase = Base.startsWithIgnoreCase
local Constants = Base.constants

local function andMore(more: number): string
  if more == 0 then return '' end

  if more == 1 then return ' (and 1 more shape)' end

  return ` (and {more} more shapes)`
end

--- A `RootCollisionNode` OpenMW doesn't use as the collision shape: rendering only hides it by
--- its own hidden flag (or as the root's collision node), and collision treats it as visible
--- geometry.
local function checkStrayCollisionNode(c: Checker, index: number, hidden: boolean)
  hidden = hidden or index == c.collisionNode
  local severity: Base.Severity, message
  if Base.gamebryoCollision(c) then
    severity = 'collision'
    message = if hidden
      then 'OpenMW doesn\'t use RootCollisionNodes in 10.0.1.0 and later NIFs, so this one collides like the render geometry'
      else 'OpenMW doesn\'t use RootCollisionNodes in 10.0.1.0 and later NIFs, so this one draws and collides like the render geometry'
  elseif not c.collisionNode then
    severity = if hidden then 'collision' else 'broken'
    message = if hidden
      then 'OpenMW doesn\'t find this RootCollisionNode, since it isn\'t a child of the root and the root has no "RCN" string data, so the render geometry collides too'
      else 'OpenMW doesn\'t find this RootCollisionNode, since it isn\'t a child of the root and the root has no "RCN" string data, so it draws and the render geometry collides too'
  else
    severity = if hidden then 'collision' else 'broken'
    message = if hidden
      then 'Extra RootCollisionNode: OpenMW only uses the last one under the root, so this one doesn\'t collide'
      else 'Extra RootCollisionNode: OpenMW only uses the last one under the root, so this one draws and doesn\'t collide'
  end

  push(c, severity, 'stray_root_collision_node', index, message)
end

type Pending = { index: number, state: CollisionState }

--- One node of the collision traversal; its children go on `stack`, the first on top.
local function visit(
  c: Checker,
  index: number,
  from: CollisionState,
  inCollisionNode: boolean,
  seen: { [number]: boolean },
  seenCount: { number },
  stack: { Pending }
)
  local av = get(c, index, 'NiAVObject')
  if not av or seen[index] then return end

  seen[index] = true
  seenCount[1] += 1
  local kind = recordType(c, index)
  if not kind then return end

  if kind == 'NiCollisionSwitch' and not bit32.btest(av.flags, 0x20) then return end

  -- Collision from 10.0.1.0 on uses no RootCollisionNode, so every one is stray.
  local used = not Base.gamebryoCollision(c) and index == c.collisionNode
  local hiddenFlag = bit32.btest(av.flags, 1)
  if kind == 'RootCollisionNode' and not used then
    checkStrayCollisionNode(c, index, hiddenFlag or from.hidden)
  end

  local name = av.name
  local state: CollisionState = {
    hidden = from.hidden or hiddenFlag,
    shadowNamed = from.shadowNamed,
    boundingBox = from.boundingBox,
  }

  if Base.morrowindRules(c) then
    state.shadowNamed = state.shadowNamed
      or startsWithIgnoreCase(name, 'shadow')
      or startsWithIgnoreCase(name, 'tri shadow')
  end

  -- Only non-root "Bounding Box" objects are dropped from rendering.
  state.boundingBox = state.boundingBox
    or (seenCount[1] > 1 and string.lower(name) == 'bounding box')

  local node = get(c, index, 'NiNode')
  if node then
    local switch = kind == 'NiSwitchNode' or kind == 'NiFltAnimationNode'
    local children = {}
    for _, child in node.children do
      if child >= 0 then table.insert(children, child) end
    end

    local count = if switch then math.min(#children, 1) else #children
    if switch and #children > 1 and not inCollisionNode then
      push(
        c,
        'info',
        'switch_collision_first_child',
        index,
        `only the first child of this {typeName(c, index)} collides`
      )
    end

    for i = count, 1, -1 do
      table.insert(stack, { index = children[i], state = state })
    end

    return
  end

  if Constants.BsGeometryTypes[kind] then
    if not inCollisionNode and not state.hidden then table.insert(c.uncollidableShapes, index) end

    return
  end

  if not Constants.CollidingTypes[kind] then return end

  local gamebryo = Base.gamebryoCollision(c)
  if c.collisionMarkers then
    local marker = if gamebryo then 'EditorMarker' else 'Tri EditorMarker'
    if startsWithIgnoreCase(name, marker) then return end
  end

  local geometry = get(c, index, 'NiGeometry')
  if not geometry then return end

  local data = get(c, geometry.data, 'NiGeometryData')
  if not data or #data.vertices == 0 then return end

  local triangles = 0
  Scene.shapeTriangles(c, geometry, function()
    triangles += 1
  end)

  c.stats.collisionTriangles += triangles
  if triangles == 0 or inCollisionNode then return end

  local reason: string? = nil
  if state.hidden then
    reason = 'is hidden'
  elseif state.shadowNamed then
    reason = 'is a shadow mesh'
  elseif state.boundingBox then
    reason = 'is under a "Bounding Box" node'
  elseif gamebryo and c.hasMarkers and startsWithIgnoreCase(name, 'VisibilityEditorMarker') then
    reason = 'is an editor marker'
  end

  -- Actors collide by their bounding box, not their shapes.
  if reason and not c.stats.skinned then table.insert(c.invisibleColliders, { index, reason }) end
end

--- bulletnifloader.cpp `handleNode`, `handleGeometry`: depth first, children in order, without
--- recursion.
local function walk(c: Checker, root: number, inCollisionNode: boolean)
  local seen, seenCount = {}, { 0 }
  local stack: { Pending } =
    { { index = root, state = { hidden = false, shadowNamed = false, boundingBox = false } } }
  while #stack > 0 do
    local pending = table.remove(stack) :: Pending
    visit(c, pending.index, pending.state, inCollisionNode, seen, seenCount, stack)
  end
end

local function reportInvisibleColliders(c: Checker, why: string)
  local invisible = c.invisibleColliders
  c.invisibleColliders = {}
  local first = invisible[1]
  if not first then return end

  push(
    c,
    'collision',
    'invisible_shape_collides',
    first[1],
    `"{nameOf(c, first[1])}"{andMore(#invisible - 1)} {first[2]} and doesn't draw, but still collides {why}`
  )
end

--- bulletnifloader.cpp `handleRoot` for files before 10.0.1.0: `NC`/`NCC` string data, then the
--- `RootCollisionNode`, then the render geometry.
local function check(c: Checker, root: number)
  local strings = Base.rootStrings(c, root)
  c.collisionMarkers = table.find(strings, 'MRK') ~= nil
  local noCollision: string? = nil
  for _, value in strings do
    if startsWithIgnoreCase(value, 'NC') then
      noCollision = value
      break
    end
  end

  local nodeIndex = c.collisionNode
  local node = if nodeIndex then get(c, nodeIndex, 'NiNode') else nil
  if not node then nodeIndex = nil end

  if not c.collision then
    local source: Base.CollisionSource
    if noCollision then
      source = if string.sub(noCollision, 3, 3) == 'C' then 'camera_only' else 'none'
    elseif node then
      source = if #node.children == 0 then 'camera_only' else 'root_collision_node'
    else
      source = 'render_geometry'
    end

    c.collision = { source = source, node = nodeIndex, hidesMarkers = c.hasMarkers, bsxFlags = nil }
  end

  if noCollision then return end

  if node and nodeIndex then
    if #node.children == 0 then
      push(
        c,
        'info',
        'camera_only_collision',
        nodeIndex,
        'the RootCollisionNode is empty, so only the camera collides, with the render geometry'
      )
    end

    walk(c, nodeIndex, true)
  else
    walk(c, root, false)
  end

  reportInvisibleColliders(c, 'because there\'s no RootCollisionNode')
  if not node and c.stats.collisionTriangles > Constants.ManyCollisionTriangles then
    push(
      c,
      'performance',
      'render_geometry_collision',
      nil,
      `no RootCollisionNode, so collision is built from {c.stats.collisionTriangles} render triangles`
    )
  end
end

--- bulletnifloader.cpp `handleRoot` for 10.0.1.0 and later: collision only with root `BSXFlags`
--- bit 2, built from the render geometry; Havok collision objects are ignored.
local function checkBsx(c: Checker, root: number)
  local bsx = Base.bsxFlags(c, root)
  local collides = bsx ~= nil and bit32.btest(bsx, Constants.BsxCollision)
  if not c.collision then
    c.collision = {
      source = if collides then 'render_geometry' else 'none',
      node = nil,
      hidesMarkers = c.hasMarkers,
      bsxFlags = bsx,
    }
  end

  local havok = 0
  for index in c.reachable do
    local av = get(c, index, 'NiAVObject')
    if av and av.collision >= 0 then
      havok += 1
    end
  end

  if not collides then
    if havok > 0 then
      local why = if bsx
        then `the root's BSXFlags ({bsx}) don't set the collision bit (2)`
        else 'the root has no BSXFlags'
      push(
        c,
        'collision',
        'no_collision',
        root,
        `{why}, so OpenMW gives the model no collision, though it has Havok collision`
      )
    end

    return
  end

  if havok > 0 then
    push(
      c,
      'info',
      'havok_ignored',
      nil,
      'OpenMW ignores Havok collision and builds this model\'s collision from its render geometry'
    )
  end

  c.collisionMarkers = bsx ~= nil and bit32.btest(bsx, 32)
  walk(c, root, false)
  reportInvisibleColliders(c, 'since OpenMW builds collision from the render geometry')
  local uncollidable = c.uncollidableShapes
  c.uncollidableShapes = {}
  local first = uncollidable[1]
  if first then
    push(
      c,
      'collision',
      'shape_without_collision',
      first,
      `"{nameOf(c, first)}"{andMore(#uncollidable - 1)} is a {typeName(c, first)}, which OpenMW doesn't build collision from, so it doesn't collide`
    )
  end

  if c.stats.collisionTriangles > Constants.ManyCollisionTriangles then
    push(
      c,
      'performance',
      'render_geometry_collision',
      nil,
      `collision is built from {c.stats.collisionTriangles} render triangles, since OpenMW ignores Havok collision`
    )
  end
end

--- bulletnifloader.cpp `findBoundingBox`: the first "Bounding Box" object sets the actor's
--- collision box, and must be a box with positive extents.
local function checkBoundingBox(c: Checker, roots: { number })
  local stack = {}
  for i = #roots, 1, -1 do
    table.insert(stack, roots[i])
  end

  local seen = {}
  while #stack > 0 do
    local index = table.remove(stack) :: number
    if seen[index] then continue end

    seen[index] = true
    local av = get(c, index, 'NiAVObject')
    if not av then continue end

    if string.lower(av.name) == 'bounding box' then
      local bounds = av.bounds
      local extents = if bounds.type == 1 then bounds.box.extents else nil
      local valid = extents ~= nil and extents.x > 0 and extents.y > 0 and extents.z > 0
      if not valid then
        push(
          c,
          'collision',
          'invalid_bounding_box',
          index,
          'Invalid Bounding Box node bounds: it needs a box bounding volume with positive extents'
        )
      end

      return
    end

    local node = get(c, index, 'NiNode')
    if node then
      local children = node.children
      for i = #children, 1, -1 do
        if children[i] >= 0 then table.insert(stack, children[i]) end
      end
    end
  end
end

return table.freeze {
  check = check,
  checkBsx = checkBsx,
  checkBoundingBox = checkBoundingBox,
}
