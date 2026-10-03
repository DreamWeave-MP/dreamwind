--!strict
--!native
-- dream.tes3's own cases: jess-plugin's raw spine tests and jess-omwaddon's codec edges, on bytes
-- built here, so the suite needs nothing but the package.
local tes3 = require '@dreamwind/tes3'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

local function u32(value: number): string return string.pack('<I4', value) end

local function subrecord(tag: string, payload: string): string
  return tag .. u32(#payload) .. payload
end

local function record(tag: string, payload: string, flags: number?): string
  return tag .. u32(#payload) .. u32(0) .. u32(flags or 0) .. payload
end

local function fixed(text: string, n: number): string return text .. string.rep('\0', n - #text) end

local function hedr(
  fileType: number,
  author: string,
  description: string,
  count: number
): string
  return subrecord(
    'HEDR',
    string.pack('<f', 1.3)
      .. u32(fileType)
      .. fixed(author, 32)
      .. fixed(description, 256)
      .. u32(count)
  )
end

local function variableHedr(
  fileType: number,
  author: string,
  description: string,
  count: number
): string
  return subrecord(
    'HEDR',
    string.pack('<f', 1.3)
      .. u32(fileType)
      .. u32(#author)
      .. author
      .. u32(#description)
      .. description
      .. u32(count)
  )
end

local function nam0(count: number): string return subrecord('NAM0', u32(count)) end

local function open(bytes: string, options: tes3.OpenOptions?): tes3.Plugin
  return tes3.open(bytes, options)
end

local function saved(plugin: tes3.Plugin): string return buffer.tostring(plugin:save()) end

local function tags(plugin: tes3.Plugin, index: number): { string }
  local out = {}
  for _, sub in plugin:subrecords(index) do
    table.insert(out, sub.tag)
  end

  return out
end

suite.describe('framing', function()
  suite.it('keeps unknown records and subrecords byte for byte', function()
    local bytes = record('ZZZZ', subrecord('ABCD', 'payload') .. subrecord('WXYZ', '\0\1\2\3'))
    local plugin = open(bytes)
    expect(saved(plugin)).toBe(bytes)
    expect(plugin:tag(0)).toBe 'ZZZZ'
    expect(tags(plugin, 0)).toEqual { 'ABCD', 'WXYZ' }
  end)

  suite.it('rejects a truncated record at its offset', function()
    expect(function() open 'TES3' end).toThrow 'truncated record header at offset 0'
  end)

  suite.it('rejects a truncated subrecord at its offset', function()
    expect(function() open(record('TES3', 'NAME')) end).toThrow 'truncated subrecord header at offset 16'
  end)

  suite.it('rejects a subrecord past its record', function()
    expect(function() open(record('TES3', 'NAME' .. u32(9) .. 'abc')) end).toThrow 'subrecord NAME extends past record payload at offset 16'
  end)

  suite.it('rejects a record past the end of the file', function()
    expect(function() open('STAT' .. u32(100) .. u32(0) .. u32(0)) end).toThrow 'record STAT extends past end of file at offset 0'
  end)

  suite.it('skips what a filter leaves out, and ends at a skipped record past the end', function()
    local bytes = record('STAT', subrecord('NAME', 'a')) .. record('BOOK', subrecord('NAME', 'b'))
    local plugin = open(bytes, {
      keep = function(tag) return if tag == 'BOOK' then 'skip' else 'whole' end,
    })
    expect(plugin:count()).toBe(1)
    expect(saved(plugin)).toBe(record('STAT', subrecord('NAME', 'a')))
    local truncated = open(record('STAT', '') .. 'BOOK' .. u32(100) .. u32(0) .. u32(0), {
      keep = function(tag) return if tag == 'BOOK' then 'skip' else 'whole' end,
    })
    expect(truncated:count()).toBe(1)
  end)

  suite.it('keeps only the parts of a CELL a filter asks for', function()
    local header = subrecord('NAME', 'cell') .. subrecord('DATA', string.rep('\0', 12))
    local refs = subrecord('FRMR', u32(1))
      .. subrecord('NAME', 'ref')
      .. subrecord('DATA', string.rep('\0', 24))
    local bytes = record('CELL', header .. refs)
    local headerOnly = open(bytes, {
      keep = function() return { references = false } end,
    })
    expect(headerOnly:isPartial(0)).toBe(true)
    expect(headerOnly:keptParts(0)).toEqual { header = true, references = false }
    expect(tags(headerOnly, 0)).toEqual { 'NAME', 'DATA' }
    local refsOnly = open(bytes, {
      keep = function() return { header = false } end,
    })
    expect(tags(refsOnly, 0)).toEqual { 'FRMR', 'NAME', 'DATA' }
    expect(tes3.records.id(refsOnly, 0)).toBeNil()
    local whole = open(record('CELL', header), {
      keep = function() return { references = false } end,
    })
    expect(whole:isPartial(0)).toBe(false)
  end)
end)

suite.describe('editing', function()
  suite.it('rebuilds only the parent of a replaced subrecord', function()
    local bytes = record('ZZZZ', subrecord('ABCD', 'payload') .. subrecord('WXYZ', '\0\1\2\3'))
    local plugin = open(bytes)
    plugin:replaceSubrecord(0, 1, 'changed')
    local reopened = open(saved(plugin))
    expect(reopened:size(0)).toBe(30)
    expect(reopened:subrecords(0)[2].size).toBe(7)
  end)

  suite.it('deletes a record and keeps its neighbours', function()
    local first = record('AAAA', subrecord('NAME', 'first'))
    local third = record('CCCC', subrecord('NAME', 'third'))
    local plugin = open(first .. record('BBBB', subrecord('NAME', 'second')) .. third)
    plugin:delete(1)
    expect(saved(plugin)).toBe(first .. third)
  end)

  suite.it('deletes subrecords in one rebuild', function()
    local first, fourth = subrecord('KEEP', 'one'), subrecord('KEEP', 'four')
    local next = record('NEXT', subrecord('NAME', 'next'))
    local plugin = open(
      record('TEST', first .. subrecord('DROP', 'two') .. subrecord('DROP', 'three') .. fourth)
        .. next
    )
    expect(plugin:deleteSubrecords(0, { 2, 1, 2 })).toBe(2)
    expect(saved(plugin)).toBe(record('TEST', first .. fourth) .. next)
    expect(function() plugin:deleteSubrecords(0, { 5 }) end).toThrow 'subrecord index 5 out of bounds'
  end)

  suite.it('deletes subrecords by tag', function()
    local plugin = open(
      record(
        'TEST',
        subrecord('NAME', 'id') .. subrecord('FNAM', 'display') .. subrecord('FNAM', 'other')
      )
    )
    expect(plugin:deleteSubrecordsByTag(0, 'FNAM')).toBe(2)
    expect(tags(open(saved(plugin)), 0)).toEqual { 'NAME' }
  end)

  suite.it('inserts records where asked and keeps the rest', function()
    local first = record('AAAA', subrecord('NAME', 'first'))
    local second = record('BBBB', subrecord('NAME', 'second'))
    local plugin = open(first .. second)
    local inserted = record('NEWW', subrecord('NAME', 'new'))
    plugin:insert(1, inserted)
    expect(saved(plugin)).toBe(first .. inserted .. second)
    expect(plugin:isDirty(1)).toBe(true)
    expect(function() plugin:insert(1, 'NEWW' .. u32(9) .. u32(0) .. u32(0)) end).toThrow 'record NEWW size doesn\'t match its bytes at offset 4'
  end)

  suite.it('replaces a record with new bytes of the same tag', function()
    local plugin = open(record('AAAA', subrecord('NAME', 'first')))
    plugin:replaceBytes(0, record('AAAA', subrecord('NAME', 'other'), 0x400))
    expect(saved(plugin)).toBe(record('AAAA', subrecord('NAME', 'other'), 0x400))
    expect(function() plugin:replaceBytes(0, record('BBBB', '')) end).toThrow 'different tag'
  end)

  suite.it('keeps deleted subrecords deleted through later edits', function()
    local plugin = open(
      record('TEST', subrecord('KEEP', 'a') .. subrecord('DROP', 'b') .. subrecord('LAST', 'c'))
    )
    plugin:deleteSubrecord(0, 1)
    plugin:replaceSubrecord(0, 1, 'changed')
    expect(saved(plugin)).toBe(
      record('TEST', subrecord('KEEP', 'a') .. subrecord('LAST', 'changed'))
    )
  end)

  suite.it('retains the records a predicate keeps', function()
    local plugin = open(record('AAAA', '') .. record('BBBB', '') .. record('CCCC', ''))
    plugin:retain(function(index) return index ~= 1 end)
    expect(saved(plugin)).toBe(record('AAAA', '') .. record('CCCC', ''))
  end)
end)

suite.describe('the TES3 header', function()
  suite.it('reads and updates the record count', function()
    local plugin = open(
      record('TES3', hedr(0, 'me', 'desc', 999)) .. record('STAT', subrecord('NAME', 'marker'))
    )
    local header = plugin:header()
    expect(header.author).toBe 'me'
    expect(header.description).toBe 'desc'
    expect(header.recordCount).toBe(999)
    expect(plugin:updateRecordCount()).toBe(true)
    expect(open(saved(plugin)):header().recordCount).toBe(1)
    expect(plugin:updateRecordCount()).toBe(false)
  end)

  suite.it('reads an absent FORM as version 0 and refuses a malformed one', function()
    expect(open(record('TES3', hedr(0, 'me', 'desc', 0))):formatVersion()).toBe(0)
    local bad = open(record('TES3', subrecord('FORM', '\1\2\3')))
    expect(function() bad:formatVersion() end).toThrow 'FORM payload is not 4 bytes at offset 24'
  end)

  suite.it('reads size-prefixed header strings after FORM 23', function()
    local plugin = open(
      record('TES3', subrecord('FORM', u32(34)) .. variableHedr(0, 'me', 'desc', 2))
        .. record('STAT', subrecord('NAME', 'marker'))
    )
    expect(plugin:formatVersion()).toBe(34)
    expect(plugin:header().author).toBe 'me'
    expect(plugin:header().recordCount).toBe(2)
    expect(plugin:updateRecordCount()).toBe(true)
    expect(open(saved(plugin)):header().recordCount).toBe(1)
    expect(function() plugin:setAuthor 'x' end).toThrow 'variable-size HEDR author strings'
  end)

  suite.it('sets the file type, author, and description', function()
    local plugin = open(record('TES3', hedr(0, 'me', 'first', 0)))
    expect(plugin:header().fileType).toBe 'plugin'
    expect(plugin:setFileType 'master').toBe(true)
    expect(plugin:setAuthor '+ and you').toBe(true)
    expect(plugin:setDescription '+\\nsecond').toBe(true)
    local header = open(saved(plugin)):header()
    expect(header.fileType).toBe 'master'
    expect(header.author).toBe 'me and you'
    expect(header.description).toBe 'first\nsecond'
    expect(plugin:setAuthor 'me and you').toBe(false)
  end)

  suite.it('refuses an author that doesn\'t fit, at its offset', function()
    local plugin = open(record('TES3', hedr(0, 'me', 'desc', 0)))
    expect(function() plugin:setAuthor 'abcdefghijklmnopqrstuvwxyzabcdefg' end).toThrow 'header string is too long for 32-byte field at offset 32'
  end)

  suite.it('refuses text the code page lacks, naming the character', function()
    local plugin = open(record('TES3', hedr(0, 'me', 'desc', 0)))
    expect(function() plugin:setAuthor 'Ж' end).toThrow 'TES3 HEDR author: \'Ж\' (U+0416) can\'t be written in Windows-1252, the plugin\'s encoding'
    local cyrillic = open(record('TES3', hedr(0, 'me', 'desc', 0)), { encoding = 'win1251' })
    expect(cyrillic:setAuthor 'Жук').toBe(true)
    expect(cyrillic:header().author).toBe 'Жук'
  end)

  suite.it('reads, sets, and syncs masters', function()
    local master = subrecord('MAST', 'Morrowind.esm\0')
      .. subrecord('DATA', string.pack('<I8', 79837557))
    local plugin = open(record('TES3', hedr(0, '', '', 0) .. master))
    expect(plugin:masters()).toEqual {
      { name = 'Morrowind.esm', size = 79837557, mast = 1, data = 2 },
    }
    expect(plugin:setMasterSize('MORROWIND.ESM', 1)).toBe(true)
    expect(plugin:masters()[1].size).toBe(1)
    expect(plugin:setMasters {
      { name = 'Morrowind.esm', size = 1 },
      { name = 'Tribunal.esm', size = 4565686 },
    }).toBe(true)
    expect(tags(plugin, 0)).toEqual { 'HEDR', 'MAST', 'DATA', 'MAST', 'DATA' }
    expect(plugin:masters()[2]).toEqual { name = 'Tribunal.esm', size = 4565686, mast = 3, data = 4 }
    local missing = open(record('TES3', hedr(0, '', '', 0) .. subrecord('MAST', 'a\0')))
    expect(function() missing:masters() end).toThrow 'TES3 MAST subrecord is missing following DATA'
  end)

  suite.it('builds an empty plugin', function()
    local plugin = tes3.new 'master'
    expect(plugin:header()).toEqual {
      version = string.unpack('<f', string.pack('<f', 1.3)),
      fileType = 'master',
      author = '',
      description = '',
      recordCount = 0,
    }
    expect(plugin:count()).toBe(1)
  end)
end)

suite.describe('CELL references', function()
  suite.it('groups references and saves unchanged', function()
    local bytes = record(
      'CELL',
      subrecord('NAME', 'cell')
        .. subrecord('DATA', string.rep('\0', 4))
        .. nam0(2)
        .. subrecord('FRMR', string.rep('\1', 4))
        .. subrecord('NAME', 'first_ref')
        .. subrecord('DATA', string.rep('\1', 24))
        .. subrecord('FRMR', string.rep('\2', 4))
        .. subrecord('NAME', 'second_ref')
        .. subrecord('DATA', string.rep('\2', 24))
    )
    local plugin = open(bytes)
    expect(plugin:cellGroups(0)).toEqual { header = 3, nam0 = 2, references = { { 3, 5 }, { 6, 8 } } }
    expect(saved(plugin)).toBe(bytes)
  end)

  suite.it('starts a moved reference at its MVRF and deletes it whole', function()
    local bytes = record(
      'CELL',
      subrecord('NAME', 'cell')
        .. subrecord('DATA', string.rep('\0', 12))
        .. subrecord('MVRF', string.rep('\1', 4))
        .. subrecord('CNDT', string.rep('\0', 8))
        .. subrecord('FRMR', string.rep('\1', 4))
        .. subrecord('NAME', 'moved_first')
        .. subrecord('FRMR', string.rep('\2', 4))
        .. subrecord('NAME', 'still')
        .. subrecord('MVRF', string.rep('\3', 4))
        .. subrecord('FRMR', string.rep('\3', 4))
        .. subrecord('NAME', 'moved_no_cndt')
        .. subrecord('MVRF', string.rep('\4', 4))
        .. subrecord('CNDT', string.rep('\0', 8))
        .. subrecord('FRMR', string.rep('\4', 4))
        .. subrecord('NAME', 'moved_last')
    )
    local plugin = open(bytes)
    expect((plugin:cellGroups(0) :: any).references).toEqual {
      { 2, 5 },
      { 6, 7 },
      { 8, 10 },
      { 11, 14 },
    }
    expect(plugin:deleteCellReferences(0, { 2 })).toBe(1)
    expect(tags(plugin, 0)).toEqual {
      'NAME',
      'DATA',
      'MVRF',
      'CNDT',
      'FRMR',
      'NAME',
      'FRMR',
      'NAME',
      'MVRF',
      'CNDT',
      'FRMR',
      'NAME',
    }
  end)

  suite.it('updates NAM0 when a reference goes', function()
    local bytes = record(
      'CELL',
      subrecord('NAME', 'cell')
        .. nam0(2)
        .. subrecord('FRMR', string.rep('\1', 4))
        .. subrecord('NAME', 'first_ref')
        .. subrecord('DATA', string.rep('\1', 24))
        .. subrecord('FRMR', string.rep('\2', 4))
        .. subrecord('NAME', 'second_ref')
        .. subrecord('DATA', string.rep('\2', 24))
    )
    local plugin = open(bytes)
    expect(plugin:deleteCellReferences(0, { 0 })).toBe(1)
    local reopened = open(saved(plugin))
    expect((reopened:cellGroups(0) :: any).references).toEqual { { 2, 4 } }
    local subs = reopened:subrecords(0)
    local source = reopened:span(0)
    expect(buffer.readu32(source, subs[2].payload)).toBe(1)
    expect(buffer.readstring(source, subs[4].payload, subs[4].size)).toBe 'second_ref'
  end)
end)

suite.describe('profiles', function()
  suite.it('flags OpenMW records for the vanilla profile only', function()
    local plugin =
      open(record('TES3', hedr(0, '', '', 1)) .. record('LUAL', subrecord('NAME', 'lua')))
    expect(plugin:validateProfile 'raw').toEqual {}
    expect(plugin:validateProfile 'tes3').toEqual {
      { offset = 324, message = 'LUAL is an OpenMW-only record type' },
    }
  end)

  suite.it('checks the structure every profile relies on', function()
    expect(open(''):validateProfile 'raw').toEqual {
      { offset = 0, message = 'the file has no records, not even a TES3 header' },
    }
    local second = open(record('TES3', hedr(0, '', '', 0)) .. record('TES3', hedr(0, '', '', 0)))
    expect(second:validateProfile 'raw').toEqual {
      { offset = 324, message = 'a second TES3 header' },
    }
  end)

  suite.it('flags what OpenMW refuses or skips', function()
    local plugin = open(
      record('TES3', hedr(0, '', '', 0))
        .. record('INFO', subrecord('INAM', 'a\0'))
        .. record('XXXX', '')
        .. record('DIAL', subrecord('NAME', 't\0'))
        .. record('INFO', subrecord('INAM', 'b\0'))
    )
    local messages = {}
    for _, diagnostic in plugin:validateProfile 'omwaddon' do
      table.insert(messages, diagnostic.message)
    end

    expect(messages).toEqual {
      'INFO has no DIAL before it; OpenMW skips it ("info record without dialog")',
      'XXXX isn\'t a record type OpenMW loads; it refuses the file ("Unknown record")',
    }
  end)
end)

suite.describe('typed records', function()
  suite.it('decodes into jess-omwaddon\'s shape', function()
    local bytes = record(
      'BOOK',
      subrecord('NAME', 'book\0')
        .. subrecord('BKDT', string.pack('<fIIiI', 1, 2, 1, 20, 3))
        .. subrecord('TEXT', 'text\0'),
      0x2000
    )
    local plugin = open(bytes)
    expect(plugin:decode(0)).toEqual {
      type = 'Book',
      flags = 'BLOCKED',
      id = 'book',
      name = '',
      script = '',
      mesh = '',
      icon = '',
      enchanting = '',
      text = 'text\0',
      data = { weight = 1, value = 2, bookType = 'Scroll', skill = 'Acrobatics', enchantment = 3 },
    }
    expect(buffer.tostring(plugin:encode(plugin:decode(0) :: tes3.Value))).toBe(bytes)
  end)

  suite.it('spells unknown flag bits in hex and unknown enum values as the default', function()
    local plugin = open(
      record(
        'LIGH',
        subrecord('NAME', 'l\0')
          .. subrecord('LHDT', string.pack('<fIiIBBBBI', 0, 0, 0, 0, 0, 0, 0, 0, 0x1003)),
        0x40
      )
    )
    local value = plugin:decode(0) :: any
    expect(value.flags).toBe '0x40'
    expect(value.data.flags).toBe 'DYNAMIC | CAN_CARRY | 0x1000'
    local book = open(record('BOOK', subrecord('BKDT', string.pack('<fIIiI', 0, 0, 7, 99, 0))))
    expect((book:decode(0) :: any).data.skill).toBe 'None'
    expect((book:decode(0) :: any).data.bookType).toBe 'Book'
  end)

  suite.it('fails where the Rust loader fails', function()
    local unknown = open(record('BOOK', subrecord('ZZZZ', '')))
    expect(function() unknown:decode(0) end).toThrow 'Unexpected Tag: BOOK::ZZZZ'
    local short = open(record('BOOK', subrecord('BKDT', 'short')))
    expect(function() short:decode(0) end).toThrow 'Unexpected Value'
    expect(open(record('ZZZZ', '')):decode(0)).toBeNil()
  end)

  suite.it('gives defaults for every record type', function()
    for _, spec in tes3.recordTypes do
      local value = tes3.default(spec.name) :: tes3.Value
      expect(value.type).toBe(spec.name)
      expect(tes3.default(spec.tag)).toEqual(value)
      local encoded = tes3.encode(value)
      expect(tes3.decode(encoded, 0, buffer.len(encoded), 'win1252')).toEqual(value)
    end
  end)

  suite.it('writes back only the subrecords an edit changed', function()
    -- No NUL after the name: an encoding would add one, but an untouched NAME keeps its bytes.
    local bytes = record(
      'MISC',
      subrecord('NAME', 'coin')
        .. subrecord('FNAM', 'Coin\0')
        .. subrecord('MCDT', string.pack('<fII', 1, 2, 0))
    )
    local plugin = open(bytes)
    local value = plugin:decode(0) :: any
    expect(plugin:set(0, value)).toBe(false)
    value.name = 'Gold'
    expect(plugin:set(0, value)).toBe(true)
    expect(buffer.tostring(plugin:bytes(0))).toBe(
      record(
        'MISC',
        subrecord('NAME', 'coin')
          .. subrecord('FNAM', 'Gold\0')
          .. subrecord('MCDT', string.pack('<fII', 1, 2, 0))
      )
    )
  end)
end)

suite.describe('OpenMW saves', function()
  local save = tes3.save

  local function metadata(): string
    return record(
      'SAVE',
      subrecord('PLNA', 'Tester')
        .. subrecord('PLLE', string.pack('<i4', 7))
        .. subrecord('PLCL', '\2Archer')
        .. subrecord('PLCN', 'Pilgrim')
        .. subrecord('PLCE', 'Balmora')
        .. subrecord('TSTM', string.pack('<fi4i4i4', 8.5, 18, 7, 427))
        .. subrecord('TIME', string.pack('<d', 25))
        .. subrecord('DESC', 'checkpoint')
        .. subrecord('DEPE', 'Morrowind.esm\0')
        .. subrecord('SCRN', '\255\216')
        .. subrecord('CDAY', string.pack('<i4', 4))
        .. subrecord('CHLT', string.pack('<f', 50))
        .. subrecord('MHLT', string.pack('<f', 75))
    )
  end

  local function current(): string
    return record(
      'TES3',
      subrecord('FORM', u32(save.CurrentFormatVersion)) .. variableHedr(0, '', '', 1)
    )
  end

  suite.it('reports the version window OpenMW loads', function()
    local old =
      open(record('TES3', subrecord('FORM', u32(save.MinEngineSupportedFormatVersion - 1))))
    local new = open(record('TES3', subrecord('FORM', u32(save.CurrentFormatVersion + 1))))
    expect(save.compatibility(old)).toEqual {
      kind = 'tooOld',
      version = save.MinEngineSupportedFormatVersion - 1,
      minimum = save.MinEngineSupportedFormatVersion,
    }

    expect(save.compatibility(new)).toEqual {
      kind = 'tooNew',
      version = save.CurrentFormatVersion + 1,
      maximum = save.CurrentFormatVersion,
    }
    expect(save.FormatHistory[#save.FormatHistory].version).toBe(save.CurrentFormatVersion)
  end)

  suite.it('reads the SAVE metadata and the screenshot', function()
    local plugin = open(current() .. metadata(), { profile = 'omwsave' })
    expect(save.profile(plugin)).toEqual {
      formatVersion = save.CurrentFormatVersion,
      playerName = 'Tester',
      playerLevel = 7,
      playerClassId = 'Archer',
      playerClassName = 'Pilgrim',
      playerCellName = 'Balmora',
      inGameTime = { gameHour = 8.5, day = 18, month = 7, year = 427 },
      timePlayed = 25,
      description = 'checkpoint',
      dependencies = { 'Morrowind.esm' },
      screenshotLength = 2,
      currentDay = 4,
      currentHealth = 50,
      maximumHealth = 75,
    }
    expect(buffer.tostring(save.screenshot(plugin))).toBe '\255\216'
    expect(function() save.profile(open(current())) end).toThrow 'OpenMW save has no SAVE record'
  end)

  suite.it('reads a save header\'s text as UTF-8', function()
    local plugin = open(record('TES3', hedr(0, 'Жук', '', 0)) .. record('SAVE', ''))
    expect(plugin:header().author).toBe 'Жук'
  end)

  suite.it('spells typed RefIds as OpenMW does', function()
    local function text(payload: string): string?
      local id = save.decodeRefId(buffer.fromstring(payload), 0, #payload)
      return if id then save.refIdText(id) else nil
    end

    expect(text '\0').toBe ''
    expect(text('\1' .. u32(3) .. 'abc')).toBe 'abc'
    expect(text '\2plain').toBe 'plain'
    expect(text('\3' .. string.pack('<I4i4', 0x123, 2))).toBe '0x2000123'
    expect(text('\3' .. string.pack('<I4i4', 5, -2))).toBe '@0x100000005'
    expect(text('\4' .. string.pack('<I4I4', 0xabc, 1))).toBe '0x100000abc'
    expect(text('\5SKIL' .. u32(26))).toBe 'SKIL:0x1a'
    expect(text('\6' .. string.pack('<i4i4', -2, -9))).toBe '#-2 -9'
    expect(text '\3short').toBeNil()
    expect(text '\9').toBeNil()
  end)

  suite.it('decodes object references in Lua data', function()
    local payload = '\0'
      .. string.char(0x80 + bit32.lshift(8, 3))
      .. 'o'
      .. string.pack('<I4i4', 42, 1)
    local value = save.decodeLuaData(buffer.fromstring(payload), 0, #payload)
    expect(value).toEqual { kind = 'object', ref = { index = 42, contentFile = 1 } }
    expect(save.luaRefs(value)).toEqual { { index = 42, contentFile = 1 } }
    local list = '\0'
      .. string.char(0x46)
      .. u32(16)
      .. 'objlist'
      .. string.pack('<I4i4I4i4', 7, 0, 8, 2)
    expect(save.luaRefs(save.decodeLuaData(buffer.fromstring(list), 0, #list))).toEqual {
      { index = 7, contentFile = 0 },
      { index = 8, contentFile = 2 },
    }
  end)

  suite.it('keeps tables and unknown userdata, and encodes them back', function()
    local payload = '\0\3\33x' .. string.char(0x42) .. u32(3) .. 'abc\1\2\3\4'
    local value = save.decodeLuaData(buffer.fromstring(payload), 0, #payload)
    expect(value).toEqual {
      kind = 'table',
      entries = {
        {
          key = { kind = 'string', value = 'x' },
          value = { kind = 'userdata', typeName = 'abc', data = '\1\2\3' },
        },
      },
    }
    expect(save.encodeLuaData(value)).toBe(payload)
    expect(save.decodeLuaData(buffer.create(0), 0, 0)).toEqual { kind = 'nil' }
    expect(save.encodeLuaData { kind = 'nil' }).toBe ''
    expect(function() save.decodeLuaData(buffer.fromstring '\1', 0, 1) end).toThrow 'unsupported Lua serialization format version 1'
    expect(function() save.decodeLuaData(buffer.fromstring '\0\0\0', 0, 3) end).toThrow 'unexpected end of serialized Lua data at offset 2'
  end)
end)

suite.describe('round trips', function()
  suite.it('checks a round trip, with types left out and cruft skipped', function()
    local bytes = record('TES3', '') .. record('GMST', subrecord('NAME', 'a\0'))
    expect(tes3.checkRoundTrip(buffer.fromstring(bytes))).toBeNil()
    expect(tes3.checkRoundTrip(buffer.fromstring(bytes), { 'GMST' })).toBeNil()
    expect(tes3.checkRoundTrip(buffer.fromstring('junk' .. bytes), nil, true)).toBeNil()
    expect(tes3.checkRoundTrip(buffer.fromstring('junk' .. bytes))).toContain 'failed to parse plugin'
  end)
end)

return suite
