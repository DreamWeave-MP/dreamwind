--!strict
--!native
-- dream-ini's Rust library is this package's executable specification, frozen: every case below
-- runs the same input through the port and expects the cfg, text, warnings, events, and errors the
-- library gave, read from the goldens under `golden/` by the Rust harness
-- (`libs/lua/tests/ini_experiment.rs`), which hands them over as the `oracle` global, one answer
-- per call in this file's order. `JESS_BLESS=1` makes the harness answer from the library itself
-- and write what it said. Only `changedKeys`, which the library's Luau binding never returned, is
-- left out; the harness checks it against the library on the Rust side. The binding's own option
-- messages, which no library call produces, are pinned below as text.
local port = require '@dreamwind/openmw-import-morrowind'
local test = require '@jess/test'
local host = require('@dream/vfs').host
type MultiMap = port.MultiMap
type Options = port.MapsOptions
type PathsOptions = port.PathsOptions
type Result = port.Result
type Native = { cfg: MultiMap, text: string, warnings: { port.Warning }, events: { port.Event } }

--- The seeded generators' seeds and counts; the harness writes them into every golden's header
--- and refuses a golden whose header differs.
export type Header = { [string]: { seed: number, count: number } }

--- The library's answers, in call order: what `dreamIni` answered, from the goldens.
type Oracle = {
  header: (header: Header) -> (),
  parseIni: (
    text: string,
    options: { encoding: string? }?
  ) -> { entries: MultiMap, warnings: { port.Warning } },
  parseCfg: (text: string) -> MultiMap,
  serializeCfg: (cfg: MultiMap) -> string,
  importMaps: (cfg: MultiMap, ini: MultiMap, options: Options?) -> Native,
  importPaths: (options: PathsOptions) -> Native,
}

local Header: Header = {
  byteSoup = { seed = 0x9184_3812, count = 400 },
  cfgLines = { seed = 77, count = 200 },
  generatedInis = { seed = 0x5eed, count = 120 },
}

local oracle = (rawget(_G :: any, 'oracle') :: Oracle?)
  or error(
    'the differential suite runs through `cargo test -p jess-lua --test ini_experiment`, which supplies the goldens as `oracle`',
    0
  )
oracle.header(Header)

-- The fallback keys the generated INIs draw from: the library's list, which the harness hands
-- over, so the suite reaches the importer only through its export, from the source or the JPK.
local fallbackKeys = (rawget(_G :: any, 'fallbackKeys') :: { string }?)
  or error('the differential suite needs the harness\'s `fallbackKeys`', 0)

local expect = test.expect
local suite = test.new()

-- The harness builds the folders the content and archive resolution runs over, with distinct
-- timestamps so the sort by modification time is exercised, and names it `fixtureRoot`.
local function fixture(): string
  local given = rawget(_G :: any, 'fixtureRoot')
  if type(given) == 'string' then return given end

  error('the differential suite needs the harness\'s `fixtureRoot`', 0)
end

local root = fixture()

-- Compared piece by piece, so a mismatch names the one key or entry that differs.
local function expectSameResult(actual: Result, expected: Native)
  for key in expected.cfg do
    expect(actual.cfg[key]).toEqual(expected.cfg[key])
  end

  for key in actual.cfg do
    expect(actual.cfg[key]).toEqual(expected.cfg[key])
  end

  expect(actual.text).toEqual(expected.text)

  for index = 1, math.max(#actual.warnings, #expected.warnings) do
    expect(actual.warnings[index]).toEqual(expected.warnings[index])
  end

  for index = 1, math.max(#actual.events, #expected.events) do
    expect(actual.events[index]).toEqual(expected.events[index])
  end
end

local function message(problem: string): string
  return string.match(problem, 'dream%.ini: .*') or problem
end

-- A copy of a multimap, malformed or not, to check the import left its input alone.
local function snapshot(map: MultiMap): MultiMap
  local result = table.clone(map)

  for key, values in result :: { [string]: unknown } do
    if type(values) == 'table' then result[key] = table.clone(values :: { string }) end
  end

  return result
end

-- Both implementations run to the same conclusion: the same result, or the same error.
local function compareMaps(cfg: MultiMap, ini: MultiMap, options: Options)
  local before = snapshot(cfg)
  -- Both calls are meant to fail in the error cases, and the message is what's compared.
  local expectedOk, expected = pcall(oracle.importMaps, cfg, ini, options)
  local actualOk, actual = pcall(port.importMaps, cfg, ini, options)
  expect(if actualOk then 'ok' else message(tostring(actual))).toBe(
    if expectedOk then 'ok' else message(tostring(expected))
  )

  if expectedOk then expectSameResult(actual :: Result, expected :: Native) end

  expect(cfg).toEqual(before)
end

local function compareTexts(cfgText: string, iniText: string, options: Options)
  compareMaps(port.parseCfg(cfgText), port.parseIni(iniText).entries, options)
end

local function minstd(seed: number): () -> number
  local state = seed

  return function(): number
    state = (state * 48271) % 2147483647
    return state
  end
end

local function pick<T>(next: () -> number, list: { T }): T return list[next() % #list + 1] end

suite.describe('parser', function()
  local fragments = {
    '[General]\nDisable Audio=1\n',
    '[Movies]\r\nNew Game=',
    '\n[bad\n[]=ignored\n',
    'a=b=c;comment\r\r\n',
    '\nEmpty=\n',
    '\n [Fonts]\nFont 0=magic\n',
    '\0\31=\255\n',
    '[Game Files]\nGameFile0=Base.esm\n',
    ';only a comment\n',
    '=novalue\n',
    '[Weather]\nSunrise Time=6\n',
  }

  suite.it('agrees on generated byte soup in every encoding', function()
    local next = minstd(Header.byteSoup.seed)

    for case = 1, Header.byteSoup.count do
      local parts: { string } = {}

      for _ = 1, case % 31 + 1 do
        table.insert(parts, pick(next, fragments))
        table.insert(parts, string.char(next() % 256))
      end

      local sample = table.concat(parts)

      for _, encoding in { 'win1250', 'win1251', 'win1252' } do
        expect(port.parseIni(sample, { encoding = encoding })).toEqual(
          oracle.parseIni(sample, { encoding = encoding })
        )
      end
    end
  end)

  suite.it('agrees on every byte after every byte order mark', function()
    local everyByte: { string } = {}

    for byte = 0, 255 do
      table.insert(everyByte, string.char(byte))
    end

    for _, bom in { '\239\187\191', '\255\254', '\254\255', '' } do
      local sample = bom .. '[Movies]\nNew Game=' .. table.concat(everyByte)

      for _, encoding in { 'win1250', 'win1251', 'win1252' } do
        expect(port.parseIni(sample, { encoding = encoding })).toEqual(
          oracle.parseIni(sample, { encoding = encoding })
        )
      end
    end
  end)

  suite.it('agrees on cfg text', function()
    local next = minstd(Header.cfgLines.seed)
    local candidateLines = {
      'data=Configured',
      'data="quoted path"',
      ' # comment',
      'key = value # kept',
      'no equals',
      '=empty key',
      'fallback=Weather_Sunrise_Time,6',
      '\tencoding=win1250\r',
      'content=Base.esm',
      '',
    }

    for _ = 1, Header.cfgLines.count do
      local lines: { string } = {}

      for _ = 1, next() % 12 do
        table.insert(lines, pick(next, candidateLines))
      end

      local text = table.concat(lines, '\n')
      expect(port.parseCfg(text)).toEqual(oracle.parseCfg(text))
      expect(port.serializeCfg(port.parseCfg(text))).toBe(
        oracle.serializeCfg(oracle.parseCfg(text))
      )
    end
  end)
end)

suite.describe('importMaps', function()
  local cases = {
    '[Game Files]\nGameFile0=Alpha.esp\nGameFile1=Base.esm\nGameFile2=Beta.esp\nGameFile3=Newer.esp\n',
    '[Game Files]\nGameFile0=Base.esm\nGameFile1=Missing.esp\nGameFile2=Alpha.esp\n',
    '[Game Files]\nGameFile0=Base.esm\nGameFile2=Alpha.esp\n',
    '[GAME FILES]\nGAMEFILE0=Base.esm\n[Game Files]\ngamefile0=Alpha.esp\nGameFile1=Beta.esp\n',
    '[Game Files]\nGameFile00=Missing.esp\nGameFile+0=Missing.esp\nGameFile0=Base.esm\n',
    '[Game Files]\nGameFile0= \tAlpha.esp \t\nGameFile1=ignored.txt\nGameFile2=Base.esm\n',
    '[Archives]\nArchive 0=Tribunal.bsa\nArchive 1=UPPER.BSA\nArchive 3=Missing.bsa\n',
    '[ARCHIVES]\nARCHIVE 0=Tribunal.bsa\n[Archives]\nArchive 0=UPPER.BSA\n',
    '[General]\nDisable Audio=0\nDisable Audio=1\n[Movies]\nNew Game=movie,with,commas.bik\n',
    '[Game Files]\nGameFile0=../Base.esm\n',
    '[Archives]\nArchive 0=../Tribunal.bsa\n',
    '[Archives]\nArchive 0=Missing.bsa\n',
  }

  local cfgs = {
    '',
    `data="{root}/Configured"\n`,
    'data=Configured\ndata-local=Local\nresources=resources\nuser-data=user\n',
    'encoding=win1250\nfallback=Old_Setting,old\nno-sound=0\n',
  }
  local explicitDirs = { {}, { root .. '/Explicit' }, { 'Explicit', 'Configured', 'Explicit' } }

  suite.it('agrees on the fixture cases in every option combination', function()
    for _, text in cases do
      for _, verbose in { false, true } do
        for _, cfg in cfgs do
          for _, explicit in explicitDirs do
            compareTexts(cfg, text, {
              iniPath = root .. '/Morrowind.ini',
              cfgDir = root,
              dataDirs = explicit,
              gameFiles = true,
              verbose = verbose,
            })
          end
        end
      end
    end
  end)

  suite.it('agrees without a cfg folder, and on option errors', function()
    for _, text in cases do
      compareTexts('encoding=win1252\n', text, {
        iniPath = root .. '/Morrowind.ini',
        gameFiles = true,
        dataDirs = { root .. '/Explicit' },
      })
      compareTexts('', text, { archives = false, gameFiles = true })
    end

    compareMaps({ encoding = { 'koi8' } }, {}, {})
  end)

  suite.it('rejects bad options and malformed multimaps with the binding\'s messages', function()
    local pinned: { { call: () -> unknown, message: string } } = {
      {
        call = function() return port.importMaps({}, {}, { encoding = 'utf-8' }) end,
        message = 'ini.importMaps.encoding: unsupported encoding: utf-8',
      },

      {
        call = function() return port.importMaps({}, {}, { game = 'Oblivion' }) end,
        message = 'ini.importMaps.game: unsupported game: Oblivion',
      },

      {
        call = function()
          return port.importMaps({}, {}, { writeResolvedDataDirs = true, ini = 'x' } :: any)
        end,
        message = 'ini.importMaps: unknown options \'ini\', \'writeResolvedDataDirs\'; known options are archives, cfgDir, dataDirs, dataLocal, encoding, fonts, game, gameFiles, iniPath, resources, userData, verbose',
      },

      {
        call = function() return port.importMaps({}, {}, { verbose = 'yes' } :: any) end,
        message = 'ini.importMaps.verbose: expected boolean, got string',
      },

      {
        call = function() return port.importMaps({}, {}, { dataDirs = 'Explicit' } :: any) end,
        message = 'ini.importMaps.dataDirs: expected an array of strings, got string',
      },

      {
        call = function() return port.importMaps({}, {}, { dataDirs = { 'Explicit', 2 } } :: any) end,
        message = 'ini.importMaps.dataDirs[2]: expected a string, got number',
      },

      {
        call = function() return port.importMaps({ data = 'Explicit' } :: any, {}, {}) end,
        message = 'ini.importMaps: expected array of strings for key \'data\', got string',
      },

      {
        call = function() return port.importMaps({ data = { 'Explicit', 2 } } :: any, {}, {}) end,
        message = 'ini.importMaps: expected a string at key \'data\' index 2, got number',
      },

      {
        call = function() return port.importMaps({}, { [1] = { 'x' } } :: any, {}) end,
        message = 'ini.importMaps: multimap keys must be strings, got number',
      },

      {
        call = function() return port.importMaps({}, {}, 'verbose' :: any) end,
        message = 'ini.importMaps: options must be a table, got string',
      },

      {
        call = function() return port.parseIni('', { encoding = 'utf-8' }) end,
        message = 'ini.parseIni.encoding: unsupported encoding: utf-8',
      },

      {
        call = function() return port.parseIni('', { encodng = 'win1252' } :: any) end,
        message = 'ini.parseIni: unknown option \'encodng\'; known options are encoding',
      },

      {
        call = function() return port.serializeCfg({ data = 'x' } :: any) end,
        message = 'ini.serializeCfg: expected array of strings for key \'data\', got string',
      },
    }

    for _, case in pinned do
      -- The call is meant to fail; its message is what's pinned.
      local ok, problem = pcall(case.call)
      expect(ok).toBe(false)
      expect(message(tostring(problem))).toBe(case.message)
    end
  end)

  suite.it('agrees on generated INIs', function()
    local next = minstd(Header.generatedInis.seed)
    local names = {
      'Base.esm',
      'Alpha.esp',
      'Beta.esp',
      'Newer.esp',
      'Missing.esp',
      'base.ESM',
      ' Alpha.esp\t',
      'notes.txt',
      'Tribunal.bsa',
      'UPPER.BSA',
      'Missing.bsa',
      'morrowind.bsa',
    }

    for _ = 1, Header.generatedInis.count do
      local lines: { string } = {}

      for _ = 1, next() % 6 do
        local key = pick(next, fallbackKeys)
        local section, field = string.match(key, '^(.-):(.*)$')
        table.insert(lines, `[{section}]\n{field}={next() % 1000}\n{field}=again\n`)
      end

      table.insert(lines, '[Game Files]\n')

      for index = 0, next() % 5 do
        table.insert(lines, `GameFile{index}={pick(next, names)}\n`)
      end

      table.insert(lines, '[Archives]\n')

      for index = 0, next() % 3 do
        table.insert(lines, `Archive {index}={pick(next, names)}\n`)
      end

      if next() % 2 == 0 then table.insert(lines, `[General]\nDisable Audio={next() % 2}\n`) end

      local text = table.concat(lines)
      local options: Options = {
        iniPath = root .. '/Morrowind.ini',
        cfgDir = root,
        gameFiles = next() % 4 ~= 0,
        archives = next() % 3 ~= 0,
        fonts = next() % 2 == 0,
        verbose = next() % 2 == 0,
        dataDirs = pick(next, explicitDirs),
      }
      compareTexts(pick(next, cfgs), text, options)
    end
  end)
end)

suite.describe('importPaths', function()
  local cfgPath, iniPath = root .. '/openmw.cfg', root .. '/Morrowind.ini'

  suite.afterEach(function()
    jess.fs.remove(cfgPath)
    jess.fs.remove(iniPath)
  end)

  local cfgFiles = {
    'data=Configured\ndata-local=Local\nresources=resources\n',
    'encoding=win1250\nfallback=Old_Setting,old\n',
    '',
  }

  local iniFiles = {
    '[Game Files]\nGameFile0=Alpha.esp\nGameFile1=Base.esm\nGameFile2=Beta.esp\n',
    '[General]\nEmpty=\n[bad\n[Movies]\nNew Game=\n',
    '[Movies]\nNew Game=intro.bik\n[Movies]\nNew Game=outro.bik\n',
  }

  suite.it('agrees on files, and leaves them alone', function()
    for _, cfg in cfgFiles do
      host.writeFile(cfgPath, cfg)

      for _, text in iniFiles do
        host.writeFile(iniPath, text)
        local options: PathsOptions = {
          ini = iniPath,
          cfg = cfgPath,
          dataDirs = { 'Explicit' },
          gameFiles = true,
          verbose = true,
        }

        expectSameResult(port.importPaths(options), oracle.importPaths(options))
        expect(host.readFileString(cfgPath)).toBe(cfg)
      end
    end
  end)

  suite.it('agrees when the cfg is missing', function()
    host.writeFile(iniPath, '[Movies]\nNew Game=intro.bik\n')
    local options: PathsOptions = { ini = iniPath, cfg = root .. '/missing.cfg', archives = false }
    expectSameResult(port.importPaths(options), oracle.importPaths(options))
    expect(host.exists(root .. '/missing.cfg')).toBe(false)
    local missing: PathsOptions = { ini = root .. '/nothing.ini' }
    -- Both fail the same way when the INI itself is missing; the failing calls are the point.
    local expectedOk, expected = pcall(oracle.importPaths, missing)
    local actualOk, actual = pcall(port.importPaths, missing)
    expect({ actualOk, expectedOk }).toEqual { false, false }
    expect(message(tostring(actual))).toBe(message(tostring(expected)))
  end)
end)

return suite
