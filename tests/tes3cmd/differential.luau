--!strict
--!native
-- dream.tes3cmd against jess-omwaddon's application logic (`lines.luau` says what is compared).
-- The host (libs/lua/tests/tes3_experiment.rs) hands over `fixtures` (name and bytes) and
-- `goldens` (name to the lines jess answered, frozen in `golden/<name>.jsonl`); blessing, it hands
-- no goldens and reads `blessed` back instead. The synthetic plugins from `fixtures.luau` always
-- run first. While the native binding is still in jess, every line is checked against it live as
-- well.
local fixtures = require './fixtures'
local lines = require './lines'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

type Fixture = { name: string, bytes: buffer }

local given = (_G :: any).fixtures :: { Fixture }?
local goldens = (_G :: any).goldens :: { [string]: lines.Lines }?
local blessed = (_G :: any).blessed :: { [string]: lines.Lines }?
local oracle = if require './../tes3/oracle' then (_G :: any).jess.plugin else nil
--- Real data too big for goldens: checked against the native binding alone.
local live = (_G :: any).live == true

local list: { Fixture } = {}
for _, fixture in fixtures.all() do
  table.insert(list, { name = fixture.name, bytes = buffer.fromstring(fixture.bytes) })
end

for _, fixture in given or {} do
  table.insert(list, fixture)
end

for _, fixture in list do
  suite.it(`{fixture.name}: matches jess`, function()
    if live then
      expect(lines.compareLive(`{fixture.name} (live)`, fixture.bytes) > 0).toBe(true)
      return
    end

    local got = lines.port(fixture.bytes)

    if blessed and not goldens then
      blessed[fixture.name] = lines.native(fixture.bytes)
      return
    end

    if goldens then
      local golden = goldens[fixture.name]
      assert(golden, `no golden for {fixture.name}; bless with JESS_BLESS=1`)
      lines.compare(fixture.name, got, golden)
    end

    if oracle then lines.compare(`{fixture.name} (live)`, got, lines.native(fixture.bytes)) end

    expect(#got > 0).toBe(true)
  end)
end

return suite
