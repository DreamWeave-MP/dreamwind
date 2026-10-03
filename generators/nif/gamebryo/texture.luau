--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- OpenMW's `components/nif/texture.hpp`.

local Schema = require '../gamebryo_schema'

local class, struct, same = Schema.class, Schema.struct, Schema.same

same('NiTexture', 'NiObjectNET')

struct('NiSourceTextureFormatPrefs', {
  { 'pixelLayout', 'u32' },
  { 'useMipMaps', 'u32' },
  { 'alphaFormat', 'u32' },
})

class('NiSourceTexture', 'NiTexture', {
  { 'external', 'u8' },
  { '_hasData', expr = 'V >= @10.0.1.4', default = 'false' },
  { '_dataFlag', 'u8', when = 'not _hasData and external == 0' },
  { '_hasData', expr = '_dataFlag ~= 0', when = 'not _hasData and external == 0' },
  { 'file', 'string', when = 'external ~= 0 or V >= @10.1.0.0' },
  { 'data', 'link:NiPixelData', when = '_hasData' },
  { 'prefs', 'NiSourceTextureFormatPrefs' },
  { 'isStatic', 'u8', default = '1' },
  { 'directRendering', 'bool', when = 'V >= @10.1.0.103', default = 'true' },
  { 'persistRenderData', 'bool', when = 'V >= @20.2.0.4' },
})

class('BSShaderTextureSet', nil, {
  { 'textures', 'custom:sizedStrings' },
})
