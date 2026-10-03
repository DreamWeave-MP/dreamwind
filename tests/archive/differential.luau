--!strict
--!native
-- The port against the dream_archive crate, case by case, through the crate's answers. Every case
-- makes one observation through `@dreamwind/archive`: builder outcomes and bytes, every entry
-- field, every read, the lookups, and the errors (codec details aside, which the codec libraries
-- word differently), and its digest must be the one `golden/differential.txt` holds. Those were
-- recorded from the crate's own binding (`@dream/archive` and `@dream/archivetool`, 1.1.0) while
-- jess linked it, with the port agreeing on every case. jess doesn't link it any more, so the
-- goldens are what's left of the crate, and they don't move: `bless = true` records the port's
-- answer only for a case without a golden. A golden that has to change is deleted from the file
-- by hand, and the commit that does it says why the port answers differently now.
--
-- The harness (`libs/lua/tests/archive_experiment.rs`) sets `scratchRoot` for the filesystem
-- cases, `linkRoot` for the symbolic link ones, `archiveFixtures` for dream_archive's large
-- fixtures, and `realArchives` for archives named by `JESS_DATA_FILES` and `JESS_ARCHIVES`; the
-- cases needing them are skipped otherwise.
local port = require '@dreamwind/archive'
local support = require './support'
local test = require '@jess/test'
local host = require('@dream/vfs').host
local expect = test.expect
local suite = test.new()

local globals = _G :: any
local function setting(name: string): any return rawget(globals, name) or support.settings[name] end

local bless = setting 'bless' == true
local scratch = setting 'scratchRoot' :: string?
local fixtureRoot = setting 'archiveFixtures' :: string?
local realArchives = setting 'realArchives' :: { string }?
local links = setting 'linkRoot' :: string?
local goldenPath = setting 'goldenPath' or `{support.here()}/golden/differential.txt`

local golden: { [string]: string } = {}
if host.exists(goldenPath) then
  for name, value in string.gmatch(host.readFileString(goldenPath), '([^\t\n]+)\t([^\n]+)') do
    golden[name] = value
  end
end

local recorded: { string } = {}
local seenNames: { [string]: boolean } = {}

--- One case: the digest of the port's observation is the golden one.
local function compare(name: string, observe: (module: any) -> string)
  assert(not seenNames[name], `case names are unique: {name}`)
  seenNames[name] = true
  local mine = observe(port)
  local digest, expected = support.digest(mine), golden[name]
  table.insert(recorded, `{name}\t{expected or digest}`)
  if not expected then
    if bless then return end

    error(`{name}: no golden; JESS_BLESS=1 records the port's answer for a new case`, 0)
  end

  if expected ~= digest then
    error(`{name}: the observation's digest {digest} is not the golden {expected}:\n{mine}`, 0)
  end
end

local function observeBytes(data: string): (module: any) -> string
  return function(module: any): string return support.observe(module, data) end
end

local random = support.generator(0x5eed_a2c4)

local Vocabulary = {
  'meshes',
  'Textures',
  'SOUND',
  'x',
  'a b',
  'door.nif',
  'Foo.NIF',
  'readme.txt',
  'icon.dds',
  'voice.fuz',
  'clip.kf',
  'noise.wav',
  'speech.adp',
  'no_extension',
  '.hidden',
  'dots.in.name.txt',
  'Mar\237a_F.fuz',
  'zażółć.dds',
  'ünïcode',
}

local Separators = { '/', '\\', '//', '\\\\', '/\\' }

local function pick<T>(list: { T }): T return list[random(#list) + 1] end

--- A random archive path: mostly well-formed, sometimes with what builders refuse.
local function randomPath(): string
  local depth = random(4)
  local parts = {}
  for _ = 1, depth do
    table.insert(parts, pick(Vocabulary))
    table.insert(parts, pick(Separators))
  end

  table.insert(parts, pick(Vocabulary))
  local path = table.concat(parts)
  local roll = random(100)
  if roll < 4 then return `../{path}` end

  if roll < 6 then return `c:{path}` end

  if roll < 8 then return `{path}\0x` end

  if roll < 10 then return `/{path}` end

  if roll < 12 then return '' end

  if roll < 14 then return `{path}/.` end

  if roll < 16 then return string.rep('long', 70) .. path end

  if roll < 20 then return string.upper(path) end

  return path
end

local function randomPayload(): string
  local roll = random(10)
  local size = if roll < 2 then random(4) else random(3000)
  if roll < 5 then return string.rep(pick { 'abc', 'payload ', '\0', 'zz' }, size // 3 + 1) end

  local parts = table.create(size)
  for index = 1, size do
    parts[index] = string.char(random(256))
  end

  return table.concat(parts)
end

type Op = { kind: string, args: { any } }
type Recipe = { family: string, settings: { Op }, ops: { Op } }

local function op(kind: string, ...: any): Op return { kind = kind, args = { ... } } end

local function texture(): support.Texture
  local format = if random(20) == 0 then 2 else pick(support.Formats)
  local width, height = 2 ^ random(7), 2 ^ random(7)
  if random(5) == 0 then width = random(70) + 1 end

  local cube = random(6) == 0
  if cube then height = width end

  local mips = 1
  while mips < 8 and bit32.rshift(math.max(width, height), mips) > 0 and random(3) > 0 do
    mips += 1
  end

  return {
    height = height,
    width = width,
    mipCount = mips,
    format = format,
    flags = if cube then 1 else 0,
    tileMode = random(4),
  }
end

local function texturePayload(header: support.Texture): string
  local size = support.mipBytes(header, 0, header.mipCount - 1)
  if random(15) == 0 then
    size += 1
  end

  return string.rep(string.char(random(256)), size)
end

local function recipe(family: string): Recipe
  local settings, ops = {}, {}
  if family == 'tes4' then
    if random(2) == 0 then
      table.insert(settings, op('setVersion', pick { 103, 104, 105, 105, 102 }))
    end

    if random(3) == 0 then
      table.insert(
        settings,
        op(
          'setProfile',
          pick { 'oblivion', 'fallout3', 'falloutNewVegas', 'skyrimLe', 'skyrimSe', 'arena' }
        )
      )
    end

    if random(2) == 0 then
      table.insert(
        settings,
        op(
          'setNameMode',
          pick { 'strings', 'hashOnly', 'embedded', 'stringsAndEmbedded', 'hash_only' }
        )
      )
    end

    if random(2) == 0 then table.insert(settings, op('setCompressed', random(2) == 0)) end

    if random(3) == 0 then
      table.insert(settings, op('setArchiveTypes', pick { 1, 2, 0x100, 0x1ff, 70000 }))
    end

    if random(3) == 0 then table.insert(settings, op('setZlibLevel', pick { 0, 1, 6, 9, 10 })) end
  elseif family == 'ba2' or family == 'dx10' then
    if random(2) == 0 then
      table.insert(settings, op('setVersion', pick { 1, 2, 3, 3, 7, 8, 4 }))
    end

    if random(2) == 0 then
      table.insert(
        settings,
        op('setCompression', pick { 'none', 'store', 'zip', 'lz4', 'lz4', 'deflate' })
      )
    end

    if random(3) == 0 then table.insert(settings, op('setZlibLevel', pick { 0, 3, 9, 12 })) end
  end

  for _ = 1, random(14) do
    local path = randomPath()
    if family == 'dx10' then
      local header = texture()
      local roll = random(4)
      if roll == 0 then
        table.insert(ops, op('addTextureBytes', path, header, texturePayload(header)))
      else
        local style = pick { 'legacy', 'plain', 'dx10', 'dx10' }
        local array = if random(12) == 0 then pick { 0, 2, 6 } else nil
        local volume = random(25) == 0
        local payload = texturePayload(header)
        table.insert(
          ops,
          op('addDdsBytes', path, support.ddsFile(header, payload, style, array, volume))
        )
      end
    else
      local roll = random(10)
      if roll == 0 and family ~= 'tes3' then
        table.insert(
          ops,
          op(
            'addBytesWithCompression',
            path,
            randomPayload(),
            pick { 'inherit', 'store', 'compress', 'squash' }
          )
        )
      elseif roll == 1 and family ~= 'ba2' then
        table.insert(
          ops,
          op(
            'addEncodedPath',
            pick { 'textures/zażółć.dds', 'привет/x.txt', 'éöü.txt', '你好.txt' },
            pick { 'utf8', 'windows1250', 'windows1251', 'windows1252', 'cp437' },
            randomPayload()
          )
        )
      else
        table.insert(ops, op('addBytes', path, randomPayload()))
      end
    end
  end

  return { family = family, settings = settings, ops = ops }
end

local function builderFor(module: any, family: string): any
  if family == 'tes3' then return module.bsa.tes3.Builder.new() end

  if family == 'tes4' then return module.bsa.tes4.Builder.new() end

  if family == 'dx10' then return module.ba2.Dx10Builder.new() end

  return module.ba2.Builder.new()
end

--- Runs a recipe and describes every outcome; the archive's bytes, if it built, come back too.
local function runRecipe(module: any, plan: Recipe): (string, string?)
  local log = {}
  local builder = builderFor(module, plan.family)
  for _, step in plan.settings do
    local ok, problem = pcall(builder[step.kind], builder, table.unpack(step.args))
    table.insert(log, `{step.kind} {if ok then 'ok' else support.errorText(problem)}`)
  end

  for _, step in plan.ops do
    local args = step.args
    if step.kind == 'addTextureBytes' then args = { args[1], table.clone(args[2]), args[3] } end

    local ok, problem = pcall(builder[step.kind], builder, table.unpack(args))
    table.insert(log, `{step.kind} {if ok then 'ok' else support.errorText(problem)}`)
  end

  table.insert(log, `len {builder:len()} empty {builder:isEmpty()}`)
  local built, data = pcall(builder.toBytes, builder)
  if not built then
    table.insert(log, `toBytes: {support.errorText(data)}`)
    return table.concat(log, '\n'), nil
  end

  table.insert(log, `toBytes {#data} {support.digest(data)}`)
  local asBuffer = builder:toBuffer()
  table.insert(log, `toBuffer same {buffer.tostring(asBuffer) == data}`)
  return table.concat(log, '\n'), data
end

local corpus: { { name: string, data: string } } = {}

suite.describe('builders', function()
  for _, family in { 'tes3', 'tes4', 'ba2', 'dx10' } do
    for index = 1, 40 do
      local plan = recipe(family)
      local name = `build/{family}/{index}`
      suite.it(name, function()
        local data: string? = nil
        compare(name, function(module: any): string
          local log, built = runRecipe(module, plan)
          data = built
          return log
        end)

        if data then
          table.insert(corpus, { name = name, data = data :: string })
          compare(`{name}/read`, observeBytes(data :: string))
        end
      end)
    end
  end

  suite.it('build/carried entries', function()
    compare('build/carried', function(module: any): string
      local log = {}
      local sources: { [string]: any } = {}
      local tes4 = module.bsa.tes4.Builder.new()
      tes4:setCompressed(true)
      tes4:addBytes('data/a.txt', string.rep('carried', 50))
      sources.tes4 = module.openBytes(tes4:toBytes())
      local tes3 = module.bsa.tes3.Builder.new()
      tes3:addBytes('data/a.txt', 'tes3 carried')
      sources.tes3 = module.openBytes(tes3:toBytes())
      local ba2 = module.ba2.Builder.new()
      ba2:setCompression 'zip'
      ba2:addBytes('data/a.txt', string.rep('ba2', 70))
      sources.ba2 = module.openBytes(ba2:toBytes())
      local dx10 = module.ba2.Dx10Builder.new()
      dx10:addTextureBytes(
        'textures/a.dds',
        { height = 4, width = 4, mipCount = 3, format = 61, flags = 0, tileMode = 8 },
        string.rep('t', 21)
      )
      sources.dx10 = module.openBytes(dx10:toBytes())
      for _, target in { 'tes3', 'tes4', 'ba2', 'dx10' } do
        for from, source in sources do
          for _, id in { 0, 1, 2, 1.5 } do
            local builder = builderFor(module, target)
            local method = if target == 'dx10' then 'addArchiveEntry' else 'addArchiveEntry'
            local ok, problem = pcall(builder[method], builder, 'copied/a.bin', source, id)
            local line =
              `{target} from {from} id {id}: {if ok then 'ok' else support.errorText(problem)}`
            if ok then
              local built, data = pcall(builder.toBytes, builder)
              line ..= if built
                then ` built {support.digest(data)}`
                else ` toBytes: {support.errorText(data)}`
            end

            table.insert(log, line)
          end
        end
      end

      for _, mode in { 'store', 'compress', 'inherit', nil :: string? } do
        for _, target in { 'tes4', 'ba2' } do
          local builder = builderFor(module, target)
          local ok, problem = pcall(
            builder.addArchiveEntryWithCompression,
            builder,
            'a.bin',
            sources[target],
            1,
            mode
          )
          table.insert(
            log,
            `{target} with {mode}: {if ok
              then support.digest(builder:toBytes())
              else support.errorText(problem)}`
          )
        end
      end

      local version = module.ba2.Dx10Builder.new()
      version:setVersion(8)
      version:addArchiveEntry('x.dds', sources.dx10, 1)
      local ok, problem = pcall(version.toBytes, version)
      table.insert(log, `dx10 version mismatch: {if ok then 'ok' else support.errorText(problem)}`)
      local lz4 = module.ba2.Dx10Builder.new()
      lz4:setVersion(3)
      lz4:setCompression 'lz4'
      lz4:addArchiveEntry('x.dds', sources.dx10, 1)
      ok, problem = pcall(lz4.toBytes, lz4)
      table.insert(
        log,
        `dx10 compression mismatch: {if ok then 'ok' else support.errorText(problem)}`
      )
      return table.concat(log, '\n')
    end)
  end)
end)

local tes3Hash = port.bsa.tes3.hashFile
local tes4Directory, tes4File = port.bsa.tes4.hashDirectory, port.bsa.tes4.hashFile

--- Archives the builders can't make, written by hand.
local function handMade(): { { name: string, data: string } }
  local made = {}
  local function add(name: string, data: string) table.insert(made, { name = name, data = data }) end

  for index = 1, 12 do
    local files = {}
    for _ = 1, random(8) do
      table.insert(files, { name = randomPath(), data = randomPayload() })
    end

    add(`tes3/{index}`, support.tes3(files, tes3Hash))
  end

  for index = 1, 30 do
    local version = pick { 103, 104, 105 }
    local flags = pick { 0, 1, 2, 3, 3, 0x100, 0x101, 0x102, 0x103 }
    if random(3) == 0 then
      flags += 4
    end

    if random(15) == 0 then
      flags += 0x200
    end

    if random(25) == 0 then
      flags += 0x40
    end

    local folders: { support.Tes4Folder } = {}
    for _ = 1, random(3) + 1 do
      local files: { support.Tes4File } = {}
      for _ = 1, random(4) + 1 do
        local compress = if random(2) == 0 then (if version == 105 then 'lz4' else 'zlib') else nil
        if random(12) == 0 then compress = if compress == 'lz4' then 'zlib' else 'lz4' end

        local compressedFlag = bit32.band(flags, 4) ~= 0
        table.insert(files, {
          name = pick(Vocabulary),
          data = randomPayload(),
          compress = compress,
          toggled = (compress ~= nil) ~= compressedFlag,
          checked = random(5) == 0,
          embedded = if random(6) == 0 then pick { 'other\\name.txt', 'flat.txt', '' } else nil,
        })
      end

      table.insert(
        folders,
        { name = pick { 'data', 'textures\\x', '.', 'meshes', '' }, files = files }
      )
    end

    add(
      `tes4/{index}`,
      support.tes4 {
        version = version,
        flags = flags,
        archiveTypes = random(0x200),
        folders = folders,
        padding = if random(5) == 0 then random(4) else nil,
        hashDirectory = tes4Directory,
        hashFile = tes4File,
      }
    )
  end

  -- LZ4 frames with the descriptor flags lz4_flex never writes, some of them spoiled.
  for index = 1, 16 do
    local data = string.rep(randomPayload(), random(40) + 1)
    local options: support.FrameOptions = {
      blockSize = 4 + random(2),
      blockChecksums = random(2) == 0,
      contentChecksum = random(2) == 0,
      contentSize = random(2) == 0,
      linked = random(6) == 0,
      stored = random(5) == 0,
    }
    add(
      `tes4/frame/{index}`,
      support.tes4 {
        version = 105,
        flags = 7,
        folders = {
          {
            name = 'data',
            files = { { name = 'frame.bin', data = data, compress = 'lz4', frame = options } },
          },
        },
        hashDirectory = tes4Directory,
        hashFile = tes4File,
      }
    )
  end

  for index = 1, 30 do
    local format = pick { 'GNRL', 'GNRL', 'DX10', 'DX10', 'GNMF' }
    local version = pick { 1, 2, 3, 7, 8 }
    local code = if version == 3 then pick { 0, 3, 3, 5 } else nil
    local codec = if code == 3 then 'lz4' else 'zip'
    local entries: { support.Ba2Entry } = {}
    for _ = 1, random(4) + 1 do
      local name = randomPath()
      if format == 'DX10' then
        local header = texture()
        if header.format == 2 then header.format = 61 end

        local chunks: { support.Ba2Chunk } = {}
        local mip = 0
        while mip < header.mipCount do
          local last = math.min(header.mipCount - 1, mip + random(3))
          local size = support.mipBytes(header, mip, last)
          if random(30) == 0 then
            size += 1
          end

          table.insert(chunks, {
            data = string.rep(string.char(random(256)), size),
            compress = if random(2) == 0 then codec else nil,
            first = mip,
            last = last,
          })
          mip = last + 1
        end

        if random(15) == 0 then table.remove(chunks) end

        table.insert(entries, { name = name, texture = header, chunks = chunks })
      else
        local chunks: { support.Ba2Chunk } = {}
        for _ = 1, if random(6) == 0 then 0 else random(3) + 1 do
          table.insert(chunks, {
            data = randomPayload(),
            compress = if random(2) == 0 then codec else nil,
            first = 0,
            last = 0,
          })
        end

        table.insert(entries, { name = name, chunks = chunks })
      end
    end

    if random(5) == 0 and #entries > 1 then entries[2].hash = port.ba2.hashFile(entries[1].name) end

    add(
      `ba2/{index}`,
      support.ba2 {
        version = version,
        format = format,
        compressionCode = code,
        strings = random(4) > 0,
        entries = entries,
        hashFile = port.ba2.hashFile,
      }
    )
  end

  return made
end

suite.describe('hand-made archives', function()
  for _, case in handMade() do
    local name = `made/{case.name}`
    table.insert(corpus, { name = name, data = case.data })
    suite.it(name, function() compare(name, observeBytes(case.data)) end)
  end
end)

--- One malformed copy of `data`: a byte flipped, a u32 replaced, a cut, or bytes added.
local function mutate(data: string): string
  local length = #data
  if length == 0 then return 'x' end

  local roll = random(10)
  local copy = buffer.fromstring(data)
  if roll < 3 then
    local at = random(length)
    buffer.writeu8(copy, at, bit32.bxor(buffer.readu8(copy, at), 2 ^ random(8)))
    return buffer.tostring(copy)
  end

  if roll < 7 and length >= 4 then
    local at = random(math.min(length - 3, 512))
    local value =
      pick { 0, 1, 0xff, 0xffff, 0x7fffffff, 0xffffffff, random(), random(length * 2 + 1) }
    buffer.writeu32(copy, at, value)
    return buffer.tostring(copy)
  end

  if roll < 9 then return string.sub(data, 1, random(length)) end

  return data .. string.rep('\0', random(5)) .. 'trailing'
end

suite.describe('malformed archives', function()
  suite.it('mutations of the built and hand-made archives', function()
    local count = 0
    for _, case in corpus do
      for mutation = 1, 6 do
        local data = mutate(case.data)
        compare(`mutated/{case.name}/{mutation}`, observeBytes(data))
        count += 1
      end
    end

    expect(count > 0).toBe(true)
  end)
end)

suite.describe('fixtures', function()
  local root = `{support.here()}/fixtures`
  for _, relative in
    {
      'ba2/invalid/invalid_exhausted.ba2',
      'ba2/invalid/invalid_format.ba2',
      'ba2/invalid/invalid_magic.ba2',
      'ba2/invalid/invalid_sentinel.ba2',
      'ba2/invalid/invalid_size.ba2',
      'ba2/invalid/invalid_version.ba2',
      'ba2/guess/fo4.ba2',
      'ba2/guess/tes3.bsa',
      'ba2/guess/tes4.bsa',
      'ba2/missing_string_table/in.ba2',
      'ba2/compression/normal.ba2',
      'ba2/compression/xbox.ba2',
      'ba2/next_gen/gnrl_v7.ba2',
      'ba2/next_gen/gnrl_v8.ba2',
      'bsa/tes4/invalid/invalid_magic.bsa',
      'bsa/tes4/invalid/invalid_size.bsa',
      'bsa/tes4/invalid/invalid_version.bsa',
      'bsa/tes4/valid/simple_uncompressed.bsa',
      'bsa/tes4/valid/test_104.bsa',
      'bsa/tes4/valid/test_105.bsa',
    }

  do
    suite.it(`fixture/{relative}`, function()
      local path = `{root}/{relative}`
      compare(`fixture/{relative}`, observeBytes(host.readFileString(path)))
      compare(`fixture/{relative}/path`, function(module: any): string
        local lines = {}
        for _, opener in { 'openPath', 'ba2', 'tes3', 'tes4' } do
          local open = if opener == 'openPath'
            then module.openPath
            elseif opener == 'ba2' then module.ba2.openPath
            elseif opener == 'tes3' then module.bsa.tes3.openPath
            else module.bsa.tes4.openPath
          local ok, opened = pcall(open, path)
          if not ok then
            table.insert(lines, `{opener}: {support.errorText(opened)}`)
            continue
          end

          table.insert(lines, `{opener} {opened:format()} {opened:len()} {opened:archiveSize()}`)
          for index = 1, opened:len() do
            local read, result = pcall(opened.readEntry, opened, index)
            table.insert(lines, if read then support.digest(result) else support.errorText(result))
          end
        end

        local ok, format = pcall(module.detectPath, path)
        table.insert(lines, `detect {ok} {format}`)
        return table.concat(lines, '\n')
      end, false)
    end)
  end
end)

suite.describe('top-level functions', function()
  suite.it('guess, detect, normalize, encode, and hash', function()
    local paths = table.create(200)
    for index = 1, 200 do
      paths[index] = randomPath()
    end

    compare('functions', function(module: any): string
      local lines = {}
      for _, magic in { '', 'B', 'BTD', 'BTDX', 'BSA\0', '\0\1\0\0', '\0\1\0', 'NOPE', 'bsa\0' } do
        table.insert(
          lines,
          `guess {string.format('%q', magic)} {module.guessFormat(magic)} {module.guessFormat(
            buffer.fromstring(magic)
          )}`
        )
        local ok, problem = pcall(module.openBytes, magic)
        table.insert(lines, `open {ok} {if ok then 'archive' else support.errorText(problem)}`)
      end

      for _, path in paths do
        table.insert(lines, string.format('%q', module.normalizePath(path)))
        table.insert(lines, string.format('%q', module.bsa.normalizePath(path)))
        local ba2 = module.ba2.hashFile(path)
        table.insert(
          lines,
          `{ba2.directory} {ba2.file} {ba2.extension} {string.format('%q', ba2.normalized)}`
        )
        local tes3 = module.bsa.tes3.hashFile(path)
        table.insert(lines, `{tes3.lo} {tes3.hi} {tes3.hex} {string.format('%q', tes3.normalized)}`)
        for _, hash in { module.bsa.tes4.hashDirectory(path), module.bsa.tes4.hashFile(path) } do
          table.insert(
            lines,
            `{hash.last} {hash.last2} {hash.length} {hash.first} {hash.crc} {hash.hex}`
          )
        end
      end

      for _, text in
        {
          'meshes/foo.nif',
          'zażółć',
          'привет',
          'María_F.fuz',
          'éöü',
          'box│─',
          '你好',
          '✓',
          'bad\255',
        }

      do
        for _, encoding in
          { 'utf8', 'windows1250', 'cp1250', 'windows1251', 'windows1252', 'cp437', 'latin1' }

        do
          local ok, encoded = pcall(module.bsa.encodeFilename, text, encoding)
          table.insert(lines, `encode {ok} {string.format('%q', support.errorText(encoded))}`)
          local decoded, shown = pcall(module.bsa.decodeFilenameLossy, text, encoding)
          table.insert(lines, `decode {decoded} {string.format('%q', support.errorText(shown))}`)
        end
      end

      for byte = 0, 255 do
        for _, encoding in { 'windows1250', 'windows1251', 'windows1252', 'cp437' } do
          table.insert(lines, (module.bsa.decodeFilenameLossy(string.char(byte), encoding)))
        end
      end

      return table.concat(lines, '\n')
    end)
  end)
end)

local function treeOf(root: string): string
  if not host.exists(root) then return '<nothing>' end

  local lines = {}
  for _, row in host.list(root, { recursive = true }) do
    local relative = string.sub(row.path, #root + 2)
    if row.isDir then
      table.insert(lines, `{string.format('%q', relative)}/`)
    else
      table.insert(
        lines,
        `{string.format('%q', relative)} {support.digest(host.readFileString(row.path))}`
      )
    end
  end

  return table.concat(lines, '\n')
end

if scratch then
  suite.describe('the host filesystem', function()
    local counter = 0
    local function folder(module: any): string
      counter += 1
      local path = `{scratch}/port-{counter}`
      host.mkdir(path, { recursive = true })
      return path
    end

    suite.it('extraction', function()
      compare('fs/extract', function(module: any): string
        local lines = {}
        -- What a failed extraction leaves behind depends on the crate's thread schedule, so only
        -- the outcome of a failed one is compared, and the tree of one that succeeded.
        local function record(label: string, root: string, ok: boolean, result: unknown)
          table.insert(lines, `{label} {ok} {support.errorText(result)}`)
          if ok then table.insert(lines, treeOf(root)) end
        end

        for index, case in corpus do
          if index % 3 ~= 0 then continue end

          local ok, opened = pcall(module.openBytes, case.data)
          if not ok then continue end

          local target = folder(module)
          table.insert(lines, case.name)
          record('extractTo', `{target}/all`, pcall(opened.extractTo, opened, `{target}/all`))
          if opened:format() ~= 'ba2' then
            for _, encoding in { 'windows1250', 'cp437' } do
              local root = `{target}/{encoding}`
              record(encoding, root, pcall(opened.extractToWithEncoding, opened, root, encoding))
            end
          end

          if opened:format() == 'bsaTes4' then
            local dictionary =
              { 'meshes/door.nif', 'data/readme.txt', 'textures\\x\\icon.dds', '../x', 'data/../y' }
            for _, entry in opened:entries() do
              if entry.path then table.insert(dictionary, string.upper(entry.path)) end
            end

            local root = `{target}/named`
            record('paths', root, pcall(opened.extractToWithPaths, opened, root, dictionary))
          end

          if opened:len() > 0 then
            local root = `{target}/single`
            record(
              'entry',
              root,
              pcall(opened.extractEntryToPath, opened, 1, `{root}/deep/entry.bin`)
            )
          end
        end

        return table.concat(lines, '\n')
      end)
    end)

    suite.it('builders over files', function()
      compare('fs/builders', function(module: any): string
        local base = folder(module)
        host.mkdir(`{base}/tree/Meshes/X`, { recursive = true })
        host.mkdir(`{base}/tree/textures`, { recursive = true })
        host.writeFile(`{base}/tree/Meshes/X/Door.NIF`, 'door')
        host.writeFile(`{base}/tree/textures/a.dds`, string.rep('dds', 99))
        host.writeFile(`{base}/tree/readme.txt`, 'readme')
        host.writeFile(`{base}/single.txt`, 'single')
        local lines = {}
        for _, family in { 'tes3', 'tes4', 'ba2' } do
          local builder = builderFor(module, family)
          for _, step in
            {
              function() builder:addDir(`{base}/tree`) end,
              function() builder:addFile('extra/single.txt', `{base}/single.txt`) end,
              function() builder:addFile('extra/missing.txt', `{base}/missing.txt`) end,
              function() builder:addDir(`{base}/missing`) end,
              function() builder:addDir(`{base}/single.txt`) end,
              function() builder:addDir(`{base}/tree`) end,
            }

          do
            local outcome = { pcall(step) }
            table.insert(lines, `{family} {outcome[1]} {support.errorText(outcome[2])}`)
          end

          local written, problem = pcall(builder.writePath, builder, `{base}/{family}.out`)
          table.insert(lines, `write {written} {support.errorText(problem)}`)
          table.insert(lines, support.digest(host.readFileString(`{base}/{family}.out`)))
          local bad, failure = pcall(builder.writePath, builder, `{base}/nowhere/x.out`)
          table.insert(lines, `write missing folder {bad} {support.errorText(failure)}`)
        end

        local dx10 = module.ba2.Dx10Builder.new()
        local header = { height = 4, width = 4, mipCount = 1, format = 61, flags = 0, tileMode = 0 }
        host.writeFile(`{base}/a.dds`, support.ddsFile(header, string.rep('p', 16), 'plain'))
        for _, step in
          {
            function() dx10:addDdsFile('textures/a.dds', `{base}/a.dds`) end,
            function() dx10:addDdsFile('textures/b.dds', `{base}/missing.dds`) end,
            function() dx10:addDdsFile('textures/c.dds', `{base}/single.txt`) end,
          }

        do
          local outcome = { pcall(step) }
          table.insert(lines, `dx10 {outcome[1]} {support.errorText(outcome[2])}`)
        end

        dx10:writePath(`{base}/dx10.out`)
        table.insert(lines, support.digest(host.readFileString(`{base}/dx10.out`)))
        for _, path in
          { `{base}/single.txt`, `{base}/tree`, `{base}/missing.bin`, `{base}/dx10.out` }

        do
          local ok, format = pcall(module.detectPath, path)
          table.insert(lines, `detect {ok} {support.errorText(format)}`)
          local opened, result = pcall(module.openPath, path)
          table.insert(
            lines,
            `open {opened} {if opened then result:len() else support.errorText(result)}`
          )
        end

        return table.concat(lines, '\n')
      end)
    end)
  end)
end

if fixtureRoot then
  suite.describe('dream_archive\'s texture fixtures', function()
    for _, case in
      {
        { 'ba2/dds/in.ba2', 'Fence006_1K_Roughness.dds', 'ba2/dds/Fence006_1K_Roughness.dds' },
        { 'ba2/cubemap/in.ba2', 'blacksky_e.dds', 'ba2/cubemap/blacksky_e.dds' },
        {
          'ba2/next_gen/dx10_v7.ba2',
          'Fence006_1K_Roughness.dds',
          'ba2/next_gen/dx10/Fence006_1K_Roughness.dds',
        },

        {
          'ba2/next_gen/dx10_v8.ba2',
          'Fence006_1K_Roughness.dds',
          'ba2/next_gen/dx10/Fence006_1K_Roughness.dds',
        },
      }

    do
      suite.it(case[1], function()
        local path = `{fixtureRoot}/{case[1]}`
        compare(
          `texture/{case[1]}`,
          function(module: any): string return support.observe(module, host.readFileString(path)) end
        )
        local opened = port.ba2.openPath(path)
        local data = opened:readFileRequired(case[2])
        local expected = host.readFileString(`{fixtureRoot}/{case[3]}`)
        expect(#data).toBe(#expected)
        expect(string.sub(data, 149)).toBe(string.sub(expected, 149))
        if case[1] == 'ba2/cubemap/in.ba2' then expect(data == expected).toBe(true) end

        local builder = port.ba2.Dx10Builder.new()
        builder:addDdsBytes('textures/again.dds', expected)
        local again = port.ba2.openBytes(builder:toBytes()):readFileRequired 'textures/again.dds'
        expect(string.sub(again, 149)).toBe(string.sub(expected, 149))
      end)
    end
  end)
end

if realArchives then
  suite.describe('real archives', function()
    for _, path in realArchives :: { string } do
      -- Named by file name and size, so the same archive is the same case wherever it is.
      local size = (host.stat(path) :: { size: number }).size
      local name = `real/{string.match(path, '[^/\\]+$')}#{size}`
      suite.it(path, function()
        compare(name, function(module: any): string
          local opened = module.openPath(path)
          local lines = { `{opened:format()} {opened:len()} {opened:archiveSize()}` }
          for index, entry in opened:entries() do
            local ok, data = pcall(opened.readEntry, opened, index)
            table.insert(
              lines,
              `{string.format('%q', tostring(entry.path))} {entry.size} {entry.offset} {entry.hashHex or ''} {entry.folderHashHex or ''} {entry.directoryHash or ''} {if ok
                then support.digest(data)
                else support.errorText(data)}`
            )
            local found = if entry.path then opened:get(string.upper(entry.path)) else nil
            if found and found.index ~= index then
              table.insert(lines, `first of its name: {found.index}`)
            end
          end

          return table.concat(lines, '\n')
        end)
      end)
    end
  end)
end

require './tool_differential' {
  suite = suite,
  compare = compare,
  corpus = corpus,
  port = port,
  scratch = scratch,
  links = links,
  realArchives = realArchives,
}

--- Whether this run may lack the case `name` names: the filesystem cases without a scratch
--- folder, the symbolic link cases without links, the large fixtures without their folder, and
--- real archives, which are whichever the environment names.
local function optional(name: string): boolean
  if string.find(name, '^fs/tool/links') then return not (scratch and links) end

  if string.find(name, '^fs/') then return not scratch end

  if string.find(name, '^texture/') then return not fixtureRoot end

  return string.find(name, '^real/') ~= nil
end

suite.describe('goldens', function()
  suite.it('cover every case, and take the new ones when blessing', function()
    if bless then
      -- The cases this run couldn't make keep their goldens, after the rest, in name order.
      local kept = {}
      for name, value in golden do
        if not seenNames[name] and optional(name) then table.insert(kept, `{name}\t{value}`) end
      end

      table.sort(kept)
      table.move(kept, 1, #kept, #recorded + 1, recorded)

      host.writeFile(goldenPath, table.concat(recorded, '\n') .. '\n')
      return
    end

    for name in golden do
      if not seenNames[name] and not optional(name) then
        error(`the golden {name} names no case; JESS_BLESS=1 drops it`, 0)
      end
    end
  end)
end)

return suite
