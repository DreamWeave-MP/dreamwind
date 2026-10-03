--!strict
--!native
-- dream.tes3 against jess-omwaddon, record by record: every record decoded, its value encoded
-- again, and the plugin saved untouched. The host (libs/lua/tests/tes3_experiment.rs) hands over
-- `fixtures` (name and bytes) and `goldens` (name to the lines jess-omwaddon answered, frozen in
-- `golden/<name>.jsonl`); blessing, it hands no goldens and reads `blessed` back instead. While the
-- native binding is still in jess, every line is checked against it live as well.
local bytes = require '@dream/bytes'
local canonical = require './canonical'
local tes3 = require '@dreamwind/tes3'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

type Fixture = { name: string, bytes: buffer }

local fixtures = (_G :: any).fixtures :: { Fixture }
local goldens = (_G :: any).goldens :: { [string]: { string } }?
local blessed = (_G :: any).blessed :: { [string]: { string } }
local oracle = if require './oracle' then (_G :: any).jess.plugin else nil
--- Real data too big for goldens: checked against the native binding alone.
local live = (_G :: any).live == true

--- What a record decodes and encodes to, as one golden line.
local function line(
  index: number,
  tag: string,
  decoded: boolean,
  value: unknown,
  encoded: boolean,
  data: unknown
): string
  local entry: { [string]: unknown } = { record = index, tag = tag }
  if not decoded then
    entry.error = tostring(value)
  elseif value == nil then
    entry.untyped = true
  else
    entry.value = value
    entry.encoded = if encoded then bytes.md5(data :: buffer) else nil
    entry.encodeError = if encoded then nil else tostring(data)
  end

  return canonical(entry)
end

--- The port's lines for a plugin.
local function portLines(plugin: tes3.Plugin): { string }
  local out: { string } = {}
  for i = 0, plugin:count() - 1 do
    -- A record that doesn't decode is a line saying why, as for the native side.
    local decoded, value = pcall(plugin.decode, plugin, i)
    local encoded, data = false, nil :: unknown
    if decoded and value then
      encoded, data = pcall(plugin.encode, plugin, value :: tes3.Value)
    end

    out[i + 1] = line(i, plugin:tag(i), decoded, value, encoded, data)
  end

  return out
end

--- jess-omwaddon's lines for the same plugin, through the native binding.
local function nativeLines(source: buffer): { string }
  local plugin = oracle.parse(source, { encoding = 'win1252' })
  local scratch = oracle.new()
  local out: { string } = {}
  for i = 0, #plugin - 1 do
    local record = plugin:record(i)
    -- The native binding throws on a record that doesn't decode; that's the line.
    local decoded, value = pcall(record.decode, record)
    local encoded, data = false, nil :: unknown
    if decoded and value then
      local inserted
      encoded, inserted = pcall(scratch.insert, scratch, value)
      if encoded then
        data = inserted:bytes()
        inserted:delete()
      else
        data = inserted
      end
    end

    out[i + 1] = line(i, (jess.meta :: any)(record).tag, decoded, value, encoded, data)
  end

  return out
end

local function compare(name: string, got: { string }, want: { string })
  expect(#got).toBe(#want)
  for i, text in want do
    if got[i] ~= text then
      error(`{name}: record {i - 1} differs\n  want {text}\n  got  {got[i]}`, 0)
    end
  end
end

for _, fixture in fixtures do
  suite.describe(fixture.name, function()
    suite.it('saves untouched byte for byte', function()
      local plugin = tes3.open(fixture.bytes)
      expect(buffer.tostring(plugin:save()) == buffer.tostring(fixture.bytes)).toBe(true)
      expect(tes3.checkRoundTrip(fixture.bytes)).toBeNil()
    end)

    suite.it('decodes and encodes every record as jess-omwaddon does', function()
      local got = portLines(tes3.open(fixture.bytes))
      if live then
        compare(`{fixture.name} (live)`, got, nativeLines(fixture.bytes))
        return
      end

      if not goldens then
        blessed[fixture.name] = nativeLines(fixture.bytes)
        return
      end

      local golden = goldens[fixture.name]
      assert(golden, `no golden for {fixture.name}; bless with JESS_BLESS=1`)
      compare(fixture.name, got, golden)
      if oracle then compare(`{fixture.name} (live)`, got, nativeLines(fixture.bytes)) end
    end)
  end)
end

return suite
