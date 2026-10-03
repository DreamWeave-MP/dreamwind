--!strict
--!native
-- dream.saves against jess-save on real saves: every `.omwsave` the host hands over as `fixtures`,
-- described, validated, checked, and dry-run stripped of each content file, against the openmw.cfg
-- it hands over as `config` (with JESS_SAVES_CONFIG), and without one.
local lines = require './lines'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

type Fixture = { name: string, bytes: buffer }

local fixtures = (_G :: any).fixtures :: { Fixture }
local config = (_G :: any).config :: string?

for _, fixture in fixtures do
  suite.it(`{fixture.name}: matches jess`, function()
    local dependencies = (_G :: any).jess.save.parse(fixture.bytes).header.dependencies :: { string }
    local operations: { lines.Operation } =
      { { kind = 'check' }, { kind = 'check', noConfig = true } }
    for _, dependency in dependencies do
      table.insert(
        operations,
        { kind = 'strip', dependencies = { dependency }, mode = 'dryRun' } :: lines.Operation
      )
    end

    local got = lines.port(fixture.bytes, config, operations)
    lines.compare(fixture.name, got, lines.native(fixture.bytes, config, operations))
    expect(#got > 0).toBe(true)
  end)
end

return suite
