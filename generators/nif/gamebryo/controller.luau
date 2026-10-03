--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- OpenMW's `components/nif/controller.hpp`.

local Schema = require '../gamebryo_schema'

local class, struct, same = Schema.class, Schema.struct, Schema.same

--[[
Links read as `custom:ptr` are checked by the class's `post`, where OpenMW's order puts them
after links the schema can't check itself.
]]

struct('NiQuatTransform', {
  { 'translation', 'vec3' },
  { 'rotation', 'quat' },
  { 'scale', 'f32', default = '1' },
  -- Before 10.1.0.110 each part is followed by whether it's used; unused parts are identity.
  { ret = 'V >= @10.1.0.110' },
  { '_hasTranslation', 'bool' },
  { 'translation', expr = 'if _hasTranslation then translation else vector.zero' },
  { '_hasRotation', 'bool' },
  { 'rotation', expr = 'if _hasRotation then rotation else { 0, 0, 0, 1 }' },
  { '_hasScale', 'bool' },
  { 'scale', expr = 'if _hasScale then scale else 1' },
})

-- Before 10.2.0.0 and after 20.1.0.0 the names are strings; in between, offsets into the palette.
struct('ControlledBlock', {
  { 'targetName', 'sstring', when = 'V <= @10.1.0.103' },
  { 'interpolator', 'link:NiInterpolator', when = 'V >= @10.1.0.106' },
  { 'controller', 'link:NiTimeController', when = 'V <= @20.5.0.0' },
  { ret = 'V <= @10.1.0.103' },
  { 'blendInterpolator', 'link:NiBlendInterpolator', when = 'V <= @10.1.0.110' },
  { 'blendIndex', 'u16', when = 'V <= @10.1.0.110' },
  { 'priority', 'u8', when = 'V >= @10.1.0.106 and BV > 0' },
  { '_offsets', expr = 'V >= @10.2.0.0 and V <= @20.1.0.0', default = 'false' },
  { 'stringPalette', 'link:NiStringPalette', when = '_offsets' },
  { 'nodeNameOffset', 'u32', when = '_offsets' },
  { 'propertyTypeOffset', 'u32', when = '_offsets' },
  { 'controllerTypeOffset', 'u32', when = '_offsets' },
  { 'controllerIdOffset', 'u32', when = '_offsets' },
  { 'interpolatorIdOffset', 'u32', when = '_offsets' },
  { 'nodeName', 'string', when = 'not _offsets' },
  { 'propertyType', 'string', when = 'not _offsets' },
  { 'controllerType', 'string', when = 'not _offsets' },
  { 'controllerId', 'string', when = 'not _offsets' },
  { 'interpolatorId', 'string', when = 'not _offsets' },
})

class('NiSequence', nil, {
  { 'name', 'string' },
  { 'accumRootName', 'string', when = 'V <= @10.1.0.103' },
  { 'textKeys', 'custom:ptr', when = 'V <= @10.1.0.103', default = '-1' },
  { '_size', 'u32' },
  { 'arrayGrowBy', 'u32', when = 'V >= @10.1.0.106' },
  { 'controlledBlocks', 'ControlledBlock', count = '_size' },
}, { post = { 'sequenceLinks' } })

class('NiControllerSequence', 'NiSequence', {
  { ret = 'V <= @10.1.0.103' },
  { 'weight', 'f32', default = '1' },
  { 'textKeys', 'custom:ptr' },
  { 'extrapolationMode', 'u32', default = '4' },
  { 'frequency', 'f32', default = '1' },
  { 'phase', 'f32', when = 'V <= @10.4.0.1', default = '1' },
  { 'startTime', 'f32' },
  { 'stopTime', 'f32' },
  { 'playBackwards', 'bool', when = 'V == @10.1.0.106' },
  { 'manager', 'custom:ptr', default = '-1' },
  { 'accumRootName', 'string' },
  { '_palette', expr = 'V >= @10.1.0.113 and V <= @20.1.0.0', default = 'false' },
  { 'stringPalette', 'custom:ptr', when = '_palette', default = '-1' },
  { '_notes', 'u16', when = 'not _palette and V >= VER_BGS and BV >= 29', default = '1' },
  -- OpenMW doesn't resolve these, so they aren't checked.
  {
    'animNotesList',
    'custom:ptrs(_notes)',
    when = 'not _palette and V >= VER_BGS and BV >= 24',
    default = '{}',
  },
}, { post = { 'controllerSequenceLinks' } })

class('NiInterpController', 'NiTimeController', {
  { 'managerControlled', 'bool', when = 'V >= @10.1.0.104 and V <= @10.1.0.108' },
})

class('NiSingleInterpController', 'NiInterpController', {
  { 'interpolator', 'link:NiInterpolator', when = 'V >= @10.1.0.104' },
})

same('NiFloatInterpController', 'NiSingleInterpController')
same('NiBoolInterpController', 'NiSingleInterpController')
same('NiPoint3InterpController', 'NiSingleInterpController')

struct('NiParticleInfo', {
  { 'velocity', 'vec3' },
  { 'rotationAxis', 'vec3', when = 'V <= @10.4.0.1' },
  { 'age', 'f32' },
  { 'lifespan', 'f32' },
  { 'lastUpdate', 'f32' },
  { 'spawnGeneration', 'u16' },
  { 'code', 'u16' },
})

class('NiParticleSystemController', 'NiTimeController', {
  { 'speed', 'f32', when = 'V >= @3.3.0.13' },
  { 'speedVariation', 'f32' },
  { 'declination', 'f32' },
  { 'declinationVariation', 'f32' },
  { 'planarAngle', 'f32' },
  { 'planarAngleVariation', 'f32' },
  { 'initialNormal', 'vec3' },
  { 'initialColor', 'vec4' },
  { 'initialSize', 'f32' },
  { 'emitStartTime', 'f32' },
  { 'emitStopTime', 'f32' },
  { '_reset', 'u8', when = 'V >= @3.3.0.13' },
  { 'resetParticleSystem', expr = '_reset ~= 0', default = 'false' },
  { 'birthRate', 'f32', when = 'V >= @3.3.0.13' },
  { 'lifetime', 'f32' },
  { 'lifetimeVariation', 'f32' },
  { 'emitFlags', 'u16', when = 'V >= @3.3.0.13' },
  { 'emitterDimensions', 'vec3' },
  { 'emitter', 'link:NiAVObject' },
  { 'numSpawnGenerations', 'u16', when = 'V >= @3.3.0.13' },
  { 'percentageSpawned', 'f32', when = 'V >= @3.3.0.13' },
  { 'spawnMultiplier', 'u16', when = 'V >= @3.3.0.13' },
  { 'spawnSpeedChaos', 'f32', when = 'V >= @3.3.0.13' },
  { 'spawnDirChaos', 'f32', when = 'V >= @3.3.0.13' },
  { 'numParticles', 'u16', when = 'V >= @3.3.0.13' },
  { 'numValid', 'u16', when = 'V >= @3.3.0.13' },
  { 'particles', 'NiParticleInfo', count = 'numParticles', when = 'V >= @3.3.0.13' },
  -- The `NiEmitterModifier` link.
  { skip = 4, when = 'V >= @3.3.0.13' },
  { 'modifier', 'link:NiParticleModifier' },
  { 'collider', 'link:NiParticleModifier' },
  { 'staticTargetBound', 'u8', when = 'V >= @3.3.0.15' },
})

class('NiLightColorController', 'NiPoint3InterpController', {
  { 'mode', 'u16', when = 'V >= @10.1.0.0' },
  { 'mode', expr = 'bit32.band(bit32.rshift(flags, 4), 1)', when = 'V < @10.1.0.0' },
  { 'data', 'link:NiPosData', when = 'V <= @10.1.0.103' },
})

class('NiMaterialColorController', 'NiPoint3InterpController', {
  { 'targetColor', 'u16', when = 'V >= @10.1.0.0' },
  { 'targetColor', expr = 'bit32.band(bit32.rshift(flags, 4), 3)', when = 'V < @10.1.0.0' },
  { 'data', 'link:NiPosData', when = 'V <= @10.1.0.103' },
})

class('NiPathController', 'NiTimeController', {
  { 'pathFlags', 'u16', when = 'V >= @10.1.0.0' },
  { 'pathFlags', expr = 'bit32.rshift(flags, 4)', when = 'V < @10.1.0.0' },
  { 'bankDirection', 'i32' },
  { 'maxBankAngle', 'f32' },
  { 'smoothing', 'f32' },
  { 'followAxis', 'u16' },
  { 'pathData', 'link:NiPosData' },
  { 'percentData', 'link:NiFloatData' },
})

class('NiLookAtController', 'NiTimeController', {
  { 'lookAtFlags', 'u16', when = 'V >= @10.1.0.0' },
  { 'lookAtFlags', expr = 'bit32.band(bit32.rshift(flags, 4), 7)', when = 'V < @10.1.0.0' },
  { 'lookAt', 'link:NiAVObject' },
})

class('NiUVController', 'NiTimeController', {
  { 'uvSet', 'u16' },
  { 'data', 'link:NiUVData' },
})

class('NiKeyframeController', 'NiSingleInterpController', {
  { 'data', 'link:NiKeyframeData', when = 'V <= @10.1.0.103' },
})

class('NiMultiTargetTransformController', 'NiInterpController', {
  { 'extraTargets', 'link:NiAVObject', list = 'u16' },
})

class('NiAlphaController', 'NiFloatInterpController', {
  { 'data', 'link:NiFloatData', when = 'V <= @10.1.0.103' },
})

class('NiRollController', 'NiSingleInterpController', {
  { 'data', 'link:NiFloatData', when = 'V <= @10.1.0.103' },
})

-- After Oblivion each interpolator comes with a weight.
class('NiGeomMorpherController', 'NiInterpController', {
  { '_updateNormals', 'u16', when = 'V >= VER_OB_OLD' },
  { 'updateNormals', expr = 'bit32.btest(_updateNormals, 1)', default = 'false' },
  { 'data', 'link:NiMorphData' },
  { ret = 'V < VER_MW' },
  { '_alwaysActive', 'u8' },
  { 'alwaysActive', expr = '_alwaysActive ~= 0', default = 'false' },
  { ret = 'V <= @10.1.0.105' },
  { '_morph', 'custom:morphInterpolators' },
  { 'interpolators', expr = '_morph.interpolators', default = '{}' },
  { 'weights', expr = '_morph.weights', default = '{}' },
}, { post = { 'morphLinks' } })

class('NiVisController', 'NiBoolInterpController', {
  { 'data', 'link:NiVisData', when = 'V <= @10.1.0.103' },
})

-- Before 10.1.0.104 it rereads the controller's start time.
class('NiFlipController', 'NiFloatInterpController', {
  { 'texSlot', 'u32' },
  { 'timeStart', 'f32', when = 'V <= @10.1.0.103' },
  { 'delta', 'f32', when = 'V <= @10.1.0.103' },
  { 'sources', 'links:NiSourceTexture' },
})

class('NiTextureTransformController', 'NiFloatInterpController', {
  { 'shaderMap', 'bool' },
  { 'texSlot', 'u32' },
  { 'transformMember', 'u32' },
  { 'data', 'link:NiFloatData', when = 'V <= @10.1.0.103' },
})

-- The skinned shape groups only exist in non-Bethesda files from 4.2.2.0.
class('NiBoneLODController', 'NiTimeController', {
  { 'lod', 'u32' },
  { '_nodeGroups', 'u32' },
  { 'numNodeGroups', 'u32' },
  { 'nodeGroups', 'custom:ptrLists(_nodeGroups)', default = '{}' },
  { ret = 'BV ~= 0 or V < @4.2.2.0' },
  { 'skinnedShapeGroups', 'custom:skinInfoGroups', default = '{}' },
  { 'shapeGroups', 'custom:ptrList', default = '{}' },
}, { post = { 'boneLodLinks' } })

-- OpenMW rejects one with keys.
class('bhkBlendController', 'NiTimeController', {
  { '_numKeys', 'u32' },
  { check = '_numKeys == 0', message = 'Unsupported keys in bhkBlendController' },
})

class('BSEffectShaderPropertyFloatController', 'NiFloatInterpController', {
  { 'controlledVariable', 'u32' },
})

class('BSEffectShaderPropertyColorController', 'NiPoint3InterpController', {
  { 'controlledColor', 'u32' },
})

class('BSKeyframeController', 'NiKeyframeController', {
  { 'data2', 'link:NiKeyframeData' },
})

class('BSLagBoneController', 'NiTimeController', {
  { 'linearVelocity', 'f32' },
  { 'linearRotation', 'f32' },
  { 'maximumDistance', 'f32' },
})

class('BSProceduralLightningController', 'NiTimeController', {
  { 'generationInterp', 'link:NiInterpolator' },
  { 'mutationInterp', 'link:NiInterpolator' },
  { 'subdivisionInterp', 'link:NiInterpolator' },
  { 'numBranchesInterp', 'link:NiInterpolator' },
  { 'numBranchesVarInterp', 'link:NiInterpolator' },
  { 'lengthInterp', 'link:NiInterpolator' },
  { 'lengthVarInterp', 'link:NiInterpolator' },
  { 'widthInterp', 'link:NiInterpolator' },
  { 'arcOffsetInterp', 'link:NiInterpolator' },
  { 'subdivisions', 'u16' },
  { 'numBranches', 'u16' },
  { 'numBranchesVar', 'u16' },
  { 'length', 'f32' },
  { 'lengthVar', 'f32' },
  { 'width', 'f32' },
  { 'childWidthMult', 'f32' },
  { 'arcOffset', 'f32' },
  { 'fadeMainBolt', 'bool' },
  { 'fadeChildBolts', 'bool' },
  { 'animateArcOffset', 'bool' },
  { 'shaderProperty', 'link:BSShaderProperty' },
})

class('NiControllerManager', 'NiTimeController', {
  { 'cumulative', 'bool' },
  { 'sequences', 'links:NiControllerSequence' },
  { 'objectPalette', 'link:NiDefaultAVObjectPalette' },
})

class('NiExtraDataController', 'NiSingleInterpController', {
  { 'extraDataName', 'string', when = 'V >= @10.2.0.0' },
})

class('NiFloatExtraDataController', 'NiExtraDataController', {
  { ret = 'V >= @10.1.0.104' },
  { '_numExtraBytes', 'u8', when = 'V <= @10.1.0.0' },
  { skip = 7, when = 'V <= @10.1.0.0' },
  { skip = '_numExtraBytes', when = 'V <= @10.1.0.0' },
  { 'data', 'link:NiFloatData' },
})

class('NiFloatsExtraDataController', 'NiExtraDataController', {
  { 'floatsExtraDataIndex', 'i32' },
  { 'data', 'link:NiFloatData', when = 'V <= @10.1.0.103' },
})

class('NiFloatsExtraDataPoint3Controller', 'NiExtraDataController', {
  { 'floatsExtraDataIndex', 'i32' },
})

class('NiInterpolator', nil, {})

class('NiPathInterpolator', 'NiInterpolator', {
  { 'flags', 'u16' },
  { 'bankDirection', 'i32' },
  { 'maxBankAngle', 'f32' },
  { 'smoothing', 'f32' },
  { 'followAxis', 'u16' },
  { 'pathData', 'link:NiPosData' },
  { 'percentData', 'link:NiFloatData' },
})

class('NiLookAtInterpolator', 'NiInterpolator', {
  { 'lookAtFlags', 'u16' },
  { 'lookAt', 'link:NiAVObject' },
  { 'lookAtName', 'string' },
  { 'transform', 'NiQuatTransform', when = 'V <= @20.4.0.12' },
  { 'translation', 'link:NiInterpolator' },
  { 'roll', 'link:NiInterpolator' },
  { 'scale', 'link:NiInterpolator' },
})

struct('NiBlendInterpolatorItem', {
  { 'interpolator', 'link:NiInterpolator' },
  { 'weight', 'f32' },
  { 'normalizedWeight', 'f32' },
  { 'priority', 'i8', when = 'V >= @10.1.0.110' },
  { 'priority', 'i32', when = 'V < @10.1.0.110' },
  { 'easeSpinner', 'f32' },
})

-- The layout changed at 10.1.0.110 and again at 10.1.0.112, which moved the booleans into the
-- flags. Classes derive from it, so its layouts are conditions, not returns.
class('NiBlendInterpolator', 'NiInterpolator', {
  { 'flags', 'u8', when = 'V >= @10.1.0.112' },
  { '_numItems', 'u8', when = 'V >= @10.1.0.112' },
  { 'weightThreshold', 'f32', when = 'V >= @10.1.0.112' },
  { '_items', expr = 'V >= @10.1.0.112 and not bit32.btest(flags, 1)', default = 'false' },
  { 'interpCount', 'u8', when = '_items' },
  { 'singleIndex', 'u8', when = '_items' },
  { 'highPriority', 'i8', when = '_items' },
  { 'nextHighPriority', 'i8', when = '_items' },
  { 'singleTime', 'f32', when = '_items' },
  { 'highWeightsSum', 'f32', when = '_items' },
  { 'nextHighWeightsSum', 'f32', when = '_items' },
  { 'highEaseSpinner', 'f32', when = '_items' },
  { 'items', 'NiBlendInterpolatorItem', count = '_numItems', when = '_items' },
  { '_numItems', 'u8', when = 'V >= @10.1.0.110 and V < @10.1.0.112' },
  { '_numItems', 'u16', when = 'V < @10.1.0.110' },
  { 'arrayGrowBy', 'u16', when = 'V < @10.1.0.110' },
  { 'items', 'NiBlendInterpolatorItem', count = '_numItems', when = 'V < @10.1.0.112' },
  { '_managerControlled', 'bool', when = 'V < @10.1.0.112' },
  { 'weightThreshold', 'f32', when = 'V < @10.1.0.112' },
  { '_onlyHighestWeight', 'bool', when = 'V < @10.1.0.112' },
  {
    'flags',
    expr = '(if _managerControlled then 1 else 0) + (if _onlyHighestWeight then 2 else 0)',
    when = 'V < @10.1.0.112',
  },
  { 'interpCount', 'u8', when = 'V >= @10.1.0.110 and V < @10.1.0.112' },
  { 'singleIndex', 'u8', when = 'V >= @10.1.0.110 and V < @10.1.0.112' },
  { 'interpCount', 'u16', when = 'V < @10.1.0.110' },
  { 'singleIndex', 'u16', when = 'V < @10.1.0.110' },
  {
    'singleInterpolator',
    'custom:ptr',
    when = 'V >= @10.1.0.108 and V < @10.1.0.112',
    default = '-1',
  },
  { 'singleTime', 'f32', when = 'V >= @10.1.0.108 and V < @10.1.0.112' },
  { 'highPriority', 'i8', when = 'V >= @10.1.0.110 and V < @10.1.0.112' },
  { 'nextHighPriority', 'i8', when = 'V >= @10.1.0.110 and V < @10.1.0.112' },
  { 'highPriority', 'i32', when = 'V < @10.1.0.110' },
  { 'nextHighPriority', 'i32', when = 'V < @10.1.0.110' },
}, { post = { 'blendLinks' } })

class('NiBlendBoolInterpolator', 'NiBlendInterpolator', {
  { 'value', 'u8' },
})

class('NiBlendFloatInterpolator', 'NiBlendInterpolator', {
  { 'value', 'f32' },
})

class('NiBlendPoint3Interpolator', 'NiBlendInterpolator', {
  { 'value', 'vec3' },
})

class('NiBlendTransformInterpolator', 'NiBlendInterpolator', {
  { 'value', 'NiQuatTransform', when = 'V <= @10.1.0.109' },
})

class('NiBSplineInterpolator', 'NiInterpolator', {
  { 'startTime', 'f32' },
  { 'stopTime', 'f32' },
  { 'splineData', 'link:NiBSplineData' },
  { 'basisData', 'link:NiBSplineBasisData' },
})

class('NiBSplineFloatInterpolator', 'NiBSplineInterpolator', {
  { 'value', 'f32' },
  { 'handle', 'u32' },
})

class('NiBSplineCompFloatInterpolator', 'NiBSplineFloatInterpolator', {
  { 'offset', 'f32' },
  { 'halfRange', 'f32' },
})

class('NiBSplinePoint3Interpolator', 'NiBSplineInterpolator', {
  { 'value', 'vec3' },
  { 'handle', 'u32' },
})

class('NiBSplineCompPoint3Interpolator', 'NiBSplinePoint3Interpolator', {
  { 'offset', 'f32' },
  { 'halfRange', 'f32' },
})

class('NiBSplineTransformInterpolator', 'NiBSplineInterpolator', {
  { 'value', 'NiQuatTransform' },
  { 'translationHandle', 'u32' },
  { 'rotationHandle', 'u32' },
  { 'scaleHandle', 'u32' },
})

class('NiBSplineCompTransformInterpolator', 'NiBSplineTransformInterpolator', {
  { 'translationOffset', 'f32' },
  { 'translationHalfRange', 'f32' },
  { 'rotationOffset', 'f32' },
  { 'rotationHalfRange', 'f32' },
  { 'scaleOffset', 'f32' },
  { 'scaleHalfRange', 'f32' },
})

struct('BSTreadTransform', {
  { 'name', 'string' },
  { 'transform1', 'NiQuatTransform' },
  { 'transform2', 'NiQuatTransform' },
})

class('BSTreadTransfInterpolator', 'NiInterpolator', {
  { 'transforms', 'BSTreadTransform', list = 'u32' },
  { 'data', 'link:NiFloatData' },
})

class('NiPoint3Interpolator', 'NiInterpolator', {
  { 'defaultValue', 'vec3' },
  { 'data', 'link:NiPosData' },
})

class('NiBoolInterpolator', 'NiInterpolator', {
  { 'defaultValue', 'bool' },
  { 'data', 'link:NiBoolData' },
})

class('NiFloatInterpolator', 'NiInterpolator', {
  { 'defaultValue', 'f32' },
  { 'data', 'link:NiFloatData' },
})

class('NiTransformInterpolator', 'NiInterpolator', {
  { 'defaultValue', 'NiQuatTransform' },
  { 'data', 'link:NiKeyframeData' },
})

class('NiColorInterpolator', 'NiInterpolator', {
  { 'defaultValue', 'vec4' },
  { 'data', 'link:NiColorData' },
})
