--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
A renderer's view of a Morrowind NIF: a port of jess-nif's `NifScene`. `build` walks the scene
graph of a NIF `open` read, once, and makes what a viewer draws: nodes with local and world
transforms, drawables, packed geometry, materials with the state OpenMW gives them, texture
references, and skins. Every node, drawable, geometry, material, texture, and skin names the
record it came from, as a 0-based index, so a picked drawable leads back to its shape and every
node above it.

The rules follow OpenMW's `NifOsg::LoaderImpl` (`components/nifosg/nifloader.cpp`), cited by
function. What the scene doesn't translate (controllers, particle systems, texture effects,
texture slots real content doesn't use) is listed in `issues` with the record it came from,
never dropped. The scene is the rest pose: controllers aren't evaluated.

Transforms are affine: three matrix columns and a translation, `vector`s, so their arithmetic is
32-bit as jess-nif's is. Geometry is packed into buffers of little-endian `f32`s (`u16`s for
indices and skin vertices), copied from the file's bytes where it can be.
]]

local Classes = require './classes'
local Writer = require './writer'

--- The most scene nodes `build` makes. A record linked from several parents becomes a node under
--- each, so a small file whose levels each link the next one twice would otherwise expand
--- exponentially. Real content stays in the hundreds.
local MaxSceneNodes = 1048576

--- An affine transform: the matrix's three columns and the translation.
export type Affine = { vector }

export type Visibility =
  'Visible'
  | 'Hidden'
  | 'Collision'
  | 'EditorMarker'
  | 'Shadow'
  | 'BoundingBox'
  | 'SwitchedOff'

export type RenderLayer = 'Opaque' | 'AlphaTest' | 'AlphaBlend'

--- A node of the scene: one appearance of an `NiAVObject` in the graph. `parent` and
--- `subtreeEnd` are 0-based node indices; a node's subtree is `index + 1` to `subtreeEnd - 1`.
export type SceneNode = {
  source: number,
  recordType: string,
  name: string,
  parent: number?,
  subtreeEnd: number,
  ['local']: Affine,
  world: Affine,
  --- An `NiBillboardNode`: OpenMW turns it to face the camera (`NifOsg::BillboardCallback`).
  billboard: boolean,
  --- Whether OpenMW draws the node, and if not, the first reason on the path from its root.
  visibility: Visibility,
}

--- A shape to draw; every index is 0-based.
export type Drawable = {
  node: number,
  geometry: number,
  material: number,
  skin: number?,
  layer: RenderLayer,
}

export type Bound = { center: vector, radius: number }

--- A geometry data record's vertices and triangles, as 0-based ranges, `{ first, past }`, into
--- the buffers: vertices in vertex units, indices in `u16`s relative to the first vertex.
export type Geometry = {
  source: number,
  recordType: string,
  vertices: { number },
  indices: { number },
  --- The first UV of the first set, in UV units; set `n` starts `n` times the vertex count later.
  firstUv: number,
  uvSets: number,
  hasNormals: boolean,
  hasColors: boolean,
  bound: Bound,
}

--- The property records that make a material: the nearest of each kind on the path from the
--- root to the shape.
export type MaterialSources = {
  texturing: number?,
  material: number?,
  alpha: number?,
  vertexColor: number?,
  zBuffer: number?,
  specular: number?,
  wireframe: number?,
  stencil: number?,
}

--- A texture a material samples. Enum values the file holds without a name stay numbers.
export type TextureSlot = {
  texture: number,
  uvSet: number,
  clamp: string | number,
  filter: string | number,
}

--- How a drawable is shaded: the state OpenMW builds from its properties
--- (`applyDrawableProperties`, `handleProperty`).
export type Material = {
  sources: MaterialSources,
  baseTexture: TextureSlot?,
  darkTexture: TextureSlot?,
  glowTexture: TextureSlot?,
  applyMode: string | number,
  ambient: vector,
  diffuse: vector,
  emissive: vector,
  --- What OpenMW shades with: always zero. `applyDrawableProperties` turns specular off for
  --- every Morrowind-version NIF; `storedSpecular` is what the file says.
  specular: vector,
  shininess: number,
  storedSpecular: { color: vector, glossiness: number, enabled: boolean },
  alpha: number,
  --- What vertex colors replace: `None`, `AmbientDiffuse`, or `Emissive`.
  vertexColors: string,
  lit: boolean,
  blend: { source: string | number, destination: string | number, sorted: boolean }?,
  alphaTest: { ['function']: string | number, threshold: number }?,
  depth: { test: boolean, write: boolean },
  --- `Back`, `Front`, or `None`.
  cull: string,
  wireframe: boolean,
}

--- An `NiSourceTexture`: an external path exactly as stored, embedded pixels, or neither.
export type Texture = {
  source: number,
  kind: 'external' | 'internal' | 'none',
  path: string?,
  pixels: number?,
}

export type Skin = {
  source: number,
  data: number,
  root: number?,
  transform: Affine,
  bones: { number },
}

export type SkinBone = {
  source: number?,
  node: number?,
  bind: Affine,
  bound: Bound,
  weights: { number },
}

--- Packed arrays for every geometry and skin, with how many elements each holds.
export type Buffers = {
  --- Three `f32`s per vertex.
  positions: buffer,
  --- Three `f32`s per vertex.
  normals: buffer,
  --- Four `f32`s (RGBA) per vertex.
  colors: buffer,
  --- Two `f32`s per vertex per UV set.
  uvs: buffer,
  --- `u16` triangle lists, each relative to its geometry's first vertex.
  indices: buffer,
  --- Each bone's weighted vertices (`u16`), relative to the geometry's first vertex.
  skinVertices: buffer,
  --- The weight (`f32`) of each entry of `skinVertices`.
  skinWeights: buffer,
  vertexCount: number,
  uvCount: number,
  indexCount: number,
  weightCount: number,
}

--- Something the scene doesn't translate, or a malformed link. `kind` is one of
--- `NotSceneObject`, `MissingLink` (with `field` and `target`), `WrongLinkType` (with `field` and
--- `found`), `Cycle`, `Controller`, `UnsupportedGeometry`, `EmptyGeometry`, `IndexOutOfRange`,
--- `AttributeLengthMismatch`, `SkinMismatch`, `Effect`, `UnsupportedProperty`, `StencilTest`,
--- `TextureSlot` (with `slot`), `EmptyTextureSlot`, `EmbeddedTexture`, or `UnsupportedNode`.
export type Issue = {
  source: number,
  recordType: string,
  kind: string,
  field: string?,
  target: number?,
  found: string?,
  slot: string?,
}

export type Scene = {
  nodes: { SceneNode },
  drawables: { Drawable },
  geometries: { Geometry },
  materials: { Material },
  textures: { Texture },
  skins: { Skin },
  skinBones: { SkinBone },
  buffers: Buffers,
  issues: { Issue },
}

--- Texture slot names by index; later slots are decals.
local TextureSlots = table.freeze { 'base', 'dark', 'detail', 'gloss', 'glow', 'bump' }

--- `NiAVObject` flag: hidden.
local HiddenFlag = 0x0001
--- `NiAlphaProperty` flag: don't sort.
local NoSorterFlag = 0x2000
--- `NiSpecularProperty` and `NiWireframeProperty` flag: enabled.
local EnableFlag = 0x0001

local AlphaBlendFunctions = table.freeze {
  [0] = 'One',
  'Zero',
  'SrcColor',
  'InvSrcColor',
  'DstColor',
  'InvDstColor',
  'SrcAlpha',
  'InvSrcAlpha',
  'DstAlpha',
  'InvDstAlpha',
  'SrcAlphaSat',
}

local AlphaTestFunctions = table.freeze {
  [0] = 'Always',
  'Less',
  'Equal',
  'LessEqual',
  'Greater',
  'NotEqual',
  'GreaterEqual',
  'Never',
}

local One = vector.create(1, 1, 1)

--- The transform `rotation` (rows, as stored), `translation`, and `scale` make.
local function affine(rotation: { vector }, translation: vector, scale: number): Affine
  local r1, r2, r3 = rotation[1], rotation[2], rotation[3]
  return {
    vector.create(r1.x, r2.x, r3.x) * scale,
    vector.create(r1.y, r2.y, r3.y) * scale,
    vector.create(r1.z, r2.z, r3.z) * scale,
    translation,
  }
end

--- `a` after `b`: the transform from `b`'s space to `a`'s parent's.
local function multiply(a: Affine, b: Affine): Affine
  local x, y, z = a[1], a[2], a[3]
  local c1, c2, c3, t = b[1], b[2], b[3], b[4]
  return {
    x * c1.x + y * c1.y + z * c1.z,
    x * c2.x + y * c2.y + z * c2.z,
    x * c3.x + y * c3.y + z * c3.z,
    x * t.x + y * t.y + z * t.z + a[4],
  }
end

local function startsWithIgnoreCase(text: string, prefix: string): boolean
  return #text >= #prefix and string.lower(string.sub(text, 1, #prefix)) == prefix
end

--- A node's visibility: the first reason on the path from its root (`handleNode`).
local function nodeVisibility(
  inherited: Visibility,
  key: number,
  isGeometry: boolean,
  av: any,
  isRoot: boolean,
  root: { markers: boolean, collision: number? }
): Visibility
  if inherited ~= 'Visible' then return inherited end

  local name: string = av.name
  if root.collision == key then return 'Collision' end

  if not isRoot and string.lower(name) == 'bounding box' then return 'BoundingBox' end

  if bit32.btest(av.flags, HiddenFlag) then return 'Hidden' end

  if
    isGeometry
    and (startsWithIgnoreCase(name, 'shadow') or startsWithIgnoreCase(name, 'tri shadow'))
  then
    return 'Shadow'
  end

  if isGeometry and root.markers and startsWithIgnoreCase(name, 'tri editormarker') then
    return 'EditorMarker'
  end

  return 'Visible'
end

--- The end of `applyDrawableProperties`: emissive-only lighting zeroes ambient and diffuse, and
--- vertex colors the geometry doesn't have become white.
local function resolveVertexColors(material: Material, hasColors: boolean)
  if not material.lit then
    material.diffuse, material.ambient = vector.zero, vector.zero
  end

  if hasColors then return end

  if material.vertexColors == 'AmbientDiffuse' then
    material.ambient, material.diffuse = One, One
  elseif material.vertexColors == 'Emissive' then
    material.emissive = One
  end

  material.vertexColors = 'None'
end

--- The map in a texture slot: 0 to 4 by name, 5 the bump map, the decals after.
local function slotMap(maps: any, slot: number): any
  if slot >= 6 then
    local decals = maps.decals
    return decals and decals[slot - 5] or nil
  end

  return maps[TextureSlots[slot + 1]]
end

--- Translates the scene graph of `nif`, a Morrowind NIF `open` read, starting at its roots.
--- Errors when the graph expands past `MaxSceneNodes` nodes; malformed links, cycles, and
--- anything untranslated are `issues` instead.
local function build(nif: any): Scene
  local nodes: { SceneNode }, drawables: { Drawable }, geometries: { Geometry } = {}, {}, {}
  local materials: { Material }, textures: { Texture }, skins: { Skin } = {}, {}, {}
  local skinBones: { SkinBone }, issues: { Issue } = {}, {}
  local positions, normals, colors, uvs =
    Writer.new(1024), Writer.new(1024), Writer.new(1024), Writer.new(1024)
  local indices, skinVertices, skinWeights = Writer.new(1024), Writer.new(256), Writer.new(256)
  local reported: { [string]: boolean } = {}
  local firstNode: { [number]: number } = {}
  local geometryBySource: { [number]: number | false } = {}
  local materialBySources: { [string]: number } = {}
  local textureBySource: { [number]: number } = {}
  local skinBySource: { [number]: number | false } = {}
  local pendingSkins: { { drawable: Drawable, skin: number, vertexCount: number } } = {}

  local function typeOf(index: number?): string?
    if not index or index < 0 then return nil end

    return nif:typeOf(index)
  end

  local function is(name: string?, class: string): boolean
    return name ~= nil and Classes.is(name, class)
  end

  local function report(source: number, kind: string, extra: { [string]: any }?)
    local issue: Issue = { source = source, recordType = typeOf(source) or '', kind = kind }
    local key = `{source}|{kind}`
    if extra then
      issue.field, issue.target, issue.found, issue.slot =
        extra.field, extra.target, extra.found, extra.slot
      key ..= `|{extra.field}|{extra.target}|{extra.found}|{extra.slot}`
    end

    if reported[key] then return end

    reported[key] = true
    table.insert(issues, issue)
  end

  local function wrongType(from: number, field: string, found: string)
    report(from, 'WrongLinkType', { field = field, found = found })
  end

  --- The type of the record `index` links, reporting a missing one. Empty links are nil
  --- without a report.
  local function linked(from: number, field: string, index: number?): string?
    if not index or index < 0 then return nil end

    local name = typeOf(index)
    if not name then report(from, 'MissingLink', { field = field, target = index }) end

    return name
  end

  --- `NiNode::findRootCollisionNode`, without recursion: children last to first, depth first.
  local function findCollisionNode(root: number, recursive: boolean): number?
    if not is(typeOf(root), 'NiNode') then return nil end

    local seen: { [number]: boolean } = {}
    local stack: { number } = {}
    local children = nif:record(root).children
    for i = 1, children.count do
      table.insert(stack, children:get(i) :: number)
    end

    while #stack > 0 do
      local key = table.remove(stack) :: number
      local name = typeOf(key)
      if not name then continue end

      if name == 'RootCollisionNode' then return key end

      if not recursive or seen[key] then continue end

      seen[key] = true
      if is(name, 'NiNode') then
        local inner = nif:record(key).children
        for i = 1, inner.count do
          table.insert(stack, inner:get(i) :: number)
        end
      end
    end

    return nil
  end

  --- A root's markers and collision node (`handleNode`).
  local function rootInfo(key: number, av: any): { markers: boolean, collision: number? }
    local seen: { [number]: boolean } = {}
    local from, nextIndex = key, av.extraData
    local markers, recursive = false, false
    while nextIndex and nextIndex >= 0 and not seen[nextIndex] do
      seen[nextIndex] = true
      local name = linked(from, 'extra_data', nextIndex)
      if not name then break end

      if not is(name, 'NiExtraData') then
        wrongType(from, 'extra_data', name)
        break
      end

      local extra = nif:record(nextIndex)
      if is(name, 'NiStringExtraData') then
        markers = markers or extra.value == 'MRK'
        recursive = recursive or extra.value == 'RCN'
      end

      from, nextIndex = nextIndex, extra.next
    end

    return { markers = markers, collision = findCollisionNode(key, recursive) }
  end

  --- Reports each controller in the chain starting at `first`, once.
  local function reportControllers(owner: number, first: number?)
    local seen: { [number]: boolean } = {}
    local from, nextIndex = owner, first
    while nextIndex and nextIndex >= 0 and not seen[nextIndex] do
      seen[nextIndex] = true
      local name = linked(from, 'controller', nextIndex)
      if not name then return end

      if not is(name, 'NiTimeController') then
        wrongType(from, 'controller', name)
        return
      end

      local following = nif:record(nextIndex).next
      report(nextIndex, 'Controller')
      from, nextIndex = nextIndex, following
    end
  end

  --- The effective properties below `av`: its own over those it inherits.
  local function applyProperties(key: number, av: any, inherited: MaterialSources): MaterialSources
    local properties = table.clone(inherited)
    local list = av.properties
    for i = 1, list.count do
      local link = list:get(i)
      local name = linked(key, 'properties', link)
      if not name then continue end

      local slot
      if name == 'NiTexturingProperty' then
        slot = 'texturing'
      elseif name == 'NiMaterialProperty' then
        slot = 'material'
      elseif name == 'NiAlphaProperty' then
        slot = 'alpha'
      elseif name == 'NiVertexColorProperty' then
        slot = 'vertexColor'
      elseif name == 'NiZBufferProperty' then
        slot = 'zBuffer'
      elseif name == 'NiSpecularProperty' then
        slot = 'specular'
      elseif name == 'NiWireframeProperty' then
        slot = 'wireframe'
      elseif name == 'NiStencilProperty' then
        if nif:record(link).stencilEnabled then report(link, 'StencilTest') end

        slot = 'stencil'
      elseif name == 'NiShadeProperty' or name == 'NiDitherProperty' then
        -- OpenMW ignores these for Morrowind ("unused by mw", `handleProperty`).
        continue
      elseif is(name, 'NiProperty') then
        report(link, 'UnsupportedProperty')
        continue
      else
        wrongType(key, 'properties', name)
        continue
      end

      (properties :: any)[slot] = link
      reportControllers(link, if is(name, 'NiObjectNET') then nif:record(link).controller else nil)
    end

    return properties
  end

  --- The geometry for a data record, packed the first time; nil when it can't be drawn.
  local function geometry(shape: number, key: number?): number?
    if key and geometryBySource[key] ~= nil then return geometryBySource[key] or nil end

    if not key or key < 0 then
      report(shape, 'EmptyGeometry')
      return nil
    end

    local name = linked(shape, 'geometry_data', key)
    if not name then
      geometryBySource[key] = false
      return nil
    end

    local function done(value: number?): number?
      geometryBySource[key] = value or false
      return value
    end

    if
      name ~= 'NiTriShapeData'
      and name ~= 'NiTriShapeDynamicData'
      and name ~= 'NiTriStripsData'
    then
      wrongType(shape, 'geometry_data', name)
      return done(nil)
    end

    local data = nif:record(key)
    local vertices = data.vertices
    local vertexCount = vertices.count
    -- The triangles as `u16` triples: a view of the file's for a triangle list, unrolled for
    -- strips, with alternating winding and without degenerate triangles.
    local triangles, at, triangleCount
    if name == 'NiTriStripsData' then
      local strips, lengths = data.strips, data.stripLengths
      local unrolled = Writer.new(64)
      local source, from = strips.buffer, strips.offset
      local point, total = 0, strips.count
      for i = 1, lengths.count do
        local length = lengths:get(i)
        -- A strip longer than the points left has the points left.
        local available = math.max(0, math.min(length, total - point))
        for k = 0, available - 3 do
          local base = from + (point + k) * 2
          local a = buffer.readu16(source, base)
          local b = buffer.readu16(source, base + 2)
          local c = buffer.readu16(source, base + 4)
          if a == b or b == c or a == c then continue end

          Writer.reserve(unrolled, 6)
          local p = unrolled.p
          buffer.writeu16(unrolled.b, p, a)
          if k % 2 == 0 then
            buffer.writeu16(unrolled.b, p + 2, b)
            buffer.writeu16(unrolled.b, p + 4, c)
          else
            buffer.writeu16(unrolled.b, p + 2, c)
            buffer.writeu16(unrolled.b, p + 4, b)
          end

          unrolled.p = p + 6
        end

        point += length
      end

      triangles, at, triangleCount = unrolled.b, 0, unrolled.p // 6
    else
      local list = data.triangles
      triangles, at, triangleCount = list.buffer, list.offset, list.count
    end

    if vertexCount == 0 or triangleCount == 0 then
      report(key, 'EmptyGeometry')
      return done(nil)
    end

    for i = 0, triangleCount * 3 - 1 do
      if buffer.readu16(triangles, at + i * 2) >= vertexCount then
        report(key, 'IndexOutOfRange')
        return done(nil)
      end
    end

    local normalList, colorList, uvLists = data.normals, data.vertexColors, data.uvSets
    local hasNormals = normalList.count == vertexCount
    local hasColors = colorList.count == vertexCount
    local uvTotal = 0
    for _, set in uvLists do
      uvTotal += set.count
    end

    local uvSets = uvTotal // vertexCount
    local uvsMatch = uvTotal % vertexCount == 0
    if
      (normalList.count > 0 and not hasNormals)
      or (colorList.count > 0 and not hasColors)
      or not uvsMatch
    then
      report(key, 'AttributeLengthMismatch')
    end

    local firstVertex, firstIndex, firstUv = positions.p // 12, indices.p // 2, uvs.p // 8
    local function copy(w: Writer.Writer, view: any, length: number)
      Writer.reserve(w, length)
      buffer.copy(w.b, w.p, view.buffer, view.offset, length)
      w.p += length
    end

    local function fill(w: Writer.Writer, value: number, count: number)
      Writer.reserve(w, count * 4)
      if value == 0 then
        buffer.fill(w.b, w.p, 0, count * 4)
      else
        for i = 0, count - 1 do
          buffer.writef32(w.b, w.p + i * 4, value)
        end
      end

      w.p += count * 4
    end

    copy(positions, vertices, vertexCount * 12)
    if hasNormals then
      copy(normals, normalList, vertexCount * 12)
    else
      fill(normals, 0, vertexCount * 3)
    end

    if hasColors then
      copy(colors, colorList, vertexCount * 16)
    else
      fill(colors, 1, vertexCount * 4)
    end

    -- The UV sets are one run of coordinates, set after set; only whole sets are kept.
    local kept = if uvsMatch then uvSets * vertexCount else 0
    for _, set in uvLists do
      if kept == 0 then break end

      local take = math.min(set.count, kept)
      copy(uvs, set, take * 8)
      kept -= take
    end

    Writer.reserve(indices, triangleCount * 6)
    buffer.copy(indices.b, indices.p, triangles, at, triangleCount * 6)
    indices.p += triangleCount * 6

    local index = #geometries
    local bound = data.bound
    table.insert(geometries, {
      source = key,
      recordType = name,
      vertices = { firstVertex, positions.p // 12 },
      indices = { firstIndex, indices.p // 2 },
      firstUv = firstUv,
      uvSets = if uvsMatch then uvSets else 0,
      hasNormals = hasNormals,
      hasColors = hasColors,
      bound = { center = bound.center, radius = bound.radius },
    })
    return done(index)
  end

  --- The texture for an `NiSourceTexture`, reporting a missing or wrong-typed one.
  local function texture(texturing: number, key: number?): number?
    if not key or key < 0 then
      report(texturing, 'EmptyTextureSlot')
      return nil
    end

    local known = textureBySource[key]
    if known then return known end

    local name = linked(texturing, 'texture', key)
    if not name then return nil end

    if name ~= 'NiSourceTexture' then
      wrongType(texturing, 'texture', name)
      return nil
    end

    local source = nif:record(key).source
    local external: string?, internal: number? = source.external, source.internal
    local made: Texture = { source = key, kind = 'none', path = external, pixels = internal }
    if external then
      made.kind, made.pixels = 'external', nil
    elseif internal then
      report(key, 'EmbeddedTexture')
      made.kind = 'internal'
    end

    local index = #textures
    table.insert(textures, made)
    textureBySource[key] = index
    return index
  end

  --- The texture slots of an `NiTexturingProperty` (`handleTextureProperty`).
  local function applyTexturing(material: Material, key: number)
    if typeOf(key) ~= 'NiTexturingProperty' then return end

    local texturing = nif:record(key)
    material.applyMode = texturing.applyMode
    local maps = texturing.textureMaps
    for slot = 0, maps.slots - 1 do
      local map = slotMap(maps, slot)
      if not map then continue end

      if slot ~= 0 and slot ~= 1 and slot ~= 4 then
        report(key, 'TextureSlot', { slot = TextureSlots[slot + 1] or 'decal' })
        continue
      end

      local index = texture(key, map.texture)
      if not index then continue end

      local made: TextureSlot = {
        texture = index,
        uvSet = map.textureIndex,
        clamp = map.clampMode,
        filter = map.filterMode,
      }

      if slot == 0 then
        material.baseTexture = made
      elseif slot == 1 then
        material.darkTexture = made
      else
        material.glowTexture = made
      end
    end
  end

  --- `applyDrawableProperties` and `handleProperty`, for one shape's properties.
  local function buildMaterial(sources: MaterialSources, hasColors: boolean): Material
    local material: Material = {
      sources = sources,
      applyMode = 'Modulate',
      ambient = One,
      diffuse = One,
      emissive = vector.zero,
      specular = vector.zero,
      shininess = 0,
      storedSpecular = { color = vector.zero, glossiness = 0, enabled = true },
      alpha = 1,
      vertexColors = if hasColors then 'AmbientDiffuse' else 'None',
      lit = true,
      depth = { test = true, write = true },
      cull = 'Back',
      wireframe = false,
    }

    local function property(index: number?, name: string): any
      if not index or typeOf(index) ~= name then return nil end

      return nif:record(index)
    end

    if sources.texturing then applyTexturing(material, sources.texturing) end

    local specular = property(sources.specular, 'NiSpecularProperty')
    if specular then material.storedSpecular.enabled = bit32.btest(specular.flags, EnableFlag) end

    local properties = property(sources.material, 'NiMaterialProperty')
    if properties then
      material.diffuse = properties.diffuseColor
      material.ambient = properties.ambientColor
      material.emissive = properties.emissiveColor
      material.storedSpecular.color = properties.specularColor
      material.storedSpecular.glossiness = properties.shine
      material.alpha = properties.alpha
    end

    local vertexColor = property(sources.vertexColor, 'NiVertexColorProperty')
    if vertexColor then
      local mode = vertexColor.sourceVertexMode
      if mode == 'Emissive' then
        material.vertexColors = 'Emissive'
      elseif mode == 'AmbientDiffuse' then
        if vertexColor.lightingMode == 'Emissive' then
          material.lit = false
          material.vertexColors = 'None'
        else
          material.vertexColors = 'AmbientDiffuse'
        end
      else
        material.vertexColors = 'None'
      end
    end

    local alpha = property(sources.alpha, 'NiAlphaProperty')
    if alpha then
      local flags = alpha.flags
      if bit32.btest(flags, 0x0001) then
        material.blend = {
          source = AlphaBlendFunctions[bit32.extract(flags, 1, 4)] or 'One',
          destination = AlphaBlendFunctions[bit32.extract(flags, 5, 4)] or 'One',
          sorted = not bit32.btest(flags, NoSorterFlag),
        }
      end

      if bit32.btest(flags, 0x0200) then
        material.alphaTest = {
          ['function'] = AlphaTestFunctions[bit32.extract(flags, 10, 3)] :: string,
          threshold = alpha.testRef :: number,
        }
      end
    end

    resolveVertexColors(material, hasColors)

    local zBuffer = property(sources.zBuffer, 'NiZBufferProperty')
    if zBuffer then
      material.depth = {
        test = bit32.btest(zBuffer.flags, 0x0001),
        write = bit32.btest(zBuffer.flags, 0x0002),
      }
    end

    local stencil = property(sources.stencil, 'NiStencilProperty')
    if stencil then
      local mode = stencil.drawMode
      material.cull = if mode == 'Both'
        then 'None'
        elseif mode == 'Clockwise' then 'Front'
        else 'Back'
    end

    local wireframe = property(sources.wireframe, 'NiWireframeProperty')
    if wireframe then material.wireframe = bit32.btest(wireframe.flags, EnableFlag) end

    return material
  end

  --- The material for a set of properties, built the first time.
  local function material(sources: MaterialSources, hasColors: boolean): number
    local key =
      `{sources.texturing}|{sources.material}|{sources.alpha}|{sources.vertexColor}|{sources.zBuffer}|{sources.specular}|{sources.wireframe}|{sources.stencil}|{hasColors}`
    local known = materialBySources[key]
    if known then return known end

    local index = #materials
    table.insert(materials, buildMaterial(sources, hasColors))
    materialBySources[key] = index
    return index
  end

  local function addGeometry(
    key: number,
    name: string,
    shape: any,
    node: number,
    properties: MaterialSources
  )
    if not is(name, 'NiTriBasedGeom') then
      report(key, 'UnsupportedGeometry')
      return
    end

    local index = geometry(key, shape.geometryData)
    if not index then return end

    local packed = geometries[index + 1]
    local materialIndex = material(properties, packed.hasColors)
    local made = materials[materialIndex + 1]
    local layer: RenderLayer = if made.blend and made.blend.sorted
      then 'AlphaBlend'
      elseif made.blend or made.alphaTest then 'AlphaTest'
      else 'Opaque'
    local drawable: Drawable =
      { node = node, geometry = index, material = materialIndex, layer = layer }
    table.insert(drawables, drawable)

    local skinKey = shape.skinInstance
    if not skinKey or skinKey < 0 then return end

    local skinName = linked(key, 'skin_instance', skinKey)
    if not skinName then return end

    if skinName ~= 'NiSkinInstance' then
      wrongType(key, 'skin_instance', skinName)
      return
    end

    table.insert(pendingSkins, {
      drawable = drawable,
      skin = skinKey,
      vertexCount = packed.vertices[2] - packed.vertices[1],
    })
  end

  type Visit = {
    key: number?,
    linkedFrom: number?,
    field: string?,
    parent: number?,
    properties: MaterialSources,
    visibility: Visibility,
    root: { markers: boolean, collision: number? },
  }

  local stack: { any } = {}
  local onPath: { [number]: boolean } = {}
  local NoRoot = { markers = false, collision = nil }

  --- Adds the node `visit` reaches, and queues its children.
  local function enter(visit: Visit)
    local key = visit.key
    if not key or key < 0 then return end

    local name = typeOf(key)
    if not name then
      report(
        visit.linkedFrom or key,
        'MissingLink',
        { field = visit.field or 'roots', target = key }
      )
      return
    end

    if not is(name, 'NiAVObject') then
      if visit.linkedFrom then
        wrongType(visit.linkedFrom, visit.field :: string, name)
      else
        report(key, 'NotSceneObject')
      end

      return
    end

    if onPath[key] then
      report(key, 'Cycle')
      return
    end

    onPath[key] = true
    if #nodes >= MaxSceneNodes then
      error(`the scene graph expands to more than {MaxSceneNodes} nodes`, 0)
    end

    local av = nif:record(key)
    local isRoot = visit.parent == nil
    local root = if isRoot then rootInfo(key, av) else visit.root
    local isGeometry = is(name, 'NiGeometry')
    local visibility = nodeVisibility(visit.visibility, key, isGeometry, av, isRoot, root)
    local localTransform = affine(av.rotation, av.translation, av.scale)
    local parent = visit.parent
    local world = if parent
      then multiply(nodes[parent + 1].world, localTransform)
      else localTransform
    local node = #nodes
    table.insert(nodes, {
      source = key,
      recordType = name,
      name = av.name,
      parent = parent,
      subtreeEnd = node + 1,
      ['local'] = localTransform,
      world = world,
      billboard = is(name, 'NiBillboardNode'),
      visibility = visibility,
    })

    if firstNode[key] == nil then firstNode[key] = node end

    table.insert(stack, { exit = true, node = node, key = key })
    reportControllers(key, av.controller)
    local properties = applyProperties(key, av, visit.properties)

    if isGeometry then
      addGeometry(key, name, av, node, properties)
      return
    end

    if is(name, 'NiDynamicEffect') then
      report(key, 'Effect')
      return
    end

    if not is(name, 'NiNode') then return end

    local effects = av.effects
    for i = 1, effects.count do
      local effect = effects:get(i)
      local effectName = linked(key, 'effects', effect)
      if not effectName then continue end

      if is(effectName, 'NiDynamicEffect') then
        report(effect, 'Effect')
      else
        wrongType(key, 'effects', effectName)
      end
    end

    if name == 'NiLODNode' or name == 'NiFltAnimationNode' or name == 'NiSortAdjustNode' then
      report(key, 'UnsupportedNode')
    end

    local active = if name == 'NiSwitchNode' then av.activeIndex else nil
    local children = av.children
    for i = children.count, 1, -1 do
      local switchedOff = active ~= nil and active ~= i - 1
      table.insert(stack, {
        key = children:get(i) :: number,
        linkedFrom = key,
        field = 'children',
        parent = node,
        properties = properties,
        visibility = if switchedOff and visibility == 'Visible' then 'SwitchedOff' else visibility,
        root = root,
      })
    end
  end

  local roots = nif.roots
  for i = #roots, 1, -1 do
    table.insert(stack, {
      key = roots[i],
      properties = {},
      visibility = 'Visible',
      root = NoRoot,
    })
  end

  while #stack > 0 do
    local frame = table.remove(stack)
    if frame.exit then
      nodes[frame.node + 1].subtreeEnd = #nodes
      onPath[frame.key] = nil
    else
      enter(frame)
    end
  end

  --- Whether every weight of `skin` names a vertex below `vertexCount`.
  local function skinFits(skin: Skin, vertexCount: number): boolean
    for b = skin.bones[1] + 1, skin.bones[2] do
      local range = skinBones[b].weights
      for i = range[1], range[2] - 1 do
        if buffer.readu16(skinVertices.b, i * 2) >= vertexCount then return false end
      end
    end

    return true
  end

  local function buildSkin(key: number, vertexCount: number): number?
    local instance = nif:record(key)
    local dataName = linked(key, 'data', instance.data)
    if not dataName then return nil end

    if dataName ~= 'NiSkinData' then
      wrongType(key, 'data', dataName)
      return nil
    end

    local data = nif:record(instance.data)
    local boneData, bones = data.boneData, instance.bones
    local fits = true
    for _, bone in boneData do
      local weights = bone.vertexWeights
      for i = 0, weights.count - 1 do
        if buffer.readu16(weights.buffer, weights.offset + i * 6) >= vertexCount then
          fits = false
          break
        end
      end

      if not fits then break end
    end

    if #boneData ~= bones.count or not fits then
      report(key, 'SkinMismatch')
      return nil
    end

    local firstBone = #skinBones
    for i, bone in boneData do
      local boneKey = bones:get(i)
      if boneKey >= 0 then
        local boneName = linked(key, 'bones', boneKey)
        if boneName and not is(boneName, 'NiAVObject') then wrongType(key, 'bones', boneName) end
      end

      local weights = bone.vertexWeights
      local count = weights.count
      local firstWeight = skinWeights.p // 4
      Writer.reserve(skinVertices, count * 2)
      Writer.reserve(skinWeights, count * 4)
      local from, at = weights.buffer, weights.offset
      for k = 0, count - 1 do
        buffer.writeu16(skinVertices.b, skinVertices.p + k * 2, buffer.readu16(from, at + k * 6))
        buffer.writeu32(skinWeights.b, skinWeights.p + k * 4, buffer.readu32(from, at + k * 6 + 2))
      end

      skinVertices.p += count * 2
      skinWeights.p += count * 4
      table.insert(skinBones, {
        source = if boneKey >= 0 then boneKey else nil,
        node = if boneKey >= 0 then firstNode[boneKey] else nil,
        bind = affine(bone.rotation, bone.translation, bone.scale),
        bound = { center = bone.bound.center, radius = bone.bound.radius },
        weights = { firstWeight, skinWeights.p // 4 },
      })
    end

    local index = #skins
    table.insert(skins, {
      source = key,
      data = instance.data,
      root = if instance.root then firstNode[instance.root] else nil,
      transform = affine(data.rotation, data.translation, data.scale),
      bones = { firstBone, #skinBones },
    })
    return index
  end

  for _, pending in pendingSkins do
    local skin = skinBySource[pending.skin]
    if skin == nil then
      skin = buildSkin(pending.skin, pending.vertexCount) or false
      skinBySource[pending.skin] = skin
    end

    if not skin then continue end

    -- A skin shared by shapes of different sizes fits only those its weights stay inside.
    if not skinFits(skins[skin + 1], pending.vertexCount) then
      report(pending.skin, 'SkinMismatch')
      continue
    end

    pending.drawable.skin = skin
  end

  return {
    nodes = nodes,
    drawables = drawables,
    geometries = geometries,
    materials = materials,
    textures = textures,
    skins = skins,
    skinBones = skinBones,
    buffers = {
      positions = Writer.finish(positions),
      normals = Writer.finish(normals),
      colors = Writer.finish(colors),
      uvs = Writer.finish(uvs),
      indices = Writer.finish(indices),
      skinVertices = Writer.finish(skinVertices),
      skinWeights = Writer.finish(skinWeights),
      vertexCount = positions.p // 12,
      uvCount = uvs.p // 8,
      indexCount = indices.p // 2,
      weightCount = skinWeights.p // 4,
    },
    issues = issues,
  }
end

--- A record as a dump shows it: `#index`, or `-` for none.
local function record(index: number?): string return if index then `#{index}` else '-' end

--- Three decimals, as Rust's `{:.3}`; adding zero turns -0 into 0.
local function decimal(value: number): string return string.format('%.3f', value + 0) end

local function vectorText(value: vector): string
  return `({decimal(value.x)}, {decimal(value.y)}, {decimal(value.z)})`
end

--- A string as Rust's `{:?}` quotes it.
local function quoted(text: string): string
  local escaped = string.gsub(text, '[%c"\\]', function(character: string): string
    if character == '"' then return '\\"' end

    if character == '\\' then return '\\\\' end

    if character == '\n' then return '\\n' end

    if character == '\r' then return '\\r' end

    if character == '\t' then return '\\t' end

    if character == '\0' then return '\\0' end

    return string.format('\\u{%x}', string.byte(character))
  end)
  return `"{escaped}"`
end

local VisibilityText: { [string]: string } = table.freeze({
  Visible = 'visible',
  Hidden = 'hidden',
  Collision = 'collision',
  EditorMarker = 'editor-marker',
  Shadow = 'shadow',
  BoundingBox = 'bounding-box',
  SwitchedOff = 'switched-off',
} :: { [string]: string })

--- A material's sources, as the dump names them, and their fields.
local SourceNames = table.freeze {
  { 'texturing', 'texturing' },
  { 'material', 'material' },
  { 'alpha', 'alpha' },
  { 'vertex-color', 'vertexColor' },
  { 'z-buffer', 'zBuffer' },
  { 'specular', 'specular' },
  { 'wireframe', 'wireframe' },
  { 'stencil', 'stencil' },
}

--- A material's texture slots, as the dump names them, and their fields.
local SlotNames = table.freeze {
  { 'base', 'baseTexture' },
  { 'dark', 'darkTexture' },
  { 'glow', 'glowTexture' },
}

local LayerText: { [string]: string } = table.freeze({
  Opaque = 'opaque',
  AlphaTest = 'alpha-test',
  AlphaBlend = 'alpha-blend',
} :: { [string]: string })

--- How jess-nif's dump words each issue.
local function issueText(issue: Issue): string
  local kind = issue.kind
  if kind == 'MissingLink' then return `{issue.field} links missing record {issue.target}` end

  if kind == 'WrongLinkType' then return `{issue.field} links a {issue.found}` end

  if kind == 'TextureSlot' then return `{issue.slot} texture not translated` end

  return ({
    NotSceneObject = 'root isn\'t a scene object',
    Cycle = 'cycle: the node is its own ancestor',
    Controller = 'controller not evaluated',
    UnsupportedGeometry = 'geometry isn\'t triangles',
    EmptyGeometry = 'no vertices or triangles',
    IndexOutOfRange = 'triangle index past the vertices',
    AttributeLengthMismatch = 'attribute count doesn\'t match the vertices',
    SkinMismatch = 'skin doesn\'t fit the shape',
    Effect = 'dynamic effect not translated',
    UnsupportedProperty = 'property not translated',
    StencilTest = 'stencil test not translated',
    EmptyTextureSlot = 'texture slot in use without a texture',
    EmbeddedTexture = 'embedded pixels not decoded',
    UnsupportedNode = 'node type\'s children or draw order not translated',
  } :: { [string]: string })[kind] or kind
end

--- A deterministic text dump, jess-nif's: the node tree, drawables with their source records,
--- geometry sizes, materials, textures, skins, and issues. Records show as `#index`.
local function dump(scene: Scene): string
  local lines = { 'nodes:' }
  local depths: { number } = {}
  for index, node in scene.nodes do
    local depth = if node.parent then depths[node.parent + 1] + 1 else 0
    depths[index] = depth
    local line =
      `  {string.rep(' ', depth * 2)}{index - 1} {record(node.source)} {node.recordType} {quoted(
        node.name
      )} at {vectorText(node.world[4])}`
    if node.billboard then
      line ..= ' billboard'
    end

    if node.visibility ~= 'Visible' then
      line ..= ` {VisibilityText[node.visibility]}`
    end

    table.insert(lines, line)
  end

  table.insert(lines, 'drawables:')
  for index, drawable in scene.drawables do
    local sources = {}
    local node: number? = drawable.node
    while node do
      local found = scene.nodes[node + 1]
      table.insert(sources, record(found.source))
      node = found.parent
    end

    local line =
      `  {index - 1} node {drawable.node} [{table.concat(sources, ' < ')}] geometry {drawable.geometry} material {drawable.material} {LayerText[drawable.layer]}`
    if drawable.skin then
      line ..= ` skin {drawable.skin}`
    end

    table.insert(lines, line)
  end

  table.insert(lines, 'geometries:')
  for index, geometry in scene.geometries do
    local line =
      `  {index - 1} {record(geometry.source)} {geometry.recordType} vertices {geometry.vertices[2] - geometry.vertices[1]} triangles {(geometry.indices[2] - geometry.indices[1]) // 3} uv-sets {geometry.uvSets}`
    if geometry.hasNormals then
      line ..= ' normals'
    end

    if geometry.hasColors then
      line ..= ' colors'
    end

    table.insert(lines, line)
  end

  table.insert(lines, 'materials:')
  for index, material in scene.materials do
    local line = `  {index - 1}`
    local sources = material.sources
    for _, entry in SourceNames do
      local source = (sources :: any)[entry[2]]
      if source then
        line ..= ` {entry[1]} {record(source)}`
      end
    end

    table.insert(lines, line)
    for _, entry in SlotNames do
      local slot = (material :: any)[entry[2]]
      if slot then
        table.insert(
          lines,
          `    {entry[1]} texture {slot.texture} uv {slot.uvSet} {slot.clamp} {slot.filter}`
        )
      end
    end

    table.insert(
      lines,
      `    {material.applyMode} ambient {vectorText(material.ambient)} diffuse {vectorText(
        material.diffuse
      )} emissive {vectorText(material.emissive)} alpha {decimal(material.alpha)} vertex-colors {material.vertexColors}{if material.lit
        then ''
        else ' unlit'}`
    )
    line = `    depth test {material.depth.test} write {material.depth.write} cull {material.cull}`
    local blend = material.blend
    if blend then
      line ..= ` blend {blend.source} {blend.destination}{if blend.sorted then '' else ' unsorted'}`
    end

    local test = material.alphaTest
    if test then
      line ..= ` test {test['function']} {test.threshold}`
    end

    if material.wireframe then
      line ..= ' wireframe'
    end

    if not material.storedSpecular.enabled then
      line ..= ' no-specular'
    end

    table.insert(lines, line)
  end

  table.insert(lines, 'textures:')
  for index, texture in scene.textures do
    local what = if texture.kind == 'external'
      then quoted(texture.path :: string)
      elseif texture.kind == 'internal' then `pixels {record(texture.pixels)}`
      else 'none'
    table.insert(lines, `  {index - 1} {record(texture.source)} {what}`)
  end

  table.insert(lines, 'skins:')
  for index, skin in scene.skins do
    local weights = 0
    for b = skin.bones[1] + 1, skin.bones[2] do
      local range = scene.skinBones[b].weights
      weights += range[2] - range[1]
    end

    local root = if skin.root then `Some({skin.root})` else 'None'
    table.insert(
      lines,
      `  {index - 1} {record(skin.source)} data {record(skin.data)} root {root} bones {skin.bones[2] - skin.bones[1]} weights {weights}`
    )
  end

  table.insert(lines, 'issues:')
  for _, issue in scene.issues do
    table.insert(lines, `  {record(issue.source)} {issue.recordType} {issueText(issue)}`)
  end

  return table.concat(lines, '\n') .. '\n'
end

return table.freeze {
  build = build,
  dump = dump,
  issueText = issueText,
  maxSceneNodes = MaxSceneNodes,
}
