--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- OpenMW's `components/nif/particle.hpp` values the schema can't state as steps.

local G = require '../stream'

type Stream = G.Stream

local custom = {}

--- `NiPSysEmitterCtlrData`'s visibility keys, read by `readKeyMapPair<float, bool>`: a count,
--- then a time and a byte per key, with no interpolation type whatever the version.
function custom.emitterVisKeys(s: Stream, p: number): (any, number)
  local b = s.b
  local count = buffer.readu32(b, p)
  p += 4
  G.checkSize(s, count * 5)
  local keys = table.create(count) :: { { time: number, value: boolean } }
  for i = 1, count do
    keys[i] = { time = buffer.readf32(b, p), value = buffer.readu8(b, p + 4) ~= 0 }
    p += 5
  end

  return { frameName = '', legacyWeight = 0, interpolationType = 0, keys = keys }, p
end

return custom
