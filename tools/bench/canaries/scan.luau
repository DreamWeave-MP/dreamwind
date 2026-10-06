--!strict
--!native
-- Walk record framing and identities without decoding payloads.
local tes3 = require '@dreamwind/tes3'

local function run(scale: number, root: string): number
  local source = assert(jess.fs.readBuffer(jess.fs.join(root, 'tests', 'tes3', 'assets', 'all_types.esp')))
  local plugin = tes3.open(source)
  local rounds = math.max(1, math.floor(1000 * scale))

  local started = os.clock()
  local identified = 0
  for _ = 1, rounds do
    for index = 0, plugin:count() - 1 do
      plugin:code(index)
      if tes3.records.id(plugin, index) then identified += 1 end
    end
  end

  local elapsed = os.clock() - started
  assert(identified > rounds)
  return elapsed
end

return table.freeze {
  name = 'scan',
  path = 'tools/bench/canaries/scan.luau',
  run = run,
}
