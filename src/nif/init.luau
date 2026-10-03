--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Morrowind NIFs (NetImmerse 4.0.0.2) in Luau.

`open` walks the file once, noting where each record starts, its type, and its links; nothing
is decoded. A record is a plain table, decoded the first time `record` is asked for it; bulk data
in it are array views of the file's bytes (`nif/array.luau`). A save copies the bytes of every
record never asked for and encodes the rest, edited or not. It keeps the records reachable from
the roots, in file order, and writes a link to a record it leaves out as -1, as jess-nif does.
]]

local Array = require '@self/internal/array'
local Edit = require '@self/internal/edit'
local Load = require '@self/internal/load'
local Scan = require '@self/internal/scan'
local Types = require '@self/internal/types'
local Writer = require '@self/internal/writer'

local intern = require '@dream/intern'

local Header = 'NetImmerse File Format, Version 4.0.0.2\n'
local Version = 0x04000002

--- Every record type name, interned once: `open` finds a name's scanner by the bytes in place,
--- without making a string, and a file naming an unknown type adds nothing.
local TypeNames: dream_intern_Pool = intern.new 'exact'
local ScanByToken: { Scan.Scanner }, NameByToken: { string } = {}, {}
for name, walk in Scan.scan do
  local token = TypeNames:intern(name)
  ScanByToken[token], NameByToken[token] = walk, name
end

--- A decoded record: any record type in `nif/types.luau`; `record.type` narrows it.
export type Record = Types.Record

type Links = { number }

--- An open file: where each record is in its bytes, what it is, and what it links to.
type NifData = {
  --- The bytes the file was opened from.
  source: buffer,
  --- How many records the file holds.
  count: number,
  --- The root records' indices.
  roots: { number },
  starts: { number },
  bodies: { number },
  types: { string },
  links: Links,
  linkEnds: { number },
  --- Decoded records by 1-based index.
  decoded: { Record },
  rootsAt: number,
  --- How many records were read from the file; the rest were inserted since.
  fromFile: number,
  --- Records removed since, by 1-based index: their indices stay empty.
  removed: { [number]: boolean },
}

local Nif = {}
Nif.__index = Nif

export type Nif = typeof(setmetatable({} :: NifData, Nif))

--- The record at a 1-based index, decoded the first time it is asked for.
local function decode(state: Nif, i: number): Record
  local decoded = state.decoded[i]
  if decoded then return decoded end

  local name = state.types[i]
  decoded = Load[name].read(state.source, state.bodies[i], name)
  state.decoded[i] = decoded
  return decoded
end

local function record(state: Nif, index: number): Record?
  local i = index + 1
  if i < 1 or i > state.count or state.removed[i] then return nil end

  return decode(state, i)
end

--- The links a record holds now: from the scan when it was never decoded, else from its fields.
local function linksOf(state: Nif, i: number, scratch: Links): (Links, number, number)
  if not state.decoded[i] then
    local first = if i == 1 then 1 else state.linkEnds[i - 1] + 1
    return state.links, first, state.linkEnds[i]
  end

  local n = Load[state.types[i]].links(state.decoded[i], scratch, 0)
  return scratch, 1, n
end

--- Puts back the signaling NaNs a decode turned quiet. Luau numbers are doubles, and widening an
--- f32 signaling NaN sets its quiet bit, so a record that was decoded and saved unchanged would
--- otherwise differ from its source by that one bit wherever the file held one. A written record
--- that wrote a NaN (the writer says so) and is the same length as its source gets back every four
--- bytes that differ only that way; arrays are copied, so their bits never change.
local function restoreNans(out: buffer, at: number, source: buffer, from: number, length: number)
  local i = 0
  while i < length do
    if i + 4 <= length and buffer.readu32(out, at + i) == buffer.readu32(source, from + i) then
      i += 4
      continue
    end

    if buffer.readu8(out, at + i) == buffer.readu8(source, from + i) then
      i += 1
      continue
    end

    for s = math.max(0, i - 3), math.min(i, length - 4) do
      local original = buffer.readu32(source, from + s)
      local quiet = bit32.bor(original, 0x00400000)
      local nan = bit32.band(original, 0x7f800000) == 0x7f800000
        and bit32.band(original, 0x007fffff) ~= 0
      if nan and original ~= quiet and buffer.readu32(out, at + s) == quiet then
        buffer.writeu32(out, at + s, original)
        break
      end
    end

    i += 1
  end
end

--- The records reachable from the roots, by 1-based index, and those linking past the end.
local function reachable(state: Nif): ({ boolean }, { boolean })
  local count, decoded, scanned, linkEnds = state.count, state.decoded, state.links, state.linkEnds
  local keep, dangling = table.create(count, false), table.create(count, false)
  local stack, top, scratch = {}, 0, {}
  for _, root in state.roots do
    if root >= 0 then
      top += 1
      stack[top] = root + 1
    end
  end

  while top > 0 do
    local i = stack[top]
    top -= 1
    if i > count or keep[i] or state.removed[i] then continue end

    keep[i] = true
    -- From the scan when the record was never decoded, else from its fields now.
    local links: Links, first: number, last: number = scratch, 1, 0
    if decoded[i] then
      last = Load[state.types[i]].links(decoded[i], scratch, 0) :: number
    else
      links, first, last = scanned, if i == 1 then 1 else linkEnds[i - 1] + 1, linkEnds[i]
    end

    for j = first, last do
      local target = links[j] + 1
      if target > count then
        dangling[i] = true
      elseif not keep[target] then
        top += 1
        stack[top] = target
      end
    end
  end

  return keep, dangling
end

local function save(state: Nif): buffer
  local count = state.count
  local keep, dangling = reachable(state)
  local scratch = {}
  local map, kept = {}, 0
  for i = 1, count do
    if keep[i] then
      map[i - 1] = kept
      kept += 1
    end
  end

  local identity = kept == count
  local source = state.source
  -- Sized for the common case, a save with nothing dropped or decoded: then it fills exactly.
  local w = Writer.new(state.rootsAt + 4 + 4 * #state.roots)
  Writer.reserve(w, 48)
  buffer.writestring(w.b, 0, Header)
  buffer.writeu32(w.b, 40, Version)
  buffer.writeu32(w.b, 44, kept)
  w.p = 48

  -- Untouched records next to each other in the source go out in one copy.
  local runStart, runStop = 0, 0
  local function flush()
    local length = runStop - runStart
    if length == 0 then return end

    Writer.reserve(w, length)
    buffer.copy(w.b, w.p, source, runStart, length)
    w.p += length
    runStart, runStop = 0, 0
  end

  for i = 1, count do
    if not keep[i] then
      flush()
      continue
    end

    -- A record added since opening has no bytes to copy.
    if i > state.fromFile then
      flush()
      local name = state.types[i]
      Writer.string(w, name)
      Load[name].write(w, state.decoded[i], map)
      continue
    end

    local start = state.starts[i]
    local stop = if i == state.fromFile then state.rootsAt else state.starts[i + 1]
    local reencode = state.decoded[i] ~= nil or dangling[i]
    if not identity and not reencode then
      local _, first, last = linksOf(state, i, scratch)
      reencode = last >= first
    end

    if not reencode then
      if runStop ~= start then
        flush()
        runStart = start
      end

      runStop = stop
      continue
    end

    flush()
    local decoded = decode(state, i)
    local name = state.types[i]
    local at = w.p
    w.nan = false
    Writer.string(w, name)
    Load[name].write(w, decoded, map)
    if w.nan and w.p - at == stop - start then restoreNans(w.b, at, source, start, stop - start) end
  end

  flush()

  local roots = state.roots
  Writer.reserve(w, 4 + 4 * #roots)
  buffer.writeu32(w.b, w.p, #roots)
  w.p += 4
  for _, root in roots do
    buffer.writei32(w.b, w.p, Writer.link(root, map))
    w.p += 4
  end

  return Writer.finish(w)
end

--- The record at a 0-based index, or nil past the end.
function Nif.record(self: Nif, index: number): Record? return record(self, index) end

--- The record at a 0-based index as the file holds it, written into `into`: its fields, and the
--- array views, matrices, and structs `into` already holds refilled in place. Nothing is kept, so
--- reading every record of a type through one table allocates little; the next read overwrites
--- it, arrays and all. Keep one table per record type: a read sets its own type's fields, and
--- leaves another type's where they were. Edits belong in `record`, whose tables `save` writes.
function Nif.read(self: Nif, index: number, into: { [string]: unknown }): Record?
  local i = index + 1
  if i < 1 or i > self.count or self.removed[i] then return nil end

  local name = self.types[i]
  local record = (into :: unknown) :: Record
  Load[name].fill(self.source, self.bodies[i], name, record)
  return record
end

--- The type name of the record at a 0-based index, without decoding it.
function Nif.typeOf(self: Nif, index: number): string?
  if self.removed[index + 1] then return nil end

  return self.types[index + 1]
end

--- A decoded record's 0-based index.
function Nif.indexOf(self: Nif, target: Record): number?
  for i, decoded in self.decoded do
    if decoded == target then return i - 1 end
  end

  return nil
end

--- Whether the record at a 0-based index has been decoded.
function Nif.isDecoded(self: Nif, index: number): boolean return self.decoded[index + 1] ~= nil end

--- The records with their 0-based indices, in file order, each decoded as it is reached;
--- removed ones are skipped.
function Nif.records(self: Nif): () -> (number?, Record?)
  local i = -1
  return function()
    repeat
      i += 1
    until i >= self.count or not self.removed[i + 1]

    if i >= self.count then return nil, nil end

    return i, record(self, i)
  end
end

--- Adds a record after the last one, returning its 0-based index. `fields` is a table of the
--- type's fields with its type name in `type`; fields left out take the type's defaults, a list
--- where the record holds an array becomes one (coordinates as `vector`s or lists), and new
--- geometry gets its bound and normals, and new strips their triangle count, unless given.
--- Nothing links to the record until a link is set to its index.
function Nif.insert(self: Nif, fields: { [string]: any }): number
  local made = Edit.fromFields(fields)
  Edit.derive(made, fields)
  local i = self.count + 1
  self.count = i
  self.types[i], self.decoded[i] = made.type, made
  return i - 1
end

--- Removes the record at a 0-based index, and the roots that were it. Links to it save as
--- empty; its index stays empty.
function Nif.remove(self: Nif, index: number): boolean
  local i = index + 1
  if i < 1 or i > self.count or self.removed[i] then return false end

  self.removed[i], self.decoded[i] = true, nil
  local roots = {}
  for _, root in self.roots do
    if root ~= index then table.insert(roots, root) end
  end

  self.roots = roots
  return true
end

--- The 0-based indices of the records of any of `type` whose name matches `name`, a case-
--- insensitive regex; every record without either.
function Nif.find(self: Nif, spec: { type: (string | { string })?, name: string? }?): { number }
  local wanted: { [string]: boolean }? = nil
  local types = spec and spec.type
  if types then
    wanted = {}
    for _, name in if type(types) == 'string' then { types } else types do
      (wanted :: { [string]: boolean })[string.lower(name)] = true
    end
  end

  local pattern = if spec and spec.name then jess.regex.new('(?i)' .. spec.name) else nil
  local found = {}
  for i = 0, self.count - 1 do
    local name = self:typeOf(i)
    if not name or (wanted and not wanted[string.lower(name)]) then continue end

    if pattern then
      local value = (record(self, i) :: any).name
      if type(value) ~= 'string' or not pattern:isMatch(value) then continue end
    end

    table.insert(found, i)
  end

  return found
end

--- Adds `child` (a 0-based index) to the children of the node at `parent`.
function Nif.attach(self: Nif, parent: number, child: number)
  local node = record(self, parent) :: any
  if not node or not Array.isArray(node.children) then error(`record {parent} isn't a node`, 0) end

  local list = node.children:toTable()
  table.insert(list, child)
  node.children = Edit.toArray('i32', list)
end

--- Takes `child` (a 0-based index) out of the children of the node at `parent`; whether it was
--- one.
function Nif.detach(self: Nif, parent: number, child: number): boolean
  local node = record(self, parent) :: any
  if not node or not Array.isArray(node.children) then error(`record {parent} isn't a node`, 0) end

  local kept = {}
  for _, index in node.children:toTable() do
    if index ~= child then table.insert(kept, index) end
  end

  if #kept == node.children.count then return false end

  node.children = Edit.toArray('i32', kept)
  return true
end

--- Every external texture path, with the 0-based index of the `NiSourceTexture` naming it.
function Nif.textures(self: Nif): { { record: number, path: string } }
  local found = {}
  for _, index in self:find { type = 'NiSourceTexture' } do
    local path = (record(self, index) :: any).source.external
    if path then table.insert(found, { record = index, path = path }) end
  end

  return found
end

--- Points the textures spelled `from` (ignoring case and slash direction) at `to`; how many.
function Nif.setTexture(self: Nif, from: string, to: string): number
  local wanted, changed = Edit.normalizePath(from), 0
  for _, texture in self:textures() do
    if Edit.normalizePath(texture.path) ~= wanted then continue end

    local source = (record(self, texture.record) :: any).source
    source.external = to
    changed += 1
  end

  return changed
end

export type ShapeSpec = {
  name: string?,
  vertices: { any },
  triangles: { any },
  normals: { any }?,
  vertexColors: { any }?,
  --- One set of texture coordinates; `uvSets` for several.
  uvs: { any }?,
  uvSets: { { any } }?,
  --- A texture path for the shape's base texture.
  texture: string?,
  --- `NiMaterialProperty` fields for the shape's material.
  material: { [string]: any }?,
  --- Property records (0-based indices) the shape has besides those two.
  properties: { number }?,
  --- The node (a 0-based index) the shape is attached to.
  parent: number?,
  translation: vector?,
  rotation: { vector }?,
  scale: number?,
}

local ShapeFields: { [string]: boolean } = table.freeze({
  name = true,
  vertices = true,
  triangles = true,
  normals = true,
  vertexColors = true,
  uvs = true,
  uvSets = true,
  texture = true,
  material = true,
  properties = true,
  parent = true,
  translation = true,
  rotation = true,
  scale = true,
} :: { [string]: boolean })

--- Adds a triangle shape and its data, a texture and a material when `spec` gives them, attached
--- to `parent` when it's given; returns the shape's 0-based index.
function Nif.shape(self: Nif, spec: ShapeSpec): number
  for key in spec :: any do
    if not ShapeFields[key] then error(`Nif:shape has no option '{key}'`, 0) end
  end

  if spec.uvs and spec.uvSets then error('pass uvs or uvSets, not both', 0) end

  local uvSets = spec.uvSets or (if spec.uvs then { spec.uvs } else nil)
  local data = self:insert {
    type = 'NiTriShapeData',
    vertices = spec.vertices,
    triangles = spec.triangles,
    normals = spec.normals,
    vertexColors = spec.vertexColors,
    uvSets = uvSets,
  }

  local properties = table.clone(spec.properties or {})
  if spec.texture then
    local source = self:insert { type = 'NiSourceTexture', source = { external = spec.texture } }
    local texturing =
      self:insert { type = 'NiTexturingProperty', textureMaps = { base = { texture = source } } }
    table.insert(properties, texturing)
  end

  if spec.material then
    local fields = table.clone(spec.material)
    fields.type = 'NiMaterialProperty'
    table.insert(properties, self:insert(fields))
  end

  local shape = self:insert {
    type = 'NiTriShape',
    geometryData = data,
    properties = properties,
    name = spec.name,
    translation = spec.translation,
    rotation = spec.rotation,
    scale = spec.scale,
  }

  if spec.parent then self:attach(spec.parent, shape) end

  return shape
end

export type DumpOptions = {
  --- Only records of these types (ignoring case).
  type: (string | { string })?,
  --- Only records at these 0-based indices.
  index: (number | { number })?,
  --- Only records whose name matches this case-insensitive regex.
  name: string?,
  --- Each record's index, type, and name only.
  list: boolean?,
}

--- The roots and the records `options` picks (every one without), each with its 0-based
--- `index`: as the model holds them, or only index, type, and name with `list`.
function Nif.dump(self: Nif, options: DumpOptions?): { roots: { number }, records: { any } }
  local settings: DumpOptions = options or {}
  local indices: { [number]: boolean }? = nil
  if settings.index then
    indices = {}
    for _, index in if type(settings.index) == 'number' then { settings.index } else settings.index do
      (indices :: { [number]: boolean })[index] = true
    end
  end

  local records = {}
  for _, index in self:find { type = settings.type, name = settings.name } do
    if indices and not indices[index] then continue end

    local found = record(self, index) :: any
    local entry
    if settings.list then
      local name = found.name
      entry = { index = index, type = found.type, name = if name and name ~= '' then name else nil }
    else
      entry = table.clone(found)
      entry.index = index
    end

    table.insert(records, entry)
  end

  return { roots = table.clone(self.roots), records = records }
end

--- Recomputes every geometry data record's bound from its vertices; how many.
function Nif.updateBounds(self: Nif): number
  local count = 0
  for _, index in self:find() do
    local data = record(self, index) :: any
    if data.vertices == nil or data.bound == nil then continue end

    Edit.updateBound(data)
    count += 1
  end

  return count
end

--- Recomputes the normals of the geometry data record at a 0-based index from its triangles.
function Nif.computeNormals(self: Nif, index: number)
  local data = record(self, index) :: any
  if not data or data.vertices == nil then error(`record {index} isn't geometry data`, 0) end

  Edit.computeNormals(data, Edit.triangles(data))
end

--- How many records a save keeps: those reachable from the roots.
function Nif.reachableCount(self: Nif): number
  local count = 0
  for _, kept in (reachable(self)) do
    if kept then
      count += 1
    end
  end

  return count
end

--- The file's bytes after any edits.
function Nif.save(self: Nif): buffer return save(self) end

--- Opens a NIF from its bytes. Errors name what's wrong, as jess-nif's do.
local function open(data: buffer | string): Nif
  local b = if type(data) == 'string' then buffer.fromstring(data) else data
  if buffer.len(b) < 48 or buffer.readstring(b, 0, 40) ~= Header then
    error('Invalid NIF Header', 0)
  end

  if buffer.readu32(b, 40) ~= Version then error('Invalid NIF Version', 0) end

  local count = buffer.readu32(b, 44)
  local reserve = math.min(count, buffer.len(b) // 4)
  local starts, bodies, linkEnds =
    table.create(reserve) :: { number },
    table.create(reserve) :: { number },
    table.create(reserve) :: { number }
  local types = table.create(reserve) :: { string }
  local links: Links = {}
  local p, n = 48, 0
  for i = 1, count do
    local length = buffer.readu32(b, p)
    local token = TypeNames:find(b, p + 4, length)
    if not token then error('Invalid Type', 0) end

    starts[i], bodies[i], types[i] = p, p + 4 + length, NameByToken[token]
    p, n = ScanByToken[token](b, p + 4 + length, links, n)
    linkEnds[i] = n
  end

  local rootsAt = p
  local rootCount = buffer.readu32(b, p)
  local roots = table.create(math.min(rootCount, buffer.len(b) // 4)) :: { number }
  for i = 1, rootCount do
    roots[i] = buffer.readi32(b, p + i * 4)
  end

  local state = {
    source = b,
    count = count,
    roots = roots,
    starts = starts,
    bodies = bodies,
    types = types,
    links = links,
    linkEnds = linkEnds,
    decoded = {},
    rootsAt = rootsAt,
    fromFile = count,
    removed = {},
  }

  return setmetatable(state, Nif)
end

--- An empty NIF to build: insert records, then set `roots`.
local function new(): Nif
  local state = {
    source = buffer.create(48),
    count = 0,
    roots = {},
    starts = {},
    bodies = {},
    types = {},
    links = {},
    linkEnds = {},
    decoded = {},
    rootsAt = 48,
    fromFile = 0,
    removed = {},
  }

  return setmetatable(state, Nif)
end

return table.freeze {
  open = open,
  new = new,
  recordTypes = Scan.names,
}
