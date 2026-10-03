--!strict
--!native
-- Saves and load orders built from bytes for dream.saves' suites: the synthetic saves and
-- scenarios jess's CLI save tests (`libs/cli/tests/common/mod.rs`, `save.rs`, `save_strip.rs`)
-- write, spelled the same way.

local plugins = require './../tes3cmd/fixtures'

local record, subrecord, u32 = plugins.record, plugins.subrecord, plugins.u32

local function i32(value: number): string return string.pack('<i4', value) end

local function f32(value: number): string return string.pack('<f', value) end

local function form(version: number): string return subrecord('FORM', u32(version)) end

local function sized(text: string): string return u32(#text) .. text end

local function variableHedr(count: number): string
  return subrecord('HEDR', f32(1.3) .. u32(0) .. sized '' .. sized '' .. u32(count))
end

local CurrentFormatVersion = 40

--- A synthetic OpenMW save (`synthetic_openmw_save_with_version_dependencies_and_header_masters`).
local function save(dependencies: { string }?, version: number?, headerMasters: boolean?): string
  local names = dependencies or { 'Morrowind.esm' }
  local tes3 = { form(version or CurrentFormatVersion), variableHedr(1) }
  if headerMasters then
    for _, name in names do
      table.insert(tes3, plugins.masterEntry(name, 0))
    end
  end

  local fields = {
    subrecord('PLNA', 'Tester'),
    subrecord('PLLE', i32(1)),
    subrecord('PLCL', '\2Archer'),
    subrecord('PLCN', 'Pilgrim'),
    subrecord('PLCE', 'Seyda Neen'),
    subrecord('TSTM', f32(8.5) .. i32(18) .. i32(7) .. i32(427)),
    subrecord('TIME', string.pack('<d', 12.5)),
    subrecord('DESC', 'synthetic'),
  }

  for _, name in names do
    table.insert(fields, subrecord('DEPE', name .. '\0'))
  end

  table.insert(fields, subrecord('SCRN', '\255\216\255\217'))
  table.insert(fields, subrecord('CDAY', i32(3)))
  table.insert(fields, subrecord('CHLT', f32(42)))
  table.insert(fields, subrecord('MHLT', f32(100)))
  return record('TES3', table.concat(tes3)) .. record('SAVE', table.concat(fields))
end

local function refId(value: string): string return '\2' .. value end

local function formId(index: number, contentFile: number): string
  return u32(index) .. i32(contentFile)
end

local function luaObject(index: number, contentFile: number): string
  return '\0' .. string.char(0x80 + bit32.lshift(8, 3)) .. 'o' .. formId(index, contentFile)
end

local function luaObjectList(refs: { { number } }): string
  local parts = { '\0', string.char(0x40 + 6), u32(#refs * 8), 'objlist' }
  for _, ref in refs do
    table.insert(parts, formId(ref[1], ref[2]))
  end

  return table.concat(parts)
end

local function luaCustom(name: string, data: string): string
  return '\0' .. string.char(0x80 + bit32.lshift(#data, 3) + #name - 1) .. name .. data
end

local function contentPlugin(master: string, records: { string }?): string
  return plugins.plugin(records or {}, { { name = master, size = 1 } })
end

local function named(tag: string, id: string): string return record(tag, subrecord('NAME', id)) end

export type Operation = {
  kind: 'check' | 'strip',
  dependencies: { string }?,
  mode: ('dryRun' | 'inMemory')?,
  sampleLimit: number?,
  --- Without the scenario's config.
  noConfig: boolean?,
}

export type Scenario = {
  name: string,
  save: string,
  --- Files in the data folder, by name.
  files: { [string]: string },
  --- More openmw.cfg lines after `data=`.
  config: string?,
  operations: { Operation },
}

local function strips(dependencies: { string }, extra: { Operation }?): { Operation }
  local out: { Operation } =
    { { kind = 'check' } :: Operation, { kind = 'check', noConfig = true } :: Operation }
  for _, dependency in dependencies do
    out[#out + 1] = { kind = 'strip', dependencies = { dependency }, mode = 'dryRun' } :: Operation
    out[#out + 1] = {
      kind = 'strip',
      dependencies = { dependency },
      mode = 'inMemory',
      sampleLimit = 20,
    } :: Operation
  end

  for _, operation in extra or {} do
    table.insert(out, operation)
  end

  return out
end

local function keptBroken(): { [string]: string }
  return {
    ['Morrowind.esm'] = contentPlugin 'Master.esm',
    ['Tribunal.esm'] = contentPlugin('Morrowind.esm', {
      named('NPC_', 'target_owner'),
      named('FACT', 'target_faction'),
      named('MISC', 'target_key'),
      named('SPEL', 'target_trap'),
      named('GLOB', 'target_global'),
      named('CELL', 'target_cell'),
      named('BSGN', 'target_sign'),
    }),
  }
end

local function chest(): string
  return record(
    'CSTA',
    table.concat {
      subrecord('NAME', refId 'base_cell'),
      subrecord('OBJE', u32(0)),
      subrecord('FRMR', formId(1, 0)),
      subrecord('NAME', refId 'base_chest'),
      subrecord('ANAM', refId 'target_owner'),
      subrecord('BNAM', 'target_global'),
      subrecord('CNAM', refId 'target_faction'),
      subrecord('INDX', i32(2)),
      subrecord('FLTV', i32(50)),
      subrecord('KNAM', refId 'target_key'),
      subrecord('TNAM', refId 'target_trap'),
      subrecord('AIPK', 'WAND'),
      subrecord('DATA', string.rep('\0', 14)),
      subrecord('AIPK', 'ESCO'),
      subrecord('CELL', 'target_cell'),
      subrecord('AIPK', 'FOLL'),
      subrecord('TARG', refId 'target_owner'),
      subrecord('TAID', formId(5, 0)),
      subrecord('LAST', i32(-1)),
    }
  )
end

local morrowindSave: () -> string

--- Every scenario, in a stable order.
local function scenarios(): { Scenario }
  local base = { ['Morrowind.esm'] = contentPlugin 'Master.esm' }
  local two = { 'Morrowind.esm', 'Tribunal.esm' }
  local three = { 'Morrowind.esm', 'Tribunal.esm', 'Bloodmoon.esm' }
  local function withTribunal(records: { string }): { [string]: string }
    return {
      ['Morrowind.esm'] = contentPlugin 'Master.esm',
      ['Tribunal.esm'] = contentPlugin('Morrowind.esm', records),
    }
  end

  local list: { Scenario } = {}
  local function add(
    name: string,
    bytes: string,
    files: { [string]: string },
    operations: { Operation },
    config: string?
  )
    table.insert(
      list,
      { name = name, save = bytes, files = files, operations = operations, config = config }
    )
  end

  add('plain', save(), base, strips { 'Morrowind.esm' })
  add(
    'target-global',
    save(two) .. record('GLOB', subrecord('NAME', refId 'DBAttack')),
    withTribunal {
      named('GLOB', 'DBAttack'),
    },
    strips { 'Tribunal.esm' }
  )
  add('cell-state', save(two) .. record(
    'CSTA',
    table.concat {
      subrecord('NAME', refId 'target_cell'),
      subrecord('DATA', string.rep('\0', 24)),
      subrecord('OBJE', 'STAT'),
      subrecord('FRMR', formId(42, 1)),
      subrecord('NAME', refId 'target_static'),
      subrecord('ICNT', u32(1)),
      subrecord('FRMR', formId(7, -1)),
      subrecord('NAME', refId 'target_inventory_item'),
      subrecord('MVRF', formId(77, 1)),
      subrecord('NAME', refId 'target_cell'),
    }
  ), withTribunal { named('CELL', 'target_cell') }, strips { 'Tribunal.esm' })
  for _, version in { 36, 37, CurrentFormatVersion + 1 } do
    add(`format-{version}`, save(nil, version), base, strips { 'Morrowind.esm' })
  end

  add(
    'script-lists',
    save { 'builtin.omwscripts', 'Morrowind.esm', 'Mod.omwscripts', 'Tribunal.esm' },
    {
      ['Morrowind.esm'] = contentPlugin 'Master.esm',
      ['Mod.omwscripts'] = 'PLAYER: scripts/mod/player.lua\n',
      ['Tribunal.esm'] = contentPlugin 'Morrowind.esm',
    },
    strips { 'Tribunal.esm', 'Mod.omwscripts' }
  )
  local broken = record('TES3', plugins.hedr(1)) .. 'STAT' .. u32(100) .. string.rep('\0', 8)
  add('unreadable', save { 'Morrowind.esm', 'Tribunal.esm', 'Broken.esp' }, {
    ['Morrowind.esm'] = contentPlugin 'Master.esm',
    ['Tribunal.esm'] = contentPlugin 'Morrowind.esm',
    ['Broken.esp'] = broken,
  }, strips { 'Tribunal.esm', 'Broken.esp' })

  local library = {
    ['Morrowind.esm'] = contentPlugin 'Master.esm',
    ['Library.esm'] = contentPlugin 'Morrowind.esm',
    ['Patch.esp'] = contentPlugin 'Library.esm',
    ['Other.esp'] = contentPlugin 'Morrowind.esm',
  }
  local four = { 'Morrowind.esm', 'Library.esm', 'Patch.esp', 'Other.esp' }
  add(
    'dependents',
    save(four),
    library,
    strips({ 'Library.esm', 'Patch.esp' }, {
      { kind = 'strip', dependencies = { 'Library.esm', 'Patch.esp' }, mode = 'inMemory' },
      { kind = 'strip', dependencies = { 'Library.esm', 'Patch.esp' }, mode = 'dryRun' },
    })
  )
  add(
    'several',
    save(four, nil, true),
    library,
    strips({}, {
      { kind = 'strip', dependencies = { 'Library.esm', 'Patch.esp' }, mode = 'inMemory' },
      { kind = 'strip', dependencies = { 'Other.esp', 'Morrowind.esm' }, mode = 'dryRun' },
    })
  )
  add(
    'projectile-in-place',
    save(three, nil, true) .. record('PROJ', subrecord('ACTO', formId(42, 0))),
    {
      ['Morrowind.esm'] = contentPlugin 'Master.esm',
      ['Tribunal.esm'] = contentPlugin 'Morrowind.esm',
      ['Bloodmoon.esm'] = contentPlugin 'Morrowind.esm',
    },
    strips { 'Bloodmoon.esm', 'Tribunal.esm', 'Morrowind.esm' }
  )
  local csta = record(
    'CSTA',
    subrecord('OBJE', u32(0))
      .. subrecord('FRMR', formId(1, -1))
      .. subrecord('NAME', refId 'target_misc')
  )
  add(
    'resolution',
    save() .. csta,
    {
      ['Morrowind.esm'] = contentPlugin(
        'Master.esm',
        { named('STAT', 'target_static'), named('MISC', 'target_misc') }
      ),
    },

    strips({ 'Morrowind.esm' }, {
      { kind = 'strip', dependencies = { 'Morrowind.esm' }, mode = 'dryRun', noConfig = true },
      { kind = 'strip', dependencies = { 'Morrowind.esm' }, mode = 'dryRun', sampleLimit = 1 },
    })
  )
  add(
    'typed-refids',
    save(two)
      .. record('NPC_', subrecord('NAME', refId 'db_assassin1b'))
      .. record('GSCR', subrecord('NAME', refId 'dbattackScript'))
      .. record('GLOB', subrecord('NAME', refId 'DBAttack')),
    withTribunal {
      named('NPC_', 'db_assassin1b'),
      record(
        'SCPT',
        subrecord('SCHD', plugins.fixed('dbattackScript', 32) .. string.rep('\0', 20))
      ),
      named('GLOB', 'DBAttack'),
    },
    strips { 'Tribunal.esm' }
  )
  add(
    'spell-state',
    save(two)
      .. record(
        'SPLM',
        table.concat {
          subrecord('SPEL', refId 'base_spell'),
          subrecord('SPEL', refId 'target_spell'),
          subrecord('USED', refId 'target_power'),
          subrecord('TIME', string.rep('\0', 12)),
          subrecord('SLCT', refId 'target_selected'),
        }
      )
      .. record(
        'ACTS',
        subrecord('SPID', refId 'target_active') .. subrecord('MGEF', refId 'target_effect')
      )
      .. record(
        'GSCR',
        subrecord('NAME', refId 'base_script') .. subrecord('TARG', refId 'target_npc')
      ),
    withTribunal {
      named('SPEL', 'target_spell'),
      named('SPEL', 'target_power'),
      named('SPEL', 'target_selected'),
      named('SPEL', 'target_active'),
      named('MGEF', 'target_effect'),
      named('NPC_', 'target_npc'),
    },
    strips { 'Tribunal.esm' }
  )
  add(
    'overrides',
    save(two)
      .. (string.gsub(csta, 'target_misc', 'shared_item'))
      .. record('NPC_', subrecord('NAME', refId 'db_assassin1b')),
    {
      ['Morrowind.esm'] = contentPlugin('Master.esm', { named('MISC', 'shared_item') }),
      ['Tribunal.esm'] = contentPlugin(
        'Morrowind.esm',
        { named('MISC', 'shared_item'), named('NPC_', 'db_assassin1b') }
      ),
    },
    strips { 'Tribunal.esm' }
  )
  add(
    'risky-lua',
    save()
      .. record('LUAM', subrecord('LUAD', '\1'))
      .. record('LUAM', subrecord('LUAD', '\1'))
      .. record('LUAM', subrecord('LUAD', luaCustom('x', '\1\2\3'))),
    base,
    strips { 'Morrowind.esm' }
  )
  add(
    'player',
    save(two)
      .. record('NPC_', subrecord('NAME', refId 'player'))
      .. record('NPC_', subrecord('NAME', refId 'db_assassin1b')),
    {
      ['Morrowind.esm'] = contentPlugin('Master.esm', { named('NPC_', 'player') }),
      ['Tribunal.esm'] = contentPlugin(
        'Morrowind.esm',
        { named('NPC_', 'player'), named('NPC_', 'db_assassin1b') }
      ),
    },
    strips { 'Tribunal.esm' }
  )
  add(
    'builtin-scripts',
    save { 'builtin.omwscripts', 'Morrowind.esm', 'Tribunal.esm' }
      .. record('NPC_', subrecord('NAME', refId 'db_assassin1b')),
    withTribunal { named('NPC_', 'db_assassin1b') },
    strips { 'Tribunal.esm' }
  )
  add(
    'inventory',
    save(two)
      .. record(
        'PLAY',
        subrecord('ICNT', u32(1))
          .. subrecord('FRMR', formId(1, -1))
          .. subrecord('NAME', refId 'target_misc')
      ),
    withTribunal { named('MISC', 'target_misc') },
    strips { 'Tribunal.esm' }
  )
  add('inventory-before-reference', save(two) .. record(
    'CSTA',
    table.concat {
      subrecord('OBJE', 'CREA'),
      subrecord('FRMR', formId(10, 0)),
      subrecord('NAME', refId 'base_crea'),
      subrecord('ICNT', u32(1)),
      subrecord('FRMR', formId(99, -1)),
      subrecord('NAME', refId 'target_misc'),
      subrecord('OBJE', 'CREA'),
      subrecord('FRMR', formId(20, 1)),
      subrecord('NAME', refId 'target_crea'),
    }
  ), {
    ['Morrowind.esm'] = contentPlugin('Master.esm', { named('CREA', 'base_crea') }),
    ['Tribunal.esm'] = contentPlugin(
      'Morrowind.esm',
      { named('MISC', 'target_misc'), named('CREA', 'target_crea') }
    ),
  }, strips { 'Tribunal.esm' })
  add(
    'stolen-and-markers',
    save(two)
      .. record(
        'STLN',
        subrecord('NAME', refId 'target_misc')
          .. subrecord('ONAM', refId 'owner')
          .. subrecord('COUN', i32(1))
      )
      .. record(
        'MARK',
        subrecord('POSX', f32(1))
          .. subrecord('POSY', f32(2))
          .. subrecord('NAME', refId 'target_cell')
      ),
    withTribunal { named('MISC', 'target_misc'), named('CELL', 'target_cell') },
    strips { 'Tribunal.esm' }
  )
  add(
    'content-file-refnums',
    save(three, nil, true)
      .. record(
        'CSTA',
        table.concat {
          subrecord('OBJE', u32(0)),
          subrecord('FRMR', formId(42, 1)),
          subrecord('NAME', refId 'db_assassin1b'),
          subrecord('MVRF', formId(77, 1)),
          subrecord('NAME', refId 'target_cell'),
        }
      )
      .. record(
        'PROJ',
        subrecord('ID__', refId 'unrelated_arrow') .. subrecord('ACTO', formId(99, 2))
      ),
    withTribunal { named('NPC_', 'db_assassin1b') },
    strips { 'Tribunal.esm' }
  )
  add(
    'lua-refnums',
    save(three)
      .. record('LUAM', subrecord('FRMR', formId(41, 1)) .. subrecord('LUAD', luaObject(42, 1)))
      .. record('LUAM', subrecord('LUAD', luaObjectList { { 7, 0 }, { 8, 2 }, { 9, 2 } })),
    {
      ['Morrowind.esm'] = contentPlugin 'Master.esm',
      ['Tribunal.esm'] = contentPlugin 'Morrowind.esm',
      ['Bloodmoon.esm'] = contentPlugin 'Morrowind.esm',
    },
    strips { 'Tribunal.esm', 'Bloodmoon.esm' }
  )
  add(
    'projectiles',
    save(two)
      .. record(
        'PROJ',
        subrecord('ID__', refId 'target_arrow')
          .. subrecord('ACTO', formId(100, 1))
          .. subrecord('BOW_', refId 'target_bow')
      )
      .. record(
        'MPRJ',
        table.concat {
          subrecord('ID__', refId 'target_magic'),
          subrecord('ACTO', formId(101, 1)),
          subrecord('SPEL', refId 'target_spell'),
          subrecord('ITEM', formId(102, 1)),
        }
      ),
    withTribunal {
      named('WEAP', 'target_arrow'),
      named('WEAP', 'target_bow'),
      named('MGEF', 'target_magic'),
      named('SPEL', 'target_spell'),
    },
    strips { 'Tribunal.esm' }
  )
  local fargoth = '\2fargoth'
  add(
    'source-backed-refnums',
    save(three)
      .. record('GSCR', subrecord('FRMR', formId(10, 1)) .. subrecord('FRMR', formId(11, 2)))
      .. record(
        'ACTS',
        table.concat {
          subrecord('CAST', formId(20, 1)),
          subrecord('CAST', formId(21, 2)),
          subrecord('ITEM', formId(30, 1)),
          subrecord('ITEM', formId(31, 2)),
          subrecord('SUM_', formId(40, 1)),
          subrecord('SUM_', formId(41, 2)),
        }
      )
      .. record(
        'CREA',
        table.concat {
          subrecord('ACID', formId(50, 1)),
          subrecord('ACID', formId(51, 2)),
          subrecord('SPAW', formId(60, 1)),
          subrecord('SPAW', formId(61, 2)),
        }
      )
      .. record(
        'AI__',
        table.concat {
          subrecord('TAID', formId(70, 1)),
          subrecord('TAID', formId(71, 2)),
          subrecord('AIPK', 'COMB'),
          subrecord('TARG', formId(80, 1)),
          subrecord('TARG', formId(81, 2)),
        }
      )
      .. record(
        'CREA',
        table.concat {
          subrecord('AIPK', 'ESCO'),
          subrecord('TARG', fargoth),
          subrecord('TAID', formId(70, 2)),
          subrecord('AIPK', 'ACTI'),
          subrecord('TARG', fargoth),
          subrecord('AIPK', 'PURS'),
          subrecord('TARG', formId(80, 2)),
        }
      )
      .. record('GSCR', subrecord('NAME', '\2main') .. subrecord('TARG', fargoth)),
    {
      ['Morrowind.esm'] = contentPlugin 'Master.esm',
      ['Tribunal.esm'] = contentPlugin 'Morrowind.esm',
      ['Bloodmoon.esm'] = contentPlugin 'Morrowind.esm',
    },
    strips { 'Tribunal.esm' }
  )
  local door = record(
    'CSTA',
    table.concat {
      subrecord('NAME', refId 'base_cell'),
      subrecord('OBJE', u32(0)),
      subrecord('FRMR', formId(1, 0)),
      subrecord('NAME', refId 'base_door'),
      subrecord('DNAM', 'target_cell'),
      subrecord('FLTV', i32(2147483647)),
      subrecord('KNAM', refId 'target_key'),
    }
  )
  add(
    'unfixable',
    save(two) .. door .. record('PLAY', subrecord('SIGN', refId 'target_sign')),
    keptBroken(),
    strips { 'Tribunal.esm' }
  )
  add('fixable', save(two) .. chest(), keptBroken(), strips { 'Tribunal.esm' })
  local uninstalled = keptBroken()
  uninstalled['Tribunal.esm'] = nil
  uninstalled['Morrowind.esm'] = contentPlugin('Master.esm', {
    named('CELL', 'base_cell'),
    named('CONT', 'base_chest'),
    named('DOOR', 'base_door'),
  })
  add('uninstalled', save(two) .. chest() .. record(
    'CSTA',
    table.concat {
      subrecord('NAME', refId 'base_cell'),
      subrecord('OBJE', u32(0)),
      subrecord('FRMR', formId(7, 1)),
      subrecord('NAME', refId 'base_door'),
    }
  ), uninstalled, strips { 'Tribunal.esm' })
  add(
    'uninstalled-blocked',
    save(two) .. record('PLAY', subrecord('SIGN', refId 'target_sign')),
    uninstalled,
    strips({ 'Tribunal.esm' }, {
      { kind = 'strip', dependencies = { 'Tribunal.esm' }, mode = 'dryRun', noConfig = true },
      {
        kind = 'strip',
        dependencies = { 'Tribunal.esm', 'Morrowind.esm' },
        mode = 'dryRun',
        noConfig = true,
      },
    })
  )
  local equipment = u32(3) .. u32(0) .. u32(1) .. u32(1) .. u32(2) .. u32(2) .. u32(5)
  add('equipment', save(two, nil, true) .. record(
    'PLAY',
    table.concat {
      subrecord('ICNT', u32(3)),
      subrecord('FRMR', formId(1, -1)),
      subrecord('NAME', refId 'iron_helmet'),
      subrecord('FRMR', formId(2, -1)),
      subrecord('NAME', refId 'tribunal_ring'),
      subrecord('FRMR', formId(3, -1)),
      subrecord('NAME', refId 'steel_boots'),
      subrecord('EQIP', equipment),
      subrecord('SELE', i32(2)),
    }
  ), withTribunal { named('MISC', 'tribunal_ring') }, strips { 'Tribunal.esm' })
  for _, encoding in { 'win1251', 'win1252' } do
    add(
      `encoding-{encoding}`,
      save(),
      { ['Morrowind.esm'] = contentPlugin('Master.esm', { named('BSGN', '\192\232\241\242\0') }) },
      strips { 'Morrowind.esm' },
      `encoding={encoding}\n`
    )
  end

  add(
    'check-missing',
    save { 'Morrowind.esm', 'Gone.esp', 'Tribunal.esm' }
      .. record(
        'PLAY',
        subrecord('SIGN', refId 'missing_sign') .. subrecord('NAME', refId 'missing_cell')
      )
      .. door,
    withTribunal {},
    { { kind = 'check' }, { kind = 'check', noConfig = true } },
    'content=Morrowind.esm\ncontent=Tribunal.esm\n'
  )
  add(
    'check-order',
    save { 'Morrowind.esm', 'Tribunal.esm' },
    withTribunal {},
    { { kind = 'check' } },
    'content=Tribunal.esm\ncontent=Morrowind.esm\n'
  )
  add(
    'check-what-breaks',
    save { 'Morrowind.esm', 'Gone.esp', 'Unticked.esp' }
      .. record('SPEL', subrecord('NAME', refId 'player_made_spell'))
      .. record(
        'SPLM',
        subrecord('SPEL', refId 'kept_spell')
          .. subrecord('SPEL', refId 'player_made_spell')
          .. subrecord('SPEL', refId 'gone_spell')
      )
      .. record(
        'CSTA',
        table.concat {
          subrecord('NAME', refId 'base_cell'),
          subrecord('OBJE', u32(0)),
          subrecord('FRMR', formId(1, 0)),
          subrecord('NAME', refId 'kept_spell'),
          subrecord('TNAM', refId 'gone_trap'),
        }
      )
      .. record('PLAY', subrecord('SIGN', refId 'gone_sign')),
    {
      ['Morrowind.esm'] = contentPlugin(
        'Master.esm',
        { named('SPEL', 'kept_spell'), named('CELL', 'base_cell') }
      ),
      ['Unticked.esp'] = contentPlugin 'Morrowind.esm',
    },
    strips { 'Gone.esp', 'Unticked.esp' },
    'content=Morrowind.esm\n'
  )
  add('player-record', save { 'Morrowind.esm', 'Races.esp' } .. record(
    'NPC_',
    table.concat {
      subrecord('NAME', refId 'player'),
      subrecord('RNAM', refId 'custom_race'),
      subrecord('CNAM', refId 'Warrior'),
      subrecord('BNAM', refId 'custom_head'),
    }
  ), {
    ['Morrowind.esm'] = contentPlugin('Master.esm', { named('CLAS', 'Warrior') }),
    ['Races.esp'] = contentPlugin(
      'Morrowind.esm',
      { named('RACE', 'custom_race'), named('BODY', 'custom_head') }
    ),
  }, strips { 'Races.esp' }, 'content=Morrowind.esm\n')
  add(
    'dangling-mvrf',
    save() .. record('CSTA', subrecord('MVRF', formId(42, 0))),
    base,
    strips { 'Morrowind.esm' }
  )
  add(
    'incomplete-csta',
    save() .. record('CSTA', subrecord('OBJE', u32(0)) .. subrecord('FRMR', formId(42, 0))),
    base,
    strips { 'Morrowind.esm' }
  )
  add('morrowind', morrowindSave(), base, strips { 'Morrowind.esm' })
  return list
end

--- A small Morrowind (`.ess`) save: a header with a master, game data, and a screenshot, the date
--- globals, and the player's NPC_ record.
morrowindSave = function(): string
  local hedr = f32(1.3)
    .. u32(32)
    .. plugins.fixed('', 32)
    .. plugins.fixed('Quicksave', 256)
    .. u32(4)
  local gmdt = f32(30)
    .. f32(50)
    .. f32(9.25)
    .. string.rep('\0', 12)
    .. plugins.fixed('Balmora', 64)
    .. string.rep('\0', 4)
    .. plugins.fixed('Nerevar', 32)
  local header = subrecord('HEDR', hedr)
    .. plugins.masterEntry('Morrowind.esm', 79837557)
    .. subrecord('GMDT', gmdt)
    .. subrecord('SCRD', string.rep('\0', 20))
    .. subrecord('SCRS', string.rep('\9', 128 * 128 * 4))
  local function global(name: string, value: number): string
    return record(
      'GLOB',
      subrecord('NAME', name .. '\0') .. subrecord('FNAM', 's') .. subrecord('FLTV', f32(value))
    )
  end

  local npdt = string.pack('<i2', 7) .. string.rep('\0', 10)
  local player = record(
    'NPC_',
    table.concat {
      subrecord('NAME', 'player\0'),
      subrecord('FNAM', 'Nerevar\0'),
      subrecord('RNAM', 'Dark Elf\0'),
      subrecord('CNAM', 'Battlemage\0'),
      subrecord('ANAM', '\0'),
      subrecord('BNAM', 'b_n_dark elf_m_head_01\0'),
      subrecord('KNAM', 'b_n_dark elf_m_hair_01\0'),
      subrecord('NPDT', npdt),
      subrecord('FLAG', u32(0x18)),
    }
  )
  return record('TES3', header)
    .. global('Day', 3)
    .. global('Month', 1)
    .. global('Year', 427)
    .. player
end

return table.freeze {
  CurrentFormatVersion = CurrentFormatVersion,
  formId = formId,
  luaCustom = luaCustom,
  luaObject = luaObject,
  luaObjectList = luaObjectList,
  morrowindSave = morrowindSave,
  refId = refId,
  save = save,
  scenarios = scenarios,
}
