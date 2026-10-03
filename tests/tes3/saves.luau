--!strict
--!native
-- dream.tes3 on real OpenMW saves (`JESS_SAVES`), against the native binding: each save opens and
-- saves byte for byte, every record's id reads as the binding's, the SAVE metadata matches what
-- `jess.save` reads, and every LUAD payload decodes exactly when the binding's does.
local tes3 = require '@dreamwind/tes3'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

type Fixture = { name: string, bytes: buffer }

local fixtures = (_G :: any).fixtures :: { Fixture }
local LUAD = tes3.tags.code 'LUAD'

for _, fixture in fixtures do
  suite.describe(fixture.name, function()
    local plugin = tes3.open(fixture.bytes, { profile = 'omwsave' })
    local native = (jess.save :: any).parse(fixture.bytes, { game = 'openmw', name = fixture.name })

    suite.it(
      'saves untouched byte for byte',
      function() expect(buffer.tostring(plugin:save()) == buffer.tostring(fixture.bytes)).toBe(true) end
    )

    suite.it('reads every record id as the binding does', function()
      local records = native.plugin
      expect(plugin:count()).toBe(#records)
      for i = 0, plugin:count() - 1 do
        local id = tes3.records.id(plugin, i)
        local want = (jess.meta :: any)(records:record(i)).id
        if id ~= want then
          error(`record {i}: id {tostring(id)}, the binding read {tostring(want)}`, 0)
        end
      end
    end)

    suite.it('reads the SAVE metadata as jess.save does', function()
      local profile = tes3.save.profile(plugin)
      local header = native.header
      expect(profile.formatVersion).toBe(header.formatVersion)
      expect(profile.playerName).toBe(header.player.name)
      expect(profile.playerLevel).toBe(header.player.level)
      expect(profile.playerClassId).toBe(header.player.classId)
      expect(profile.playerClassName).toBe(header.player.className)
      expect(profile.playerCellName).toBe(header.cell)
      expect(profile.inGameTime).toEqual(header.inGameTime)
      expect(profile.timePlayed).toBe(header.timePlayed)
      expect(profile.description).toBe(header.description)
      expect(profile.dependencies).toEqual(header.dependencies)
      expect(profile.screenshotLength).toBe(header.screenshotBytes)
    end)

    suite.it('decodes every LUAD payload exactly when the binding does', function()
      local decoded = 0
      for _, entry in native:luaData() do
        if entry.error then continue end

        decoded += 1
      end

      local ours = 0
      for i = 0, plugin:count() - 1 do
        local source = plugin:span(i)
        for _, sub in plugin:subrecords(i) do
          if sub.code ~= LUAD then continue end

          -- A payload that doesn't decode is counted out on both sides.
          if pcall(tes3.save.decodeLuaData, source, sub.payload, sub.size) then
            ours += 1
          end
        end
      end

      expect(ours).toBe(decoded)
    end)
  end)
end

return suite
