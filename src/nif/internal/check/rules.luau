--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Record-level checks for NIFs of every version OpenMW reads, over the multi-version reader's
records, following OpenMW's `nifosg` loader (`components/nifosg/nifloader.cpp`) and its collision
loader (`components/nifbullet/bulletnifloader.cpp`): a port of jess-nif's `check::gamebryo`.

Most rules apply to every version; the rest follow the loaders' branches by version or record
type: `BSXFlags` collision and editor markers, render geometry collision with Havok ignored,
`BSTriShape` geometry, Bethesda shader properties, interpolators, and the controllers, particles,
and animations OpenMW doesn't handle. The rules live in `base`, `scene`, `collision`, and
`properties`; this runs them in OpenMW's order.
]]

local Base = require './base'
local Collision = require './collision'
local Properties = require './properties'
local Reader = require '../gamebryo/reader'
local Scene = require './scene'
local Types = require './types'

type Checker = Base.Checker

local get, is, typeName, push = Base.get, Base.is, Base.typeName, Base.push
local Constants = Base.constants

--- nifloader.cpp `loadKf`: only `NiSequenceStreamHelper` animations load.
local function checkKf(c: Checker)
  local helper: number? = nil
  local sequences = false
  for _, root in c.file.roots do
    if root < 0 or root >= #c.records then continue end

    if not helper and is(c, root, 'NiSequenceStreamHelper') then helper = root end

    if is(c, root, 'NiControllerSequence') then sequences = true end
  end

  if not helper then
    push(
      c,
      'broken',
      'kf_without_sequence',
      nil,
      if sequences
        then 'Found no NiSequenceStreamHelper root record, so no animation loads; OpenMW doesn\'t read NiControllerSequence animations'
        else 'Found no NiSequenceStreamHelper root record, so no animation loads'
    )
    return
  end

  local net = get(c, helper, 'NiObjectNET')
  if not net then return end

  local extras = Base.extraList(c, net)
  local first = extras[1]
  if not first then
    push(
      c,
      'broken',
      'kf_without_text_keys',
      helper,
      'NiSequenceStreamHelper has no text keys, so the animation is discarded'
    )
    return
  end

  if not is(c, first, 'NiTextKeyExtraData') then
    push(
      c,
      'broken',
      'kf_without_text_keys',
      first,
      `First extra data was not a NiTextKeyExtraData, but a {typeName(c, first)}`
    )
    return
  end

  local chain = Base.controllers(c, net.controller)
  local keyframes = 0
  for i = 2, math.min(#extras, #chain + 1) do
    local extra, controller = extras[i], chain[i - 1][1]
    if not is(c, extra, 'NiStringExtraData') or not is(c, controller, 'NiKeyframeController') then
      push(
        c,
        'broken',
        'kf_unexpected_pair',
        extra,
        `Unexpected extra data {typeName(c, extra)} with controller {typeName(c, controller)}; the pair is skipped`
      )
      continue
    end

    local keyframe = get(c, controller, 'NiKeyframeController')
    local data = keyframe ~= nil and keyframe.data >= 0
    if
      (data or Base.hasInterpolator(c, controller))
      and Base.checkInterpolator(c, controller, 'NiTransformInterpolator')
    then
      keyframes += 1
    end
  end

  if keyframes == 0 then
    push(
      c,
      'broken',
      'kf_without_controllers',
      helper,
      'the KF has no keyframe controllers, so OpenMW discards it'
    )
  end
end

local function checkPerformance(c: Checker)
  local stats = c.stats
  -- Later files link records OpenMW reads but never resolves (Havok constraints and actions,
  -- additional geometry data, animation notes), which the reader doesn't follow.
  local unreachable = stats.records - stats.reachableRecords
  if unreachable > 0 and Base.morrowindRules(c) then
    push(
      c,
      'performance',
      'unreachable_records',
      nil,
      if unreachable == 1
        then '1 record isn\'t reachable from any root and is loaded for nothing'
        else `{unreachable} records aren't reachable from any root and are loaded for nothing`
    )
  end

  if stats.embeddedTextures > 0 then
    push(
      c,
      'performance',
      'embedded_textures',
      nil,
      `{stats.embeddedTextures} embedded textures ({stats.embeddedTextureBytes} bytes) can't be shared, compressed, or replaced like texture files`
    )
  end

  if stats.shapes > Constants.ManyShapes then
    push(
      c,
      'performance',
      'many_shapes',
      nil,
      `{stats.shapes} shapes: each one is at least one draw call`
    )
  end

  if stats.triangles > Constants.ManyTriangles then
    push(c, 'performance', 'many_triangles', nil, `{stats.triangles} triangles in one model`)
  end
end

local function run(c: Checker, rootsChecked: boolean)
  Base.findReachable(c, rootsChecked)
  local roots = {}
  for _, root in c.file.roots do
    if root >= 0 and root < #c.records and get(c, root, 'NiAVObject') then
      table.insert(roots, root)
    end
  end

  if c.kf then
    checkKf(c)
  elseif #roots == 0 then
    -- nifloader.cpp `load`: throws when no root is an NiAVObject.
    push(c, 'wont_load', 'no_root_nodes', nil, 'Found no root nodes')
  end

  Base.checkRootTransform(c)
  for _, root in roots do
    Base.checkRootStrings(c, root)
    Scene.walk(c, root, { texturing = nil, root = true })
    if Base.gamebryoCollision(c) then
      Collision.checkBsx(c, root)
    else
      Collision.check(c, root)
    end
  end

  Collision.checkBoundingBox(c, roots)
  Properties.check(c)
  Properties.collectTextures(c)
  checkPerformance(c)
end

--- Checks every record of `file`, read from `name` (`.kf` files are checked as animations), into
--- `report`.
local function check(name: string, file: Reader.File, report: Types.Report)
  report.deep = true
  local fileName = string.lower(string.match(name, '[^/\\]*$') or name)
  local rootsChecked = false
  for _, finding in report.findings do
    if finding.code == 'root_out_of_range' then rootsChecked = true end
  end

  local c: Checker = {
    file = file,
    records = file.records,
    version = file.header.version,
    kf = string.sub(fileName, -3) == '.kf',
    findings = {},
    textures = {},
    stats = {
      records = 0,
      reachableRecords = 0,
      nodes = 0,
      shapes = 0,
      vertices = 0,
      triangles = 0,
      collisionTriangles = 0,
      controllers = 0,
      embeddedTextures = 0,
      embeddedTextureBytes = 0,
      skinned = false,
    },
    reachable = {},
    properties = {},
    hasMarkers = false,
    collisionMarkers = false,
    collisionNode = nil,
    invisibleColliders = {},
    uncollidableShapes = {},
    collision = nil,
    listedEffects = {},
  }

  for index = 0, #file.records - 1 do
    local node = get(c, index, 'NiNode')
    if not node then continue end

    for _, effect in node.effects do
      if effect >= 0 then c.listedEffects[effect] = true end
    end
  end

  run(c, rootsChecked)
  table.move(c.findings, 1, #c.findings, #report.findings + 1, report.findings)
  report.textures = c.textures
  report.stats = c.stats
  report.collision = c.collision
end

return table.freeze { check = check }
