--!strict
--!native
-- dream.saves against jess-save (`lines.luau` says what is compared), on every scenario
-- `fixtures.luau` builds: its content files and openmw.cfg are written under the folder the host
-- (libs/lua/tests/tes3_experiment.rs) hands over as `scratch`, and the lines spell that folder
-- `<scratch>`. The host hands over `goldens` (scenario name to the lines jess answered, frozen in
-- `golden/<name>.jsonl`); blessing, it hands no goldens and reads `blessed` back instead. While
-- the native binding is still in jess, every line is checked against it live as well.
local fixtures = require './fixtures'
local lines = require './lines'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

local scratch = (_G :: any).scratch :: string
local goldens = (_G :: any).goldens :: { [string]: lines.Lines }?
local blessed = (_G :: any).blessed :: { [string]: lines.Lines }?
local oracle = (_G :: any).jess and (_G :: any).jess.save

--- `lines` with the scratch folder spelled `<scratch>`, so goldens hold no machine's paths.
local function portable(found: lines.Lines): lines.Lines
  local pattern = string.gsub(scratch, '[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0')
  local out = {}
  for i, line in found do
    out[i] = string.gsub(line, pattern, '<scratch>')
  end

  return out
end

for _, scenario in fixtures.scenarios() do
  suite.it(`{scenario.name}: matches jess`, function()
    local folder = jess.fs.join(scratch, scenario.name)
    local data = jess.fs.join(folder, 'data')
    jess.fs.createDir(data)
    for name, content in scenario.files do
      jess.fs.write(jess.fs.join(data, name), content)
    end

    local config = jess.fs.join(folder, 'openmw.cfg')
    jess.fs.write(config, `data={data}\n{scenario.config or ''}`)
    local bytes = buffer.fromstring(scenario.save)
    local got = portable(lines.port(bytes, config, scenario.operations))
    if blessed and not goldens then
      blessed[scenario.name] = portable(lines.native(bytes, config, scenario.operations))
      return
    end

    if goldens then
      local golden = goldens[scenario.name]
      assert(golden, `no golden for {scenario.name}; bless with JESS_BLESS=1`)
      lines.compare(scenario.name, got, golden)
    end

    if oracle then
      lines.compare(
        `{scenario.name} (live)`,
        got,
        portable(lines.native(bytes, config, scenario.operations))
      )
    end

    expect(#got > 0).toBe(true)
  end)
end

return suite
