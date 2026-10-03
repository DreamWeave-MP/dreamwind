--!strict
--!native
-- The package's own cases: the edge semantics dream-ini pins, checked on the port alone.
local ini = require '@dreamwind/openmw-import-morrowind'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

type ParserCase = { name: string, text: string, entries: { [string]: { string } } }

local ParserCases: { ParserCase } = {
  {
    name = 'duplicates and equals signs in values',
    text = '[General]\nName=a=b\nName=c\n',
    entries = { ['General:Name'] = { 'a=b', 'c' } },
  },

  {
    name = 'a key before any section',
    text = 'Loose=value\n',
    entries = { [':Loose'] = { 'value' } },
  },
  { name = 'CRLF', text = '[General]\r\nName=a\r\n', entries = { ['General:Name'] = { 'a' } } },
  {
    name = 'exactly one trailing CR comes off',
    text = '[General]\r\nName=a\r\r\nLast=b\r',
    entries = { ['General:Name'] = { 'a\r' }, ['General:Last'] = { 'b' } },
  },

  {
    name = 'CR alone is not a line end',
    text = '[General]\rName=a\r[Movies]\rNew Game=intro.bik\r',
    entries = {},
  },

  {
    name = 'a UTF-8 byte order mark',
    text = '\239\187\191[General]\nName=a\n',
    entries = { ['General:Name'] = { 'a' } },
  },

  {
    name = 'repeated sections append',
    text = '[Movies]\nNew Game=a\n[Movies]\nNew Game=b\n',
    entries = { ['Movies:New Game'] = { 'a', 'b' } },
  },

  {
    name = 'whitespace is significant',
    text = ' [General]\nName=a\n[General]\n Name=b\nName =c\n',
    entries = { [':Name'] = { 'a' }, ['General: Name'] = { 'b' }, ['General:Name '] = { 'c' } },
  },

  {
    name = 'a semicolon starts a comment',
    text = '[Movies]\nNew Game=intro;rest\n',
    entries = { ['Movies:New Game'] = { 'intro' } },
  },

  {
    name = 'control bytes survive',
    text = '[Movies]\nNew Game=intro\0\31.bik\n',
    entries = { ['Movies:New Game'] = { 'intro\0\31.bik' } },
  },

  {
    name = 'a malformed section line is skipped',
    text = '[bad\n[General]\nName=a\n',
    entries = { ['General:Name'] = { 'a' } },
  },

  {
    name = 'windows-1252 by default',
    text = '[Movies]\nNew Game=caf\233.bik\n',
    entries = { ['Movies:New Game'] = { 'café.bik' } },
  },

  {
    name = 'windows-1251 on request',
    text = '[Movies]\nNew Game=\192.bik\n',
    entries = { ['Movies:New Game'] = { 'А.bik' } },
  },
}

suite.describe('parseIni', function()
  for _, case in ParserCases do
    suite.it(case.name, function()
      local encoding = if string.find(case.name, '1251') then 'win1251' else nil
      expect(ini.parseIni(case.text, { encoding = encoding }).entries).toEqual(case.entries)
    end)
  end

  suite.it('reports warnings in input order', function()
    local warnings = ini.parseIni('[General]\nEmpty=\n[bad\n[]=ignored\n').warnings
    expect(warnings).toEqual {
      {
        kind = 'ignoredEmptyValue',
        key = 'General:Empty',
        message = 'ignored empty value for key \'General:Empty\'.',
      },

      {
        kind = 'malformedIniLine',
        line = '[bad',
        message = 'ini file wrongly formatted ([bad). Line ignored.',
      },

      {
        kind = 'malformedIniLine',
        line = '[]=ignored',
        message = 'ini file wrongly formatted ([]=ignored). Line ignored.',
      },
    }
  end)

  suite.it('rejects other encodings and unknown options', function()
    expect(function() ini.parseIni('', { encoding = 'utf-8' }) end).toThrow 'unsupported encoding'
    expect(function() ini.parseIni('', { encodng = 'win1252' } :: any) end).toThrow 'unknown option'
  end)
end)

suite.describe('parseCfg and serializeCfg', function()
  suite.it(
    'trims and keeps an inline hash',
    function()
      expect(ini.parseCfg ' # comment\nkey = value # not comment\nkey= second\ninvalid\n').toEqual {
        key = { 'value # not comment', 'second' },
      }
    end
  )

  suite.it(
    'serializes keys sorted and values in order',
    function()
      expect(ini.serializeCfg { data = { 'b', 'a' }, content = { 'x' } }).toBe 'content=x\ndata=b\ndata=a\n'
    end
  )
end)

suite.describe('importMaps', function()
  suite.it('takes the last audio value, replaces fallback, and gates fonts', function()
    local parsed = ini.parseIni(
      '[General]\nDisable Audio=1\nDisable Audio=0\n[Fonts]\nFont 0=magic\n[Movies]\nNew Game=intro.bik\n'
    ).entries
    local cfg = { fallback = { 'old' }, ['no-sound'] = { '1' } }
    local result = ini.importMaps(cfg, parsed, { archives = false })
    expect(result.cfg.fallback).toEqual { 'Movies_New_Game,intro.bik' }
    expect(result.cfg['no-sound']).toEqual { '0' }
    expect(cfg).toEqual { fallback = { 'old' }, ['no-sound'] = { '1' } }
    expect(ini.importMaps({}, parsed, { archives = false, fonts = true }).cfg.fallback).toEqual {
      'Fonts_Font_0,magic',
      'Movies_New_Game,intro.bik',
    }
  end)

  suite.it('leaves fallback alone when the INI has none', function()
    local parsed = ini.parseIni '[Movies]\nNew Game=\n'
    expect(
      ini.importMaps({ fallback = { 'old' } }, parsed.entries, { archives = false }).cfg.fallback
    ).toEqual {
      'old',
    }
    expect(#parsed.warnings).toBe(1)
  end)

  suite.it('resolves the encoding and writes the singleton overrides', function()
    local result = ini.importMaps({ encoding = { 'win1250' } }, {}, {
      archives = false,
      encoding = 'WINDOWS-1251',
      dataLocal = 'local',
      resources = 'resources',
      userData = 'user',
    })

    expect(result.cfg).toEqual {
      encoding = { 'win1251' },
      ['data-local'] = { 'local' },
      resources = { 'resources' },
      ['user-data'] = { 'user' },
    }
    expect(result.changedKeys).toEqual { 'data-local', 'encoding', 'resources', 'user-data' }
    expect(result.text).toBe 'data-local=local\nencoding=win1251\nresources=resources\nuser-data=user\n'
  end)

  suite.it('keeps the cfg encoding when nothing overrides it', function()
    local result = ini.importMaps({ encoding = { 'win1250' } }, {}, { archives = false })
    expect(result.cfg.encoding).toEqual { 'win1250' }
    expect(result.changedKeys).toEqual {}
  end)

  suite.it('rejects bad options and malformed multimaps', function()
    expect(function() ini.importMaps({}, {}, { encoding = 'utf-8' }) end).toThrow 'unsupported encoding'
    expect(function() ini.importMaps({}, {}, { game = 'Oblivion' }) end).toThrow 'unsupported game'
    expect(function() ini.importMaps({}, {}, { verbose = 'yes' } :: any) end).toThrow 'expected boolean'
    expect(function() ini.importMaps({ data = 'not a list' } :: any, {}, {}) end).toThrow 'ini.importMaps: expected array of strings for key \'data\', got string'
    expect(function() ini.importMaps({}, {}, { writeResolvedDataDirs = true } :: any) end).toThrow 'unknown option \'writeResolvedDataDirs\''
  end)
end)

suite.describe('documents and writers', function()
  local root = jess.fs.join(
    jess.fs.parent(arg[0]) or '.',
    '..',
    '..',
    '..',
    '..',
    'target',
    'openmw-import-morrowind-writers'
  )
  jess.fs.createDir(root)
  local cfgPath = jess.fs.join(root, 'openmw.cfg')

  suite.afterEach(function() jess.fs.remove(cfgPath) end)

  suite.it('keeps comments, blank lines, and untouched lines where they were', function()
    jess.fs.write(
      cfgPath,
      '# top\r\n\r\nno-sound=0\r\n# audio\r\nno-sound=0\r\nkey = value # kept\r\nencoding=win1250\r\nencoding=win1251\r\nconfig=sub\r\ndata=Configured\r\n\r\n# tail\r\n# OpenMW-Config Serializer Version: 3.0.0\r\n'
    )
    local document = ini.loadDocument(cfgPath)
    ini.applyUpdate(document, {
      cfg = {
        ['no-sound'] = { '1' },
        encoding = { 'win1252' },
        data = { 'Configured', 'Explicit' },
      },
      changedKeys = { 'data', 'encoding', 'no-sound' },
    }, {})
    -- A removed line takes the comment above it along; a replaced encoding goes to the end; a
    -- folder the chain has only under its resolved path is added again, as dream-ini adds it.
    expect(ini.renderDocument(document)).toBe 'key=value # kept\ndata=Configured\nconfig=sub\n\n# tail\nencoding=win1252\nno-sound=1\ndata=Configured\ndata=Explicit\n'
  end)

  suite.it('replaces a singleton in every place it was written, and gates the lists', function()
    jess.fs.write(
      cfgPath,
      'data-local=a\ncontent=Old.esp\nfallback-archive=Old.bsa\ndata-local=b\nfallback=Old,1\n'
    )
    local document = ini.loadDocument(cfgPath)
    local result = {
      cfg = {
        content = { 'New.esp' },
        ['fallback-archive'] = { 'New.bsa' },
        fallback = { 'New,2' },
      },
      changedKeys = { 'content', 'fallback', 'fallback-archive' },
    }
    ini.applyUpdate(document, result, { dataLocal = 'c', archives = false })
    expect(ini.renderDocument(document)).toBe 'content=Old.esp\nfallback-archive=Old.bsa\nfallback=New,2\ndata-local=c\n'
    ini.applyUpdate(document, result, { gameFiles = true })
    expect(ini.renderDocument(document)).toBe 'data-local=c\nfallback=New,2\ncontent=New.esp\nfallback-archive=New.bsa\n'
  end)

  suite.it('writes through a temporary file and reports the failure with the path', function()
    ini.saveCfg({ content = { 'A.esp' }, data = { 'Data Files' } }, cfgPath)
    local written = jess.fs.read(cfgPath) or ''
    expect(written).toContain 'content=A.esp\n'
    expect(written).toContain '# OpenMW-Config Serializer Version:'
    ini.saveResolvedCfg({ content = { 'A.esp' } }, cfgPath)
    expect(jess.fs.read(cfgPath)).toBe 'content=A.esp\n'
    local missing = jess.fs.join(root, 'nowhere', 'openmw.cfg')
    expect(function() ini.saveCfg({}, missing) end).toThrow(`dream.ini: {missing}: `)
    expect(
      function()
        ini.applyUpdate(
          ini.loadDocument(cfgPath),
          { cfg = {}, changedKeys = {} },
          { archive = true } :: any
        )
      end
    ).toThrow 'unknown option \'archive\''
  end)
end)

return suite
