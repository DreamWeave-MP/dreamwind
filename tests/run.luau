--!strict
--!native
-- DreamWind's own cases. First, that it and the packages it depends on resolve into one plan:
-- every module each of them exports (the lists are their manifests') can be required and is the
-- table its package says it is. What a module does is its own package's suite's to prove. Second,
-- that `@dreamwind` hands a command line to the tool it names and returns that tool's exit status.
-- The tools' messages go to the suite's own standard error, and their output to its standard
-- output.
local dreamwind = require '@dreamwind'
local fs = require '@dream/fs'
local test = require '@jess/test'

local expect = test.expect
local suite = test.new()

--- Holds `module` to a table with a function under each of `functions`, and under each name in
--- `others` a value of the type it names, as `type` spells it.
local function exposes(module: any, functions: { string }, others: { [string]: string }?)
  expect(type(module)).toBe 'table'
  local expected: { [string]: string }, found: { [string]: string } = {}, {}

  for _, name in functions do
    expected[name] = 'function'
  end

  for name, kind in others or {} do
    expected[name] = kind
  end

  for name in expected do
    found[name] = type(module[name])
  end

  expect(found).toEqual(expected)
end

--- A folder of this suite's own under the harness's `scratchRoot`, emptied.
local function fresh(name: string): string
  local root = assert(rawget(_G, 'scratchRoot') :: string?, 'the case needs a scratchRoot')
  local path = jess.fs.join(root, name)

  if fs.exists(path) then assert(fs.remove(path, { recursive = true })) end

  assert(fs.mkdir(path, { recursive = true }))
  return path
end

suite.describe('the packages', function()
  suite.it('tes3 exports @tes3', function()
    exposes(require '@tes3', { 'open', 'new', 'decode', 'encode' }, { records = 'table' })
  end)

  suite.it('tes3cmd exports @tes3cmd', function()
    exposes(require '@tes3cmd', { 'lint', 'clean', 'dump', 'validate' }, { files = 'table' })
  end)

  suite.it('tes3conv exports @tes3conv and its record helpers', function()
    exposes(require '@tes3conv', { 'decode', 'plugin', 'records', 'prepare' })
    exposes(require '@tes3conv/records', { 'editorId', 'sortObjects' }, { TypeNames = 'table' })
  end)

  suite.it('tes3-saves exports @tes3-saves', function()
    exposes(require '@tes3-saves', { 'open', 'parse', 'check', 'strip' }, { loadOrder = 'table' })
  end)

  suite.it('nif exports @nif and its six parts', function()
    exposes(require '@nif', { 'open', 'new' }, { recordTypes = 'table' })
    exposes(require '@nif/check', { 'check' })
    exposes(require '@nif/fix', { 'fix' }, { kinds = 'table' })
    exposes(require '@nif/gamebryo', { 'open' })
    exposes(require '@nif/header', { 'parse', 'version' })
    exposes(require '@nif/info', { 'sceneTree', 'recordTypeCounts' })
    exposes(require '@nif/scene', { 'build', 'dump' })
  end)

  suite.it('dream-archive exports @dream-archive, its formats, and what the tool is built on', function()
    local archive = require '@dream-archive'
    exposes(archive, { 'openPath', 'openBytes', 'detectPath' }, { version = 'string' })
    expect(require '@dream-archive/ba2').toBe(archive.ba2)
    expect(require '@dream-archive/bsa').toBe(archive.bsa)
    expect(require '@dream-archive/bsa/tes3').toBe(archive.bsa.tes3)
    expect(require '@dream-archive/bsa/tes4').toBe(archive.bsa.tes4)
    exposes(archive.ba2, { 'openPath', 'openBytes', 'hashFile' }, { Builder = 'table' })
    exposes(archive.bsa, { 'encodeFilename', 'normalizePath' })
    exposes(archive.bsa.tes3, { 'openPath', 'openBytes', 'hashFile' }, { Builder = 'table' })
    exposes(archive.bsa.tes4, { 'openPath', 'openBytes', 'hashFile' }, { Builder = 'table' })

    -- `types` is its types alone: a table with nothing in it.
    expect(require '@dream-archive/types').toEqual {}
    exposes(require '@dream-archive/util', { 'lookupKey', 'checkString' })
    exposes(require '@dream-archive/backend', { 'new', 'isEntry' })
  end)

  suite.it('dream-archivetool exports @dream-archivetool', function()
    exposes(
      require '@dream-archivetool',
      { 'info', 'extract', 'create', 'verify' },
      { version = 'string' }
    )
  end)

  suite.it('vfs exports @vfs and what vfstool is built on', function()
    exposes(
      require '@vfs',
      { 'serialize', 'snapshotDirectory' },
      { VFS = 'table', version = 'string' }
    )

    exposes(require '@vfs/paths', { 'normalize', 'join' })
    exposes(require '@vfs/layer', { 'build', 'drift' }, { SchemaVersion = 'number' })
    exposes(require '@vfs/encode', { 'fromLuau', 'displayTree' })
    exposes(require '@vfs/core', { 'build', 'fromDirectories' })
  end)

  suite.it('vfstool exports @vfstool', function() exposes(require '@vfstool', { 'run' }) end)

  suite.it('openmw-config exports @openmw-config, its grammar, and its paths', function()
    exposes(require '@openmw-config', { 'new', 'newEmpty', 'loadOptional' })
    exposes(require '@openmw-config/text', { 'parse', 'render', 'trim' })
    exposes(require '@openmw-config/paths', { 'resolve', 'key' })
  end)

  suite.it(
    'openmw exports @openmw',
    function() exposes(require '@openmw', { 'new', 'fromConfig' }) end
  )

  suite.it('dream-ini exports @dream-ini and what the importer is built on', function()
    exposes(
      require '@dream-ini',
      { 'parseIni', 'parseCfg', 'serializeCfg', 'renderDocument', 'saveDocument' },
      { version = 'string' }
    )

    exposes(require '@dream-ini/parser', { 'parseIni', 'parseCfg', 'trim' })
    exposes(require '@dream-ini/options', { 'read', 'multimap' })
    exposes(require '@dream-ini/document', { 'parse', 'render', 'save' })
    exposes(require '@dream-ini/storage', { 'canonical' })
  end)

  suite.it('openmw-import-morrowind exports @openmw-import-morrowind', function()
    exposes(
      require '@openmw-import-morrowind',
      { 'importMaps', 'importPaths', 'readPluginHeader', 'saveCfg' },
      { version = 'string' }
    )
  end)

  suite.it(
    'merge-to-master exports @merge-to-master',
    function() exposes(require '@merge-to-master', { 'merge' }) end
  )

  suite.it(
    'add-vanilla-refs exports @add-vanilla-refs',
    function() exposes(require '@add-vanilla-refs', { 'run' }) end
  )

  suite.it('starwind exports @starwind and its command line', function()
    exposes(require '@starwind', { 'build' }, { pipeline = 'table' })
    exposes(require '@starwind/cli', { 'run', 'parse' }, { Exit = 'table' })
  end)

  suite.it('load-order exports @load-order', function()
    exposes(require '@load-order', { 'open', 'masters', 'outputDirectory', 'activate' })
  end)

  suite.it('nif-assets exports @nif-assets', function()
    exposes(require '@nif-assets', { 'new', 'sources', 'check', 'info', 'fix' })
  end)

  suite.it('plugin-assets exports @plugin-assets', function()
    exposes(require '@plugin-assets', { 'check' }, { recordTypes = 'table' })
  end)

  suite.it('s3lightfixes exports @s3lightfixes and its command line', function()
    expect(type(require '@s3lightfixes')).toBe 'function'
    exposes(require '@s3lightfixes/cli', { 'run', 'parse', 'configuration' }, { Exit = 'table' })
  end)

  suite.it('merged-lands exports @merged-lands and its command line', function()
    expect(type(require '@merged-lands')).toBe 'function'
    exposes(require '@merged-lands/cli', { 'run', 'parse', 'configuration' }, { Exit = 'table' })
  end)

  suite.it('tes3merge exports @tes3merge and its command line', function()
    expect(type(require '@tes3merge')).toBe 'function'
    exposes(require '@tes3merge/cli', { 'run', 'parse' }, { Exit = 'table', version = 'string' })
  end)

  suite.it('doctor exports @doctor and its command line', function()
    expect(type(require '@doctor')).toBe 'function'
    exposes(require '@doctor/cli', { 'run', 'parse' }, { Exit = 'table' })
  end)
end)

suite.describe('the dispatcher', function()
  suite.it('is a table with run alone', function()
    exposes(dreamwind, { 'run' })
    expect(next(dreamwind, 'run')).toBeNil()
  end)

  suite.it('returns 0 for help under each of its spellings', function()
    expect(dreamwind.run { 'help' }).toBe(0)
    expect(dreamwind.run { '--help' }).toBe(0)
    expect(dreamwind.run { '-h' }).toBe(0)
  end)

  suite.it('returns 8 when no tool or an unknown tool is named', function()
    expect(dreamwind.run {}).toBe(8)
    expect(dreamwind.run { 'frobnicate' }).toBe(8)
    expect(dreamwind.run { 'Vfstool' }).toBe(8)
    expect(dreamwind.run { '--strict', 'starwind', 'help' }).toBe(8)
  end)

  suite.it('hands starwind the rest of the command line, and returns its status', function()
    expect(dreamwind.run { 'starwind', 'help' }).toBe(0)

    -- Starwind's own refusals: no command, and a help that was given an argument.
    expect(dreamwind.run { 'starwind' }).toBe(8)
    expect(dreamwind.run { 'starwind', 'help', 'build' }).toBe(8)
  end)

  suite.it('hands s3lightfixes the rest of the command line, and returns its status', function()
    expect(dreamwind.run { 's3lightfixes', '--help' }).toBe(0)

    -- S3LightFixes' own refusals: a flag this port doesn't have, and one nothing has.
    expect(dreamwind.run { 's3lightfixes', '--generate-manpage' }).toBe(8)
    expect(dreamwind.run { 's3lightfixes', '--frobnicate' }).toBe(8)
  end)

  suite.it('hands merged-lands the rest of the command line, and returns its status', function()
    expect(dreamwind.run { 'merged-lands', '--help' }).toBe(0)

    -- Merged Lands' own refusals: a flag this port doesn't have, and one nothing has.
    expect(dreamwind.run { 'merged-lands', '--vanilla' }).toBe(8)
    expect(dreamwind.run { 'merged-lands', '--frobnicate' }).toBe(8)
  end)

  suite.it('hands tes3merge the rest of the command line, and returns its status', function()
    expect(dreamwind.run { 'tes3merge', '--help' }).toBe(0)

    -- TES3Merge's own refusals: a command this port doesn't have, and a flag nothing has.
    expect(dreamwind.run { 'tes3merge', 'multipatch' }).toBe(8)
    expect(dreamwind.run { 'tes3merge', '--frobnicate' }).toBe(8)
  end)

  suite.it('hands doctor the rest of the command line, and returns its status', function()
    expect(dreamwind.run { 'doctor', '--help' }).toBe(0)

    -- The doctor's own refusals: a flag without its value, and a flag nothing has.
    expect(dreamwind.run { 'doctor', '--checks' }).toBe(8)
    expect(dreamwind.run { 'doctor', '--frobnicate' }).toBe(8)
  end)

  suite.it('hands vfstool the rest of the command line, and returns its status', function()
    local root = fresh 'dreamwind-vfstool'
    local data = jess.fs.join(root, 'Data Files')
    assert(fs.mkdir(data))
    assert(fs.writeFile(jess.fs.join(data, 'Morrowind.esm'), ''))
    assert(fs.writeFile(jess.fs.join(root, 'openmw.cfg'), `data="{data}"\n`))

    -- vfstool's own statuses: 0 for a file it found, 1 for one the VFS doesn't have, 7 for a
    -- configuration that isn't there, and 8 for a command line it can't use.
    expect(dreamwind.run { 'vfstool', 'find-file', '-s', '--config', root, 'Morrowind.esm' }).toBe(0)
    expect(dreamwind.run { 'vfstool', 'find-file', '-s', '--config', root, 'Tribunal.esm' }).toBe(1)
    local elsewhere = jess.fs.join(root, 'elsewhere')
    expect(dreamwind.run { 'vfstool', 'find-file', '--config', elsewhere, 'Morrowind.esm' }).toBe(7)
    expect(dreamwind.run { 'vfstool' }).toBe(8)
    expect(dreamwind.run { 'vfstool', 'not-a-command' }).toBe(8)
  end)

  suite.it('leaves the argument list as it was', function()
    -- vfstool takes the list it is given apart, so it is given one of its own.
    local argv = { 'vfstool', 'not-a-command', '--format', 'json' }
    dreamwind.run(argv)
    expect(argv).toEqual { 'vfstool', 'not-a-command', '--format', 'json' }
  end)
end)

return suite
