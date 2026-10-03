--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Record-level checks for NIFs of every version OpenMW reads, over the multi-version reader's
records, following OpenMW's `nifosg` loader (`components/nifosg/nifloader.cpp`) and its collision
loader (`components/nifbullet/bulletnifloader.cpp`): a port of jess-nif's `check::gamebryo`.

Most rules apply to every version; the rest follow the loaders' branches by version or record
type: `BSXFlags` collision and editor markers, render geometry collision with Havok ignored,
`BSTriShape` geometry, Bethesda shader properties, interpolators, and the controllers, particles,
and animations OpenMW doesn't handle. Records are 0-based by index, as in the file.
]]

local L = require '../gamebryo/links'
local Load = require '../gamebryo/load'
local Reader = require '../gamebryo/reader'
local Types = require './types'

type File = Reader.File
type Report = Types.Report
export type Severity = Types.Severity
export type CollisionSource = Types.CollisionSource
type Finding = Types.Finding
type Stats = Types.Stats
type Collision = Types.Collision

local Is = L.is

--- Past this many controllers or modifiers a chain is treated as a loop.
local MaxChain = 4096
--- Rendered shapes past which a single model is a lot of draw calls.
local ManyShapes = 100
--- Rendered triangles past which a single model is heavy.
local ManyTriangles = 50000
--- Collision triangles, built from render geometry, past which collision is heavy.
local ManyCollisionTriangles = 5000
--- `NiTexturingProperty` slots OpenMW binds: base, dark, detail, gloss, glow, bump, decal.
local TextureStages = 7
--- `BSShaderTextureSet` slots OpenMW binds: diffuse, normal, glow.
local TextureSetStages = 3
--- `NiMaterialColorController::TargetColor::Specular`.
local TargetSpecular = 2
--- `BSXFlags` bit that gives a model collision.
local BsxCollision = 2
--- `BSXFlags` bit that hides editor markers.
local BsxEditorMarkers = 32
--- `NIFFile::VER_MW` and `VER_BGS`.
local VerMw, VerBgs = 0x04000002, 0x14020007

local NiGeometryTypes: { [string]: boolean } = table.freeze({
  NiTriShape = true,
  NiTriStrips = true,
  NiLines = true,
  BSLODTriShape = true,
  BSSegmentedTriShape = true,
} :: { [string]: boolean })

local BsGeometryTypes: { [string]: boolean } = table.freeze({
  BSTriShape = true,
  BSDynamicTriShape = true,
  BSMeshLODTriShape = true,
  BSSubIndexTriShape = true,
} :: { [string]: boolean })

--- Shapes `getCollisionShape` builds a mesh from: `NiTriShape` and `NiTriStrips`, and the
--- `NiTriShape` subclasses.
local CollidingTypes: { [string]: boolean } = table.freeze({
  NiTriShape = true,
  NiTriStrips = true,
  BSLODTriShape = true,
  BSSegmentedTriShape = true,
} :: { [string]: boolean })

--- Whether a transform is identity up to the float noise exporters leave, which changes nothing.
local function isIdentityTransform(
  translation: vector,
  rotation: { vector },
  scale: number
): boolean
  local function near(value: number, expected: number): boolean
    return math.abs(value - expected) <= 1e-5
  end

  if not (near(translation.x, 0) and near(translation.y, 0) and near(translation.z, 0)) then
    return false
  end

  for row = 1, 3 do
    local values = rotation[row]
    if
      not (
        near(values.x, if row == 1 then 1 else 0)
        and near(values.y, if row == 2 then 1 else 0)
        and near(values.z, if row == 3 then 1 else 0)
      )
    then
      return false
    end
  end

  return near(scale, 1)
end

local function startsWithIgnoreCase(text: string, prefix: string): boolean
  return #text >= #prefix and string.lower(string.sub(text, 1, #prefix)) == string.lower(prefix)
end

--- Scene-graph state inherited from ancestors: the texturing property in effect (a child's
--- replaces its parent's), and whether this is the root.
export type RenderState = { texturing: number?, root: boolean }

export type CollisionState = { hidden: boolean, shadowNamed: boolean, boundingBox: boolean }

export type Checker = {
  file: File,
  records: { any },
  version: number,
  --- A `.kf` animation rather than a model.
  kf: boolean,
  findings: { Finding },
  textures: { string },
  stats: Stats,
  reachable: { [number]: boolean },
  --- Properties on rendered objects, checked once each.
  properties: { number },
  --- Editor markers aren't drawn: root `MRK` string data, or root `BSXFlags` bit 32.
  hasMarkers: boolean,
  --- The collision loader skips editor markers: `Tri EditorMarker` shapes with root `MRK` in
  --- Morrowind-era files, `EditorMarker` shapes with `BSXFlags` bit 32 in later ones.
  collisionMarkers: boolean,
  --- The `RootCollisionNode` OpenMW hides from rendering.
  collisionNode: number?,
  --- Shapes that collide without drawing, and why they don't draw.
  invisibleColliders: { { any } },
  --- Shapes of a type the collision loader skips, in files whose render geometry collides.
  uncollidableShapes: { number },
  --- The first root's collision setup.
  collision: Collision?,
  --- Every effect in some node's effect list; effects are usually children as well.
  listedEffects: { [number]: boolean },
}

--- Record `index` when it is or derives from `class`.
local function get(c: Checker, index: number?, class: string): any
  if not index or index < 0 then return nil end

  local record = c.records[index + 1]
  if not record or not Is[c.file.classes[index + 1]][class] then return nil end

  return record
end

local function recordType(c: Checker, index: number): string? return c.file.recordTypes[index + 1] end

local function is(c: Checker, index: number, kind: string): boolean
  return c.file.recordTypes[index + 1] == kind
end

local function typeName(c: Checker, index: number): string return c.file.names[index + 1] or '' end

local function nameOf(c: Checker, index: number): string
  local net = get(c, index, 'NiObjectNET')
  return if net then net.name else ''
end

local function push(
  c: Checker,
  severity: Severity,
  code: string,
  record: number?,
  message: string
)
  table.insert(c.findings, { severity = severity, code = code, message = message, record = record })
end

--- The controllers chained from `first`, stopping at a missing link or a loop, as
--- `{ index, controller }` pairs.
local function controllers(c: Checker, first: number): { { any } }
  local chain, seen = {}, {}
  local link = first
  while #chain < MaxChain do
    if link < 0 or seen[link] then break end

    seen[link] = true
    local controller = get(c, link, 'NiTimeController')
    if not controller then break end

    table.insert(chain, { link, controller })
    link = controller.next
  end

  return chain
end

--- `NiObjectNET::getExtraList`: the extra data list, then the chain older files use.
local function extraList(c: Checker, net: any): { number }
  local list = {}
  for _, index in net.extraList do
    if index >= 0 then table.insert(list, index) end
  end

  local seen = {}
  local link = net.extra
  while #list < MaxChain do
    if link < 0 or seen[link] then break end

    seen[link] = true
    local extra = get(c, link, 'Extra')
    if not extra then break end

    table.insert(list, link)
    link = extra.next
  end

  return list
end

local function rootExtra(c: Checker, root: number): { number }
  local net = get(c, root, 'NiObjectNET')
  return if net then extraList(c, net) else {}
end

local function rootStrings(c: Checker, root: number): { string }
  local strings = {}
  for _, index in rootExtra(c, root) do
    if not is(c, index, 'NiStringExtraData') then continue end

    local extra = get(c, index, 'NiStringExtraData')
    if extra then table.insert(strings, extra.data) end
  end

  return strings
end

--- The root's first `BSXFlags` (bulletnifloader.cpp `handleRoot`).
local function bsxFlags(c: Checker, root: number): number?
  for _, index in rootExtra(c, root) do
    if not is(c, index, 'BSXFlags') then continue end

    local flags = get(c, index, 'NiIntegerExtraData')
    return if flags then flags.data else nil
  end

  return nil
end

local function contains(list: { string }, value: string): boolean
  return table.find(list, value) ~= nil
end

--- Morrowind-era files (up to 4.0.0.2), which get Morrowind's shadow, marker, and specular rules.
local function morrowindRules(c: Checker): boolean return c.version <= VerMw end

--- Files before 10.0.1.0 collide by `RootCollisionNode` and string data; later ones by `BSXFlags`.
local function gamebryoCollision(c: Checker): boolean return c.version >= 0x0A000100 end

local function findReachable(c: Checker, rootsChecked: boolean)
  local file = c.file
  local stack = {}
  for _, root in file.roots do
    if root >= 0 and root < #c.records then table.insert(stack, root) end
  end

  local count = 0
  while #stack > 0 do
    local index = table.remove(stack) :: number
    local record = c.records[index + 1]
    if not record or c.reachable[index] then continue end

    c.reachable[index] = true
    count += 1
    local codec: any = (Load :: any)[file.classes[index + 1]]
    for _, link in L.of(record, codec.check, c.records, file.classes, index) do
      if link >= 0 then table.insert(stack, link) end
    end
  end

  c.stats.records = #c.records
  c.stats.reachableRecords = count
  if rootsChecked then return end

  for position, root in file.roots do
    if root < -1 or root >= #c.records then
      push(
        c,
        'broken',
        'root_out_of_range',
        nil,
        `Root {position - 1} does not point to a record, so it's skipped`
      )
    end
  end
end

--- node.cpp `NiNode::read`: record 0's transform is discarded when it's a node other than
--- `Bip01`, in Morrowind-era and Fallout 3 and later files (not Oblivion's).
local function checkRootTransform(c: Checker)
  if c.version > VerMw and c.version < VerBgs then return end

  local node = get(c, 0, 'NiNode')
  if not node then return end

  local transform = node.transform
  local identity = isIdentityTransform(transform.translation, transform.rotation, transform.scale)
  if identity or string.lower(node.name) == 'bip01' then return end

  push(
    c,
    'info',
    'root_transform_ignored',
    0,
    `the root node "{node.name}" has a transform, which OpenMW ignores like Morrowind does`
  )
end

--- node.cpp `findRootCollisionNode`: children in reverse, searching each one's subtree before the
--- next child only with `RCN`. Depth first without recursion.
local function findCollisionNode(c: Checker, root: number, recursive: boolean): number?
  local node = get(c, root, 'NiNode')
  if not node then return nil end

  local seen = { [root] = true }
  -- The stack pops the last child first.
  local stack = {}
  for _, child in node.children do
    if child >= 0 then table.insert(stack, child) end
  end

  while #stack > 0 do
    local child = table.remove(stack) :: number
    if is(c, child, 'RootCollisionNode') then return child end

    if not recursive then continue end

    local inner = get(c, child, 'NiNode')
    if inner and not seen[child] then
      seen[child] = true
      for _, grandchild in inner.children do
        if grandchild >= 0 then table.insert(stack, grandchild) end
      end
    end
  end

  return nil
end

--- nifloader.cpp `handleNode` at the root: `MRK` string data or `BSXFlags` bit 32 hides editor
--- markers, and `RCN` searches for the collision node recursively.
local function checkRootStrings(c: Checker, root: number)
  local strings = rootStrings(c, root)
  local stringRecords = {}
  for _, index in rootExtra(c, root) do
    if not is(c, index, 'NiStringExtraData') then continue end

    local extra = get(c, index, 'NiStringExtraData')
    if extra then table.insert(stringRecords, { index, extra.data }) end
  end

  local bsx = bsxFlags(c, root)
  c.hasMarkers = contains(strings, 'MRK') or (bsx ~= nil and bit32.btest(bsx, BsxEditorMarkers))
  c.collisionNode = findCollisionNode(c, root, contains(strings, 'RCN'))
  if gamebryoCollision(c) then return end

  for _, entry in stringRecords do
    local index, value = entry[1], entry[2]
    -- bulletnifloader.cpp: only an uppercase third letter makes "NCC" camera-only.
    if startsWithIgnoreCase(value, 'NC') and string.sub(value, 3, 3) == 'c' then
      -- The string data record, which `nif fix` changes, not the root.
      push(
        c,
        'collision',
        'lowercase_ncc',
        index,
        `"{value}" turns collision off entirely; only an uppercase "NCC" keeps camera collision`
      )
    end
  end
end

local function isActive(controller: any): boolean return bit32.btest(controller.flags, 0x8) end

--- An interpolator of a type the controller can't use makes OpenMW skip the controller.
local function checkInterpolator(c: Checker, controller: number, expected: string): boolean
  local single = get(c, controller, 'NiSingleInterpController')
  if not single or single.interpolator < 0 then return true end

  local interpolator = single.interpolator
  if is(c, interpolator, expected) then return true end

  push(
    c,
    'broken',
    'unsupported_interpolator',
    controller,
    `Unsupported interpolator type for {typeName(c, controller)}: {typeName(c, interpolator)}, so the controller is skipped`
  )
  return false
end

local function hasInterpolator(c: Checker, controller: number): boolean
  local single = get(c, controller, 'NiSingleInterpController')
  return single ~= nil and single.interpolator >= 0
end

local function checkNodeController(c: Checker, index: number)
  local kind = recordType(c, index)
  if kind == 'NiPathController' then
    local path = get(c, index, 'NiPathController')
    if not path then return end

    if path.pathData < 0 or path.percentData < 0 then
      push(
        c,
        'broken',
        'controller_without_data',
        index,
        'NiPathController without path or percent data is skipped'
      )
    elseif path.pathFlags ~= 0 then
      -- controller.cpp `PathController`: only the position along the path is applied.
      push(
        c,
        'broken',
        'path_flags_ignored',
        index,
        'NiPathController\'s follow, bank, and flip flags are ignored; only the position is animated'
      )
    end
  elseif kind == 'NiLookAtController' then
    local lookAt = get(c, index, 'NiLookAtController')
    if lookAt and lookAt.lookAt < 0 then
      push(
        c,
        'broken',
        'controller_without_data',
        index,
        'NiLookAtController without a target is skipped'
      )
    end
  elseif kind == 'NiKeyframeController' then
    local keyframe = get(c, index, 'NiKeyframeController')
    local data = keyframe ~= nil and keyframe.data >= 0
    if not data and not hasInterpolator(c, index) then
      push(
        c,
        'info',
        'controller_without_data',
        index,
        `{typeName(c, index)} without data is skipped`
      )
    else
      checkInterpolator(c, index, 'NiTransformInterpolator')
    end
  elseif kind == 'NiVisController' then
    checkInterpolator(c, index, 'NiBoolInterpolator')
  elseif kind == 'NiRollController' then
    checkInterpolator(c, index, 'NiFloatInterpolator')
  end
end

local function shapeData(c: Checker, index: number): any
  local geometry = get(c, index, 'NiGeometry')
  return if geometry then get(c, geometry.data, 'NiGeometryData') else nil
end

local function checkMorpher(c: Checker, owner: number, index: number, skinned: boolean)
  if skinned then
    push(
      c,
      'broken',
      'morpher_on_skinned_shape',
      index,
      'NiGeomMorpherController is ignored on skinned shapes'
    )
    return
  end

  local data = shapeData(c, owner)
  local vertices = if data then #data.vertices else 0
  local controller = get(c, index, 'NiGeomMorpherController')
  local morphData = if controller then get(c, controller.data, 'NiMorphData') else nil
  local base = if morphData then morphData.morphs[1] else nil
  if not base then
    push(
      c,
      'broken',
      'controller_without_data',
      index,
      'NiGeomMorpherController without morphs is skipped'
    )
    return
  end

  if #base.vertices == vertices then return end

  push(
    c,
    'broken',
    'morph_vertex_mismatch',
    index,
    `the base morph has {#base.vertices} vertices but the shape has {vertices}, so the morph is ignored`
  )
end

--- nifloader.cpp `handleNodeControllers`, `handleMeshControllers`, and the morpher in
--- `handleNiGeometry`.
local function checkNodeControllers(c: Checker, owner: number, chain: { { any } })
  local ownerType = typeName(c, owner)
  local ownerKind = recordType(c, owner)
  local isNiGeometry = ownerKind ~= nil and NiGeometryTypes[ownerKind] == true
  local isMesh = isNiGeometry or (ownerKind ~= nil and BsGeometryTypes[ownerKind] == true)
  local isParticles = ownerKind == 'NiParticles'
  local geometry = get(c, owner, 'NiGeometry')
  local skinned = geometry ~= nil and geometry.skin >= 0
  -- Particle systems OpenMW doesn't draw are reported once, as unsupported_particles.
  local unsupportedParticles = ownerKind == 'NiParticleSystem'
    or ownerKind == 'BSStripParticleSystem'
  for _, entry in chain do
    local index, controller = entry[1], entry[2]
    -- Inactive controllers are skipped everywhere except in KF files.
    if not isActive(controller) then continue end

    c.stats.controllers += 1
    if unsupportedParticles then continue end

    local name = typeName(c, index)
    local kind = recordType(c, index)
    if
      kind == 'NiKeyframeController'
      or kind == 'NiPathController'
      or kind == 'NiVisController'
      or kind == 'NiRollController'
      or kind == 'NiLookAtController'
    then
      checkNodeController(c, index)
    elseif kind == 'NiUVController' and isMesh then
      continue
    elseif kind == 'NiGeomMorpherController' and isNiGeometry then
      checkMorpher(c, owner, index, skinned)
    elseif
      (kind == 'NiParticleSystemController' or kind == 'NiBSPArrayController') and isParticles
    then
      continue
    elseif
      kind == 'NiUVController'
      or kind == 'NiGeomMorpherController'
      or kind == 'NiParticleSystemController'
      or kind == 'NiBSPArrayController'
    then
      push(
        c,
        'broken',
        'controller_does_nothing',
        index,
        `{name} on {ownerType} does nothing; it only works on geometry`
      )
    else
      push(c, 'broken', 'unhandled_controller', index, `Unhandled controller {name} on {ownerType}`)
    end
  end
end

return {
  get = get,
  is = is,
  recordType = recordType,
  typeName = typeName,
  nameOf = nameOf,
  push = push,
  controllers = controllers,
  extraList = extraList,
  rootExtra = rootExtra,
  rootStrings = rootStrings,
  bsxFlags = bsxFlags,
  morrowindRules = morrowindRules,
  gamebryoCollision = gamebryoCollision,
  findReachable = findReachable,
  checkRootTransform = checkRootTransform,
  checkRootStrings = checkRootStrings,
  checkNodeControllers = checkNodeControllers,
  shapeData = shapeData,
  isActive = isActive,
  checkInterpolator = checkInterpolator,
  hasInterpolator = hasInterpolator,
  startsWithIgnoreCase = startsWithIgnoreCase,
  isIdentityTransform = isIdentityTransform,
  constants = {
    ManyShapes = ManyShapes,
    ManyTriangles = ManyTriangles,
    ManyCollisionTriangles = ManyCollisionTriangles,
    TextureStages = TextureStages,
    TextureSetStages = TextureSetStages,
    TargetSpecular = TargetSpecular,
    BsxCollision = BsxCollision,
    NiGeometryTypes = NiGeometryTypes,
    BsGeometryTypes = BsGeometryTypes,
    CollidingTypes = CollidingTypes,
  },
}
