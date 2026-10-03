--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- OpenMW's `components/nif/physics.hpp`: Bethesda's Havok physics records.

local Schema = require '../gamebryo_schema'

local class, struct, same = Schema.class, Schema.struct, Schema.same

type Step = Schema.Step

--[[
Links OpenMW never resolves are read as `custom:ptr` and `custom:ptrList`; links inside a struct
are checked by the class's `post`.
]]

struct('bhkWorldObjCInfoProperty', {
  { 'data', 'u32' },
  { 'size', 'u32' },
  { 'capacityAndFlags', 'u32' },
})

struct('bhkWorldObjectCInfo', {
  { skip = 4 },
  { 'phaseType', 'u8' },
  { skip = 3 },
  { 'property', 'bhkWorldObjCInfoProperty' },
})

struct('HavokMaterial', {
  { skip = 4, when = 'V <= VER_OB_OLD' },
  { 'material', 'u32' },
})

struct('HavokFilter', {
  { 'layer', 'u8' },
  { 'flags', 'u8' },
  { 'group', 'u16' },
}, { min = 4 })

struct('hkSubPartData', {
  { 'havokFilter', 'HavokFilter' },
  { 'numVertices', 'u32' },
  { 'havokMaterial', 'HavokMaterial' },
})

struct('bhkEntityCInfo', {
  { 'responseType', 'u8' },
  { skip = 1 },
  { 'processContactDelay', 'u16' },
})

struct('hkpMoppCode', {
  { '_dataSize', 'u32' },
  { 'offset', 'vec4', when = 'V >= @10.1.0.0' },
  { 'buildType', 'u8', when = 'BV > FO3' },
  { 'data', 'u8', count = '_dataSize' },
})

struct('bhkMeshMaterial', {
  { 'havokMaterial', 'HavokMaterial' },
  { 'havokFilter', 'HavokFilter' },
})

struct('bhkQsTransform', {
  { 'translation', 'vec4' },
  { 'rotation', 'quat' },
})

struct('bhkCMSBigTri', {
  { 'triangle', 'u16', fixed = 3 },
  { 'material', 'u32' },
  { 'weldingInfo', 'u16' },
})

struct('bhkCMSChunk', {
  { 'translation', 'vec4' },
  { 'materialIndex', 'u32' },
  { 'reference', 'u16' },
  { 'transformIndex', 'u16' },
  { 'vertices', 'u16', list = 'u32' },
  { 'indices', 'u16', list = 'u32' },
  { 'strips', 'u16', list = 'u32' },
  { 'weldingInfos', 'u16', list = 'u32' },
})

-- From Skyrim on (83) the layout changes; Fallout 4 moves some fields after the solver.
struct('bhkRigidBodyCInfo', {
  { skip = 4, when = 'V >= @10.1.0.0' },
  { 'havokFilter', 'HavokFilter', when = 'V >= @10.1.0.0' },
  { skip = 4, when = 'V >= @10.1.0.0' },
  { skip = 4, when = 'V >= @10.1.0.0 and BV ~= FO4 and BV >= 83' },
  { 'responseType', 'u8', when = 'V >= @10.1.0.0 and BV ~= FO4' },
  { skip = 1, when = 'V >= @10.1.0.0 and BV ~= FO4' },
  { 'processContactDelay', 'u16', when = 'V >= @10.1.0.0 and BV ~= FO4' },
  { skip = 4, when = 'BV < 83' },
  { 'translation', 'vec4' },
  { 'rotation', 'quat' },
  { 'linearVelocity', 'vec4' },
  { 'angularVelocity', 'vec4' },
  -- The only 3x3 matrix with padding.
  { '_row1', 'vec3' },
  { skip = 4 },
  { '_row2', 'vec3' },
  { skip = 4 },
  { '_row3', 'vec3' },
  { skip = 4 },
  { 'inertiaTensor', expr = '{ _row1, _row2, _row3 }', default = 'G.identity()' },
  { 'center', 'vec4' },
  { 'mass', 'f32' },
  { 'linearDamping', 'f32' },
  { 'angularDamping', 'f32' },
  { 'timeFactor', 'f32', when = 'BV >= 83 and BV ~= FO4', default = '1' },
  { 'gravityFactor', 'f32', when = 'BV >= 83', default = '1' },
  { 'friction', 'f32' },
  { 'rollingFrictionMult', 'f32', when = 'BV >= 83' },
  { 'restitution', 'f32' },
  { 'maxLinearVelocity', 'f32', when = 'V >= @10.1.0.0' },
  { 'maxAngularVelocity', 'f32', when = 'V >= @10.1.0.0' },
  { 'penetrationDepth', 'f32', when = 'V >= @10.1.0.0 and BV ~= FO4' },
  { 'motionType', 'u8' },
  { 'deactivatorType', 'u8', when = 'BV < 83' },
  { 'enableDeactivation', 'bool', when = 'BV >= 83', default = 'true' },
  { 'solverDeactivation', 'u8' },
  { skip = 1, when = 'BV == FO4' },
  { 'penetrationDepth', 'f32', when = 'BV == FO4' },
  { 'timeFactor', 'f32', when = 'BV == FO4' },
  { skip = 4, when = 'BV == FO4' },
  { 'responseType', 'u8', when = 'BV == FO4' },
  { skip = 1, when = 'BV == FO4' },
  { 'processContactDelay', 'u16', when = 'BV == FO4' },
  { 'qualityType', 'u8' },
  { 'autoRemoveLevel', 'u8', when = 'BV >= 83' },
  { 'responseModifierFlags', 'u8', when = 'BV >= 83' },
  { 'numContactPointShapeKeys', 'u8', when = 'BV >= 83' },
  { 'forceCollidedOntoPpu', 'bool', when = 'BV >= 83' },
  { skip = 3, when = 'BV == FO4' },
  { skip = 12, when = 'BV ~= FO4' },
})

struct('bhkConstraintCInfo', {
  { '_numEntities', 'u32' },
  { 'entityA', 'custom:ptr', default = '-1' },
  { 'entityB', 'custom:ptr', default = '-1' },
  { 'priority', 'u32' },
})

struct('bhkPositionConstraintMotor', {
  { 'minForce', 'f32' },
  { 'maxForce', 'f32' },
  { 'tau', 'f32' },
  { 'damping', 'f32' },
  { 'proportionalRecoveryVelocity', 'f32' },
  { 'constantRecoveryVelocity', 'f32' },
  { 'enabled', 'bool' },
})

struct('bhkVelocityConstraintMotor', {
  { 'minForce', 'f32' },
  { 'maxForce', 'f32' },
  { 'tau', 'f32' },
  { 'targetVelocity', 'f32' },
  { 'useVelocityTarget', 'bool' },
  { 'enabled', 'bool' },
})

struct('bhkSpringDamperConstraintMotor', {
  { 'minForce', 'f32' },
  { 'maxForce', 'f32' },
  { 'springConstant', 'f32' },
  { 'springDamping', 'f32' },
  { 'enabled', 'bool' },
})

struct('bhkConstraintMotorCInfo', {
  { 'type', 'u8' },
  { 'positionMotor', 'bhkPositionConstraintMotor', when = 'type == 1' },
  { 'velocityMotor', 'bhkVelocityConstraintMotor', when = 'type == 2' },
  { 'springDamperMotor', 'bhkSpringDamperConstraintMotor', when = 'type == 3' },
})

struct('bhkRagdollConstraintCInfoData', {
  { 'pivot', 'vec4' },
  { 'plane', 'vec4' },
  { 'twist', 'vec4' },
  { 'motor', 'vec4' },
})

--- Two of `data`'s structs, which the steps after them fill field by field.
local function pair(data: string): { Step }
  return {
    -- Copies of the shared default, since the steps after these assign into them.
    { 'dataA', expr = `table.clone(D.{data}())`, default = `D.{data}()` },
    { 'dataB', expr = `table.clone(D.{data}())`, default = `D.{data}()` },
  }
end

--- `fields` of `data` in this order, for each of `targets`, when `when` holds.
local function each(targets: { string }, fields: { string }, when: string): { Step }
  local steps: { Step } = {}
  for _, target in targets do
    for _, field in fields do
      table.insert(steps, { `{target}.{field}`, 'vec4', when = when })
    end
  end

  return steps
end

--- Concatenates step lists.
local function steps(...: { Step }): { Step }
  local list: { Step } = {}
  for _, part in { ... } do
    table.move(part, 1, #part, #list + 1, list)
  end

  return list
end

struct(
  'bhkRagdollConstraintCInfo',
  steps(
    pair 'bhkRagdollConstraintCInfoData',
    each({ 'dataA', 'dataB' }, { 'pivot', 'plane', 'twist' }, 'BV <= 16'),
    each({ 'dataA', 'dataB' }, { 'twist', 'plane', 'motor', 'pivot' }, 'BV > 16'),
    {
      { 'coneMaxAngle', 'f32' },
      { 'planeMinAngle', 'f32' },
      { 'planeMaxAngle', 'f32' },
      { 'twistMinAngle', 'f32' },
      { 'twistMaxAngle', 'f32' },
      { 'maxFriction', 'f32' },
      { 'motor', 'bhkConstraintMotorCInfo', when = 'V >= VER_BGS and BV > 16' },
    }
  )
)

struct('bhkHingeConstraintCInfoHingeData', {
  { 'pivot', 'vec4' },
  { 'axis', 'vec4' },
  { 'perpAxis1', 'vec4' },
  { 'perpAxis2', 'vec4' },
})

local AxesThenPivot = { 'axis', 'perpAxis1', 'perpAxis2', 'pivot' }

struct(
  'bhkHingeConstraintCInfo',
  steps(
    pair 'bhkHingeConstraintCInfoHingeData',
    each({ 'dataA' }, { 'pivot', 'perpAxis1', 'perpAxis2' }, 'V <= VER_OB'),
    each({ 'dataB' }, { 'pivot', 'axis' }, 'V <= VER_OB'),
    each({ 'dataA', 'dataB' }, AxesThenPivot, 'V > VER_OB')
  )
)

struct(
  'bhkLimitedHingeConstraintCInfo',
  steps(
    pair 'bhkHingeConstraintCInfoHingeData',
    each({ 'dataA' }, { 'pivot', 'axis', 'perpAxis1', 'perpAxis2' }, 'BV <= 16'),
    each({ 'dataB' }, { 'pivot', 'axis', 'perpAxis2' }, 'BV <= 16'),
    each({ 'dataA', 'dataB' }, AxesThenPivot, 'BV > 16'),
    {
      { 'minAngle', 'f32' },
      { 'maxAngle', 'f32' },
      { 'maxFriction', 'f32' },
      { 'motor', 'bhkConstraintMotorCInfo', when = 'V >= VER_BGS and BV > 16' },
    }
  )
)

struct('bhkBallAndSocketConstraintCInfo', {
  { 'pivotA', 'vec4' },
  { 'pivotB', 'vec4' },
})

struct('bhkStiffSpringConstraintCInfo', {
  { 'pivotA', 'vec4' },
  { 'pivotB', 'vec4' },
  { 'length', 'f32' },
})

struct('bhkPrismaticConstraintCInfoData', {
  { 'sliding', 'vec4' },
  { 'rotation', 'vec4' },
  { 'plane', 'vec4' },
  { 'pivot', 'vec4' },
})

struct(
  'bhkPrismaticConstraintCInfo',
  steps(
    pair 'bhkPrismaticConstraintCInfoData',
    each({ 'dataA' }, { 'pivot', 'rotation', 'plane', 'sliding' }, 'V <= VER_OB'),
    each({ 'dataB' }, { 'sliding', 'pivot', 'rotation', 'plane' }, 'V <= VER_OB'),
    each({ 'dataA', 'dataB' }, { 'sliding', 'rotation', 'plane', 'pivot' }, 'V > VER_OB'),
    {
      { 'minDistance', 'f32' },
      { 'maxDistance', 'f32' },
      { 'friction', 'f32' },
      { 'motor', 'bhkConstraintMotorCInfo', when = 'V >= VER_BGS and BV >= 17' },
    }
  )
)

--- `bhkWrappedConstraintDataBase::read_common`: the type, the common info, and the info for the
--- type, if it's one of the plain constraint types, which `_plain` says.
local function wrapped(): { Step }
  return {
    { 'type', 'u32' },
    { 'info', 'bhkConstraintCInfo' },
    { 'ballAndSocketInfo', 'bhkBallAndSocketConstraintCInfo', when = 'type == 0' },
    { 'hingeInfo', 'bhkHingeConstraintCInfo', when = 'type == 1' },
    { 'limitedHingeInfo', 'bhkLimitedHingeConstraintCInfo', when = 'type == 2' },
    { 'prismaticInfo', 'bhkPrismaticConstraintCInfo', when = 'type == 6' },
    { 'ragdollInfo', 'bhkRagdollConstraintCInfo', when = 'type == 7' },
    { 'stiffSpringInfo', 'bhkStiffSpringConstraintCInfo', when = 'type == 8' },
    {
      '_plain',
      expr = 'type == 0 or type == 1 or type == 2 or type == 6 or type == 7 or type == 8',
      default = 'false',
    },
  }
end

struct(
  'bhkMalleableConstraintCInfo',
  steps(wrapped(), {
    { check = '_plain', message = 'Unrecognized constraint type in bhkMalleableConstraint' },
    { 'tau', 'f32', when = 'V <= VER_OB' },
    { 'damping', 'f32', when = 'V <= VER_OB' },
    { 'strength', 'f32', when = 'V > VER_OB' },
  })
)

struct(
  'bhkWrappedConstraintData',
  steps(wrapped(), {
    {
      check = '_plain or type == 13',
      message = 'Unrecognized constraint type in bhkWrappedConstraintData',
    },

    { 'malleableInfo', 'bhkMalleableConstraintCInfo', when = 'not _plain' },
  })
)

struct('bhkConstraintChainCInfo', {
  { 'entities', 'custom:ptrList', default = '{}' },
  { 'info', 'bhkConstraintCInfo' },
})

-- Records.

class('bhkRefObject', nil, {})
same('bhkSerializable', 'bhkRefObject')
same('bhkShape', 'bhkSerializable')
same('bhkShapeCollection', 'bhkShape')
class('bhkSystem', nil, {})

class('NiCollisionObject', nil, {
  { 'target', 'link:NiAVObject' },
})

class('bhkCollisionObject', 'NiCollisionObject', {
  { 'flags', 'u16' },
  { 'body', 'link:bhkWorldObject' },
})

class('bhkNPCollisionObject', 'NiCollisionObject', {
  { 'flags', 'u16' },
  { 'data', 'link:bhkSystem' },
  { 'bodyId', 'u32' },
})

class('bhkBlendCollisionObject', 'bhkCollisionObject', {
  { 'heirGain', 'f32' },
  { 'velGain', 'f32' },
  { skip = 8, when = 'BV <= 8' },
})

class('bhkPhysicsSystem', 'bhkSystem', {
  { 'data', 'u8', list = 'u32' },
})

class('bhkRagdollSystem', 'bhkSystem', {
  { 'data', 'u8', list = 'u32' },
})

class('bhkWorldObject', 'bhkSerializable', {
  { 'shape', 'link:bhkShape' },
  { skip = 4, when = 'V <= VER_OB_OLD' },
  { 'havokFilter', 'HavokFilter' },
  { 'worldObjectInfo', 'bhkWorldObjectCInfo' },
})

class('bhkEntity', 'bhkWorldObject', {
  { 'info', 'bhkEntityCInfo' },
})

class('bhkBvTreeShape', 'bhkShape', {
  { 'shape', 'link:bhkShape' },
})

class('bhkMoppBvTreeShape', 'bhkBvTreeShape', {
  { skip = 12 },
  { 'scale', 'f32' },
  { 'mopp', 'hkpMoppCode' },
})

class('bhkNiTriStripsShape', 'bhkShape', {
  { 'havokMaterial', 'HavokMaterial' },
  { 'radius', 'f32' },
  { skip = 20 },
  { 'growBy', 'u32' },
  { 'scale', 'vec4', when = 'V >= @10.1.0.0', default = '{ 1, 1, 1, 0 }' },
  { 'data', 'links:NiTriStripsData' },
  { 'havokFilters', 'HavokFilter', list = 'u32' },
})

class('bhkPackedNiTriStripsShape', 'bhkShapeCollection', {
  { 'subshapes', 'hkSubPartData', list = 'u16', when = 'V <= VER_OB' },
  { 'userData', 'u32' },
  { skip = 4 },
  { 'radius', 'f32' },
  { skip = 4 },
  { 'scale', 'vec4' },
  -- Duplicates of the two previous fields.
  { skip = 20 },
  { 'data', 'link:hkPackedNiTriStripsData' },
})

-- Compressed (half-precision) vertices are skipped, as OpenMW doesn't support them.
class('hkPackedNiTriStripsData', 'bhkShapeCollection', {
  { 'triangles', 'custom:packedTriangles', default = '{}' },
  { '_numVertices', 'u32' },
  { '_compressed', 'bool', when = 'V >= VER_BGS' },
  { 'vertices', 'vec3', count = '_numVertices', when = 'not _compressed' },
  { skip = '_numVertices * 6', when = '_compressed' },
  { 'subshapes', 'hkSubPartData', list = 'u16', when = 'V >= VER_BGS' },
})

class('bhkSphereRepShape', 'bhkShape', {
  { 'havokMaterial', 'HavokMaterial' },
})

class('bhkConvexShape', 'bhkSphereRepShape', {
  { 'radius', 'f32' },
})

class('bhkConvexListShape', 'bhkShape', {
  { 'subShapes', 'links:bhkShape' },
  { 'material', 'HavokMaterial' },
  { 'radius', 'f32' },
  { skip = 8 },
  { 'childShapeProperty', 'bhkWorldObjCInfoProperty' },
  { 'useCachedAabb', 'bool' },
  { 'closestPointMinDistance', 'f32' },
})

class('bhkConvexSweepShape', 'bhkShape', {
  { 'shape', 'link:bhkConvexShape' },
  { 'material', 'HavokMaterial' },
  { 'radius', 'f32' },
  { skip = 12 },
})

class('bhkConvexVerticesShape', 'bhkConvexShape', {
  { 'verticesProperty', 'bhkWorldObjCInfoProperty' },
  { 'normalsProperty', 'bhkWorldObjCInfoProperty' },
  { 'vertices', 'vec4', list = 'u32' },
  { 'normals', 'vec4', list = 'u32' },
})

class('bhkConvexTransformShape', 'bhkShape', {
  { 'shape', 'link:bhkShape' },
  { 'havokMaterial', 'HavokMaterial' },
  { 'radius', 'f32' },
  { skip = 8 },
  { 'transform', 'f32', fixed = 16 },
})

class('bhkBoxShape', 'bhkConvexShape', {
  { skip = 8 },
  { 'extents', 'vec3' },
  { skip = 4 },
})

class('bhkCapsuleShape', 'bhkConvexShape', {
  { skip = 8 },
  { 'point1', 'vec3' },
  { 'radius1', 'f32' },
  { 'point2', 'vec3' },
  { 'radius2', 'f32' },
})

class('bhkCylinderShape', 'bhkConvexShape', {
  { skip = 8 },
  { 'vertexA', 'vec4' },
  { 'vertexB', 'vec4' },
  { 'cylinderRadius', 'f32' },
  { skip = 12 },
})

class('bhkHeightfieldShape', 'bhkShape', {
  { 'havokMaterial', 'HavokMaterial' },
})

class('bhkPlaneShape', 'bhkHeightfieldShape', {
  { skip = 12 },
  { 'plane', 'vec4' },
  { 'extents', 'vec4' },
  { 'center', 'vec4' },
})

class('bhkMeshShape', 'bhkShape', {
  { skip = 8 },
  { 'radius', 'f32' },
  { skip = 8 },
  { 'scale', 'vec4' },
  { 'shapeProperties', 'bhkWorldObjCInfoProperty', list = 'u32' },
  { skip = 12 },
  { 'dataList', 'links:NiTriStripsData' },
})

class('bhkMultiSphereShape', 'bhkSphereRepShape', {
  { 'shapeProperty', 'bhkWorldObjCInfoProperty' },
  { 'spheres', 'sphere', list = 'u32' },
})

class('bhkListShape', 'bhkShapeCollection', {
  { 'subshapes', 'links:bhkShape' },
  { 'havokMaterial', 'HavokMaterial' },
  { 'childShapeProperty', 'bhkWorldObjCInfoProperty' },
  { 'childFilterProperty', 'bhkWorldObjCInfoProperty' },
  { 'havokFilters', 'HavokFilter', list = 'u32' },
})

class('bhkCompressedMeshShape', 'bhkShape', {
  { 'target', 'link:NiAVObject' },
  { 'userData', 'u32' },
  { 'radius', 'f32' },
  { skip = 4 },
  { 'scale', 'vec4' },
  -- The radius and scale again.
  { skip = 20 },
  { 'data', 'link:bhkCompressedMeshShapeData' },
})

class('bhkCompressedMeshShapeData', 'bhkRefObject', {
  { 'bitsPerIndex', 'u32' },
  { 'bitsPerWIndex', 'u32' },
  { 'maskWIndex', 'u32' },
  { 'maskIndex', 'u32' },
  { 'error', 'f32' },
  { 'aabbMin', 'vec4' },
  { 'aabbMax', 'vec4' },
  { 'weldingType', 'u8' },
  { 'materialType', 'u8' },
  { '_unused', 'u32' },
  { skip = '_unused * 4' },
  { '_unused', 'u32' },
  { skip = '_unused * 4' },
  { '_unused', 'u32' },
  { skip = '_unused * 4' },
  { 'materials', 'bhkMeshMaterial', list = 'u32' },
  { skip = 4 },
  { 'chunkTransforms', 'bhkQsTransform', list = 'u32' },
  { 'bigVerts', 'vec4', list = 'u32' },
  { 'bigTris', 'bhkCMSBigTri', list = 'u32' },
  { 'chunks', 'bhkCMSChunk', list = 'u32' },
  { skip = 4 },
})

class('bhkRigidBody', 'bhkEntity', {
  { 'info', 'bhkRigidBodyCInfo' },
  { 'constraints', 'custom:ptrList', default = '{}' },
  { 'bodyFlags', 'u32', when = 'BV < 76' },
  { 'bodyFlags', 'u16', when = 'BV >= 76' },
})

same('bhkPhantom', 'bhkWorldObject')

class('bhkAabbPhantom', 'bhkPhantom', {
  { skip = 8 },
  { 'aabbMin', 'vec4' },
  { 'aabbMax', 'vec4' },
})

same('bhkShapePhantom', 'bhkPhantom')

class('bhkSimpleShapePhantom', 'bhkShapePhantom', {
  { skip = 8 },
  { 'transform', 'f32', fixed = 16 },
})

class('bhkConstraint', 'bhkSerializable', {
  { 'info', 'bhkConstraintCInfo' },
}, { post = { 'constraintLinks' } })

-- Each constraint record: a `bhkConstraint`, then one constraint info.
local Constraints: { [string]: string } = {
  bhkRagdollConstraint = 'bhkRagdollConstraintCInfo',
  bhkHingeConstraint = 'bhkHingeConstraintCInfo',
  bhkLimitedHingeConstraint = 'bhkLimitedHingeConstraintCInfo',
  bhkBallAndSocketConstraint = 'bhkBallAndSocketConstraintCInfo',
  bhkStiffSpringConstraint = 'bhkStiffSpringConstraintCInfo',
  bhkPrismaticConstraint = 'bhkPrismaticConstraintCInfo',
  bhkMalleableConstraint = 'bhkMalleableConstraintCInfo',
}

for name, info in Constraints do
  class(name, 'bhkConstraint', { { 'constraint', info } })
end

class('bhkBallSocketConstraintChain', 'bhkSerializable', {
  { '_numPivots', 'u32' },
  {
    check = '_numPivots % 2 == 0',
    message = 'Invalid number of constraints in bhkBallSocketConstraintChain',
  },

  { 'constraints', 'bhkBallAndSocketConstraintCInfo', count = '_numPivots // 2' },
  { 'tau', 'f32' },
  { 'damping', 'f32' },
  { 'constraintForceMixing', 'f32' },
  { 'maxErrorDistance', 'f32' },
  { 'constraintChainInfo', 'bhkConstraintChainCInfo' },
}, { post = { 'constraintChainLinks' } })

class('bhkBreakableConstraint', 'bhkConstraint', {
  { 'constraint', 'bhkWrappedConstraintData' },
  { 'threshold', 'f32' },
  { 'removeWhenBroken', 'bool' },
})

same('bhkAction', 'bhkSerializable')

class('bhkUnaryAction', 'bhkAction', {
  { 'entity', 'link:bhkRigidBody' },
  { skip = 8 },
})

class('bhkLiquidAction', 'bhkAction', {
  { skip = 12 },
  { 'initialStickForce', 'f32' },
  { 'stickStrength', 'f32' },
  { 'neighborDistance', 'f32' },
  { 'neighborStrength', 'f32' },
})

class('bhkOrientHingedBodyAction', 'bhkUnaryAction', {
  { skip = 8 },
  { 'hingeAxisLs', 'vec4' },
  { 'forwardLs', 'vec4' },
  { 'strength', 'f32' },
  { 'damping', 'f32' },
  { skip = 8 },
})

class('bhkRagdollTemplate', 'Extra', {
  { 'bones', 'links:bhkRagdollTemplateData' },
})

class('bhkRagdollTemplateData', nil, {
  { 'name', 'string' },
  { 'mass', 'f32' },
  { 'restitution', 'f32' },
  { 'friction', 'f32' },
  { 'radius', 'f32' },
  { 'havokMaterial', 'HavokMaterial' },
  { 'constraints', 'bhkWrappedConstraintData', list = 'u32' },
})

class('bhkPoseArray', nil, {
  { 'bones', 'string', list = 'u32' },
  { 'poses', 'custom:poses', default = '{}' },
})
