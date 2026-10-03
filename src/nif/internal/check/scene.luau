--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The render traversal's checks: what OpenMW's `NIFObjectLoader::handleNode` does to each node,
effect, shape, particle system, and their controllers.
]]

local Base = require './base'

type Checker = Base.Checker
type RenderState = Base.RenderState

local get, is, recordType, typeName, nameOf, push =
  Base.get, Base.is, Base.recordType, Base.typeName, Base.nameOf, Base.push
local startsWithIgnoreCase = Base.startsWithIgnoreCase
local Constants = Base.constants
local NiGeometryTypes, BsGeometryTypes = Constants.NiGeometryTypes, Constants.BsGeometryTypes

--- Calls `visit` with each triangle of a `u16` view of triples.
local function triangleList(list: any, visit: (number, number, number) -> ())
  local b, offset = list.buffer, list.offset
  for i = 0, list.count // 3 - 1 do
    local at = offset + i * 6
    visit(buffer.readu16(b, at), buffer.readu16(b, at + 2), buffer.readu16(b, at + 4))
  end
end

--- Calls `visit` with each triangle of strips, unrolled: strips shorter than 3 and degenerate
--- triangles are dropped.
local function unrollStrips(strips: any, visit: (number, number, number) -> ())
  for _, strip in strips do
    local b, offset = strip.buffer, strip.offset
    for i = 0, strip.count - 3 do
      local at = offset + i * 2
      local first, second, third =
        buffer.readu16(b, at), buffer.readu16(b, at + 2), buffer.readu16(b, at + 4)
      if i % 2 == 1 then
        second, third = third, second
      end

      if first ~= second and second ~= third and first ~= third then visit(first, second, third) end
    end
  end
end

--- `getPartitions`: a skin instance's own partitions, or its skin data's.
local function partitionsOf(c: Checker, skin: any): any
  local partitions = get(c, skin.partitions, 'NiSkinPartition')
  if partitions then return partitions end

  local data = get(c, skin.data, 'NiSkinData')
  return if data then get(c, data.partitions, 'NiSkinPartition') else nil
end

--- Calls `visit` with each triangle OpenMW draws and collides with: the skin partitions' when
--- there are any, otherwise the data's.
local function shapeTriangles(c: Checker, geometry: any, visit: (number, number, number) -> ())
  local skin = get(c, geometry.skin, 'NiSkinInstance')
  local partitions = if skin then partitionsOf(c, skin) else nil
  if partitions then
    for _, partition in partitions.partitions do
      triangleList(partition.trueTriangles, visit)
      unrollStrips(partition.trueStrips, visit)
    end

    return
  end

  if geometry.data < 0 then return end

  local shape = get(c, geometry.data, 'NiTriShapeData')
  if shape then
    triangleList(shape.triangles, visit)
    return
  end

  local strips = get(c, geometry.data, 'NiTriStripsData')
  if strips then unrollStrips(strips.strips, visit) end
end

--- How many triangles `shapeTriangles` visits, and the first vertex index at or past `vertices`.
local function countTriangles(c: Checker, geometry: any, vertices: number): (number, number?)
  local count = 0
  local bad: number? = nil
  shapeTriangles(c, geometry, function(first: number, second: number, third: number)
    count += 1
    if bad then return end

    if first >= vertices then
      bad = first
    elseif second >= vertices then
      bad = second
    elseif third >= vertices then
      bad = third
    end
  end)

  return count, bad
end

--- nifloader.cpp `handleNiGeometry`: `influences.at(vertex)` throws past the end.
local function checkSkinWeights(c: Checker, shape: number, skin: number, vertices: number)
  local instance = get(c, skin, 'NiSkinInstance')
  local data = if instance then get(c, instance.data, 'NiSkinData') else nil
  if not data then return end

  local worst = -1
  for _, bone in data.bones do
    local weights = bone.weights
    local b, offset = weights.buffer, weights.offset
    for i = 0, weights.count - 1 do
      local vertex = buffer.readu16(b, offset + i * 6)
      if vertex >= vertices and vertex > worst then worst = vertex end
    end
  end

  if worst < 0 then return end

  push(
    c,
    'wont_load',
    'skin_weight_out_of_range',
    shape,
    `the skin weights vertex {worst}, but the shape has {vertices} {if vertices == 1
      then 'vertex'
      else 'vertices'}`
  )
end

local function checkGeometry(c: Checker, index: number, kind: string, state: RenderState)
  local geometry = get(c, index, 'NiGeometry')
  if not geometry then return end

  local shapeType = typeName(c, index)
  local name = geometry.name

  -- node.cpp `NiGeometry::post`: data of the wrong kind is silently dropped.
  local dataIndex = geometry.data
  if dataIndex < 0 then return end

  local expected = if kind == 'NiTriStrips'
    then 'NiTriStripsData'
    elseif kind == 'NiLines' then 'NiLinesData'
    else 'NiTriShapeData'
  if not is(c, dataIndex, expected) then
    push(
      c,
      'broken',
      'wrong_geometry_data',
      index,
      `{shapeType} "{name}" has {typeName(c, dataIndex)} rather than {expected}, so it doesn't draw`
    )
    return
  end

  local data = get(c, dataIndex, 'NiGeometryData')
  if not data then return end

  local vertices = #data.vertices
  local triangles, bad = countTriangles(c, geometry, vertices)
  local linesData = get(c, dataIndex, 'NiLinesData')
  local lines = if linesData then #linesData.lines else 0
  local empty = if kind == 'NiLines' then lines == 0 else triangles == 0
  if vertices == 0 or empty then
    push(
      c,
      'info',
      'empty_geometry',
      index,
      `{shapeType} "{name}" has no triangles and isn't drawn`
    )
    return
  end

  c.stats.shapes += 1
  c.stats.vertices += vertices
  c.stats.triangles += triangles
  if bad then
    push(
      c,
      'broken',
      'vertex_index_out_of_range',
      dataIndex,
      `"{name}" uses vertex {bad} of {vertices}; this may crash OpenMW`
    )
  end

  -- nifloader.cpp `handleNiGeometryData`: a missing UV set falls back to set 0.
  local uvSets = #data.uvList
  local texturing = get(c, state.texturing, 'NiTexturingProperty')
  if texturing then
    for slot, texture in texturing.textures do
      if not texture.enabled then continue end

      local set = texture.uvSet
      if slot - 1 < Constants.TextureStages and set >= uvSets and uvSets > 0 then
        push(
          c,
          'broken',
          'uv_set_out_of_range',
          index,
          `"{name}" texture slot {slot - 1} uses UV set {set} but has {uvSets}; UV set 0 is used instead`
        )
      end
    end
  end

  if geometry.skin >= 0 then
    c.stats.skinned = true
    checkSkinWeights(c, index, geometry.skin, vertices)
  end
end

--- nifloader.cpp `handleBSGeometry`.
local function checkBsGeometry(c: Checker, index: number)
  local shape = get(c, index, 'BSTriShape')
  if not shape then return end

  local shapeType = typeName(c, index)
  local name = shape.name
  local vertices = if bit32.btest(shape.vertDesc.flags, 0x1) then #shape.vertData else 0
  local triangles = 0
  local bad: number? = nil
  triangleList(shape.triangles, function(first: number, second: number, third: number)
    triangles += 1
    if bad then return end

    if first >= vertices then
      bad = first
    elseif second >= vertices then
      bad = second
    elseif third >= vertices then
      bad = third
    end
  end)

  if vertices == 0 or triangles == 0 then
    push(
      c,
      'info',
      'empty_geometry',
      index,
      `{shapeType} "{name}" has no triangles and isn't drawn`
    )
    return
  end

  c.stats.shapes += 1
  c.stats.vertices += vertices
  c.stats.triangles += triangles
  if bad then
    push(
      c,
      'broken',
      'vertex_index_out_of_range',
      index,
      `"{name}" uses vertex {bad} of {vertices}; this may crash OpenMW`
    )
  end

  local skin = shape.skin
  if skin < 0 then return end

  c.stats.skinned = true
  -- Only Fallout 4's skinning is handled; Skyrim SE's isn't yet.
  local problem: string? = nil
  if not is(c, skin, 'BSSkinInstance') then
    problem =
      `"{name}" is skinned with {typeName(c, skin)}, which OpenMW doesn't support yet, so it's drawn unskinned`
  elseif not bit32.btest(shape.vertDesc.flags, 0x40) then
    problem = `"{name}" has a skin but its vertices have no skin weights, so it's drawn unskinned`
  end

  if problem then push(c, 'broken', 'unsupported_skinning', index, problem) end
end

local function checkParticleModifier(c: Checker, modifier: number, collider: boolean)
  local kind = recordType(c, modifier)
  if collider then
    if kind ~= 'NiPlanarCollider' and kind ~= 'NiSphericalCollider' then
      push(
        c,
        'broken',
        'unhandled_particle_modifier',
        modifier,
        `Unhandled particle collider {typeName(c, modifier)}`
      )
    end

    return
  end

  if kind == 'NiParticleGrowFade' or kind == 'NiGravity' or kind == 'NiParticleBomb' then return end

  if kind == 'NiParticleRotation' then
    push(c, 'info', 'particle_rotation_ignored', modifier, 'NiParticleRotation is ignored')
    return
  end

  if kind == 'NiParticleColorModifier' then
    local color = get(c, modifier, 'NiParticleColorModifier')
    if color and color.data < 0 then
      push(
        c,
        'broken',
        'controller_without_data',
        modifier,
        'NiParticleColorModifier without color data is skipped'
      )
    end

    return
  end

  push(
    c,
    'broken',
    'unhandled_particle_modifier',
    modifier,
    `Unhandled particle modifier {typeName(c, modifier)}`
  )
end

--- nifloader.cpp `handleParticleSystem`, `handleParticlePrograms`.
local function checkParticles(c: Checker, index: number)
  local particles = get(c, index, 'NiGeometry')
  if not particles then return end

  local name = particles.name
  local chain = Base.controllers(c, particles.controller)
  local function isSystemController(controller: number): boolean
    local kind = recordType(c, controller)
    return kind == 'NiParticleSystemController' or kind == 'NiBSPArrayController'
  end

  local controllerIndex, controller = nil, nil
  for i = #chain, 1, -1 do
    local entry = chain[i]
    if not Base.isActive(entry[2]) or not isSystemController(entry[1]) then continue end

    local system = get(c, entry[1], 'NiParticleSystemController')
    if system then
      controllerIndex, controller = entry[1], system
      break
    end
  end

  if not controller then
    for _, entry in chain do
      if isSystemController(entry[1]) then
        push(
          c,
          'info',
          'inactive_particles',
          index,
          `"{name}" has only inactive particle controllers, so it has no particles`
        )
        return
      end
    end

    push(
      c,
      'broken',
      'particles_without_controller',
      index,
      `No particle controller found for "{name}", so it has no particles`
    )
    return
  end

  c.stats.shapes += 1
  if controller.emitter < 0 then
    push(
      c,
      'broken',
      'particles_without_emitter',
      controllerIndex,
      'the particle controller has no emitter, so nothing is emitted'
    )
  end

  local function chain(first: number, colliders: boolean)
    local seen, count = {}, 0
    local link = first
    while count < 4096 do
      if link < 0 or seen[link] then break end

      seen[link] = true
      count += 1
      local object = get(c, link, 'NiParticleModifier')
      if not object then break end

      checkParticleModifier(c, link, colliders)
      link = object.next
    end
  end

  chain(controller.modifier, false)
  chain(controller.collider, true)
end

--- nifloader.cpp `handleEffect`: only enabled, sphere-mapped environment maps work.
local function checkEffect(c: Checker, index: number)
  if not is(c, index, 'NiTextureEffect') then
    if c.records[index + 1] then
      push(
        c,
        'info',
        'light_ignored',
        index,
        `Unhandled effect {typeName(c, index)}; NIF lights don't light anything`
      )
    end

    return
  end

  local effect = get(c, index, 'NiTextureEffect')
  if not effect or not effect.switchState then return end

  -- `NiTextureEffect::TextureType::Environment_Map` and `CoordGenType::Sphere_Map`.
  if effect.textureType ~= 2 then
    push(
      c,
      'broken',
      'unhandled_texture_effect',
      index,
      `Unhandled NiTextureEffect type {effect.textureType}`
    )
  elseif effect.texture < 0 then
    push(
      c,
      'broken',
      'texture_effect_without_texture',
      index,
      'NiTextureEffect missing source texture'
    )
  elseif effect.coordGenType ~= 2 then
    push(
      c,
      'broken',
      'unhandled_texture_effect',
      index,
      `Unhandled NiTextureEffect CoordGenType {effect.coordGenType}`
    )
  end
end

local function checkNode(c: Checker, index: number, node: any)
  local kind = recordType(c, index)
  if kind == 'NiBillboardNode' then
    -- nifloader.cpp `createNode`: other modes fall back to rigid face camera.
    local billboard = get(c, index, 'NiBillboardNode')
    local mode = if billboard then billboard.mode else 0
    local unhandled: string? = nil
    if mode == 3 then
      unhandled = 'always face center'
    elseif mode == 4 then
      unhandled = 'rigid face center'
    elseif mode ~= 0 and mode ~= 1 and mode ~= 2 and mode ~= 5 then
      unhandled = 'unknown'
    end

    if unhandled then
      push(
        c,
        'broken',
        'unhandled_billboard_mode',
        index,
        `Unhandled billboard mode {mode} ({unhandled}); it falls back to rigid face camera`
      )
    end
  elseif kind == 'NiSortAdjustNode' then
    local sort = get(c, index, 'NiSortAdjustNode')
    if sort then
      if sort.subSorter < 0 then
        push(
          c,
          'broken',
          'empty_accumulator',
          index,
          'Empty accumulator found in NiSortAdjustNode; it has no effect'
        )
      else
        push(
          c,
          'info',
          'sort_adjust_leaks',
          index,
          'OpenMW applies an NiSortAdjustNode\'s sorting to every shape after it in the file, not just its children'
        )
      end
    end
  end

  for _, effect in node.effects do
    if effect >= 0 then checkEffect(c, effect) end
  end

  for _, child in node.children do
    if child < 0 then continue end

    if get(c, child, 'NiDynamicEffect') and not c.listedEffects[child] then
      push(
        c,
        'info',
        'effect_in_children',
        child,
        `{typeName(c, child)} is a child but in no node's effect list, so it does nothing`
      )
    end
  end
end

--- What `handleNode` draws of a visible leaf: particles, geometry, and `BSTriShape`s, minus
--- shadows and hidden editor markers.
local function checkShape(c: Checker, index: number, state: RenderState)
  local kind = recordType(c, index)
  if not kind then return end

  local name = nameOf(c, index)
  -- nifloader.cpp `handleNode`: particles are handled before and apart from geometry.
  if kind == 'NiParticles' then
    checkParticles(c, index)
    return
  end

  -- Neither NiParticles nor geometry, so nothing handles them.
  if kind == 'NiParticleSystem' or kind == 'BSStripParticleSystem' then
    push(
      c,
      'broken',
      'unsupported_particles',
      index,
      `{typeName(c, index)} "{name}" isn't drawn; OpenMW only handles Morrowind-style NiParticles`
    )
    return
  end

  if not NiGeometryTypes[kind] and not BsGeometryTypes[kind] then return end

  if Base.morrowindRules(c) then
    if startsWithIgnoreCase(name, 'shadow') or startsWithIgnoreCase(name, 'tri shadow') then
      return
    end

    if startsWithIgnoreCase(name, 'tri editormarker') then
      if c.hasMarkers then return end

      push(
        c,
        'broken',
        'visible_editor_marker',
        index,
        `"{name}" draws in game because the root has no "MRK" string data`
      )
    end
  elseif
    startsWithIgnoreCase(name, 'EditorMarker')
    or startsWithIgnoreCase(name, 'VisibilityEditorMarker')
  then
    if c.hasMarkers then return end

    push(
      c,
      'broken',
      'visible_editor_marker',
      index,
      `"{name}" draws in game because the root has neither "MRK" string data nor the BSXFlags editor marker bit (32)`
    )
  end

  if BsGeometryTypes[kind] then
    checkBsGeometry(c, index)
  else
    checkGeometry(c, index, kind, state)
  end
end

type Pending = { index: number, state: RenderState? }

--- One node of the render traversal; its children go on `stack`, the first on top.
local function walkNode(
  c: Checker,
  index: number,
  from: RenderState,
  seen: { [number]: boolean },
  stack: { Pending }
)
  local av = get(c, index, 'NiAVObject')
  if not av or seen[index] then return end

  seen[index] = true
  local state: RenderState = { texturing = from.texturing, root = false }
  -- Non-root "Bounding Box" objects are dropped.
  if not from.root and string.lower(av.name) == 'bounding box' then return end

  local node = get(c, index, 'NiNode')
  if node then
    c.stats.nodes += 1
  end

  for _, property in av.properties do
    if property >= 0 then table.insert(c.properties, property) end
  end

  -- applyNodeProperties: geometry's shader and alpha properties.
  local geometry = get(c, index, 'NiGeometry') or get(c, index, 'BSTriShape')
  if geometry then
    if geometry.shaderProperty >= 0 then table.insert(c.properties, geometry.shaderProperty) end

    if geometry.alphaProperty >= 0 then table.insert(c.properties, geometry.alphaProperty) end
  end

  for _, property in av.properties do
    if property >= 0 and is(c, property, 'NiTexturingProperty') then state.texturing = property end
  end

  local chain = Base.controllers(c, av.controller)
  local hasVisController = false
  for _, entry in chain do
    if is(c, entry[1], 'NiVisController') then hasVisController = true end
  end

  Base.checkNodeControllers(c, index, chain)

  -- Hidden subtrees (flag 0x1) stay in the graph for their controllers, but only draw with an
  -- NiVisController on the hidden node itself. The collision node is hidden too.
  local hidden = (bit32.btest(av.flags, 1) and not hasVisController) or index == c.collisionNode
  if node then
    checkNode(c, index, node)
    local childState = if hidden then nil else state
    local children = node.children
    for i = #children, 1, -1 do
      local child = children[i]
      if child >= 0 then table.insert(stack, { index = child, state = childState }) end
    end
  elseif not hidden then
    checkShape(c, index, state)
  end
end

--- Hidden subtrees: controllers still load, nothing draws.
local function walkHiddenNode(
  c: Checker,
  index: number,
  seen: { [number]: boolean },
  stack: { Pending }
)
  local av = get(c, index, 'NiAVObject')
  if not av or seen[index] then return end

  seen[index] = true
  Base.checkNodeControllers(c, index, Base.controllers(c, av.controller))
  local node = get(c, index, 'NiNode')
  if not node then return end

  local children = node.children
  for i = #children, 1, -1 do
    local child = children[i]
    if child >= 0 then table.insert(stack, { index = child, state = nil }) end
  end
end

--- The render traversal, `NIFObjectLoader::handleNode`: depth first, children in order, without
--- recursion. A child without a render state is in a hidden subtree.
local function walk(c: Checker, root: number, state: RenderState)
  local seen = {}
  local stack: { Pending } = { { index = root, state = state } }
  while #stack > 0 do
    local pending = table.remove(stack) :: Pending
    if pending.state then
      walkNode(c, pending.index, pending.state, seen, stack)
    else
      walkHiddenNode(c, pending.index, seen, stack)
    end
  end
end

return table.freeze {
  walk = walk,
  shapeTriangles = shapeTriangles,
  countTriangles = countTriangles,
}
