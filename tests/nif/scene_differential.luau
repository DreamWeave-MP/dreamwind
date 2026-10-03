--!nonstrict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Holds the package's scene to jess-nif's, file by file, field by field, against
`jess.nif.sceneBytes`: every node and its transforms, drawable, geometry and its packed buffers,
material, texture, skin, bone, and issue, and the text dump. Floats compare as the 32-bit values
they are; NaN equals NaN. An enum value jess-nif has no name for reads as its default there and
as the file's number in the port: counted in `known`, not a difference.
]]

local Nif = require '../../src/nif/init'
local Scene = require '../../src/nif/internal/scene'

local Known = { lossyEnums = 0 }

--- The scene's buffers: each one's name, element kind, and element size.
local Buffers = table.freeze {
  { 'positions', 'f32', 4 },
  { 'normals', 'f32', 4 },
  { 'colors', 'f32', 4 },
  { 'uvs', 'f32', 4 },
  { 'indices', 'u16', 2 },
  { 'skinVertices', 'u16', 2 },
  { 'skinWeights', 'f32', 4 },
}

local function same(rust: any, mine: any): boolean
  if rust == jess.null then rust = nil end

  if type(rust) == 'number' and type(mine) == 'number' then
    return rust == mine or (rust ~= rust and mine ~= mine)
  end

  return rust == mine
end

local function vectorOf(rust: any): vector return vector.create(rust[1], rust[2], rust[3]) end

local function sameVector(rust: any, mine: vector): boolean
  return same(rust[1], mine.x) and same(rust[2], mine.y) and same(rust[3], mine.z)
end

local function check(bytes: buffer, path: string?): { string }
  local problems = {}
  local lossyBefore = Known.lossyEnums
  local function problem(text: string)
    if #problems < 12 then table.insert(problems, text) end
  end

  local okRust, rust = pcall(jess.nif.sceneBytes, bytes)
  local okOpen, nif = pcall(Nif.open, bytes)
  local okMine, mine = false, nil
  if okOpen then
    okMine, mine = pcall(Scene.build, nif)
  end

  if not okRust or not okMine then
    if okRust ~= okMine then
      problem(
        `jess-nif {if okRust then 'builds' else 'refuses'} the scene, the port {if okMine
          then 'builds'
          else 'refuses'} it: {if okRust then mine else rust}`
      )
    end

    return problems
  end

  local function field(where: string, name: string, rustValue: any, mineValue: any)
    if same(rustValue, mineValue) then return end

    if type(rustValue) == 'string' and type(mineValue) == 'number' then
      Known.lossyEnums += 1
      return
    end

    problem(`{where}.{name}: {tostring(mineValue)} where jess-nif has {tostring(rustValue)}`)
  end

  local function fields(where: string, rustTable: any, mineTable: any, names: { string })
    for _, name in names do
      field(where, name, rustTable[name], mineTable[name])
    end
  end

  local function affine(where: string, rustValue: any, mineValue: any)
    for i = 1, 4 do
      if not sameVector(rustValue[i], mineValue[i]) then
        problem(`{where}[{i}]: {mineValue[i]} where jess-nif has {vectorOf(rustValue[i])}`)
        return
      end
    end
  end

  local function range(where: string, rustValue: any, mineValue: any)
    if rustValue[1] ~= mineValue[1] or rustValue[2] ~= mineValue[2] then
      problem(
        `{where}: {mineValue[1]}..{mineValue[2]} where jess-nif has {rustValue[1]}..{rustValue[2]}`
      )
    end
  end

  local function bound(where: string, rustValue: any, mineValue: any)
    if
      not sameVector(rustValue.center, mineValue.center)
      or not same(rustValue.radius, mineValue.radius)
    then
      problem(`{where}: differs`)
    end
  end

  local function list(name: string, compare: (string, any, any) -> ())
    local rustList, mineList = rust[name], mine[name]
    if #rustList ~= #mineList then
      problem(`{#mineList} {name} where jess-nif has {#rustList}`)
      return
    end

    for i, rustItem in rustList do
      compare(`{name}[{i - 1}]`, rustItem, mineList[i])
    end
  end

  list('nodes', function(where, r, m)
    fields(
      where,
      r,
      m,
      { 'source', 'recordType', 'name', 'parent', 'subtreeEnd', 'billboard', 'visibility' }
    )
    affine(`{where}.local`, r['local'], m['local'])
    affine(`{where}.world`, r.world, m.world)
  end)

  list(
    'drawables',
    function(where, r, m) fields(where, r, m, { 'node', 'geometry', 'material', 'skin', 'layer' }) end
  )

  list('geometries', function(where, r, m)
    fields(where, r, m, { 'source', 'recordType', 'firstUv', 'uvSets', 'hasNormals', 'hasColors' })
    range(`{where}.vertices`, r.vertices, m.vertices)
    range(`{where}.indices`, r.indices, m.indices)
    bound(`{where}.bound`, r.bound, m.bound)
  end)

  list('materials', function(where, r, m)
    fields(where, r.sources, m.sources, {
      'texturing',
      'material',
      'alpha',
      'vertexColor',
      'zBuffer',
      'specular',
      'wireframe',
      'stencil',
    })
    fields(
      where,
      r,
      m,
      { 'applyMode', 'shininess', 'alpha', 'vertexColors', 'lit', 'cull', 'wireframe' }
    )
    for _, name in { 'ambient', 'diffuse', 'emissive', 'specular' } do
      if not sameVector(r[name], m[name]) then problem(`{where}.{name}: {m[name]}`) end
    end

    if not sameVector(r.storedSpecular.color, m.storedSpecular.color) then
      problem(`{where}.storedSpecular.color`)
    end

    fields(
      `{where}.storedSpecular`,
      r.storedSpecular,
      m.storedSpecular,
      { 'glossiness', 'enabled' }
    )
    fields(`{where}.depth`, r.depth, m.depth, { 'test', 'write' })
    for _, name in { 'baseTexture', 'darkTexture', 'glowTexture', 'blend', 'alphaTest' } do
      local rustSlot, mineSlot = r[name], m[name]
      if rustSlot == jess.null then rustSlot = nil end

      if (rustSlot == nil) ~= (mineSlot == nil) then
        problem(`{where}.{name}: {mineSlot ~= nil} where jess-nif has {rustSlot ~= nil}`)
      elseif rustSlot then
        for key, value in rustSlot do
          field(`{where}.{name}`, key, value, mineSlot[key])
        end
      end
    end
  end)

  list(
    'textures',
    function(where, r, m) fields(where, r, m, { 'source', 'kind', 'path', 'pixels' }) end
  )

  list('skins', function(where, r, m)
    fields(where, r, m, { 'source', 'data', 'root' })
    affine(`{where}.transform`, r.transform, m.transform)
    range(`{where}.bones`, r.bones, m.bones)
  end)

  list('skinBones', function(where, r, m)
    fields(where, r, m, { 'source', 'node' })
    affine(`{where}.bind`, r.bind, m.bind)
    bound(`{where}.bound`, r.bound, m.bound)
    range(`{where}.weights`, r.weights, m.weights)
  end)

  list('issues', function(where, r, m)
    fields(where, r, m, { 'source', 'recordType', 'kind', 'field', 'target', 'found', 'slot' })
    field(where, 'text', r.text, Scene.issueText(m))
  end)

  local buffers = mine.buffers
  for _, entry in Buffers do
    local name, kind, size = entry[1], entry[2], entry[3]
    local rustValues, mineBuffer = rust.buffers[name], buffers[name]
    if #rustValues * size ~= buffer.len(mineBuffer) then
      problem(
        `buffers.{name}: {buffer.len(mineBuffer) // size} values where jess-nif has {#rustValues}`
      )
      continue
    end

    for i, value in rustValues do
      local at = (i - 1) * size
      local mineValue = if kind == 'f32'
        then buffer.readf32(mineBuffer, at)
        else buffer.readu16(mineBuffer, at)
      if not same(value, mineValue) then
        problem(`buffers.{name}[{i - 1}]: {mineValue} where jess-nif has {value}`)
        break
      end
    end
  end

  if #problems == 0 and Known.lossyEnums == lossyBefore and Scene.dump(mine) ~= rust.text then
    problem 'the text dump differs from jess-nif\'s'
  end

  return problems
end

--- The port's text dump of a Morrowind NIF's scene.
local function dump(bytes: buffer): string return Scene.dump(Scene.build(Nif.open(bytes))) end

return table.freeze { check = check, dump = dump, known = Known }
