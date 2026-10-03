--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- OpenMW's `components/nif/base.hpp`.

local Schema = require '../gamebryo_schema'

local class, struct, same = Schema.class, Schema.struct, Schema.same

class('Extra', nil, {
  { 'name', 'string', when = 'V >= @10.0.1.0' },
  { 'next', 'link:Extra', when = 'V < @10.0.1.0 and V <= @4.2.2.0' },
  { 'recordSize', 'u32', when = 'V < @10.0.1.0 and V <= @4.2.2.0' },
})

class('NiTimeController', nil, {
  { 'next', 'link:NiTimeController' },
  { 'flags', 'u16' },
  { 'frequency', 'f32' },
  { 'phase', 'f32' },
  { 'timeStart', 'f32' },
  { 'timeStop', 'f32' },
  { 'target', 'link:NiObjectNET', when = 'V >= @3.3.0.13' },
})

class('NiObjectNET', nil, {
  { 'name', 'string' },
  { 'extra', 'link:Extra', when = 'V < @10.0.1.0' },
  { 'extraList', 'links:Extra', when = 'V >= @10.0.1.0' },
  { 'controller', 'link:NiTimeController' },
})
