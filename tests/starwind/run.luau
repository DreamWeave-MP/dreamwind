--!strict
--!native
-- The Starwind port's own cases, on records small enough to read: the tool ports' semantics
-- (addVanillaRefs's are its Rust tests, case for case), and the tes3cmd and validator corners the
-- Python build depends on. The real-data equivalence check is equivalence.luau.
local addVanillaRefs = require '@dreamwind/tools/add-vanilla-refs'
local mergeToMaster = require '@dreamwind/tools/merge-to-master'
local starwind = require '@dreamwind/starwind'
local tes3conv = require '@dreamwind/tools/tes3conv'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

type Record = { [string | number]: any }

local function header(masters: { { string | number } }?): Record
  return {
    type = 'Header',
    flags = '',
    version = 1.3,
    fileType = 'Esp',
    author = '',
    description = '',
    numObjects = 0,
    masters = masters or {},
  }
end

local function misc(id: string, script: string?): Record
  return {
    type = 'MiscItem',
    flags = '',
    id = id,
    name = id,
    script = script or '',
    mesh = '',
    icon = '',
  }
end

local function dial(id: string, kind: string?): Record
  return { type = 'Dialogue', flags = '', id = id, dialogueType = kind or 'Topic' }
end

local function info(id: string, prev: string?, next: string?, fields: Record?): Record
  local record: Record = {
    type = 'DialogueInfo',
    flags = '',
    id = id,
    prevId = prev or '',
    nextId = next or '',
    speakerId = '',
    speakerRace = '',
    speakerClass = '',
    speakerFaction = '',
    speakerCell = '',
    playerFaction = '',
    soundPath = '',
    text = '',
    scriptText = '',
    filters = {},
    data = {
      dialogueType = 'Topic',
      disposition = 0,
      speakerRank = -1,
      speakerSex = 'Any',
      playerRank = -1,
    },
  }

  for key, value in fields or {} do
    record[key] = value
  end

  return record
end

local function ids(records: { Record }): { string }
  local list = {}

  for _, record in records do
    if record.type ~= 'Header' then
      table.insert(list, `{record.type}:{record.id or record.name or record.effectId}`)
    end
  end

  return list
end

local function has(records: { Record }, id: string): boolean
  for _, record in records do
    if type(record.id) == 'string' and string.lower(record.id) == string.lower(id) then
      return true
    end
  end

  return false
end

local function chain(records: { Record }): { string }
  local list = {}

  for _, record in records do
    if record.type == 'DialogueInfo' then
      table.insert(list, `{record.id}<{record.prevId}|{record.nextId}>`)
    end
  end

  return list
end

suite.describe('tes3conv', function()
  local Document = [[
[
  {
    "type": "Header",
    "flags": "",
    "version": 1.3,
    "file_type": "Esp",
    "author": "",
    "description": "",
    "num_objects": 3,
    "masters": []
  },
  {
    "type": "GameSetting",
    "flags": "",
    "id": "sQuote",
    "value": {
      "type": "String",
      "data": "say \"hi\"\né"
    }
  },
  {
    "type": "Class",
    "flags": "",
    "id": "Pilot",
    "name": "Pilot",
    "data": {
      "attribute1": "Speed",
      "attribute2": "Agility",
      "specialization": "Stealth",
      "major1": "Acrobatics",
      "minor1": "Athletics",
      "major2": "Alchemy",
      "minor2": "Alteration",
      "major3": "Armorer",
      "minor3": "Axe",
      "major4": "Block",
      "minor4": "BluntWeapon",
      "major5": "Conjuration",
      "minor5": "Destruction",
      "flags": "",
      "services": ""
    },
    "description": "Flies."
  },
  {
    "type": "Cell",
    "flags": "",
    "name": "Hangar",
    "data": {
      "flags": "IS_INTERIOR",
      "grid": [
        0,
        0
      ]
    },
    "references": []
  }
]
]]

  suite.it('reads keys camelCase and strings unescaped', function()
    local records = tes3conv.decode(Document)
    expect(#records).toBe(4)
    expect(records[1].fileType).toBe 'Esp'
    expect(records[2].value.data).toBe 'say "hi"\n\u{e9}'
  end)

  suite.it('leaves lazy types unread until realized', function()
    local records = tes3conv.decode(Document, { lazy = { Cell = true } })
    local cell = records[4]
    expect(tes3conv.isLazy(cell)).toBe(true)
    expect(cell.name).toBeNil()
    tes3conv.realize(cell)
    expect(cell.name).toBe 'Hangar'
    expect(tes3conv.isLazy(cell)).toBe(false)
  end)

  suite.it(
    'terminates the text tes3conv terminates, and drops a plugin\'s own counts of one',
    function()
      local records = tes3conv.decode(Document)
      expect(tes3conv.prepare(records[3]).description).toBe 'Flies.\0'
      expect(records[3].description).toBe 'Flies.'
      local cell = {
        type = 'Cell',
        references = {
          { mastIndex = 0, refrIndex = 2, id = 'b', temporary = true, objectCount = 1 },
          { mastIndex = 1, refrIndex = 9, id = 'a', temporary = true, objectCount = 1 },
          { mastIndex = 0, refrIndex = 1, id = 'p', temporary = false },
        },
      }
      local prepared = tes3conv.prepare(cell)
      local order = {}

      for _, reference in prepared.references do
        table.insert(order, `{reference.id}:{reference.objectCount}`)
      end

      expect(order).toEqual { 'p:nil', 'a:1', 'b:nil' }
    end
  )

  suite.it('writes what it reads, and reads it back sorted', function()
    local records = tes3conv.decode(Document)
    local plugin = tes3conv.plugin(records)
    local back = tes3conv.records(plugin)
    expect(back[2].type).toBe 'GameSetting'
    expect(back[3].description).toBe 'Flies.'
    expect(back[2].value.data).toBe 'say "hi"\n\u{e9}'
  end)
end)

suite.describe('merge-to-master', function()
  local function npc(id: string): Record return { type = 'Npc', flags = '', id = id, name = id } end

  suite.it(
    'remaps the plugin\'s masters and renumbers its own references after the master\'s',
    function()
      local master = {
        header { { 'A.esm', 1 }, { 'D.esm', 1 } },
        {
          type = 'Cell',
          flags = '',
          name = 'Hall',
          data = { flags = 'IS_INTERIOR', grid = { 0, 0 } },
          references = { { mastIndex = 0, refrIndex = 41, id = 'old', temporary = true } },
        },
      }

      local plugin = {
        header { { 'A.esm', 1 }, { 'B.esp', 1 }, { 'C.esm', 1 } },
        {
          type = 'Cell',
          flags = '',
          name = 'Hall',
          data = { flags = 'IS_INTERIOR', grid = { 0, 0 } },
          references = {
            { mastIndex = 0, refrIndex = 1, id = 'new', temporary = true },
            { mastIndex = 2, refrIndex = 5, id = 'target', temporary = true },
            { mastIndex = 3, refrIndex = 7, id = 'third', temporary = true },
          },
        },
      }

      local merged = mergeToMaster.merge(plugin, master, {
        masterName = 'B.esp',
        masters = { ['a.esm'] = { header() }, ['c.esm'] = { header() } },
      })
      local masters = {}

      for _, entry in merged[1].masters do
        table.insert(masters, entry[1])
      end

      expect(masters).toEqual { 'A.esm', 'D.esm', 'C.esm' }
      local references = {}

      for _, reference in merged[2].references do
        references[reference.id] = `{reference.mastIndex}:{reference.refrIndex}`
      end

      expect(references).toEqual { old = '0:41', new = '0:42', target = '0:5', third = '3:7' }
    end
  )

  suite.it('places INFOs after their previous INFO and repairs the links between', function()
    local master = { header(), dial 'Topic', info('I1', '', 'I2'), info('I2', 'I1', '') }
    local plugin = {
      header { { 'Master.esm', 1 } },
      dial 'Topic',
      info('I3', 'I1', 'I2'),
      info('I0', '', ''),
      info('I9', 'missing', ''),
    }
    local merged = mergeToMaster.merge(plugin, master, { masterName = 'Master.esm' })
    expect(chain(merged)).toEqual { 'I0<|I1>', 'I1<I0|I3>', 'I3<I1|I2>', 'I2<I3|I9>', 'I9<I2|>' }
  end)

  suite.it(
    'keys the item and actor families together, and keeps only the master dialogue it merged',
    function()
      local master = { header { { 'Base.esm', 1 } }, { type = 'Creature', flags = '', id = 'Foo' } }
      local plugin = {
        header { { 'Base.esm', 1 }, { 'Master.esm', 1 } },
        npc 'foo',
        dial('Greeting 0', 'Greeting'),
        info('G1', 'V1', ''),
      }
      local base = { header(), dial('Greeting 0', 'Greeting'), info('V1', '', '') }
      local merged = mergeToMaster.merge(
        plugin,
        master,
        { masterName = 'Master.esm', masters = { ['base.esm'] = base } }
      )
      expect(ids(merged)).toEqual { 'Npc:foo', 'Dialogue:Greeting 0', 'DialogueInfo:G1' }
      expect(chain(merged)).toEqual { 'G1<V1|>' }
    end
  )

  suite.it('writes types in order, ids sorted, journals before other topics', function()
    local master = { header(), dial('b', 'Topic'), dial('a', 'Topic'), dial('z', 'Journal') }
    local plugin = {
      header { { 'Master.esm', 1 } },
      { type = 'Static', flags = '', id = 'b_rock', mesh = '' },
      { type = 'Static', flags = '', id = 'B_rock2', mesh = '' },
      { type = 'GameSetting', flags = '', id = 'sZ', value = { type = 'String', data = '' } },
    }
    local merged = mergeToMaster.merge(plugin, master, { masterName = 'Master.esm' })
    expect(ids(merged)).toEqual {
      'GameSetting:sZ',
      'Static:B_rock2',
      'Static:b_rock',
      'Dialogue:z',
      'Dialogue:a',
      'Dialogue:b',
    }
  end)
end)

suite.describe('add-vanilla-refs', function()
  local Names = { names = { 'Bloodmoon.esm', 'Tribunal.esm', 'Morrowind.esm' } }

  local function run(plugin: { Record }, bases: { { Record } }): ({ Record }, { string })
    return addVanillaRefs.run(plugin, bases, Names)
  end

  suite.it('resolves imported records transitively', function()
    local result = run({ header(), misc('root', 'first_dependency') }, {
      { header(), misc('first_dependency', 'second_dependency') },
      { header(), misc('second_dependency', 'third_dependency') },
      { header(), misc 'third_dependency' },
    })
    expect(
      has(result, 'first_dependency')
        and has(result, 'second_dependency')
        and has(result, 'third_dependency')
    ).toBe(true)
  end)

  suite.it('defers dialogue dependencies to the second closure', function()
    local result, log = run(
      { header(), dial 'Topic', info('Info', '', '', { speakerId = 'vanilla_speaker' }) },
      {
        { header(), misc 'vanilla_speaker' },
      }
    )
    expect(has(result, 'vanilla_speaker')).toBe(true)
    local passes = {}

    for index, line in log do
      if line == '  target=MISC \'vanilla_speaker\'' then table.insert(passes, log[index - 1]) end
    end

    expect(passes).toEqual { '  pass=post-dialogue' }
  end)

  suite.it('doesn\'t follow or keep deleted records', function()
    local deleted = misc('deleted_record', 'unwanted_dependency')
    deleted.flags = 'DELETED'
    local result = run({ header(), deleted }, { { header(), misc 'unwanted_dependency' } })
    expect(ids(result)).toEqual {}
  end)

  suite.it('removes exact duplicate magic effects', function()
    local effect =
      { type = 'MagicEffect', flags = '', effectId = 'WaterBreathing', description = '' }
    local result = run({ header(), effect, table.clone(effect) }, {})
    expect(ids(result)).toEqual { 'MagicEffect:WaterBreathing' }
  end)

  suite.it('keeps Bloodmoon precedence', function()
    local result = run({ header(), misc('root', 'shared_dependency') }, {
      { header(), misc('shared_dependency', 'bloodmoon_leaf'), misc 'bloodmoon_leaf' },
      { header(), misc('shared_dependency', 'tribunal_leaf') },
    })
    expect(has(result, 'bloodmoon_leaf')).toBe(true)
    expect(has(result, 'tribunal_leaf')).toBe(false)
  end)

  suite.it('imports the masters\' foundations and what they need', function()
    local result = run({ header(), misc 'WaterBreathing' }, {
      {
        header(),
        { type = 'Race', flags = '', id = 'vanilla_race', spells = { 'vanilla_spell' } },
        { type = 'Spell', flags = '', id = 'vanilla_spell' },
        {
          type = 'MagicEffect',
          flags = '',
          effectId = 'WaterBreathing',
          castVisual = 'vanilla_cast_visual',
        },
        { type = 'Static', flags = '', id = 'vanilla_cast_visual' },
      },
    })
    expect(
      has(result, 'vanilla_race')
        and has(result, 'vanilla_spell')
        and has(result, 'vanilla_cast_visual')
    ).toBe(true)
  end)

  suite.it('follows escort and follow targets, and sends undefined cells to igtestcell', function()
    local actor = {
      type = 'Npc',
      flags = '',
      id = 'root',
      aiPackages = {
        { type = 'Escort', target = 'escort_target', cell = '' },
        { type = 'Follow', target = 'follow_target', cell = 'root' },
      },
    }
    local result = run(
      { header(), actor },
      { { header(), misc 'escort_target', misc 'follow_target' } }
    )
    expect(has(result, 'escort_target') and has(result, 'follow_target')).toBe(true)
    expect(result[2].aiPackages[1].cell).toBe 'igtestcell'
    expect(result[2].aiPackages[2].cell).toBe 'root'
  end)

  suite.it('doesn\'t treat sound paths or filter operands as dependencies', function()
    local line = info('Info', '', '', {
      soundPath = 'sound/dialogue.wav',
      filters = { { id = 'filter_operand', filterType = 'Global' } },
    })
    local result = run(
      { header(), dial 'Topic', line },
      { { header(), misc 'filter_operand', misc 'sound/dialogue.wav' } }
    )
    expect(has(result, 'filter_operand') or has(result, 'sound/dialogue.wav')).toBe(false)
  end)

  suite.it('relinks dialogue around removed vanilla INFOs', function()
    local usable = info('V2', 'V1', 'V3', { speakerCell = 'MissingCell' })
    local bases = {
      {
        header(),
        dial 'Topic',
        info('V1', '', 'V2', { speakerId = 'missing_actor' }),
        usable,
        info('V3', 'V2', '', { speakerId = 'missing_actor' }),
      },
    }
    local first =
      info('S1', '', 'V1', { speakerCell = 'VanillaCell', filters = { { id = 'filter_operand' } } })
    local result =
      run({ header(), dial 'Topic', first, info('S2', 'V2', 'V3'), info('S3', 'V3', '') }, bases)
    expect(chain(result)).toEqual { 'S1<|V2>', 'V2<S1|S2>', 'S2<V2|S3>', 'S3<S2|>' }
  end)

  suite.it(
    'materializes a live vanilla-only topic, and not one only dialogue text names',
    function()
      local script =
        { type = 'Script', flags = '', id = 'starwind_script', text = 'AddTopic "VanillaTopic"' }
      local result = run({ header(), script }, {
        {
          header(),
          dial 'VanillaTopic',
          info('VanillaInfo', '', ''),
          dial 'Ship',
          info('ShipInfo', '', ''),
        },
      })
      expect(has(result, 'VanillaTopic') and has(result, 'VanillaInfo')).toBe(true)
      expect(has(result, 'Ship') or has(result, 'ShipInfo')).toBe(false)

      local priced = info('PriceInfo', '', '', { text = 'VanillaB' })
      local mine = info('StarwindInfo', '', '', { text = 'price on your head; VanillaB' })
      result = run({ header(), dial 'StarwindTopic', mine }, {
        {
          header(),
          dial 'Price on Your Head',
          priced,
          dial 'VanillaB',
          info('VanillaBInfo', '', ''),
        },
      })
      expect(has(result, 'Price on Your Head') or has(result, 'VanillaB')).toBe(false)
    end
  )

  suite.it('resolves what materialized dialogue needs in the second pass', function()
    local result = run({ header() }, {
      {
        header(),
        dial('Topic', 'Voice'),
        info('VanillaInfo', '', '', { speakerFaction = 'Morag Tong' }),
        { type = 'Faction', flags = '', id = 'Morag Tong', reactions = {} },
      },
    })
    expect(has(result, 'VanillaInfo') and has(result, 'Morag Tong')).toBe(true)
  end)

  suite.it('keeps vanilla INFOs a plugin actor could say, and prunes the rest', function()
    local speaker = { type = 'Npc', flags = '', id = 'speaker', race = 'Nord', class = 'Warrior' }
    local function vanilla(fields: Record): { { Record } }
      return { { header(), dial 'Topic', info('VanillaInfo', '', '', fields) } }
    end

    local matching = run(
      { header(), speaker, dial 'Topic', info 'StarwindInfo' },
      vanilla {
        speakerRace = 'Nord',
        speakerClass = 'Warrior',
      }
    )
    expect(has(matching, 'VanillaInfo')).toBe(true)

    local other = run(
      { header(), speaker, dial 'Topic', info 'StarwindInfo' },
      vanilla {
        speakerRace = 'Dunmer',
        speakerClass = 'Warrior',
      }
    )
    expect(has(other, 'VanillaInfo')).toBe(false)

    local impossible = run(
      { header(), dial 'Topic', info 'StarwindInfo' },
      vanilla {
        speakerId = 'missing_speaker',
        speakerFaction = 'some_faction',
      }
    )
    expect(has(impossible, 'VanillaInfo')).toBe(false)
  end)

  suite.it('orders INFOs as OpenMW does, ids matched case-insensitively', function()
    local bases = { { header(), dial 'Topic', info('First', '', ''), info('Third', 'First', '') } }
    local result = run({ header(), dial 'Topic', info('second', 'first', '') }, bases)
    expect(chain(result)).toEqual { 'First<|second>', 'second<First|Third>', 'Third<second|>' }

    local moved = run({ header(), dial 'Topic', info('First', 'First', '') }, {
      { header(), dial 'Topic', info('First', '', ''), info('Second', 'First', '') },
    })
    expect(chain(moved)).toEqual { 'First<|Second>', 'Second<First|>' }
  end)

  suite.it('keeps empty shells, drops tombstones, and writes a topic once', function()
    local shells = run({ header(), dial 'DeadTopic', dial 'LiveTopic', info('LiveInfo', '', '') }, {
      { header(), dial 'DeadTopic' },
    })

    expect(ids(shells)).toEqual {
      'Dialogue:DeadTopic',
      'Dialogue:LiveTopic',
      'DialogueInfo:LiveInfo',
    }

    local tombstone = info('VanillaInfo', '', '')
    tombstone.flags = 'DELETED'
    local suppressed = run(
      { header(), dial 'Topic', tombstone },
      { { header(), dial 'Topic', info 'VanillaInfo' } }
    )
    expect(ids(suppressed)).toEqual { 'Dialogue:Topic' }

    local twice = run({ header(), dial 'Topic', info('Info', '', ''), dial 'Topic' }, {})
    expect(ids(twice)).toEqual { 'Dialogue:Topic', 'DialogueInfo:Info' }
  end)

  suite.it('drops the masters', function()
    local result = run({ header { { 'Morrowind.esm', 79837557 } } }, {})
    expect(#result[1].masters).toBe(0)
    expect(result[1].version).toBe(1.3)
  end)
end)

suite.describe('tes3cmd surgery', function()
  local surgery = starwind.surgery

  local function reference(index: number, id: string, temporary: boolean, fields: Record?): Record
    local value: Record = {
      mastIndex = 0,
      refrIndex = index,
      id = id,
      temporary = temporary,
      translation = { 0, 0, 0 },
      rotation = { 0, 0, 0 },
    }

    for key, item in fields or {} do
      value[key] = item
    end

    return value
  end

  local function cell(references: { Record }): Record
    return {
      type = 'Cell',
      flags = 'PERSISTENT',
      name = 'Lair',
      data = { flags = 'IS_INTERIOR', grid = { 0, 0 } },
      references = references,
    }
  end

  suite.it(
    'matches instances by their dump text, and rebuilds the cell without its header flags',
    function()
      local records = {
        header(),
        cell {
          reference(1, 'SW_SignCantina', false),
          reference(2, 'Bench', true, { owner = 'Adele' }),
          reference(3, 'Rock', true),
        },
      }
      expect(surgery.deleteInstances(records, { instance = 'DELE' })).toBe(1)
      expect(#records[2].references).toBe(2)
      expect(records[2].flags).toBe ''
    end
  )

  suite.it(
    'loses NAM0 with the reference it follows, leaving every reference persistent',
    function()
      local records = {
        header(),
        cell {
          reference(1, 'Door', false),
          reference(2, 'Tombstone', false, { deleted = true }),
          reference(3, 'Rock', true),
          reference(4, 'Tree', true),
        },
      }
      surgery.deleteDeletedInstances(records)
      local persistence = {}

      for _, value in records[2].references do
        persistence[value.id] = value.temporary
      end

      expect(persistence).toEqual { Door = false, Rock = false, Tree = false }

      local kept = {
        header(),
        cell {
          reference(1, 'Tombstone', false, { deleted = true }),
          reference(2, 'Door', false),
          reference(3, 'Rock', true),
        },
      }
      surgery.deleteDeletedInstances(kept)
      expect(kept[2].references[2].temporary).toBe(true)
    end
  )

  suite.it('reads a leveled list\'s orphaned level onto the entry before', function()
    local records = {
      header(),
      {
        type = 'LeveledCreature',
        flags = 'BLOCKED',
        id = 'Sand',
        creatures = { { 'Jawa', 1 }, { 'SW_Rakhoul1', 5 }, { 'Tusken', 3 } },
      },
    }
    surgery.deleteLeveledCreatures(records, 'sand', 'SW_Rakhoul1')
    expect(records[2].creatures).toEqual { { 'Jawa', 5 }, { 'Tusken', 3 } }
    expect(records[2].flags).toBe ''
  end)

  suite.it('ids cells and path grids the way tes3cmd does', function()
    expect(surgery.id {
      type = 'Cell',
      name = '',
      region = 'Tatooine Region',
      data = { flags = '', grid = { -2, 3 } },
    }).toBe 'tatooine region (-2, 3)'
    expect(surgery.id { type = 'PathGrid', cell = 'Hall', data = { grid = { 0, 0 } } }).toBe 'hall'
    expect(surgery.id { type = 'MagicEffect', effectId = 'TurnUndead' }).toBe '101'
  end)
end)

suite.describe('dialogue audit', function()
  local dialogue = starwind.dialogue

  suite.it('doesn\'t move an INFO whose previous INFO is itself', function()
    local replay = dialogue.replay {
      {
        name = 'test',
        records = {
          header(),
          dial 'test',
          info('First', '', ''),
          info('Second', 'First', ''),
          info('First', 'First', ''),
        },
      },
    }
    expect(dialogue.finalizedOrder(replay.dialogues.test)).toEqual { 'first', 'second' }
  end)

  suite.it('erases a deleted topic and keeps adding to the one before it', function()
    local deleted = dial 'Gone'
    deleted.flags = 'DELETED'
    local replay = dialogue.replay {
      {
        name = 'test',
        records = { header(), dial 'Kept', info('A', '', ''), deleted, info('B', 'A', '') },
      },
    }
    expect(replay.dialogues.gone).toBeNil()
    expect(dialogue.finalizedOrder(replay.dialogues.kept)).toEqual { 'a', 'b' }
  end)
end)

suite.describe('split', function()
  suite.it('demotes candidates to a fixed point when what they need is content', function()
    local records = {
      header(),
      { type = 'Script', flags = '', id = 'BagScript', text = '' },
      misc('Bag', 'BagScript'),
      { type = 'Container', flags = '', id = 'Crate', script = '', inventory = { { 1, 'Bag' } } },
      { type = 'Static', flags = '', id = 'Rock' },
    }
    local data, demotions = starwind.split.choose(records)
    expect(data[4]).toBe(true)
    expect(data[2]).toBeNil()
    expect(data[3]).toBeNil()
    expect(#demotions).toBe(2)
  end)
end)

return suite
