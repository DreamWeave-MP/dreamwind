--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- OpenMW's `components/nif/effect.hpp`.

local Schema = require '../gamebryo_schema'

local class = Schema.class

class('NiDynamicEffect', 'NiAVObject', {
  -- Between Morrowind and 10.1.0.0, and from Fallout 4 on, an effect has no data of its own.
  { '_effect', expr = 'not (V > VER_MW and V < @10.1.0.0) and BV < FO4', default = 'false' },
  { 'switchState', 'bool', when = '_effect and V >= @10.1.0.106', default = 'true' },
  { '_affectedNodes', 'u32', when = '_effect' },
  { skip = '_affectedNodes * 4', when = '_effect' },
})

class('NiLight', 'NiDynamicEffect', {
  { 'dimmer', 'f32' },
  { 'ambient', 'vec3' },
  { 'diffuse', 'vec3' },
  { 'specular', 'vec3' },
})

class('NiPointLight', 'NiLight', {
  { 'constantAttenuation', 'f32' },
  { 'linearAttenuation', 'f32' },
  { 'quadraticAttenuation', 'f32' },
})

class('NiSpotLight', 'NiPointLight', {
  { 'outerSpotAngle', 'f32' },
  { 'innerSpotAngle', 'f32', when = 'V >= @20.2.0.5' },
  { 'exponent', 'f32' },
})

class('NiTextureEffect', 'NiDynamicEffect', {
  { 'projectionRotation', 'mat3' },
  { 'projectionPosition', 'vec3' },
  { 'filterMode', 'u32' },
  { 'maxAnisotropy', 'u16', when = 'V >= @20.5.0.4' },
  { 'clampMode', 'u32' },
  { 'textureType', 'u32' },
  { 'coordGenType', 'u32' },
  { 'texture', 'link:NiSourceTexture' },
  { 'enableClipPlane', 'u8' },
  { 'clipPlane', 'vec4' },
  { skip = 4, when = 'V <= @10.2.0.0' },
  { skip = 2, when = 'V <= @4.1.0.12' },
})
