--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
What building and editing records needs beyond reading them: each record type's defaults (jess-
nif's, frozen in `defaults.luau`), a record made from the fields a script gives over those
defaults, and the geometry a record derives from its vertices and triangles, its bound and
normals, computed with jess-nif's 32-bit arithmetic so a built file saves as jess-nif's did.
]]

local Array = require './array'
local Defaults = require './defaults'
local Load = require './load'

--- One rounding to 32 bits, for the scalar steps `vector` arithmetic doesn't already round.
local Scratch = buffer.create(4)
local function f32(value: number): number
  buffer.writef32(Scratch, 0, value)
  return buffer.readf32(Scratch, 0)
end

--- A record of type `name` with every field at its default; an error for a type jess doesn't
--- know.
local function defaultRecord(name: string): any
  local body = Defaults.bodies[name]
  if not body then error(`unknown NIF record type '{name}'`, 0) end

  local record = Load[name].read(buffer.fromstring(body), 0, name)
  return record
end

--- A nested struct at its default: `TextureMap` or `BumpMap`.
local function defaultStruct(name: string): any
  local entry = (Defaults.structs :: any)[name]
  local value = Load[entry.type].read(buffer.fromstring(entry.body), 0, entry.type)
  for part in string.gmatch(entry.path, '[^.]+') do
    value = value[part]
  end

  return value
end

--- The 32-bit `x, y, z` of a coordinate given as a `vector` or a list of numbers.
local function coordinates(value: any): (number, number, number, number)
  if type(value) == 'vector' then return value.x, value.y, value.z, 0 end

  return value[1] or 0, value[2] or 0, value[3] or 0, value[4] or 0
end

--- `list` (numbers, or coordinates as `vector`s or lists) as an array of `kind`: the kinds
--- scripts build geometry and link lists with.
local function toArray(kind: Array.Kind, list: { any }): any
  local count = #list
  local array = Array.new(kind, count) :: any
  local b, stride = array.buffer, array.stride
  for i, value in list do
    local p = (i - 1) * stride
    if kind == 'u8' then
      buffer.writeu8(b, p, value)
    elseif kind == 'u16' then
      buffer.writeu16(b, p, value)
    elseif kind == 'i32' then
      buffer.writei32(b, p, value)
    elseif kind == 'f32' then
      buffer.writef32(b, p, value)
    elseif kind == 'tri' then
      local x, y, z = coordinates(value)
      buffer.writeu16(b, p, x)
      buffer.writeu16(b, p + 2, y)
      buffer.writeu16(b, p + 4, z)
    elseif kind == 'vec2' or kind == 'vec3' or kind == 'vec4' then
      local x, y, z, w = coordinates(value)
      buffer.writef32(b, p, x)
      buffer.writef32(b, p + 4, y)
      if kind ~= 'vec2' then buffer.writef32(b, p + 8, z) end

      if kind == 'vec4' then buffer.writef32(b, p + 12, w) end
    else
      error(`a {kind} array is built with the array module, not from a list`, 0)
    end
  end

  return array
end

--- `value` in the shape of `base`, the field's default: a list where the default is an array
--- becomes one, and a table where the default is a struct is merged over it.
local function merge(base: any, value: any, field: string): any
  if type(value) ~= 'table' or Array.isArray(value) then return value end

  if type(base) == 'vector' then
    return vector.create(value[1] or 0, value[2] or 0, value[3] or 0)
  end

  -- A rotation is three row vectors, or nine numbers row by row.
  if type(base) == 'table' and type(base[1]) == 'vector' and type(value[1]) == 'number' then
    return {
      vector.create(value[1], value[2], value[3]),
      vector.create(value[4], value[5], value[6]),
      vector.create(value[7], value[8], value[9]),
    }
  end

  local kind = Array.kindOf(base)
  if kind then return toArray(kind, value) end

  -- UV sets default to no sets, so there's no array to take each set's kind from.
  if field == 'uvSets' then
    local sets = {}
    for i, set in value do
      sets[i] = if Array.isArray(set) then set else toArray('vec2', set)
    end

    return sets
  end

  if type(base) ~= 'table' or getmetatable(base) then return value end

  local merged = table.clone(base)
  for key, entry in value do
    local default = base[key]
    if default == nil and field == 'textureMaps' then
      default = defaultStruct(if key == 'bump' then 'BumpMap' else 'TextureMap')
    end

    merged[key] = merge(default, entry, key)
  end

  return merged
end

--- `fields` (with the record's `type`) over the type's defaults.
local function fromFields(fields: { [string]: any }): any
  local name = fields.type
  if type(name) ~= 'string' then error('a record table needs a type, such as "NiNode"', 0) end

  local record = defaultRecord(name)
  for key, value in fields do
    if key ~= 'type' then record[key] = merge(record[key], value, key) end
  end

  return record
end

--- The triangles a geometry data record draws, as index triples: its list, or its strips
--- unrolled with alternating winding and without degenerate triangles.
local function triangles(data: any): { { number } }
  local found = {}
  if data.type == 'NiTriShapeData' or data.type == 'NiTriShapeDynamicData' then
    local list = data.triangles
    for i = 0, list.count - 1 do
      local p = list.offset + i * 6
      local b = list.buffer
      table.insert(
        found,
        { buffer.readu16(b, p), buffer.readu16(b, p + 2), buffer.readu16(b, p + 4) }
      )
    end
  elseif data.type == 'NiTriStripsData' then
    local strips, lengths = data.strips, data.stripLengths
    local point, total = 0, strips.count
    for i = 1, lengths.count do
      local length = lengths:get(i)
      local available = math.max(0, math.min(length, total - point))
      for k = 0, available - 3 do
        local a, b, c =
          strips:get(point + k + 1), strips:get(point + k + 2), strips:get(point + k + 3)
        if a == b or b == c or a == c then continue end

        table.insert(found, if k % 2 == 0 then { a, b, c } else { a, c, b })
      end

      point += length
    end
  end

  return found
end

--- The vertices of a geometry data record, as `vector`s.
local function vertices(data: any): { vector }
  local list = data.vertices
  local found = table.create(list.count) :: { vector }
  for i = 0, list.count - 1 do
    local p = list.offset + i * 12
    local b = list.buffer
    found[i + 1] =
      vector.create(buffer.readf32(b, p), buffer.readf32(b, p + 4), buffer.readf32(b, p + 8))
  end

  return found
end

--- A `vector`'s length in 32 bits: glam's `(x * x + y * y) + z * z`, then the square root.
local function length(v: vector): number
  local square = v * v
  return f32(math.sqrt(f32(f32(square.x + square.y) + square.z)))
end

--- Sets a geometry data record's bound to the sphere around its vertices: centered between
--- their extremes, out to the farthest (`NiGeometryData::update_bound`).
local function updateBound(data: any)
  local points = vertices(data)
  if #points == 0 then
    data.bound = { center = vector.zero, radius = 0 }
    return
  end

  local low, high = points[1], points[1]
  for _, point in points do
    low =
      vector.create(math.min(low.x, point.x), math.min(low.y, point.y), math.min(low.z, point.z))
    high =
      vector.create(math.max(high.x, point.x), math.max(high.y, point.y), math.max(high.z, point.z))
  end

  local center = (low + high) * 0.5
  local radius = 0
  for _, point in points do
    radius = math.max(radius, length(point - center))
  end

  data.bound = { center = center, radius = radius }
end

--- Sets a geometry data record's normals to each vertex's average of the normals of
--- `faces` around it, weighted by their area; a vertex no triangle uses gets a zero normal
--- (`NiGeometryData::compute_normals`).
local function computeNormals(data: any, faces: { { number } })
  local points = vertices(data)
  local sums = table.create(#points, vector.zero) :: { vector }
  for _, face in faces do
    local a, b, c = points[face[1] + 1], points[face[2] + 1], points[face[3] + 1]
    if not a or not b or not c then continue end

    -- The cross product's length is twice the triangle's area, which does the weighting.
    local normal = vector.cross(b - a, c - a)
    sums[face[1] + 1] += normal
    sums[face[2] + 1] += normal
    sums[face[3] + 1] += normal
  end

  local normals = table.create(#points) :: { vector }
  for i, sum in sums do
    local reciprocal = f32(1 / length(sum))
    normals[i] = if reciprocal == reciprocal
        and reciprocal < math.huge
        and reciprocal > 0
      then sum * reciprocal
      else vector.zero
  end

  data.normals = toArray('vec3', normals)
end

--- What a new record derives from the fields a script set and didn't: a strip's triangle
--- count, and geometry's bound and normals (`update_derived` in jess-nif, for a new record).
local function derive(record: any, fields: { [string]: any })
  if
    record.type == 'NiTriStripsData'
    and (fields.stripLengths or fields.strips)
    and fields.numTriangles == nil
  then
    local count = 0
    for i = 1, record.stripLengths.count do
      count += math.max(record.stripLengths:get(i) - 2, 0)
    end

    record.numTriangles = math.min(count, 0xFFFF)
  end

  if record.vertices == nil or not Array.isArray(record.vertices) then return end

  local verticesSet = fields.vertices ~= nil and record.vertices.count > 0
  if verticesSet and fields.bound == nil then updateBound(record) end

  local faces = triangles(record)
  local trianglesSet = (fields.triangles or fields.strips or fields.stripLengths) and #faces > 0
  if (verticesSet or trianglesSet) and fields.normals == nil and #faces > 0 then
    computeNormals(record, faces)
  end
end

--- A texture path as OpenMW compares them: lowercase, forward slashes.
local function normalizePath(path: string): string
  return string.lower((string.gsub(path, '\\', '/')))
end

return table.freeze {
  defaultRecord = defaultRecord,
  fromFields = fromFields,
  toArray = toArray,
  triangles = triangles,
  updateBound = updateBound,
  computeNormals = computeNormals,
  derive = derive,
  normalizePath = normalizePath,
}
