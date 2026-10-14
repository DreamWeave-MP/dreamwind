--!strict
-- Prints scalar report fields from DreamWind tool state, one `fact name value` line each. This is
-- kept with DreamWind because the state belongs to DreamWind's load-order tools, not Jess.
local function printFact(name: string, value: unknown)
  if type(value) ~= 'table' then
    print(`fact {name} {value}`)
    return
  end

  local fields = value :: { [unknown]: unknown }
  if #fields > 0 then
    print(`fact {name} {#fields}`)
    return
  end

  for field, inner in fields do
    if type(inner) == 'table' then continue end
    print(`fact {name}.{field} {inner}`)
  end
end

return function(state: { [string]: unknown })
  for script, options in state do
    if type(options) ~= 'table' then continue end

    local report = (options :: { report: unknown? }).report
    if type(report) ~= 'table' then continue end

    for field, value in report :: { [string]: unknown } do
      printFact(`{script}.{field}`, value)
    end
  end
end
