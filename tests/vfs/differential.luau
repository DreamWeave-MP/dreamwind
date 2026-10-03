--!strict
--!native
-- The port against the crate, case by case. Every case runs the same calls through
-- `@dreamwind/vfs` and, while jess still links it, the native `@dream/vfs`, and expects the same
-- observation: every report, every read, every write and what it left on disk, and the errors.
-- Each observation's digest is frozen in `golden/differential.txt`; without the native module the
-- port is held to the goldens instead. `bless = true` rewrites them from the native module.
--
-- The harness (`libs/lua/tests/vfs_experiment.rs`) sets `scratchRoot` for the fixture trees, and
-- `dataFiles` for a Morrowind `Data Files` folder read in place (never frozen: it is the
-- machine's own).
local archive = require '@dreamwind/archive'
local fs = require '@dream/fs'
local port = require '@dreamwind/vfs'
local support = require './support'
local test = require '@jess/test'
local suite = test.new()

local loaded, nativeModule = pcall(require, '@dream/vfs')
local native: any = if loaded then nativeModule else nil
local globals = _G :: any
local function setting(name: string): any return rawget(globals, name) or support.settings[name] end

local bless = setting 'bless' == true
local scratch = setting 'scratchRoot' :: string?
local dataFiles = setting 'dataFiles' :: string?
local goldenPath = setting 'goldenPath' or `{support.here()}/golden/differential.txt`

local golden: { [string]: string } = {}
if fs.exists(goldenPath) then
  for name, value in string.gmatch(fs.readFileString(goldenPath), '([^\t\n]+)\t([^\n]+)') do
    golden[name] = value
  end
end

local recorded: { string } = {}
local seenNames: { [string]: boolean } = {}

--- The first line two observations differ on, with its neighbours.
local function difference(mine: string, theirs: string): string
  local a, b = string.split(mine, '\n'), string.split(theirs, '\n')
  for index = 1, math.max(#a, #b) do
    if a[index] ~= b[index] then
      local context = {}
      for line = math.max(1, index - 4), index - 1 do
        table.insert(context, `  same:   {string.sub(a[line], 1, 400)}`)
      end

      return `line {index}:\n{table.concat(context, '\n')}\n  port:   {string.sub(
        a[index] or '<end>',
        1,
        2000
      )}\n  native: {string.sub(b[index] or '<end>', 1, 2000)}`
    end
  end

  return 'identical'
end

type Observe = (lib: any, root: string) -> string

--- `text` marked as compared live but never frozen: what spells the scratch folder's own
--- components out, like an absolute tree's display, which no scrub can make root-independent.
local function liveOnly(text: string): string return `\1{text}\2` end

local function frozenPart(observation: string): string
  return (string.gsub(observation, '\1.-\2', '<live>'))
end

--- An absolute tree's nesting with its single-child chain from `/` collapsed into one path, so
--- the scratch folder becomes one key the scrub spells `<root>`.
local function rebased(value: any): any
  if type(value) ~= 'table' or not value['/'] then return value end

  local path, node = '', value['/']
  while #node.files == 0 do
    local only, count = nil, 0
    for name in node.subdirs do
      only = name
      count += 1
    end

    if count ~= 1 then break end

    path = `{path}/{only}`
    node = node.subdirs[only]
  end

  return { [path] = node }
end

--- One case: the port's observation equals the native one, and the frozen digest of it. Each
--- side runs in a fresh folder of its own; `prepare` writes the fixture there first.
local function compare(
  name: string,
  observe: Observe,
  prepare: ((root: string) -> ())?,
  frozen: boolean?
)
  local base = fs.canonicalize(scratch or fs.cwd())
  local function run(lib: any, side: string): string
    local root = support.fresh(`{base}/{string.gsub(name, '[^%w]', '_')}`)
    if prepare then prepare(root) end

    local observed = support.scrub(observe(lib, root), root)
    fs.remove(root, { recursive = true })
    return observed
  end

  local mine = run(port, 'port')
  if native then
    local theirs = run(native, 'native')
    if mine ~= theirs then error(`{name}: {difference(mine, theirs)}`, 0) end
  end

  if frozen == false then return end

  assert(not seenNames[name], `case names are unique: {name}`)
  seenNames[name] = true
  local digest = support.digest(frozenPart(mine))
  table.insert(recorded, `{name}\t{digest}`)
  if bless then return end

  local expected = golden[name]
  if not expected then error(`{name}: no golden; rerun with JESS_BLESS=1 to record it`, 0) end

  if expected ~= digest then
    error(
      `{name}: the observation's digest {digest} is not the golden {expected}:\n{string.sub(
        mine,
        1,
        4000
      )}`,
      0
    )
  end
end

local describe, attempt = support.describe, support.attempt

-- Random inputs ---------------------------------------------------------------------------------------

local Names = {
  'Meshes',
  'meshes',
  'MESHES',
  'textures',
  'Textures',
  'a b',
  'x',
  'X',
  'dot.in.name',
  '.hidden',
  'Ünïcode',
  'bad\255name',
  'plain',
  'sound',
  'Icons',
  'File.TXT',
  'file.txt',
  'readme.md',
  'conf.ini',
  'cfg.toml',
  'data.json',
  'script.lua',
  'x.mws',
  'n.bsa',
  'archiveinvalidationinvalidated!.bsa',
}

local Contents = {
  '[Section]\nKey=1\nother = two\n',
  '; comment\n[section]\nother=two\nkey = 1\n',
  '[section]\nkey=2\n',
  '{"a": 1, "b": [true, null]}',
  '{\n  "b": [true, null],\n  "a": 1\n}',
  '{"a": 1.0}',
  'title = "x"\n[t]\nv = 1\n',
  '[t]\nv = 1\ntitle = "x"\n',
  'title = "x"\n[t]\nv = 1.0\n',
  'plain text\n',
  '  plain text  \r\n\n',
  'different text',
  'binary\0payload',
  'binary\0other',
  '',
  'not valid \255 utf8',
}

local function pick<T>(random: support.Random, list: { T }): T return list[random(#list) + 1] end

--- A load order of `count` data folders with random files: case variants, names that aren't
--- UTF-8, dotfiles, nested folders, and a file in one folder where another has a folder.
local function randomTree(random: support.Random, root: string, count: number): { string }
  local dirs = {}
  for index = 1, count do
    local dir = `{root}/data{index}`
    fs.mkdir(dir, { recursive = true })
    table.insert(dirs, dir)
    local files: { [string]: string } = {}
    for _ = 1, 3 + random(10) do
      local parts = {}
      for _ = 1, random(4) do
        table.insert(parts, pick(random, Names))
      end

      table.insert(parts, pick(random, Names))
      files[table.concat(parts, '/')] = pick(random, Contents)
    end

    -- A name that is a file here and a folder elsewhere.
    if random(2) == 0 then
      files['clash'] = 'a file'
    else
      files['CLASH/inside.txt'] = 'under a folder'
    end

    for path, contents in files do
      local ok = pcall(support.writeTree, dir, { [path] = contents })
      local _ = ok
    end
  end

  return dirs
end

-- Observations ------------------------------------------------------------------------------------------

local Needles = { 'x', 'MESH', 'file', '\\', '.', '', 'ü', 'nothing-matches' }
local Patterns = { '^meshes/', 'txt$', '(?i)FILE', '.*', '[', 'ü' }

--- Everything a VFS answers about itself, one line each.
local function report(lib: any, vfs: any, dirs: { string }): string
  local lines: { string } = {}
  local function line(label: string, text: string) table.insert(lines, `{label}: {text}`) end

  line('tostring', tostring(vfs))
  line('len', attempt(nil, vfs.len, vfs))
  line('isEmpty', attempt(nil, vfs.isEmpty, vfs))
  local keys = vfs:keys():toTable()
  line('keys', describe(keys))
  line('entries', describe(vfs:entries()))
  for _, key in keys do
    local upper = string.upper(key)
    local backslash = string.gsub(key, '/', '\\')
    for _, spelled in { key, upper, backslash, `/{key}`, `{key}/` } do
      line(`getFile {describe(spelled)}`, attempt(nil, vfs.getFile, vfs, spelled))
      line(`contains {describe(spelled)}`, attempt(nil, vfs.contains, vfs, spelled))
    end

    line(`providersFor {describe(key)}`, attempt(nil, vfs.providersFor, vfs, key))
    line(`providerRecordsFor {describe(key)}`, attempt(nil, vfs.providerRecordsFor, vfs, key))
    line(`explain {describe(key)}`, attempt(nil, vfs.explain, vfs, key))
  end

  line('providersFor missing', attempt(nil, vfs.providersFor, vfs, 'no/such/key'))
  line('explain missing', attempt(nil, vfs.explain, vfs, 'no/such/key'))
  for _, needle in Needles do
    line(`pathsMatching {describe(needle)}`, attempt(nil, vfs.pathsMatching, vfs, needle))
    line(`pathsWith {describe(needle)}`, attempt(nil, vfs.pathsWith, vfs, needle))
  end

  line('duplicates', attempt(nil, vfs.duplicates, vfs))
  for _, pattern in Patterns do
    line(`duplicates {describe(pattern)}`, attempt(nil, vfs.duplicates, vfs, pattern))
    line(`findByRegex {describe(pattern)}`, attempt(nil, vfs.findByRegex, vfs, pattern))
    line(
      `findByRegex absolute {describe(pattern)}`,
      attempt(nil, function() return rebased(vfs:findByRegex(pattern, false):toTable()) end)
    )
  end

  line('archives', attempt(nil, vfs.archives, vfs))
  for _, info in vfs:archives() do
    line(`archiveEntries {info.path}`, attempt(nil, vfs.archiveEntries, vfs, info.path))
    line(
      `archiveEntries upper {info.path}`,
      attempt(nil, vfs.archiveEntries, vfs, string.upper(info.path))
    )
    line(`filesFromArchive {info.path}`, attempt(nil, vfs.filesFromArchive, vfs, info.path))
  end

  line('sourceContributions', attempt(nil, vfs.sourceContributions, vfs))
  for _, relative in { true, false } do
    local tree = vfs:tree(relative)
    local rows = {}
    for _, row in tree do
      table.insert(rows, `{row.dir} {describe(row.file)}`)
    end

    line(`tree {relative}`, `{tree:count()} {table.concat(rows, ' | ')}`)
    local spelled = if relative then function(text: string): string return text end else liveOnly
    line(`tree toTable {relative}`, describe(rebased(tree:toTable())))
    line(`display {relative}`, spelled(describe(vfs:display(relative))))
    for _, format in { 'json', 'yaml', 'toml' } do
      line(
        `serializeTree {relative} {format}`,
        spelled(attempt(nil, vfs.serializeTree, vfs, relative, format))
      )
      line(`serialize tree {relative} {format}`, spelled(attempt(nil, lib.serialize, tree, format)))
    end
  end

  for _, dir in dirs do
    for _, replacements in { false, true } do
      local tree = vfs:remaining(dir, replacements, dirs)
      local rows = {}
      for _, row in tree do
        table.insert(rows, `{row.dir} {describe(row.file)}`)
      end

      line(`remaining {dir} {replacements}`, table.concat(rows, ' | '))
    end
  end

  for _, options in
    {
      {},
      { allowCopying = true },
      { extractArchives = true },
      { useSymlinks = true },
      { extractArchives = true, useSymlinks = true },
    }

  do
    line(
      `materializationPlan {describe(options)}`,
      attempt(nil, vfs.materializationPlan, vfs, '/out', options)
    )
  end

  local layer = vfs:layerIndex()
  line('layer', tostring(layer))
  line('layer keys', describe(layer:keys()))
  line('layer duplicateKeys', describe(layer:duplicateKeys()))
  line('layer sources', describe(layer:sources()))
  line('layer contributions', describe(layer:sourceContributions()))
  for index = 0, #layer:sources() + 1 do
    line(`layer sourceById {index}`, attempt(nil, layer.sourceById, layer, index))
  end

  for _, dir in dirs do
    line(`layer sourceIdForPath {dir}`, attempt(nil, layer.sourceIdForPath, layer, dir))
    line(`layer sourceIdForPath {dir}/`, attempt(nil, layer.sourceIdForPath, layer, `{dir}/`))
  end

  for _, key in keys do
    line(
      `layer sourcesContaining {describe(key)}`,
      attempt(nil, layer.sourcesContaining, layer, key)
    )
    line(`layer providerChain {describe(key)}`, attempt(nil, layer.providerChain, layer, key))
    for index = 1, 3 do
      line(
        `layer providerOriginalPath {index} {describe(key)}`,
        attempt(nil, layer.providerOriginalPath, layer, index, key)
      )
    end

    line(`layer provenance {describe(key)}`, attempt(nil, layer.provenance, layer, vfs, key, false))
    line(
      `layer provenance hashes {describe(key)}`,
      attempt(nil, layer.provenance, layer, vfs, key, true)
    )
  end

  local locked, lock = pcall(layer.lockManifest, layer, vfs)
  if locked then
    line('lock', describe(lock:toTable()))
    line('lock schemaVersion', describe(lock:schemaVersion()))
    line('lock entries', describe(lock:entries()))
    line('drift self', attempt(nil, layer.diffAgainstLock, layer, vfs, lock))
  else
    line('lock', `error {tostring(lock)}`)
  end

  for _, mode in { 'disabled', 'winnerOnly', 'allProviders' } do
    for _, deltas in { false, true } do
      line(
        `semanticConflicts {mode} {deltas}`,
        attempt(
          nil,
          layer.semanticConflicts,
          layer,
          vfs,
          { archiveHashMode = mode, includeSemanticDeltas = deltas }
        )
      )
    end
  end

  line('semanticConflicts default', attempt(nil, layer.semanticConflicts, layer, vfs))
  for _, format in { 'json', 'yaml', 'toml' } do
    line(`serialize keys {format}`, attempt(nil, lib.serialize, { keys = vfs:keys() }, format))
    line(
      `serialize entries {format}`,
      attempt(nil, lib.serialize, { entries = vfs:entries() }, format)
    )
    line(`serialize duplicates {format}`, attempt(nil, lib.serialize, vfs:duplicates(), format))
    line(
      `serialize contributions {format}`,
      attempt(nil, lib.serialize, vfs:sourceContributions(), format)
    )
    line(
      `serialize lock {format}`,
      attempt(nil, function() return lib.serialize(layer:lockManifest(vfs):toTable(), format) end)
    )
    line(
      `serialize plan {format}`,
      attempt(nil, lib.serialize, vfs:materializationPlan('/out', {}), format)
    )
    line(
      `serialize semantic {format}`,
      attempt(
        nil,
        function()
          return lib.serialize(
            layer:semanticConflicts(vfs, { includeSemanticDeltas = true }),
            format
          )
        end
      )
    )
  end

  return table.concat(lines, '\n')
end

--- A conflict index's reports.
local function conflictReport(conflicts: any, dirs: { string }): string
  local lines: { string } = {}
  local function line(label: string, text: string) table.insert(lines, `{label}: {text}`) end

  line('tostring', tostring(conflicts))
  line('sources', describe(conflicts:sources()))
  for _, relative in { true, false } do
    line(`conflictsReport {relative}`, attempt(nil, conflicts.conflictsReport, conflicts, relative))
    for _, list in { true, false } do
      line(
        `shadowedReport {relative} {list}`,
        attempt(nil, conflicts.shadowedReport, conflicts, relative, list)
      )
    end
  end

  for _, a in dirs do
    for _, b in dirs do
      line(`diffReport {a} {b}`, attempt(nil, conflicts.diffReport, conflicts, a, b))
    end

    line(
      `diffReport upper {a}`,
      attempt(nil, conflicts.diffReport, conflicts, string.upper(a), dirs[1])
    )
    for _, key in { 'clash', 'CLASH/inside.txt', 'meshes' } do
      line(`sourcesContaining {key}`, attempt(nil, conflicts.sourcesContaining, conflicts, key))
    end
  end

  return table.concat(lines, '\n')
end

-- Cases ----------------------------------------------------------------------------------------------

local Seeds = { 0x5eed0001, 0x5eed0002, 0x5eed0003, 0x5eed0004, 0x5eed0005, 0x5eed0006 }

suite.describe('paths and globs', function()
  suite.it('normalize, glob, and fold like the crate', function()
    compare('paths/glob', function(lib: any): string
      local random = support.generator(0x91ab)
      local pieces = {
        'Meshes',
        'textures',
        '*',
        '**',
        '**/',
        '?',
        '\\',
        '/',
        'a.b',
        'Ü',
        '[x]',
        '(y)',
        '+',
        '.dds',
        '$',
        '\255',
      }
      local lines = {}
      for _ = 1, 300 do
        local glob, path = {}, {}
        for _ = 1, 1 + random(5) do
          table.insert(glob, pick(random, pieces))
          table.insert(path, pick(random, pieces))
        end

        local globText, pathText = table.concat(glob), table.concat(path)
        table.insert(
          lines,
          `{describe(globText)} {describe(pathText)} {attempt(
            nil,
            lib.pathGlobMatches,
            globText,
            pathText
          )} {attempt(nil, lib.sourceGlobMatches, globText, pathText)} {attempt(
            nil,
            lib.normalizeHostPath,
            pathText
          )} {attempt(nil, lib.normalizeHostPathInPlace, globText)}`
        )
      end

      for _, pair in
        {
          { 'textures/**', 'textures/foo/bar.dds' },
          { '**/foo.txt', 'foo.txt' },
          { '**/foo.txt', 'meshes/foo.txt' },
          { 'textures/**/*.dds', 'textures/foo.dds' },
          { 'textures/*.dds', 'textures/a/b.dds' },
          { '**/mods/*patch*', '/home/user/MODS/MyPatch' },
          { 'Textures\\**', 'textures/foo.dds' },
          { 'textures/?.dds', 'textures/a.dds' },
        }

      do
        table.insert(lines, attempt(nil, lib.pathGlobMatches, pair[1], pair[2]))
      end

      return table.concat(lines, '\n')
    end)
  end)
end)

suite.describe('semantic analysis', function()
  suite.it('classifies and compares pairs like the crate', function()
    compare('semantic/pairs', function(lib: any): string
      local lines = {}
      local names = {
        'a.ini',
        'b.CFG',
        'c.toml',
        'd.json',
        'e.lua',
        'f.mws',
        'g.mwscript',
        'h.txt',
        'i.md',
        'j.bin',
        'k',
        'l.\255',
      }

      for _, name in names do
        for _, left in Contents do
          for _, right in Contents do
            table.insert(lines, attempt(nil, lib.analyzePair, name, left, right))
          end
        end
      end

      table.insert(lines, attempt(nil, lib.analyzePair, 'x.txt', ' a \u{a0}\n\u{3000}b', 'a\nb'))
      table.insert(lines, attempt(nil, lib.analyzePair, 'x.ini', '[ S ]\nK = v\n', '[s]\nk=v'))
      table.insert(lines, attempt(nil, lib.analyzePair, 'x.json', '{"a":1}', '{"a":1.0}'))
      table.insert(lines, attempt(nil, lib.analyzePair, 'x.json', '[1,2]', '[1, 2] '))
      table.insert(lines, attempt(nil, lib.analyzePair, 'x.json', '{"a":-0}', '{"a":0.0}'))
      table.insert(lines, attempt(nil, lib.analyzePair, 'x.toml', 'a = 1', 'a = 1.0'))
      table.insert(
        lines,
        attempt(nil, lib.analyzePair, 'x.toml', 'a = 1979-05-27', 'a = \'1979-05-27\'')
      )
      return table.concat(lines, '\n')
    end)
  end)
end)

local Strings = {
  'plain',
  'yes',
  'no',
  'true',
  'True',
  'TRUE',
  'false',
  'null',
  '~',
  '',
  ' ',
  ' leading',
  'trailing ',
  '123',
  '-12',
  '+5',
  '012',
  '0x1F',
  '0o17',
  '0b101',
  '-0x1',
  '1.5',
  '1e5',
  '.inf',
  '-.inf',
  '.nan',
  'inf',
  'nan',
  'a: b',
  'a:b',
  '- x',
  '-x',
  '#x',
  'a #b',
  'a#b',
  '? x',
  '?x',
  ':x',
  '!tag',
  '&anchor',
  '*alias',
  '|',
  '>',
  'it\'s',
  'say "hi"',
  '%x',
  '@x',
  '`x',
  '[x]',
  '{x}',
  'a,b',
  '---',
  '...',
  'a\nb',
  'a\n',
  '\na',
  'a \nb',
  'a\n b',
  'tab\there',
  'ctl\1here',
  'del\127',
  'ü',
  '\u{feff}bom',
  '\u{85}nel',
  '\u{2028}ls',
  'C:\\Games\\Data Files',
  '/home/user/Data Files/Meshes/x.nif',
  '\'\'\'',
  '"""',
  'a\r\nb',
}

local function randomValue(random: support.Random, depth: number): any
  local roll = random(if depth > 3 then 6 else 9)
  if roll == 0 then return pick(random, Strings) end

  if roll == 1 then return random(1000) - 500 end

  if roll == 2 then
    return pick(
      random,
      { 0.1, 1.5, -2.25, 1e21, 1e-7, 2 ^ 60, 123456789012345678, 1e15, 1e16, 1e-5, 0.00012 }
    )
  end

  if roll == 3 then return random(2) == 0 end

  if roll == 4 then return pick(random, Strings) end

  if roll == 5 then return integer.create(random(100000)) end

  if roll == 6 then
    local items = {}
    for _ = 1, random(4) do
      table.insert(items, randomValue(random, depth + 1))
    end

    return items
  end

  local map = {}
  for _ = 1, random(4) do
    map[pick(random, Strings)] = randomValue(random, depth + 1)
  end

  return map
end

suite.describe('serialization', function()
  suite.it('writes JSON, YAML and TOML byte for byte', function()
    compare('serialize/strings', function(lib: any): string
      local lines = {}
      for _, text in Strings do
        for _, format in { 'json', 'yaml', 'toml' } do
          table.insert(
            lines,
            attempt(nil, lib.serialize, { [text] = text, list = { text, text } }, format)
          )
          table.insert(lines, attempt(nil, lib.serialize, { text }, format))
        end
      end

      return table.concat(lines, '\n')
    end)

    for seed = 1, 8 do
      compare(`serialize/random-{seed}`, function(lib: any): string
        local random = support.generator(0xcafe00 + seed)
        local lines = {}
        for _ = 1, 40 do
          local value = randomValue(random, 0)
          for _, format in { 'json', 'yaml', 'toml' } do
            table.insert(lines, attempt(nil, lib.serialize, value, format))
            table.insert(lines, attempt(nil, lib.serialize, { root = value }, format))
          end
        end

        return table.concat(lines, '\n')
      end)
    end

    compare('serialize/errors', function(lib: any): string
      local lines = {}
      local cyclic: any = {}
      cyclic.self = cyclic
      for _, value in
        {
          { 0 / 0 },
          { math.huge },
          { print },
          { [true] = 1 },
          { ['\255'] = 1 },
          { '\255' },
          cyclic,
          { [1.5] = 'x', [2] = 'y' },
          { [1] = 'a', [3] = 'c' },
          { buffer.create(2) },
          'top',
          12,
          nil,
        }

      do
        for _, format in { 'json', 'yaml', 'toml', 'xml' } do
          table.insert(lines, attempt(nil, lib.serialize, value, format))
        end
      end

      return table.concat(lines, '\n')
    end)
  end)
end)

local function buildArchives(root: string, random: support.Random)
  local tes3 = archive.bsa.tes3.Builder.new()
  local tes4 = archive.bsa.tes4.Builder.new()
  local ba2 = archive.ba2.Builder.new()
  local used = {}
  for index = 1, 6 + random(6) do
    local folder = pick(random, { 'meshes', 'Textures', 'sound/fx', 'x' })
    local name =
      `{folder}\\{pick(random, { 'a', 'B', 'c.nif', 'D.dds', 'file.txt', 'clash' })}{index % 3}`
    if used[string.lower(name)] then continue end

    used[string.lower(name)] = true
    local data = pick(random, Contents) .. tostring(index)
    tes3:addBytes(name, data)
    tes4:addBytes(name, data)
    ba2:addBytes(string.gsub(name, '\\', '/'), data)
  end

  tes3:addBytes('meshes\\shared.nif', 'from tes3')
  tes4:addBytes('meshes\\shared.nif', 'from tes4')
  ba2:addBytes('meshes/shared.nif', 'from ba2')
  fs.mkdir(`{root}/data1`, { recursive = true })
  tes3:writePath(`{root}/data1/Packed.bsa`)
  tes4:writePath(`{root}/data1/Fourth.bsa`)
  ba2:writePath(`{root}/data1/General.ba2`)
  fs.writeFile(`{root}/data1/Broken.bsa`, 'not an archive')
end

suite.describe('load orders', function()
  suite.it('build, look up, and report like the crate', function()
    for index, seed in Seeds do
      local function prepare(root: string) randomTree(support.generator(seed), root, 2 + index % 3) end

      compare(`fs/build-{index}`, function(lib: any, root: string): string
        local dirs = {}
        for dir = 1, 2 + index % 3 do
          table.insert(dirs, `{root}/data{dir}`)
        end

        local vfs = lib.VFS.fromDirectories(dirs)
        local _, conflicts = lib.VFS.fromDirectoriesWithConflictIndex(dirs)
        local withLayer, layer = lib.VFS.fromDirectoriesWithLayerIndex(dirs)
        return table.concat({
          report(lib, vfs, dirs),
          conflictReport(conflicts, dirs),
          conflictReport(lib.ConflictIndex.fromDirectories(dirs), dirs),
          conflictReport(lib.ConflictIndex.fromLayerIndex(layer), dirs),
          describe(layer:keys()),
          tostring(withLayer),
        }, '\n')
      end, prepare)
    end
  end)

  suite.it('read archives below loose files', function()
    for index, seed in Seeds do
      local function prepare(root: string)
        local random = support.generator(seed + 77)
        randomTree(random, root, 3)
        buildArchives(root, random)
      end

      compare(`fs/archives-{index}`, function(lib: any, root: string): string
        local dirs = { `{root}/data1`, `{root}/data2`, `{root}/data3` }
        local lists = {
          { 'Packed.bsa', 'FOURTH.BSA', 'general.ba2', 'Broken.bsa', 'missing.bsa' },
          { 'general.ba2', 'packed.bsa' },
          {},
        }
        local lines = {}
        for _, list in lists do
          local vfs = lib.VFS.fromDirectories(dirs, { archives = list })
          table.insert(lines, report(lib, vfs, dirs))
          for _, key in vfs:keys():toTable() do
            local file = vfs:getFile(key)
            table.insert(
              lines,
              `{key} size {attempt(nil, file.size, file)} all {attempt(nil, file.readAll, file)} buffer {attempt(
                nil,
                file.readAllBuffer,
                file
              )}`
            )
          end
        end

        local pushed = lib.VFS.new()
        for _, name in { 'Packed.bsa', 'Fourth.bsa', 'General.ba2', 'Broken.bsa', 'missing.bsa' } do
          table.insert(lines, attempt(nil, pushed.pushArchive, pushed, `{root}/data1/{name}`))
        end

        table.insert(lines, report(lib, pushed, dirs))
        return table.concat(lines, '\n')
      end, prepare)
    end
  end)
end)

--- A run of random mutations, each followed by the state it left.
local function mutate(lib: any, root: string, seed: number): string
  local random = support.generator(seed)
  local dirs = { `{root}/data1`, `{root}/data2`, `{root}/data3` }
  local vfs = lib.VFS.fromDirectories(dirs, { archives = { 'Packed.bsa' } })
  local lines = {}
  local function state(label: string)
    local keys = vfs:keys():toTable()
    local winners = {}
    for _, key in keys do
      local providers = vfs:providersFor(key)
      table.insert(winners, `{key}={#providers}:{describe(vfs:getFile(key))}`)
    end

    table.insert(lines, `{label}: {vfs:len()} {table.concat(winners, ' ')}`)
  end

  local function sorted(result: any): string
    if type(result) ~= 'table' or getmetatable(result) ~= nil then return describe(result) end

    local rows = {}
    for _, row in result do
      table.insert(rows, describe(row))
    end

    table.sort(rows)
    return table.concat(rows, ' ; ')
  end

  state 'start'
  for step = 1, 40 do
    local keys = vfs:keys():toTable()
    local key = if #keys > 0 and random(4) > 0 then pick(random, keys) else pick(random, Names)
    local spelled = if random(2) == 0 then string.upper(key) else key
    local action = random(13)
    local label: string
    local ok, result: any
    if action == 0 then
      label = 'setWinnerLooseFile'
      ok, result = pcall(vfs.setWinnerLooseFile, vfs, spelled, `{root}/data1/{pick(random, Names)}`)
    elseif action == 1 then
      label = 'setWinnerFile'
      ok, result = pcall(vfs.setWinnerFile, vfs, spelled, lib.VfsFile.from(`{root}/data2/x`))
    elseif action == 2 then
      label = 'pushDirectory'
      ok, result = pcall(vfs.pushDirectory, vfs, pick(random, dirs))
    elseif action == 3 then
      label = 'pushProvider'
      local provider = lib.VfsProvider.new(
        { path = pick(random, dirs), kind = pick(random, { 'looseDir', 'archive' }) },
        lib.VfsFile.from(`{root}/elsewhere`)
      )
      ok, result = pcall(vfs.pushProvider, vfs, spelled, provider)
    elseif action == 4 then
      label = 'pushArchive'
      ok, result = pcall(
        vfs.pushArchive,
        vfs,
        `{root}/data1/{pick(random, { 'Packed.bsa', 'Fourth.bsa', 'Broken.bsa' })}`
      )
    elseif action == 5 then
      label = 'removeWinner'
      ok, result = pcall(vfs.removeWinner, vfs, spelled)
      if ok and result then
        result = { tostring(result), describe(result:source()), describe(result:file()) }
      end
    elseif action == 6 then
      label = 'removeResolvedFile'
      ok, result = pcall(vfs.removeResolvedFile, vfs, spelled)
    elseif action == 7 then
      label = 'removeProviderPrefix'
      ok, result = pcall(vfs.removeProviderPrefix, vfs, string.match(spelled, '^[^/]*') or spelled)
    elseif action == 8 then
      label = 'removeResolvedPrefix'
      ok, result = pcall(vfs.removeResolvedPrefix, vfs, string.match(spelled, '^[^/]*') or spelled)
    elseif action == 9 then
      label = 'removeProvider'
      ok, result = pcall(vfs.removeProvider, vfs, spelled, pick(random, dirs))
    elseif action == 10 then
      label = 'removeSource'
      ok, result = pcall(vfs.removeSource, vfs, pick(random, dirs))
    elseif action == 11 then
      label = 'removeResolvedMatchingGlob'
      ok, result = pcall(
        vfs.removeResolvedMatchingGlob,
        vfs,
        pick(random, { '**/*.txt', 'meshes/**', '*', '?', '[', '**' })
      )
    else
      label = 'layer'
      local layer = vfs:layerIndex()
      ok, result =
        true, {
          describe(layer:sources()),
          describe(layer:keys()),
          attempt(root, function() return layer:lockManifest(vfs):toTable() end),
        }
    end

    table.insert(
      lines,
      `{step} {label} {describe(spelled)} {if ok then sorted(result) else `error {tostring(result)}`}`
    )
    state(tostring(step))
  end

  table.insert(lines, report(lib, vfs, dirs))
  return table.concat(lines, '\n')
end

suite.describe('mutation', function()
  suite.it('keeps stacks, winners and indexes like the crate', function()
    for index, seed in Seeds do
      local function prepare(root: string)
        local random = support.generator(seed + 991)
        randomTree(random, root, 3)
        buildArchives(root, random)
      end

      compare(
        `fs/mutate-{index}`,
        function(lib: any, root: string): string return mutate(lib, root, seed) end,
        prepare
      )
    end
  end)
end)

suite.describe('files', function()
  suite.it('read whole, positionally and through readers like the crate', function()
    local function prepare(root: string)
      local bytes = {}
      for index = 0, 999 do
        table.insert(bytes, string.char(index % 256))
      end

      support.writeTree(root, {
        ['data/Big.bin'] = table.concat(bytes),
        ['data/empty.bin'] = '',
        ['data/odd/\255.dat'] = 'odd',
      })
      local random = support.generator(5)
      buildArchives(root, random)
    end

    compare('fs/files', function(lib: any, root: string): string
      local vfs = lib.VFS.fromDirectories(
        { `{root}/data`, `{root}/data1` },
        { archives = { 'Packed.bsa', 'Fourth.bsa', 'General.ba2' } }
      )
      local lines = {}
      local function line(text: string) table.insert(lines, text) end

      for _, key in vfs:keys():toTable() do
        local file = vfs:getFile(key)
        line(`{key} {describe(file)} {tostring(file)}`)
        line(attempt(nil, file.size, file))
        line(attempt(nil, file.readAll, file))
        line(attempt(nil, file.readAllBuffer, file))
        for _, size in { 0, 8, 64, 2000 } do
          local target = buffer.create(size)
          for _, offset in { nil, 0, 4, size, size + 1, -1, 1.5 } do
            local readInto = if offset == nil
              then attempt(nil, file.readInto, file, target)
              else attempt(nil, file.readInto, file, target, offset)
            line(`readInto {size} {describe(offset)} {readInto} {describe(target)}`)
          end

          for _, window in
            {
              { 0 },
              { 16, 8, 4 },
              { 990 },
              { 1000 },
              { 1001 },
              { -1 },
              { 0, 65 },
              { 0, 8, 60 },
              { 0, nil, size + 1, n = 3 },
              { 0, -3 },
              { 1.5 },
            }

          do
            local fresh = buffer.create(size)
            line(
              `readAt {size} {describe(window)} {attempt(
                nil,
                file.readAt,
                file,
                fresh,
                table.unpack(window, 1, window.n or #window)
              )} {describe(fresh)}`
            )
          end
        end

        for _, range in { { 0, 10 }, { 995, 100 }, { 1000, 1 }, { 1001, 1 }, { -1, 1 }, { 0, -1 } } do
          line(
            `readRange {describe(range)} {attempt(nil, file.readRange, file, range[1], range[2])}`
          )
        end

        local reader = file:open()
        line(`reader {describe(reader:size())} {describe(reader:tell())}`)
        local steps: { { any } } = {
          { 'read', 16 },
          { 'readInto', buffer.create(32) },
          { 'readInto', buffer.create(32), 8, 4 },
          { 'skip', 200 },
          { 'tell' },
          { 'read', 2000 },
          { 'read', 10 },
          { 'seek', 10 },
          { 'read', 1 },
          { 'seek', 5000 },
          { 'seek', -1 },
          { 'skip', 100000 },
          { 'read', -1 },
          { 'readInto', buffer.create(32), 33 },
          { 'readInto', buffer.create(32), 0, 40 },
          { 'close' },
          { 'read', 1 },
          { 'seek', 0 },
          { 'tell' },
          { 'size' },
          { 'close' },
        }

        for _, step in steps do
          local method = step[1] :: string
          line(`reader {method} {attempt(nil, reader[method], reader, table.unpack(step, 2))}`)
        end
      end

      local missing = lib.VfsFile.from(`{root}/definitely/missing`)
      for _, method in
        { 'readAll', 'readAllBuffer', 'size', 'open', 'path', 'fileName', 'fileStem', 'isLoose' }

      do
        line(`missing {method} {attempt(nil, missing[method], missing)}`)
      end

      line(attempt(nil, missing.readAt, missing, buffer.create(4), 0))
      line(attempt(nil, missing.readInto, missing, buffer.create(4)))
      local folder = lib.VfsFile.from(root)
      line(attempt(nil, folder.readAll, folder))
      line(attempt(nil, folder.readAllBuffer, folder))
      line(tostring(lib.VfsProvider.new({ path = 'x', kind = 'looseDir' }, folder)))
      return table.concat(lines, '\n')
    end, prepare)
  end)
end)

suite.describe('writing out', function()
  suite.it('dumps, collapses, extracts and diffs like the crate', function()
    for index, seed in Seeds do
      local function prepare(root: string)
        local random = support.generator(seed + 5150)
        randomTree(random, root, 3)
        buildArchives(root, random)
      end

      compare(`fs/materialize-{index}`, function(lib: any, root: string): string
        local dirs = { `{root}/data1`, `{root}/data2`, `{root}/data3` }
        local vfs = lib.VFS.fromDirectories(dirs, { archives = { 'Packed.bsa', 'General.ba2' } })
        local lines = {}
        local function line(text: string) table.insert(lines, text) end

        for _, hardlinks in { true, false } do
          local out = `{root}/dump-{hardlinks}`
          line(`dump {hardlinks} {attempt(root, vfs.dumpToDirectory, vfs, out, hardlinks)}`)
          line(support.listing(out))
        end

        for _, options in
          {
            {},
            { allowCopying = true },
            { extractArchives = true },
            { useSymlinks = true },
            { extractArchives = true, allowCopying = true },
            { bogus = true },
          }

        do
          local out = `{root}/collapse-{support.digest(describe(options))}`
          line(`collapse {describe(options)} {attempt(root, vfs.collapseInto, vfs, out, options)}`)
          line(support.listing(out))
          line(
            `plan {describe(options)} {attempt(root, vfs.materializationPlan, vfs, out, options)}`
          )
        end

        for _, key in vfs:keys():toTable() do
          line(
            `extract {describe(key)} {attempt(root, vfs.extractFile, vfs, key, `{root}/extracted`)}`
          )
        end

        line(`extract missing {attempt(root, vfs.extractFile, vfs, 'no/such', `{root}/extracted`)}`)
        line(support.listing(`{root}/extracted`))
        local diff = vfs:diffDirectory(`{root}/data2`)
        local function rows(list: { any }): string
          local out = {}
          for _, row in list do
            table.insert(out, describe(row))
          end

          table.sort(out)
          return table.concat(out, ' ; ')
        end

        line(`diff conflicts {rows(diff.conflicts)}`)
        line(`diff additions {rows(diff.additions)}`)
        line(`diff unreadable {rows(diff.unreadable)}`)
        local missing = vfs:diffDirectory(`{root}/no-such-folder`)
        line(
          `diff missing {rows(missing.conflicts)} {rows(missing.additions)} {rows(
            missing.unreadable
          )}`
        )
        return table.concat(lines, '\n')
      end, prepare)
    end
  end)

  suite.it('runs the setup and finalize workflow like the crate', function()
    local function prepare(root: string)
      randomTree(support.generator(77), root, 2)
      buildArchives(root, support.generator(78))
    end

    compare('fs/run', function(lib: any, root: string): string
      local vfs = lib.VFS.fromDirectories(
        { `{root}/data1`, `{root}/data2` },
        { archives = { 'Packed.bsa' } }
      )
      local lines = {}
      local function line(text: string) table.insert(lines, text) end

      for _, tracked in { false, true } do
        for _, hardlinks in { false, true } do
          local merged = `{root}/merged-{tracked}-{hardlinks}`
          local setup = if tracked then lib.runSetupTracked else lib.runSetup
          local finalize = if tracked then lib.runFinalizeTracked else lib.runFinalize
          local changed = if tracked then lib.changedFilesMetadata else lib.changedFiles
          local ok, count, snapshot = pcall(setup, vfs, merged, hardlinks)
          line(
            `setup {tracked} {hardlinks} {ok} {describe(count)} {if ok
              then describe(snapshot:len())
              else ''}`
          )
          if not ok then continue end

          line(support.listing(merged))
          line(`changed none {attempt(root, changed, merged, snapshot)}`)
          fs.mkdir(`{merged}/new`, { recursive = true })
          fs.writeFile(`{merged}/new/file.txt`, 'new')
          local first = fs.walk(merged, { include = 'files', sort = true }).paths[1]
          if first then fs.writeFile(`{merged}/{first}`, 'rewritten in place', { offset = 0 }) end

          line(`changed {attempt(root, changed, merged, snapshot)}`)
          line(
            `finalize {attempt(
              root,
              finalize,
              merged,
              `{root}/output-{tracked}-{hardlinks}`,
              snapshot
            )}`
          )
          line(support.listing(`{root}/output-{tracked}-{hardlinks}`))
          line(
            `finalize again {attempt(
              root,
              finalize,
              merged,
              `{root}/output-{tracked}-{hardlinks}`,
              snapshot
            )}`
          )
          line(
            `wrong snapshot {attempt(
              root,
              if tracked then lib.runFinalize else lib.runFinalizeTracked,
              merged,
              `{root}/x`,
              snapshot
            )}`
          )
        end
      end

      local snapshot = lib.snapshotDirectory(`{root}/data1`)
      line(`snapshot {snapshot:len()} {attempt(root, lib.changedFiles, `{root}/data1`, snapshot)}`)
      line(`snapshot missing {attempt(root, lib.snapshotDirectory, `{root}/no-such`)}`)
      line(
        `snapshot metadata {attempt(
          root,
          function() return lib.snapshotDirectoryMetadata(`{root}/data2`):len() end
        )}`
      )
      fs.writeFile(`{root}/a-file`, 'x')
      line(`setup over a file {attempt(root, lib.runSetup, vfs, `{root}/a-file`, false)}`)
      return table.concat(lines, '\n')
    end, prepare)
  end)
end)

suite.describe('writes under a write root', function()
  suite.it('write, open, move and remove like the crate', function()
    local function prepare(root: string)
      support.writeTree(root, { ['base/textures/a.dds'] = 'old', ['base/keep.txt'] = 'keep' })
      fs.mkdir(`{root}/out/real`, { recursive = true })
      fs.symlink(`{root}/out/real`, `{root}/out/link`, { directory = true })
      fs.symlink('/', `{root}/out/escape`, { directory = true })
    end

    compare('fs/writes', function(lib: any, root: string): string
      local lines = {}
      local function line(text: string) table.insert(lines, text) end

      local vfs = lib.VFS.fromDirectories({ `{root}/base` }, { writeRoot = `{root}/out` })
      line(`writeRoot {describe(vfs:writeRoot())}`)
      local steps: { { any } } = {
        { 'writeFile', 'textures/a.dds', 'new' },
        { 'writeFile', 'new/deep/b.bin', buffer.fromstring 'bufferdata' },
        { 'writeFile', 'textures/a.dds', 'XY', { offset = 1 } },
        { 'writeFile', 'textures/a.dds', 'Z', { append = true } },
        { 'writeFile', 'textures/a.dds', 'Z', { append = true, offset = 1 } },
        { 'writeFile', 'textures/a.dds', 'Z', { bogus = true } },
        { 'writeFile', 'textures/a.dds', 'Z', { offset = -1 } },
        { 'writeFile', 'missing.txt', 'Z', { create = false } },
        { 'writeFile', '../escape.txt', 'x' },
        { 'writeFile', '/abs.txt', 'x' },
        { 'writeFile', 'c:drive.txt', 'x' },
        { 'writeFile', 'nul\0.txt', 'x' },
        { 'writeFile', 'link/inside.txt', 'x' },
        { 'writeFile', 'escape/etc/passwd', 'x' },
        { 'writeFile', 'textures', 'x' },
        { 'writeFile', 'Mixed\\Case.TXT', 'mixed' },
        { 'mkdir', 'made/folder' },
        { 'mkdir', '../nope' },
        { 'rename', 'new/deep/b.bin', 'moved/b.bin' },
        { 'rename', 'nope.txt', 'x.txt' },
        { 'rename', 'made', 'renamed' },
        { 'remove', 'textures/nope.dds' },
        { 'remove', 'moved' },
        { 'remove', 'mixed/case.txt' },
        { 'remove', 'Mixed/Case.TXT' },
      }

      for _, step in steps do
        local method = step[1] :: string
        line(
          `{method} {describe(step[2])} {attempt(root, vfs[method], vfs, table.unpack(step, 2))}`
        )
        line(`  keys {describe(vfs:keys())}`)
      end

      local writer = vfs:openWrite 'log.txt'
      line(`writer {support.scrub(tostring(writer), root)}`)
      local calls: { { any } } = {
        { 'write', 'hello ' },
        { 'write', buffer.fromstring 'xxworldxx', 2, 5 },
        { 'writeAt', 0, 'J' },
        { 'tell' },
        { 'write', 'x', 5 },
        { 'write', 'x', -1 },
        { 'seek', 5 },
        { 'truncate', 5 },
        { 'tell' },
        { 'flush' },
        { 'close' },
        { 'close' },
        { 'write', 'more' },
      }

      for _, call in calls do
        local method = call[1] :: string
        line(`writer {method} {attempt(root, writer[method], writer, table.unpack(call, 2))}`)
      end

      line(
        `after close {describe(vfs:getFile 'log.txt')} {attempt(
          root,
          function() return vfs:getFile('log.txt'):readAll() end
        )}`
      )
      local appender = vfs:openWrite('log.txt', { append = true })
      line(
        `append tell {appender:tell()} {attempt(root, appender.writeAt, appender, 0, 'x')} {attempt(
          root,
          appender.write,
          appender,
          '!'
        )}`
      )
      appender:close()
      local keeper = vfs:openWrite('log.txt', { truncate = false })
      keeper:write 'H'
      keeper:close()
      line(`kept {attempt(root, function() return vfs:getFile('log.txt'):readAll() end)}`)
      line(`openWrite bad option {attempt(root, vfs.openWrite, vfs, 'x', { mode = 'w' })}`)
      line(
        `setWriteRoot {attempt(root, vfs.setWriteRoot, vfs, `{root}/second`)} {describe(
          vfs:writeRoot()
        )}`
      )
      local plain = lib.VFS.new()
      line(`no root {attempt(root, plain.writeFile, plain, 'a', 'b')}`)
      line(`no root mkdir {attempt(root, plain.mkdir, plain, 'a')}`)
      line(support.listing(`{root}/out`))
      return table.concat(lines, '\n')
    end, prepare)
  end)
end)

suite.describe('the host table', function()
  suite.it('reads, writes and lists host paths like the crate', function()
    local function prepare(root: string)
      support.writeTree(
        root,
        { ['a.txt'] = '0123456789', ['sub/b.txt'] = 'b', ['sub/deeper/c.txt'] = 'c' }
      )
      fs.symlink(`{root}/sub`, `{root}/link`, { directory = true })
    end

    compare('fs/host', function(lib: any, root: string): string
      local host = lib.host
      local lines = {}
      local function line(text: string) table.insert(lines, text) end

      line(`readFile {attempt(root, host.readFile, `{root}/a.txt`)}`)
      line(`readFileString {attempt(root, host.readFileString, `{root}/a.txt`)}`)
      for _, window in { { 0, 4 }, { 8, 10 }, { 10, 1 }, { 11, 1 }, { -1, 1 }, { 0, -1 } } do
        line(
          `readAt {describe(window)} {attempt(
            root,
            host.readAt,
            `{root}/a.txt`,
            window[1],
            window[2]
          )}`
        )
      end

      line(`readFile missing {attempt(root, host.readFile, `{root}/missing`)}`)
      line(`stat {attempt(root, function()
        local stat = host.stat(`{root}/a.txt`)
        return { stat.size, stat.isFile, stat.isDir, stat.readonly, stat.modified ~= nil }
      end)}`)
      line(`stat dir {attempt(root, function()
        local stat = host.stat(`{root}/sub`)
        return { stat.size, stat.isFile, stat.isDir }
      end)}`)
      line(`stat missing {attempt(root, host.stat, `{root}/missing`)}`)
      line(
        `exists {attempt(root, host.exists, `{root}/a.txt`)} {attempt(
          root,
          host.exists,
          `{root}/missing`
        )}`
      )
      line(`list {attempt(root, host.list, root)}`)
      line(`list recursive {attempt(root, host.list, root, { recursive = true })}`)
      line(`list missing {attempt(root, host.list, `{root}/missing`)}`)
      line(
        `list missing recursive {attempt(root, host.list, `{root}/missing`, { recursive = true })}`
      )
      line(`list bad option {attempt(root, host.list, root, { deep = true })}`)
      line(`writeFile {attempt(root, host.writeFile, `{root}/w.txt`, 'abc')}`)
      line(
        `writeFile append {attempt(
          root,
          host.writeFile,
          `{root}/w.txt`,
          buffer.fromstring 'def',
          { append = true }
        )}`
      )
      line(`writeFile offset {attempt(root, host.writeFile, `{root}/w.txt`, 'x', { offset = 1 })}`)
      line(
        `mkdir {attempt(root, host.mkdir, `{root}/m/n`)} {attempt(
          root,
          host.mkdir,
          `{root}/m/n`,
          { recursive = true }
        )}`
      )
      line(`copy {attempt(root, host.copy, `{root}/w.txt`, `{root}/m/n/w.txt`)}`)
      line(`rename {attempt(root, host.rename, `{root}/m/n/w.txt`, `{root}/m/w.txt`)}`)
      line(
        `remove {attempt(root, host.remove, `{root}/m`)} {attempt(
          root,
          host.remove,
          `{root}/m`,
          { recursive = true }
        )}`
      )
      line(`remove link {attempt(root, host.remove, `{root}/link`)}`)
      line(
        `canonicalize {attempt(root, host.canonicalize, `{root}/sub/../a.txt`)} {attempt(
          root,
          host.canonicalize,
          `{root}/missing`
        )}`
      )
      local reader = host.open(`{root}/a.txt`)
      line(
        `open {support.scrub(tostring(reader), root)} {reader:size()} {describe(reader:read(4))}`
      )
      local writer = host.openWrite(`{root}/o.txt`)
      writer:write 'data'
      line(
        `openWrite {attempt(root, writer.close, writer)} {attempt(
          root,
          host.readFileString,
          `{root}/o.txt`
        )}`
      )
      line(support.listing(root))
      return table.concat(lines, '\n')
    end, prepare)
  end)
end)

suite.describe('arguments', function()
  suite.it('refuse what the binding refused, with its messages', function()
    compare('args', function(lib: any, root: string): string
      local vfs = lib.VFS.new()
      local file = lib.VfsFile.from(`{root}/x`)
      local layer = vfs:layerIndex()
      local lines = {}
      for _, call in
        {
          { lib.VFS.fromDirectories, 1 },
          { lib.VFS.fromDirectories, { 1 } },
          { lib.VFS.fromDirectories, {}, { archive = { 'x' } } },
          { lib.VFS.fromDirectories, {}, { archives = 'x' } },
          { lib.VFS.fromDirectories, {}, { archives = { 1 } } },
          { lib.VFS.fromDirectories, {}, 'x' },
          { lib.VFS.fromDirectoriesWithConflictIndex, 1 },
          { lib.VFS.fromDirectoriesWithLayerIndex, {}, { bad = 1 } },
          { vfs.getFile, vfs, 42 },
          { vfs.getFile, 42, 'x' },
          { vfs.findByRegex, vfs, '(' },
          { vfs.findByRegex, vfs, 1 },
          { vfs.remaining, vfs, 'x', false, 1 },
          { vfs.remaining, vfs, 'x', 1, {} },
          { vfs.collapseInto, vfs, root, { allow_copying = true } },
          { vfs.materializationPlan, vfs, root, { useSymlinks = 1 } },
          { vfs.dumpToDirectory, vfs, root, 'yes' },
          { vfs.setWinnerFile, vfs, 'x', 'notafile' },
          { vfs.pushProvider, vfs, 'x', 'notaprovider' },
          { vfs.serializeTree, vfs, true, 'xml' },
          { file.readAt, file, buffer.create(8), 1.5 },
          { file.readAt, file, buffer.create(8), 'x' },
          { file.readAt, file, 'x', 0 },
          { file.open, 42 },
          { lib.VfsFile.from, 1 },
          { lib.VfsProvider.new, { path = 'x', kind = 'weird' }, file },
          { lib.VfsProvider.new, { path = 1, kind = 'looseDir' }, file },
          { lib.VfsProvider.new, { path = 'x' }, file },
          { lib.VfsProvider.new, { path = 'x', kind = 'looseDir', extra = 1 }, file },
          { lib.VfsProvider.new, { path = 'x', kind = 'looseDir' }, 'notafile' },
          { lib.LayerIndex.fromFileLists, { { source = { path = 'x' }, files = {} } } },
          {
            lib.LayerIndex.fromFileLists,
            { { source = { path = 'x', kind = 'looseDir' }, files = 'x' } },
          },

          {
            lib.LayerIndex.fromFileLists,
            { { source = { path = 'x', kind = 'looseDir' }, files = { 1 } } },
          },
          { lib.LayerIndex.fromFileLists, { 'x' } },
          { lib.ConflictIndex.fromFileLists, { { source = 'x', files = { 1 } } } },
          { lib.ConflictIndex.fromFileLists, { { files = {} } } },
          { lib.ConflictIndex.fromLayerIndex, 'x' },
          { layer.sourceById, layer, 0 },
          { layer.providerOriginalPath, layer, 0, 'x' },
          { layer.semanticConflicts, layer, vfs, { archiveHashMode = 'sometimes' } },
          { layer.semanticConflicts, layer, vfs, { other = true } },
          { layer.semanticConflicts, layer, 'notavfs' },
          { layer.lockManifest, layer, 'notavfs' },
          { layer.diffAgainstLock, layer, vfs, 'notalock' },
          { lib.serialize, {}, 'xml' },
          { lib.runSetup, 'notavfs', root, false },
          { lib.runFinalize, root, root, 'notasnapshot' },
          { lib.host.readFile, 1 },
          { lib.host.list, root, { deep = true } },
          { lib.host.writeFile, `{root}/a`, 1 },
        }

      do
        table.insert(lines, attempt(root, table.unpack(call)))
      end

      local layers = lib.LayerIndex.fromFileLists {
        {
          source = { path = 'base', kind = 'looseDir' },
          files = { 'A.txt', 'dir/B.txt', 'a.txt' },
        },
        { source = { path = 'mod', kind = 'archive' }, files = { 'a.txt', '../escape', '' } },
      }
      table.insert(lines, describe(layers:keys()))
      table.insert(lines, describe(layers:providerChain 'a.txt'))
      table.insert(lines, describe(layers:sourceContributions()))
      local conflicts = lib.ConflictIndex.fromFileLists {
        { source = 'base', files = { 'a.txt', 'b.txt' } },
        { source = 'mod', files = { 'A.TXT' } },
      }
      table.insert(lines, describe(conflicts:conflictsReport(false)))
      table.insert(lines, describe(conflicts:shadowedReport()))
      table.insert(lines, describe(conflicts:diffReport('base', 'mod')))
      return table.concat(lines, '\n')
    end)
  end)
end)

if dataFiles then
  suite.describe('real data', function()
    suite.it('reads a Data Files folder in place like the crate', function()
      compare('real/data-files', function(lib: any): string
        local vfs = lib.VFS.fromDirectories(
          { dataFiles },
          { archives = { 'Morrowind.bsa', 'Tribunal.bsa', 'Bloodmoon.bsa' } }
        )
        local lines = { tostring(vfs), describe(vfs:archives()), describe(vfs:keys()) }
        for index, key in vfs:keys():toTable() do
          if index % 97 ~= 1 then continue end

          local file = vfs:getFile(key)
          table.insert(
            lines,
            `{key} {describe(file)} {attempt(nil, file.size, file)} {support.digest(file:readAll())}`
          )
        end

        local layer = vfs:layerIndex()
        table.insert(lines, describe(layer:sourceContributions()))
        table.insert(lines, describe(vfs:duplicates '^meshes/'))
        return support.scrub(table.concat(lines, '\n'), dataFiles)
      end, nil, false)
    end)
  end)
end

suite.describe('goldens', function()
  suite.it('cover every case, and are rewritten when blessing', function()
    if bless then
      fs.writeFile(goldenPath, table.concat(recorded, '\n') .. '\n')
      return
    end

    for name in golden do
      if not seenNames[name] then
        error(`the golden {name} names no case; rerun with JESS_BLESS=1`, 0)
      end
    end
  end)
end)

return suite
