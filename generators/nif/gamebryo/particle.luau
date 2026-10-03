--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- OpenMW's `components/nif/particle.hpp`.

local Schema = require '../gamebryo_schema'

local class = Schema.class

class('NiParticleModifier', nil, {
  { 'next', 'link:NiParticleModifier' },
  { 'controller', 'link:NiTimeController', when = 'V >= @3.3.0.13' },
})

class('NiParticleGrowFade', 'NiParticleModifier', {
  { 'growTime', 'f32' },
  { 'fadeTime', 'f32' },
})

class('NiParticleColorModifier', 'NiParticleModifier', {
  { 'data', 'link:NiColorData' },
})

class('NiGravity', 'NiParticleModifier', {
  { 'decay', 'f32', when = 'V >= @3.3.0.13' },
  { 'force', 'f32' },
  { 'type', 'u32' },
  { 'position', 'vec3' },
  { 'direction', 'vec3' },
})

class('NiParticleBomb', 'NiParticleModifier', {
  { 'range', 'f32' },
  { 'duration', 'f32' },
  { 'strength', 'f32' },
  { 'startTime', 'f32' },
  { 'decayType', 'u32' },
  { 'symmetryType', 'u32' },
  { 'position', 'vec3' },
  { 'direction', 'vec3' },
})

class('NiParticleCollider', 'NiParticleModifier', {
  { 'bounceFactor', 'f32' },
  { 'spawnOnCollision', 'bool', when = 'V >= @4.2.0.2' },
  { 'dieOnCollision', 'bool', when = 'V >= @4.2.0.2' },
})

class('NiPlanarCollider', 'NiParticleCollider', {
  { 'extents', 'vec2' },
  { 'position', 'vec3' },
  { 'xVector', 'vec3' },
  { 'yVector', 'vec3' },
  { 'planeNormal', 'vec3' },
  { 'planeDistance', 'f32' },
})

class('NiSphericalCollider', 'NiParticleCollider', {
  { 'radius', 'f32' },
  { 'center', 'vec3' },
})

class('NiParticleRotation', 'NiParticleModifier', {
  { 'randomInitialAxis', 'u8' },
  { 'initialAxis', 'vec3' },
  { 'rotationSpeed', 'f32' },
})

-- Per-particle arrays are sized by the vertex count, which doesn't always match `numParticles`.
-- Bethesda's 20.2.0.7 files flag the arrays but never store them.
class('NiParticlesData', 'NiGeometryData', {
  { 'numParticles', 'u16', when = 'V <= VER_MW' },
  { '_bs202', expr = 'V == VER_BGS and BV ~= 0', default = 'false' },
  { '_hasRadii', 'bool', when = 'V > @10.0.1.0' },
  {
    '_numRadii',
    expr = 'if V <= @10.0.1.0 then 1 elseif _hasRadii and not _bs202 then numVertices else 0',
    default = '0',
  },
  { 'radii', 'f32', count = '_numRadii' },
  { 'activeCount', 'u16' },
  { '_hasSizes', 'bool' },
  { 'sizes', 'f32', count = 'numVertices', when = '_hasSizes and not _bs202' },
  { '_hasRotations', 'bool', when = 'V >= @10.0.1.0' },
  { 'rotations', 'quat', count = 'numVertices', when = '_hasRotations and not _bs202' },
  { '_hasAngles', 'bool', when = 'V >= @20.0.0.4' },
  { 'rotationAngles', 'f32', count = 'numVertices', when = '_hasAngles and not _bs202' },
  { '_hasAxes', 'bool', when = 'V >= @20.0.0.4' },
  { 'rotationAxes', 'vec3', count = 'numVertices', when = '_hasAxes and not _bs202' },
  { 'hasTextureIndices', 'bool', when = '_bs202' },
  { '_numOffsets', 'u8', when = '_bs202 and BV <= FO3' },
  { '_numOffsets', 'u32', when = '_bs202 and BV > FO3' },
  { 'subtextureOffsets', 'vec4', count = '_numOffsets', when = '_bs202' },
  { 'aspectRatio', 'f32', when = '_bs202 and BV > FO3', default = '1' },
  { 'aspectFlags', 'u16', when = '_bs202 and BV > FO3' },
  { 'aspectRatio2', 'f32', when = '_bs202 and BV > FO3' },
  { 'aspectSpeed', 'f32', when = '_bs202 and BV > FO3' },
  { 'aspectSpeed2', 'f32', when = '_bs202 and BV > FO3' },
})

-- Before 4.2.2.0 it may store rotations after the particle data.
class('NiRotatingParticlesData', 'NiParticlesData', {
  { '_hasOldRotations', 'bool', when = 'V <= @4.2.2.0' },
  { 'rotations', 'quat', count = 'numVertices', when = '_hasOldRotations' },
})

class('BSMasterParticleSystem', 'NiNode', {
  { 'maxEmitters', 'u16' },
  { 'particleSystems', 'links:NiAVObject' },
})

-- From Skyrim SE on it's no longer a `NiGeometry` on disk: it reads `NiAVObject`, then its own
-- bounds, the geometry's skin and shader and alpha properties, and a vertex descriptor.
class('NiParticleSystem', 'NiParticles', {
  { 'boundingSphere', 'sphere', when = 'BV >= SSE' },
  { 'boundMinMax', 'f32', fixed = 6, when = 'BV >= F76', default = 'table.create(6, 0)' },
  { 'skin', 'link:NiSkinInstance', when = 'BV >= SSE' },
  { 'shaderProperty', 'link:BSShaderProperty', when = 'BV >= SSE' },
  { 'alphaProperty', 'link:NiAlphaProperty', when = 'BV >= SSE' },
  { 'vertDesc', 'custom:vertexDesc', when = 'BV >= SSE', default = 'C.noVertexDesc()' },
  { 'nearFar', 'u16', fixed = 4, when = 'BV >= SKY', default = 'table.create(4, 0)' },
  { 'data', 'link:NiGeometryData', when = 'BV >= SSE' },
  { 'worldSpace', 'bool', when = 'V >= @10.1.0.0', default = 'true' },
  { 'modifiers', 'links:NiPSysModifier', when = 'V >= @10.1.0.0' },
}, { bases = { NiGeometry = 'BV < SSE' } })

-- Bethesda's files from Fallout 3 on don't store the particle info.
class('NiPSysData', 'NiParticlesData', {
  { 'particles', 'NiParticleInfo', count = 'numVertices', when = 'BV < FO3' },
  { skip = 12, when = 'BV > FO4' },
  { '_hasRotationSpeeds', 'bool', when = 'V >= @20.0.0.2' },
  {
    'rotationSpeeds',
    'f32',
    count = 'numVertices',
    when = '_hasRotationSpeeds and BV < FO3',
  },

  { 'numAddedParticles', 'u16', when = 'V ~= @20.2.0.7 or BV == 0' },
  { 'addedParticlesBase', 'u16', when = 'V ~= @20.2.0.7 or BV == 0' },
})

class('NiMeshPSysData', 'NiPSysData', {
  { 'defaultPoolSize', 'u32', when = 'V >= @10.2.0.0' },
  { 'fillPoolsOnLoad', 'bool', when = 'V >= @10.2.0.0' },
  { 'generations', 'u32', list = 'u32', when = 'V >= @10.2.0.0' },
  { 'particleMeshes', 'link:NiAVObject' },
})

class('BSStripPSysData', 'NiPSysData', {
  { 'maxPointCount', 'u16' },
  { 'startCapSize', 'f32' },
  { 'endCapSize', 'f32' },
  { 'doZPrepass', 'bool' },
})

class('NiPSysModifier', nil, {
  { 'name', 'string' },
  { 'order', 'u32' },
  { 'target', 'link:NiParticleSystem' },
  { 'active', 'bool' },
})

class('NiPSysAgeDeathModifier', 'NiPSysModifier', {
  { 'spawnOnDeath', 'bool' },
  { 'spawnModifier', 'link:NiPSysSpawnModifier' },
})

class('NiPSysBombModifier', 'NiPSysModifier', {
  { 'bombObject', 'link:NiAVObject' },
  { 'bombAxis', 'vec3' },
  { 'range', 'f32' },
  { 'strength', 'f32' },
  { 'decayType', 'u32' },
  { 'symmetryType', 'u32' },
})

class('NiPSysBoundUpdateModifier', 'NiPSysModifier', {
  { 'updateSkip', 'u16' },
})

class('NiPSysColorModifier', 'NiPSysModifier', {
  { 'data', 'link:NiColorData' },
})

class('NiPSysDragModifier', 'NiPSysModifier', {
  { 'dragObject', 'link:NiAVObject' },
  { 'dragAxis', 'vec3' },
  { 'percentage', 'f32' },
  { 'range', 'f32' },
  { 'rangeFalloff', 'f32' },
})

class('NiPSysGravityModifier', 'NiPSysModifier', {
  { 'gravityObject', 'link:NiAVObject' },
  { 'gravityAxis', 'vec3' },
  { 'decay', 'f32' },
  { 'strength', 'f32' },
  { 'forceType', 'u32' },
  { 'turbulence', 'f32' },
  { 'turbulenceScale', 'f32' },
  { 'worldAligned', 'bool', when = 'BV >= 17' },
})

class('NiPSysGrowFadeModifier', 'NiPSysModifier', {
  { 'growTime', 'f32' },
  { 'growGeneration', 'u16' },
  { 'fadeTime', 'f32' },
  { 'fadeGeneration', 'u16' },
  { 'baseScale', 'f32', when = 'V == VER_BGS and BV >= FO3' },
})

class('NiPSysMeshUpdateModifier', 'NiPSysModifier', {
  { 'meshes', 'links:NiAVObject' },
})

class('NiPSysRotationModifier', 'NiPSysModifier', {
  { 'rotationSpeed', 'f32' },
  { 'rotationSpeedVariation', 'f32', when = 'V >= @20.0.0.2' },
  { skip = 17, when = 'V >= @20.0.0.2 and BV > FO4' },
  { 'rotationAngle', 'f32', when = 'V >= @20.0.0.2' },
  { 'rotationAngleVariation', 'f32', when = 'V >= @20.0.0.2' },
  { 'randomRotSpeedSign', 'bool', when = 'V >= @20.0.0.2' },
  { 'randomAxis', 'bool' },
  { 'axis', 'vec3' },
})

class('NiPSysSpawnModifier', 'NiPSysModifier', {
  { 'numSpawnGenerations', 'u16' },
  { 'percentageSpawned', 'f32' },
  { 'minNumToSpawn', 'u16' },
  { 'maxNumToSpawn', 'u16' },
  { 'spawnSpeedVariation', 'f32' },
  { 'spawnDirVariation', 'f32' },
  { 'lifespan', 'f32' },
  { 'lifespanVariation', 'f32' },
})

class('BSParentVelocityModifier', 'NiPSysModifier', {
  { 'damping', 'f32' },
})

class('BSPSysHavokUpdateModifier', 'NiPSysMeshUpdateModifier', {
  { 'modifier', 'link:NiPSysModifier' },
})

-- `velcoityVariation` keeps OpenMW's spelling.
class('BSPSysInheritVelocityModifier', 'NiPSysModifier', {
  { 'inheritObject', 'link:NiAVObject' },
  { 'inheritChance', 'f32' },
  { 'velocityMult', 'f32' },
  { 'velcoityVariation', 'f32' },
})

class('BSPSysLODModifier', 'NiPSysModifier', {
  { 'lodStartDistance', 'f32' },
  { 'lodEndDistance', 'f32' },
  { 'endEmitScale', 'f32' },
  { 'endSize', 'f32' },
})

class('BSPSysRecycleBoundModifier', 'NiPSysModifier', {
  { 'boundOffset', 'vec3' },
  { 'boundExtents', 'vec3' },
  { 'boundObject', 'link:NiAVObject' },
})

class('BSPSysScaleModifier', 'NiPSysModifier', {
  { 'scales', 'f32', list = 'u32' },
})

class('BSPSysSimpleColorModifier', 'NiPSysModifier', {
  { 'fadeInPercent', 'f32' },
  { 'fadeOutPercent', 'f32' },
  { 'color1EndPercent', 'f32' },
  { 'color1StartPercent', 'f32' },
  { 'color2EndPercent', 'f32' },
  { 'color2StartPercent', 'f32' },
  { 'colors', 'vec4', fixed = 3 },
  { skip = 52, when = 'BV >= F76' },
})

class('BSPSysStripUpdateModifier', 'NiPSysModifier', {
  { 'updateDeltaTime', 'f32' },
})

class('BSPSysSubTexModifier', 'NiPSysModifier', {
  { 'startFrame', 'f32' },
  { 'startFrameFudge', 'f32' },
  { 'endFrame', 'f32' },
  { 'loopStartFrame', 'f32' },
  { 'loopStartFrameFudge', 'f32' },
  { 'frameCount', 'f32' },
  { 'frameCountFudge', 'f32' },
})

class('BSWindModifier', 'NiPSysModifier', {
  { 'strength', 'f32' },
})

class('NiPSysEmitter', 'NiPSysModifier', {
  { 'speed', 'f32' },
  { 'speedVariation', 'f32' },
  { 'declination', 'f32' },
  { 'declinationVariation', 'f32' },
  { 'planarAngle', 'f32' },
  { 'planarAngleVariation', 'f32' },
  { 'initialColor', 'vec4' },
  { 'initialRadius', 'f32' },
  { 'radiusVariation', 'f32', when = 'V >= @10.4.0.1' },
  { 'lifespan', 'f32' },
  { 'lifespanVariation', 'f32' },
})

class('NiPSysVolumeEmitter', 'NiPSysEmitter', {
  { 'emitterObject', 'link:NiAVObject', when = 'V >= @10.1.0.0' },
})

class('NiPSysBoxEmitter', 'NiPSysVolumeEmitter', {
  { 'width', 'f32' },
  { 'height', 'f32' },
  { 'depth', 'f32' },
})

class('NiPSysCylinderEmitter', 'NiPSysVolumeEmitter', {
  { 'radius', 'f32' },
  { 'height', 'f32' },
})

class('NiPSysMeshEmitter', 'NiPSysEmitter', {
  { 'emitterMeshes', 'links:NiAVObject' },
  { 'initialVelocityType', 'u32' },
  { 'emissionType', 'u32' },
  { 'emissionAxis', 'vec3' },
})

class('NiPSysSphereEmitter', 'NiPSysVolumeEmitter', {
  { 'radius', 'f32' },
})

class('NiPSysModifierCtlr', 'NiSingleInterpController', {
  { 'modifierName', 'string' },
})

-- Until 10.1.0.103 it has data, after it a visibility interpolator.
class('NiPSysEmitterCtlr', 'NiPSysModifierCtlr', {
  { 'data', 'link:NiPSysEmitterCtlrData', when = 'V <= @10.1.0.103' },
  { 'visInterpolator', 'link:NiInterpolator', when = 'V > @10.1.0.103' },
})

class('BSPSysMultiTargetEmitterCtlr', 'NiPSysEmitterCtlr', {
  { 'maxEmitters', 'u16' },
  { 'masterPSys', 'link:BSMasterParticleSystem' },
})

class('NiPSysEmitterCtlrData', nil, {
  { 'floatKeyList', 'custom:floatKeys' },
  { 'visKeyList', 'custom:emitterVisKeys' },
})

class('NiPSysCollider', nil, {
  { 'bounce', 'f32' },
  { 'collideSpawn', 'bool' },
  { 'collideDie', 'bool' },
  { 'spawnModifier', 'link:NiPSysSpawnModifier' },
  { 'parent', 'link:NiPSysColliderManager' },
  { 'nextCollider', 'link:NiPSysCollider' },
  { 'colliderObject', 'link:NiAVObject' },
})

class('NiPSysColliderManager', 'NiPSysModifier', {
  { 'collider', 'link:NiPSysCollider' },
})

class('NiPSysPlanarCollider', 'NiPSysCollider', {
  { 'width', 'f32' },
  { 'height', 'f32' },
  { 'xAxis', 'vec3' },
  { 'yAxis', 'vec3' },
})

class('NiPSysSphericalCollider', 'NiPSysCollider', {
  { 'radius', 'f32' },
})

class('NiPSysModifierBoolCtlr', 'NiPSysModifierCtlr', {
  { 'data', 'link:NiVisData', when = 'V <= @10.1.0.103' },
})

class('NiPSysModifierFloatCtlr', 'NiPSysModifierCtlr', {
  { 'data', 'link:NiFloatData', when = 'V <= @10.1.0.103' },
})
