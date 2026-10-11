--!strict
--!native
-- Decode every supported record in the representative all-types plugin.
local tes3 = require '@dreamwind/tes3'

local function run(scale: number, root: string): number
  local source = assert(jess.fs.readBuffer(jess.fs.join(root, 'tools', 'bench', 'assets', 'all_types.esp')))
  local plugin = tes3.open(source)
  local rounds = math.max(1, math.floor(20 * scale))

  local started = os.clock()
  local decoded = 0
  for _ = 1, rounds do
    for index = 0, plugin:count() - 1 do
      if plugin:decode(index) then decoded += 1 end
    end
  end

  local elapsed = os.clock() - started
  assert(decoded > rounds)
  return elapsed
end

return table.freeze {
  name = 'decode',
  path = 'tools/bench/canaries/decode.luau',
  run = run,
}
