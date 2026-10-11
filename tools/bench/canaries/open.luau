--!strict
--!native
-- Parse the representative all-types TES3 plugin repeatedly. File IO is outside the timed loop.
local tes3 = require '@dreamwind/tes3'

local function run(scale: number, root: string): number
  local source = assert(jess.fs.readBuffer(jess.fs.join(root, 'tools', 'bench', 'assets', 'all_types.esp')))
  local rounds = math.max(1, math.floor(200 * scale))
  local started = os.clock()
  local records = 0
  for _ = 1, rounds do
    records += tes3.open(source):count()
  end

  local elapsed = os.clock() - started
  assert(records > rounds)
  return elapsed
end

return table.freeze {
  name = 'open',
  path = 'tools/bench/canaries/open.luau',
  run = run,
}
