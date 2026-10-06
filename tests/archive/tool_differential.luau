--!strict
--!native
-- The archive tool against the dream_archivetool crate, case by case, through the crate's answers:
-- every result as a table with its keys sorted, every error, and the bytes and files an operation
-- wrote, with the scratch folder it wrote in named `<base>`. `differential.luau` registers these
-- after its own cases, on the corpus they built, and holds each observation to the digest frozen
-- from the crate's native module while jess linked it. That module took an opened archive through
-- methods on it (`archive:verify()`); the port takes it as the first argument
-- (`tool.verify(archive)`), and its errors name the function where the module's named the method.
local support = require './support'
local tool = require '@dreamwind/archive/tool'
local host = require('@dreamwind/vfs').host

export type Context = {
  suite: any,
  compare: (name: string, observe: (module: any) -> string) -> (),
  corpus: { { name: string, data: string } },
  port: any,
  scratch: string?,
  links: string?,
  realArchives: { string }?,
}

--- Every occurrence of `from` in `text` replaced, matched as plain text.
local function replaceAll(text: string, from: string, to: string): string
  if from == '' then return text end

  local parts = {}
  local start = 1
  while true do
    local at, finish = string.find(text, from, start, true)
    if not at then break end

    table.insert(parts, string.sub(text, start, at - 1))
    table.insert(parts, to)
    start = (finish :: number) + 1
  end

  table.insert(parts, string.sub(text, start))
  return table.concat(parts)
end

--- Every function of the tool, for calls with the wrong arguments on purpose.
local tools: any = tool

--- A value as text: tables with their keys sorted, integers as 16 hex digits.
local function show(value: any): string
  if typeof(value) == 'integer' then return string.format('%016x', value) end

  if type(value) == 'string' then return string.format('%q', value) end

  if type(value) ~= 'table' then return tostring(value) end

  local keys = {}
  for key in value do
    table.insert(keys, key)
  end

  table.sort(
    keys,
    function(left: any, right: any): boolean return tostring(left) < tostring(right) end
  )
  local parts = {}
  for _, key in keys do
    table.insert(parts, `{key}={show(value[key])}`)
  end

  return `\{{table.concat(parts, ',')}}`
end

--- An error as the comparison sees it: the codec details aside.
local function errorText(message: unknown): string
  local text = tostring(message)
  for _, kind in { 'archive error: ', 'I/O error: ' } do
    if string.sub(text, 1, #kind) == kind then
      return kind .. support.errorText(string.sub(text, #kind + 1))
    end
  end

  return support.errorText(text)
end

--- One call's outcome: its results, or its error.
local function outcome(...: any): string
  local results = table.pack(...)
  if not results[1] then return `error {errorText(results[2])}` end

  local shown = {}
  for index = 2, results.n do
    table.insert(shown, show(results[index]))
  end

  return `ok {table.concat(shown, ' ')}`
end

--- The files below `root`, each with its contents' digest.
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

--- A DDS texture `support.ddsFile` writes, 4x4 BC1 with one mip.
local function ddsTexture(payload: string): string
  local header = { height = 4, width = 4, mipCount = 1, format = 71, flags = 0, tileMode = 0 }
  return support.ddsFile(header, payload, 'dx10')
end

return function(context: Context)
  local suite, compare, port = context.suite, context.compare, context.port
  local random = support.generator(0x7001_5eed)

  --- A tool operation on an opened archive, which takes it first.
  local function call(_module: any, name: string, opened: any, ...: any): any
    return tools[name](opened, ...)
  end

  --- Everything the tool says of an archive opened from `data`, without writing anything.
  local function observeOpened(module: any, data: string, other: string?): string
    local ok, opened = pcall(module.openBytes, data)
    -- `open: ` as the archive cases write it, which the comparison knows a capacity failure by.
    if not ok then return `open: {errorText(opened)}` end

    local lines = {}
    local function line(label: string, ...: any) table.insert(lines, `{label} {outcome(...)}`) end

    line('info', pcall(call, module, 'info', opened))
    line('verify', pcall(call, module, 'verify', opened))
    line('verify read', pcall(call, module, 'verify', opened, { readPayloads = true }))
    local output = 'dreamwind-tool-nowhere'
    line('planExtractAll', pcall(call, module, 'planExtractAll', opened, { output = output }))
    line(
      'planExtractAll skip',
      pcall(call, module, 'planExtractAll', opened, { output = `{output}/`, overwrite = 'skip' })
    )

    local paths, hexes = {}, {}
    for index, entry in opened:entries() do
      if index > 3 then break end

      local path = entry.path
      if not path then continue end

      table.insert(paths, path)
      table.insert(
        hexes,
        (
          string.gsub(
            module.normalizePath(path),
            '.',
            function(byte: string): string return string.format('%02x', string.byte(byte)) end
          )
        )
      )
    end

    if #paths > 0 then
      line('planExtract', pcall(call, module, 'planExtract', opened, paths, { output = output }))
      line(
        'planExtract flat',
        pcall(
          call,
          module,
          'planExtract',
          opened,
          paths,
          { output = output, preservePaths = false }
        )
      )
      line(
        'planExtract upper',
        pcall(call, module, 'planExtract', opened, { string.upper(paths[1]), 'missing.dds' })
      )
      line('planExtractByPathHex', pcall(call, module, 'planExtractByPathHex', opened, hexes))
      local entries = {}
      for index, entry in opened:entries() do
        if index > 3 then break end

        table.insert(entries, entry)
      end

      line('planExtract entries', pcall(call, module, 'planExtract', opened, entries))
    end

    line('diff self', pcall(call, module, 'diff', opened, opened))
    if other then
      local opens, second = pcall(module.openBytes, other)
      if opens then
        line('diff', pcall(call, module, 'diff', opened, second))
        line(
          'diff fingerprints',
          pcall(call, module, 'diff', opened, second, { fingerprintPayloads = true })
        )
        line(
          'diff back',
          pcall(call, module, 'diff', second, opened, { fingerprintPayloads = true })
        )
      end
    end

    return table.concat(lines, '\n')
  end

  suite.describe('the archive tool on archives in memory', function()
    suite.it('the built and hand-made archives', function()
      for index, case in context.corpus do
        local other = context.corpus[index % #context.corpus + 1].data
        compare(
          `tool/{case.name}`,
          function(module: any): string return observeOpened(module, case.data, other) end
        )
      end
    end)

    suite.it('malformed copies of them', function()
      for _, case in context.corpus do
        for mutation = 1, 2 do
          local data = case.data
          local length = #data
          if length == 0 then continue end

          local copy = buffer.fromstring(data)
          local at = random(length)
          buffer.writeu8(copy, at, bit32.bxor(buffer.readu8(copy, at), 2 ^ random(8)))
          local mutated = buffer.tostring(copy)
          compare(
            `tool/mutated/{case.name}/{mutation}`,
            function(module: any): string return observeOpened(module, mutated, data) end
          )
        end
      end
    end)
  end)

  local realArchives = context.realArchives
  if realArchives then
    suite.describe('the archive tool on real archives', function()
      for _, path in realArchives :: { string } do
        local size = (host.stat(path) :: { size: number }).size
        local name = `real/tool/{string.match(path, '[^/\\]+$')}#{size}`
        suite.it(path, function()
          compare(name, function(module: any): string
            local lines = {}
            local function line(label: string, ...: any)
              table.insert(lines, `{label} {outcome(...)}`)
            end

            line('info', pcall(tools.info, path))
            line('verify', pcall(tools.verify, path, { readPayloads = true }))
            line('plan', pcall(tools.planExtractAll, path, { output = 'dreamwind-tool-nowhere' }))
            return replaceAll(table.concat(lines, '\n'), path, '<archive>')
          end)
        end)
      end
    end)
  end

  local scratch = context.scratch
  if not scratch then return end

  local counter = 0
  --- A fresh folder for one side of one case.
  local function folder(module: any): string
    counter += 1
    local path = `{scratch}/tool-{counter}`
    host.mkdir(path, { recursive = true })
    return path
  end

  --- Archives both sides read, built once by the port's builders, which the archive suite holds
  --- to the crate's bytes.
  local function sampleArchives(): { [string]: string }
    local archives: { [string]: string } = {}
    local tes3 = port.bsa.tes3.Builder.new()
    tes3:addBytes('Textures/A.dds', 'texture a')
    tes3:addBytes('meshes\\x\\Door.NIF', 'door')
    tes3:addBytes('icons/a.dds', 'icon a')
    tes3:addBytes('readme.txt', 'readme')
    archives.tes3 = tes3:toBytes()

    for _, spec: any in
      {
        { 'tes4', 103, 'strings', false },
        { 'tes4embedded', 104, 'stringsAndEmbedded', true },
        { 'tes4sse', 105, 'embedded', true },
      }

    do
      local builder = port.bsa.tes4.Builder.new()
      builder:setVersion(spec[2])
      builder:setNameMode(spec[3])
      builder:setCompressed(spec[4])
      builder:addBytes('meshes/a.nif', string.rep('a', 300))
      builder:addBytes('meshes/b.nif', 'bb')
      builder:addBytes('textures/c.dds', 'c')
      archives[spec[1]] = builder:toBytes()
    end

    local hashOnly = port.bsa.tes4.Builder.new()
    hashOnly:setNameMode 'hashOnly'
    hashOnly:addBytes('meshes/a.nif', 'hash only')
    archives.tes4hash = hashOnly:toBytes()

    for _, spec: any in { { 'ba2', 'none', 1 }, { 'ba2zip', 'zip', 1 }, { 'ba2lz4', 'lz4', 3 } } do
      local builder = port.ba2.Builder.new()
      builder:setVersion(spec[3])
      builder:setCompression(spec[2])
      builder:addBytes('Meshes/A.nif', string.rep('a', 400))
      builder:addBytes('textures/b.txt', 'b')
      archives[spec[1]] = builder:toBytes()
    end

    local dx10 = port.ba2.Dx10Builder.new()
    dx10:addDdsBytes('textures/a.dds', ddsTexture(string.rep('t', 8)))
    archives.dx10 = dx10:toBytes()

    -- A TES3 archive whose stored names leave the output folder, as the crate's own test makes it.
    local unsafe = port.bsa.tes3.Builder.new()
    unsafe:addBytes('ab\\cd\\C.dds', 'payload')
    unsafe:addBytes('fine.txt', 'fine')
    local bytes = unsafe:toBytes()
    local at = string.find(string.lower(bytes), 'ab\\cd\\c.dds', 1, true) :: number
    archives.unsafe = string.sub(bytes, 1, at - 1) .. '..\\..\\C.dds' .. string.sub(bytes, at + 11)
    return archives
  end

  --- Writes the sample archives into `base`, each as `<name>.archive`.
  local function writeArchives(base: string, archives: { [string]: string })
    for name, data in archives do
      host.writeFile(`{base}/{name}.archive`, data)
    end
  end

  local function sortedNames(archives: { [string]: string }): { string }
    local names = {}
    for name in archives do
      table.insert(names, name)
    end

    table.sort(names)
    return names
  end

  suite.describe('the archive tool on the host filesystem', function()
    local archives: { [string]: string } = {}
    local names: { string } = {}
    suite.it('builds the sample archives', function()
      archives = sampleArchives()
      names = sortedNames(archives)
    end)

    suite.it('inspects archives by path', function()
      compare('fs/tool/inspect', function(module: any): string
        local base = folder(module)
        writeArchives(base, archives)
        local lines = {}
        local function line(label: string, ...: any) table.insert(lines, `{label} {outcome(...)}`) end

        for index, name in names do
          local path = `{base}/{name}.archive`
          local other = `{base}/{names[index % #names + 1]}.archive`
          line(`{name} info`, pcall(tools.info, path))
          line(`{name} verify`, pcall(tools.verify, path, { readPayloads = true }))
          line(`{name} diff`, pcall(tools.diff, path, other, { fingerprintPayloads = true }))
          line(`{name} diff self`, pcall(tools.diff, path, path))
          line(`{name} plan`, pcall(tools.planExtractAll, path, { output = `{base}/out` }))
        end

        local path = `{base}/tes3.archive`
        line('missing archive', pcall(tools.info, `{base}/missing.bsa`))
        line('folder as archive', pcall(tools.info, base))
        line('below a file', pcall(tools.info, `{base}/tes3.archive/x`))
        line('no arguments', pcall(tools.info))
        line('a number', pcall(tools.info, 5))
        line('verify options', pcall(tools.verify, path, { readPayloads = 1 }))
        line('verify unknown', pcall(tools.verify, path, { read = true }))
        line('verify not a table', pcall(tools.verify, path, 'x'))
        line('diff one', pcall(tools.diff, path))
        line('diff options', pcall(tools.diff, path, path, { fingerprint = true }))
        return replaceAll(table.concat(lines, '\n'), base, '<base>')
      end)
    end)

    suite.it('extracts', function()
      compare('fs/tool/extract', function(module: any): string
        local base = folder(module)
        writeArchives(base, archives)
        local lines = {}
        local function line(label: string, ...: any) table.insert(lines, `{label} {outcome(...)}`) end

        local function tree(label: string, root: string)
          table.insert(lines, `{label}:\n{treeOf(root)}`)
        end

        for _, name in names do
          local path = `{base}/{name}.archive`
          local out = `{base}/all-{name}`
          line(`{name} plan`, pcall(tools.planExtractAll, path, { output = out }))
          line(`{name} all`, pcall(tools.extractAll, path, { output = out }))
          tree(name, out)
          line(`{name} again`, pcall(tools.extractAll, path, { output = out }))
          line(`{name} plan again`, pcall(tools.planExtractAll, path, { output = out }))
          line(`{name} skip`, pcall(tools.extractAll, path, { output = out, overwrite = 'skip' }))
          line(
            `{name} overwrite`,
            pcall(tools.extractAll, path, { output = out, overwrite = 'overwrite' })
          )
        end

        local path = `{base}/tes3.archive`
        local out = `{base}/one`
        for _, case: any in
          {
            { 'upper', 'TEXTURES//A.DDS', {} },
            { 'flat', 'meshes\\x\\door.nif', { preservePaths = false } },
            { 'again', 'textures/a.dds', {} },
            { 'skip', 'textures/a.dds', { overwrite = 'skip' } },
            { 'overwrite', 'textures/a.dds', { overwrite = 'overwrite' } },
            { 'missing', 'Missing.DDS', {} },
            { 'parent', '../readme.txt', {} },
            { 'absolute', '/readme.txt', {} },
            { 'colon', 'c:readme.txt', {} },
            { 'nul', 'readme.txt\0x', {} },
            { 'empty', '', {} },
            { 'dot', './readme.txt', {} },
            { 'number', 5, {} },
            { 'bad options', 'readme.txt', { overwrite = 'explode' } },
            { 'unknown options', 'readme.txt', { b = 1, a = 2 } },
            { 'options not a table', 'readme.txt', 'x' },
            { 'option keys', 'readme.txt', { 1 } },
          }

        do
          local options = case[3]
          if type(options) == 'table' and options[1] == nil then
            options = table.clone(options)
            options.output = out
          end

          line(`extract {case[1]}`, pcall(tools.extract, path, case[2], options))
        end

        line('extract nothing', pcall(tools.extract, path))
        line(
          'extract to a bare name',
          pcall(tools.planExtract, path, { 'readme.txt' }, { output = '' })
        )
        line('extract to the default', pcall(tools.planExtract, path, { 'readme.txt' }))
        tree('one', out)

        local hexes = {
          '74657874757265732f612e646473',
          '726561646d652e747874',
          '2e2e2f78',
          '6d697373696e67',
          'zz',
          'abc',
        }

        for _, value in hexes do
          line(
            `byPathHex {value}`,
            pcall(tools.extractByPathHex, path, value, { output = `{base}/hex` })
          )
          line(
            `hex {value}`,
            pcall(tools.extractHex, path, value, { output = `{base}/hex`, overwrite = 'skip' })
          )
        end

        line('byPathHex number', pcall(tools.extractByPathHex, path, 5))
        tree('hex', `{base}/hex`)

        local many = `{base}/many`
        for _, case: any in
          {
            { 'list', { 'textures/a.dds', 'MESHES/X/DOOR.NIF' }, {} },
            { 'existing', { 'readme.txt', 'textures/a.dds' }, {} },
            { 'skip', { 'readme.txt', 'textures/a.dds' }, { overwrite = 'skip' } },
            { 'flat clash', { 'textures/a.dds', 'icons/a.dds' }, { preservePaths = false } },
            { 'same twice', { 'readme.txt', 'README.TXT' }, { overwrite = 'overwrite' } },
            { 'missing', { 'readme.txt', 'missing.dds' }, { overwrite = 'overwrite' } },
            { 'unsafe', { '../x' }, {} },
            { 'holes', { [1] = 'readme.txt', [3] = 'x' }, {} },
            { 'keys', { x = 'readme.txt' }, {} },
            { 'numbers', { 5 }, {} },
            { 'not a list', 5, {} },
            { 'empty', {}, {} },
          }

        do
          local options = table.clone(case[3])
          options.output = many
          line(`many {case[1]}`, pcall(tools.extractMany, path, case[2], options))
          line(`plan many {case[1]}`, pcall(tools.planExtract, path, case[2], options))
        end

        tree('many', many)
        for _, case: any in
          {
            { 'hexes', { '726561646d652e747874', '69636f6e732f612e646473' } },
            { 'bad hex', { 'zz' } },
            { 'numbers', { 5 } },
            { 'not a list', 5 },
          }

        do
          local options = { output = `{base}/manyhex`, overwrite = 'skip' }
          line(`many hex {case[1]}`, pcall(tools.extractManyByPathHex, path, case[2], options))
          line(`plan many hex {case[1]}`, pcall(tools.planExtractByPathHex, path, case[2], options))
        end

        tree('many hex', `{base}/manyhex`)

        local opened = module.openPath(path)
        local entries = opened:entries()
        line('entries', pcall(tools.extractMany, path, entries, { output = `{base}/entries` }))
        line('entry', pcall(tools.extract, path, entries[2], { output = `{base}/entry` }))
        tree('entries', `{base}/entries`)
        tree('entry', `{base}/entry`)

        local hashOnly = `{base}/tes4hash.archive`
        local hashed = module.openPath(hashOnly)
        line(
          'hash only by path',
          pcall(tools.extract, hashOnly, 'meshes/a.nif', { output = `{base}/hashed` })
        )
        line(
          'hash only entry',
          pcall(tools.extract, hashOnly, hashed:entries()[1], { output = `{base}/hashed` })
        )
        line('hash only list', pcall(tools.extractMany, hashOnly, { hashed:entries()[1] }))
        tree('hashed', `{base}/hashed`)

        host.writeFile(`{base}/blocked`, 'a file where a folder goes')
        line(
          'folder is a file',
          pcall(tools.extract, path, 'readme.txt', { output = `{base}/blocked/x` })
        )
        line(
          'all into a file',
          pcall(tools.extractAll, path, { output = `{base}/blocked`, overwrite = 'overwrite' })
        )
        return replaceAll(table.concat(lines, '\n'), base, '<base>')
      end)
    end)

    --- A folder of loose files to pack, the same on both sides.
    local function writeTree(root: string)
      host.mkdir(`{root}/tree/Meshes/X`, { recursive = true })
      host.mkdir(`{root}/tree/textures/sub`, { recursive = true })
      host.mkdir(`{root}/tree/empty`, { recursive = true })
      host.writeFile(`{root}/tree/Meshes/X/Door.NIF`, 'door')
      host.writeFile(`{root}/tree/textures/a.dds`, string.rep('dds', 99))
      host.writeFile(`{root}/tree/textures/sub/b.txt`, 'b')
      host.writeFile(`{root}/tree/readme.txt`, 'readme')
      host.mkdir(`{root}/textures/x`, { recursive = true })
      host.writeFile(`{root}/textures/x/a.dds`, ddsTexture(string.rep('a', 8)))
      host.writeFile(`{root}/textures/x/B.DDS`, ddsTexture(string.rep('b', 8)))
      host.mkdir(`{root}/more/textures`, { recursive = true })
      host.writeFile(`{root}/more/textures/a.dds`, string.rep('new', 50))
      host.writeFile(`{root}/more/extra.txt`, 'extra')
      host.mkdir(`{root}/colon`, { recursive = true })
      host.writeFile(`{root}/colon/a:b.txt`, 'colon')
      host.writeFile(`{root}/single.TXT`, 'single')
    end

    suite.it('creates archives', function()
      compare('fs/tool/create', function(module: any): string
        local base = folder(module)
        writeTree(base)
        local lines = {}
        local function line(label: string, ...: any) table.insert(lines, `{label} {outcome(...)}`) end

        local tree = `{base}/tree`
        local cases = {
          { 'default', tree, nil },
          { 'tes3', tree, { format = 'tes3' } },
          { 'bsaTes3', `{tree}/`, { format = 'bsaTes3' } },
          { 'tes4', tree, { format = 'tes4' } },
          { 'tes4 compressed', tree, { format = 'bsaTes4', compress = true } },
          { 'fallout3', tree, { format = 'tes4', tes4Version = 'fallout3' } },
          { 'skyrim', tree, { format = 'tes4', tes4Version = 'skyrim', compress = true } },
          { 'skyrimSe', tree, { format = 'tes4', tes4Version = 'skyrimSe', compress = true } },
          { 'sse', tree, { format = 'tes4', tes4Version = 'sse' } },
          { 'ba2', tree, { format = 'ba2' } },
          { 'ba2 compressed', tree, { format = 'ba2', compress = true } },
          { 'starfield', tree, { format = 'ba2', ba2Version = 'starfield', compress = true } },
          { 'next gen', tree, { format = 'ba2', ba2Version = 'fallout4NextGen' } },
          { 'dx10', `{base}/textures`, { format = 'ba2', ba2Kind = 'dx10' } },
          {
            'dx10 compressed',
            `{base}/textures`,
            { format = 'ba2', ba2Kind = 'dx10', compress = true, ba2Version = 'fallout4NextGen' },
          },
          { 'dx10 of anything', tree, { format = 'ba2', ba2Kind = 'dx10' } },
          { 'gnmf', tree, { format = 'ba2', ba2Kind = 'gnmf' } },
          { 'single file', `{base}/single.TXT`, { format = 'tes4' } },
          { 'missing input', `{base}/missing`, nil },
          { 'unsafe name', `{base}/colon`, nil },
          { 'empty folder', `{tree}/empty`, nil },
          { 'unknown format', tree, { format = 'zip' } },
          { 'tes3 compressed', tree, { compress = true } },
          { 'tes3 version', tree, { tes4Version = 'skyrim' } },
          { 'tes3 kind', tree, { ba2Kind = 'gnrl' } },
          { 'tes4 kind', tree, { format = 'tes4', ba2Kind = 'gnrl' } },
          { 'tes4 ba2 version', tree, { format = 'tes4', ba2Version = 'starfield' } },
          { 'ba2 tes4 version', tree, { format = 'ba2', tes4Version = 'skyrim' } },
          { 'bad tes4 version', tree, { format = 'tes4', tes4Version = 'morrowind' } },
          { 'bad kind', tree, { format = 'ba2', ba2Kind = 'zip' } },
          { 'bad ba2 version', tree, { format = 'ba2', ba2Version = 'fallout76' } },
          { 'bad compress', tree, { format = 'tes4', compress = 'yes' } },
          { 'unknown option', tree, { format = 'tes4', level = 9 } },
        }

        for index, case: any in cases do
          local output = `{base}/out-{index}.archive`
          line(`plan {case[1]}`, pcall(tools.planCreate, output, case[2], case[3]))
          line(`create {case[1]}`, pcall(tools.create, output, case[2], case[3]))
          if host.exists(output) then
            table.insert(lines, `bytes {support.digest(host.readFileString(output))}`)
            line(`verify {case[1]}`, pcall(tools.verify, output, { readPayloads = true }))
          end
        end

        line('into a missing folder', pcall(tools.create, `{base}/nowhere/out.bsa`, tree))
        line('onto a folder', pcall(tools.create, tree, `{base}/single.TXT`))
        line('replacing', pcall(tools.create, `{base}/out-1.archive`, `{base}/single.TXT`))
        table.insert(lines, `bytes {support.digest(host.readFileString(`{base}/out-1.archive`))}`)
        line('one argument', pcall(tools.create, `{base}/x.bsa`))
        line('a number', pcall(tools.create, `{base}/x.bsa`, 5))
        return replaceAll(table.concat(lines, '\n'), base, '<base>')
      end)
    end)

    suite.it('adds to archives', function()
      compare('fs/tool/add', function(module: any): string
        local base = folder(module)
        writeTree(base)
        writeArchives(base, archives)
        local lines = {}
        local function line(label: string, ...: any) table.insert(lines, `{label} {outcome(...)}`) end

        local more = `{base}/more`
        for _, name in names do
          local path = `{base}/{name}.archive`
          local inputs = if name == 'dx10' then { `{base}/textures` } else { more }
          local output = `{base}/{name}-added.archive`
          line(`{name} plan`, pcall(tools.planAdd, path, { inputs = inputs, output = output }))
          line(`{name} add`, pcall(tools.add, path, { inputs = inputs, output = output }))
          if host.exists(output) then
            table.insert(lines, `bytes {support.digest(host.readFileString(output))}`)
            line(`{name} diff`, pcall(tools.diff, path, output, { fingerprintPayloads = true }))
          end
        end

        local path = `{base}/tes3.archive`
        line('in place plan', pcall(tools.planAdd, path, { inputs = { `{base}/single.TXT` } }))
        line('in place', pcall(tools.add, path, { inputs = { `{base}/single.TXT` } }))
        table.insert(lines, `bytes {support.digest(host.readFileString(path))}`)
        line('two inputs', pcall(tools.planAdd, path, { inputs = { more, `{base}/single.TXT` } }))
        line(
          'clashing inputs',
          pcall(
            tools.planAdd,
            path,
            { inputs = { more, `{more}/extra.txt` }, output = `{base}/x.bsa` }
          )
        )
        line('same output', pcall(tools.add, path, { inputs = { more }, output = path }))
        line(
          'same output spelled otherwise',
          pcall(
            tools.add,
            path,
            { inputs = { more }, output = `{base}/../{string.match(base, '[^/]+$')}/tes3.archive` }
          )
        )
        line(
          'dx10 of anything',
          pcall(tools.add, `{base}/dx10.archive`, { inputs = { more }, output = `{base}/y.ba2` })
        )
        line('missing input', pcall(tools.planAdd, path, { inputs = { `{base}/missing` } }))
        line('missing archive', pcall(tools.planAdd, `{base}/missing.bsa`, { inputs = { more } }))
        line(
          'missing folder',
          pcall(tools.add, path, { inputs = { more }, output = `{base}/nowhere/x.bsa` })
        )
        line('no options', pcall(tools.add, path))
        line('nil options', pcall(tools.add, path, nil))
        line('no inputs', pcall(tools.add, path, {}))
        line('empty inputs', pcall(tools.add, path, { inputs = {} }))
        line('inputs a number', pcall(tools.add, path, { inputs = 5 }))
        line('inputs numbers', pcall(tools.add, path, { inputs = { 5 } }))
        line('inputs holes', pcall(tools.add, path, { inputs = { [2] = more } }))
        line('options a string', pcall(tools.add, path, 'x'))
        line('unknown option', pcall(tools.add, path, { inputs = { more }, compress = true }))
        return replaceAll(table.concat(lines, '\n'), base, '<base>')
      end)
    end)

    local links = context.links
    if not links then return end

    suite.it('refuses symbolic links unless asked to follow them', function()
      compare('fs/tool/links', function(module: any): string
        local base = folder(module)
        local lines = {}
        local function line(label: string, ...: any) table.insert(lines, `{label} {outcome(...)}`) end

        for _, case: any in
          {
            { 'file link', `{links}/file-link` },
            { 'folder link', `{links}/folder-link` },
            { 'tree with a link', `{links}/tree` },
            { 'plain folder', `{links}/folder` },
          }

        do
          line(`{case[1]} refused`, pcall(tools.planCreate, `{base}/out.bsa`, case[2]))
          line(
            `{case[1]} followed`,
            pcall(tools.planCreate, `{base}/out.bsa`, case[2], { followSymlinks = true })
          )
        end

        return replaceAll(replaceAll(table.concat(lines, '\n'), base, '<base>'), links, '<links>')
      end)
    end)
  end)
end
