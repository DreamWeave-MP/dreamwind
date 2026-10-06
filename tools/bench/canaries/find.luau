--!strict
--!native
-- Record identity plus linear typed lookup through @dreamwind/tes3's current query surface.
local tes3 = require '@dreamwind/tes3'

local function run(scale: number, root: string): number
  local source = assert(jess.fs.readBuffer(jess.fs.join(root, 'tests', 'tes3', 'assets', 'all_types.esp')))
  local plugin = tes3.open(source)
  assert(tes3.records.find(plugin, 'LIGH', 'test_light') ~= nil)
  local rounds = math.max(1, math.floor(10000 * scale))

  local started = os.clock()
  local found = 0
  for _ = 1, rounds do
    if tes3.records.find(plugin, 'LIGH', 'test_light') then found += 1 end
  end

  local elapsed = os.clock() - started
  assert(found == rounds)
  return elapsed
end

return table.freeze {
  name = 'find',
  path = 'tools/bench/canaries/find.luau',
  run = run,
}
