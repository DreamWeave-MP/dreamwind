--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- OpenMW's `components/nif/node.hpp`.

local Schema = require '../gamebryo_schema'

local class, struct, same = Schema.class, Schema.struct, Schema.same

struct('AVTransform', {
  { 'translation', 'vec3' },
  { 'rotation', 'mat3' },
  { 'scale', 'f32', default = '1' },
}, { doc = '`NiTransform` as `NiAVObject` reads it: translation first.' })

same('NiSequenceStreamHelper', 'NiObjectNET')

class('NiAVObject', 'NiObjectNET', {
  { 'flags', 'u16', when = 'BV <= 26' },
  { 'flags', 'u32', when = 'BV > 26' },
  { 'transform', 'AVTransform' },
  { 'velocity', 'vec3', when = 'V <= @4.2.2.0' },
  { 'properties', 'links:NiProperty', when = 'BV <= FO3' },
  { '_hasBounds', 'bool', when = 'V <= @4.2.2.0' },
  { 'bounds', 'custom:boundingVolume', when = '_hasBounds', default = 'C.noBounds()' },
  { 'collision', 'link:NiCollisionObject', when = 'V >= @10.0.1.0' },
})

class('NiNode', 'NiAVObject', {
  { 'children', 'links:NiAVObject' },
  { 'effects', 'links:NiAVObject', when = 'BV < FO4' },
})

struct('NiGeometryMaterialData', {
  { ret = 'V < @10.0.1.0' },
  { '_count', 'u32', when = 'V >= @20.2.0.5' },
  { '_flag', 'bool', when = 'V < @20.2.0.5 and V <= @20.1.0.3' },
  { '_count', expr = 'if _flag then 1 else _count' },
  { 'names', 'string', count = '_count' },
  { 'extra', 'i32', count = '_count' },
  { 'active', 'i32', when = 'V >= @20.2.0.5', default = '-1' },
  { 'needsUpdate', 'bool', when = 'V >= VER_BGS' },
})

class('NiGeometry', 'NiAVObject', {
  { 'data', 'link:NiGeometryData' },
  { 'skin', 'link:NiSkinInstance', when = 'V >= @3.3.0.13' },
  { 'material', 'NiGeometryMaterialData' },
  { 'shaderProperty', 'link:BSShaderProperty', when = 'V == VER_BGS and BV > FO3' },
  { 'alphaProperty', 'link:NiAlphaProperty', when = 'V == VER_BGS and BV > FO3' },
})

same('NiTriBasedGeom', 'NiGeometry')
same('NiTriShape', 'NiTriBasedGeom')

struct('BSSegmentedTriShapeSegmentData', {
  { 'flags', 'u8' },
  { 'startIndex', 'u32' },
  { 'numTriangles', 'u32' },
})

class('BSSegmentedTriShape', 'NiTriShape', {
  { 'segments', 'BSSegmentedTriShapeSegmentData', list = 'u32' },
})

same('NiTriStrips', 'NiTriBasedGeom')
same('NiLines', 'NiTriBasedGeom')
same('NiParticles', 'NiGeometry')

class('BSLODTriShape', 'NiTriShape', {
  { 'lod', 'u32', fixed = 3 },
})

class('NiCamera', 'NiAVObject', {
  { 'cameraFlags', 'u16', when = 'V >= @10.1.0.0' },
  { 'left', 'f32' },
  { 'right', 'f32' },
  { 'top', 'f32' },
  { 'bottom', 'f32' },
  { 'nearDist', 'f32' },
  { 'farDist', 'f32' },
  { 'orthographic', 'bool', when = 'V >= @10.1.0.0' },
  { 'vLeft', 'f32' },
  { 'vRight', 'f32' },
  { 'vTop', 'f32' },
  { 'vBottom', 'f32' },
  { 'lodAdjust', 'f32' },
  { 'scene', 'link:NiAVObject' },
  { skip = 4 },
  { skip = 4, when = 'V >= @4.2.1.0' },
})

class('NiSwitchNode', 'NiNode', {
  { 'switchFlags', 'u16', when = 'V >= @10.1.0.0' },
  { 'initialIndex', 'u32' },
})

struct('NiLODNodeLODRange', {
  { 'minRange', 'f32' },
  { 'maxRange', 'f32' },
})

class('NiLODNode', 'NiSwitchNode', {
  { skip = 4, when = 'V > @10.0.1.0' },
  { ret = 'V > @10.0.1.0' },
  { 'lodCenter', 'vec3', when = 'V >= VER_MW' },
  { 'lodLevels', 'NiLODNodeLODRange', list = 'u32' },
})

class('NiFltAnimationNode', 'NiSwitchNode', {
  { 'duration', 'f32' },
})

class('NiAccumulator', nil, {})
same('NiClusterAccumulator', 'NiAccumulator')
same('NiAlphaAccumulator', 'NiClusterAccumulator')

class('NiSortAdjustNode', 'NiNode', {
  { 'mode', 'u32' },
  { 'subSorter', 'link:NiAccumulator', when = 'V <= @20.0.0.3' },
})

class('NiBillboardNode', 'NiNode', {
  { 'mode', 'u16', when = 'V >= @10.1.0.0' },
  {
    'mode',
    expr = 'if V >= @10.1.0.0 then bit32.band(mode, 7) else bit32.band(bit32.rshift(flags, 5), 3)',
  },
})

class('NiDefaultAVObjectPalette', nil, {
  { 'scene', 'link:NiAVObject' },
  { 'objects', 'custom:avObjectPalette' },
}, { post = { 'paletteLinks' } })

class('BSTreeNode', 'NiNode', {
  { 'bones1', 'links:NiAVObject' },
  { 'bones2', 'links:NiAVObject' },
})

class('BSMultiBoundNode', 'NiNode', {
  { 'multiBound', 'link:BSMultiBound' },
  { 'cullingType', 'u32', when = 'BV >= SKY' },
})

class('BSTriShape', 'NiAVObject', {
  { 'boundingSphere', 'sphere' },
  { 'boundMinMax', 'f32', fixed = 6, when = 'BV >= F76', default = 'table.create(6, 0)' },
  { 'skin', 'link:any' },
  { 'shaderProperty', 'link:BSShaderProperty' },
  { 'alphaProperty', 'link:NiAlphaProperty' },
  { 'vertDesc', 'custom:vertexDesc' },
  { '_triangleIndices', 'u32', when = 'BV >= FO4' },
  { '_triangleIndices16', 'u16', when = 'BV < FO4' },
  -- Multiplied in 32 bits, as in OpenMW.
  {
    '_triangleIndices',
    expr = 'if BV >= FO4 then (_triangleIndices * 3) % 4294967296 else _triangleIndices16 * 3',
  },
  { 'numVertices', 'u16' },
  { 'dataSize', 'u32' },
  { 'vertData', 'custom:vertexData(numVertices, vertDesc.flags)', when = 'dataSize > 0' },
  { 'triangles', 'u16', count = '_triangleIndices', when = 'dataSize > 0' },
  { 'particleDataSize', 'u32', when = 'BV == SSE' },
  {
    'particleVerts',
    'f16',
    count = 'numVertices * 3',
    when = 'BV == SSE and particleDataSize > 0',
  },

  {
    'particleNormals',
    'f16',
    count = 'numVertices * 3',
    when = 'BV == SSE and particleDataSize > 0',
  },

  {
    'particleTriangles',
    'u16',
    count = '_triangleIndices',
    when = 'BV == SSE and particleDataSize > 0',
  },
})

class('BSDynamicTriShape', 'BSTriShape', {
  { 'dynamicDataSize', 'u32' },
  -- nifly's reading: one vector per vertex, whatever the size says.
  { 'dynamicData', 'vec4', count = 'numVertices' },
})

class('BSMeshLODTriShape', 'BSTriShape', {
  { 'lod', 'u32', fixed = 3 },
})

struct('BSSubIndexTriShapeSubSegment', {
  { 'startIndex', 'u32' },
  { 'numPrimitives', 'u32' },
  { 'arrayIndex', 'u32' },
  { skip = 4 },
})

struct('BSSubIndexTriShapeSegment', {
  { 'startIndex', 'u32' },
  { 'numPrimitives', 'u32' },
  { 'parentArrayIndex', 'u32' },
  { 'subSegments', 'BSSubIndexTriShapeSubSegment', list = 'u32' },
})

struct('BSSubIndexTriShapeSubSegmentDataRecord', {
  { 'userSlotId', 'u32' },
  { 'material', 'u32' },
  { 'extraData', 'f32', list = 'u32' },
})

struct('BSSubIndexTriShapeSubSegmentData', {
  { '_arrayIndices', 'u32' },
  { '_records', 'u32' },
  { 'arrayIndices', 'u32', count = '_arrayIndices' },
  { 'dataRecords', 'BSSubIndexTriShapeSubSegmentDataRecord', count = '_records' },
  { 'ssfFile', 'custom:sizedU16' },
})

struct('BSSubIndexTriShapeSegmentation', {
  { 'numPrimitives', 'u32' },
  { '_segments', 'u32' },
  { 'numTotalSegments', 'u32' },
  { 'segments', 'BSSubIndexTriShapeSegment', count = '_segments' },
  { 'subSegmentData', 'BSSubIndexTriShapeSubSegmentData', when = '_segments < numTotalSegments' },
})

class('BSSubIndexTriShape', 'BSTriShape', {
  { 'segments', 'BSSegmentedTriShapeSegmentData', list = 'u32', when = 'BV == SSE' },
  {
    'segmentation',
    'BSSubIndexTriShapeSegmentation',
    when = 'BV ~= SSE and BV >= FO4 and dataSize > 0',
  },
})

class('BSValueNode', 'NiNode', {
  { 'value', 'u32' },
  { 'valueFlags', 'u8' },
})

class('BSOrderedNode', 'NiNode', {
  { 'alphaSortBound', 'vec4' },
  { 'staticBound', 'bool' },
})

class('BSRangeNode', 'NiNode', {
  { 'min', 'u8' },
  { 'max', 'u8' },
  { 'current', 'u8' },
})

struct('BSResourceID', {
  { 'fileHash', 'u32' },
  { 'extension', 'u8', fixed = 4 },
  { 'directoryHash', 'u32' },
})

struct('BSDistantObjectInstance', {
  { 'resourceId', 'BSResourceID' },
  { '_unknown', 'u32' },
  -- Multiplied in 32 bits, as in OpenMW.
  { skip = '(_unknown * 12) % 4294967296' },
  { 'transforms', 'custom:f32Rows(16)' },
})

struct('BSShaderTextureArray', {
  { skip = 1 },
  { 'textureArrays', 'custom:stringLists' },
})

class('BSDistantObjectInstancedNode', 'BSMultiBoundNode', {
  { 'instances', 'BSDistantObjectInstance', list = 'u32' },
  { 'shaderTextureArrays', 'BSShaderTextureArray', fixed = 3 },
})
