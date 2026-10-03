--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- OpenMW's `components/nif/extra.hpp`.

local Schema = require '../gamebryo_schema'

local class, struct = Schema.class, Schema.struct

class('NiExtraData', 'Extra', {
  { 'data', 'u8', count = 'recordSize' },
})

class('NiStringsExtraData', 'Extra', {
  { 'data', 'custom:sizedStrings' },
})

class('NiVertWeightsExtraData', 'Extra', {
  { '_count', 'u16' },
  { skip = '_count * 4' },
})

struct('NiTextKeyExtraDataTextKey', {
  { 'time', 'f32' },
  { 'text', 'string' },
})

class('NiTextKeyExtraData', 'Extra', {
  { 'list', 'NiTextKeyExtraDataTextKey', list = 'u32' },
})

class('BSBound', 'Extra', {
  { 'center', 'vec3' },
  { 'extents', 'vec3' },
})

struct('BSFurnitureMarkerLegacyFurniturePosition', {
  { 'offset', 'vec3' },
  { 'orientation', 'u16' },
  { 'positionRef', 'u8' },
  { skip = 1 },
})

struct('BSFurnitureMarkerFurniturePosition', {
  { 'offset', 'vec3' },
  { 'heading', 'f32' },
  { 'type', 'u16' },
  { 'entryPoint', 'u16' },
})

class('BSFurnitureMarker', 'Extra', {
  { 'legacyMarkers', 'BSFurnitureMarkerLegacyFurniturePosition', list = 'u32', when = 'BV <= FO3' },
  { 'markers', 'BSFurnitureMarkerFurniturePosition', list = 'u32', when = 'BV > FO3' },
})

class('BSInvMarker', 'Extra', {
  { 'rotation', 'custom:invMarkerRotation' },
  { 'scale', 'f32' },
})

class('BSBehaviorGraphExtraData', 'Extra', {
  { 'file', 'string' },
  { 'controlsBaseSkeleton', 'bool' },
})

struct('BSBoneLODExtraDataBoneLOD', {
  { 'distance', 'u32' },
  { 'bone', 'string' },
})

class('BSBoneLODExtraData', 'Extra', {
  { 'data', 'BSBoneLODExtraDataBoneLOD', list = 'u32' },
})

struct('BSDecalPlacementVectorExtraDataBlock', {
  { '_count', 'u16' },
  { 'points', 'vec3', count = '_count' },
  { 'normals', 'vec3', count = '_count' },
})

class('BSDecalPlacementVectorExtraData', 'NiFloatExtraData', {
  { 'blocks', 'BSDecalPlacementVectorExtraDataBlock', list = 'u16' },
})

class('BSExtraData', 'NiExtraData', {}, { bare = true })

class('BSClothExtraData', 'BSExtraData', {
  { 'data', 'u8', list = 'u32' },
})

class('BSCollisionQueryProxyExtraData', 'BSExtraData', {
  { 'data', 'u8', list = 'u32' },
})

struct('BSConnectPointTransform', {
  { 'rotation', 'quat' },
  { 'translation', 'vec3' },
  { 'scale', 'f32' },
}, { doc = '`NiQuatTransform` as `BSConnectPoint::Point` stores it: rotation first.' })

struct('BSConnectPointPoint', {
  { 'parent', 'sstring' },
  { 'name', 'sstring' },
  { 'transform', 'BSConnectPointTransform' },
})

class('BSConnectPointParents', 'NiExtraData', {
  { 'points', 'BSConnectPointPoint', list = 'u32' },
})

class('BSConnectPointChildren', 'NiExtraData', {
  { 'skinned', 'bool' },
  { 'pointNames', 'custom:sizedStrings' },
})

struct('NiTransform', {
  { 'rotation', 'mat3' },
  { 'translation', 'vec3' },
  { 'scale', 'f32' },
}, { min = 52, doc = '`NiTransform` as it is stored: rotation first.' })

struct('BSPackedGeomDataCombined', {
  { 'grayscaleToPaletteScale', 'f32' },
  { 'transform', 'NiTransform' },
  { 'boundingSphere', 'sphere' },
})

struct('BSPackedGeomObject', {
  { 'fileHash', 'u32' },
  { 'dataOffset', 'u32' },
})

struct('BSPackedSharedGeomData', {
  { 'numVertices', 'u32' },
  { 'lodLevels', 'u32' },
  { 'lod0TriCount', 'u32' },
  { 'lod0TriOffset', 'u32' },
  { 'lod1TriCount', 'u32' },
  { 'lod1TriOffset', 'u32' },
  { 'lod2TriCount', 'u32' },
  { 'lod2TriOffset', 'u32' },
  { 'combined', 'BSPackedGeomDataCombined', list = 'u32' },
  { 'vertexDesc', 'custom:vertexDesc' },
})

class('BSPackedCombinedSharedGeomDataExtra', 'NiExtraData', {
  { 'vertexDesc', 'custom:vertexDesc' },
  { 'numVertices', 'u32' },
  { 'numTriangles', 'u32' },
  { 'flags1', 'u32' },
  { 'flags2', 'u32' },
  { 'objects', 'BSPackedGeomObject', list = 'u32' },
  { 'objectData', 'BSPackedSharedGeomData', count = '#objects' },
})

-- `TypedExtra<T>`: one value.
class('NiBooleanExtraData', 'Extra', { { 'data', 'bool' } })
class('NiFloatExtraData', 'Extra', { { 'data', 'f32' } })
class('NiIntegerExtraData', 'Extra', { { 'data', 'u32' } })
class('NiStringExtraData', 'Extra', { { 'data', 'string' } })
class('NiVectorExtraData', 'Extra', { { 'data', 'vec4' } })

-- `TypedVectorExtra<T>`: a `u32` count, then values.
class('NiBinaryExtraData', 'Extra', { { 'data', 'u8', list = 'u32' } })
class('NiFloatsExtraData', 'Extra', { { 'data', 'f32', list = 'u32' } })
class('NiIntegersExtraData', 'Extra', { { 'data', 'u32', list = 'u32' } })
class('BSPositionData', 'Extra', { { 'data', 'f16', list = 'u32' } })
class('BSWArray', 'Extra', { { 'data', 'i32', list = 'u32' } })
