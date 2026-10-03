--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The Morrowind (4.0.0.2) NIF records as data: what `generate.luau` turns into the readers,
scanners (`nif/scan.luau`), readers, writers, and link walkers (`nif/records/`, `nif/structs.luau`),
and the types in `nif/types.luau`.

A field is `{ name, kind, ...options }`, read and written in order:

- `kind` is a scalar (`u8`, `u16`, `i16`, `u32`, `i32`, `f32`, `bool8`), `string` (a u32
  length and the bytes, cut at the first NUL), `link` (an i32 record index, nil when negative),
  `vec2`/`vec3` (a `vector`), `vec4`/`quat` (four numbers; a quat is stored w first and read
  x, y, z, w), `mat2` (four numbers), `mat3` (three row vectors), `tri` (three u16 indices
  as a `vector`), `u16f32` (an index and a weight as a `vector`),
  `enum:Name`, a struct named in `Structs`, or a codec in `custom.luau` (`custom:name`).
- `list = 'u32'` (or `u16`) prefixes the elements with their count. A list of numbers, vectors,
  or small fixed tuples is an array view of the file's bytes (`nif/array.luau`), not a table.
- `count = expression` reads that many elements with no prefix (`scanCount` says it for the
  scanner, which keeps no lists, from `<name>At`, where a skipped list starts); `when = expression` reads the
  field only when true, and leaves it nil otherwise.
- `fixed = n` reads exactly n elements.
- A name starting with `_` is a local, not a field: it is read, and written from `save`, an
  expression over the record `r`. `expr` makes a local computed rather than read.
- `stash = 'key'` keeps the value in the scratch table `S` for a derived record's fields, which
  are read by another function.

Expressions are Luau source over the locals read so far, `S`, and `r`.
]]

export type Field = {
  [number]: string,
  list: string?,
  count: string?,
  when: string?,
  fixed: number?,
  save: string?,
  expr: string?,
  stash: string?,
  args: string?,
  scanCount: string?,
  doc: string?,
}

export type Definition = {
  base: string?,
  fields: { Field },
  doc: string?,
}

local Enums: { [string]: { { string | number } } } = {
  BoundType = {
    { 'Sphere', 0 },
    { 'Box', 1 },
    { 'Capsule', 2 },
    { 'Lozenge', 3 },
    { 'Union', 4 },
    { 'Halfspace', 5 },
  },

  KeyType = {
    { 'NoInterp', 0 },
    { 'LinKey', 1 },
    { 'BezKey', 2 },
    { 'TCBKey', 3 },
    { 'EulerKey', 4 },
  },
  ForceType = { { 'Planar', 0 }, { 'Spherical', 1 } },
  DecayType = { { 'None', 0 }, { 'Linear', 1 }, { 'Exponential', 2 } },
  SymmetryType = { { 'Spherical', 0 }, { 'Cylindrical', 1 }, { 'Planar', 2 } },
  BankDirection = { { 'Negative', -1 }, { 'Positive', 1 } },
  PixelFormat = {
    { 'RGB', 0 },
    { 'RGBA', 1 },
    { 'PAL', 2 },
    { 'PALAlpha', 3 },
    { 'Compress1', 4 },
    { 'Compress3', 5 },
    { 'Compress5', 6 },
    { 'RGB24NonInterleaved', 7 },
    { 'Bump', 8 },
    { 'BumpLuma', 9 },
  },

  AxisOrder = {
    { 'XYZ', 0 },
    { 'XZY', 1 },
    { 'YZX', 2 },
    { 'YXZ', 3 },
    { 'ZXY', 4 },
    { 'ZYX', 5 },
    { 'XYX', 6 },
    { 'YZY', 7 },
    { 'ZXZ', 8 },
  },
  SortingMode = { { 'Inherit', 0 }, { 'Off', 1 }, { 'Subsort', 2 }, { 'Grouped', 64 } },
  PixelLayout = {
    { 'Palettized8', 0 },
    { 'HighColor16', 1 },
    { 'TrueColor32', 2 },
    { 'Compressed', 3 },
    { 'BumpMap', 4 },
    { 'Palettized4', 5 },
    { 'Default', 6 },
  },
  UseMipMaps = { { 'No', 0 }, { 'Yes', 1 }, { 'Default', 2 } },
  AlphaFormat = { { 'None', 0 }, { 'Binary', 1 }, { 'Smooth', 2 }, { 'Default', 3 } },
  StencilTestFunction = {
    { 'Never', 0 },
    { 'Less', 1 },
    { 'Equal', 2 },
    { 'LessEqual', 3 },
    { 'Greater', 4 },
    { 'NotEqual', 5 },
    { 'GreaterEqual', 6 },
    { 'Always', 7 },
  },

  Action = {
    { 'Keep', 0 },
    { 'Zero', 1 },
    { 'Replace', 2 },
    { 'Increment', 3 },
    { 'Decrement', 4 },
    { 'Invert', 5 },
  },
  DrawMode = { { 'Default', 0 }, { 'CounterClockwise', 1 }, { 'Clockwise', 2 }, { 'Both', 3 } },
  TextureType = {
    { 'ProjectedLight', 0 },
    { 'ProjectedShadow', 1 },
    { 'EnvironmentMap', 2 },
    { 'FogMap', 3 },
  },

  CoordGenType = {
    { 'WorldParallel', 0 },
    { 'WorldPerspective', 1 },
    { 'SphereMap', 2 },
    { 'SpecularCubeMap', 3 },
    { 'DiffuseCubeMap', 4 },
  },

  ClampMode = {
    { 'ClampSClampT', 0 },
    { 'ClampSWrapT', 1 },
    { 'WrapSClampT', 2 },
    { 'WrapSWrapT', 3 },
  },

  FilterMode = {
    { 'Nearest', 0 },
    { 'Bilerp', 1 },
    { 'Trilerp', 2 },
    { 'NearestMipNearest', 3 },
    { 'NearestMipLerp', 4 },
    { 'BilerpMipNearest', 5 },
  },

  ApplyMode = {
    { 'Replace', 0 },
    { 'Decal', 1 },
    { 'Modulate', 2 },
    { 'Hilight', 3 },
    { 'Hilight2', 4 },
  },
  SourceVertexMode = { { 'Ignore', 0 }, { 'Emissive', 1 }, { 'AmbientDiffuse', 2 } },
  LightingMode = { { 'Emissive', 0 }, { 'EmissiveAmbientDiffuse', 1 } },
}

--[[
Array element kinds (`nif/array.luau`): what a list of numbers, vectors, or small tuples reads
as. A kind's `values` are what `get` returns and `set` takes, in order; each is a name, `number`
or `vector`, and the components it is stored as, `{ encoding, offset }` (a vector's missing z is
0). `shape` is what `toTable` makes of an element: `value` (the one value), `list` (the values in
order), `record` (by name), or `grouped` (by name, with x, y, z, w or r, g, b, a gathered into
`value`, as jess-nif's keys have them).
]]
export type Encoding = 'u8' | 'u16' | 'u32' | 'i32' | 'f32'

export type Component = { encoding: Encoding, offset: number }

export type ArrayValue = { name: string, type: 'number' | 'vector', components: { Component } }

export type ArrayKind = {
  kind: string,
  type: string,
  doc: string,
  stride: number,
  shape: 'value' | 'list' | 'record' | 'grouped',
  values: { ArrayValue },
}

local function scalar(name: string, encoding: Encoding, offset: number): ArrayValue
  return { name = name, type = 'number', components = { { encoding = encoding, offset = offset } } }
end

local function at(encoding: Encoding, offset: number): Component
  return { encoding = encoding, offset = offset }
end

--- A vector of two or three components.
local function vec(name: string, ...: Component): ArrayValue
  return { name = name, type = 'vector', components = { ... } }
end

local function f32s(names: { string }, first: number): { ArrayValue }
  local values = {}
  for i, name in names do
    table.insert(values, scalar(name, 'f32', first + (i - 1) * 4))
  end

  return values
end

local function join(...: { ArrayValue }): { ArrayValue }
  local values = {}
  for _, list in { ... } do
    for _, value in list do
      table.insert(values, value)
    end
  end

  return values
end

local ArrayKinds: { ArrayKind } = {
  {
    kind = 'u8',
    type = 'U8Array',
    doc = 'unsigned bytes',
    stride = 1,
    shape = 'value',
    values = { scalar('value', 'u8', 0) },
  },

  {
    kind = 'u16',
    type = 'U16Array',
    doc = 'u16s',
    stride = 2,
    shape = 'value',
    values = { scalar('value', 'u16', 0) },
  },

  {
    kind = 'i32',
    type = 'I32Array',
    doc = 'i32s; as links, record indices, -1 for null',
    stride = 4,
    shape = 'value',
    values = { scalar('value', 'i32', 0) },
  },

  {
    kind = 'f32',
    type = 'F32Array',
    doc = 'floats',
    stride = 4,
    shape = 'value',
    values = { scalar('value', 'f32', 0) },
  },

  {
    kind = 'vec2',
    type = 'Vec2Array',
    doc = 'two floats as a vector, z 0',
    stride = 8,
    shape = 'value',
    values = { vec('value', at('f32', 0), at('f32', 4)) },
  },

  {
    kind = 'vec3',
    type = 'Vec3Array',
    doc = 'three floats as a vector',
    stride = 12,
    shape = 'value',
    values = { vec('value', at('f32', 0), at('f32', 4), at('f32', 8)) },
  },

  {
    kind = 'vec4',
    type = 'Vec4Array',
    doc = 'four floats: x, y, z, w or r, g, b, a',
    stride = 16,
    shape = 'list',
    values = f32s({ 'x', 'y', 'z', 'w' }, 0),
  },

  {
    kind = 'quat',
    type = 'QuatArray',
    doc = 'quaternions, x, y, z, w; stored w first',
    stride = 16,
    shape = 'list',
    values = {
      scalar('x', 'f32', 4),
      scalar('y', 'f32', 8),
      scalar('z', 'f32', 12),
      scalar('w', 'f32', 0),
    },
  },

  {
    kind = 'tri',
    type = 'TriArray',
    doc = 'triangles: three u16 vertex indices as a vector',
    stride = 6,
    shape = 'value',
    values = { vec('value', at('u16', 0), at('u16', 2), at('u16', 4)) },
  },

  {
    kind = 'u16f32',
    type = 'WeightArray',
    doc = 'vertex weights as vector(vertex, weight, 0)',
    stride = 6,
    shape = 'value',
    values = { vec('value', at('u16', 0), at('f32', 2)) },
  },

  {
    kind = 'f32x2',
    type = 'RangeArray',
    doc = 'level of detail ranges: near, far',
    stride = 8,
    shape = 'list',
    values = f32s({ 'near', 'far' }, 0),
  },

  {
    kind = 'u32x3',
    type = 'MipmapArray',
    doc = 'mipmaps: width, height, offset',
    stride = 12,
    shape = 'list',
    values = { scalar('width', 'u32', 0), scalar('height', 'u32', 4), scalar('offset', 'u32', 8) },
  },

  {
    kind = 'u8x4',
    type = 'ColorBytesArray',
    doc = 'RGBA8 colors: r, g, b, a',
    stride = 4,
    shape = 'list',
    values = {
      scalar('r', 'u8', 0),
      scalar('g', 'u8', 1),
      scalar('b', 'u8', 2),
      scalar('a', 'u8', 3),
    },
  },

  {
    kind = 'floatLin',
    type = 'FloatLinKeys',
    doc = 'linear float keys: time, value',
    stride = 8,
    shape = 'record',
    values = f32s({ 'time', 'value' }, 0),
  },

  {
    kind = 'floatBez',
    type = 'FloatBezKeys',
    doc = 'Bezier float keys: time, value, inTan, outTan',
    stride = 16,
    shape = 'record',
    values = f32s({ 'time', 'value', 'inTan', 'outTan' }, 0),
  },

  {
    kind = 'floatTcb',
    type = 'FloatTcbKeys',
    doc = 'TCB float keys: time, value, tension, continuity, bias',
    stride = 20,
    shape = 'record',
    values = f32s({ 'time', 'value', 'tension', 'continuity', 'bias' }, 0),
  },

  {
    kind = 'posLin',
    type = 'PosLinKeys',
    doc = 'linear position keys: time, value',
    stride = 16,
    shape = 'record',
    values = { scalar('time', 'f32', 0), vec('value', at('f32', 4), at('f32', 8), at('f32', 12)) },
  },

  {
    kind = 'posBez',
    type = 'PosBezKeys',
    doc = 'Bezier position keys: time, value, inTan, outTan',
    stride = 40,
    shape = 'record',
    values = {
      scalar('time', 'f32', 0),
      vec('value', at('f32', 4), at('f32', 8), at('f32', 12)),
      vec('inTan', at('f32', 16), at('f32', 20), at('f32', 24)),
      vec('outTan', at('f32', 28), at('f32', 32), at('f32', 36)),
    },
  },

  {
    kind = 'posTcb',
    type = 'PosTcbKeys',
    doc = 'TCB position keys: time, value, tension, continuity, bias',
    stride = 28,
    shape = 'record',
    values = join(
      { scalar('time', 'f32', 0), vec('value', at('f32', 4), at('f32', 8), at('f32', 12)) },
      f32s({ 'tension', 'continuity', 'bias' }, 16)
    ),
  },

  {
    kind = 'rotLin',
    type = 'RotLinKeys',
    doc = 'rotation keys: time, x, y, z, w; stored w first',
    stride = 20,
    shape = 'grouped',
    values = {
      scalar('time', 'f32', 0),
      scalar('x', 'f32', 8),
      scalar('y', 'f32', 12),
      scalar('z', 'f32', 16),
      scalar('w', 'f32', 4),
    },
  },

  {
    kind = 'rotTcb',
    type = 'RotTcbKeys',
    doc = 'TCB rotation keys: time, x, y, z, w, tension, continuity, bias; stored w first',
    stride = 32,
    shape = 'grouped',
    values = join({
      scalar('time', 'f32', 0),
      scalar('x', 'f32', 8),
      scalar('y', 'f32', 12),
      scalar('z', 'f32', 16),
      scalar('w', 'f32', 4),
    }, f32s({ 'tension', 'continuity', 'bias' }, 20)),
  },

  {
    kind = 'colorLin',
    type = 'ColorLinKeys',
    doc = 'color keys: time, r, g, b, a',
    stride = 20,
    shape = 'grouped',
    values = f32s({ 'time', 'r', 'g', 'b', 'a' }, 0),
  },
}

--- Values that are not records: read in place inside one.
local Structs: { [string]: Definition } = {
  NiBound = {
    doc = 'A bounding sphere.',
    fields = { { 'center', 'vec3' }, { 'radius', 'f32' } },
  },

  NiPixelFormat = {
    fields = {
      { 'pixelFormat', 'enum:PixelFormat' },
      { 'colorMasks', 'u32', fixed = 4 },
      { 'bitsPerPixel', 'u32' },
      { 'compareBits', 'u8', fixed = 8 },
    },
  },

  NiPerParticleData = {
    fields = {
      { 'velocity', 'vec3' },
      { 'rotationAxis', 'vec3' },
      { 'age', 'f32' },
      { 'lifespan', 'f32' },
      { 'lastUpdate', 'f32' },
      { 'generation', 'u16' },
      { 'index', 'u16' },
    },
  },

  NiTextKey = {
    fields = { { 'time', 'f32' }, { 'value', 'string' } },
  },

  NiVisKey = {
    fields = { { 'time', 'f32' }, { 'value', 'u8' } },
  },

  NiSequence = {
    fields = {
      { 'sequenceName', 'string' },
      { 'sequenceTarget', 'custom:sequenceTarget' },
      { 'nameControllerPairs', 'custom:nameControllerPairs' },
    },
  },

  BoneData = {
    fields = {
      { 'rotation', 'mat3' },
      { 'translation', 'vec3' },
      { 'scale', 'f32' },
      { 'bound', 'NiBound' },
      { 'vertexWeights', 'u16f32', list = 'u16', doc = 'Each `vector(vertex, weight, 0)`.' },
    },
  },

  Partition = {
    fields = {
      { '_numVertices', 'u16', save = 'r.vertexIndices.count' },
      { '_numTriangles', 'u16', save = 'r.triangles.count' },
      { '_numBones', 'u16', save = 'r.bones.count' },
      { '_numStripLengths', 'u16', save = 'r.stripLengths.count' },
      { 'numBonesPerVertex', 'u16' },
      { '_numWeights', expr = '_numVertices * numBonesPerVertex' },
      { 'bones', 'u16', count = '_numBones' },
      { 'vertexIndices', 'u16', count = '_numVertices' },
      { 'weights', 'f32', count = '_numWeights' },
      { 'triangles', 'tri', count = '_numTriangles' },
      { 'stripLengths', 'u16', count = '_numStripLengths' },
      {
        'strips',
        'u16',
        count = 'Array.sum(stripLengths)',
        scanCount = 'C.sumU16(b, stripLengthsAt, _numStripLengths)',
      },
      { '_hasBonePalette', 'u8', save = 'r.bonePalette and 1 or 0' },
      { 'bonePalette', 'u8', count = '_numWeights', when = '_hasBonePalette ~= 0' },
    },
  },

  MorphTarget = {
    fields = {
      { 'keys', 'custom:morphKeys' },
      { 'vertices', 'vec3', count = 'S.morphVertices' },
    },
  },
  FloatData = { fields = { { 'keys', 'custom:floatKeys' } } },
  PosData = { fields = { { 'keys', 'custom:posKeys' } } },
  RotData = { fields = { { 'keys', 'custom:rotKeys' } } },
}

--- Every record type, in `NiType`'s order. A record's fields follow its base's.
local Records: { { name: string, definition: Definition } } = {}

local function record(name: string, definition: Definition)
  table.insert(Records, { name = name, definition = definition })
end

local function alias(name: string, base: string) record(name, { base = base, fields = {} }) end

record('NiObject', { fields = {} })

record('NiObjectNET', {
  base = 'NiObject',
  fields = { { 'name', 'string' }, { 'extraData', 'link' }, { 'controller', 'link' } },
})

record('NiAVObject', {
  base = 'NiObjectNET',
  fields = {
    { 'flags', 'u16' },
    { 'translation', 'vec3' },
    { 'rotation', 'mat3' },
    { 'scale', 'f32' },
    { 'velocity', 'vec3' },
    { 'properties', 'link', list = 'u32' },
    { '_hasBoundingVolume', 'u32', save = 'r.boundingVolume and 1 or 0' },
    { 'boundingVolume', 'custom:boundingVolume', when = '_hasBoundingVolume ~= 0' },
  },
})

record('NiNode', {
  base = 'NiAVObject',
  fields = { { 'children', 'link', list = 'u32' }, { 'effects', 'link', list = 'u32' } },
})

alias('AvoidNode', 'NiNode')
alias('BSMirroredNode', 'NiNode')
alias('NiBillboardNode', 'NiNode')
alias('NiBSAnimationManager', 'NiNode')
alias('NiBSAnimationNode', 'NiNode')
alias('NiBSParticleNode', 'NiNode')
alias('NiCollisionSwitch', 'NiNode')
alias('RootCollisionNode', 'NiNode')
record('NiSwitchNode', { base = 'NiNode', fields = { { 'activeIndex', 'u32' } } })
record('NiFltAnimationNode', { base = 'NiSwitchNode', fields = { { 'period', 'f32' } } })

record('NiLODNode', {
  base = 'NiSwitchNode',
  fields = {
    { 'lodCenter', 'vec3' },
    { 'lodLevels', 'f32x2', list = 'u32', doc = 'Each `{ near, far }`.' },
  },
})

record('NiBSPNode', { base = 'NiNode', fields = { { 'plane', 'f32', fixed = 4 } } })

record('NiSortAdjustNode', {
  base = 'NiNode',
  fields = { { 'sortingMode', 'enum:SortingMode' }, { 'subSorter', 'link' } },
})

record('NiCamera', {
  base = 'NiAVObject',
  fields = {
    { 'viewFrustum', 'f32', fixed = 6 },
    { 'viewPort', 'f32', fixed = 4 },
    { 'lodAdjust', 'f32' },
    { 'scene', 'link' },
    { 'screenPolygons', 'link', list = 'u32' },
  },
})

record('NiDynamicEffect', {
  base = 'NiAVObject',
  fields = {
    { 'affectedNodes', 'i32', list = 'u32', doc = 'Indices the engine does not resolve.' },
  },
})

record('NiLight', {
  base = 'NiDynamicEffect',
  fields = {
    { 'dimmer', 'f32' },
    { 'ambientColor', 'vec3' },
    { 'diffuseColor', 'vec3' },
    { 'specularColor', 'vec3' },
  },
})

alias('NiAmbientLight', 'NiLight')
alias('NiDirectionalLight', 'NiLight')

record('NiPointLight', {
  base = 'NiLight',
  fields = {
    { 'constantAttenuation', 'f32' },
    { 'linearAttenuation', 'f32' },
    { 'quadraticAttenuation', 'f32' },
  },
})

record(
  'NiSpotLight',
  { base = 'NiPointLight', fields = { { 'outerSpotAngle', 'f32' }, { 'exponent', 'f32' } } }
)

record('NiTextureEffect', {
  base = 'NiDynamicEffect',
  fields = {
    { 'projectionMatrix', 'mat3' },
    { 'projectionTranslation', 'vec3' },
    { 'textureFilter', 'enum:FilterMode' },
    { 'textureClamp', 'enum:ClampMode' },
    { 'textureType', 'enum:TextureType' },
    { 'coordinateGenerationType', 'enum:CoordGenType' },
    { 'sourceTexture', 'link' },
    { 'clippingPlaneEnable', 'u8' },
    { 'clippingPlane', 'f32', fixed = 4 },
    { 'ps2L', 'i16' },
    { 'ps2K', 'i16' },
    { 'unknownByte1', 'u8' },
    { 'unknownByte2', 'u8' },
  },
})

record('NiGeometry', {
  base = 'NiAVObject',
  fields = { { 'geometryData', 'link' }, { 'skinInstance', 'link' } },
})

alias('NiTriBasedGeom', 'NiGeometry')
alias('NiTriShape', 'NiTriBasedGeom')
alias('NiTriStrips', 'NiTriBasedGeom')
alias('NiLines', 'NiGeometry')
alias('NiParticles', 'NiGeometry')
alias('NiAutoNormalParticles', 'NiParticles')
alias('NiRotatingParticles', 'NiParticles')

record('NiGeometryData', {
  base = 'NiObject',
  fields = {
    { '_numVertices', 'u16', save = 'r.vertices.count' },
    { '_hasVertices', 'u32', save = 'r.vertices.count > 0 and 1 or 0' },
    { '_count', expr = '_hasVertices ~= 0 and _numVertices or 0', stash = 'vertexCount' },
    { 'vertices', 'vec3', count = '_count' },
    { '_hasNormals', 'u32', save = 'r.normals.count > 0 and 1 or 0' },
    { 'normals', 'vec3', count = '_hasNormals ~= 0 and _count or 0' },
    { 'bound', 'NiBound' },
    { '_hasVertexColors', 'u32', save = 'r.vertexColors.count > 0 and 1 or 0' },
    { 'vertexColors', 'vec4', count = '_hasVertexColors ~= 0 and _count or 0' },
    { '_numUvSets', 'u16', save = 'C.uvSetCount(r)' },
    { '_hasUvSets', 'u32', save = 'C.uvSetTotal(r) > 0 and 1 or 0' },
    {
      'uvSets',
      'custom:uvSets',
      args = '_hasUvSets ~= 0 and _numUvSets or 0, _count',
      doc = 'One list of coordinates per set.',
    },
  },
})

alias('NiTriBasedGeomData', 'NiGeometryData')

record('NiTriShapeData', {
  base = 'NiTriBasedGeomData',
  fields = {
    { '_numTriangles', 'u16', save = 'r.triangles.count' },
    { '_numTrianglePoints', 'u32', save = 'r.triangles.count * 3' },
    { 'triangles', 'tri', count = '_numTrianglePoints // 3' },
    { 'sharedNormals', 'custom:sharedNormals' },
  },
})

record('NiTriShapeDynamicData', {
  base = 'NiTriShapeData',
  fields = { { 'activeVertices', 'u16' }, { 'activeTriangles', 'u16' } },
})

record('NiTriStripsData', {
  base = 'NiTriBasedGeomData',
  fields = {
    { 'numTriangles', 'u16' },
    { '_numStripLengths', 'u16', save = 'r.stripLengths.count' },
    { 'stripLengths', 'u16', count = '_numStripLengths' },
    {
      'strips',
      'u16',
      count = 'Array.sum(stripLengths)',
      scanCount = 'C.sumU16(b, stripLengthsAt, _numStripLengths)',
    },
  },
})

record('NiLinesData', {
  base = 'NiGeometryData',
  fields = { { 'vertexConnectivityFlags', 'u8', count = 'S.vertexCount' } },
})

record('NiParticlesData', {
  base = 'NiGeometryData',
  fields = {
    { 'numParticles', 'u16' },
    { 'particleRadius', 'f32' },
    { 'numActive', 'u16' },
    { '_hasSizes', 'u32', save = 'r.sizes.count > 0 and 1 or 0' },
    { 'sizes', 'f32', count = '_hasSizes ~= 0 and S.vertexCount or 0' },
  },
})

alias('NiAutoNormalParticlesData', 'NiParticlesData')

record('NiRotatingParticlesData', {
  base = 'NiParticlesData',
  fields = {
    { '_hasRotations', 'u32', save = 'r.rotations.count > 0 and 1 or 0' },
    { 'rotations', 'quat', count = '_hasRotations ~= 0 and S.vertexCount or 0' },
  },
})

record('NiSkinInstance', {
  base = 'NiObject',
  fields = { { 'data', 'link' }, { 'root', 'link' }, { 'bones', 'link', list = 'u32' } },
})

record('NiSkinData', {
  base = 'NiObject',
  fields = {
    { 'rotation', 'mat3' },
    { 'translation', 'vec3' },
    { 'scale', 'f32' },
    { '_numBoneData', 'u32', save = '#r.boneData' },
    { 'skinPartition', 'link' },
    { 'boneData', 'BoneData', count = '_numBoneData' },
  },
})

record(
  'NiSkinPartition',
  { base = 'NiObject', fields = { { 'partitions', 'Partition', list = 'u32' } } }
)

record('NiPixelData', {
  base = 'NiObject',
  fields = {
    { 'pixelFormat', 'NiPixelFormat' },
    { 'palette', 'link' },
    { '_numMipmaps', 'u32', save = 'r.mipmaps.count' },
    { 'pixelStride', 'u32' },
    { 'mipmaps', 'u32x3', count = '_numMipmaps', doc = 'Each `{ width, height, offset }`.' },
    { 'pixelData', 'u8', list = 'u32' },
  },
})

record('NiPalette', {
  base = 'NiObject',
  fields = {
    { 'hasAlpha', 'bool8' },
    { 'palettes', 'u8x4', list = 'u32', doc = 'Each `{ r, g, b, a }`.' },
  },
})

record('NiTexture', { base = 'NiObjectNET', fields = {} })
alias('NiRenderedTexture', 'NiTexture')
alias('NiRenderedCubeMap', 'NiRenderedTexture')

record('NiSourceTexture', {
  base = 'NiTexture',
  fields = {
    { 'source', 'custom:textureSource' },
    { 'pixelLayout', 'enum:PixelLayout' },
    { 'useMipmaps', 'enum:UseMipMaps' },
    { 'alphaFormat', 'enum:AlphaFormat' },
    { 'isStatic', 'bool8' },
  },
})

record('NiBltSource', { base = 'NiObject', fields = { { 'source', 'custom:textureSource' } } })
record('NiProperty', { base = 'NiObjectNET', fields = { { 'flags', 'u16' } } })
record('NiAlphaProperty', { base = 'NiProperty', fields = { { 'testRef', 'u8' } } })
alias('NiDitherProperty', 'NiProperty')
alias('NiShadeProperty', 'NiProperty')
alias('NiSpecularProperty', 'NiProperty')
alias('NiWireframeProperty', 'NiProperty')
alias('NiZBufferProperty', 'NiProperty')
record(
  'NiFogProperty',
  { base = 'NiProperty', fields = { { 'fogDepth', 'f32' }, { 'fogColor', 'vec3' } } }
)

record('NiMaterialProperty', {
  base = 'NiProperty',
  fields = {
    { 'ambientColor', 'vec3' },
    { 'diffuseColor', 'vec3' },
    { 'specularColor', 'vec3' },
    { 'emissiveColor', 'vec3' },
    { 'shine', 'f32' },
    { 'alpha', 'f32' },
  },
})

record('NiStencilProperty', {
  base = 'NiProperty',
  fields = {
    { 'stencilEnabled', 'bool8' },
    { 'stencilFunction', 'enum:StencilTestFunction' },
    { 'stencilRef', 'u32' },
    { 'stencilMask', 'u32' },
    { 'failAction', 'enum:Action' },
    { 'passZFailAction', 'enum:Action' },
    { 'passAction', 'enum:Action' },
    { 'drawMode', 'enum:DrawMode' },
  },
})

record('NiVertexColorProperty', {
  base = 'NiProperty',
  fields = {
    { 'sourceVertexMode', 'enum:SourceVertexMode' },
    { 'lightingMode', 'enum:LightingMode' },
  },
})

record('NiTexturingProperty', {
  base = 'NiProperty',
  fields = { { 'applyMode', 'enum:ApplyMode' }, { 'textureMaps', 'custom:textureMaps' } },
})

record(
  'NiExtraData',
  { base = 'NiObject', fields = { { 'next', 'link' }, { 'bytesRemaining', 'u32' } } }
)
alias('BrickNiExtraData', 'NiExtraData')
alias('TES3ObjectExtraData', 'NiExtraData')
record('NiStringExtraData', { base = 'NiExtraData', fields = { { 'value', 'string' } } })
record(
  'NiTextKeyExtraData',
  { base = 'NiExtraData', fields = { { 'keys', 'NiTextKey', list = 'u32' } } }
)
record(
  'NiVertWeightsExtraData',
  { base = 'NiExtraData', fields = { { 'weights', 'f32', list = 'u16' } } }
)

record('NiTimeController', {
  base = 'NiObject',
  fields = {
    { 'next', 'link' },
    { 'flags', 'u16' },
    { 'frequency', 'f32' },
    { 'phase', 'f32' },
    { 'startTime', 'f32' },
    { 'stopTime', 'f32' },
    { 'target', 'link' },
  },
})

record('NiFloatController', { base = 'NiTimeController', fields = { { 'data', 'link' } } })
alias('NiAlphaController', 'NiFloatController')
alias('NiRollController', 'NiFloatController')

record('NiFlipController', {
  base = 'NiTimeController',
  fields = {
    { 'affectedMap', 'u32' },
    { 'flipStartTime', 'f32' },
    { 'secsPerFrame', 'f32' },
    { 'textures', 'link', list = 'u32' },
  },
})

record('NiKeyframeController', { base = 'NiTimeController', fields = { { 'data', 'link' } } })
record('NiLightColorController', { base = 'NiTimeController', fields = { { 'data', 'link' } } })
record('NiMaterialColorController', { base = 'NiTimeController', fields = { { 'data', 'link' } } })
record('NiLookAtController', { base = 'NiTimeController', fields = { { 'lookAt', 'link' } } })
record('NiVisController', { base = 'NiTimeController', fields = { { 'data', 'link' } } })
record('NiMorpherController', { base = 'NiTimeController', fields = { { 'data', 'link' } } })
record(
  'NiGeomMorpherController',
  { base = 'NiMorpherController', fields = { { 'alwaysUpdate', 'bool8' } } }
)

record('NiUVController', {
  base = 'NiTimeController',
  fields = { { 'textureSet', 'u16' }, { 'data', 'link' } },
})

record('NiPathController', {
  base = 'NiTimeController',
  fields = {
    { 'bankDirection', 'enum:BankDirection' },
    { 'maxBankAngle', 'f32' },
    { 'smoothing', 'f32' },
    { 'followAxis', 'u16' },
    { 'data', 'link' },
    { 'percentageData', 'link' },
  },
})

record('NiParticleSystemController', {
  base = 'NiTimeController',
  fields = {
    { 'speed', 'f32' },
    { 'speedVariation', 'f32' },
    { 'declinationAngle', 'f32' },
    { 'declinationVariation', 'f32' },
    { 'planarAngle', 'f32' },
    { 'planarAngleVariation', 'f32' },
    { 'initialNormal', 'vec3' },
    { 'initialColor', 'vec4' },
    { 'initialSize', 'f32' },
    { 'emitStartTime', 'f32' },
    { 'emitStopTime', 'f32' },
    { 'resetParticleSystem', 'bool8' },
    { 'birthRate', 'f32' },
    { 'lifespan', 'f32' },
    { 'lifespanVariation', 'f32' },
    { 'useBirthRate', 'bool8' },
    { 'spawnOnDeath', 'bool8' },
    { 'emitterWidth', 'f32' },
    { 'emitterHeight', 'f32' },
    { 'emitterDepth', 'f32' },
    { 'emitter', 'link' },
    { 'spawnGenerations', 'u16' },
    { 'spawnPercentage', 'f32' },
    { 'spawnMultiplier', 'u16' },
    { 'spawnedSpeedChaos', 'f32' },
    { 'spawnedDirectionChaos', 'f32' },
    { 'particles', 'NiPerParticleData', list = 'u16' },
    { 'numActiveParticles', 'u16' },
    { 'emitterModifier', 'link' },
    { 'particleModifier', 'link' },
    { 'particleCollider', 'link' },
    { 'computeDynamicBoundingVolume', 'bool8' },
  },
})

alias('NiBSPArrayController', 'NiParticleSystemController')
record(
  'NiKeyframeManager',
  { base = 'NiTimeController', fields = { { 'sequences', 'NiSequence', list = 'u32' } } }
)

record('NiParticleModifier', {
  base = 'NiObject',
  fields = { { 'next', 'link' }, { 'controller', 'link' } },
})

record('NiGravity', {
  base = 'NiParticleModifier',
  fields = {
    { 'decay', 'f32' },
    { 'strength', 'f32' },
    { 'forceType', 'enum:ForceType' },
    { 'position', 'vec3' },
    { 'direction', 'vec3' },
  },
})

record('NiParticleBomb', {
  base = 'NiParticleModifier',
  fields = {
    { 'decay', 'f32' },
    { 'duration', 'f32' },
    { 'deltaV', 'f32' },
    { 'startTime', 'f32' },
    { 'decayType', 'enum:DecayType' },
    { 'symmetryType', 'enum:SymmetryType' },
    { 'position', 'vec3' },
    { 'direction', 'vec3' },
  },
})

record('NiParticleCollider', { base = 'NiParticleModifier', fields = { { 'bounce', 'f32' } } })

record('NiPlanarCollider', {
  base = 'NiParticleCollider',
  fields = {
    { 'height', 'f32' },
    { 'width', 'f32' },
    { 'position', 'vec3' },
    { 'xAxis', 'vec3' },
    { 'yAxis', 'vec3' },
    { 'normal', 'vec3' },
    { 'constant', 'f32' },
  },
})

record('NiSphericalCollider', {
  base = 'NiParticleCollider',
  fields = { { 'radius', 'f32' }, { 'position', 'vec3' } },
})

record(
  'NiParticleColorModifier',
  { base = 'NiParticleModifier', fields = { { 'colorData', 'link' } } }
)

record('NiParticleGrowFade', {
  base = 'NiParticleModifier',
  fields = { { 'growTime', 'f32' }, { 'fadeTime', 'f32' } },
})

record('NiParticleRotation', {
  base = 'NiParticleModifier',
  fields = {
    { 'randomInitialAxis', 'bool8' },
    { 'initialAxis', 'vec3' },
    { 'rotationSpeed', 'f32' },
  },
})

alias('NiEmitterModifier', 'NiObject')
record('NiColorData', { base = 'NiObject', fields = { { 'keys', 'custom:colorKeys' } } })
record('NiFloatData', { base = 'NiObject', fields = { { 'keys', 'custom:floatKeys' } } })
record('NiPosData', { base = 'NiObject', fields = { { 'keys', 'custom:posKeys' } } })
record('NiRotData', { base = 'NiObject', fields = { { 'keys', 'custom:rotKeys' } } })

record('NiKeyframeData', {
  base = 'NiObject',
  fields = { { 'rotations', 'RotData' }, { 'translations', 'PosData' }, { 'scales', 'FloatData' } },
})

record('NiUVData', {
  base = 'NiObject',
  fields = {
    { 'uOffsetData', 'FloatData' },
    { 'vOffsetData', 'FloatData' },
    { 'uTilingData', 'FloatData' },
    { 'vTilingData', 'FloatData' },
  },
})

record('NiMorphData', {
  base = 'NiObject',
  fields = {
    { '_numTargets', 'u32', save = '#r.targets' },
    {
      '_numVertices',
      'u32',
      save = 'r.targets[1] and r.targets[1].vertices.count or 0',
      stash = 'morphVertices',
    },
    { 'relativeTargets', 'bool8' },
    { 'targets', 'MorphTarget', count = '_numTargets' },
  },
})

record('NiVisData', { base = 'NiObject', fields = { { 'keys', 'NiVisKey', list = 'u32' } } })
alias('NiSequenceStreamHelper', 'NiObjectNET')

record('NiScreenPolygon', {
  base = 'NiObject',
  fields = {
    { '_numVertices', 'u16', save = 'r.vertices.count' },
    { 'vertices', 'vec3', count = '_numVertices' },
    { '_hasUvCoords', 'u32', save = 'r.uvCoords.count > 0 and 1 or 0' },
    { 'uvCoords', 'vec2', count = '_hasUvCoords ~= 0 and _numVertices or 0' },
    { '_hasVertexColors', 'u32', save = 'r.vertexColors.count > 0 and 1 or 0' },
    { 'vertexColors', 'vec4', count = '_hasVertexColors ~= 0 and _numVertices or 0' },
    { 'propertyStates', 'i32', list = 'u32' },
  },
})

alias('NiAccumulator', 'NiObject')
alias('NiClusterAccumulator', 'NiAccumulator')
alias('NiAlphaAccumulator', 'NiClusterAccumulator')
alias('NiRenderer', 'NiObject')
alias('NiDX8Renderer', 'NiRenderer')

return table.freeze { Enums = Enums, Structs = Structs, Records = Records, ArrayKinds = ArrayKinds }
