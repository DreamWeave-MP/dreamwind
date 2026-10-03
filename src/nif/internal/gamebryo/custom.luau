--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The values and checks the schema can't state as steps, one part per OpenMW header: each reader
takes the stream and the position and returns the value and the position after it; each check
takes the record, the records, their classes, and the record's index.
]]

local custom = {}
for _, part in
  {
    require './custom/node',
    require './custom/property',
    require './custom/extra',
    require './custom/data',
    require './custom/controller',
    require './custom/physics',
    require './custom/particle',
  }

do
  for name, value in part :: { [string]: any } do
    assert(custom[name] == nil, `custom {name} is defined twice`)
    custom[name] = value
  end
end

return table.freeze(custom)
