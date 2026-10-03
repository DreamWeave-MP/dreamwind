--!nonstrict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Building and editing through the model, held to jess-nif's: each scenario makes the same edits
through the model (`port`) and through `jess.nif` (`rust`), and the two saves must be the same
bytes. Every record type inserted bare, a shape built from scratch (bound and normals derived,
so in jess-nif's 32-bit arithmetic), strips, and on a fixture: remove, attach and detach, a
texture repointed, and normals and bounds recomputed after moving vertices. `scenarios` lists
them by name; `run` holds one to jess-nif, given the fixtures' folder; `golden.luau` keeps the
port's saves.
]]

local Nif = require '../../src/nif/init'

local Vertices = { { 0, 0, 0 }, { 10, 0, 0 }, { 10, 10, 0 }, { 0, 10, 3 }, { 5, 5, 8 } }
local Triangles = { { 0, 1, 2 }, { 0, 2, 3 }, { 2, 3, 4 } }
local Uvs = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, { 0.5, 0.5 } }
local Colors = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 }, { 1, 1, 1, 0.5 }, { 0, 0, 0, 1 } }

local Strips = {
  type = 'NiTriStripsData',
  vertices = Vertices,
  stripLengths = { 4, 3 },
  strips = { 0, 1, 3, 2, 2, 3, 4 },
}

--- A shape's options, under `root`.
local function shapeSpec(root: any): { [string]: any }
  return {
    name = 'Tri Shape',
    vertices = Vertices,
    triangles = Triangles,
    uvSets = { Uvs, Uvs },
    vertexColors = Colors,
    texture = 'textures\\tx_a.dds',
    material = { alpha = 0.5, emissiveColor = { 0.2, 0.3, 0.4 } },
    parent = root,
    translation = { 1, 2, 3 },
    rotation = { 0, -1, 0, 1, 0, 0, 0, 0, 1 },
    scale = 2,
  }
end

local function read(folder: string, name: string): buffer
  return buffer.fromstring(jess.fs.read(jess.fs.join(folder, name)) :: string)
end

type Scenario = { port: (fixtures: string) -> buffer, rust: (fixtures: string) -> buffer }

local Scenarios: { [string]: Scenario } = {}

Scenarios['bare records'] = {
  port = function(): buffer
    local nif = Nif.new()
    local roots = {}
    for _, name in Nif.recordTypes do
      table.insert(roots, nif:insert { type = name })
    end

    nif.roots = roots
    return nif:save()
  end,

  rust = function(): buffer
    local nif = jess.nif.new()
    local roots = {}
    for _, name in Nif.recordTypes do
      table.insert(roots, nif:insert { type = name })
    end

    nif:setRoots(roots)
    return nif:bytes()
  end,
}

Scenarios['shape'] = {
  port = function(): buffer
    local nif = Nif.new()
    local root = nif:insert { type = 'NiNode', name = 'Root' }
    nif:shape(shapeSpec(root))
    nif.roots = { root }
    return nif:save()
  end,

  rust = function(): buffer
    local nif = jess.nif.new()
    local root = nif:insert { type = 'NiNode', name = 'Root' }
    nif:shape(shapeSpec(root))
    nif:setRoots { root }
    return nif:bytes()
  end,
}

Scenarios['strips'] = {
  port = function(): buffer
    local nif = Nif.new()
    nif.roots = { nif:insert { type = 'NiTriStrips', geometryData = nif:insert(Strips) } }
    return nif:save()
  end,

  rust = function(): buffer
    local nif = jess.nif.new()
    nif:setRoots { nif:insert { type = 'NiTriStrips', geometryData = nif:insert(Strips) } }
    return nif:bytes()
  end,
}

Scenarios['remove'] = {
  port = function(fixtures: string): buffer
    local nif = Nif.open(read(fixtures, 'random_objects.nif'))
    nif:remove(nif:find({ type = 'NiTriShape', name = 'cube' })[1])
    return nif:save()
  end,

  rust = function(fixtures: string): buffer
    local nif = jess.nif.openBytes(read(fixtures, 'random_objects.nif'))
    nif:find({ type = 'NiTriShape', name = 'cube' })[1]:delete()
    return nif:bytes()
  end,
}

Scenarios['attach and detach'] = {
  port = function(fixtures: string): buffer
    local nif = Nif.open(read(fixtures, 'random_objects.nif'))
    local sphere = nif:find({ name = '^sphere$' })[1]
    nif:detach(nif:find({ name = '^empty 2$' })[1], sphere)
    nif:attach(nif.roots[1], sphere)
    return nif:save()
  end,

  rust = function(fixtures: string): buffer
    local nif = jess.nif.openBytes(read(fixtures, 'random_objects.nif'))
    local sphere = nif:find({ name = '^sphere$' })[1]
    nif:find({ name = '^empty 2$' })[1]:detach(sphere)
    nif:roots()[1]:attach(sphere)
    return nif:bytes()
  end,
}

--- The first texture path in `all_types.nif`, spelled another way.
local function respelled(fixtures: string): string?
  local textures = Nif.open(read(fixtures, 'all_types.nif')):textures()
  if #textures == 0 then return nil end

  return string.upper((string.gsub(textures[1].path, '\\', '/')))
end

Scenarios['textures'] = {
  port = function(fixtures: string): buffer
    local nif = Nif.open(read(fixtures, 'all_types.nif'))
    local from = respelled(fixtures)
    if from then nif:setTexture(from, 'textures/replaced.dds') end

    return nif:save()
  end,

  rust = function(fixtures: string): buffer
    local nif = jess.nif.openBytes(read(fixtures, 'all_types.nif'))
    local from = respelled(fixtures)
    if from then nif:setTexture(from, 'textures/replaced.dds') end

    return nif:bytes()
  end,
}

Scenarios['bounds'] = {
  port = function(fixtures: string): buffer
    local nif = Nif.open(read(fixtures, 'random_objects.nif'))
    local index = nif:find({ type = 'NiTriShapeData' })[1]
    local data = nif:record(index) :: any
    for i = 1, data.vertices.count do
      local v = data.vertices:get(i)
      data.vertices:set(i, vector.create(v.x * 3, v.y + 7, v.z))
    end

    nif:computeNormals(index)
    nif:updateBounds()
    return nif:save()
  end,

  rust = function(fixtures: string): buffer
    -- jess-nif's update recomputes the normals of moved vertices; the model does on request.
    local nif = jess.nif.openBytes(read(fixtures, 'random_objects.nif'))
    local record = nif:find({ type = 'NiTriShapeData' })[1]
    local fields = record:toTable()
    for i, vertex in fields.vertices do
      fields.vertices[i] = { vertex[1] * 3, vertex[2] + 7, vertex[3] }
    end

    record:update { vertices = fields.vertices, bound = fields.bound }
    nif:updateBounds()
    return nif:bytes()
  end,
}

--- What differs between the two saves of one scenario.
local function run(name: string, fixtures: string): { string }
  local scenario = Scenarios[name]
  local left = buffer.tostring(scenario.rust(fixtures))
  local right = buffer.tostring(scenario.port(fixtures))
  if left == right then return {} end

  for i = 1, math.max(#left, #right) do
    if string.byte(left, i) ~= string.byte(right, i) then
      return {
        `{name}: the saves differ from byte {i - 1} ({#right} bytes where jess-nif has {#left})`,
      }
    end
  end

  return {}
end

local names = {}
for name in Scenarios do
  table.insert(names, name)
end

table.sort(names)

return table.freeze { run = run, scenarios = names, build = Scenarios }
