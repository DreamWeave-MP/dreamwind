--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- OpenMW's `components/nif/property.hpp`.

local Schema = require '../gamebryo_schema'

local class, struct, same = Schema.class, Schema.struct, Schema.same

same('NiProperty', 'NiObjectNET')

struct('NiTextureTransform', {
  { 'offset', 'vec2' },
  { 'scale', 'vec2' },
  { 'rotation', 'f32' },
  { 'transformMethod', 'u32' },
  { 'origin', 'vec2' },
})

struct('NiTexturingPropertyTexture', {
  { 'enabled', 'bool' },
  { ret = 'not enabled' },
  { 'sourceTexture', 'link:NiSourceTexture', when = 'V >= @3.3.0.13' },
  { 'clamp', 'u32', when = 'V <= VER_OB' },
  { 'filter', 'u32', when = 'V <= VER_OB' },
  { '_flags', 'u16', when = 'V > VER_OB' },
  { 'clamp', expr = 'bit32.band(_flags, 15)', when = 'V > VER_OB' },
  { 'filter', expr = 'bit32.extract(_flags, 4, 4)', when = 'V > VER_OB' },
  { 'maxAnisotropy', 'u16', when = 'V >= @20.5.0.4' },
  { 'uvSet', 'u32', when = 'V <= VER_OB' },
  -- PS2 filtering settings, then an unknown short.
  { skip = 4, when = 'V <= @10.4.0.1' },
  { skip = 2, when = 'V <= @4.1.0.12' },
  { 'hasTransform', 'bool', when = 'V >= @10.1.0.0' },
  { 'transform', 'NiTextureTransform', when = 'hasTransform' },
})

class('NiTexturingProperty', 'NiProperty', {
  { 'flags', 'u16', when = 'V <= VER_OB_OLD or V >= @20.1.0.2' },
  { 'applyMode', 'u32', when = 'V <= @20.1.0.1', default = '2' },
  { '_maps', 'custom:texturingMaps(R.NiTexturingPropertyTexture)' },
  { 'textures', expr = '_maps.textures', default = '{}' },
  { 'shaderTextures', expr = '_maps.shaderTextures', default = '{}' },
  { 'shaderIds', expr = '_maps.shaderIds', default = '{}' },
  { 'envMapLumaBias', expr = '_maps.envMapLumaBias', default = 'vector.zero' },
  { 'bumpMapMatrix', expr = '_maps.bumpMapMatrix', default = '{ 0, 0, 0, 0 }' },
  { 'parallaxOffset', expr = '_maps.parallaxOffset', default = '0' },
}, { post = { 'texturingLinks' } })

class('NiShadeProperty', 'NiProperty', {
  { 'flags', 'u16', when = 'BV <= FO3' },
})

struct('BSSPParallaxParams', {
  { 'maxPasses', 'f32', default = '4' },
  { 'scale', 'f32', default = '1' },
})

struct('BSSPRefractionParams', {
  { 'strength', 'f32' },
  { 'period', 'i32' },
})

-- `type` replaces the record's name in the record, as it does in jess-nif's dump.
class('BSShaderProperty', 'NiShadeProperty', {
  { 'type', 'u32', when = 'UV <= 11' },
  { 'shaderFlags1', 'u32', when = 'UV <= 11' },
  { 'shaderFlags2', 'u32', when = 'UV <= 11' },
  { 'envMapScale', 'f32', when = 'UV <= 11' },
  -- OpenMW returns after the fields above, and for a named Fallout 76 shader, here.
  { '_shader', expr = 'UV > 11 and not (name ~= \'\' and BV >= F76)', default = 'false' },
  { 'shaderFlags1', 'u32', when = '_shader and BV <= 131' },
  { 'shaderFlags2', 'u32', when = '_shader and BV <= 131' },
  -- Fallout 76's shader types, remapped to Fallout 4's.
  {
    'type',
    'u32',
    when = '_shader and BV > 131 and BV >= F76 and RN == \'BSLightingShaderProperty\'',
  },

  {
    'type',
    expr = '({ [3] = 4, [4] = 5, [5] = 6, [12] = 16, [17] = 21 })[type] or type',
    when = '_shader and BV > 131 and BV >= F76 and RN == \'BSLightingShaderProperty\'',
  },
  { '_flags1', 'u32', when = '_shader and BV > 131' },
  { '_flags2', 'u32', when = '_shader and BV >= 152' },
  { 'shaderFlags1Hashes', 'u32', count = '_flags1', when = '_shader and BV > 131' },
  { 'shaderFlags2Hashes', 'u32', count = '_flags2', when = '_shader and BV > 131' },
  { 'uvOffset', 'vec2', when = '_shader' },
  { 'uvScale', 'vec2', when = '_shader' },
})

class('BSShaderLightingProperty', 'BSShaderProperty', {
  { 'clamp', 'u32', when = 'UV <= 11', default = '3' },
})

class('BSShaderPPLightingProperty', 'BSShaderLightingProperty', {
  { 'textureSet', 'link:BSShaderTextureSet' },
  { 'refraction', 'BSSPRefractionParams', when = 'UV == 11 and BV >= 15' },
  { 'parallax', 'BSSPParallaxParams', when = 'UV == 11 and BV >= 25' },
  { 'emissiveColor', 'vec4', when = 'UV >= 12' },
})

class('BSShaderNoLightingProperty', 'BSShaderLightingProperty', {
  { 'filename', 'sstring' },
  { 'falloffParams', 'vec4', when = 'BV >= 27' },
})

class('SkyShaderProperty', 'BSShaderLightingProperty', {
  { 'filename', 'sstring' },
  { 'skyObjectType', 'u32' },
})

class('TallGrassShaderProperty', 'BSShaderProperty', {
  { 'filename', 'sstring' },
})

class('TileShaderProperty', 'BSShaderLightingProperty', {
  { 'filename', 'sstring' },
})

struct('BSSPLuminanceParams', {
  { 'lumEmittance', 'f32' },
  { 'exposureOffset', 'f32' },
  { 'finalExposureMin', 'f32' },
  { 'finalExposureMax', 'f32' },
})

struct('BSSPWetnessParams', {
  { 'specScale', 'f32' },
  { 'specPower', 'f32' },
  { 'minVar', 'f32' },
  { 'envMapScale', 'f32', when = 'BV == FO4' },
  { 'fresnelPower', 'f32' },
  { 'metalness', 'f32' },
  { skip = 4, when = 'BV > FO4' },
  { skip = 4, when = 'BV >= F76' },
})

struct('BSSPMLParallaxParams', {
  { 'innerLayerThickness', 'f32' },
  { 'refractionScale', 'f32' },
  { 'innerLayerTextureScale', 'vec2' },
  { 'envMapScale', 'f32' },
})

struct('BSSPTranslucencyParams', {
  { 'subsurfaceColor', 'vec3' },
  { 'transmissiveScale', 'f32' },
  { 'turbulence', 'f32' },
  { 'thickObject', 'bool' },
  { 'mixAlbedo', 'bool' },
})

class('BSLightingShaderProperty', 'BSShaderProperty', {
  { ret = 'name ~= \'\' and BV >= F76' },
  { 'textureSet', 'link:BSShaderTextureSet' },
  { 'emissive', 'vec3' },
  { 'emissiveMult', 'f32', default = '1' },
  { 'rootMaterial', 'string', when = 'BV >= FO4' },
  { skip = 4, when = 'BV >= STF' },
  { 'clamp', 'u32', default = '3' },
  { 'alpha', 'f32', default = '1' },
  { 'refractionStrength', 'f32' },
  { 'glossiness', 'f32', when = 'BV < FO4', default = '80' },
  { 'smoothness', 'f32', when = 'BV >= FO4', default = '1' },
  { 'specular', 'vec3' },
  { 'specStrength', 'f32', default = '1' },
  { 'lightingEffects', 'f32', fixed = 2, when = 'BV < FO4', default = '{ 0, 0 }' },
  { 'subsurfaceRolloff', 'f32', when = 'BV >= FO4 and BV <= 139' },
  { 'rimlightPower', 'f32', when = 'BV >= FO4 and BV <= 139' },
  -- `f32::MAX`.
  {
    'backlightPower',
    'f32',
    when = 'BV >= FO4 and BV <= 139 and rimlightPower == 3.4028234663852886e38',
  },
  { 'grayscaleToPaletteScale', 'f32', when = 'BV >= FO4', default = '1' },
  { 'fresnelPower', 'f32', when = 'BV >= FO4', default = '5' },
  { 'wetness', 'BSSPWetnessParams', when = 'BV >= FO4' },
  { 'luminance', 'BSSPLuminanceParams', when = 'BV >= F76' },
  { 'doTranslucency', 'bool', when = 'BV == F76' },
  { 'translucency', 'BSSPTranslucencyParams', when = 'BV == F76 and doTranslucency' },
  { '_hasTextureArrays', 'u8', when = 'BV == F76' },
  {
    'textureArrays',
    'custom:stringLists',
    when = 'BV == F76 and _hasTextureArrays ~= 0',
    default = '{}',
  },
  { skip = 4, when = 'BV >= STF' },
  { skip = 4, when = 'BV >= STF' },
  { skip = 2, when = 'BV >= STF' },
  -- By shader type: environment map, skin tint, hair tint, parallax occlusion, multi-layer
  -- parallax, sparkle snow, eye environment map.
  { 'envMapScale', 'f32', when = 'type == 1 and BV <= 139' },
  { 'useSsr', 'bool', when = 'type == 1 and BV >= FO4' },
  { 'wetnessUseSsr', 'bool', when = 'type == 1 and BV >= FO4' },
  { 'skinTintColor', 'vec3', when = 'type == 5' },
  { 'skinTintAlpha', 'f32', when = 'type == 5 and BV >= FO4', default = '1' },
  { 'hairTintColor', 'vec3', when = 'type == 6' },
  { 'parallax', 'BSSPParallaxParams', when = 'type == 7' },
  { 'multiLayerParallax', 'BSSPMLParallaxParams', when = 'type == 11' },
  { 'sparkle', 'vec4', when = 'type == 14' },
  { 'cubeMapScale', 'f32', when = 'type == 16' },
  { 'leftEyeReflectionCenter', 'vec3', when = 'type == 16' },
  { 'rightEyeReflectionCenter', 'vec3', when = 'type == 16' },
}, { first = { { 'type', 'u32', when = 'BV < F76' } } })

class('BSEffectShaderProperty', 'BSShaderProperty', {
  -- Its own `envMapScale` replaces the base's in the record, read or not.
  { 'envMapScale', expr = '0' },
  { ret = 'name ~= \'\' and BV >= F76' },
  { 'sourceTexture', 'sstring' },
  { skip = 4, when = 'BV >= STF' },
  { '_packed', 'u32' },
  { 'clamp', expr = 'bit32.extract(_packed, 0, 8)', default = '0' },
  { 'lightingInfluence', expr = 'bit32.extract(_packed, 8, 8)', default = '0' },
  { 'envMapMinLod', expr = 'bit32.extract(_packed, 16, 8)', default = '0' },
  { 'falloffParams', 'vec4' },
  { 'refractionPower', 'f32', when = 'BV == F76' },
  { 'baseColor', 'vec4' },
  { 'baseColorScale', 'f32' },
  { 'falloffDepth', 'f32' },
  { 'greyscaleTexture', 'sstring' },
  { 'envMapTexture', 'sstring', when = 'BV >= FO4' },
  { 'normalTexture', 'sstring', when = 'BV >= FO4' },
  { 'envMaskTexture', 'sstring', when = 'BV >= FO4' },
  { 'envMapScale', 'f32', when = 'BV >= FO4' },
  { 'reflectanceTexture', 'sstring', when = 'BV >= F76' },
  { 'lightingTexture', 'sstring', when = 'BV >= F76' },
  { 'emittanceColor', 'vec3', when = 'BV >= F76' },
  { 'emitGradientTexture', 'sstring', when = 'BV >= F76' },
  { 'luminance', 'BSSPLuminanceParams', when = 'BV >= F76' },
  { skip = 7, when = 'BV >= STF' },
  { skip = 24, when = 'BV >= STF' },
  { skip = 1, when = 'BV >= STF' },
})

class('BSSkyShaderProperty', 'BSShaderProperty', {
  { 'filename', 'sstring' },
  { 'skyObjectType', 'u32' },
})

-- Its `flags` replace `NiShadeProperty`'s in the record.
class('BSWaterShaderProperty', 'BSShaderProperty', {
  { 'flags', 'u32' },
})

class('NiAlphaProperty', 'NiProperty', {
  { 'flags', 'u16' },
  { 'threshold', 'u8' },
})

class('NiDitherProperty', 'NiProperty', {
  { 'flags', 'u16' },
})

class('NiFogProperty', 'NiProperty', {
  { 'flags', 'u16' },
  { 'fogDepth', 'f32' },
  { 'colour', 'vec3' },
})

class('NiMaterialProperty', 'NiProperty', {
  { 'flags', 'u16', when = 'V <= VER_OB_OLD' },
  { 'ambient', 'vec3', when = 'BV < 26', default = 'vector.one' },
  { 'diffuse', 'vec3', when = 'BV < 26', default = 'vector.one' },
  { 'specular', 'vec3' },
  { 'emissive', 'vec3' },
  { 'glossiness', 'f32' },
  { 'alpha', 'f32' },
  { 'emissiveMult', 'f32', when = 'BV >= 22', default = '1' },
})

class('NiSpecularProperty', 'NiProperty', {
  { '_flags', 'u16' },
  { 'enable', expr = 'bit32.btest(_flags, 1)', default = 'false' },
})

class('NiStencilProperty', 'NiProperty', {
  { 'flags', 'u16', when = 'V <= VER_OB_OLD' },
  { '_enabled', 'u8', when = 'V <= VER_OB' },
  { 'enabled', expr = '_enabled ~= 0', when = 'V <= VER_OB', default = 'false' },
  { 'testFunction', 'u32', when = 'V <= VER_OB' },
  { 'stencilRef', 'u32', when = 'V <= VER_OB' },
  { 'stencilMask', 'u32', when = 'V <= VER_OB' },
  { 'failAction', 'u32', when = 'V <= VER_OB' },
  { 'zFailAction', 'u32', when = 'V <= VER_OB' },
  { 'passAction', 'u32', when = 'V <= VER_OB' },
  { 'drawMode', 'u32', when = 'V <= VER_OB' },
  { 'flags', 'u16', when = 'V > VER_OB' },
  { 'enabled', expr = 'bit32.btest(flags, 1)', when = 'V > VER_OB' },
  { 'failAction', expr = 'bit32.extract(flags, 1, 3)', when = 'V > VER_OB' },
  { 'zFailAction', expr = 'bit32.extract(flags, 4, 3)', when = 'V > VER_OB' },
  { 'passAction', expr = 'bit32.extract(flags, 7, 3)', when = 'V > VER_OB' },
  { 'drawMode', expr = 'bit32.extract(flags, 10, 2)', when = 'V > VER_OB' },
  { 'testFunction', expr = 'bit32.extract(flags, 12, 3)', when = 'V > VER_OB' },
  { 'stencilRef', 'u32', when = 'V > VER_OB' },
  { 'stencilMask', 'u32', when = 'V > VER_OB' },
})

class('NiVertexColorProperty', 'NiProperty', {
  { 'flags', 'u16' },
  { 'vertexMode', 'u32', when = 'V <= VER_OB' },
  { 'lightingMode', 'u32', when = 'V <= VER_OB' },
  { 'vertexMode', expr = 'bit32.extract(flags, 4, 2)', when = 'V > VER_OB' },
  { 'lightingMode', expr = 'bit32.extract(flags, 3, 1)', when = 'V > VER_OB' },
})

class('NiWireframeProperty', 'NiProperty', {
  { '_flags', 'u16' },
  { 'enable', expr = 'bit32.btest(_flags, 1)', default = 'false' },
})

class('NiZBufferProperty', 'NiProperty', {
  { 'flags', 'u16' },
  { 'testFunction', 'u32', when = 'V >= @4.1.0.12 and V <= VER_OB' },
  {
    'testFunction',
    expr = 'bit32.extract(flags, 2, 3)',
    when = 'not (V >= @4.1.0.12 and V <= VER_OB)',
  },
})
