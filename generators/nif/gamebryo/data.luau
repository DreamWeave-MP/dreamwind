--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- OpenMW's `components/nif/data.hpp`.

local Schema = require '../gamebryo_schema'

local class, struct = Schema.class, Schema.struct

class('NiGeometryData', nil, {
  { 'groupId', 'i32', when = 'V >= @10.1.0.114' },
  { 'numVertices', 'u16' },
  -- Particle system data from Fallout 3 on has flags but no vertex data.
  {
    '_hasData',
    expr = 'not (RN == \'NiPSysData\' or RN == \'NiMeshPSysData\' or RN == \'BSStripPSysData\') or BV < FO3',
    default = 'true',
  },
  { 'keepFlags', 'u8', when = 'V >= @10.1.0.0' },
  { 'compressFlags', 'u8', when = 'V >= @10.1.0.0' },
  { '_hasVertices', 'bool' },
  { 'vertices', 'vec3', count = 'numVertices', when = '_hasVertices and _hasData' },
  { 'dataFlags', 'u16', when = 'V >= @10.0.1.0' },
  { 'materialHash', 'u32', when = 'V >= @10.0.1.0 and V == VER_BGS and BV > FO3' },
  { '_hasNormals', 'bool' },
  { 'normals', 'vec3', count = 'numVertices', when = '_hasNormals and _hasData' },
  {
    'tangents',
    'vec3',
    count = 'numVertices',
    when = '_hasNormals and _hasData and bit32.btest(dataFlags, 0x1000)',
  },

  {
    'bitangents',
    'vec3',
    count = 'numVertices',
    when = '_hasNormals and _hasData and bit32.btest(dataFlags, 0x1000)',
  },
  { 'boundingSphere', 'sphere' },
  { '_hasColors', 'bool' },
  { 'colors', 'vec4', count = 'numVertices', when = '_hasColors and _hasData' },
  { 'dataFlags', 'u16', when = 'V <= @4.2.2.0' },
  -- In 4.0.0.2 the flags are the number of UV sets; later, only part of them is.
  { '_numUvs', expr = 'dataFlags', default = '0' },
  { '_numUvs', expr = 'bit32.band(_numUvs, 0x3F)', when = 'V > VER_MW' },
  { '_numUvs', expr = 'bit32.band(_numUvs, 1)', when = 'V > VER_MW and V == VER_BGS and BV > 0' },
  { '_hasUvs', 'bool', when = 'V <= VER_MW' },
  { '_numUvs', expr = '0', when = 'V <= VER_MW and not _hasUvs' },
  { 'uvList', 'custom:vec2Lists(_numUvs, numVertices)', when = '_hasData', default = '{}' },
  { 'consistencyType', 'u16', when = 'V >= @10.0.1.0' },
  { skip = 4, when = 'V >= @20.0.0.4' },
})

class('NiTriBasedGeomData', 'NiGeometryData', {
  { 'numTriangles', 'u16' },
})

class('NiTriShapeData', 'NiTriBasedGeomData', {
  { '_numIndices', 'u32' },
  { '_hasTriangles', 'bool', when = 'V > VER_OB_OLD' },
  { 'triangles', 'u16', count = '_numIndices', when = 'V <= VER_OB_OLD or _hasTriangles' },
  { 'matchGroups', 'custom:u16Lists', default = '{}' },
})

class('NiTriStripsData', 'NiTriBasedGeomData', {
  { '_numStrips', 'u16' },
  { '_lengths', 'u16', count = '_numStrips' },
  { '_hasStrips', 'bool', when = 'V > VER_OB_OLD' },
  { 'strips', 'custom:strips(_lengths)', when = 'V <= VER_OB_OLD or _hasStrips', default = '{}' },
})

class('NiLinesData', 'NiGeometryData', {
  { 'lines', 'custom:lines(numVertices)' },
})

class('NiPosData', nil, {
  { 'keyList', 'custom:vec3Keys' },
})

class('NiUVData', nil, {
  { 'keyList', 'custom:floatKeys', fixed = 4 },
})

class('NiFloatData', nil, {
  { 'keyList', 'custom:floatKeys' },
})

struct('NiPixelFormatChannelData', {
  { 'type', 'u32' },
  { 'convention', 'u32' },
  { 'bitsPerChannel', 'u8' },
  { 'signed', 'bool' },
})

struct('NiPixelFormat', {
  { 'format', 'u32' },
  { 'colorMasks', 'u32', fixed = 4, when = 'V <= @10.4.0.1', default = 'table.create(4, 0)' },
  { 'bitsPerPixel', 'u32', when = 'V <= @10.4.0.1' },
  { 'compareBits', 'u32', fixed = 2, when = 'V <= @10.4.0.1', default = 'table.create(2, 0)' },
  { 'pixelTiling', 'u32', when = 'V <= @10.4.0.1 and V >= @10.1.0.0' },
  { 'bitsPerPixel', 'u8', when = 'V > @10.4.0.1' },
  { 'rendererHint', 'u32', when = 'V > @10.4.0.1' },
  { 'extraData', 'u32', when = 'V > @10.4.0.1' },
  { 'flags', 'u8', when = 'V > @10.4.0.1' },
  { 'pixelTiling', 'u32', when = 'V > @10.4.0.1' },
  { 'useSrgb', 'bool', when = 'V > @10.4.0.1 and V >= @20.3.0.4' },
  {
    'channels',
    'NiPixelFormatChannelData',
    fixed = 4,
    when = 'V > @10.4.0.1',
    default = '{ D.NiPixelFormatChannelData(), D.NiPixelFormatChannelData(), D.NiPixelFormatChannelData(), D.NiPixelFormatChannelData() }',
  },
})

struct('NiPixelDataMipmap', {
  { 'width', 'u32' },
  { 'height', 'u32' },
  { 'offset', 'u32' },
})

class('NiPixelData', nil, {
  { 'pixelFormat', 'NiPixelFormat' },
  { 'palette', 'link:NiPalette' },
  { '_numMipmaps', 'u32' },
  { 'bytesPerPixel', 'u32' },
  { 'mipmaps', 'NiPixelDataMipmap', count = '_numMipmaps' },
  { '_numPixels', 'u32' },
  { 'numFaces', 'u32', when = 'V >= @10.4.0.2', default = '1' },
  -- Kept, as jess-nif keeps it, though its dump leaves it out.
  { 'data', 'u8', count = '_numPixels * numFaces' },
})

class('NiColorData', nil, {
  { 'keyMap', 'custom:vec4Keys' },
})

class('NiVisData', nil, {
  { 'keys', 'custom:visKeys' },
})

class('NiSkinInstance', nil, {
  { 'data', 'link:NiSkinData' },
  { 'partitions', 'link:NiSkinPartition', when = 'V >= @10.1.0.101' },
  { 'root', 'link:NiAVObject' },
  { 'bones', 'links:NiAVObject' },
}, { post = { 'skinInstance' } })

struct('BSDismemberSkinInstanceBodyPart', {
  { 'flags', 'u16' },
  { 'type', 'u16' },
})

class('BSDismemberSkinInstance', 'NiSkinInstance', {
  { 'parts', 'BSDismemberSkinInstanceBodyPart', list = 'u32' },
})

class('BSSkinInstance', nil, {
  { 'root', 'link:NiAVObject' },
  { 'data', 'link:BSSkinBoneData' },
  { 'bones', 'links:NiAVObject' },
  { 'scales', 'vec3', list = 'u32' },
}, { post = { 'bsSkinInstance' } })

class('NiSkinData', nil, {
  { 'transform', 'NiTransform' },
  { '_numBones', 'u32' },
  { 'partitions', 'link:NiSkinPartition', when = 'V >= VER_MW and V <= @10.1.0.0' },
  { '_hasVertexWeights', 'bool', when = 'V >= VER_MW and V >= @4.2.1.0', default = 'true' },
  { 'bones', 'custom:skinBones(_numBones, _hasVertexWeights)' },
})

struct('BSSkinBoneDataBoneInfo', {
  { 'boundSphere', 'sphere' },
  { 'transform', 'NiTransform' },
})

class('BSSkinBoneData', nil, {
  { 'bones', 'BSSkinBoneDataBoneInfo', list = 'u32' },
})

struct('NiSkinPartitionPartition', {
  { '_numVertices', 'u16' },
  { '_numTriangles', 'u16' },
  { '_numBones', 'u16' },
  { '_numStrips', 'u16' },
  { '_bonesPerVertex', 'u16' },
  { 'bones', 'u16', count = '_numBones' },
  { '_hasVertexMap', 'bool', when = 'V >= @10.1.0.0', default = 'true' },
  { 'vertexMap', 'u16', count = '_numVertices', when = '_hasVertexMap' },
  { '_hasWeights', 'bool', when = 'V >= @10.1.0.0', default = 'true' },
  { 'weights', 'f32', count = '_numVertices * _bonesPerVertex', when = '_hasWeights' },
  { '_stripLengths', 'u16', count = '_numStrips' },
  { '_hasFaces', 'bool', when = 'V >= @10.1.0.0', default = 'true' },
  { 'triangles', 'u16', count = '_numTriangles * 3', when = '_hasFaces and _numStrips == 0' },
  {
    'strips',
    'custom:strips(_stripLengths)',
    when = '_hasFaces and _numStrips ~= 0',
    default = '{}',
  },
  { '_hasBoneIndices', 'u8' },
  { 'boneIndices', 'u8', count = '_numVertices * _bonesPerVertex', when = '_hasBoneIndices ~= 0' },
  { 'lodLevel', 'u8', when = 'BV > FO3' },
  { 'globalVb', 'bool', when = 'BV > FO3' },
  { 'vertexDesc', 'custom:vertexDesc', when = 'BV == SSE', default = 'C.noVertexDesc()' },
  { 'trueTriangles', 'u16', count = '_numTriangles * 3', when = 'BV == SSE' },
  -- Not part of loading, but OpenMW does it here, without checking the indices.
  { '_remap', expr = '#trueTriangles == 0 and #vertexMap > 0', default = 'false' },
  {
    'trueStrips',
    expr = 'C.remapStrips(strips, vertexMap)',
    when = '_remap and #strips > 0',
    default = '{}',
  },

  {
    'trueTriangles',
    expr = 'C.remap(triangles, vertexMap)',
    when = '_remap and #strips == 0 and #triangles > 0',
  },
})

class('NiSkinPartition', nil, {
  { '_numPartitions', 'u32' },
  { 'dataSize', 'u32', when = 'BV == SSE' },
  { 'vertexSize', 'u32', when = 'BV == SSE' },
  { 'vertexDesc', 'custom:vertexDesc', when = 'BV == SSE', default = 'C.noVertexDesc()' },
  -- OpenMW divides without checking; a vertex size of 0 would crash it.
  { check = 'BV ~= SSE or vertexSize ~= 0', message = 'NiSkinPartition vertex size is 0' },
  {
    'vertexData',
    'custom:vertexData(dataSize // vertexSize, vertexDesc.flags)',
    when = 'BV == SSE',
    default = '{}',
  },
  { 'partitions', 'NiSkinPartitionPartition', count = '_numPartitions' },
})

class('NiMorphData', nil, {
  { '_numMorphs', 'u32' },
  { '_numVertices', 'u32' },
  { 'relativeTargets', 'u8' },
  { 'morphs', 'custom:morphs(_numMorphs, _numVertices)' },
})

class('NiKeyframeData', nil, {
  { 'rotations', 'custom:quatKeys' },
  -- XYZ rotations: three float key groups instead of quaternion keys.
  { 'axisOrder', 'u32', when = 'rotations.interpolationType == 4 and V <= @10.1.0.0' },
  { 'xRotations', 'custom:floatKeys', when = 'rotations.interpolationType == 4' },
  { 'yRotations', 'custom:floatKeys', when = 'rotations.interpolationType == 4' },
  { 'zRotations', 'custom:floatKeys', when = 'rotations.interpolationType == 4' },
  { 'translations', 'custom:vec3Keys' },
  { 'scales', 'custom:floatKeys' },
})

class('NiPalette', nil, {
  { '_useAlpha', 'u8' },
  { 'colors', 'custom:paletteColors(_useAlpha ~= 0)' },
})

class('NiStringPalette', nil, {
  { 'palette', 'palette' },
  -- The palette's size again, only checked for a warning.
  { '_size', 'u32' },
})

class('NiBoolData', nil, {
  { 'keyList', 'custom:boolKeys' },
})

class('NiBSplineData', nil, {
  { 'floatControlPoints', 'f32', list = 'u32' },
  { 'compactControlPoints', 'i16', list = 'u32' },
})

class('NiBSplineBasisData', nil, {
  { 'numControlPoints', 'u32' },
})

struct('NiAdditionalGeometryDataDataStream', {
  { 'type', 'u32' },
  { 'unitSize', 'u32' },
  { 'totalSize', 'u32' },
  { 'stride', 'u32' },
  { 'blockIndex', 'u32' },
  { 'blockOffset', 'u32' },
  { 'flags', 'u8' },
})

class('NiAdditionalGeometryData', nil, {
  { 'numVertices', 'u16' },
  { 'blockInfos', 'NiAdditionalGeometryDataDataStream', list = 'u32' },
  -- `BSPackedAdditionalGeometryData`'s blocks end with two more values.
  { 'blocks', 'custom:geometryBlocks(RN == \'BSPackedAdditionalGeometryData\')' },
})

class('BSMultiBound', nil, {
  { 'data', 'link:BSMultiBoundData' },
})

class('BSMultiBoundData', nil, {})

class('BSMultiBoundAABB', 'BSMultiBoundData', {
  { 'position', 'vec3' },
  { 'extents', 'vec3' },
})

class('BSMultiBoundOBB', 'BSMultiBoundData', {
  { 'center', 'vec3' },
  { 'size', 'vec3' },
  { 'rotation', 'mat3' },
})

class('BSMultiBoundSphere', 'BSMultiBoundData', {
  { 'sphere', 'sphere' },
})

-- Its own `type` replaces the record's, as it does in jess-nif's dump.
class('BSAnimNote', nil, {
  { 'type', 'u32' },
  { 'time', 'f32' },
  { 'arm', 'u32', when = 'type == 1' },
  { 'gain', 'f32', when = 'type == 2' },
  { 'state', 'u32', when = 'type == 2' },
})

class('BSAnimNotes', nil, {
  { 'list', 'link:BSAnimNote', list = 'u16' },
})
