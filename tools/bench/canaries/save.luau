--!strict
--!native
-- Serialize an unchanged parsed plugin, including the byte-preserving record spine.
local tes3 = require '@tes3'

local function run(scale: number, root: string): number
  local source = assert(jess.fs.readBuffer(jess.fs.join(root, 'tools', 'bench', 'assets', 'all_types.esp')))
  local plugin = tes3.open(source)
  local rounds = math.max(1, math.floor(200 * scale))

  local started = os.clock()
  local size = 0
  for _ = 1, rounds do
    size += buffer.len(plugin:save())
  end

  local elapsed = os.clock() - started
  assert(size > rounds)
  return elapsed
end

return table.freeze {
  name = 'save',
  path = 'tools/bench/canaries/save.luau',
  run = run,
}
